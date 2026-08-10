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

    enum ResolveError: Error, CustomStringConvertible, LocalizedError {
        case binaryNotFound(String)
        case emptyCommand

        var description: String {
            switch self {
            case .binaryNotFound(let b): return "“\(b)” isn’t on your PATH — check it’s installed, then Re-scan."
            case .emptyCommand: return "This agent’s command template is empty."
            }
        }
        var errorDescription: String? { description }
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

    /// Wrap a resolved command so the agent starts a *fresh* session even when
    /// the shell it runs in is polluted: `env -u` drops each inherited session
    /// marker (see `ShellEnvironment.sessionMarkers`) before exec'ing the agent.
    /// This is the only layer that can fix a dirty *terminal* (e.g. Ghostty
    /// relaunched from inside a Claude Code session) — scrubbing Tintpad's own
    /// spawn environment can't reach a shell another app owns.
    ///
    /// `env -u`, not `unset …;`: the adapters embed the command in
    /// `cd … && <command>; exec <shell>` chains, and a `;` in the prefix would
    /// split the `&&` so the agent runs even when the cd failed. `env -u` keeps
    /// the whole thing one simple command, leaving the parse structure intact.
    static func inFreshSession(_ command: String) -> String {
        let flags = ShellEnvironment.sessionMarkers.map { "-u \($0)" }.joined(separator: " ")
        return "env \(flags) \(command)"
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
            if value.isEmpty {
                // An empty slot swallows one adjacent space so
                // "claude {mode} {prompt}" tidies to "claude" — a targeted
                // cleanup, never a global collapse, which would rewrite
                // legitimate double spaces inside quoted paths and prompts.
                result = result.replacingOccurrences(of: " " + key, with: "")
            }
            result = result.replacingOccurrences(of: key, with: value)
        }
        return result.trimmingCharacters(in: .whitespaces)
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
