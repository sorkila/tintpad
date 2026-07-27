import AppKit
import SwiftUI

private struct PendingLaunch { let repo: Repo; let agent: Agent; let mode: RunMode }

/// Holds the palette's mutable state and behavior. Lives as an `ObservableObject`
/// so a scoped `NSEvent` key monitor can drive navigation/actions reliably —
/// `.onKeyPress` on a `TextField` swallows arrow keys, so we don't rely on it.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0; clearTransient() } }
    @Published var selection = 0
    @Published var agentOverrideID: UUID?
    @Published var modeOverrideID: UUID?
    @Published var status: String?
    @Published var selectedPromptID: UUID?
    @Published var worktreeRepo: Repo?
    /// When set, the search field captures a one-off prompt for this repo.
    @Published var promptRepo: Repo?

    fileprivate var pendingDangerous: PendingLaunch?

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
        if repo.id == selectedRepo?.id, let override = store.agent(agentOverrideID) { return override }
        if let def = store.agent(repo.defaultAgentID) { return def }
        return store.agents.first
    }

    var isPendingDangerous: Bool { pendingDangerous != nil }

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
        status = nil
        pendingDangerous = nil
        agentOverrideID = nil
        modeOverrideID = nil
        worktreeRepo = nil
        promptRepo = nil
        selectedPromptID = nil
        query = ""
        if store.repos.isEmpty { store.runAutoDiscovery() }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        let chars = event.charactersIgnoringModifiers?.lowercased()
        switch event.keyCode {
        case 125: move(1); return true          // ↓
        case 126: move(-1); return true         // ↑
        case 36, 76: handleReturn(modifiers: mods); return true  // ↩ / ⌅
        case 53: handleEscape(); return true    // esc
        case 48:                                // ⇥ agent / ⇧⇥ mode
            mods.contains(.shift) ? cycleMode() : cycleAgent()
            return true
        default: break
        }
        // ⌘1–⌘9 jump straight to a numbered row and launch it. The numbers shown
        // in the list are this shortcut, not decoration.
        if mods.contains(.command), let c = chars, c.count == 1,
           let digit = Int(c), (1...9).contains(digit) {
            return launchByIndex(digit - 1)
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
        guard filtered.indices.contains(index) else { return false }
        selection = index
        agentOverrideID = nil
        modeOverrideID = nil
        handleReturn(modifiers: [])
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
        if repo.id == selectedRepo?.id,
           let id = modeOverrideID, let m = agent.modes.first(where: { $0.id == id }) { return m }
        if let pinned = repo.defaultModeID, let m = agent.modes.first(where: { $0.id == pinned }) { return m }
        return agent.defaultMode
    }

    func resolveMode(agent: Agent, repo: Repo, modifiers: NSEvent.ModifierFlags) -> RunMode {
        if modifiers.contains(.option), let danger = agent.dangerousMode { return danger }
        if modifiers.contains(.shift) {
            return agent.modes.first { $0.name.lowercased() == "safe" } ?? agent.modes.first ?? .safe()
        }
        return displayMode(agent: agent, repo: repo)
    }

    func previewCommand(repo: Repo, agent: Agent) -> String {
        let mode = resolveMode(agent: agent, repo: repo, modifiers: [])
        return CommandTemplate.preview(agent.commandTemplate,
            context: .init(repo: repo, mode: mode, prompt: nil, branch: nil, remote: nil))
    }

    // MARK: - Worktree mode

    func enterWorktreeMode() {
        guard let repo = selectedRepo else { return }
        guard store.allows(.worktree) else { status = ProFeature.worktree.blurb; return }
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
        do {
            let outcome = try LaunchService.launchInWorktree(
                repo: repo, agent: agent, mode: mode, branch: branch, prompt: selectedPrompt?.text, store: store)
            if let note = outcome.note { status = note } else { onClose() }
        } catch { status = "⚠ \(error)" }
    }

    // MARK: - Prompt mode

    func enterPromptMode() {
        guard let repo = selectedRepo else { return }
        guard store.allows(.promptLibrary) else { status = ProFeature.promptLibrary.blurb; return }
        promptRepo = repo
        query = ""
    }

    func exitPromptMode() { promptRepo = nil; query = "" }

    private func launchWithTypedPrompt() {
        guard let repo = promptRepo, let agent = activeAgent(for: repo) else { return }
        let prompt = query.trimmingCharacters(in: .whitespaces)
        let mode = resolveMode(agent: agent, repo: repo, modifiers: [])
        if mode.isDangerous && !store.allows(.yoloMode) { status = ProFeature.yoloMode.blurb; return }
        perform(repo: repo, agent: agent, mode: mode, prompt: prompt.isEmpty ? nil : prompt)
    }

    // MARK: - Actions

    func handleEscape() {
        if pendingDangerous != nil { clearTransient(); return }
        if worktreeRepo != nil { exitWorktreeMode(); return }
        if promptRepo != nil { exitPromptMode(); return }
        onClose()
    }

    func handleReturn(modifiers mods: NSEvent.ModifierFlags) {
        if promptRepo != nil { launchWithTypedPrompt(); return }
        if worktreeRepo != nil { createWorktreeAndLaunch(); return }
        if let pending = pendingDangerous {
            pendingDangerous = nil
            perform(repo: pending.repo, agent: pending.agent, mode: pending.mode)
            return
        }
        guard let repo = selectedRepo else { return }
        if mods.contains(.command) { openInEditor(repo: repo); return }
        guard let agent = activeAgent(for: repo) else { return }
        let mode = resolveMode(agent: agent, repo: repo, modifiers: mods)

        if mods.contains(.control) { dispatch(repo: repo, agent: agent, mode: mode); return }
        if mode.isDangerous && !store.allows(.yoloMode) { status = ProFeature.yoloMode.blurb; return }
        if mode.isDangerous && store.settings.confirmDangerousModes {
            pendingDangerous = PendingLaunch(repo: repo, agent: agent, mode: mode)
            return
        }
        perform(repo: repo, agent: agent, mode: mode)
    }

    /// Click-to-launch (uses currently held modifiers).
    func activate(at index: Int) {
        selection = index
        handleReturn(modifiers: NSEvent.modifierFlags)
    }

    private func dispatch(repo: Repo, agent: Agent, mode: RunMode) {
        guard store.allows(.dispatch) else { status = ProFeature.dispatch.blurb; return }
        do {
            _ = try DispatchService.shared.dispatch(
                repo: repo, agent: agent, mode: mode, prompt: selectedPrompt?.text, store: store)
            onClose()
        } catch { status = "⚠ dispatch: \(error)" }
    }

    private func openInEditor(repo: Repo) {
        do { try LaunchService.openInEditor(repo: repo, store: store); onClose() }
        catch { status = "⚠ no editor detected — set one in Settings" }
    }

    private func perform(repo: Repo, agent: Agent, mode: RunMode, prompt: String? = nil) {
        do {
            let outcome = try LaunchService.launchAgent(
                repo: repo, agent: agent, mode: mode,
                prompt: prompt ?? selectedPrompt?.text, store: store)
            if let note = outcome.note { status = note } else { onClose() }
        } catch { status = "⚠ \(error)" }
    }
}

// MARK: - View

/// The palette: a terminal HUD held to a strict grid.
///
/// Rules the layout obeys, so that changing one thing doesn't quietly break the
/// rest:
///
/// 1. **The accent means "here, now"** and nothing else — the prompt caret, the
///    selection marker, the selected row's index, the active-mode badge. It is
///    never used for emphasis, decoration, or brand sprinkle. Danger red is the
///    only other color, and it means exactly "this skips permissions".
/// 2. **Every element does work.** The row numbers are ⌘1–⌘9. The result count
///    tells you how much the filter cut. Nothing is here to look like something.
/// 3. **One 8pt module.** Rows are 32, the status line 30, the header 46, and
///    the columns sit on fixed x-positions (`Col`) so the list reads as columns
///    rather than eleven independently-arranged rows.
/// 4. **Repeated ink is deleted.** A path that is the same on every row tells
///    you nothing, so paths appear only on the row you're about to launch.
struct PaletteView: View {
    @ObservedObject private var model: PaletteModel
    let onResize: (CGFloat) -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: Int?
    @State private var shown = false

    /// The grid. Column widths and the gutter between them; the row's leading
    /// inset plus these gives every column a fixed x-position down the list.
    private enum Col {
        static let inset: CGFloat = 14
        static let index: CGFloat = 14
        static let gutter: CGFloat = 10
        /// Where repo names begin — section labels align to it, not to the edge,
        /// so a label sits over the thing it labels.
        static func name(mark: CGFloat) -> CGFloat { inset + index + gutter + mark + gutter }
    }

    private enum Metric {
        static let listPad: CGFloat = 6
        static let corner: CGFloat = 12
        static let maxPanel: CGFloat = 520
        static let minPanel: CGFloat = 120
    }

    // Dynamic Type. Type and the grid scale together, or the panel's computed
    // height stops matching what it actually lays out. Capped at xxLarge below,
    // since a fixed-width HUD can't absorb the accessibility sizes.
    @ScaledMetric(relativeTo: .body) private var headerH: CGFloat = 46
    @ScaledMetric(relativeTo: .body) private var rowH: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var groupLabelH: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var statusLineH: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var fieldSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 12.5
    @ScaledMetric(relativeTo: .body) private var metaSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var labelSize: CGFloat = 9.5
    @ScaledMetric(relativeTo: .body) private var bannerSize: CGFloat = 11.5
    @ScaledMetric(relativeTo: .body) private var bannerH: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 14

    /// The model is owned by the controller (created + monitored at launch) so
    /// the very first summon is already warm.
    init(model: PaletteModel, onResize: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        self.onResize = onResize
    }

    private var accent: Color { model.accent }
    private var isDark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            promptLine
            rule
            content
            if model.isPendingDangerous { confirmBanner }
            else if model.status != nil { statusBanner }
            rule
            statusLine
        }
        .background {
            ZStack {
                GlassBackground(material: isDark ? .hudWindow : .popover)
                // Enough scrim for a HUD's contrast, not so much that the panel
                // stops acknowledging the desktop it's floating over.
                (isDark ? Color.black : Color.white).opacity(isDark ? 0.38 : 0.62)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metric.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.corner, style: .continuous)
                .strokeBorder(isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.12),
                              lineWidth: 1)
        }
        .scaleEffect(shown ? 1 : 0.995, anchor: .top)
        .opacity(shown ? 1 : 0)
        // Scale text with the system size, but cap it so this fixed-width HUD
        // stays usable (accessibility sizes would otherwise overflow the rows).
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onAppear { model.startMonitoring(); model.reset(); searchFocused = true; animateIn(); pushHeight() }
        .onChange(of: model.filtered.count) { _, _ in pushHeight() }
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

    /// Quick fade + a barely-there scale, replayed on every show (skipped if
    /// Reduce Motion). A launcher that announces itself gets tiring.
    private func animateIn() {
        if reduceMotion { shown = true; return }
        shown = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) { shown = true }
        }
    }

    // MARK: - Panel sizing

    /// Height is derived from the grid, not measured, so the resize is exact and
    /// can never oscillate against SwiftUI's own layout pass.
    private func pushHeight() {
        onResize(min(max(naturalHeight, Metric.minPanel), Metric.maxPanel))
    }

    private var naturalHeight: CGFloat {
        var h = headerH + 1 + 1 + statusLineH
        if model.isPendingDangerous || model.status != nil { h += bannerHeight }
        // The side panels are a fixed block of explanatory text; the worktree
        // one grows by a line once there's a path to preview.
        if model.worktreeRepo != nil {
            return h + (model.worktreePreviewPath() == nil ? 108 : 128)
        }
        if model.promptRepo != nil { return h + 108 }
        let rows = model.filtered.count
        if rows == 0 { return h + 96 }
        h += Metric.listPad * 2
        h += CGFloat(rows) * rowH
        h += CGFloat(groupLabelCount) * groupLabelH
        return h
    }

    /// Banners wrap, so allow two lines' worth rather than guessing one.
    private var bannerHeight: CGFloat { bannerH }

    private var groupLabelCount: Int {
        guard model.query.isEmpty else { return 0 }
        let repos = model.filtered
        guard !repos.isEmpty else { return 0 }
        let pinned = repos.contains(where: { $0.pinned })
        let loose = repos.contains(where: { !$0.pinned })
        return (pinned ? 1 : 0) + (loose ? 1 : 0)
    }

    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
    }

    // MARK: - Prompt line

    /// A shell prompt, not a search box: the prefix names the mode you're in, so
    /// worktree and prompt modes don't need a separate banner to explain
    /// themselves.
    private var promptLine: some View {
        HStack(spacing: 0) {
            Text(promptPrefix)
                .font(.system(size: nameSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.38))
                .accessibilityHidden(true)
            Text(" ❯ ")
                .font(.system(size: nameSize, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: fieldSize, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.95))
                .focused($searchFocused)
                .accessibilityLabel("Search repositories")
            // How much the filter cut. Only shown while filtering, because
            // "11 of 11" is not information.
            if !model.query.isEmpty, model.worktreeRepo == nil, model.promptRepo == nil {
                Text("\(model.filtered.count)")
                    .font(.system(size: metaSize, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.3))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Col.inset)
        .frame(height: headerH)
    }

    private var promptPrefix: String {
        if model.worktreeRepo != nil { return "worktree" }
        if model.promptRepo != nil { return "prompt" }
        return "tintpad"
    }

    private var placeholder: String {
        if let wt = model.worktreeRepo { return "branch name for \(wt.name)" }
        if let pr = model.promptRepo { return "prompt for \(pr.name)" }
        return "repo"
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
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
            repoList
        }
    }

    private func sidePanel(title: String, body: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.1)
                .foregroundStyle(accent)
            Text(body)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.38))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Col.inset)
        .padding(.vertical, 18)
    }

    private var repoList: some View {
        // Snapshot once per render: avoids re-sorting on every row access, and
        // gives the ForEach and selection a single consistent list.
        let repos = model.filtered
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Index identity throughout (id: \.self == .id(index) == selection),
                    // so a selection change updates the row in place instead of being
                    // mis-diffed as a remove/insert (which read as a "deselect").
                    ForEach(repos.indices, id: \.self) { index in
                        if let header = groupHeader(at: index, in: repos) { sectionLabel(header) }
                        row(repos[index], index: index,
                            selected: index == model.selection, hovered: hovered == index)
                            .id(index)
                            .contentShape(Rectangle())
                            .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
                            .onTapGesture { model.activate(at: index) }
                    }
                    if repos.isEmpty { emptyState }
                }
                .padding(.vertical, Metric.listPad)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, new in
                let scroll = { proxy.scrollTo(new, anchor: .center) }
                reduceMotion ? scroll() : withAnimation(.easeOut(duration: 0.14), scroll)
            }
        }
    }

    /// "Pinned" before the first pinned repo, "Recent" before the first
    /// non-pinned one. Suppressed while filtering, where rank is the only order
    /// that matters.
    private func groupHeader(at index: Int, in list: [Repo]) -> String? {
        guard model.query.isEmpty, index < list.count else { return nil }
        let repo = list[index]
        if index == 0 { return repo.pinned ? "pinned" : "recent" }
        if list[index - 1].pinned && !repo.pinned { return "recent" }
        return nil
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: labelSize, weight: .semibold, design: .monospaced))
            .tracking(0.12)
            .foregroundStyle(.primary.opacity(0.26))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Col.name(mark: markSize))
            .padding(.bottom, 3)
            // Exactly `groupLabel` tall including the padding, or the panel's
            // computed height comes up short and clips the last row.
            .frame(height: groupLabelH, alignment: .bottom)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        Text(model.allRepos.isEmpty
             ? "no repos — ⌘R to scan, or add roots in settings"
             : "no match: \(model.query)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.4))
            .frame(height: 96)
    }

    // MARK: - Row

    private func row(_ repo: Repo, index: Int, selected: Bool, hovered: Bool) -> some View {
        let agent = model.activeAgent(for: repo)
        let mode = agent.map { model.displayMode(agent: $0, repo: repo) }
        let dangerous = mode?.isDangerous == true
        return HStack(spacing: Col.gutter) {
            // ⌘1–⌘9. Past nine there's no shortcut, so there's no number.
            Text(index < 9 ? "\(index + 1)" : "")
                .font(.system(size: metaSize, weight: .medium, design: .monospaced))
                .foregroundStyle(selected ? here(dangerous) : .primary.opacity(0.22))
                .monospacedDigit()
                .frame(width: Col.index, alignment: .trailing)
                .accessibilityHidden(true)
            AgentMark(agent: agent,
                      tint: agent?.tintHex.flatMap(Color.init(hex:)) ?? accent,
                      monogram: model.monogram(for: agent),
                      selected: selected, dark: isDark, size: markSize)
                .accessibilityHidden(true)
            Text(repo.name)
                .font(.system(size: nameSize, weight: selected ? .semibold : .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(selected ? 1 : 0.72))
                .lineLimit(1)
                .layoutPriority(2)
            if repo.pinned {
                Circle()
                    .fill(.primary.opacity(selected ? 0.5 : 0.28))
                    .frame(width: 3.5, height: 3.5)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: Col.gutter)
            // The path is the expensive ink: it only appears on the row you are
            // about to launch, where it answers "which one is this".
            if selected {
                Text(displayPath(repo.path))
                    .font(.system(size: metaSize, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.38))
                    .lineLimit(1).truncationMode(.head)
                    .layoutPriority(-1)
                if let agent {
                    Text(agent.name.lowercased())
                        .font(.system(size: metaSize, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.5))
                        .lineLimit(1)
                }
            }
            if dangerous, let mode {
                Text(mode.name.lowercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.06)
                    .foregroundStyle(dangerTint)
            }
        }
        .padding(.horizontal, Col.inset)
        .frame(height: rowH)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Color.primary.opacity(selected ? (isDark ? 0.075 : 0.085)
                                               : (hovered ? 0.035 : 0))
                // The whole selection signal, in 3 points: a precise marker at a
                // fixed x, not a saturated bar across the row.
                if selected {
                    Rectangle().fill(here(dangerous)).frame(width: 3)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(repo: repo, agent: agent, mode: mode, index: index))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The colour of the "you are here" marker. It turns red when *here* is a
    /// mode that skips permissions, so the indicator telling you where you are
    /// also tells you what pressing ↵ will do.
    private func here(_ dangerous: Bool) -> Color { dangerous ? dangerTint : accent }

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
                .font(.system(size: bannerSize, weight: .bold, design: .monospaced))
            Text("↵ again to launch \(model.pendingDangerousDescription ?? "") — skips all permissions")
                .font(.system(size: bannerSize, design: .monospaced))
            Spacer(minLength: 8)
            Text("esc cancels")
                .font(.system(size: bannerSize, design: .monospaced))
                .foregroundStyle(dangerTint.opacity(0.65))
        }
        .foregroundStyle(dangerTint)
        .padding(.horizontal, Col.inset)
        .frame(height: bannerHeight)
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
                    .font(.system(size: bannerSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(isError ? dangerTint : accent)
                Text(text)
                    .font(.system(size: bannerSize, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Col.inset)
            .frame(minHeight: bannerHeight, alignment: .center)
            .background((isError ? dangerTint : accent).opacity(0.11))
        }
    }

    // MARK: - Status line

    /// One line, no keycap boxes. A mode badge appears only when you are *not*
    /// in the normal list, because labelling the default state is noise.
    private var statusLine: some View {
        HStack(spacing: 0) {
            if let badge = modeBadge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.1)
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background(model.isPendingDangerous ? dangerTint : accent,
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(.trailing, 12)
            }
            HStack(spacing: 15) {
                ForEach(keyHints, id: \.key) { hint in
                    KeyHint(key: hint.key, label: hint.label, action: hint.action)
                }
            }
            Spacer(minLength: 12)
            trailingContext
        }
        .padding(.horizontal, Col.inset)
        .frame(height: statusLineH)
    }

    private var modeBadge: String? {
        if model.isPendingDangerous { return "CONFIRM" }
        if model.worktreeRepo != nil { return "WORKTREE" }
        if model.promptRepo != nil { return "PROMPT" }
        return nil
    }

    private struct Hint { let key: String; let label: String; let action: () -> Void }

    private var keyHints: [Hint] {
        if model.isPendingDangerous {
            return [Hint(key: "↵", label: "confirm") { model.handleReturn(modifiers: []) },
                    Hint(key: "esc", label: "cancel") { model.handleEscape() }]
        }
        if model.worktreeRepo != nil {
            return [Hint(key: "↵", label: "create") { model.handleReturn(modifiers: []) },
                    Hint(key: "esc", label: "back") { model.handleEscape() }]
        }
        if model.promptRepo != nil {
            return [Hint(key: "↵", label: "launch") { model.handleReturn(modifiers: []) },
                    Hint(key: "esc", label: "back") { model.handleEscape() }]
        }
        return [
            Hint(key: "↵", label: "launch") { model.handleReturn(modifiers: []) },
            Hint(key: "⌘1–9", label: "jump") { },
            Hint(key: "⇥", label: "agent") { model.cycleAgent() },
            Hint(key: "⇧⇥", label: "mode") { model.cycleMode() },
            Hint(key: "⌘L", label: "prompt") { model.enterPromptMode() },
        ]
    }

    @ViewBuilder private var trailingContext: some View {
        HStack(spacing: 10) {
            if let prompt = model.selectedPrompt {
                Text(prompt.title.lowercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
            if let repo = model.selectedRepo, let branch = GitInfo.currentBranch(at: repo.path) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5, weight: .medium))
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(.primary.opacity(0.33))
                .lineLimit(1)
                .accessibilityLabel("On branch \(branch)")
            }
        }
    }
}

/// A status-line hint. No box, no capsule: the glyph and its label are the whole
/// control. Clicking still works — hover just brightens the label, which is all
/// the affordance a line this quiet should carry.
private struct KeyHint: View {
    let key: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(hovering ? 0.75 : 0.5))
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary.opacity(hovering ? 0.55 : 0.32))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(key)")
        // Hover highlight only — no manual NSCursor.set(), which can leave a
        // stray cursor if the panel closes mid-hover.
        .onHover { hovering = $0 }
    }
}
