import Foundation
import UserNotifications

/// Runs an agent in the background (no terminal window), captures its output to
/// a log file, and posts a notification when it finishes. For agents that
/// support a non-interactive/headless mode (e.g. `claude -p "<prompt>"`).
@MainActor
final class DispatchService {
    static let shared = DispatchService()

    /// Keep strong references so processes aren't deallocated mid-run.
    private var active: [UUID: Process] = [:]

    private let logDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Tintpad/dispatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func requestAuthorization() {
        guard AppEnvironment.isBundled else { return }  // UN crashes outside a bundle
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Dispatch an agent command in the background. Returns the log file URL.
    @discardableResult
    func dispatch(repo: Repo, agent: Agent, mode: RunMode,
                  prompt: String?, store: AppStore) throws -> URL {
        let git = GitInfo.read(at: repo.path)
        let ctx = CommandTemplate.Context(
            repo: repo, mode: mode, prompt: prompt, branch: git.branch,
            remote: git.remoteURL, worktreePath: nil)
        let command = try CommandTemplate.resolved(agent.commandTemplate, context: ctx)

        let id = UUID()
        let stamp = "\(repo.name)-\(Int(Date().timeIntervalSince1970))"
        let logURL = logDir.appendingPathComponent("\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)

        let script = "cd \(shellQuote(repo.path)) && \(command)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ShellEnvironment.loginShell)
        p.arguments = ["-ic", script]
        p.environment = ShellEnvironment.processEnvironment
        p.standardOutput = handle
        p.standardError = handle

        let repoName = repo.name
        let agentName = agent.name
        p.terminationHandler = { [weak self] proc in
            try? handle.close()
            let status = proc.terminationStatus
            Task { @MainActor in
                self?.active[id] = nil
                self?.notify(repo: repoName, agent: agentName, status: status, log: logURL)
            }
        }

        try p.run()
        active[id] = p
        store.recordLaunch(repoID: repo.id)
        store.recordSession(repo: repo, agent: agent, mode: mode, prompt: prompt)
        return logURL
    }

    private func notify(repo: String, agent: String, status: Int32, log: URL) {
        guard AppEnvironment.isBundled else {
            NSLog("Tintpad dispatch done: \(agent) @ \(repo) exit \(status) — \(log.path)")
            return
        }
        let content = UNMutableNotificationContent()
        let ok = status == 0
        content.title = ok ? "✓ \(agent) finished" : "⚠ \(agent) exited \(status)"
        content.body = repo
        content.sound = ok ? .default : .defaultCritical
        content.userInfo = ["log": log.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
