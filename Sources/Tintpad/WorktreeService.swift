import Foundation

/// Creates and manages git worktrees so an agent can work on an isolated branch
/// checkout without disturbing the main working tree.
enum WorktreeService {
    struct Worktree: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let branch: String?
    }

    enum WorktreeError: Error, CustomStringConvertible {
        case gitFailed(String)
        var description: String {
            switch self { case .gitFailed(let m): return m }
        }
    }

    private static var gitBinary: String {
        ShellEnvironment.resolveBinary("git") ?? "/usr/bin/git"
    }

    /// Default placement for a new worktree: a sibling directory
    /// `<repoName>-<sanitizedBranch>` next to the repo (or under `customRoot`).
    static func defaultPath(repoPath: String, branch: String, customRoot: String?) -> String {
        let repoName = (repoPath as NSString).lastPathComponent
        let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
        let dirName = "\(repoName)-\(safeBranch)"
        if let root = customRoot, !root.isEmpty {
            return ((root as NSString).expandingTildeInPath as NSString).appendingPathComponent(dirName)
        }
        let parent = (repoPath as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent(dirName)
    }

    /// Creates a worktree at `path` checking out `branch`. If the branch doesn't
    /// exist it's created (`-b`). Returns the worktree path.
    @discardableResult
    static func create(repoPath: String, branch: String, at path: String) throws -> String {
        let exists = branchExists(repoPath: repoPath, branch: branch)
        // "--" pins positionals, and the branch rides as -b's value when new,
        // so a user-typed name starting with "-" can never become a git option.
        var args = ["-C", repoPath, "worktree", "add"]
        if exists {
            args += ["--", path, branch]
        } else {
            args += ["-b", branch, "--", path]
        }
        try runGit(args)
        return path
    }

    static func list(repoPath: String) -> [Worktree] {
        guard let out = try? runGit(["-C", repoPath, "worktree", "list", "--porcelain"]) else { return [] }
        var trees: [Worktree] = []
        var curPath: String?
        var curBranch: String?
        func flush() {
            if let p = curPath { trees.append(Worktree(path: p, branch: curBranch)) }
            curPath = nil; curBranch = nil
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush()
                curPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                curBranch = (ref as NSString).lastPathComponent
            } else if line.isEmpty {
                flush()
            }
        }
        flush()
        return trees
    }

    static func remove(repoPath: String, worktreePath: String) throws {
        try runGit(["-C", repoPath, "worktree", "remove", worktreePath])
    }

    // MARK: - Internals

    private static func branchExists(repoPath: String, branch: String) -> Bool {
        // Full ref path: unambiguous, and a "-" prefix can't become an option.
        (try? runGit(["-C", repoPath, "rev-parse", "--verify", "--quiet",
                      "refs/heads/\(branch)"])) != nil
    }

    @discardableResult
    private static func runGit(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitBinary)
        p.arguments = args
        p.environment = ShellEnvironment.processEnvironment
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch {
            throw WorktreeError.gitFailed("git: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WorktreeError.gitFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
