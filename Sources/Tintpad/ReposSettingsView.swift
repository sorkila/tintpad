import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReposSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var scanResult: String?

    var body: some View {
        SettingsScroll {
            SettingsCard("Scan roots", trailing: AnyView(
                Button { addRootFolder() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add a folder to auto-scan for repos"))) {
                if store.settings.rootScanFolders.isEmpty {
                    Text("No scan roots — add ~/repos or ~/Developer.")
                        .font(.callout).foregroundStyle(.secondary).padding(14)
                } else {
                    ForEach(Array(store.settings.rootScanFolders.enumerated()), id: \.element) { i, folder in
                        if i > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(folder).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { removeRoot(folder) } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
            }

            SettingsCard("Repositories · \(store.repos.count)", trailing: AnyView(HStack(spacing: 10) {
                if let scanResult { Text(scanResult).font(.caption).foregroundStyle(.secondary) }
                Button("Add…") { addRepoFolder() }
                Button("Scan") { let n = store.runAutoDiscovery(); scanResult = "+\(n)" }
            })) {
                if store.repos.isEmpty {
                    EmptyStateView(icon: "folder.badge.plus", title: "No repositories yet",
                                   subtitle: "Drop a folder here, or Scan your roots.")
                } else {
                    ForEach(Array(store.repos.enumerated()), id: \.element.id) { i, repo in
                        if i > 0 { Divider() }
                        RepoRow(store: store, repo: repo)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
    }

    // MARK: - Actions

    private func addRepoFolder() {
        guard let url = chooseFolder() else { return }
        store.addRepo(path: url.path, via: .manual)
    }

    private func addRootFolder() {
        guard let url = chooseFolder() else { return }
        if !store.settings.rootScanFolders.contains(url.path) {
            store.settings.rootScanFolders.append(url.path)
            store.save()
        }
    }

    private func removeRoot(_ folder: String) {
        store.settings.rootScanFolders.removeAll { $0 == folder }
        store.save()
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath else { return }
                Task { @MainActor in store.addRepo(path: url.path, via: .manual) }
            }
            handled = true
        }
        return handled
    }
}

// MARK: - Repo row

private struct RepoRow: View {
    @ObservedObject var store: AppStore
    let repo: Repo

    private var agent: Agent? {
        store.agent(repo.defaultAgentID) ?? store.agents.first
    }

    var body: some View {
        HStack(spacing: 12) {
            AgentBrandIcon(agent: agent,
                           tint: agent?.tintHex.flatMap(Color.init(hex:)) ?? .accentColor,
                           selected: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.body.weight(.medium))
                Text(displayPath(repo.path)).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()

            Button { toggle(\.pinned) } label: {
                Image(systemName: repo.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(repo.pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(repo.pinned ? "Unpin" : "Pin to top")

            Picker("", selection: agentBinding) {
                Text("—").tag(UUID?.none)
                ForEach(store.agents) { a in Text(a.name).tag(Optional(a.id)) }
            }
            .labelsHidden().frame(width: 130)

            Picker("", selection: modeBinding) {
                Text("default").tag(UUID?.none)
                ForEach(agent?.modes ?? []) { m in Text(m.name).tag(Optional(m.id)) }
            }
            .labelsHidden().frame(width: 100)

            Button { store.removeRepo(repo.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func toggle(_ kp: WritableKeyPath<Repo, Bool>) {
        var r = repo; r[keyPath: kp].toggle(); store.updateRepo(r)
    }

    private var agentBinding: Binding<UUID?> {
        Binding(get: { repo.defaultAgentID }, set: { var r = repo; r.defaultAgentID = $0; r.defaultModeID = nil; store.updateRepo(r) })
    }

    private var modeBinding: Binding<UUID?> {
        Binding(get: { repo.defaultModeID }, set: { var r = repo; r.defaultModeID = $0; store.updateRepo(r) })
    }
}
