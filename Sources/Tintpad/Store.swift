import Foundation
import SwiftUI

/// The single source of truth, persisted to
/// `~/Library/Application Support/Tintpad/store.json`. Local-only, no accounts.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var repos: [Repo] = []
    @Published var agents: [Agent] = []
    @Published var settings: Settings = .defaults()

    private let fileURL: URL
    private var isLoading = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Tintpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("store.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder.tintpad.decode(StoreDocument.self, from: data) else {
            // First run: seed defaults and persist.
            let seeded = StoreDocument.seeded()
            repos = seeded.repos
            agents = seeded.agents
            settings = seeded.settings
            persist()   // write directly; save() is suppressed while loading
            return
        }
        repos = doc.repos
        agents = doc.agents.isEmpty ? AgentSeed.defaults : doc.agents
        settings = doc.settings
    }

    func save() {
        guard !isLoading else { return }
        persist()
    }

    private func persist() {
        let doc = StoreDocument(version: 1, repos: repos, agents: agents, settings: settings)
        guard let data = try? JSONEncoder.tintpad.encode(doc) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Repo operations

    func addRepo(path: String, via source: RepoSource = .manual) {
        let canonical = (path as NSString).standardizingPath
        guard !repos.contains(where: { $0.path == canonical }) else { return }
        let name = (canonical as NSString).lastPathComponent
        repos.append(Repo(path: canonical, name: name, addedVia: source))
        save()
    }

    func removeRepo(_ id: UUID) {
        repos.removeAll { $0.id == id }
        save()
    }

    func updateRepo(_ repo: Repo) {
        guard let idx = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[idx] = repo
        save()
    }

    /// Records a launch, bumping frecency.
    func recordLaunch(repoID: UUID, now: Date = Date()) {
        guard let idx = repos.firstIndex(where: { $0.id == repoID }) else { return }
        Frecency.recordVisit(&repos[idx], now: now, halfLifeDays: settings.frecencyHalfLifeDays)
        save()
    }

    /// Repos ordered for the palette: pinned first, then by decayed frecency.
    func orderedRepos(now: Date = Date()) -> [Repo] {
        let half = settings.frecencyHalfLifeDays
        return repos.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return Frecency.decayedScore(a, now: now, halfLifeDays: half)
                 > Frecency.decayedScore(b, now: now, halfLifeDays: half)
        }
    }

    // MARK: - Agent operations

    func agent(_ id: UUID?) -> Agent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    func addAgent(_ agent: Agent) {
        agents.append(agent)
        save()
    }

    func updateAgent(_ agent: Agent) {
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[idx] = agent
        save()
    }

    func removeAgent(_ id: UUID) {
        agents.removeAll { $0.id == id }
        save()
    }

    /// A SwiftUI binding to a settings field that persists on every write.
    func bind<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0; self.save() }
        )
    }

    // MARK: - Discovery

    /// Scan the configured root folders (1–2 levels) for `.git` directories and
    /// add any new repos. Returns the number added.
    @discardableResult
    func runAutoDiscovery() -> Int {
        let found = RepoDiscovery.scan(roots: settings.rootScanFolders)
        let existing = Set(repos.map(\.path))
        var added = 0
        for path in found where !existing.contains(path) {
            addRepo(path: path, via: .autoDiscover)
            added += 1
        }
        return added
    }
}

// MARK: - JSON coders

extension JSONEncoder {
    static var tintpad: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var tintpad: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
