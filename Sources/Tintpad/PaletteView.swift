import AppKit
import SwiftUI

struct PaletteView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    /// Override of the active agent for this launch (nil = repo default / first).
    @State private var agentOverrideID: UUID?
    @State private var status: String?
    /// When a dangerous mode needs confirmation, the pending launch is parked here.
    @State private var pendingDangerous: PendingLaunch?

    private struct PendingLaunch { let repo: Repo; let agent: Agent; let mode: RunMode }

    private var accent: Color { store.settings.tintAccent.color }

    private var orderedRepos: [Repo] { store.orderedRepos() }

    private var filtered: [Repo] {
        guard !query.isEmpty else { return orderedRepos }
        let q = query.lowercased()
        return orderedRepos.filter {
            $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    private var selectedRepo: Repo? {
        let list = filtered
        guard !list.isEmpty else { return nil }
        return list[min(selection, list.count - 1)]
    }

    private func activeAgent(for repo: Repo) -> Agent? {
        if let override = store.agent(agentOverrideID) { return override }
        if let def = store.agent(repo.defaultAgentID) { return def }
        return store.agents.first
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Color.white.opacity(0.06))
            resultList
            Divider().overlay(Color.white.opacity(0.06))
            footer
        }
        .background(Color(red: 0.055, green: 0.055, blue: 0.055))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            if store.repos.isEmpty { store.runAutoDiscovery() }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
            TextField("search a repo…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, design: .monospaced))
                .foregroundStyle(.white)
                .onChange(of: query) { _, _ in selection = 0; clearTransient() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { handleEscape(); return .handled }
                .onKeyPress(.tab) { cycleAgent(); return .handled }
                .onKeyPress(.return) { handleReturn(); return .handled }
                .onKeyPress(keys: ["r"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    let n = store.runAutoDiscovery()
                    status = "scanned — \(n) new repo\(n == 1 ? "" : "s")"
                    return .handled
                }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    // MARK: - Results

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, repo in
                        row(repo, selected: index == selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = index; handleReturn() }
                    }
                    if filtered.isEmpty { emptyState }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        Text(store.repos.isEmpty
             ? "no repos yet — ⌘R to scan, or add roots in Settings"
             : "no match for “\(query)”")
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.white.opacity(0.3))
            .padding(.vertical, 40)
    }

    private func row(_ repo: Repo, selected: Bool) -> some View {
        let agent = activeAgent(for: repo)
        let agentTint = agent?.tintHex.flatMap(Color.init(hex:)) ?? accent
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent).frame(width: 3, height: 24)
                .opacity(selected ? 1 : 0)
            if repo.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(accent.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                Text(repo.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let agent {
                Text(agent.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(agentTint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(agentTint.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.06) : .clear))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if pendingDangerous != nil {
                keycap("↵", "confirm").foregroundStyle(dangerTint)
                keycap("esc", "cancel")
            } else {
                keycap("↵", "launch")
                keycap("⌥↵", "YOLO")
                keycap("⇧↵", "safe")
                keycap("⇥", "agent")
            }
            Spacer()
            statusOrPreview
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var statusOrPreview: some View {
        if let pending = pendingDangerous {
            Label("\(pending.agent.name) · \(pending.mode.name)", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(dangerTint)
        } else if let status {
            Text(status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1).truncationMode(.middle)
        } else if let repo = selectedRepo, let agent = activeAgent(for: repo) {
            let mode = resolveMode(agent: agent, repo: repo, modifiers: [])
            HStack(spacing: 8) {
                if let branch = GitInfo.currentBranch(at: repo.path) {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(CommandTemplate.preview(agent.commandTemplate,
                    context: .init(repo: repo, mode: mode, prompt: nil, branch: nil, remote: nil)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1).truncationMode(.head)
            }
        }
    }

    private func keycap(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Behavior

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
        clearTransient()
    }

    private func cycleAgent() {
        guard !store.agents.isEmpty, let repo = selectedRepo,
              let current = activeAgent(for: repo),
              let idx = store.agents.firstIndex(where: { $0.id == current.id }) else { return }
        agentOverrideID = store.agents[(idx + 1) % store.agents.count].id
        clearTransient()
    }

    private func clearTransient() {
        status = nil
        pendingDangerous = nil
    }

    /// Resolve the run mode from modifier keys: ⌥ → dangerous, ⇧ → safe,
    /// otherwise the repo override or the agent's default.
    private func resolveMode(agent: Agent, repo: Repo, modifiers: NSEvent.ModifierFlags) -> RunMode {
        if modifiers.contains(.option), let danger = agent.dangerousMode { return danger }
        if modifiers.contains(.shift) {
            return agent.modes.first { $0.name.lowercased() == "safe" } ?? agent.modes.first ?? .safe()
        }
        if let pinned = repo.defaultModeID, let m = agent.modes.first(where: { $0.id == pinned }) { return m }
        return agent.defaultMode
    }

    private func handleEscape() {
        if pendingDangerous != nil { clearTransient(); return }
        onClose()
    }

    private func handleReturn() {
        // Second confirmation for a parked dangerous launch.
        if let pending = pendingDangerous {
            pendingDangerous = nil
            perform(repo: pending.repo, agent: pending.agent, mode: pending.mode)
            return
        }
        guard let repo = selectedRepo, let agent = activeAgent(for: repo) else { return }
        let mode = resolveMode(agent: agent, repo: repo, modifiers: NSEvent.modifierFlags)

        if mode.isDangerous && store.settings.confirmDangerousModes {
            pendingDangerous = PendingLaunch(repo: repo, agent: agent, mode: mode)
            return
        }
        perform(repo: repo, agent: agent, mode: mode)
    }

    private func perform(repo: Repo, agent: Agent, mode: RunMode) {
        let git = GitInfo.read(at: repo.path)
        let ctx = CommandTemplate.Context(
            repo: repo, mode: mode, prompt: nil, branch: git.branch, remote: git.remoteURL)
        let command: String
        do {
            command = try CommandTemplate.resolved(agent.commandTemplate, context: ctx)
        } catch {
            status = "⚠ \(error)"
            return
        }
        let terminal = TerminalRegistry.preferred(settings: store.settings)
        do {
            let outcome = try terminal.launch(TerminalLaunch(workingDirectory: repo.path, command: command))
            store.recordLaunch(repoID: repo.id)
            if let note = outcome.note {
                status = note   // e.g. Warp clipboard fallback — keep palette open
            } else {
                onClose()
            }
        } catch {
            status = "⚠ \(terminal.displayName): \(error)"
        }
    }
}
