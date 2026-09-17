import Foundation

/// The drop's launch lines, in one place. Pure so the copy is tested. Gray
/// means waiting (opening, still opening), red means failure, and a failure
/// always says what Return and Esc do, so an error is never a dead end.
enum LaunchStatusCopy {
    /// How long a launch may stay quiet before the line admits it is slow.
    static let stillOpeningAfter: TimeInterval = LaunchFeedbackTiming.stillOpening

    static func opening(_ name: String) -> String { "Opening \(name)…" }

    static func stillOpening(_ name: String) -> String { "Still opening \(name)…" }

    /// `Couldn't open Ghostty (exit 1), Return retries, Esc closes`.
    static func error(terminal: String, error: Error) -> String {
        "Couldn't open \(terminal) (\(reason(error))), Return retries, Esc closes"
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
                return clause(String(message.dropFirst("AppleScript: ".count)))
            }
            return clause(message)
        default:
            return clause(error.localizedDescription)
        }
    }

    static let maxReason = 40

    /// The first clause: up to the first comma, sentence end, or line break,
    /// with a path's dots left alone ("Ghostty.app" is not a sentence end).
    static func clause(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [", ", ". ", "; ", "\n"] {
            if let r = s.range(of: separator) { s = String(s[..<r.lowerBound]) }
        }
        while s.hasSuffix(".") { s.removeLast() }
        if s.count > maxReason {
            s = String(s.prefix(maxReason - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return s.isEmpty ? "unknown error" : s
    }
}
