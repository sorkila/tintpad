import Foundation
import SwiftUI

/// The single source of truth, persisted to
/// `~/Library/Application Support/Tintpad/store.json`. Local-only, no accounts.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore(fileURL: defaultFileURL)

    /// `~/Library/Application Support/Tintpad/store.json`, the only store the
    /// app itself ever opens. Tests hand `init(fileURL:)` a temp file instead.
    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tintpad", isDirectory: true)
            .appendingPathComponent("store.json")
    }

    @Published var repos: [Repo] = [] { didSet { searchRevision &+= 1 } }
    @Published var agents: [Agent] = []
    @Published var prompts: [PromptTemplate] = []
    @Published var sessions: [Session] = []
    @Published var settings: Settings = .defaults() {
        didSet {
            if settings.frecencyHalfLifeDays != oldValue.frecencyHalfLifeDays { searchRevision &+= 1 }
        }
    }
    /// Bumped whenever anything `orderedRepos()` reads changes (any repo
    /// mutation, the half-life), so the palette's search cache can validate
    /// with one integer compare instead of comparing every repo.
    private(set) var searchRevision = 0

    private let fileURL: URL
    private var isLoading = false
    /// Why the store on disk didn't load, nil when it did (or on a first run).
    /// The app says so once at launch, a silent failure reads as "Tintpad
    /// forgot everything".
    @Published private(set) var loadFailure: LoadFailure?
    /// False when nothing this session may write over the file on disk: it
    /// exists but could not be read, or it failed to decode and no backup of
    /// it could be made. The seed then lives in memory only, and a relaunch
    /// reads the file again.
    var canPersist: Bool { loadFailure?.allowsSaving ?? true }
    /// First-run onboarding, never over a store this session can't save:
    /// that user has been here before, and nothing onboarding sets would stick.
    var shouldOnboard: Bool { Self.shouldOnboard(hasOnboarded: settings.hasOnboarded, canPersist: canPersist) }
    nonisolated static func shouldOnboard(hasOnboarded: Bool, canPersist: Bool) -> Bool {
        !hasOnboarded && canPersist
    }
    /// Completed writes to disk, so tests can pin how often a change persists.
    private(set) var writeCount = 0

    init(fileURL: URL) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        self.fileURL = fileURL
        load()
    }

    // MARK: - Persistence

    /// What reading the store file found. A failed *read* and a failed
    /// *decode* are different problems: a read that fails (permissions, an
    /// iCloud placeholder, a transient I/O error) says nothing about the data,
    /// which is probably fine, while a decode that fails means the bytes are.
    enum LoadResult {
        case loaded(StoreDocument)
        /// Nothing at the path: a true first run.
        case missing
        /// Something is there but could not be read.
        case unreadable(Error)
        /// The bytes were read but are not a store.
        case corrupt(Error)
    }

    /// A store that existed but didn't load, as the user hears about it.
    enum LoadFailure: Equatable {
        /// Couldn't be read. The data is probably fine, nothing is saved.
        case unreadable
        /// Didn't decode, a copy was kept at `backup`, the seed saves normally.
        case corrupt(backup: URL)
        /// Didn't decode and the copy failed, so nothing is saved over it.
        case corruptNotBackedUp(store: URL)

        var allowsSaving: Bool {
            if case .corrupt = self { return true }
            return false
        }

        /// The launch alert's text. Pure, so the copy is pinned by tests.
        var alertCopy: (message: String, informative: String) {
            switch self {
            case .unreadable:
                return ("Tintpad couldn't read its data",
                        "Your repos and settings are safe on disk. Changes made this session won't be saved. Quit and reopen Tintpad to try again.")
            case .corrupt(let backup):
                let folder = (backup.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                return ("Tintpad couldn't load its data",
                        "The saved file was damaged, so Tintpad kept a copy as \(backup.lastPathComponent) in \(folder) and started fresh.")
            case .corruptNotBackedUp(let store):
                let folder = (store.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                return ("Tintpad couldn't load its data",
                        "The saved file is damaged and Tintpad couldn't keep a copy, so it is left untouched and changes made this session won't be saved. Move \(store.lastPathComponent) out of \(folder) and reopen Tintpad to start fresh.")
            }
        }
    }

    /// Pure: classify a read attempt. `entryExists` is asked separately
    /// (without following a symlink), so only "no such file" *and* nothing at
    /// the path counts as missing. Anything else that fails to read is
    /// unreadable, never a first run that may seed over it.
    nonisolated static func classify(read: Result<Data, Error>, entryExists: Bool) -> LoadResult {
        switch read {
        case .success(let data):
            do { return .loaded(try JSONDecoder.tintpad.decode(StoreDocument.self, from: data)) }
            catch { return .corrupt(error) }
        case .failure(let error):
            let ns = error as NSError
            let noSuchFile = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
            return noSuchFile && !entryExists ? .missing : .unreadable(error)
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let read = Result { try Data(contentsOf: fileURL) }
        // attributesOfItem doesn't traverse a final symlink, so a dangling one
        // (a synced folder not mounted yet) still counts as something there.
        let entryExists = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) != nil
        switch Self.classify(read: read, entryExists: entryExists) {
        case .loaded(let doc):
            repos = doc.repos
            let raw = doc.agents.isEmpty ? AgentSeed.defaults : doc.agents
            agents = AgentSeed.migrateModeNames(raw)
            prompts = doc.prompts
            sessions = doc.sessions
            settings = doc.settings
            // A vocabulary migration that changed something is written back
            // once, so the store speaks the new names from here on.
            if agents != raw { persist() }
        case .missing:
            seed()
            // A true first run: the seed is the store.
            persist()
        case .corrupt(let error):
            // A store exists but didn't decode (a sync conflict, a half-written
            // file): preserve the evidence before anything can write over it.
            // Reseeding must never destroy the only copy of the user's data,
            // so a backup that fails leaves the store read-only.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("store.corrupt-\(stamp).json")
            do {
                try FileManager.default.copyItem(at: fileURL, to: backup)
                loadFailure = .corrupt(backup: backup)
                NSLog("Tintpad: store.json failed to decode (\(error)), preserved a copy at \(backup.path)")
            } catch {
                loadFailure = .corruptNotBackedUp(store: fileURL)
                NSLog("Tintpad: store.json failed to decode and couldn't be backed up (\(error.localizedDescription)), not saving this session")
            }
            // The seed stays in memory until something actually changes.
            seed()
        case .unreadable(let error):
            // The file is there but couldn't be read. Its contents are
            // probably fine, so this session must never save a seed over them:
            // seed in memory so the palette still works, write nothing.
            loadFailure = .unreadable
            NSLog("Tintpad: store.json couldn't be read (\(error.localizedDescription)), not saving this session")
            seed()
        }
    }

    private func seed() {
        let seeded = StoreDocument.seeded()
        repos = seeded.repos
        agents = seeded.agents
        prompts = seeded.prompts
        sessions = seeded.sessions
        settings = seeded.settings
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
        guard canPersist else { return }
        let doc = StoreDocument(version: 1, repos: repos, agents: agents,
                                prompts: prompts, sessions: sessions, settings: settings)
        do {
            let data = try JSONEncoder.tintpad.encode(doc)
            try data.write(to: fileURL, options: .atomic)
            writeCount += 1
        } catch {
            // A failed save must at least leave a trace — silent loss of
            // repos/sessions/settings on disk-full is worse than a log line.
            NSLog("Tintpad: failed to save store.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Repo operations

    func addRepo(path: String, via source: RepoSource = .manual) {
        addRepos(paths: [path], via: source)
    }

    /// Add every path not already known, in order, with one save: a first
    /// discovery scan of sixty repos is one encode and one write on main, not
    /// sixty. Returns the number added.
    @discardableResult
    func addRepos(paths: [String], via source: RepoSource) -> Int {
        var known = Set(repos.map(\.path))
        var added: [Repo] = []
        for path in paths {
            let canonical = (path as NSString).standardizingPath
            guard known.insert(canonical).inserted else { continue }
            let name = (canonical as NSString).lastPathComponent
            added.append(Repo(path: canonical, name: name, addedVia: source))
        }
        guard !added.isEmpty else { return 0 }
        repos.append(contentsOf: added)
        save()
        return added.count
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
        addRepos(paths: found, via: .autoDiscover)
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
