import Foundation

/// The single launch path used by both the palette and the quick-resume hotkey:
/// resolve the command template, hand off to the terminal/editor, and record
/// frecency + session history. Every launch answers through a completion on
/// the main actor, there is no synchronous variant: the handoff itself runs
/// on `handoffQueue`.
@MainActor
enum LaunchService {
    /// Resolves the terminal to launch into. Injectable so the launch path can be
    /// exercised in tests with a fake adapter instead of spawning a real terminal.
    static var resolveTerminal: @MainActor (Settings) -> TerminalAdapter = {
        TerminalRegistry.preferred(settings: $0)
    }

    /// The terminal a launch would open right now, by name, for the drop's
    /// "Opening …" line.
    static func terminalName(store: AppStore) -> String {
        resolveTerminal(store.settings).displayName
    }

    /// Pure: turn a launch request into the concrete `TerminalLaunch` (working
    /// directory + resolved command + tab preference). No side effects, no store —
    /// this is the decision logic, unit-tested in isolation.
    nonisolated static func makeLaunch(repo: Repo, agent: Agent, mode: RunMode,
                                       prompt: String?, worktreePath: String?,
                                       settings: Settings) throws -> TerminalLaunch {
        let workingDir = worktreePath ?? repo.path
        let git = GitInfo.read(at: workingDir)
        let ctx = CommandTemplate.Context(
            repo: repo, mode: mode, prompt: prompt, branch: git.branch,
            remote: git.remoteURL, worktreePath: worktreePath)
        let command = try CommandTemplate.resolved(agent.commandTemplate, context: ctx)
        // Launched sessions are always fresh and top-level — strip inherited
        // session markers so a polluted terminal env can't demote them (a
        // "child" Claude Code session silently stops saving transcripts).
        return TerminalLaunch(workingDirectory: workingDir,
                              command: CommandTemplate.inFreshSession(command),
                              openInTab: settings.openInNewTab)
    }

    /// Where the blocking half of every handoff runs. A plain GCD queue,
    /// deliberately not the Swift cooperative pool (same reasoning as
    /// `PaletteModel.gitQueue`): `ProcessRunner` blocks on a subprocess, and a
    /// hung `osascript` may hold a disposable GCD thread, never a pool thread.
    ///
    /// **Serial on purpose.** A summon clears the palette's in-flight flag, so
    /// a second launch can start while the first is still typing (a cold
    /// Ghostty, Esc, re-summon, Return on another repo inside the poll
    /// window). Two keystroke scripts running at once would interleave into
    /// one window. Serial, the second waits its turn, and every step is
    /// bounded (`AppleScriptRunner.timeout`, `ProcessRunner` timeouts), so no
    /// launch can hold the queue forever.
    nonisolated static let handoffQueue = DispatchQueue(
        label: "com.sorkila.tintpad.handoff", qos: .userInitiated)

    typealias Completion = @MainActor (Result<LaunchOutcome, Error>) -> Void

    /// Carries a main-actor completion across the handoff queue. It is only
    /// ever called on the main queue (`MainActor.assumeIsolated`), so the
    /// closure's captures never actually cross threads.
    private struct MainCallback: @unchecked Sendable {
        let call: Completion
        func deliver(_ result: Result<LaunchOutcome, Error>) {
            DispatchQueue.main.async { MainActor.assumeIsolated { call(result) } }
        }
    }

    /// The one way a terminal launch runs: the adapter's preflight on main
    /// (it throws the actionable errors at once and reads AppKit state, such
    /// as whether Ghostty is already running), the blocking rest on
    /// `handoffQueue`, and the answer back on main. `before` runs first on
    /// the queue (the optional editor). A preflight answer arrives
    /// synchronously, a blocking one on a later main-queue turn.
    static func handOff(_ launch: TerminalLaunch, to adapter: TerminalAdapter,
                        before: (@Sendable () -> Void)? = nil,
                        completion: @escaping Completion) {
        let handoff: TerminalHandoff
        do { handoff = try adapter.prepare(launch) } catch {
            completion(.failure(error))
            return
        }
        switch handoff {
        case .done(let outcome):
            if let before { handoffQueue.async(execute: before) }
            completion(.success(outcome))
        case .blocking(let work):
            let callback = MainCallback(call: completion)
            handoffQueue.async {
                before?()
                callback.deliver(Result { try work() })
            }
        }
    }

    /// Launch an agent in a repo. Never blocks the main thread: the handoff
    /// answers through `completion`, on main, after recording frecency and
    /// the session on success (so a launch whose drop has gone still counts).
    static func launchAgent(repo: Repo, agent: Agent, mode: RunMode,
                            prompt: String?, store: AppStore,
                            worktreePath: String? = nil,
                            completion: @escaping Completion) {
        let launch: TerminalLaunch
        do {
            launch = try makeLaunch(repo: repo, agent: agent, mode: mode, prompt: prompt,
                                    worktreePath: worktreePath, settings: store.settings)
        } catch {
            completion(.failure(error))
            return
        }

        // Multi-step: optionally open the editor alongside the terminal+agent.
        // Resolved here (it reads the store), opened on the handoff queue.
        var before: (@Sendable () -> Void)?
        if store.settings.alsoOpenEditor, let editor = EditorRegistry.preferred(settings: store.settings) {
            let path = launch.workingDirectory
            before = { try? editor.open(path: path) }
        }

        handOff(launch, to: resolveTerminal(store.settings), before: before) { result in
            if case .success = result {
                store.recordLaunch(repoID: repo.id)
                store.recordSession(repo: repo, agent: agent, mode: mode, prompt: prompt)
            }
            completion(result)
        }
    }

    /// Open a repo in the preferred editor, off main like a terminal launch
    /// (`open -b` waits on LaunchServices).
    static func openInEditor(repo: Repo, store: AppStore, completion: @escaping Completion) {
        guard let editor = EditorRegistry.preferred(settings: store.settings) else {
            completion(.failure(TerminalLaunchError.notInstalled))
            return
        }
        let path = repo.path
        let callback = MainCallback(call: { result in
            if case .success = result { store.recordLaunch(repoID: repo.id) }
            completion(result)
        })
        handoffQueue.async {
            callback.deliver(Result { try editor.open(path: path); return LaunchOutcome() })
        }
    }

    enum ResumeError: Error, CustomStringConvertible, LocalizedError {
        /// The stored session references a repo, agent, or mode that no
        /// longer exists, a different problem than a launch failing.
        case unavailable
        /// A resume is already opening. A double press on the menu item, the
        /// hotkey or a Recents row must not launch the session twice.
        case inFlight
        var description: String {
            switch self {
            case .unavailable: return "That session can't be resumed, its repo, agent, or mode is gone"
            case .inFlight: return "That session is already opening"
            }
        }
        var errorDescription: String? { description }
    }

    /// A double press, not a failure: callers stay quiet.
    static func isInFlight(_ error: Error) -> Bool {
        if case ResumeError.inFlight = error { return true }
        return false
    }

    /// True from a resume's start until its handoff answers. Shared by every
    /// resume surface (⌘0, the menu, the hotkey, Recents), which have no
    /// in-flight state of their own.
    private(set) static var resumeInFlight = false

    /// Can the most recent session still be reconstructed? Drives the ⌘0
    /// affordance, so the palette never advertises a resume that can't work.
    static func canResumeLast(store: AppStore) -> Bool {
        guard let session = store.lastSession,
              store.repos.contains(where: { $0.id == session.repoID }),
              let agent = store.agent(session.agentID),
              agent.modes.contains(where: { $0.id == session.modeID })
        else { return false }
        return true
    }

    /// Re-run the most recent session exactly. A session that can't be
    /// reconstructed fails with `ResumeError.unavailable` (synchronously), so
    /// callers can tell "gone" from "failed" and say the true thing.
    static func resumeLast(store: AppStore, completion: @escaping Completion) {
        guard let session = store.lastSession else {
            completion(.failure(ResumeError.unavailable))
            return
        }
        resume(session, store: store, completion: completion)
    }

    /// Re-run a stored session exactly. Fails with `ResumeError.inFlight`
    /// while another resume is still opening.
    static func resume(_ session: Session, store: AppStore, completion: @escaping Completion) {
        guard !resumeInFlight else {
            completion(.failure(ResumeError.inFlight))
            return
        }
        guard let repo = store.repos.first(where: { $0.id == session.repoID }),
              let agent = store.agent(session.agentID),
              let mode = agent.modes.first(where: { $0.id == session.modeID })
        else {
            completion(.failure(ResumeError.unavailable))
            return
        }
        resumeInFlight = true
        launchAgent(repo: repo, agent: agent, mode: mode,
                    prompt: session.prompt, store: store) { result in
            resumeInFlight = false
            completion(result)
        }
    }
}
