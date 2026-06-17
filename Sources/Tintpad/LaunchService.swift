import Foundation

/// The single launch path used by both the palette and the quick-resume hotkey:
/// resolve the command template, hand off to the terminal/editor, and record
/// frecency + session history.
@MainActor
enum LaunchService {
    @discardableResult
    static func launchAgent(repo: Repo, agent: Agent, mode: RunMode,
                            prompt: String?, store: AppStore) throws -> LaunchOutcome {
        let git = GitInfo.read(at: repo.path)
        let ctx = CommandTemplate.Context(
            repo: repo, mode: mode, prompt: prompt, branch: git.branch, remote: git.remoteURL)
        let command = try CommandTemplate.resolved(agent.commandTemplate, context: ctx)
        let terminal = TerminalRegistry.preferred(settings: store.settings)
        let outcome = try terminal.launch(TerminalLaunch(workingDirectory: repo.path, command: command))
        store.recordLaunch(repoID: repo.id)
        store.recordSession(repo: repo, agent: agent, mode: mode, prompt: prompt)
        return outcome
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
