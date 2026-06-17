import Foundation

/// Resolves an agent command template into a concrete shell command.
///
/// Variables (per the spec): `{repoPath}` `{repoName}` `{branch}` `{remote}`
/// `{prompt}` `{mode}` `{shell}` `{worktreePath}`. The leading binary token is
/// resolved to an absolute path via the login-shell PATH so a GUI-launched app
/// finds `claude`/`codex`/… (the #1 footgun).
enum CommandTemplate {
    struct Context {
        var repo: Repo
        var mode: RunMode
        var prompt: String?
        var branch: String?
        var remote: String?
        var worktreePath: String?
    }

    enum ResolveError: Error, CustomStringConvertible {
        case binaryNotFound(String)
        case emptyCommand

        var description: String {
            switch self {
            case .binaryNotFound(let b): return "\(b) not found on PATH — try “Re-scan agents”"
            case .emptyCommand: return "Command template is empty"
            }
        }
    }

    /// The fully substituted, human-readable command (binary NOT yet absolutized)
    /// — used for the footer preview.
    static func preview(_ template: String, context: Context) -> String {
        substitute(template, context: context)
    }

    /// The final command to hand to a terminal: variables substituted AND the
    /// leading binary resolved to an absolute path. Throws if the binary is
    /// missing so the caller can warn instead of launching a broken command.
    static func resolved(_ template: String, context: Context) throws -> String {
        let substituted = substitute(template, context: context)
        let tokens = substituted.split(separator: " ", maxSplits: 1).map(String.init)
        guard let head = tokens.first, !head.isEmpty else { throw ResolveError.emptyCommand }
        // Already an absolute/relative path? Trust as-is.
        if head.contains("/") {
            return substituted
        }
        guard let abs = ShellEnvironment.resolveBinary(head) else {
            throw ResolveError.binaryNotFound(head)
        }
        let rest = tokens.count > 1 ? " \(tokens[1])" : ""
        return abs + rest
    }

    // MARK: - Substitution

    private static func substitute(_ template: String, context c: Context) -> String {
        let shell = ShellEnvironment.loginShell
        let replacements: [String: String] = [
            "{repoPath}": shellQuotePath(c.repo.path),
            "{repoName}": c.repo.name,
            "{branch}": c.branch ?? "",
            "{remote}": c.remote ?? "",
            "{prompt}": c.prompt.map(promptArgument) ?? "",
            "{mode}": c.mode.flags,
            "{shell}": shell,
            "{worktreePath}": c.worktreePath.map(shellQuotePath) ?? "",
        ]
        var result = template
        for (key, value) in replacements {
            result = result.replacingOccurrences(of: key, with: value)
        }
        // Collapse the gaps left by empty substitutions (e.g. empty {mode}).
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func shellQuotePath(_ p: String) -> String {
        "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func promptArgument(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return shellQuotePath(trimmed)
    }
}
