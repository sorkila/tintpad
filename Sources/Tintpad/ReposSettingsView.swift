import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReposSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var scanResult: String?
    @State private var scanClear: Task<Void, Never>?
    // Paired with the mono value chip so it keeps fitting at accessibility
    // sizes (a11y #3).
    @ScaledMetric(relativeTo: .callout) private var chipWidth: CGFloat = 48

    var body: some View {
        SettingsScroll {
            SettingsCard("Scan roots", trailing: AnyView(
                Button { addRootFolder() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add a folder to auto-scan for repos"))) {
                if store.settings.rootScanFolders.isEmpty {
                    Text("No scan roots, add ~/repos or ~/Developer.")
                        .font(.callout).foregroundStyle(.secondary).padding(14)
                } else {
                    ForEach(Array(store.settings.rootScanFolders.enumerated()), id: \.element) { i, folder in
                        if i > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(folder).font(.monoStyle(.caption)).lineLimit(1).truncationMode(.middle)
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
                Button("Scan") { scan() }
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

            // Ranking lives beside the list it orders.
            SettingsCard("Ranking") {
                VStack(alignment: .leading, spacing: 6) {
                    slider("Frecency half-life", value: store.bind(\.frecencyHalfLifeDays), range: 3...90, unit: "d", snap: 1)
                    Text("How fast a repo's ranking decays. Shorter, recency wins. Longer, frequency wins.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
    }

    // MARK: - Actions

    /// Says what the scan did in words, then clears after two seconds. A new
    /// scan cancels the pending clear so it cannot wipe the fresh result.
    private func scan() {
        scanClear?.cancel()
        let n = store.runAutoDiscovery()
        scanResult = "Scanned, \(n) new repo\(n == 1 ? "" : "s")"
        scanClear = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            scanResult = nil
        }
    }

    /// A clean tinted slider (no tick marks) with a value chip, snaps on release.
    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String, snap: Double) -> some View {
        LabeledContent(title) {
            HStack(spacing: 14) {
                Slider(value: value, in: range) { editing in
                    if !editing { value.wrappedValue = (value.wrappedValue / snap).rounded() * snap }
                }
                .tint(.gray)   // monochrome controls, like the drop
                Text("\(Int((value.wrappedValue / snap).rounded() * snap))\(unit)")
                    .font(TypeRamp.mono.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: chipWidth, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

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
            // The row identifies a repo, so it wears the repo's short name in
            // the same grammar as the drop's tokens. The agent is already
            // named in the picker beside it.
            RepoTintBadge(name: repo.name)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.body.weight(.medium))
                Text(displayPath(repo.path)).font(.monoStyle(.caption))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()

            Button { toggle(\.pinned) } label: {
                Image(systemName: repo.pinned ? "pin.fill" : "pin")
                    // Ink, not color: `.accentColor` here was the *system*
                    // accent, so a user's blue or pink leaked into a room the
                    // product paints black and white. On/off is weight.
                    .foregroundStyle(repo.pinned ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(repo.pinned ? "Unpin" : "Pin to top")

            Picker("", selection: agentBinding) {
                Text("Remembers last").tag(UUID?.none)
                ForEach(store.agents) { a in Text(a.name).tag(Optional(a.id)) }
            }
            .labelsHidden().frame(width: 130)

            Picker("", selection: modeBinding) {
                Text("Remembers last").tag(UUID?.none)
                ForEach(agent?.modes ?? []) { m in Text(m.name).tag(Optional(m.id)) }
            }
            .labelsHidden().frame(width: 130)

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
        Binding(get: { repo.defaultAgentID }, set: { newID in
            // Only a real agent change invalidates the pinned mode (modes are
            // agent-specific). Re-selecting the same agent must not wipe it —
            // that silently erased per-repo YOLO pins.
            guard newID != repo.defaultAgentID else { return }
            var r = repo
            r.defaultAgentID = newID
            r.defaultModeID = nil
            store.updateRepo(r)
        })
    }

    private var modeBinding: Binding<UUID?> {
        Binding(get: { repo.defaultModeID }, set: { var r = repo; r.defaultModeID = $0; store.updateRepo(r) })
    }
}

/// A miniature palette token: the repo's short name as ink on a quiet
/// neutral tile — monochrome, like the drop it previews.
private struct RepoTintBadge: View {
    let name: String

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .frame(width: 30, height: 30)
            .overlay(
                Text(RepoTint.shortName(for: name))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2))
            .accessibilityHidden(true)
    }
}
