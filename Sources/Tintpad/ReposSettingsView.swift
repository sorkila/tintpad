import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReposSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var scanResult: String?

    var body: some View {
        VStack(spacing: 0) {
            rootFoldersSection
            Divider()
            repoListSection
            Divider()
            toolbar
        }
    }

    // MARK: - Root folders

    private var rootFoldersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scan roots").font(.headline)
                Spacer()
                Button { addRootFolder() } label: { Image(systemName: "plus") }
                    .help("Add a folder to auto-scan for repos")
            }
            if store.settings.rootScanFolders.isEmpty {
                Text("No scan roots — add ~/repos or ~/Developer.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.settings.rootScanFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(folder).font(.system(.caption, design: .monospaced)).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button { removeRoot(folder) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Repo list

    private var repoListSection: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.repos) { repo in
                    RepoRow(store: store, repo: repo)
                    Divider()
                }
                if store.repos.isEmpty {
                    Text("Drop a repo folder here, or press “Scan now”.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 50)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
    }

    private var toolbar: some View {
        HStack {
            Button("Add Repo…") { addRepoFolder() }
            Button("Scan now") {
                let n = store.runAutoDiscovery()
                scanResult = "Added \(n) repo\(n == 1 ? "" : "s")."
            }
            if let scanResult {
                Text(scanResult).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.repos.count) repos").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
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
            Button { toggle(\.pinned) } label: {
                Image(systemName: repo.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(repo.pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(repo.pinned ? "Unpin" : "Pin to top")

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.body.weight(.medium))
                Text(repo.path).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()

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
