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
        if let override = store.agent(agentOverrideID) { return override }
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

    // MARK: - Navigation

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
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
        if let id = modeOverrideID, let m = agent.modes.first(where: { $0.id == id }) { return m }
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

struct PaletteView: View {
    @StateObject private var model: PaletteModel
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Int?
    @State private var shown = false
    private let corner: CGFloat = 18

    init(store: AppStore, onClose: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PaletteModel(
            store: store, onClose: onClose, onOpenSettings: onOpenSettings))
    }

    private var accent: Color { model.accent }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            hairline
            resultList
            if model.isPendingDangerous { confirmBanner }
            hairline
            footer
        }
        .background {
            // Glass, but with a strong dark scrim so text stays high-contrast
            // over bright backgrounds behind the panel.
            ZStack { GlassBackground(); Color.black.opacity(0.5) }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.05), .white.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        }
        .scaleEffect(shown ? 1 : 0.985, anchor: .top)
        .opacity(shown ? 1 : 0)
        .onAppear { model.startMonitoring(); model.reset(); searchFocused = true; animateIn() }
        .onReceive(NotificationCenter.default.publisher(for: .tintpadPanelDidShow)) { _ in
            model.reset()
            searchFocused = true
            animateIn()
        }
    }

    /// Quick scale + fade summon, replayed on every show (skipped if Reduce Motion).
    private func animateIn() {
        if reduceMotion { shown = true; return }
        shown = false
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) { shown = true }
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }

    private var confirmBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Press ↵ again to launch \(model.pendingDangerousDescription ?? "") — skips all permissions")
                .fontWeight(.medium)
            Spacer()
            Text("esc to cancel").foregroundStyle(dangerTint.opacity(0.7))
        }
        .font(.system(size: 12))
        .foregroundStyle(dangerTint)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(dangerTint.opacity(0.12))
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 11) {
            Image(systemName: searchIcon)
                .font(.system(size: 14))
                .foregroundStyle(model.worktreeRepo == nil && model.promptRepo == nil ? .white.opacity(0.3) : accent)
            TextField(searchPlaceholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .focused($searchFocused)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var searchIcon: String {
        if model.worktreeRepo != nil { return "arrow.triangle.branch" }
        if model.promptRepo != nil { return "text.bubble" }
        return "magnifyingglass"
    }

    private var searchPlaceholder: String {
        if let wt = model.worktreeRepo { return "New branch in \(wt.name)…" }
        if let pr = model.promptRepo { return "Prompt for \(pr.name)… (↵ to launch)" }
        return "Search a repo…"
    }

    // MARK: - Results

    @ViewBuilder private var resultList: some View {
        if let wt = model.worktreeRepo {
            worktreePanel(wt)
        } else if let pr = model.promptRepo {
            promptPanel(pr)
        } else {
            repoResults
        }
    }

    private func promptPanel(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Starting prompt", systemImage: "text.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
            Text("Type a one-off prompt to hand \(repo.name) to \(model.activeAgent(for: repo)?.name ?? "the agent"). Press ↵ to launch, esc to cancel.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private func worktreePanel(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("New worktree", systemImage: "arrow.triangle.branch")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
            Text("Creates an isolated checkout of \(repo.name) on a new branch, then launches the agent there.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
            if let path = model.worktreePreviewPath() {
                Text("→ \(displayPath(path))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var repoResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, repo in
                        if let header = groupHeader(at: index, repo: repo) { sectionHeader(header) }
                        row(repo, selected: index == model.selection, hovered: hovered == index)
                            .id(index)
                            .contentShape(Rectangle())
                            .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
                            .onTapGesture { model.activate(at: index) }
                    }
                    if model.filtered.isEmpty { emptyState }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            .onChange(of: model.selection) { _, new in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Section label shown when the list is unfiltered: "Pinned" before the
    /// first pinned repo, "Recent" before the first non-pinned one.
    private func groupHeader(at index: Int, repo: Repo) -> String? {
        guard model.query.isEmpty else { return nil }
        let list = model.filtered
        if index == 0 { return repo.pinned ? "Pinned" : "Recent" }
        let prevPinned = list[index - 1].pinned
        if prevPinned && !repo.pinned { return "Recent" }
        return nil
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 3)
    }

    private var emptyState: some View {
        Text(model.allRepos.isEmpty
             ? "No repos yet — ⌘R to scan, or add roots in Settings"
             : "No match for “\(model.query)”")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white.opacity(0.3))
            .padding(.vertical, 40)
    }

    private func row(_ repo: Repo, selected: Bool, hovered: Bool = false) -> some View {
        let agent = model.activeAgent(for: repo)
        let agentTint = agent?.tintHex.flatMap(Color.init(hex:)) ?? accent
        let mode = agent.map { model.displayMode(agent: $0, repo: repo) }
        // Show the mode chip when selected, or when this repo's default mode is
        // notable (dangerous, or an explicit non-Default pin) — so YOLO repos
        // are visible at a glance.
        let showMode = mode.map { m in
            selected || m.isDangerous || (repo.defaultModeID != nil && m.name.lowercased() != "default")
        } ?? false
        return HStack(spacing: 11) {
            AgentBrandIcon(agent: agent, tint: agentTint, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(repo.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                    if repo.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(accent.opacity(0.8))
                    }
                }
                Text(displayPath(repo.path))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(selected ? 0.4 : 0.3))
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 12)
            if selected, let agent {
                Text(agent.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if showMode, let mode { modeChip(mode) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(selected ? 0.10 : (hovered ? 0.05 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.08 : 0), lineWidth: 1))
        }
    }

    private func modeChip(_ mode: RunMode) -> some View {
        let color = mode.isDangerous ? dangerTint : Color.white
        return Text(mode.name.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(mode.isDangerous ? dangerTint : .white.opacity(0.7))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(mode.isDangerous ? 0.16 : 0.10), in: Capsule())
    }

    /// Abbreviate the home directory to `~` for a calmer path.
    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            if model.isPendingDangerous {
                FooterButton(key: "↵", label: "confirm", danger: true) { model.handleReturn(modifiers: []) }
                FooterButton(key: "esc", label: "cancel") { model.handleEscape() }
            } else if model.worktreeRepo != nil {
                FooterButton(key: "↵", label: "create + launch") { model.handleReturn(modifiers: []) }
                FooterButton(key: "esc", label: "back") { model.handleEscape() }
            } else if model.promptRepo != nil {
                FooterButton(key: "↵", label: "launch with prompt") { model.handleReturn(modifiers: []) }
                FooterButton(key: "esc", label: "back") { model.handleEscape() }
            } else {
                FooterButton(key: "↵", label: "launch") { model.handleReturn(modifiers: []) }
                FooterButton(key: "⇥", label: "agent") { model.cycleAgent() }
                FooterButton(key: "⇧⇥", label: "mode") { model.cycleMode() }
                FooterButton(key: "⌘L", label: "prompt") { model.enterPromptMode() }
                FooterButton(key: "⌘↵", label: "editor") { model.handleReturn(modifiers: .command) }
            }
            Spacer(minLength: 12)
            statusOrPreview
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var statusOrPreview: some View {
        if let status = model.status {
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1).truncationMode(.middle)
        } else if let repo = model.selectedRepo {
            HStack(spacing: 9) {
                if let prompt = model.selectedPrompt {
                    Label(prompt.title, systemImage: "text.bubble")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(accent)
                }
                if let branch = GitInfo.currentBranch(at: repo.path) {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        }
    }

}

/// A clickable footer hint: a keycap glyph + label that also runs its action on
/// click, with a hover highlight and pointing-hand cursor.
private struct FooterButton: View {
    let key: String
    let label: String
    var danger: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(danger ? dangerTint : .white.opacity(0.85))
                    .frame(minWidth: 15)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(danger ? dangerTint.opacity(0.9) : .white.opacity(0.5))
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}
