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
            return agent.modes.first { $0.name.lowercased() == "safe" } ?? agent.modes.first ?? .safe()
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

// MARK: - View

/// The palette: a floating cluster of Liquid Glass pieces — ⌘Tab for repos.
///
/// Not a sheet with rows (every launcher is that). Three discrete glass
/// pieces with real gaps: a search pill, a horizontal strip of repo tiles you
/// arrow through like the app switcher, and a launch pill that says exactly
/// what ⏎ will do.
///
/// Rules the layout obeys:
///
/// 1. **One material, three pieces.** On macOS 26 each piece is real Liquid
///    Glass inside a shared `GlassEffectContainer`; earlier systems get the
///    legacy vibrancy stack per piece. The window draws no system shadow —
///    each piece carries its own, inside a transparent margin, so AppKit can
///    never mis-shadow a shape it doesn't understand.
/// 2. **The accent means "here, now"** — the caret and the selected tile's
///    tint. Danger red means exactly "skips permissions"; a dangerous tile is
///    ringed red before you arrive, and the launch pill's mode word is red.
/// 3. **The launch pill is the contract.** `❯ agent · mode · branch` — the
///    agent and mode words are quietly clickable (the visible counterpart of
///    ⇥/⇧⇥, real flags in the tooltip). Nothing happens that this line
///    didn't announce.
/// 4. **One voice of type.** SF Mono only, at exactly two sizes — `fieldSize`
///    for what you type, `metaSize` for everything else — and weight carries
///    the hierarchy. The palette speaks machine, quietly.
/// 5. **Keyboard first, mouse honest.** ←/→ (or ↑/↓) move, ⏎ launches,
///    ⌘1–⌘9 jump, ⌘0 resumes; tiles click, launch words cycle.
struct PaletteView: View {
    @ObservedObject private var model: PaletteModel
    let onResize: (CGFloat) -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered: Int?
    @State private var shown = false

    /// Transparent margin around the cluster: the pieces' own shadows live
    /// here. The window is this much larger than the visible content.
    static let windowMargin: CGFloat = 30

    private enum Metric {
        static let gap: CGFloat = 12
        static let tileCorner: CGFloat = 16
        static let stripCorner: CGFloat = 30
        static let maxPanel: CGFloat = 560
        static let minPanel: CGFloat = 120
    }

    // Dynamic Type. Type and the grid scale together, or the panel's computed
    // height stops matching what it actually lays out. Capped at xxLarge below,
    // since a fixed-width HUD can't absorb the accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var pillH: CGFloat = 50
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 66
    @ScaledMetric(relativeTo: .body) private var tileLabelH: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var stripPad: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var fieldSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var metaSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var bannerH: CGFloat = 38

    /// The model is owned by the controller (created + monitored at launch) so
    /// the very first summon is already warm.
    init(model: PaletteModel, onResize: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.onResize = onResize
    }

    private var accent: Color { model.accent }
    private var isDark: Bool { scheme == .dark }
    /// Which content the middle piece shows — drives the crossfade.
    private var modeToken: Int {
        if model.worktreeRepo != nil { return 1 }
        if model.promptRepo != nil { return 2 }
        return 0
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // Blend distance just under the resting gap: pieces fuse into
                // one glass body only while the summon settle has them close,
                // then read as three crisp objects at rest.
                GlassEffectContainer(spacing: 10) { cluster }
            } else {
                cluster
            }
        }
        .scaleEffect(model.launching ? 0.985 : (shown ? 1 : 0.99), anchor: .top)
        .opacity(model.launching ? 0 : (shown ? 1 : 0))
        .offset(y: model.launching ? 10 : 0)
        // The launch gesture: the cluster releases downward as it fades.
        .animation(reduceMotion ? nil : .easeIn(duration: 0.15), value: model.launching)
        // Scale text with the system size, but cap it so this fixed-width HUD
        // stays usable (accessibility sizes would otherwise overflow the strip).
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { model.startMonitoring(); model.reset(); searchFocused = true; animateIn(); pushHeight() }
        .onChange(of: model.worktreeRepo?.id) { _, _ in pushHeight() }
        .onChange(of: model.promptRepo?.id) { _, _ in pushHeight() }
        .onChange(of: model.status) { _, s in
            pushHeight()
            if let s { AccessibilityNotification.Announcement(s).post() }
        }
        .onChange(of: model.isPendingDangerous) { _, pending in
            pushHeight()
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

    private var cluster: some View {
        VStack(spacing: shown ? Metric.gap : -10) {
            searchPill
                .modifier(glassPiece(Capsule(), interactive: true))
            contentPiece
                .modifier(glassPiece(RoundedRectangle(cornerRadius: Metric.stripCorner, style: .continuous),
                                     prominent: true))
                .transition(.opacity)
            if model.isPendingDangerous {
                confirmBanner
                    .modifier(glassPiece(RoundedRectangle(cornerRadius: 14, style: .continuous)))
            } else if model.status != nil {
                statusBanner
                    .modifier(glassPiece(RoundedRectangle(cornerRadius: 14, style: .continuous)))
            }
            launchPill
                .modifier(glassPiece(Capsule(), interactive: true))
        }
        // Worktree/prompt swap the strip for a side panel — as a crossfade,
        // never a hard cut.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: modeToken)
        .padding(Self.windowMargin)
    }

    private func glassPiece<S: InsettableShape>(_ shape: S, interactive: Bool = false,
                                                prominent: Bool = false) -> GlassPiece<S> {
        GlassPiece(shape: shape, isDark: isDark, reduceTransparency: reduceTransparency,
                   interactive: interactive, prominent: prominent)
    }

    /// Quick fade + a barely-there scale, replayed on every show (skipped if
    /// Reduce Motion). A launcher that announces itself gets tiring.
    private func animateIn() {
        if reduceMotion { shown = true; return }
        shown = false
        DispatchQueue.main.async {
            // A settle, not a pop: the pieces separate out of one glass body.
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { shown = true }
        }
    }

    // MARK: - Panel sizing

    /// Height is derived from the grid, not measured, so the resize is exact and
    /// can never oscillate against SwiftUI's own layout pass.
    private func pushHeight() {
        onResize(min(max(naturalHeight, Metric.minPanel), Metric.maxPanel) + Self.windowMargin * 2)
    }

    private var naturalHeight: CGFloat {
        var h = pillH * 2 + Metric.gap * 2 + contentHeight
        if model.isPendingDangerous || model.status != nil { h += bannerH + Metric.gap }
        return h
    }

    private var contentHeight: CGFloat {
        if model.worktreeRepo != nil || model.promptRepo != nil { return 128 }
        return stripPad * 2 + tileSize + 5 + tileLabelH
    }

    // MARK: - Search pill

    /// A shell prompt, not a search box: the prefix names the mode you're in, so
    /// worktree and prompt modes don't need a separate banner to explain
    /// themselves.
    private var searchPill: some View {
        HStack(spacing: 0) {
            if !promptPrefix.isEmpty {
                Text(promptPrefix)
                    .font(.system(size: metaSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(promptPrefix.isEmpty ? "❯ " : " ❯ ")
                .font(.system(size: metaSize, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: fieldSize, design: .monospaced))
                .foregroundStyle(.primary)
                .focused($searchFocused)
                .tint(accent)   // the caret wears the brand, not system blue
                .accessibilityLabel("Search repositories")
            if !model.query.isEmpty, model.worktreeRepo == nil, model.promptRepo == nil {
                // How much the filter cut. Only shown while filtering, because
                // "11 of 11" is not information.
                Text("\(model.filtered.count)")
                    .font(.system(size: metaSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if model.hasLastSession, model.worktreeRepo == nil, model.promptRepo == nil {
                // The idle corner teaches the one shortcut that has no tile:
                // replay the last session.
                Button { model.resumeLastSession() } label: {
                    Text("⌘0 resume")
                        .font(.system(size: metaSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Resume last session")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: pillH)
    }

    /// Empty in the normal state: the caret alone is the prompt (the brand
    /// lives in the icon now). Worktree/prompt name themselves because that
    /// is state the user must not lose track of.
    private var promptPrefix: String {
        if model.worktreeRepo != nil { return "worktree" }
        if model.promptRepo != nil { return "prompt" }
        return ""
    }

    private var placeholder: String {
        if let wt = model.worktreeRepo { return "branch name for \(wt.name)" }
        if let pr = model.promptRepo { return "prompt for \(pr.name)" }
        return "repo"
    }

    // MARK: - Content piece

    @ViewBuilder private var contentPiece: some View {
        if let wt = model.worktreeRepo {
            sidePanel(
                title: "git worktree add",
                body: "An isolated checkout of \(wt.name) on a new branch. The agent launches there, leaving your working tree untouched.",
                detail: model.worktreePreviewPath().map(displayPath))
        } else if let pr = model.promptRepo {
            sidePanel(
                title: "starting prompt",
                body: "Handed to \(model.activeAgent(for: pr)?.name ?? "the agent") in \(pr.name) as its first message.",
                detail: nil)
        } else {
            tileStrip
        }
    }

    private func sidePanel(title: String, body: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: metaSize, weight: .semibold, design: .monospaced))
                .tracking(0.1)
                .foregroundStyle(accent)
            Text(body)
                .font(.system(size: metaSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: metaSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(height: contentHeight)
    }

    /// The repo strip — ⌘Tab, but for repos. Frecency order, ←/→ to move,
    /// ⏎ to launch, pinned repos first.
    private var tileStrip: some View {
        let repos = model.filtered
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    // Index identity throughout (id: \.self == .id(index) == selection),
                    // so a selection change updates the tile in place instead of
                    // being mis-diffed as a remove/insert.
                    ForEach(repos.indices, id: \.self) { index in
                        tile(repos[index], index: index,
                             selected: index == model.selection, hovered: hovered == index)
                            .id(index)
                            .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
                            .onTapGesture { model.activate(at: index) }
                    }
                    if repos.isEmpty { emptyState }
                }
                .padding(.horizontal, 20)   // same grid line as the pills' text
                .padding(.vertical, stripPad)
            }
            .scrollIndicators(.never)
            // Soft edges: tiles fade out at the sides instead of being
            // guillotined by the clip — the strip reads as continuing.
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 18)
                    Color.black
                    LinearGradient(colors: [.black, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 18)
                }
            )
            .frame(height: contentHeight)
            .onChange(of: model.selection) { _, new in
                let scroll = { proxy.scrollTo(new, anchor: .center) }
                reduceMotion ? scroll() : withAnimation(.easeOut(duration: 0.14), scroll)
            }
        }
    }

    /// One repo as a tile — every repo gets its tint. Identity is the repo:
    /// a stable hue hashed from its name, its monogram in that hue, and the
    /// agent's mark as a small corner badge. Recognition works the way ⌘Tab
    /// works: color + letter, at a glance. A red ring still warns before you
    /// arrive that this tile's mode skips permissions.
    private func tile(_ repo: Repo, index: Int, selected: Bool, hovered: Bool) -> some View {
        let agent = model.activeAgent(for: repo)
        let mode = agent.map { model.displayMode(agent: $0, repo: repo) }
        let dangerous = mode?.isDangerous == true
        let repoColor = RepoTint.color(for: repo.name, dark: isDark)
        let repoFill = RepoTint.fill(for: repo.name, dark: isDark)
        // Micro-motion is transform-only (scale + glow), so it can never fight
        // the layout pass — the strip's geometry stays put.
        let scale: CGFloat = selected ? (model.launching ? 0.92 : 1.05) : (hovered ? 1.03 : 1)
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Metric.tileCorner, style: .continuous)
                    .fill(LinearGradient(
                        colors: [repoFill.opacity(isDark ? (selected ? 0.4 : 0.15) : (selected ? 0.28 : 0.11)),
                                 repoFill.opacity(isDark ? (selected ? 0.18 : 0.05) : (selected ? 0.13 : 0.04))],
                        startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: Metric.tileCorner, style: .continuous)
                    .strokeBorder(
                        dangerous ? dangerTint.opacity(selected ? 0.85 : 0.45)
                                  : selected ? Color.primary.opacity(0.7)
                                             : repoColor.opacity(hovered ? 0.35 : 0),
                        lineWidth: selected ? 1.5 : 1)
                // The short name is the identity — no badges competing with it.
                // The agent lives in the launch pill, where agent info belongs.
                Text(RepoTint.shortName(for: repo.name))
                    .font(.system(size: tileSize * 0.24, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(repoColor)
                    .accessibilityHidden(true)
                if repo.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topTrailing)
                        .padding(6)
                }
            }
            .frame(width: tileSize, height: tileSize)
            .shadow(color: selected ? (dangerous ? dangerTint : repoColor).opacity(isDark ? 0.4 : 0.3) : .clear,
                    radius: 9, y: 2)
            .scaleEffect(scale)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75),
                       value: scale)
            Text(repo.name)
                .font(.system(size: metaSize, weight: selected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: tileSize + 22)
                .frame(height: tileLabelH)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(repo: repo, agent: agent, mode: mode, index: index))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Switch agent") { model.cycleAgent() }
        .accessibilityAction(named: "Switch mode") { model.cycleMode() }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.allRepos.isEmpty
                 ? "No repos yet — ⌘R scans your folders, or add roots in Settings"
                 : "No match for “\(model.query)”")
                .font(.system(size: metaSize, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(height: tileSize + 5 + tileLabelH)
        .padding(.horizontal, 8)
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

    // MARK: - Banners

    private var confirmBanner: some View {
        HStack(spacing: 8) {
            Text("!!")
                .font(.system(size: metaSize, weight: .bold, design: .monospaced))
            Text("↵ again to launch \(model.pendingDangerousDescription ?? "") — skips all permissions")
                .font(.system(size: metaSize, design: .monospaced))
            Spacer(minLength: 8)
            Text("esc cancels")
                .font(.system(size: metaSize, design: .monospaced))
                .foregroundStyle(dangerTint.opacity(0.65))
        }
        .foregroundStyle(dangerTint)
        .padding(.horizontal, 20)
        .frame(height: bannerH)
        .background(dangerTint.opacity(0.13))
    }

    /// Full-width, wrapping, selectable banner for status + errors — readable,
    /// unlike a one-line truncated footer.
    @ViewBuilder private var statusBanner: some View {
        if let status = model.status {
            let isError = status.hasPrefix("⚠")
            let text = isError ? String(status.dropFirst(2)) : status
            HStack(alignment: .top, spacing: 8) {
                Text(isError ? "!!" : "::")
                    .font(.system(size: metaSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(isError ? dangerTint : accent)
                Text(text)
                    .font(.system(size: metaSize, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: bannerH, alignment: .center)
            .background((isError ? dangerTint : accent).opacity(0.1))
        }
    }

    // MARK: - Launch pill

    /// The launch contract: `❯ agent · mode` and, at the right, the selected
    /// repo's path and branch. The agent and mode words are quietly clickable
    /// (the visible counterpart of ⇥/⇧⇥, real flags in the tooltip). In
    /// worktree/prompt/confirm states it names the state and its two keys.
    private var launchPill: some View {
        // The caret is the contract's mood: accent normally, red the moment ⏎
        // would skip permissions — before any confirm step.
        let selectedDangerous = model.selectedRepo.flatMap { repo in
            model.activeAgent(for: repo).map { model.displayMode(agent: $0, repo: repo).isDangerous }
        } ?? false
        return HStack(spacing: 8) {
            Text("❯")
                .font(.system(size: metaSize, weight: .bold, design: .monospaced))
                .foregroundStyle(model.isPendingDangerous || selectedDangerous ? dangerTint : accent)
                .accessibilityHidden(true)
            if model.isPendingDangerous {
                planText("confirm — ↵ launches, esc cancels", color: dangerTint)
            } else if model.worktreeRepo != nil {
                planText("worktree — ↵ creates and launches, esc goes back")
            } else if model.promptRepo != nil {
                planText("prompt — ↵ launches with it, esc goes back")
            } else if let repo = model.selectedRepo, let agent = model.activeAgent(for: repo) {
                let mode = model.displayMode(agent: agent, repo: repo)
                // The agent's mark sits with the agent's name — its one home.
                AgentMark(agent: agent,
                          tint: agent.tintHex.flatMap(Color.init(hex:)) ?? accent,
                          monogram: model.monogram(for: agent),
                          selected: true, dark: isDark, size: 12)
                    .accessibilityHidden(true)
                segment(agent.name.lowercased(),
                        help: "Agent — click or ⇥ to switch") { model.cycleAgent() }
                planDot
                segment(mode.name.lowercased(), danger: mode.isDangerous,
                        help: modeHelp(mode)) { model.cycleMode() }
            }
            Spacer(minLength: 12)
            if let prompt = model.selectedPrompt {
                Text(prompt.title.lowercased())
                    .font(.system(size: metaSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
            pathAndBranch
        }
        .padding(.horizontal, 20)
        .frame(height: pillH)
    }

    private var planDot: some View {
        Text("·")
            .font(.system(size: metaSize, design: .monospaced))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func planText(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: metaSize, design: .monospaced))
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .lineLimit(1)
    }

    /// The tooltip carries the truth: the exact flags this mode passes.
    private func modeHelp(_ mode: RunMode) -> String {
        let flags = mode.flags.isEmpty ? "no flags" : mode.flags
        return mode.isDangerous
            ? "Skips permissions (\(flags)) — click or ⇧⇥ to switch"
            : "Mode (\(flags)) — click or ⇧⇥ to switch"
    }

    /// Where the launch lands: the selected repo's path, then its branch with
    /// the shell dirty marker — async from the model's cache, never a
    /// subprocess or disk read on the render path.
    @ViewBuilder private var pathAndBranch: some View {
        if model.worktreeRepo == nil, model.promptRepo == nil, !model.isPendingDangerous,
           let repo = model.selectedRepo {
            let full = displayPath(repo.path)
            let leaf = (full as NSString).lastPathComponent
            let dir = String(full.dropLast(leaf.count))
            HStack(spacing: 8) {
                // The directory is context, the leaf is the answer — the path
                // carries its own hierarchy instead of one flat grey.
                (Text(dir).foregroundColor(.secondary.opacity(0.75))
                    + Text(leaf).foregroundColor(.primary))
                    .font(.system(size: metaSize, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                    .layoutPriority(-1)
                if let ctx = model.gitContext(for: repo), let branch = ctx.branch {
                    let dirty = ctx.dirty == true
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8.5, weight: .medium))
                        Text(dirty ? "\(branch)*" : branch)
                            .font(.system(size: metaSize, design: .monospaced))
                    }
                    .foregroundStyle(dirty ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .accessibilityLabel(dirty ? "On branch \(branch), uncommitted changes"
                                              : "On branch \(branch)")
                }
            }
        }
    }

    /// A quietly clickable word in the launch line. Hover brightens it — all
    /// the affordance a prompt should carry; the tooltip explains the rest.
    private func segment(_ label: String, danger: Bool = false, help: String,
                         action: @escaping () -> Void) -> some View {
        SegmentButton(label: label, danger: danger, help: help,
                      size: metaSize, action: action)
    }
}


/// Hover-brightening text button for the launch line.
private struct SegmentButton: View {
    let label: String
    let danger: Bool
    let help: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundStyle(danger ? AnyShapeStyle(dangerTint)
                                        : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .underline(hovering, color: danger ? dangerTint : .secondary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Glass piece

/// One floating element of the cluster. On macOS 26 it is real Liquid Glass
/// (with a measured frost so small mono type survives a busy window); earlier
/// systems get the legacy vibrancy stack. Reduce Transparency gets a fully
/// opaque piece on every OS. Each piece carries its own soft shadow — the
/// window itself draws none.
private struct GlassPiece<S: InsettableShape>: ViewModifier {
    let shape: S
    let isDark: Bool
    let reduceTransparency: Bool
    /// Interactive glass reacts to hover/press like a real Tahoe control —
    /// the pills are controls, the strip is a surface.
    var interactive = false
    /// The strip is the biggest object, so it sits lowest; pills float lighter.
    var prominent = false

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content
                    .background(isDark ? Color(white: 0.11) : Color(white: 0.97))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(
                        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.14), lineWidth: 1))
            } else if #available(macOS 26.0, *) {
                // Legibility comes from vibrancy (hierarchical foreground
                // styles on the glass), not from a heavy scrim — a whisper of
                // frost is all the material needs over a worst-case window.
                content
                    .background((isDark ? Color.black : Color.white).opacity(isDark ? 0.18 : 0.15))
                    .clipShape(shape)
                    .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            } else {
                content
                    .background {
                        ZStack {
                            GlassBackground(material: isDark ? .hudWindow : .popover)
                            (isDark ? Color.black : Color.white).opacity(isDark ? 0.45 : 0.6)
                        }
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(
                        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.14), lineWidth: 1))
            }
        }
        .shadow(color: .black.opacity(isDark ? 0.32 : 0.15),
                radius: prominent ? 20 : 12, y: prominent ? 8 : 5)
    }
}
