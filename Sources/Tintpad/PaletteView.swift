import AppKit
import SwiftUI

private struct PendingLaunch {
    let repo: Repo
    let agent: Agent
    let mode: RunMode
    /// What ⏎ replays once the user confirms — launch, dispatch, prompt,
    /// worktree, or resume all arm the same banner with their own action.
    let fire: () -> Void
}

/// What a launch line is about, held from the moment a launch starts until
/// its handoff answers, so the completion needs to carry nothing but its
/// generation (it crosses the handoff queue).
private struct LaunchContext {
    let generation: Int
    let summonGeneration: Int
    let repo: Repo?
    /// The launch as identities, held if it fails on a missing grant so the
    /// summon after the grant can offer it back. Nil when the launch has no
    /// agent (the editor).
    let held: HeldLaunch?
    /// The app named in "Opening …", nil for a launch with no line.
    let target: String?
    /// Re-runs the launch from its error line, through the danger gate. Nil
    /// when a failure has nothing honest to retry.
    let retry: (() -> Void)?
    /// Overrides the failure line (the editor path's own copy).
    let failureLine: ((Error) -> String)?
}

/// A failure that answered after its drop had gone (Esc, a focus loss, a
/// re-summon), held so the next summon can say it instead of it vanishing.
private struct DeferredFailure {
    let error: Error
    let context: LaunchContext
    let at: Date
}

/// An error line that Return retries. Holds the exact line it showed, so
/// anything that replaces or clears the line ends the retry.
private struct FailedLaunch {
    let line: String
    let retry: () -> Void
}

/// A launch that failed on a missing TCC grant. Held so the next ⏎ opens the
/// right System Settings pane instead of the error being a dead end — a
/// permission failure whose only affordance is prose reads as "nothing
/// happened" (the developer proved this personally).
struct PendingPermission {
    let summary: String
    let pane: PrivacyPane
    /// Permission failures on `pane` this app session, this one included.
    /// The second and later say the stale-grant remedy instead.
    let failures: Int
    /// The launch that failed, held once Return opens System Settings so
    /// the next summon can offer it back. Nil when it has nothing to retry.
    let retry: PendingRetry?

    var line: String { PermissionEscalation.line(pane: pane, summary: summary, failures: failures) }

    /// VoiceOver's version: both lines already say what Return does.
    var announcement: String { "\(line)." }
}

/// A terminal launch by identity, never by value: the repo, agent and mode
/// are looked up again when it runs, so an edited command or a deleted mode
/// is never replayed from a stale copy.
struct HeldLaunch {
    let repoID: UUID
    let agentID: UUID
    let modeID: UUID
    let prompt: String?
    let worktreePath: String?
}

/// A launch that failed on a missing grant, kept across summons from the
/// moment Return opens System Settings. Never fired without a Return, and
/// only through `LaunchGate` and the danger gate. Forgotten when used,
/// cancelled, superseded by any other launch, too old, or when its repo,
/// agent or mode is gone.
struct PendingRetry {
    let launch: HeldLaunch
    let pane: PrivacyPane
    var armedAt = Date()
}

/// Keyboard policy decisions that depend on assistive-tech state, kept pure so
/// they can be reasoned about and tested without the environment.
enum KeyPolicy {
    /// Tab is two things at once: our shortcut for cycling agents, and the key
    /// assistive tech uses to move focus between the field, the list, and the
    /// footer. Swallowing it unconditionally traps VoiceOver and Full Keyboard
    /// Access users in the search field. When either is on, Tab is left alone
    /// and the footer's "agent" and "mode" hints (real buttons, with labels)
    /// carry the same actions.
    static func tabShouldTraverse(voiceOver: Bool, fullKeyboardAccess: Bool) -> Bool {
        voiceOver || fullKeyboardAccess
    }
}

/// Which repo a middle-region line wears as its subject token. Generic so the
/// precedence is tested without building repos.
///
/// A pending confirm names its launch, a capture mode (worktree, prompt) its
/// repo. Outside those, a status or permission line belongs to the launch
/// that raised it, or to nothing (a scan result, "No session to resume yet"),
/// and must never borrow the selection's chip.
enum DropSubject {
    static func pick<R>(pending: R?, worktree: R?, prompt: R?, statusShown: Bool,
                        launch: R?, selected: R?) -> R? {
        if let pending { return pending }
        if let worktree { return worktree }
        if let prompt { return prompt }
        if statusShown { return launch }
        return launch ?? selected
    }
}

/// Holds the palette's mutable state and behavior. Lives as an `ObservableObject`
/// so a scoped `NSEvent` key monitor can drive navigation/actions reliably —
/// `.onKeyPress` on a `TextField` swallows arrow keys, so we don't rely on it.
@MainActor
final class PaletteModel: ObservableObject {
    // Typing changes which repo is selected, and overrides belong to the row
    // they were made on — so a query change clears them along with transients.
    @Published var query = "" {
        didSet {
            // Unanimated: the row just changed under the chip, a slide from a
            // token that no longer exists would be noise.
            select(0, animated: false)
            agentOverrideID = nil
            modeOverrideID = nil
            clearTransient()
            refreshGitContext()
        }
    }
    @Published var selection = 0
    /// The repo the last launch attempt was for, so its status line (Opening,
    /// an error, a note) keeps the right subject token even when that repo
    /// is not the selected one (⌘0 resumes a session from any repo).
    @Published private(set) var launchRepo: Repo?
    /// The drop's content at its natural (unconstrained) width, measured by
    /// a hidden copy in the view. The view hugs the capsule to it.
    @Published private(set) var naturalContentWidth: CGFloat = 0
    /// True while the token strip holds a scroll offset, which is the only
    /// time its left edge is hiding tokens rather than being the margin.
    @Published private(set) var stripScrolled = false
    @Published var agentOverrideID: UUID?
    @Published var modeOverrideID: UUID?
    @Published var status: String?
    @Published var selectedPromptID: UUID?
    @Published var worktreeRepo: Repo?
    /// When set, the search field captures a one-off prompt for this repo.
    @Published var promptRepo: Repo?

    /// The exit that is playing, from the request until the next summon's
    /// `reset()` (or a summon mid-exit, `cancelDismissal()`). Never cleared on
    /// the way out, because clearing it would reinflate the capsule offscreen.
    /// The view plays the exit and calls `exitDidFinish()` on its close beat,
    /// and only then does the panel-level `DismissSequencer` run.
    @Published private(set) var dismissal: DismissReason?
    var isDismissing: Bool { dismissal != nil }
    /// Set once the exit's close has been handed to the controller, so the
    /// view's close beat and the fallback below can't close twice.
    private var exitClosed = false
    /// Moves on every request and cancel, so a stale fallback stands down.
    private var dismissRequestGeneration = 0

    /// True from the launch request until its handoff answers. The handoff
    /// runs off main, so the drop stays live while it does: this flag is what
    /// keeps a second Return from launching again (`LaunchGate`), and what
    /// turns a focus loss mid-handoff (the terminal activating) into the
    /// launch exit (`DismissPolicy`). A summon clears it, a newer drop is
    /// free to launch while an older handoff finishes on its own.
    @Published private(set) var launchInFlight = false

    /// Bumped by every launch. Only the latest launch's answer is acted on,
    /// an older one was superseded by a launch the user made since.
    private var launchGeneration = 0
    private var launchContext: LaunchContext?
    /// Plays the "Still opening …" beat, cancelled when the handoff answers.
    private let launchBeats = StepSequencer()
    private var failedLaunch: FailedLaunch?
    private var deferredFailure: DeferredFailure?

    /// The note a finished launch left (Warp), kept while the drop stays open
    /// to show it.
    private var launchNote: String?

    /// True while the status line is still that note. Derived from `status`,
    /// so anything that replaces or clears the line (typing, moving, a scan)
    /// ends it, and Return goes back to launching.
    var noteShown: Bool { launchNote != nil && status == launchNote }

    /// Bumped on every summon. Deferred launch work captures it and stands
    /// down when a newer summon has happened, so a launch the user walked
    /// away from (Esc, then the hotkey) never lands in and closes a fresh drop.
    private var summonGeneration = 0

    /// Bumped by every note, so only the latest note's auto-close can fire.
    private var noteGeneration = 0

    /// Moves each time the controller blanks the panel for dismissal, so the
    /// view can snap the drop back to rest with no animation.
    @Published private(set) var dismissGeneration = 0

    /// The controller's `.blank` effect, see `DismissSequencer`.
    func noteDismissal() { dismissGeneration += 1 }

    /// The modifiers held while the palette is key, fed by `flagsChanged`, so
    /// the contract chips can preview what ⏎ would do before it lands.
    @Published private(set) var heldModifiers: NSEvent.ModifierFlags = []
    /// ⌘ has been held past `commandHoldDelay`. A hold, not a chord: ⌘R or
    /// ⌘P tapped quickly never flashes OPEN IN.
    @Published private(set) var commandHeld = false
    /// The editor ⌘⏎ opens, looked up once per ⌘ hold rather than per render
    /// (detection touches the filesystem).
    @Published private(set) var heldEditorName: String?
    /// Bumped on every ⌘ transition and every summon, so only the latest ⌘
    /// press can arm the hold.
    private var commandGeneration = 0
    private var commandDown = false
    private static let commandHoldDelay: TimeInterval = 0.15

    fileprivate var pendingDangerous: PendingLaunch?
    @Published private(set) var pendingPermission: PendingPermission?
    /// Permission failures per pane since the app started, never reset: a
    /// grant that fails again after it was given is the stale-grant trap,
    /// which is exactly what the escalated line explains.
    private var permissionFailures: [PrivacyPane: Int] = [:]
    /// The launch held for after the grant, see `PendingRetry`. Survives
    /// `reset()`, which is where it is offered.
    private var pendingRetry: PendingRetry?
    /// The offer line while a summon is offering `pendingRetry`. Return runs
    /// it, Esc forgets it.
    @Published private(set) var resumeOffer: String?

    /// Whether the panel is on screen. Set by the controller: Settings orders
    /// the panel out without a dismissal, so `isDismissing` alone can't tell.
    var isPresented: () -> Bool = { true }

    /// Injectable (like `tabTraverses`) so the gesture can be tested off.
    var reduceMotionActive: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Close after the launch exit has played.
    private func closeAfterLaunch() { requestDismiss(.launch) }

    /// Ask the drop to leave. The view plays the exit for `reason` (see
    /// `DropTimeline`) and calls `exitDidFinish()` on its close beat. The
    /// first request wins (`DismissPolicy`), and the flag it sets is what
    /// `LaunchGate` reads to ignore a Return while the drop is leaving.
    func requestDismiss(_ reason: DismissReason) {
        let next = DismissPolicy.next(current: dismissal, requested: reason, inFlight: launchInFlight)
        guard next != dismissal else { return }
        dismissal = next
        exitClosed = false
        disarmCommandHold()
        dismissRequestGeneration += 1
        // Safety net, not the choreography: if the view never plays the exit
        // (it isn't rendering), the panel must still close, a beat after the
        // exit's own close so it can never cut the animation short.
        let gen = dismissRequestGeneration
        let closeAt = DropTimeline.exit(next, reduceMotion: reduceMotionActive()).last?.at ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + closeAt + 0.25) { [weak self] in
            guard let self, dismissRequestGeneration == gen else { return }
            exitDidFinish()
        }
    }

    /// The exit's close beat: hand over to the panel-level dismissal.
    func exitDidFinish() {
        guard dismissal != nil, !exitClosed else { return }
        exitClosed = true
        onClose()
    }

    /// A summon landed mid-exit: nothing still queued may close the new drop.
    func cancelDismissal() {
        dismissRequestGeneration += 1
        exitClosed = false
        if dismissal != nil { dismissal = nil }
    }

    /// The gate every launch gesture passes first. Returns true when the
    /// gesture may go on to launch.
    private func admitLaunchGesture() -> Bool {
        switch LaunchGate.returnDisposition(
            inFlight: launchInFlight, dismissing: isDismissing, noteShown: noteShown) {
        case .launch: return true
        case .ignore: return false
        case .closeOnly: requestDismiss(.launch); return false
        }
    }

    /// Say where the launch is going and start it. `start` kicks off the
    /// handoff and must answer through the completion it is given, on main
    /// (synchronously for a preflight error, later for the handoff itself).
    /// After `stillOpeningAfter` seconds without an answer, the line admits
    /// the launch is slow.
    private func beginLaunch(opening target: String?, repo: Repo?, held: HeldLaunch? = nil,
                             retry: (() -> Void)?,
                             failureLine: ((Error) -> String)? = nil,
                             _ start: (@escaping LaunchService.Completion) -> Void) {
        launchGeneration += 1
        let gen = launchGeneration
        launchContext = LaunchContext(generation: gen, summonGeneration: summonGeneration,
                                      repo: repo, held: held, target: target, retry: retry,
                                      failureLine: failureLine)
        // The user has moved on from any older failure. A held permission
        // retry goes too: this launch is either it, or something newer.
        deferredFailure = nil
        failedLaunch = nil
        pendingRetry = nil
        resumeOffer = nil
        launchInFlight = true
        launchRepo = repo
        launchBeats.cancel()
        if let target {
            let opening = LaunchStatusCopy.opening(target)
            status = opening
            launchBeats.run([StepSequencer.Beat(at: LaunchStatusCopy.stillOpeningAfter) { [weak self] in
                // Only over its own line: typing or moving replaced it.
                guard let self, launchGeneration == gen, launchInFlight, status == opening else { return }
                status = LaunchStatusCopy.stillOpening(target)
            }])
        }
        start { [weak self] result in self?.launchDidFinish(result, generation: gen) }
    }

    /// A handoff answered. `LaunchAnswerPolicy` decides where: in its own
    /// drop it lands as usual (close, a note, an error line), a success
    /// anywhere else is silent, and a failure is said in a newer drop that is
    /// up and idle, or held for the next summon. It never closes a drop it
    /// doesn't belong to.
    private func launchDidFinish(_ result: Result<LaunchOutcome, Error>, generation gen: Int) {
        guard gen == launchGeneration, let context = launchContext else { return }
        launchContext = nil
        let ownDrop = context.summonGeneration == summonGeneration
        if ownDrop {
            launchInFlight = false
            launchBeats.cancel()
        }
        let succeeded: Bool
        if case .success = result { succeeded = true } else { succeeded = false }
        // A launch that went through means the grants it needed hold, so a
        // later refusal is a first failure again, not an escalation.
        if succeeded { permissionFailures.removeAll() }
        // Counted when the failure answers, wherever it is said (or if it is
        // never said, a held failure can expire): it happened this session.
        if case .failure(TerminalLaunchError.permissionNeeded(_, _, let pane)) = result {
            permissionFailures[pane, default: 0] += 1
        }
        let disposition = LaunchAnswerPolicy.disposition(
            succeeded: succeeded, ownDrop: ownDrop,
            dropPresent: isPresented() && !isDismissing,
            dropBusy: pendingDangerous != nil || pendingPermission != nil || resumeOffer != nil
                || worktreeRepo != nil || promptRepo != nil)
        switch (disposition, result) {
        case (.land, .success(let outcome)):
            finishLaunch(outcome)
        case (.land, .failure(let error)), (.reportNow, .failure(let error)):
            report(error, context: context)
        case (.deferUntilSummon, .failure(let error)):
            deferredFailure = DeferredFailure(error: error, context: context, at: Date())
        default:
            break
        }
    }

    /// A launch returned: close, or keep the drop open to show its note and
    /// close on our own after a moment if nothing else happens.
    private func finishLaunch(_ outcome: LaunchOutcome) {
        noteGeneration += 1
        guard let note = outcome.note else { closeAfterLaunch(); return }
        launchNote = note
        status = note
        let noteGen = noteGeneration, summonGen = summonGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, noteGeneration == noteGen, summonGeneration == summonGen,
                  noteShown else { return }
            requestDismiss(.launch)
        }
    }

    /// Injectable so the Tab policy can be exercised without VoiceOver running.
    var tabTraverses: () -> Bool = {
        KeyPolicy.tabShouldTraverse(
            voiceOver: NSWorkspace.shared.isVoiceOverEnabled,
            fullKeyboardAccess: NSApp.isFullKeyboardAccessEnabled)
    }

    private let store: AppStore
    private let onClose: () -> Void
    private let onOpenSettings: () -> Void
    private var monitor: Any?

    init(store: AppStore, onClose: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        self.onOpenSettings = onOpenSettings
    }

    // MARK: - Derived state

    /// Supporter perk: tinted selection chip (cosmetic only, like every gate).
    var tintedChips: Bool { store.allows(.customTint) && store.settings.tintedChips }
    var prompts: [PromptTemplate] { store.prompts }
    var allRepos: [Repo] { store.repos }

    var selectedPrompt: PromptTemplate? { store.prompts.first { $0.id == selectedPromptID } }

    func monogram(for agent: Agent?) -> String { store.monogram(for: agent) }

    var filtered: [Repo] { ranked().repos }

    /// How the query found this repo, for the token's match ink. Nil when
    /// the field is empty or the repo isn't in the current results.
    func match(for repo: Repo) -> FuzzyMatch.Match? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ranked().matches[repo.id]
    }

    /// `filtered` is read many times per render (selection, agent, mode,
    /// every token), so the ranking is kept until the query or the store's
    /// `searchRevision` changes (every repo mutation bumps it, so it never
    /// goes stale under ⌘1–9 or the selection). Time passing alone doesn't
    /// reorder repos in practice, decay scales every score by the same factor. Not
    /// @Published: it is derived state, never a cause.
    private var rankCache: (query: String, revision: Int, repos: [Repo], matches: [UUID: FuzzyMatch.Match])?

    private func ranked() -> (repos: [Repo], matches: [UUID: FuzzyMatch.Match]) {
        let revision = store.searchRevision
        if let c = rankCache, c.query == query, c.revision == revision { return (c.repos, c.matches) }
        let results = RepoSearch.rank(query, in: store.orderedRepos())
        let repos = results.map(\.repo)
        var matches: [UUID: FuzzyMatch.Match] = [:]
        for r in results { matches[r.repo.id] = r.match }
        rankCache = (query, revision, repos, matches)
        return (repos, matches)
    }

    var selectedRepo: Repo? {
        let list = filtered
        guard !list.isEmpty else { return nil }
        return list[min(selection, list.count - 1)]
    }

    func activeAgent(for repo: Repo) -> Agent? {
        // The ⇥ override only applies to the row you're on — other rows keep their
        // own default agent.
        let override = repo.id == selectedRepo?.id ? agentOverrideID : nil
        return LaunchDefaults.agent(for: repo, agents: store.agents, overrideID: override)
    }

    var isPendingDangerous: Bool { pendingDangerous != nil }

    /// True only when the session can actually be reconstructed — the ⌘0
    /// hint must never advertise a resume that fails on arrival.
    var hasLastSession: Bool { LaunchService.canResumeLast(store: store) }

    // MARK: - Git context (branch + dirty) for the selected row

    struct GitContext: Equatable { var branch: String?; var dirty: Bool? }

    /// Keyed by repo path, filled asynchronously, cleared on each summon so a
    /// stale answer never outlives the working tree it described.
    @Published private(set) var gitContexts: [String: GitContext] = [:]
    private var gitInFlight: Set<String> = []

    func gitContext(for repo: Repo) -> GitContext? { gitContexts[repo.path] }

    /// A plain GCD queue, deliberately not the Swift cooperative pool: the
    /// dirty check blocks on subprocess I/O, and a repo on a stalled mount
    /// must be able to hang a disposable GCD thread, never a pool thread.
    private static let gitQueue = DispatchQueue(
        label: "com.sorkila.tintpad.gitstatus", qos: .userInitiated, attributes: .concurrent)

    /// Kick off a fetch for the selected repo. Runs on `gitQueue` and lands
    /// back on the main actor — the pill renders from cache instantly and
    /// fills in when the answer arrives.
    func refreshGitContext() {
        guard let path = selectedRepo?.path else { return }
        guard gitContexts[path] == nil, !gitInFlight.contains(path) else { return }
        gitInFlight.insert(path)
        PaletteModel.gitQueue.async { [weak self] in
            let ctx = GitContext(branch: GitInfo.currentBranch(at: path),
                                 dirty: GitStatus.isDirty(at: path))
            Task { @MainActor in self?.storeGitContext(ctx, for: path) }
        }
    }

    private func storeGitContext(_ ctx: GitContext, for path: String) {
        gitInFlight.remove(path)
        gitContexts[path] = ctx
    }

    var pendingDangerousDescription: String? {
        guard let p = pendingDangerous else { return nil }
        return "\(p.mode.name) in \(p.repo.name) with \(p.agent.name)"
    }

    // MARK: - Key monitor

    /// Install a local key monitor scoped to the command panel. Returns the
    /// event (passes through) for normal typing, nil to swallow handled keys.
    /// `flagsChanged` only updates the held modifiers and is always passed on,
    /// never swallowed: AppKit and the field editor track modifiers from it too.
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                if event.window is CommandPanel || NSApp.keyWindow is CommandPanel {
                    noteModifiers(event.modifierFlags)
                }
                return event
            }
            guard let window = event.window, window is CommandPanel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// ⌥, ⇧ and ⌃ preview at once (⌥ must be red before Return lands). ⌘
    /// waits a beat, so a chord like ⌘R doesn't flash a chip.
    private func noteModifiers(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection([.option, .shift, .control, .command])
        if heldModifiers != held { heldModifiers = held }
        let down = held.contains(.command)
        guard down != commandDown else { return }
        // Every ⌘ transition moves the generation, so a timer armed by an
        // earlier press finds it changed and stands down.
        commandDown = down
        commandGeneration += 1
        guard down else {
            if commandHeld { setCommandHeld(false) }
            return
        }
        let gen = commandGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandHoldDelay) { [weak self] in
            // Never reveal onto a launch or an exit (the ⌘1 chord's own ⌘).
            guard let self, commandGeneration == gen, !isDismissing, !launchInFlight else { return }
            heldEditorName = EditorRegistry.preferred(settings: store.settings)?.name
            setCommandHeld(true)
        }
    }

    /// The ⌘ reveal (digits on tokens, keys on chips) crossfades in and out
    /// in 0.12s, instant under Reduce Motion. Only the hold animates this
    /// way, a summon's reset clears it unanimated.
    private func setCommandHeld(_ held: Bool) {
        if reduceMotionActive() {
            commandHeld = held
        } else {
            withAnimation(.easeInOut(duration: 0.12)) { commandHeld = held }
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Called when the panel is shown to reset transient per-summon state.
    func reset() {
        cancelDismissal()
        // A handoff still running from the last summon finishes on its own
        // (its answer checks the generation and never lands in this drop), so
        // nothing is in flight here and a stuck flag must never swallow every
        // Return.
        summonGeneration += 1
        launchInFlight = false
        launchBeats.cancel()
        failedLaunch = nil
        launchNote = nil
        launchRepo = nil
        stripScrolled = false
        // Seed from the physical keys: the hotkey chord (⌥⌘Space by default)
        // is still down on every summon, and no flagsChanged arrives until it
        // moves. ⌘ is recorded as down but never arms the hold, so the
        // hotkey's own ⌘ cannot flash OPEN IN. Any timer from the last summon
        // stands down, and the next ⌘ transition bumps the generation again.
        heldModifiers = NSEvent.modifierFlags.intersection([.option, .shift, .control, .command])
        commandHeld = false
        commandDown = heldModifiers.contains(.command)
        commandGeneration += 1
        status = nil
        pendingDangerous = nil
        pendingPermission = nil
        // Must stay ahead of `query = ""` below: its didSet runs
        // clearTransient, which forgets the held retry whenever an offer is
        // still showing.
        resumeOffer = nil
        agentOverrideID = nil
        modeOverrideID = nil
        worktreeRepo = nil
        promptRepo = nil
        selectedPromptID = nil
        // The working tree may have changed since the last summon — refetch.
        // In-flight markers go too: a fetch that never returned must not lock
        // its repo out of git context for the rest of the app's life.
        gitContexts.removeAll()
        gitInFlight.removeAll()
        query = ""   // didSet refreshes git context for the new selection
        // Off-main: a summon must render instantly even if the scan roots
        // live on a slow volume — the strip fills in as repos arrive.
        if store.repos.isEmpty { store.runAutoDiscoveryInBackground() }
        // A launch that failed after its drop had gone says so now, last, so
        // nothing above clears it. Return retries it, Esc closes.
        if let failure = deferredFailure {
            deferredFailure = nil
            if LaunchAnswerPolicy.surfacesDeferred(age: Date().timeIntervalSince(failure.at)) {
                report(failure.error, context: failure.context)
            }
        }
        offerPendingRetry()
    }

    /// A launch held since Return opened System Settings: offer it back if
    /// the grant can have landed. Only Accessibility is checked, and only
    /// here, on summon. Nothing fires without a Return. A newer failure the
    /// summon just reported takes the line, the retry keeps holding.
    private func offerPendingRetry() {
        guard let retry = pendingRetry else { return }
        let resolved = resolve(retry.launch)
        let trusted: Bool? = retry.pane == .accessibility ? AXIsProcessTrusted() : nil
        switch PermissionEscalation.resume(pane: retry.pane, trusted: trusted,
                                           age: Date().timeIntervalSince(retry.armedAt),
                                           subjectPresent: resolved != nil) {
        case .drop:
            pendingRetry = nil
        case .hold:
            break
        case .offer:
            guard status == nil, pendingPermission == nil, let (repo, agent, _) = resolved else { return }
            // The strip behind the offer lands on the repo, so Esc leaves the
            // user where the launch was. Named as the store has them now.
            select(filtered.firstIndex { $0.id == repo.id } ?? 0, animated: false)
            launchRepo = repo
            resumeOffer = PermissionEscalation.grantedLine(
                pane: retry.pane, repo: repo.name, agent: agent.name)
        }
    }

    /// A held launch's repo, agent and mode as the store has them now, or nil
    /// when any of them is gone.
    private func resolve(_ held: HeldLaunch) -> (Repo, Agent, RunMode)? {
        guard let repo = store.repos.first(where: { $0.id == held.repoID }),
              let agent = store.agent(held.agentID),
              let mode = agent.modes.first(where: { $0.id == held.modeID }) else { return nil }
        return (repo, agent, mode)
    }

    func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        let chars = event.charactersIgnoringModifiers?.lowercased()
        switch event.keyCode {
        case 125: move(1); return true          // ↓
        case 126: move(-1); return true         // ↑
        // ←/→ drive the strip only while the field is empty — with text in the
        // field they must keep moving the caret.
        case 124 where query.isEmpty && worktreeRepo == nil && promptRepo == nil:
            move(1); return true                // →
        case 123 where query.isEmpty && worktreeRepo == nil && promptRepo == nil:
            move(-1); return true               // ←
        case 36, 76: handleReturn(modifiers: mods); return true  // ↩ / ⌅
        case 53: handleEscape(); return true    // esc
        case 48:                                // ⇥ agent / ⇧⇥ mode
            // Leave Tab to focus traversal when assistive tech needs it (a11y #1).
            if tabTraverses() { return false }
            mods.contains(.shift) ? cycleMode() : cycleAgent()
            return true
        default: break
        }
        // ⌘1–⌘9 jump straight to a numbered row and launch it. The numbers shown
        // in the list are this shortcut, not decoration. ⌘0 replays the last
        // session exactly — the zeroth row, in a sense: the one you just left.
        if mods.contains(.command), let c = chars, c.count == 1, let digit = Int(c) {
            if digit == 0 { return resumeLastSession() }
            if (1...9).contains(digit) { return launchByIndex(digit - 1) }
        }
        // Bulletproof type-to-search: if the field is genuinely first
        // responder (an active field editor), let the event through to it.
        // Otherwise route characters straight into the query — typing must
        // search no matter where AppKit thinks focus is.
        if !(event.window?.firstResponder is NSTextView),
           !mods.contains(.command), !mods.contains(.control), !mods.contains(.option) {
            if event.keyCode == 51 {   // delete
                if !query.isEmpty { query.removeLast() }
                return true
            }
            if let ch = event.characters, !ch.isEmpty,
               ch.rangeOfCharacter(from: .controlCharacters) == nil {
                query += ch
                return true
            }
        }
        if mods.contains(.command), chars == "," { openSettings(); return true }
        if mods.contains(.command), chars == "r" {
            let n = store.runAutoDiscovery()
            // The scan result replaces a resume offer, which declines it.
            if resumeOffer != nil { clearTransient() }
            launchRepo = nil
            status = "Scanned, \(n) new repo\(n == 1 ? "" : "s")"
            return true
        }
        if mods.contains(.command), chars == "p" { cyclePrompt(); return true }
        if mods.contains(.command), chars == "l" { enterPromptMode(); return true }
        if mods.contains(.control), chars == "w" { enterWorktreeMode(); return true }
        return false
    }

    /// ⌘<n>: select row n and launch it with its own default agent + mode.
    /// Only meaningful in the plain repo list — worktree and prompt modes are
    /// typing into the field, where ⌘<n> should stay inert.
    private func launchByIndex(_ index: Int) -> Bool {
        guard worktreeRepo == nil, promptRepo == nil else { return false }
        guard admitLaunchGesture() else { return true }
        // ⌘n while a dangerous confirm (or permission prompt) is pending
        // cancels it — the jump must never fire a YOLO that was armed for a
        // different repo, nor bounce the user into System Settings.
        if pendingDangerous != nil || pendingPermission != nil || resumeOffer != nil { clearTransient() }
        guard filtered.indices.contains(index) else { return false }
        select(index)
        agentOverrideID = nil
        modeOverrideID = nil
        handleReturn(modifiers: [])
        return true
    }

    /// ⌘0 — relaunch the most recent session exactly (repo, agent, mode,
    /// prompt), same semantics as the global resume hotkey. Inert while the
    /// field is capturing a worktree branch or a prompt, like ⌘1–⌘9. A pending
    /// confirm is cancelled, never fired, and a dangerous last session arms
    /// the same confirm banner as any other dangerous launch.
    @discardableResult
    func resumeLastSession() -> Bool {
        guard worktreeRepo == nil, promptRepo == nil else { return false }
        guard admitLaunchGesture() else { return true }
        clearTransient()
        guard let session = store.lastSession else { status = "No session to resume yet"; return true }
        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            let canResume = LaunchService.canResumeLast(store: store)
            let opening = canResume ? LaunchService.terminalName(store: store) : nil
            let repo = canResume ? store.repos.first { $0.id == session.repoID } : nil
            // A retry replays "the last session" as it is at retry time, the
            // same as pressing ⌘0 again.
            let retry: (() -> Void)? = canResume ? { [weak self] in _ = self?.resumeLastSession() } : nil
            // Held after a permission failure as this session's concrete
            // launch, so the offer runs what it names even if another session
            // has become the last one since.
            let held = canResume ? HeldLaunch(repoID: session.repoID, agentID: session.agentID,
                                              modeID: session.modeID, prompt: session.prompt,
                                              worktreePath: nil) : nil
            beginLaunch(opening: opening, repo: repo, held: held, retry: retry) { [store] completion in
                LaunchService.resumeLast(store: store, completion: completion)
            }
        }
        if let agent = store.agent(session.agentID),
           let mode = agent.modes.first(where: { $0.id == session.modeID }),
           let repo = store.repos.first(where: { $0.id == session.repoID }) {
            fireOrConfirm(repo: repo, agent: agent, mode: mode, fire)
        } else {
            fire()
        }
        return true
    }

    // MARK: - Navigation

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        select((selection + delta + count) % count)
        // Agent/mode overrides belong to the row you were on — reset on move.
        agentOverrideID = nil
        modeOverrideID = nil
        clearTransient()
        refreshGitContext()
    }

    func cyclePrompt() {
        guard !store.prompts.isEmpty else {
            launchRepo = nil
            status = "No saved prompts, add some in Settings"
            return
        }
        let ids: [UUID?] = [nil] + store.prompts.map { Optional($0.id) }
        let idx = ids.firstIndex(of: selectedPromptID) ?? 0
        selectedPromptID = ids[(idx + 1) % ids.count]
        status = nil
    }

    func cycleAgent() {
        guard !store.agents.isEmpty, let repo = selectedRepo,
              let current = activeAgent(for: repo),
              let idx = store.agents.firstIndex(where: { $0.id == current.id }) else { return }
        agentOverrideID = store.agents[(idx + 1) % store.agents.count].id
        modeOverrideID = nil   // modes are agent-specific
        clearTransient()
    }

    /// ⇧⇥ — cycle the run mode for the current agent.
    func cycleMode() {
        guard let repo = selectedRepo, let agent = activeAgent(for: repo), !agent.modes.isEmpty else { return }
        let current = displayMode(agent: agent, repo: repo)
        let idx = agent.modes.firstIndex { $0.id == current.id } ?? 0
        modeOverrideID = agent.modes[(idx + 1) % agent.modes.count].id
        clearTransient()
    }

    func openSettings() {
        // Settings orders the panel out without a dismissal, so disarm here too.
        disarmCommandHold()
        onOpenSettings()
    }

    /// A leaving drop takes no ⌘ reveal with it. ⌘1 or ⌘, is a chord whose
    /// ⌘ is often still down when the 150ms beat lands, and that timer would
    /// otherwise reveal onto exiting content and leave `commandHeld` true on
    /// the hidden panel. `commandDown` stays as the keys are, like `reset()`.
    private func disarmCommandHold() {
        commandGeneration += 1
        if commandHeld { commandHeld = false }
    }

    func clearTransient() {
        status = nil; pendingDangerous = nil; pendingPermission = nil; launchRepo = nil
        // Moving, typing or cycling away from a resume offer declines it. A
        // retry that is only holding (no offer showing) is left alone.
        if resumeOffer != nil { resumeOffer = nil; pendingRetry = nil }
    }

    /// Routes a launch error: permission failures arm the ⏎-opens-Settings
    /// state, a gone session says so, and everything else is an error line
    /// naming the app and what Return does (it retries).
    private func report(_ error: Error, context: LaunchContext) {
        launchRepo = context.repo
        if case TerminalLaunchError.permissionNeeded(let summary, _, let pane) = error {
            status = nil   // the "Opening …" line has had its turn
            let retry = context.held.map { PendingRetry(launch: $0, pane: pane) }
            pendingPermission = PendingPermission(
                summary: summary, pane: pane,
                failures: max(permissionFailures[pane] ?? 0, 1), retry: retry)
            return
        }
        if error is LaunchService.ResumeError {
            launchRepo = nil
            status = "⚠ \(error)"
            return
        }
        if let failureLine = context.failureLine {
            status = "⚠ " + failureLine(error)
            return
        }
        let line = "⚠ " + LaunchStatusCopy.error(terminal: context.target ?? "the terminal", error: error)
        status = line
        if let retry = context.retry { failedLaunch = FailedLaunch(line: line, retry: retry) }
    }

    /// Guarded so a scroll that never crosses the edge doesn't republish, and
    /// the strip doesn't redraw itself on every frame of a drag.
    func setStripScrolled(_ scrolled: Bool) {
        if stripScrolled != scrolled { stripScrolled = scrolled }
    }

    /// Guarded against sub-point jitter, so layout noise never re-hugs.
    func setNaturalContentWidth(_ width: CGFloat) {
        if abs(naturalContentWidth - width) > 0.5 { naturalContentWidth = width }
    }

    /// Move the selection. The one white chip slides to its new token
    /// (`matchedGeometryEffect`), which needs the change to happen inside an
    /// animation transaction at the mutation site, never a stack-wide
    /// `.animation(value: selection)` (see CLAUDE.md, palette keyboard nav).
    func select(_ index: Int, animated: Bool = true) {
        guard selection != index else { return }
        withAnimation(animated && !reduceMotionActive() ? .snappy(duration: 0.24) : nil) {
            selection = index
        }
    }

    /// The repo a middle-region line is about, shown as a white token to its
    /// left so the drop never loses its subject: the confirm's repo, the
    /// capture mode's repo, the last launch's repo, or the selection. A
    /// status or permission line outside a capture mode is about the launch
    /// or about nothing ("Scanned, 3 new repos"), never the selection.
    var subjectRepo: Repo? {
        DropSubject.pick(pending: pendingDangerous?.repo, worktree: worktreeRepo, prompt: promptRepo,
                         statusShown: status != nil || pendingPermission != nil || resumeOffer != nil,
                         launch: launchRepo, selected: selectedRepo)
    }

    /// The mode that a plain ⏎ will use right now (no modifiers) — drives the chip.
    func displayMode(agent: Agent, repo: Repo) -> RunMode {
        // The ⇧⇥ override is scoped to the selected row too.
        let override = repo.id == selectedRepo?.id ? modeOverrideID : nil
        return LaunchDefaults.mode(for: repo, agent: agent, overrideID: override)
    }

    /// The mode ⏎ runs with these modifiers. The rule lives in `ModeResolution`,
    /// shared with the chips' live preview so the two cannot disagree.
    func resolveMode(agent: Agent, repo: Repo, modifiers: NSEvent.ModifierFlags) -> RunMode {
        ModeResolution.mode(for: agent, resting: displayMode(agent: agent, repo: repo),
                            option: modifiers.contains(.option),
                            shift: modifiers.contains(.shift))
    }

    /// The mode the contract states for this repo right now: what ⏎ would
    /// run with the held modifiers. The tile's VoiceOver label speaks it too.
    func previewMode(agent: Agent, repo: Repo) -> RunMode {
        ContractPreview.mode(
            agent: agent, restingMode: displayMode(agent: agent, repo: repo),
            held: ContractPreview.Held(flags: heldModifiers, commandHeldLong: commandHeld))
    }

    /// The contract chips for the selected repo as they read with the
    /// modifiers held right now (see `ContractPreview`), or with `held` when
    /// given. The hug measures with `.none`: a held modifier reshapes the
    /// chips (the strip gives way), never the drop.
    func contractChips(agent: Agent, repo: Repo,
                       held: ContractPreview.Held? = nil) -> [ContractPreview.Chip] {
        ContractPreview.chips(
            agent: agent, restingMode: displayMode(agent: agent, repo: repo),
            prompt: selectedPrompt, editorName: heldEditorName,
            held: held ?? ContractPreview.Held(flags: heldModifiers, commandHeldLong: commandHeld))
    }


    // MARK: - Worktree mode

    func enterWorktreeMode() {
        guard let repo = selectedRepo else { return }
        promptRepo = nil   // the two field-capture modes are mutually exclusive
        worktreeRepo = repo
        query = ""
    }

    func exitWorktreeMode() { worktreeRepo = nil; query = "" }

    func worktreePreviewPath() -> String? {
        guard let repo = worktreeRepo, !query.isEmpty else { return nil }
        return WorktreeService.defaultPath(repoPath: repo.path, branch: query, customRoot: store.settings.worktreeRoot)
    }

    private func createWorktreeAndLaunch() {
        guard let repo = worktreeRepo else { return }
        let branch = query.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { status = "Enter a branch name"; return }
        guard let agent = activeAgent(for: repo) else { return }
        let mode = resolveMode(agent: agent, repo: repo, modifiers: [])
        let promptText = selectedPrompt?.text
        let worktreePath = WorktreeService.defaultPath(
            repoPath: repo.path, branch: branch, customRoot: store.settings.worktreeRoot)
        fireOrConfirm(repo: repo, agent: agent, mode: mode) { [weak self] in
            guard let self else { return }
            // The git work runs off the main actor (a worktree add on a big
            // repo can take a while); the terminal handoff hops back to main.
            launchInFlight = true
            status = "Creating worktree…"
            // A worktree add can take minutes on a stalled mount. If the user
            // has since dismissed and re-summoned, the result belongs to a
            // drop that no longer exists: stand down, never launch into the
            // new one.
            let gen = summonGeneration
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try WorktreeService.create(repoPath: repo.path, branch: branch, at: worktreePath)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // A stale answer leaves the flag alone: `reset()`
                        // already cleared it, and it may belong to a launch
                        // from the newer summon now.
                        guard summonGeneration == gen else { return }
                        // `launch` keeps the flight flag up across the hop,
                        // so there is no gap for a second Return. A retry
                        // relaunches into the worktree, never re-creates it.
                        launch(repo: repo, agent: agent, mode: mode,
                               prompt: promptText, worktreePath: worktreePath)
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        guard let self, summonGeneration == gen else { return }
                        launchInFlight = false
                        status = "⚠ \(error)"
                    }
                }
            }
        }
    }

    // MARK: - Prompt mode

    func enterPromptMode() {
        guard let repo = selectedRepo else { return }
        worktreeRepo = nil   // the two field-capture modes are mutually exclusive
        promptRepo = repo
        query = ""
    }

    func exitPromptMode() { promptRepo = nil; query = "" }

    private func launchWithTypedPrompt() {
        guard let repo = promptRepo, let agent = activeAgent(for: repo) else { return }
        let prompt = query.trimmingCharacters(in: .whitespaces)
        let mode = resolveMode(agent: agent, repo: repo, modifiers: [])
        fireOrConfirm(repo: repo, agent: agent, mode: mode) { [weak self] in
            self?.perform(repo: repo, agent: agent, mode: mode, prompt: prompt.isEmpty ? nil : prompt)
        }
    }

    // MARK: - Actions

    func handleEscape() {
        // clearTransient forgets a showing resume offer along with its retry.
        if pendingDangerous != nil || pendingPermission != nil || resumeOffer != nil {
            clearTransient(); return
        }
        if worktreeRepo != nil { exitWorktreeMode(); return }
        if promptRepo != nil { exitPromptMode(); return }
        requestDismiss(.escape)
    }

    func handleReturn(modifiers mods: NSEvent.ModifierFlags) {
        // First, before any pending state is consumed: a Return queued behind
        // a launch is ignored, a Return on a note closes.
        guard admitLaunchGesture() else { return }
        if let pending = pendingDangerous {
            pendingDangerous = nil
            pending.fire()
            return
        }
        // A launch failed and its line says Return retries: it does, through
        // the danger gate again, since the drop may have been away since.
        if let failed = failedLaunch, status == failed.line {
            failedLaunch = nil
            failed.retry()
            return
        }
        // A permission failure is showing: ⏎ opens the pane that fixes it.
        // System Settings takes focus, which hides the palette on its own.
        if let permission = pendingPermission {
            pendingPermission = nil
            // Held for the summon after the grant, which offers it back.
            if let retry = permission.retry {
                pendingRetry = retry
                pendingRetry?.armedAt = Date()
            }
            permission.pane.open()
            // Leaving for System Settings, which takes focus anyway.
            requestDismiss(.focusLoss)
            return
        }
        // A summon offered the launch held since System Settings: Return
        // runs it, through the danger gate, if its repo and agent survive.
        if resumeOffer != nil, let retry = pendingRetry {
            resumeOffer = nil
            pendingRetry = nil
            launchRepo = nil
            guard let (repo, agent, mode) = resolve(retry.launch) else { return }
            let held = retry.launch
            fireOrConfirm(repo: repo, agent: agent, mode: mode) { [weak self] in
                self?.launch(repo: repo, agent: agent, mode: mode,
                             prompt: held.prompt, worktreePath: held.worktreePath)
            }
            return
        }
        if promptRepo != nil { launchWithTypedPrompt(); return }
        if worktreeRepo != nil { createWorktreeAndLaunch(); return }
        guard let repo = selectedRepo else { return }
        if mods.contains(.command) { openInEditor(repo: repo); return }
        guard let agent = activeAgent(for: repo) else { return }
        let mode = resolveMode(agent: agent, repo: repo, modifiers: mods)

        if mods.contains(.control) {
            // Headless dispatch is *less* visible than a terminal launch, so it
            // must never be easier to reach a permission-skipping run with.
            fireOrConfirm(repo: repo, agent: agent, mode: mode) { [weak self] in
                self?.dispatch(repo: repo, agent: agent, mode: mode)
            }
            return
        }
        fireOrConfirm(repo: repo, agent: agent, mode: mode) { [weak self] in
            self?.perform(repo: repo, agent: agent, mode: mode)
        }
    }

    /// The one danger gate: every path that would run a permission-skipping
    /// mode arms the confirm banner (when the setting is on) instead of firing.
    /// Launch, dispatch, prompt, worktree, and resume all pass through here —
    /// no flow is quieter than the plain ⏎.
    private func fireOrConfirm(repo: Repo, agent: Agent, mode: RunMode,
                               _ fire: @escaping () -> Void) {
        if mode.isDangerous && store.settings.confirmDangerousModes {
            pendingDangerous = PendingLaunch(repo: repo, agent: agent, mode: mode, fire: fire)
            return
        }
        fire()
    }

    /// Click-to-launch (uses currently held modifiers). Clicking any tile
    /// while a dangerous confirm is pending cancels the pending launch — a
    /// click must never fire a YOLO that was armed for a different repo.
    func activate(at index: Int) {
        guard admitLaunchGesture() else { return }
        if pendingDangerous != nil || pendingPermission != nil || resumeOffer != nil { clearTransient() }
        guard filtered.indices.contains(index) else { return }
        select(index)
        handleReturn(modifiers: NSEvent.modifierFlags)
    }

    private func dispatch(repo: Repo, agent: Agent, mode: RunMode) {
        launchRepo = repo
        do {
            _ = try DispatchService.shared.dispatch(
                repo: repo, agent: agent, mode: mode, prompt: selectedPrompt?.text, store: store)
            closeAfterLaunch()
        } catch { status = "⚠ Dispatch: \(error)" }
    }

    private func openInEditor(repo: Repo) {
        let editor = EditorRegistry.preferred(settings: store.settings)
        beginLaunch(opening: editor?.name, repo: repo, retry: nil,
                    failureLine: { _ in "No editor detected, set one in Settings" }) { [store] completion in
            LaunchService.openInEditor(repo: repo, store: store, completion: completion)
        }
    }

    private func perform(repo: Repo, agent: Agent, mode: RunMode, prompt: String? = nil) {
        // Resolved now: what launches (and what a retry relaunches) is the
        // prompt showing at Return, not whatever is cycled to later.
        launch(repo: repo, agent: agent, mode: mode, prompt: prompt ?? selectedPrompt?.text)
    }

    /// The terminal launch itself, with everything already resolved, so a
    /// retry from the error line runs exactly the same launch.
    private func launch(repo: Repo, agent: Agent, mode: RunMode,
                        prompt: String?, worktreePath: String? = nil) {
        let retry: () -> Void = { [weak self] in
            self?.fireOrConfirm(repo: repo, agent: agent, mode: mode) { [weak self] in
                self?.launch(repo: repo, agent: agent, mode: mode,
                             prompt: prompt, worktreePath: worktreePath)
            }
        }
        let held = HeldLaunch(repoID: repo.id, agentID: agent.id, modeID: mode.id,
                              prompt: prompt, worktreePath: worktreePath)
        beginLaunch(opening: LaunchService.terminalName(store: store), repo: repo, held: held,
                    retry: retry) { [store] completion in
            LaunchService.launchAgent(repo: repo, agent: agent, mode: mode, prompt: prompt,
                                      store: store, worktreePath: worktreePath,
                                      completion: completion)
        }
    }
}

// MARK: - Notch anchor

/// Where the drop hangs from on the summon screen. Computed by the
/// controller on every show — the screen (and whether it has a notch) can
/// change between summons.
struct NotchGeometry: Equatable {
    /// True when the summon screen has a camera housing to hang from.
    var hasNotch: Bool
    /// The housing's depth — the transparent gap above the string when the
    /// window is flush with the screen's top edge. Zero when floating.
    var restHeight: CGFloat
    /// The housing's width: the gap between the menu bar's two auxiliary
    /// areas either side of the camera. Zero when floating (or when AppKit
    /// reports no auxiliary areas).
    var housingWidth: CGFloat = 0
    /// The widest the capsule may settle on this screen.
    var maxWidth: CGFloat

    static let fallback = NotchGeometry(hasNotch: false, restHeight: 0, housingWidth: 0, maxWidth: 640)
}

/// Bridges the controller's per-summon geometry into the SwiftUI drop.
@MainActor
final class NotchAnchor: ObservableObject {
    @Published var geometry: NotchGeometry = .fallback
}

// MARK: - View

/// The palette: a black drop that forms under the notch.
///
/// Summon, and a bead of black swells at the camera housing's lip, then
/// expands in place into a capsule that hangs 8pt below it, and the words
/// follow the shape in. The drop holds the repos as words: stark black and
/// white, nothing else. Launch or Esc, and the capsule shrinks back into the
/// bead and is absorbed by the housing. A click elsewhere just fades it.
///
/// Rules the layout obeys:
///
/// 1. **Nothing behind the camera.** The drop floats strictly below the
///    housing line; the housing keeps every one of its pixels.
/// 2. **Black and white, fully mute.** The capsule is pure black in every
///    theme, the ink is white and gray, the caret included. At rest the
///    drop speaks one object language: every element is a capsule of one
///    height. White chip = where you are (one chip, it slides), gray chips = the contract (what
///    ⏎ does — always present, a contract that hides reads as a bug), red
///    chip = it skips permissions, the only color the drop ever allows.
///    The query materializes at the left as you type.
/// 3. **The blend is the brand.** Bead (swells at the lip) → spread (expands
///    in place, growing only downward and sideways) → content (the search
///    and strip, then the contract, rising 4pt out of a 4pt blur). One
///    generation-counted `StepSequencer` timeline plays the `DropTimeline`
///    beats, so a re-summon cancels every stale beat and springs retarget
///    mid-flight. Reduce Motion replaces the film with a crossfade.
/// 4. **Keyboard first, mouse honest.** ←/→ (or ↑/↓) move through tokens
///    while the field is empty, ⏎ launches, ⌘1–⌘9 jump, ⌘0 resumes, ⇥/⇧⇥
///    cycle agent/mode — the contract's words are the clickable counterparts.
struct PaletteView: View {
    @ObservedObject private var model: PaletteModel
    @ObservedObject private var anchor: NotchAnchor
    let onResize: (CGFloat) -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: DropPhase = .hidden
    /// The search region and token strip.
    @State private var contentA = false
    /// The contract.
    @State private var contentB = false
    /// The bead's swell, anchored at its top edge.
    @State private var beadScale: CGFloat = 0
    /// The smallest scale the droplet is ever drawn at (see `droplet`).
    static let minScale: CGFloat = 0.001
    /// Exit into the housing: shrunk toward the top edge and gone.
    @State private var absorbed = false
    /// Exit by fading (focus loss, Reduce Motion), and the RM arrival's start.
    @State private var faded = false
    /// Plays the arrival and the exits. One per view, so a re-summon cancels.
    @State private var sequencer = StepSequencer()
    /// Content is leaving: it fades and blurs but does not sink (the 4pt
    /// rise belongs to arrival only).
    @State private var exiting = false
    /// The capsule's hugged width (see `rehug`). Seeded on every summon.
    @State private var hugWidth: CGFloat = 0
    /// The one white chip that slides between tokens.
    @Namespace private var selectionNS
    @Environment(\.displayScale) private var displayScale

    enum DropPhase { case hidden, bead, spread }
    /// Tokens keep one padding whether selected or not, so an arrow press
    /// moves the chip and never reflows the row.
    private static let tokenPadding: CGFloat = 9
    private static let tokenSpacing: CGFloat = 2
    /// The strip's right-edge fade, also reserved in the hugged width so a
    /// row that fits never fades its last token.
    private static let stripFade: CGFloat = 16
    /// Separation between the middle region and the contract.
    private static let contractGap: CGFloat = 32
    /// The token strip's viewport, so its content can measure its own offset.
    private static let stripSpace = "tokenStrip"

    /// Where a token should land when the strip scrolls to it.
    ///
    /// The first token is pinned to the **leading** edge, never centered. The
    /// row is left-anchored by design, and centering index 0 asks the scroll
    /// view to scroll past its own start: the target resolves against the
    /// viewport, and on arrival the viewport is still moving (tokens stagger
    /// in, the query field animates its width), so it settles on a stray
    /// offset of a few tens of points that nothing afterwards corrects. The
    /// leading token then sits shorn flat against the hard clip at x=0, which
    /// reads as a rendering fault. Leading anchoring needs no viewport
    /// measurement at all, so a half-built layout cannot mislead it.
    static func anchor(for index: Int) -> UnitPoint { index == 0 ? .leading : .center }

    // Dynamic Type. The drop's geometry (`DropGeometry`) scales with
    // `typeScale`, the type with its own metrics, so they grow together.
    // Capped at xxLarge — one line cannot absorb accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var fieldSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var metaSize: CGFloat = 11
    /// The ⌘ reveal's superscript digit, the chips' eyebrow size.
    @ScaledMetric(relativeTo: .body) private var digitSize: CGFloat = 8.5

    /// Every size the drop lays out with, for this summon's screen.
    private var drop: DropGeometry { DropGeometry.resolve(anchor.geometry, typeScale: typeScale) }
    private var dropH: CGFloat { drop.dropHeight }
    private var chipH: CGFloat { drop.chipHeight }

    /// The model is owned by the controller (created + monitored at launch) so
    /// the very first summon is already warm.
    init(model: PaletteModel, anchor: NotchAnchor,
         onResize: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.anchor = anchor
        self.onResize = onResize
    }

    /// Which content the middle region shows — drives the crossfade.
    private var middleToken: Int {
        if model.isPendingDangerous { return 1 }
        if model.pendingPermission != nil { return 5 }
        if model.resumeOffer != nil { return 6 }
        if model.status != nil { return 2 }
        if model.worktreeRepo != nil { return 3 }
        if model.promptRepo != nil { return 4 }
        return 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // The housing's own depth — the window is flush with the screen
            // top on notched Macs, and the capsule hangs a gap below where
            // the housing ends (or below the menu bar on a plain display).
            // The gap opens with the spread: the bead forms touching the
            // housing's lower edge and the capsule hangs 8pt below it.
            Spacer().frame(height: anchor.geometry.restHeight + (phase == .spread ? DropGeometry.gap : 0))
            droplet
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The hug: a hidden copy of the content, at its natural width, says
        // how wide the capsule wants to be. It never carries the selection's
        // matchedGeometryEffect (two sources would break the slide).
        .background(alignment: .topLeading) { measuringContent }
        .onPreferenceChange(ContentWidthKey.self) { [model] width in
            // @Sendable callback, hop to the actor that owns the state.
            Task { @MainActor in model.setNaturalContentWidth(width) }
        }
        .onChange(of: model.naturalContentWidth) { _, _ in rehug(animated: true) }
        // An emptied field releases the ratchet even when the content's
        // natural width happens not to change.
        .onChange(of: model.query.isEmpty) { _, _ in rehug(animated: true) }
        .onChange(of: model.launchInFlight) { _, _ in rehug(animated: true) }
        .onChange(of: middleToken) { _, _ in rehug(animated: true) }
        .onChange(of: drop) { _, _ in rehug(animated: false) }
        // Nothing behind the camera, structurally: whatever a spring's
        // overshoot or a shadow's blur does, no pixel above the housing's
        // lower edge is drawn. (The pill's rest height is 0, so it clips
        // nothing there.)
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: anchor.geometry.restHeight)
                Color.black
            }
        }
        // The drop is a black world regardless of system theme — fix the
        // hierarchy styles to dark so .secondary/.tertiary read on black.
        // (Dynamic Type is clamped at the hosting root, see CommandPanel, so
        // the geometry's own `typeScale` metric is clamped too.)
        .environment(\.colorScheme, .dark)
        .onAppear { model.startMonitoring(); model.reset(); searchFocused = true; animateIn(); pushHeight() }
        // Typing always lands in the field — no one should ever have to click
        // it first. Exception: when VoiceOver/Full Keyboard Access owns focus
        // traversal, forcing it back would trap the user (a11y #1).
        .onChange(of: searchFocused) { _, focused in
            if !focused && !model.tabTraverses() {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
        .onChange(of: model.status) { _, s in
            if let s { AccessibilityNotification.Announcement(s).post() }
        }
        .onChange(of: model.isPendingDangerous) { _, pending in
            if pending, let d = model.pendingDangerousDescription {
                AccessibilityNotification.Announcement(
                    "Confirm: \(d). Press return again to launch, or escape to cancel."
                ).post()
            }
        }
        .onChange(of: model.pendingPermission?.announcement) { _, announcement in
            if let announcement { AccessibilityNotification.Announcement(announcement).post() }
        }
        .onChange(of: model.resumeOffer) { _, offer in
            if let offer {
                AccessibilityNotification.Announcement("\(offer), or press escape to cancel.").post()
            }
        }
        // The panel is being dismissed and is already transparent: put the
        // drop back at rest instantly, so no frame the window server keeps
        // can hold a capsule or its shadow.
        .onChange(of: model.dismissGeneration) { _, _ in
            sequencer.cancel()
            snap { rest() }
        }
        // An exit was requested: play it, then hand over to the panel.
        .onChange(of: model.dismissal) { _, reason in
            guard let reason else { return }
            play(DropTimeline.exit(reason, reduceMotion: reduceMotion), reason: reason)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tintpadPanelDidShow)) { _ in
            model.reset()
            searchFocused = true
            animateIn()
            pushHeight()
        }
    }

    // MARK: - The droplet

    private var droplet: some View {
        let spread = phase == .spread
        let bead = DropGeometry.beadSize
        let width = capsuleWidth
        return ZStack {
            Capsule(style: .continuous).fill(.black)
            // Laid out at the settled (hugged) size whatever the capsule's
            // size, so the words never reflow while the shape grows around
            // them. The strip's viewport follows the hug rather than staying
            // at maxWidth: a wider viewport would be centre-clipped by a
            // narrower capsule and lose its leading tokens. It is still
            // static through arrival, because `rehug` only animates once the
            // content has arrived.
            content
                .frame(width: width, height: dropH)
        }
        .frame(width: spread ? width : bead, height: spread ? dropH : bead)
        .clipShape(Capsule(style: .continuous))
        // The key line: one device pixel of light on the rim, so the black
        // capsule holds its edge against a black housing or a dark wall.
        .overlay(Capsule(style: .continuous)
            .strokeBorder(Color.white.opacity(spread ? 0.14 : 0), lineWidth: 1 / max(displayScale, 1)))
        // Every scale anchors at the top edge, so growth and overshoot only
        // ever go down, never up behind the camera.
        //
        // Never scale to exactly 0: the content hosts an AppKit scroll view,
        // and attaching it under a singular transform trips an AppKit
        // assertion (NSCGSizeApplyInverseAffineTransform) and aborts the app
        // on summon. A thousandth of a point is invisible and invertible.
        .scaleEffect(max(beadScale, Self.minScale), anchor: .top)
        .scaleEffect(absorbed ? 0.4 : 1, anchor: .top)
        .opacity(phase == .hidden || absorbed || faded ? 0 : 1)
        // A contact shadow, close and light, and only once spread: a bead
        // casting a grounded shadow reads as two objects.
        .shadow(color: .black.opacity(spread ? 0.22 : 0), radius: 8, y: 2)
    }

    private var content: some View {
        // Spacing is owned by the regions (the field pads itself only while
        // visible; the contract carries its own separation) so the token row
        // starts hard at the drop's left padding — an honest rag, no drift.
        HStack(spacing: 0) {
            searchRegion
                .reveal(contentA, rise: !exiting)
            middleRegion()
                .frame(maxWidth: .infinity, alignment: .leading)
                .reveal(contentA, rise: !exiting)
                .transition(.opacity)
            contractRegion()
                .layoutPriority(1)
                .padding(.leading, Self.contractGap)   // separation is space, not a divider
                .reveal(contentB, rise: !exiting)
        }
        // The middle-region swap is a crossfade, never a hard cut.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: middleToken)
        // Optical law: the first chip's margin reads equal to the vertical
        // inset. The scroll clip's 3pt protection already supplies the
        // round-end breath — adding more made the left visibly heavier
        // than the top and bottom.
        .padding(.horizontal, drop.chipInsetResolved)
    }

    // MARK: - Search region

    /// Fully mute: at rest the field is invisible (a hairline that still
    /// holds keyboard focus). It materializes at the left as you type; in
    /// worktree/prompt modes it names the state and widens — it is
    /// capturing, not filtering. The caret is white: the drop is monochrome
    /// down to the last pixel.
    private var searchRegion: some View {
        let resting = searchResting
        return HStack(spacing: 8) {
            if !promptPrefix.isEmpty {
                Text(promptPrefix)
                    .font(.system(size: metaSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            TextField("", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: fieldSize))
                .foregroundStyle(.primary)
                .focused($searchFocused)
                .tint(model.isPendingDangerous ? dangerTint : .white)
                .accessibilityLabel(fieldAccessibilityLabel)
            if !model.query.isEmpty, model.worktreeRepo == nil, model.promptRepo == nil {
                // Shown only while filtering — "11 of 11" is not information.
                Text("\(model.filtered.count)")
                    .font(.system(size: metaSize))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(width: searchRegionWidth, alignment: .leading)
        .padding(.trailing, searchRegionTrailing)
        .opacity(resting ? 0 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                   value: resting)
    }

    private var capturing: Bool { model.worktreeRepo != nil || model.promptRepo != nil }
    private var searchResting: Bool { model.query.isEmpty && !capturing }
    private var searchRegionWidth: CGFloat { capturing ? 280 : (searchResting ? 0 : 150) }
    private var searchRegionTrailing: CGFloat { searchResting ? 0 : 12 }

    private var promptPrefix: String {
        if model.worktreeRepo != nil { return "Worktree" }
        if model.promptRepo != nil { return "Prompt" }
        return ""
    }

    private var fieldAccessibilityLabel: String {
        if let wt = model.worktreeRepo { return "Branch name for \(wt.name)" }
        if let pr = model.promptRepo { return "Prompt for \(pr.name)" }
        return "Search repositories"
    }

    // MARK: - Middle region

    /// The drop becomes the question: confirm, status, worktree, and prompt
    /// all speak here, in place of the tokens. One storey, always, and never
    /// without its subject: the repo the line is about stays on the left as
    /// a white token. `measuring` builds the hidden copy the hug reads.
    @ViewBuilder private func middleRegion(measuring: Bool = false) -> some View {
        if middleToken == 0 {
            if measuring { stripMeasure } else { tokenStrip }
        } else {
            HStack(spacing: 8) {
                if let repo = model.subjectRepo {
                    token(repo, index: model.selection, selected: true,
                          role: measuring ? .measuring : .subject)
                        .fixedSize()
                        .opacity(model.launchInFlight ? 0.7 : 1)
                        // The line names what matters, the token is its picture.
                        .accessibilityHidden(true)
                }
                middleLine
            }
        }
    }

    @ViewBuilder private var middleLine: some View {
        if model.isPendingDangerous {
            middleLine("\(model.pendingDangerousDescription ?? ""), Return confirms, Esc cancels",
                       color: dangerTint)
        } else if let permission = model.pendingPermission {
            middleLine(permission.line, color: dangerTint)
        } else if let offer = model.resumeOffer {
            // White: the grant is done, the launch waits on Return.
            middleLine(offer, color: Color(white: 0.9))
        } else if let status = model.status {
            // Gray means waiting ("Opening …"), red means failure, white
            // means done (a launch note).
            let isError = status.hasPrefix("⚠")
            middleLine(isError ? String(status.dropFirst(2)) : status,
                       color: isError ? dangerTint : model.noteShown ? Color(white: 0.9) : nil)
        } else if model.worktreeRepo != nil {
            middleLine(worktreeExplainer)
        } else if model.promptRepo != nil {
            middleLine("Handed to \(model.promptRepo.flatMap { model.activeAgent(for: $0) }?.name ?? "the agent") as its first message, Return launches, Esc goes back")
        }
    }

    private var worktreeExplainer: String {
        if let path = model.worktreePreviewPath() {
            return "New worktree at \(displayPath(path)), Return creates and launches"
        }
        return "An isolated checkout on a new branch, Return creates and launches"
    }

    private func middleLine(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: fieldSize))
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// The token strip — ⌘Tab, but for repos, as words on black. Gray at
    /// rest; the selected repo is a white chip with black ink. That is the
    /// entire palette.
    private var tokenStrip: some View {
        let repos = model.filtered
        // Left-anchored, like a line of type: the row begins at the drop's
        // padding and rags right. At rest only the right edge fades, because
        // the left edge is margin, not overflow. Once the row is actually
        // scrolled that stops being true — there are tokens back there, and a
        // name shorn flat against x=0 reads as a rendering fault — so the left
        // fade appears with the scroll and leaves with it.
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // The scroll viewport clips hard at x=0 — the first chip's
                // curve needs protected points inside the clip or its left
                // edge shears. This padding lives inside the scroll content,
                // so the rag still reads flush with the computed margin.
                HStack(spacing: Self.tokenSpacing) {
                    // Index identity throughout (id: \.self == .id(index) == selection),
                    // so a selection change updates the token in place instead of
                    // being mis-diffed as a remove/insert.
                    ForEach(repos.indices, id: \.self) { index in
                        token(repos[index], index: index, selected: index == model.selection)
                            .id(index)
                            .onTapGesture { model.activate(at: index) }
                    }
                    if repos.isEmpty { emptyState }
                }
                .padding(.leading, 3)
                // The measurement rides with the content: its minX in the
                // viewport's space *is* the scroll offset. A Bool preference,
                // not the raw offset, so this fires when the edge state flips
                // rather than on every frame of a drag.
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: StripScrolledKey.self,
                            value: g.frame(in: .named(Self.stripSpace)).minX < -0.5)
                    })
            }
            .coordinateSpace(.named(Self.stripSpace))
            .scrollIndicators(.never)
            .onPreferenceChange(StripScrolledKey.self) { [model] scrolled in
                // The callback is @Sendable, and a View is not — hop to the
                // actor that owns the state instead of capturing self.
                Task { @MainActor in model.setStripScrolled(scrolled) }
            }
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: model.stripScrolled ? Self.stripFade : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.stripFade)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                           value: model.stripScrolled)
            )
            .onChange(of: model.selection) { _, new in
                // The same curve as the chip's slide (`PaletteModel.select`),
                // so the strip and the chip move together.
                let scroll = { proxy.scrollTo(new, anchor: Self.anchor(for: new)) }
                reduceMotion ? scroll() : withAnimation(.snappy(duration: 0.24), scroll)
            }
            // Typing reshapes the row (fewer tokens) but leaves the ScrollView
            // holding its old offset, clamped to the shorter content — and a
            // query change sets selection to 0, so when it was *already* 0 the
            // selection observer above never fires. The row settles scrolled,
            // shearing the first chip against the hard clip at x=0. Re-anchor on
            // the query itself, unanimated: the content just swapped, so sliding
            // it as well reads as noise rather than movement.
            .onChange(of: model.query) { _, _ in proxy.scrollTo(0, anchor: .leading) }
            // Same staleness across summons: the view is reused, so a strip left
            // scrolled by the last visit must return to its margin on arrival.
            .onChange(of: contentA) { _, shown in
                guard shown else { return }
                // Unanimated: the reveal's transaction must not slide the row.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    proxy.scrollTo(model.selection, anchor: Self.anchor(for: model.selection))
                }
            }
        }
    }

    /// Where a token is drawn: in the strip (its chip is the sliding one),
    /// as a middle line's subject (a plain chip), or in the hidden measuring
    /// copy (no chip at all, and always at the selected weight so moving the
    /// selection never changes the measured width).
    private enum TokenRole { case strip, subject, measuring }

    /// One repo as a token: its name in gray, and when you arrive, a white
    /// chip with black ink, stark reverse video, no hue anywhere. The chip
    /// alone is selection; danger speaks once, as the red mode word in the
    /// contract (and again at the confirm gate), never as a ring here.
    ///
    /// There is one chip, and it slides: the fill carries a
    /// `matchedGeometryEffect`, animated by the transaction the selection
    /// changed in (`PaletteModel.select`). The padding is constant, so the
    /// neighbours never shift under it.
    private func token(_ repo: Repo, index: Int, selected: Bool,
                       role: TokenRole = .strip) -> some View {
        let label = role == .measuring ? repo.name : tokenAccessibilityText(repo, index: index)
        // No pin glyph: pinned repos already speak by standing first in the
        // row (VoiceOver still says "pinned", the mark was decoration).
        let ink = selected ? Color.black : Color(white: 0.58)
        return tokenText(repo, index: index, selected: selected, role: role)
            // The digit crossfades in with the ⌘ hold's transaction instead of popping.
            .contentTransition(reduceMotion ? .identity : .opacity)
            .font(.system(size: fieldSize,
                          weight: selected || role == .measuring ? .medium : .regular))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, Self.tokenPadding)
            .frame(height: chipH)
            .background {
                if selected && role != .measuring {
                    selectionChip(for: repo, slides: role == .strip)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Switch agent") { model.cycleAgent() }
            .accessibilityAction(named: "Switch mode") { model.cycleMode() }
    }

    /// The name, and while ⌘ is held a superscript digit: the ⌘1–⌘9 that
    /// launches it. Strip tokens only. The subject token is not a target and
    /// the measuring copy never carries a digit, so a held ⌘ reflows the
    /// strip (the same object, briefly annotated) but never moves the hug.
    private func tokenText(_ repo: Repo, index: Int, selected: Bool, role: TokenRole) -> Text {
        let name = Text(matchInk(repo, selected: selected, role: role))
        guard role == .strip, model.commandHeld, index < 9 else { return name }
        // The name and its digit are one Text, see `.contentTransition` at the call site.
        return name + Text(" \(index + 1)")
            .font(.system(size: digitSize, weight: .medium))
            .foregroundStyle(selected ? Color.black.opacity(0.5) : Color(white: 0.58))
            .baselineOffset(4)
    }

    /// The name with the letters the query found drawn in match ink: white
    /// and semibold on gray. On the white chip, where ink can't get any
    /// whiter, the rest of the name steps back to black 0.55 and the matched
    /// letters stay full black, bold. Weight and value, never color. The measuring copy
    /// renders the same runs at the heavier (selected) weight, so the hug is
    /// an upper bound whichever token holds the chip, exactly as the medium
    /// base weight already is.
    private func matchInk(_ repo: Repo, selected: Bool, role: TokenRole) -> AttributedString {
        var text = AttributedString(repo.name)
        guard let offsets = model.match(for: repo)?.offsets, !offsets.isEmpty else { return text }
        let heavy = selected || role == .measuring
        if selected { text.foregroundColor = Color.black.opacity(0.55) }
        var ink = AttributeContainer()
        ink.font = .system(size: fieldSize, weight: heavy ? .bold : .semibold)
        ink.foregroundColor = selected ? Color.black : Color.white
        let characters = Array(text.characters.indices)
        for offset in offsets where characters.indices.contains(offset) {
            let start = characters[offset]
            let end = text.characters.index(after: start)
            text[start..<end].mergeAttributes(ink)
        }
        return text
    }

    /// The chip's fill. Supporters may spend one drop of color here: the
    /// chip in the repo's own bleached hue. Everyone else, pure white.
    @ViewBuilder private func selectionChip(for repo: Repo, slides: Bool) -> some View {
        let chip = Capsule(style: .continuous)
            .fill(model.tintedChips ? RepoTint.chip(for: repo.name) : Color(white: 0.96))
        if slides {
            chip.matchedGeometryEffect(id: "selection", in: selectionNS)
        } else {
            chip
        }
    }

    private func tokenAccessibilityText(_ repo: Repo, index: Int) -> String {
        let agent = model.activeAgent(for: repo)
        let mode = agent.map { model.previewMode(agent: $0, repo: repo) }
        return accessibilityText(repo: repo, agent: agent, mode: mode, index: index)
    }

    /// The strip as the hug measures it: every token at its natural width,
    /// the clip's 3pt protection, and room for the right-edge fade.
    private var stripMeasure: some View {
        let repos = model.filtered
        return HStack(spacing: Self.tokenSpacing) {
            ForEach(repos.indices, id: \.self) { index in
                token(repos[index], index: index, selected: false, role: .measuring)
            }
            if repos.isEmpty { emptyState }
        }
        .padding(.leading, 3)
        .padding(.trailing, Self.stripFade)
    }

    // MARK: - The hug

    /// The content at its natural width, laid out like `content` but never
    /// drawn, never hit, never read by VoiceOver. The search field is stood
    /// in for by its width alone (a second `TextField` would fight for focus).
    private var measuringContent: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: searchRegionWidth + searchRegionTrailing, height: 1)
            middleRegion(measuring: true)
            contractRegion(measuring: true)
                .padding(.leading, Self.contractGap)
        }
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.preference(key: ContentWidthKey.self, value: g.size.width)
        })
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The capsule's width, held inside this screen's range whatever the
    /// last summon left behind.
    private var capsuleWidth: CGFloat { min(max(hugWidth, drop.minWidth), drop.maxWidth) }

    /// Hug the capsule to its content: clamp to [min, max], round up to 8pt
    /// (`DropGeometry.hugWidth`), and while the field holds text only ever
    /// grow (`DropGeometry.ratchet`). Frozen while a launch is in flight
    /// (its Opening line is transient, the capsule must not breathe for it
    /// and again for what replaces it) and while the drop is leaving. Animates only once the content has
    /// arrived, so the strip's viewport is static through the arrival's
    /// re-scroll (the 0.3.2 shear fix depends on that).
    private func rehug(animated: Bool, fresh: Bool = false) {
        guard fresh || (!model.isDismissing && !model.launchInFlight) else { return }
        let proposed = DropGeometry.hugWidth(
            natural: model.naturalContentWidth + 2 * drop.chipInsetResolved,
            min: drop.minWidth, max: drop.maxWidth)
        let next = fresh ? proposed
            : DropGeometry.ratchet(previous: capsuleWidth, proposed: proposed,
                                   // Held in a middle line too (confirm, ⌃W, ⌘L),
                                   // so the gate doesn't make the capsule breathe.
                                   queryEmpty: model.query.isEmpty && middleToken == 0)
        guard next != hugWidth else { return }
        if animated && !reduceMotion && phase == .spread && contentA {
            withAnimation(.smooth(duration: 0.2)) { hugWidth = next }
        } else {
            snap { hugWidth = next }
        }
    }

    private var emptyState: some View {
        Text(model.allRepos.isEmpty
             ? "No repos yet, ⌘R scans your folders, or add roots in Settings"
             : "No match for “\(model.query)”, ⌘R rescans your folders")
            .font(.system(size: fieldSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func accessibilityText(repo: Repo, agent: Agent?, mode: RunMode?, index: Int) -> String {
        var parts = [repo.name]
        if let agent { parts.append(agent.name) }
        if let mode { parts.append("\(mode.name) mode") }
        if repo.pinned { parts.append("pinned") }
        if index < 9 { parts.append("command \(index + 1)") }
        return parts.joined(separator: ", ")
    }

    /// Abbreviate the home directory to `~` for a calmer path.
    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Contract region

    /// The launch contract as two labeled chips — instrument fields, the way
    /// hardware labels its controls: a micro-label eyebrow (AGENT, MODE) and
    /// the value. The drop speaks one object language: every element is a
    /// capsule of one height. White = where you are, gray = what ⏎ does,
    /// red = it skips permissions. Always present (a contract that sometimes
    /// hides reads as a bug), and quietly clickable (the visible counterpart
    /// of ⇥/⇧⇥, real flags in the tooltip). No branch chip: where you are
    /// launching *from* is the tile's business, not the contract's.
    ///
    /// Live: the chips read what ⏎ would do with the modifiers held right
    /// now (`ContractPreview`), so ⌥ turns MODE red before Return lands, ⌃
    /// appends RUN, and a held ⌘ appends OPEN IN.
    @ViewBuilder private func contractRegion(measuring: Bool = false) -> some View {
        if middleToken == 0, let repo = model.selectedRepo,
           let agent = model.activeAgent(for: repo) {
            if measuring {
                // Resting chips, plain faces: no button, no tooltip, no hover,
                // so the hidden copy can never surface anything.
                HStack(spacing: 6) {
                    ForEach(model.contractChips(agent: agent, repo: repo, held: ContractPreview.Held.none)) { c in
                        ChipFace(tag: c.tag, label: c.label, danger: c.danger, hovering: false,
                                 size: metaSize, height: chipH)
                    }
                }
            } else {
                let chips = model.contractChips(agent: agent, repo: repo)
                HStack(spacing: 6) {
                    ForEach(chips) { contractChip($0, agent: agent, repo: repo) }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: chips)
                .transition(.opacity)
            }
        }
    }

    private func contractChip(_ c: ContractPreview.Chip, agent: Agent, repo: Repo) -> some View {
        let help: String
        let action: () -> Void
        switch c.kind {
        case .prompt:
            help = "Starting prompt, ⌘P cycles"
            action = { model.cyclePrompt() }
        case .agent:
            help = "Agent, click or ⇥ to switch"
            action = { model.cycleAgent() }
        case .mode:
            help = modeHelp(model.previewMode(agent: agent, repo: repo))
            action = { model.cycleMode() }
        case .run:
            help = "⌃⏎ runs headless"
            action = {}
        case .openIn:
            help = "⌘⏎ opens the repo in \(c.label)"
            action = {}
        }
        return chip(c.tag, c.label, key: c.key, danger: c.danger, help: help, action: action)
            // RUN and OPEN IN only state what a modifier does, a click does
            // nothing, so they must not announce themselves as buttons.
            .accessibilityRemoveTraits(c.kind == .run || c.kind == .openIn ? .isButton : [])
            .transition(.opacity)
    }

    /// The tooltip carries the truth: the exact flags this mode passes.
    private func modeHelp(_ mode: RunMode) -> String {
        let flags = mode.flags.isEmpty ? "no flags" : mode.flags
        return mode.isDangerous
            ? "Skips permissions (\(flags)), click or ⇧⇥ to switch"
            : "Mode (\(flags)), click or ⇧⇥ to switch"
    }

    private func chip(_ tag: String, _ label: String, key: String? = nil, danger: Bool = false,
                      help: String, action: @escaping () -> Void) -> some View {
        ChipButton(tag: tag, label: label, key: key, danger: danger, help: help,
                   size: metaSize, height: chipH, action: action)
    }

    // MARK: - The drop

    /// The choreography (`DropTimeline`, values in seconds):
    ///
    ///   - **bead** @0: a 12pt bead swells at the housing's lip (spring 0.16,
    ///     bounce 0.2), its top edge on the housing's lower edge.
    ///   - **spread** @0.07: it expands in place into the capsule and the gap
    ///     opens to 8pt (spring 0.34, bounce 0.12).
    ///   - **contentA** @0.17: the search region and token strip arrive
    ///     (opacity, a 4pt rise, blur 4 to 0, smooth 0.22).
    ///   - **contentB** @0.20: the contract, the same way.
    ///
    /// Exits run it backwards: content out, shrink to the bead, absorbed into
    /// the housing, then close. A focus loss only fades. Reduce Motion
    /// crossfades both ways. Every beat is cancellable by a re-summon.
    private func animateIn() {
        sequencer.cancel()
        snap {
            rest()
            if reduceMotion {
                // The crossfade starts from the settled drop, fully faded.
                phase = .spread; beadScale = 1; contentA = true; contentB = true; faded = true
            }
        }
        // Seeded from the last measurement against this screen's range. The
        // measurement itself may not change (and so not refire) this summon.
        rehug(animated: false, fresh: true)
        play(DropTimeline.arrival(reduceMotion: reduceMotion), reason: nil)
    }

    /// The drop at rest: nothing drawn.
    private func rest() {
        phase = .hidden
        contentA = false
        contentB = false
        beadScale = 0
        absorbed = false
        faded = false
        exiting = false
    }

    /// Commit state with no animation, whatever transaction is around.
    private func snap(_ body: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, body)
    }

    private func play(_ beats: [DropTimeline.Beat], reason: DismissReason?) {
        sequencer.run(beats.map { beat in
            StepSequencer.Beat(at: beat.at) { apply(beat.step, reason: reason) }
        })
    }

    private func apply(_ step: DropTimeline.Step, reason: DismissReason?) {
        switch step {
        case .bead:
            snap { phase = .bead }
            withAnimation(.spring(duration: 0.16, bounce: 0.2)) { beadScale = 1 }
        case .spread:
            withAnimation(.spring(duration: 0.34, bounce: 0.12)) { phase = .spread }
        case .contentA:
            withAnimation(.smooth(duration: 0.22)) { contentA = true }
        case .contentB:
            withAnimation(.smooth(duration: 0.22)) { contentB = true }
        case .crossfadeIn:
            withAnimation(.easeInOut(duration: 0.12)) { faded = false }
        case .contentOut:
            // Exiting content fades and blurs in place, it does not sink.
            snap { exiting = true }
            withAnimation(.easeIn(duration: 0.08)) { contentA = false; contentB = false }
        case .shrink:
            // An exit before the bead ever formed has nothing to shrink, and
            // must not conjure a bead just to absorb it.
            guard phase != .hidden else { return }
            withAnimation(.smooth(duration: reason == .launch ? 0.24 : 0.20)) {
                phase = .bead; beadScale = 1
            }
        case .absorb:
            guard phase != .hidden else { return }
            withAnimation(.easeIn(duration: 0.08)) { absorbed = true }
        case .fade:
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.14)) { faded = true }
        case .close:
            model.exitDidFinish()
        }
    }

    /// The drop's window height: housing depth + gap + capsule + the
    /// transparent room the shadow falls into. One storey, always.
    private func pushHeight() {
        onResize(DropGeometry.windowHeight(anchor.geometry, drop: drop))
    }
}

/// Whether the token strip is holding a scroll offset. Deliberately a Bool and
/// not the offset itself: preferences propagate on change, so answering the
/// only question the mask asks keeps a drag from republishing every frame.
private struct StripScrolledKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

/// The natural width of the drop's content, from the hidden measuring copy.
private struct ContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Content arriving in the drop: fade in, rise 4pt, sharpen out of a 4pt
/// blur. Leaving, it only fades and blurs (`rise` false). No animation of its
/// own, the timeline's `withAnimation` carries it, so a cancelled beat leaves
/// nothing half-scheduled behind.
private struct Reveal: ViewModifier {
    let shown: Bool
    let rise: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || !rise ? 0 : 4)
            .blur(radius: shown ? 0 : 4)
    }
}

private extension View {
    func reveal(_ shown: Bool, rise: Bool = true) -> some View {
        modifier(Reveal(shown: shown, rise: rise))
    }
}

/// An instrument field that acts: a micro-label eyebrow and its value in a
/// capsule, the way hardware labels its controls. Hover lifts the fill and
/// brightens the ink — all the affordance a chip needs. Danger wears red
/// ink on a red-tinted fill, the drop's one color: impossible to miss,
/// impossible to shout.
private struct ChipButton: View {
    let tag: String
    let label: String
    let key: String?
    let danger: Bool
    let help: String
    let size: CGFloat
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ChipFace(tag: tag, label: label, key: key, danger: danger, hovering: hovering,
                     size: size, height: height)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(tag): \(label). \(help)")
        .onHover { hovering = $0 }
    }
}

/// A chip's face: the eyebrow and value in their capsule, with no behaviour.
/// `ChipButton` wraps it in a button, the hug's hidden copy draws it bare.
private struct ChipFace: View {
    let tag: String
    let label: String
    /// The ⌘ reveal's key hint, between the eyebrow and the value. Nil at
    /// rest, and always nil in the hug's measuring copy.
    var key: String? = nil
    let danger: Bool
    let hovering: Bool
    let size: CGFloat
    let height: CGFloat
    /// The eyebrow's own metric, so it scales with Dynamic Type but never
    /// drops below legibility at the default size.
    @ScaledMetric(relativeTo: .body) private var eyebrowSize: CGFloat = 8.5
    @ScaledMetric(relativeTo: .body) private var keySize: CGFloat = 10

    var body: some View {
        // Baseline-aligned, not box-centered: the eyebrow and the value
        // are one line of type at two sizes, so they share a baseline
        // the way set type does.
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(tag.uppercased())
                .font(.system(size: eyebrowSize, weight: .semibold))
                .tracking(0.7)
                // Optical centering: on the shared baseline the small
                // caps hang low against the value's cap height — a
                // one-point lift centers the two heights on each other.
                .baselineOffset(1)
                .foregroundStyle(danger ? AnyShapeStyle(dangerTint.opacity(0.6))
                                        : AnyShapeStyle(Color(white: 0.5)))
            if let key {
                Text(key)
                    .font(.system(size: keySize, weight: .regular))
                    .foregroundStyle(Color(white: 0.5))
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(danger ? AnyShapeStyle(dangerTint)
                                        : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .lineLimit(1)
        // A contract never truncates — the token strip scrolls, so it
        // absorbs every point of compression; the chips state their
        // words in full or the contract is meaningless.
        .fixedSize()
        .padding(.horizontal, 11)
        .frame(height: height)
        // Etched, not filled: on pure black a fill reads as a smudge, a
        // hairline reads as an instrument. Danger alone keeps a breath
        // of fill under its red ink so the warning has a temperature.
        .background {
            if danger {
                Capsule(style: .continuous).fill(dangerTint.opacity(hovering ? 0.14 : 0.09))
            }
        }
        .overlay(Capsule(style: .continuous)
            .strokeBorder(danger ? dangerTint.opacity(hovering ? 0.75 : 0.55)
                                 : Color.white.opacity(hovering ? 0.34 : 0.17),
                          lineWidth: 1))
        .contentShape(Capsule(style: .continuous))
    }
}
