import Foundation

/// The single launch path used by both the palette and the quick-resume hotkey:
/// resolve the command template, hand off to the terminal/editor, and record
/// frecency + session history.
@MainActor
enum LaunchService {
    /// Resolves the terminal to launch into. Injectable so the launch path can be
    /// exercised in tests with a fake adapter instead of spawning a real terminal.
    static var resolveTerminal: @MainActor (Settings) -> TerminalAdapter = {
        TerminalRegistry.preferred(settings: $0)
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
        return TerminalLaunch(workingDirectory: workingDir, command: command,
                              openInTab: settings.openInNewTab)
    }

    @discardableResult
    static func launchAgent(repo: Repo, agent: Agent, mode: RunMode,
                            prompt: String?, store: AppStore,
                            worktreePath: String? = nil) throws -> LaunchOutcome {
        let launch = try makeLaunch(repo: repo, agent: agent, mode: mode, prompt: prompt,
                                    worktreePath: worktreePath, settings: store.settings)

        // Multi-step: optionally open the editor alongside the terminal+agent.
        if store.settings.alsoOpenEditor, let editor = EditorRegistry.preferred(settings: store.settings) {
            try? editor.open(path: launch.workingDirectory)
        }

        let outcome = try resolveTerminal(store.settings).launch(launch)
        store.recordLaunch(repoID: repo.id)
        store.recordSession(repo: repo, agent: agent, mode: mode, prompt: prompt)
        return outcome
    }

    /// Create a worktree for `branch` off `repo`, then launch the agent in it.
    @discardableResult
    static func launchInWorktree(repo: Repo, agent: Agent, mode: RunMode,
                                 branch: String, prompt: String?, store: AppStore) throws -> LaunchOutcome {
        let path = WorktreeService.defaultPath(
            repoPath: repo.path, branch: branch, customRoot: store.settings.worktreeRoot)
        try WorktreeService.create(repoPath: repo.path, branch: branch, at: path)
        return try launchAgent(repo: repo, agent: agent, mode: mode,
                               prompt: prompt, store: store, worktreePath: path)
    }

    static func openInEditor(repo: Repo, store: AppStore) throws {
        guard let editor = EditorRegistry.preferred(settings: store.settings) else {
            throw TerminalLaunchError.notInstalled
        }
        try editor.open(path: repo.path)
        store.recordLaunch(repoID: repo.id)
    }

    /// Re-run the most recent session exactly. Returns false if it can't be
    /// reconstructed (repo/agent/mode no longer exist).
    @discardableResult
    static func resumeLast(store: AppStore) -> Bool {
        guard let session = store.lastSession,
              let repo = store.repos.first(where: { $0.id == session.repoID }),
              let agent = store.agent(session.agentID),
              let mode = agent.modes.first(where: { $0.id == session.modeID })
        else { return false }
        return (try? launchAgent(repo: repo, agent: agent, mode: mode,
                                 prompt: session.prompt, store: store)) != nil
    }
}
