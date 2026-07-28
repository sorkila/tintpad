import Foundation
import SwiftUI

/// The single source of truth, persisted to
/// `~/Library/Application Support/Tintpad/store.json`. Local-only, no accounts.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var repos: [Repo] = []
    @Published var agents: [Agent] = []
    @Published var prompts: [PromptTemplate] = []
    @Published var sessions: [Session] = []
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
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder.tintpad.decode(StoreDocument.self, from: data) {
            repos = doc.repos
            let raw = doc.agents.isEmpty ? AgentSeed.defaults : doc.agents
            agents = AgentSeed.migrateModeNames(raw)
            prompts = doc.prompts
            sessions = doc.sessions
            settings = doc.settings
            // A vocabulary migration that changed something is written back
            // once, so the store speaks the new names from here on.
            if agents != raw { persist() }
            return
        }
        // A store exists but didn't load (corrupt, sync conflict, transient
        // read error): preserve the evidence before anything can write over
        // it. Reseeding must never destroy the only copy of the user's data.
        let hadFile = FileManager.default.fileExists(atPath: fileURL.path)
        if hadFile {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("store.corrupt-\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            NSLog("Tintpad: store.json failed to load — preserved a copy at \(backup.path)")
        }
        let seeded = StoreDocument.seeded()
        repos = seeded.repos
        agents = seeded.agents
        prompts = seeded.prompts
        sessions = seeded.sessions
        settings = seeded.settings
        // Persist immediately only on a true first run; after a failed load
        // the seed stays in memory until something actually changes.
        if !hadFile { persist() }
    }

    func save() {
        guard !isLoading else { return }
        pendingSave?.cancel()
        pendingSave = nil
        persist()
    }

    private var pendingSave: DispatchWorkItem?

    /// Coalesced save for rapid-fire writers (sliders, text fields): a full
    /// store encode + atomic write per keystroke is main-thread work the user
    /// can feel. An explicit `save()` or app termination flushes early.
    func saveSoon(after delay: TimeInterval = 0.4) {
        guard !isLoading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.persist()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Land any debounced write now (called on app termination).
    func flushPendingSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        persist()
    }

    private func persist() {
        let doc = StoreDocument(version: 1, repos: repos, agents: agents,
                                prompts: prompts, sessions: sessions, settings: settings)
        do {
            let data = try JSONEncoder.tintpad.encode(doc)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A failed save must at least leave a trace — silent loss of
            // repos/sessions/license on disk-full is worse than a log line.
            NSLog("Tintpad: failed to save store.json: \(error.localizedDescription)")
        }
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
        Frecency.ordered(repos, now: now, halfLifeDays: settings.frecencyHalfLifeDays)
    }

    // MARK: - Agent operations

    func agent(_ id: UUID?) -> Agent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    /// The agent's monogram, assigned across the whole set so it stays distinct
    /// from the others. Lives here so the palette and Settings can't disagree
    /// about what letter an agent is.
    func monogram(for agent: Agent?) -> String {
        guard let agent else { return "?" }
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else {
            return Monogram.assign([agent.name]).first ?? "?"
        }
        return Monogram.assign(agents.map(\.name))[idx]
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
        // The last agent is load-bearing: without one the palette dead-keys
        // (⏎ and ⇥ silently no-op) until the next launch reseeds.
        guard agents.count > 1 else { return }
        agents.removeAll { $0.id == id }
        save()
    }

    // MARK: - Licensing / entitlements

    var licenseInfo: LicenseManager.LicenseInfo? { LicenseManager.verify(settings.licenseKey) }
    /// Has the user bought the optional Supporter unlock. (Tintpad is MIT and
    /// fully free; this only ever unlocks a cosmetic thank-you.)
    var isSupporter: Bool { licenseInfo != nil }

    /// Tip-jar model: every functional feature is free. The only thing the
    /// Supporter purchase unlocks is custom accent tints — a small thank-you,
    /// never a wall.
    func allows(_ feature: ProFeature) -> Bool {
        switch feature {
        case .customTint: return isSupporter
        default: return true
        }
    }

    /// Validates and stores a license key. Returns true if accepted.
    @discardableResult
    func applyLicense(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LicenseManager.verify(trimmed) != nil else { return false }
        settings.licenseKey = trimmed
        save()
        return true
    }

    func clearLicense() {
        settings.licenseKey = nil
        save()
    }

    /// A SwiftUI binding to a settings field that persists on every write
    /// (debounced — sliders and text fields write on every tick).
    func bind<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0; self.saveSoon() }
        )
    }

    // MARK: - Prompt library

    func addPrompt(_ p: PromptTemplate) { prompts.append(p); save() }
    func removePrompt(_ id: UUID) { prompts.removeAll { $0.id == id }; save() }
    func updatePrompt(_ p: PromptTemplate) {
        guard let i = prompts.firstIndex(where: { $0.id == p.id }) else { return }
        prompts[i] = p; save()
    }

    // MARK: - Sessions

    private let maxSessions = 50

    /// Record a launch as a session (newest first, de-duped by repo+agent+mode).
    /// Also stamps the repo's last-used agent + mode, so the palette can offer
    /// "the way you opened it last" when no explicit default is pinned.
    func recordSession(repo: Repo, agent: Agent, mode: RunMode, prompt: String?, now: Date = Date()) {
        if let idx = repos.firstIndex(where: { $0.id == repo.id }) {
            repos[idx].lastAgentID = agent.id
            repos[idx].lastModeID = mode.id
        }
        let session = Session(
            repoID: repo.id, repoPath: repo.path, repoName: repo.name,
            agentID: agent.id, agentName: agent.name,
            modeID: mode.id, modeName: mode.name,
            prompt: prompt, date: now
        )
        sessions.removeAll { $0.repoID == repo.id && $0.agentID == agent.id && $0.modeID == mode.id }
        sessions.insert(session, at: 0)
        if sessions.count > maxSessions { sessions.removeLast(sessions.count - maxSessions) }
        save()
    }

    var lastSession: Session? { sessions.first }

    func clearSessions() { sessions.removeAll(); save() }

    // MARK: - Discovery

    /// Scan the configured root folders (1–2 levels) for `.git` directories and
    /// add any new repos. Returns the number added. Synchronous — only for
    /// explicit user actions (⌘R, the Scan button); launch paths use the
    /// background variant below.
    @discardableResult
    func runAutoDiscovery() -> Int {
        let found = RepoDiscovery.scan(roots: settings.rootScanFolders)
        return merge(found)
    }

    /// The same scan off the main thread: root folders can live on slow
    /// fileprovider volumes, and app launch or a palette summon must never
    /// block on a directory walk.
    func runAutoDiscoveryInBackground() {
        let roots = settings.rootScanFolders
        DispatchQueue.global(qos: .utility).async {
            let found = RepoDiscovery.scan(roots: roots)
            Task { @MainActor in
                let added = self.merge(found)
                if added > 0 { NSLog("Tintpad: discovered \(added) repos") }
            }
        }
    }

    private func merge(_ found: [String]) -> Int {
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
