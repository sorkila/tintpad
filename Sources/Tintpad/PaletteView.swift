import AppKit
import SwiftUI

// MARK: - Spike model

struct RunMode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let flags: String
    let isDangerous: Bool
}

struct Agent: Identifiable, Hashable {
    let id = UUID()
    let name: String
    /// Binary name to resolve via the login-shell PATH, e.g. "claude".
    let binary: String
    let modes: [RunMode]
}

struct Repo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
}

// MARK: - Discovery (spike: scan one root, one level deep)

enum RepoDiscovery {
    static func scan() -> [Repo] {
        let fm = FileManager.default
        let roots = [
            "\(NSHomeDirectory())/Documents/Repositories",
            "\(NSHomeDirectory())/Developer",
            "\(NSHomeDirectory())/repos",
        ]
        var repos: [Repo] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() {
                let path = "\(root)/\(entry)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if fm.fileExists(atPath: "\(path)/.git") {
                    repos.append(Repo(name: entry, path: path))
                }
            }
        }
        return repos
    }
}

// MARK: - Palette

struct PaletteView: View {
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var repos: [Repo] = []
    @State private var status: String?

    // Spike: one agent with the canonical three modes.
    private let agent = Agent(
        name: "Claude Code",
        binary: "claude",
        modes: [
            RunMode(name: "Safe", flags: "", isDangerous: false),
            RunMode(name: "Default", flags: "", isDangerous: false),
            RunMode(name: "YOLO", flags: "--dangerously-skip-permissions", isDangerous: true),
        ]
    )

    private let accent = Color(red: 1.0, green: 0.45, blue: 0.20)   // signal orange
    private let danger = Color(red: 1.0, green: 0.35, blue: 0.35)   // coral

    private var filtered: [Repo] {
        guard !query.isEmpty else { return repos }
        let q = query.lowercased()
        return repos.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    private var selectedRepo: Repo? {
        let list = filtered
        guard !list.isEmpty else { return nil }
        return list[min(selection, list.count - 1)]
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
        .onAppear { repos = RepoDiscovery.scan() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.4))
            TextField("search a repo…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .onChange(of: query) { _, _ in selection = 0 }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onKeyPress(.return) { launch(mode: defaultMode, withOption: optionDown()); return .handled }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, repo in
                        row(repo, selected: index == selection)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                launch(mode: defaultMode, withOption: optionDown())
                            }
                    }
                    if filtered.isEmpty {
                        Text("no repos found — add ~/Documents/Repositories, ~/Developer, or ~/repos")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.vertical, 40)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func row(_ repo: Repo, selected: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent)
                .frame(width: 3, height: 22)
                .opacity(selected ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                Text(repo.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(agent.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(accent.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.white.opacity(0.06) : .clear)
        )
    }

    private var footer: some View {
        HStack(spacing: 14) {
            keycap("↵", "launch")
            keycap("⌥↵", "YOLO")
            keycap("esc", "close")
            Spacer()
            if let status {
                Text(status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.middle)
            } else if let repo = selectedRepo {
                Text(previewCommand(for: repo, mode: defaultMode))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func keycap(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Behavior

    private var defaultMode: RunMode { agent.modes[1] }   // "Default"
    private var yoloMode: RunMode { agent.modes[2] }

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func optionDown() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private func previewCommand(for repo: Repo, mode: RunMode) -> String {
        let flags = mode.flags.isEmpty ? "" : " \(mode.flags)"
        return "cd \(repo.name) && \(agent.binary)\(flags)"
    }

    private func launch(mode: RunMode, withOption: Bool) {
        let resolvedMode = withOption ? yoloMode : mode
        guard let repo = selectedRepo else { return }
        guard let binary = ShellEnvironment.resolveBinary(agent.binary) else {
            status = "⚠ \(agent.binary) not found on PATH — re-scan agents"
            return
        }
        let flags = resolvedMode.flags.isEmpty ? "" : " \(resolvedMode.flags)"
        let command = "\(binary)\(flags)"
        let terminal = TerminalRegistry.preferred
        do {
            try terminal.launch(TerminalLaunch(workingDirectory: repo.path, command: command))
            onClose()
        } catch {
            status = "⚠ \(terminal.displayName): \(error)"
        }
    }
}
