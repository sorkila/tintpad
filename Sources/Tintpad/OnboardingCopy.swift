import Foundation

/// Onboarding's dynamic lines, pure so their shapes are tested rather than
/// eyeballed on a first run nobody repeats.
enum OnboardingCopy {
    /// The repos step's status line. `existingRoots` are the scan roots that
    /// exist on disk, `count` is how many repos the store holds.
    static func reposLine(count: Int, existingRoots: [String],
                          home: String = NSHomeDirectory()) -> String {
        guard !existingRoots.isEmpty else {
            return "Add the folder your projects live in, Tintpad finds the repos inside it"
        }
        let places = joined(existingRoots.map { abbreviate($0, home: home) })
        switch count {
        case 0: return "No repos found in \(places) yet"
        case 1: return "Found 1 repo in \(places)"
        default: return "Found \(count) repos in \(places)"
        }
    }

    /// The finish button names the real hotkey, so the last thing onboarding
    /// says is how to come back.
    static func doneLabel(shortcut: String?) -> String {
        let key = shortcut.flatMap { $0.isEmpty ? nil : $0 } ?? "your hotkey"
        return "Done, press \(key) anytime"
    }

    /// `/Users/me/Developer` reads `~/Developer`, a path outside home is left alone.
    static func abbreviate(_ path: String, home: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty else { return expanded }
        if expanded == trimmedHome { return "~" }
        if expanded.hasPrefix(trimmedHome + "/") { return "~" + expanded.dropFirst(trimmedHome.count) }
        return expanded
    }

    /// "a", "a and b", "a, b, and c".
    static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}
