import Foundation

/// Reads git metadata by parsing `.git` files directly — no `git` subprocess,
/// so it avoids PATH/latency issues and works even when git isn't on PATH.
enum GitInfo {
    struct Metadata {
        var branch: String?
        var remoteURL: String?
    }

    static func read(at repoPath: String) -> Metadata {
        let gitDir = resolveGitDir(repoPath)
        return Metadata(
            branch: branch(gitDir: gitDir),
            remoteURL: originRemote(gitDir: gitDir)
        )
    }

    static func currentBranch(at repoPath: String) -> String? {
        branch(gitDir: resolveGitDir(repoPath))
    }

    // MARK: - Internals

    /// Handles both a normal `.git` directory and a worktree/submodule `.git`
    /// file that points elsewhere via `gitdir: <path>`.
    private static func resolveGitDir(_ repoPath: String) -> String {
        let dotGit = "\(repoPath)/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else {
            return dotGit
        }
        if isDir.boolValue { return dotGit }
        // `.git` is a file: read the gitdir pointer.
        if let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
           let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("/") { return target }
            return (repoPath as NSString).appendingPathComponent(target)
        }
        return dotGit
    }

    private static func branch(gitDir: String) -> String? {
        let headPath = "\(gitDir)/HEAD"
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            // e.g. "ref: refs/heads/main" -> "main"
            let ref = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            return (ref as NSString).lastPathComponent
        }
        // Detached HEAD: show the short SHA.
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }

    /// Minimal `.git/config` parse for `[remote "origin"] url = …`.
    private static func originRemote(gitDir: String) -> String? {
        let configPath = "\(gitDir)/config"
        guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        var inOrigin = false
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "")
                    .lowercased()
                    .hasPrefix("[remote\"origin\"]")
                continue
            }
            if inOrigin, line.lowercased().hasPrefix("url") {
                if let eq = line.firstIndex(of: "=") {
                    return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}
