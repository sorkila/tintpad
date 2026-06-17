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
        // Every interpolated value is sanitized (control chars/newlines removed)
        // and single-quoted, so neither shell metacharacters nor a newline (which
        // would break AppleScript or submit early via the keystroke adapter) can
        // escape the argument. {mode} and {shell} are app-controlled, not quoted.
        let replacements: [String: String] = [
            "{repoPath}": quote(c.repo.path),
            "{repoName}": quote(c.repo.name),
            "{branch}": quote(c.branch),
            "{remote}": quote(c.remote),
            "{prompt}": quote(c.prompt),
            "{mode}": sanitize(c.mode.flags),
            "{shell}": ShellEnvironment.loginShell,
            "{worktreePath}": quote(c.worktreePath),
        ]
        var result = template
        for (key, value) in replacements {
            result = result.replacingOccurrences(of: key, with: value)
        }
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Remove control characters (newlines, etc.) — they break AppleScript string
    /// literals and cause the Ghostty keystroke adapter to submit the line early.
    static func sanitize(_ s: String) -> String {
        let space = Unicode.Scalar(UInt8(32))
        let scalars = s.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? space : $0
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// Sanitize then POSIX single-quote a value; empty values collapse to nothing.
    static func quote(_ s: String?) -> String {
        let t = sanitize(s ?? "")
        guard !t.isEmpty else { return "" }
        return "'" + t.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
