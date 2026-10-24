import Foundation

/// The drop's launch lines, in one place. Pure so the copy is tested. Gray
/// means waiting (opening, still opening), red means failure, and a failure
/// always says what Return and Esc do, so an error is never a dead end.
enum LaunchStatusCopy {
    /// How long a launch may stay quiet before the line admits it is slow.
    static let stillOpeningAfter: TimeInterval = LaunchFeedbackTiming.stillOpening

    static func opening(_ name: String) -> String { "Opening \(name)…" }

    static func stillOpening(_ name: String) -> String { "Still opening \(name)…" }

    /// The keys every error line ends with.
    static let retryKeys = ", Return retries, Esc closes"

    /// `Couldn't open Ghostty (exit 1), Return retries, Esc closes`.
    ///
    /// Held to `DropCopy.maxLineCharacters`: the reason is cut to whatever
    /// room the target's name leaves, never past `maxReason`. A reason that
    /// is already a sentence about the target ("Ghostty lost focus") is the
    /// line itself, rather than "Couldn't open Ghostty (Ghostty lost focus)".
    static func error(terminal: String, error: Error) -> String {
        let full = rawReason(error)
        if full.hasPrefix(terminal + " ") {
            return cut(full, to: DropCopy.maxLineCharacters - retryKeys.count) + retryKeys
        }
        let frame = "Couldn't open \(terminal) ()".count + retryKeys.count
        let room = min(maxReason, max(DropCopy.maxLineCharacters - frame, minReason))
        return "Couldn't open \(terminal) (\(cut(full, to: room)))" + retryKeys
    }

    /// The parenthetical: short enough for one line of the drop.
    ///
    /// - A timeout reads "timed out", whichever layer reported it.
    /// - A helper that exited nonzero (`launchFailed("exited N: …")`) reads
    ///   "exit N", its stderr is rarely a sentence.
    /// - An AppleScript error reads as its own message's first clause, since
    ///   the scripts raise sentences ("Ghostty lost focus, nothing was typed").
    /// - Anything else reads as its description's first clause.
    ///
    /// Clauses are cut to `maxReason` characters.
    static func reason(_ error: Error) -> String {
        cut(rawReason(error), to: maxReason)
    }

    /// `reason` before any cut.
    private static func rawReason(_ error: Error) -> String {
        if let run = error as? ProcessRunner.RunError, case .timedOut = run { return "timed out" }
        switch error {
        case TerminalLaunchError.notInstalled:
            return "not installed"
        case TerminalLaunchError.launchFailed(var message):
            // "/usr/bin/open: …" names the helper, the rest is the reason.
            if message.hasPrefix("/"), let r = message.range(of: ": ") {
                message = String(message[r.upperBound...])
            }
            if message.contains("timed out after") { return "timed out" }
            if message.hasPrefix("exited "),
               let code = message.dropFirst("exited ".count).split(separator: ":").first {
                return "exit \(code)"
            }
            if message.hasPrefix("AppleScript: ") {
                return firstClause(String(message.dropFirst("AppleScript: ".count)))
            }
            return firstClause(message)
        default:
            return firstClause(error.localizedDescription)
        }
    }

    static let maxReason = 40
    /// However long the target's name, a reason keeps this much.
    static let minReason = 12

    /// The first clause, cut to `maxReason`.
    static func clause(_ text: String) -> String {
        cut(firstClause(text), to: maxReason)
    }

    /// The first clause: up to the first comma, sentence end, or line break,
    /// with a path's dots left alone ("Ghostty.app" is not a sentence end).
    private static func firstClause(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [", ", ". ", "; ", "\n"] {
            if let r = s.range(of: separator) { s = String(s[..<r.lowerBound]) }
        }
        while s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "unknown error" : s
    }

    private static func cut(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The drop's middle lines: the confirm gate, the capture explainers, the
/// empty strip. Pure so the copy is tested.
///
/// Every middle line shares one storey with its subject token (a repo name
/// in a chip, often 80 to 160pt), so each is written to a budget rather
/// than left to the truncation. The view still truncates at the tail as the
/// safety net, so if something overflows, the keys at the end go before
/// the reason at the start.
enum DropCopy {
    /// 72 characters of 12pt SF Pro is about 430pt, which leaves room for a
    /// long subject token, its spacing and the insets inside a 640pt drop.
    static let maxLineCharacters = 72

    /// The dangerous-mode gate. The repo is the line's subject token, so the
    /// line names only what is about to run.
    static func confirm(mode: String, agent: String) -> String {
        "\(mode) with \(agent), Return confirms, Esc cancels"
    }

    /// ⌘L's explainer while the field takes the agent's first message.
    static func prompt(agent: String) -> String {
        "First message to \(agent), Return launches, Esc goes back"
    }

    /// ⌃W's explainer. A preview path that would push the line past budget
    /// keeps its head and its tail, the parts that say where and what.
    static func worktree(path: String?) -> String {
        let keys = ", Return creates and launches"
        guard let path else { return "An isolated checkout on a new branch" + keys }
        let lead = "New worktree at "
        return lead + middleCut(path, to: maxLineCharacters - lead.count - keys.count) + keys
    }

    /// ⌘R's answer.
    static func scanned(_ n: Int) -> String {
        "Scanned, \(n) new repo\(n == 1 ? "" : "s")"
    }

    /// Keeps the first and last characters of `s`, joined by an ellipsis.
    static func middleCut(_ s: String, to limit: Int) -> String {
        guard s.count > limit, limit > 1 else { return s }
        let tail = (limit - 1) / 2
        let head = limit - 1 - tail
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}
