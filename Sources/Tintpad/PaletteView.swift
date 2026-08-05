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

/// Holds the palette's mutable state and behavior. Lives as an `ObservableObject`
/// so a scoped `NSEvent` key monitor can drive navigation/actions reliably —
/// `.onKeyPress` on a `TextField` swallows arrow keys, so we don't rely on it.
@MainActor
final class PaletteModel: ObservableObject {
    // Typing changes which repo is selected, and overrides belong to the row
    // they were made on — so a query change clears them along with transients.
    @Published var query = "" {
        didSet {
            selection = 0
            agentOverrideID = nil
            modeOverrideID = nil
            clearTransient()
            refreshGitContext()
        }
    }
    @Published var selection = 0
    @Published var agentOverrideID: UUID?
    @Published var modeOverrideID: UUID?
    @Published var status: String?
    @Published var selectedPromptID: UUID?
    @Published var worktreeRepo: Repo?
    /// When set, the search field captures a one-off prompt for this repo.
    @Published var promptRepo: Repo?

    /// True for the ~160ms launch gesture: the cluster releases downward as
    /// it fades, so a launch *feels* like one. Esc still closes instantly.
    @Published private(set) var launching = false

    fileprivate var pendingDangerous: PendingLaunch?

    /// Injectable (like `tabTraverses`) so the gesture can be tested off.
    var reduceMotionActive: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Close after the launch gesture has played — or immediately when motion
    /// is reduced, because a delay with no animation just reads as lag.
    private func closeAfterLaunch() {
        guard !launching else { return }
        if reduceMotionActive() { onClose(); return }
        launching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            self?.launching = false
            self?.onClose()
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

    var accent: Color { store.settings.tintAccent.color }
    var prompts: [PromptTemplate] { store.prompts }
    var allRepos: [Repo] { store.repos }

    var selectedPrompt: PromptTemplate? { store.prompts.first { $0.id == selectedPromptID } }

    func monogram(for agent: Agent?) -> String { store.monogram(for: agent) }

    var filtered: [Repo] {
        let ordered = store.orderedRepos()
        guard !query.isEmpty else { return ordered }
        let q = query.lowercased()
        return ordered.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
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
        return "\(p.agent.name) · \(p.mode.name)"
    }

    // MARK: - Key monitor

    /// Install a local key monitor scoped to the command panel. Returns the
    /// event (passes through) for normal typing, nil to swallow handled keys.
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window, window is CommandPanel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Called when the panel is shown to reset transient per-summon state.
    func reset() {
        launching = false
        status = nil
        pendingDangerous = nil
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
            status = "Scanned — \(n) new repo\(n == 1 ? "" : "s")"
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
        // ⌘n while a dangerous confirm is pending cancels it — the jump must
        // never fire a YOLO that was armed for a different repo.
        if pendingDangerous != nil { clearTransient() }
        guard filtered.indices.contains(index) else { return false }
        selection = index
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
        clearTransient()
        guard let session = store.lastSession else { status = "no session to resume yet"; return true }
        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            switch LaunchService.resumeLast(store: store) {
            case .launched: closeAfterLaunch()
            case .unavailable:
                status = "⚠ that session can't be resumed — its repo, agent, or mode is gone"
            case .failed(let error):
                status = "⚠ \(error)"
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
        selection = (selection + delta + count) % count
        // Agent/mode overrides belong to the row you were on — reset on move.
        agentOverrideID = nil
        modeOverrideID = nil
        clearTransient()
        refreshGitContext()
    }

    func cyclePrompt() {
        guard store.allows(.promptLibrary) else { status = ProFeature.promptLibrary.blurb; return }
        guard !store.prompts.isEmpty else { status = "No saved prompts — add some in Settings"; return }
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
        onOpenSettings()
    }

    func clearTransient() { status = nil; pendingDangerous = nil }

    /// The mode that a plain ⏎ will use right now (no modifiers) — drives the chip.
    func displayMode(agent: Agent, repo: Repo) -> RunMode {
        // The ⇧⇥ override is scoped to the selected row too.
        let override = repo.id == selectedRepo?.id ? modeOverrideID : nil
        return LaunchDefaults.mode(for: repo, agent: agent, overrideID: override)
    }

    func resolveMode(agent: Agent, repo: Repo, modifiers: NSEvent.ModifierFlags) -> RunMode {
        if modifiers.contains(.option), let danger = agent.dangerousMode { return danger }
        if modifiers.contains(.shift) {
            // "Safest available": the first non-dangerous mode, whatever the
            // agent calls it (modes speak the agent's language, not ours).
            return agent.modes.first { !$0.isDangerous } ?? agent.modes.first ?? .defaultMode()
        }
        return displayMode(agent: agent, repo: repo)
    }


    // MARK: - Worktree mode

    func enterWorktreeMode() {
        guard let repo = selectedRepo else { return }
        guard store.allows(.worktree) else { status = ProFeature.worktree.blurb; return }
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
            status = "creating worktree…"
            let store = self.store
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try WorktreeService.create(repoPath: repo.path, branch: branch, at: worktreePath)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        do {
                            let outcome = try LaunchService.launchAgent(
                                repo: repo, agent: agent, mode: mode, prompt: promptText,
                                store: store, worktreePath: worktreePath)
                            if let note = outcome.note { status = note } else { closeAfterLaunch() }
                        } catch { status = "⚠ \(error)" }
                    }
                } catch {
                    Task { @MainActor [weak self] in self?.status = "⚠ \(error)" }
                }
            }
        }
    }

    // MARK: - Prompt mode

    func enterPromptMode() {
        guard let repo = selectedRepo else { return }
        guard store.allows(.promptLibrary) else { status = ProFeature.promptLibrary.blurb; return }
        worktreeRepo = nil   // the two field-capture modes are mutually exclusive
        promptRepo = repo
        query = ""
    }

    func exitPromptMode() { promptRepo = nil; query = "" }

    private func launchWithTypedPrompt() {
        guard let repo = promptRepo, let agent = activeAgent(for: repo) else { return }
        let prompt = query.trimmingCharacters(in: .whitespaces)
        let mode = resolveMode(agent: agent, repo: repo, modifiers: [])
        if mode.isDangerous && !store.allows(.yoloMode) { status = ProFeature.yoloMode.blurb; return }
        fireOrConfirm(repo: repo, agent: agent, mode: mode) { [weak self] in
            self?.perform(repo: repo, agent: agent, mode: mode, prompt: prompt.isEmpty ? nil : prompt)
        }
    }

    // MARK: - Actions

    func handleEscape() {
        if pendingDangerous != nil { clearTransient(); return }
        if worktreeRepo != nil { exitWorktreeMode(); return }
        if promptRepo != nil { exitPromptMode(); return }
        onClose()
    }

    func handleReturn(modifiers mods: NSEvent.ModifierFlags) {
        if let pending = pendingDangerous {
            pendingDangerous = nil
            pending.fire()
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
        if mode.isDangerous && !store.allows(.yoloMode) { status = ProFeature.yoloMode.blurb; return }
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
        if pendingDangerous != nil { clearTransient() }
        guard filtered.indices.contains(index) else { return }
        selection = index
        handleReturn(modifiers: NSEvent.modifierFlags)
    }

    private func dispatch(repo: Repo, agent: Agent, mode: RunMode) {
        guard store.allows(.dispatch) else { status = ProFeature.dispatch.blurb; return }
        do {
            _ = try DispatchService.shared.dispatch(
                repo: repo, agent: agent, mode: mode, prompt: selectedPrompt?.text, store: store)
            closeAfterLaunch()
        } catch { status = "⚠ dispatch: \(error)" }
    }

    private func openInEditor(repo: Repo) {
        do { try LaunchService.openInEditor(repo: repo, store: store); closeAfterLaunch() }
        catch { status = "⚠ no editor detected — set one in Settings" }
    }

    private func perform(repo: Repo, agent: Agent, mode: RunMode, prompt: String? = nil) {
        do {
            let outcome = try LaunchService.launchAgent(
                repo: repo, agent: agent, mode: mode,
                prompt: prompt ?? selectedPrompt?.text, store: store)
            if let note = outcome.note { status = note } else { closeAfterLaunch() }
        } catch { status = "⚠ \(error)" }
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
    /// The settled droplet width for this screen.
    var maxWidth: CGFloat

    static let fallback = NotchGeometry(hasNotch: false, restHeight: 0, maxWidth: 640)
}

/// Bridges the controller's per-summon geometry into the SwiftUI drop.
@MainActor
final class NotchAnchor: ObservableObject {
    @Published var geometry: NotchGeometry = .fallback
}

// MARK: - View

/// The palette: a black drop that falls out of the notch.
///
/// Summon, and a bead of black drips from the camera housing's lip, falls
/// free — stretching slightly, the way liquid does — lands a beat below,
/// and splats sideways into a floating capsule that settles with one soft
/// bob. The drop holds the repos as words: stark black and white, nothing
/// else. Launch, and the capsule condenses back into the bead and is pulled
/// up into the housing.
///
/// Rules the layout obeys:
///
/// 1. **Nothing behind the camera.** The drop floats strictly below the
///    housing line; the housing keeps every one of its pixels.
/// 2. **Black and white, fully mute.** The capsule is pure black in every
///    theme, the ink is white and gray, the caret included. At rest the
///    drop speaks one object language: every element is a capsule of one
///    height. White chip = where you are, gray chips = the contract (what
///    ⏎ does — always present, a contract that hides reads as a bug), red
///    chip = it skips permissions, the only color the drop ever allows.
///    The query materializes at the left as you type.
/// 3. **The fall is the brand.** Drip (a bead pops at the lip) → fall
///    (easeIn, elongating) → splat (one spring with a touch of overshoot,
///    squash into spread) → settle (a single bob) → tokens surfacing
///    center-out. Squash and stretch, anticipation, follow-through —
///    springs, not durations, so any interruption retargets mid-flight.
///    Reduce Motion replaces the film with a crossfade.
/// 4. **Keyboard first, mouse honest.** ←/→ (or ↑/↓) move through tokens
///    while the field is empty, ⏎ launches, ⌘1–⌘9 jump, ⌘0 resumes, ⇥/⇧⇥
///    cycle agent/mode — the contract's words are the clickable counterparts.
struct PaletteView: View {
    @ObservedObject private var model: PaletteModel
    @ObservedObject private var anchor: NotchAnchor
    let onResize: (CGFloat) -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0          // 0 rest · 1 drip · 2 fallen · 3 spread
    @State private var contentShown = false
    @State private var landBob = false    // one soft bounce as the drop settles

    /// Transparent room around the drop where its shadow falls.
    static let shadowMargin: CGFloat = 30
    /// How far the bead falls from the housing's lip to where it rests.
    private static let fall: CGFloat = 22
    /// The bead before it spreads.
    private static let beadSize: CGFloat = 14

    // Dynamic Type. The drop's height derives from these, so they scale
    // together. Capped at xxLarge — one line cannot absorb accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var dropH: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var fieldSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var metaSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var chipH: CGFloat = 21

    /// The model is owned by the controller (created + monitored at launch) so
    /// the very first summon is already warm.
    init(model: PaletteModel, anchor: NotchAnchor,
         onResize: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.anchor = anchor
        self.onResize = onResize
    }

    private var accent: Color { model.accent }
    /// Which content the middle region shows — drives the crossfade.
    private var middleToken: Int {
        if model.isPendingDangerous { return 1 }
        if model.status != nil { return 2 }
        if model.worktreeRepo != nil { return 3 }
        if model.promptRepo != nil { return 4 }
        return 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // The housing's own depth — the window is flush with the screen
            // top on notched Macs, and the fall begins where the housing ends.
            Spacer().frame(height: anchor.geometry.restHeight + Self.fall)
            droplet
                // Follow-through: the landing carries 4pt past the resting
                // line and springs back — the splat has weight.
                .offset(y: landBob ? 0 : -4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        // The drop is a black world regardless of system theme — fix the
        // hierarchy styles to dark so .secondary/.tertiary read on black.
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
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
                    "Confirm dangerous launch: \(d). Press return again to launch, or escape to cancel."
                ).post()
            }
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
        let g = anchor.geometry
        let spread = phase >= 3 && !model.launching
        let falling = phase == 2 && !model.launching
        let drip = phase == 1 && !model.launching
        // The bead elongates while it falls — liquid stretches under its
        // own weight — and rides above the resting line until it lands.
        let width: CGFloat = spread ? g.maxWidth : (falling ? Self.beadSize - 2 : Self.beadSize)
        let height: CGFloat = spread ? dropH : (falling ? Self.beadSize + 5 : Self.beadSize)
        return ZStack {
            Capsule(style: .continuous).fill(.black)
            content
                .opacity(contentShown && !model.launching ? 1 : 0)
                .animation(reduceMotion ? nil : .easeIn(duration: 0.08), value: model.launching)
        }
        .clipShape(Capsule(style: .continuous))
        .frame(width: width, height: height)
        .offset(y: drip || model.launching ? -Self.fall : 0)
        .opacity(phase >= 1 ? 1 : 0)
        .shadow(color: .black.opacity(spread ? 0.5 : 0.25), radius: spread ? 16 : 5,
                y: spread ? 8 : 3)
        .animation(reduceMotion ? nil : .easeIn(duration: 0.15), value: model.launching)
    }

    private var content: some View {
        // Spacing is owned by the regions (the field pads itself only while
        // visible; the contract carries its own separation) so the token row
        // starts hard at the drop's left padding — an honest rag, no drift.
        HStack(spacing: 0) {
            searchRegion
                .stagger(0.02, shown: contentShown, reduced: reduceMotion)
            middleRegion
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            contractRegion
                .layoutPriority(1)
                .padding(.leading, 32)   // separation is space, not a divider
                .stagger(0.05, shown: contentShown, reduced: reduceMotion)
        }
        // The middle-region swap is a crossfade, never a hard cut.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: middleToken)
        // Optical law: the first chip's margin matches the vertical inset —
        // plus the round-end compensation. A capsule's curve eats into the
        // corner, so the geometric margin alone reads as a clip; the extra
        // points give back what the curve takes.
        .padding(.horizontal, (dropH - chipH) / 2 + 5)
    }

    // MARK: - Search region

    /// Fully mute: at rest the field is invisible (a hairline that still
    /// holds keyboard focus). It materializes at the left as you type; in
    /// worktree/prompt modes it names the state and widens — it is
    /// capturing, not filtering. The caret is white: the drop is monochrome
    /// down to the last pixel.
    private var searchRegion: some View {
        let resting = model.query.isEmpty && !capturing
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
        .frame(width: capturing ? 280 : (resting ? 0 : 150), alignment: .leading)
        .padding(.trailing, resting ? 0 : 12)
        .opacity(resting ? 0 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                   value: resting)
    }

    private var capturing: Bool { model.worktreeRepo != nil || model.promptRepo != nil }

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
    /// all speak here, in place of the tokens. One storey, always.
    @ViewBuilder private var middleRegion: some View {
        if model.isPendingDangerous {
            middleLine("Return again to launch \(model.pendingDangerousDescription ?? "") — Esc cancels",
                       color: dangerTint)
        } else if let status = model.status {
            let isError = status.hasPrefix("⚠")
            middleLine(isError ? String(status.dropFirst(2)) : status,
                       color: isError ? dangerTint : nil)
        } else if model.worktreeRepo != nil {
            middleLine(worktreeExplainer)
        } else if model.promptRepo != nil {
            middleLine("Handed to \(model.promptRepo.flatMap { model.activeAgent(for: $0) }?.name ?? "the agent") as its first message — Return launches, Esc goes back")
        } else {
            tokenStrip
        }
    }

    private var worktreeExplainer: String {
        if let path = model.worktreePreviewPath() {
            return "New worktree at \(displayPath(path)) — Return creates and launches"
        }
        return "An isolated checkout on a new branch — Return creates and launches"
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
        let mid = Double(max(repos.count - 1, 0)) / 2
        // Left-anchored, like a line of type: the row begins at the drop's
        // padding and rags right. Only the right edge fades (overflow is the
        // only thing worth signaling — the left edge is the margin).
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // The scroll viewport clips hard at x=0 — the first chip's
                // curve needs protected points inside the clip or its left
                // edge shears. This padding lives inside the scroll content,
                // so the rag still reads flush with the computed margin.
                HStack(spacing: 6) {
                    // Index identity throughout (id: \.self == .id(index) == selection),
                    // so a selection change updates the token in place instead of
                    // being mis-diffed as a remove/insert.
                    ForEach(repos.indices, id: \.self) { index in
                        token(repos[index], index: index, selected: index == model.selection)
                            .id(index)
                            .onTapGesture { model.activate(at: index) }
                            // Tokens surface like objects floating up as the
                            // liquid stills — center-out, a beat apart.
                            .stagger(0.04 + abs(Double(index) - mid) * 0.022,
                                     shown: contentShown, reduced: reduceMotion)
                    }
                    if repos.isEmpty {
                        emptyState.stagger(0.04, shown: contentShown, reduced: reduceMotion)
                    }
                }
                .padding(.leading, 3)
            }
            .scrollIndicators(.never)
            .mask(
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                }
            )
            .onChange(of: model.selection) { _, new in
                let scroll = { proxy.scrollTo(new, anchor: .center) }
                reduceMotion ? scroll() : withAnimation(.easeOut(duration: 0.14), scroll)
            }
        }
    }

    /// One repo as a token: its name in gray, and when you arrive, a white
    /// chip with black ink — stark reverse video, no hue anywhere. The chip
    /// alone is selection; danger speaks once, as the red mode word in the
    /// contract (and again at the confirm gate), never as a ring here.
    private func token(_ repo: Repo, index: Int, selected: Bool) -> some View {
        let agent = model.activeAgent(for: repo)
        let mode = agent.map { model.displayMode(agent: $0, repo: repo) }
        // No pin glyph: pinned repos already speak by standing first in the
        // row (VoiceOver still says "pinned" — the mark was decoration).
        return HStack(spacing: 4) {
            Text(repo.name)
                .font(.system(size: fieldSize, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : Color(white: 0.58))
                .lineLimit(1)
        }
        .padding(.horizontal, selected ? 9 : 5)
        .frame(height: chipH)
        .background {
            if selected {
                Capsule(style: .continuous).fill(Color(white: 0.96))
            }
        }
        .scaleEffect(selected && model.launching ? 0.94 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.8),
                   value: selected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(repo: repo, agent: agent, mode: mode, index: index))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Switch agent") { model.cycleAgent() }
        .accessibilityAction(named: "Switch mode") { model.cycleMode() }
    }

    private var emptyState: some View {
        Text(model.allRepos.isEmpty
             ? "No repos yet — ⌘R scans your folders, or add roots in Settings"
             : "No match for “\(model.query)”")
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
    @ViewBuilder private var contractRegion: some View {
        if middleToken == 0, let repo = model.selectedRepo,
           let agent = model.activeAgent(for: repo) {
            let mode = model.displayMode(agent: agent, repo: repo)
            HStack(spacing: 6) {
                if let prompt = model.selectedPrompt {
                    chip("prompt", prompt.title,
                         help: "Starting prompt — ⌘P cycles") { model.cyclePrompt() }
                }
                chip("agent", agent.name,
                     help: "Agent — click or ⇥ to switch") { model.cycleAgent() }
                chip("mode", mode.name, danger: mode.isDangerous,
                     help: modeHelp(mode)) { model.cycleMode() }
            }
            .transition(.opacity)
        }
    }

    /// The tooltip carries the truth: the exact flags this mode passes.
    private func modeHelp(_ mode: RunMode) -> String {
        let flags = mode.flags.isEmpty ? "no flags" : mode.flags
        return mode.isDangerous
            ? "Skips permissions (\(flags)) — click or ⇧⇥ to switch"
            : "Mode (\(flags)) — click or ⇧⇥ to switch"
    }

    private func chip(_ tag: String, _ label: String, danger: Bool = false, help: String,
                      action: @escaping () -> Void) -> some View {
        ChipButton(tag: tag, label: label, danger: danger, help: help,
                   size: metaSize, height: chipH, action: action)
    }

    // MARK: - The drop

    /// The choreography, four beats — the classic principles (anticipation,
    /// squash and stretch, follow-through), springs throughout so any
    /// interruption retargets mid-flight:
    ///
    ///   1. **Drip** — a bead pops at the housing's lip (response 0.22,
    ///      damping 0.55: a squishy overshoot). Anticipation: the drop
    ///      forms before it falls.
    ///   2. **Fall** — 130ms easeIn, accelerating like a thing with weight,
    ///      the bead elongating as it goes. Stretch.
    ///   3. **Splat** — the spread spring carries a touch of overshoot
    ///      (response 0.4, damping 0.72): width blooms past and settles.
    ///      The whole capsule simultaneously carries 4pt past the resting
    ///      line and springs back (damping 0.58). Squash + follow-through.
    ///   4. **Surface** — tokens float up center-out, 22ms apart, as the
    ///      liquid stills.
    ///
    /// Launch runs the film backwards: the capsule condenses to the bead
    /// and is pulled up into the housing. Reduce Motion replaces all of it
    /// with a crossfade.
    private func animateIn() {
        if reduceMotion { phase = 3; contentShown = true; landBob = true; return }
        phase = 0
        contentShown = false
        landBob = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { phase = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeIn(duration: 0.13)) { phase = 2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) { phase = 3 }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.58)) { landBob = true }
                    // Content elements carry their own stagger delays.
                    contentShown = true
                }
            }
        }
    }

    /// The drop's window height: housing depth + fall + capsule + the
    /// transparent room the shadow falls into. One storey, always.
    private func pushHeight() {
        onResize(anchor.geometry.restHeight + Self.fall + dropH + Self.shadowMargin)
    }
}

/// Staggered arrival for drop content: fade + a 6pt rise, delayed per
/// element so the liquid hands off to the content center-out.
private struct Stagger: ViewModifier {
    let delay: Double
    let shown: Bool
    let reduced: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduced ? 0 : 6)
            .animation(reduced ? nil : .spring(response: 0.32, dampingFraction: 0.85).delay(delay),
                       value: shown)
    }
}

private extension View {
    func stagger(_ delay: Double, shown: Bool, reduced: Bool) -> some View {
        modifier(Stagger(delay: delay, shown: shown, reduced: reduced))
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
    let danger: Bool
    let help: String
    let size: CGFloat
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // Baseline-aligned, not box-centered: the eyebrow and the value
            // are one line of type at two sizes, so they share a baseline
            // the way set type does.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(tag.uppercased())
                    .font(.system(size: size * 0.68, weight: .semibold))
                    .tracking(0.7)
                    // Optical centering: on the shared baseline the small
                    // caps hang low against the value's cap height — a
                    // one-point lift centers the two heights on each other.
                    .baselineOffset(1)
                    .foregroundStyle(danger ? AnyShapeStyle(dangerTint.opacity(0.6))
                                            : AnyShapeStyle(Color(white: 0.42)))
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
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(tag): \(label). \(help)")
        .onHover { hovering = $0 }
    }
}
