import Foundation

/// The drop's permission lines, and when a launch that failed on a missing
/// grant is offered again. Pure so the copy and the rules are tested without
/// a palette or TCC.
///
/// The first failure on a pane says what is missing. A second one in the same
/// app session is almost always the stale-grant trap (macOS keys grants to the
/// code signature, so a listed, enabled Tintpad can still be refused), so the
/// line stops repeating itself and says the remedy where the problem is.
///
/// After Return has opened System Settings, the launch is held. The next
/// summon offers it back, never fires it: Accessibility is checked first
/// (`AXIsProcessTrusted`, cheap), Automation has no cheap check, so it gets a
/// neutral retry offer.
enum PermissionEscalation {
    /// "Accessibility" or "Automation access", as the lines name the pane.
    static func noun(_ pane: PrivacyPane) -> String {
        switch pane {
        case .accessibility: return "Accessibility"
        case .automation: return "Automation access"
        }
    }

    /// The permission line for the `failures`th failure on `pane` this
    /// session (1 is the first). Return opens the pane either way.
    static func line(pane: PrivacyPane, summary: String, failures: Int) -> String {
        if failures <= 1 {
            return "\(summary), Return opens System Settings, Esc cancels"
        }
        switch pane {
        case .accessibility:
            return "Still no Accessibility, if Tintpad is listed, remove it and add it back, Return opens the pane"
        case .automation:
            // Automation lists apps as toggles, there is nothing to add.
            return "Still no Automation access, if Tintpad is listed, switch it off and on, Return opens the pane"
        }
    }

    /// The offer a summon makes once the held launch may run. Accessibility
    /// was checked and is granted, Automation could not be checked.
    static func grantedLine(pane: PrivacyPane, repo: String, agent: String) -> String {
        switch pane {
        case .accessibility:
            return "\(noun(pane)) granted, Return launches \(repo) with \(agent)"
        case .automation:
            return "Return retries the launch in \(repo) with \(agent)"
        }
    }

    /// A held launch older than this is dropped on summon. Long enough to
    /// remove and re-add Tintpad in System Settings, short enough that the
    /// offer never names a launch from another part of the day.
    static let retryLifetime: TimeInterval = 600

    enum Resume: Equatable {
        /// Show the offer, Return runs the launch.
        case offer
        /// Not granted yet: keep holding, say nothing.
        case hold
        /// The launch can no longer be offered (its repo or agent is gone, or
        /// it is too old): forget it.
        case drop
    }

    /// What a summon does with a held launch.
    /// - Parameters:
    ///   - trusted: `AXIsProcessTrusted()` for `.accessibility`, ignored (and
    ///     best passed as nil) for `.automation`, which has no cheap check.
    ///   - age: seconds since Return opened System Settings.
    ///   - subjectPresent: the launch's repo, agent and mode still exist.
    static func resume(pane: PrivacyPane, trusted: Bool?, age: TimeInterval,
                       subjectPresent: Bool) -> Resume {
        guard subjectPresent, age <= retryLifetime else { return .drop }
        if pane == .accessibility && trusted != true { return .hold }
        return .offer
    }
}
