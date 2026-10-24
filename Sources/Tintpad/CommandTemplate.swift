import Foundation

/// Resolves an agent command template into a concrete shell command.
///
/// Variables (per the spec): `{repoPath}` `{repoName}` `{branch}` `{remote}`
/// `{prompt}` `{mode}` `{shell}` `{worktreePath}` `{continue}`. The leading
/// binary token is resolved to an absolute path via the login-shell PATH so a
/// GUI-launched app finds `claude`/`codex`/… (the #1 footgun).
///
/// A continue is the same template with the agent's continue form spliced
/// in: at `{continue}` when the template has the slot, otherwise right after
/// the leading binary, so every existing template continues without an edit
/// (`claude {mode} {prompt}` → `claude --continue {mode} {prompt}`).
enum CommandTemplate {
    struct Context {
        var repo: Repo
        var mode: RunMode
        var prompt: String?
        var branch: String?
        var remote: String?
        var worktreePath: String?
        /// The agent's continue form when this launch continues the
        /// conversation, nil for a fresh launch.
        var continueFlags: String? = nil
    }

    enum ResolveError: Error, CustomStringConvertible, LocalizedError {
        case binaryNotFound(String)
        case emptyCommand

        var description: String {
            switch self {
            case .binaryNotFound(let b): return "“\(b)” isn’t on your PATH, check it’s installed, then Re-scan."
            case .emptyCommand: return "This agent’s command template is empty."
            }
        }
        var errorDescription: String? { description }
    }

    /// The fully substituted, human-readable command (binary NOT yet absolutized)
    /// — used for the footer preview.
    static func preview(_ template: String, context: Context) -> String {
        substitute(spliced(template, context: context), context: context)
    }

    /// The final command to hand to a terminal: variables substituted AND the
    /// leading binary resolved to an absolute path. Throws if the binary is
    /// missing so the caller can warn instead of launching a broken command.
    static func resolved(_ template: String, context: Context) throws -> String {
        let substituted = substitute(spliced(template, context: context), context: context)
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

    /// The template with a `{continue}` slot after its leading binary when
    /// this launch continues and the template has no slot of its own. The
    /// head is found the way `resolved` finds it (the first space-delimited
    /// token, a path or not), so the two can never disagree about where the
    /// binary ends. A fresh launch, or a template that places the slot
    /// itself, is returned as it is.
    static func spliced(_ template: String, context c: Context) -> String {
        guard !sanitize(c.continueFlags ?? "").isEmpty, !template.contains("{continue}") else { return template }
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first, !head.isEmpty else { return template }
        let rest = parts.count > 1 ? " " + parts[1] : ""
        return head + " {continue}" + rest
    }

    private static func substitute(_ template: String, context c: Context) -> String {
        // Every interpolated value is sanitized (control chars/newlines removed)
        // and single-quoted, so neither shell metacharacters nor a newline (which
        // would break AppleScript or submit early via the keystroke adapter) can
        // escape the argument. {mode}, {continue} and {shell} are
        // app-controlled, sanitized onto one line, not quoted.
        //
        // One pass, left to right over the template, and a value is never
        // scanned again: a prompt or a continue form that contains `{prompt}`
        // stays those literal characters. (Replacing key by key from a
        // dictionary made the answer depend on the per-process hash order.)
        // A `{name}` the table doesn't know is left as written.
        let values: [String: String] = [
            "repoPath": quote(c.repo.path),
            "repoName": quote(c.repo.name),
            "branch": quote(c.branch),
            "remote": quote(c.remote),
            "prompt": quote(c.prompt),
            "mode": sanitize(c.mode.flags),
            "continue": sanitize(c.continueFlags ?? ""),
            "shell": ShellEnvironment.loginShell,
            "worktreePath": quote(c.worktreePath),
        ]
        var result = ""
        // Characters copied from the template since the last value, so the
        // tidy below can only ever eat a template space, never a value's.
        var literalTail = 0
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            literalTail += rest.distance(from: rest.startIndex, to: open)
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}"),
                  let value = values[String(rest[afterOpen..<close])] else {
                result.append("{")
                literalTail += 1
                rest = rest[afterOpen...]
                continue
            }
            if value.isEmpty {
                // An empty slot swallows one adjacent space so
                // "claude {mode} {prompt}" tidies to "claude" — a targeted
                // cleanup, never a global collapse, which would rewrite
                // legitimate double spaces inside quoted paths and prompts.
                if literalTail > 0, result.last == " " {
                    result.removeLast()
                    literalTail -= 1
                }
            } else {
                result += value
                literalTail = 0
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
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
