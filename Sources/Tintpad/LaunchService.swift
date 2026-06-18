import Foundation

/// The single launch path used by both the palette and the quick-resume hotkey:
/// resolve the command template, hand off to the terminal/editor, and record
/// frecency + session history.
@MainActor
enum LaunchService {
    @discardableResult
    static func launchAgent(repo: Repo, agent: Agent, mode: RunMode,
                            prompt: String?, store: AppStore,
                            worktreePath: String? = nil) throws -> LaunchOutcome {
        let workingDir = worktreePath ?? repo.path
        let git = GitInfo.read(at: workingDir)
        let ctx = CommandTemplate.Context(
            repo: repo, mode: mode, prompt: prompt, branch: git.branch,
            remote: git.remoteURL, worktreePath: worktreePath)
        let command = try CommandTemplate.resolved(agent.commandTemplate, context: ctx)

        // Multi-step: optionally open the editor alongside the terminal+agent.
        if store.settings.alsoOpenEditor, let editor = EditorRegistry.preferred(settings: store.settings) {
            try? editor.open(path: workingDir)
        }

        let terminal = TerminalRegistry.preferred(settings: store.settings)
        let outcome = try terminal.launch(TerminalLaunch(
            workingDirectory: workingDir, command: command,
            openInTab: store.settings.openInNewTab))
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
