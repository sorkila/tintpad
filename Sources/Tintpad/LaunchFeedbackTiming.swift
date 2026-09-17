import Foundation

/// When the drop's gray waiting line ("Opening Ghostty…", "Creating
/// worktree…") may appear, and how long it must then stay. Pure so the rules
/// are tested without a clock.
///
/// A warm launch takes focus in about half a second and answers a little
/// later. Saying "Opening …" early and leaving a beat later flashes a line
/// nobody can read, so the Return is acknowledged wordlessly (the chip dims)
/// and the line only appears once the launch has visibly taken a while. Once
/// it has appeared it stays long enough to be read before the drop's launch
/// exit begins, however that exit was asked for.
///
/// The hold belongs to the drop's exit choreography only. The handoff and the
/// terminal never wait on it. Error, permission and note lines are not
/// waiting lines and take none of this: they show at once and stay until
/// acted on.
enum LaunchFeedbackTiming {
    /// A launch still in flight this long after it started shows its line.
    /// Past a warm Ghostty handoff (focus taken at about 450ms, the answer at
    /// about 800ms), so a warm launch never shows one.
    static let showDelay: TimeInterval = 0.7
    /// A waiting line that appeared stays at least this long before the
    /// launch exit plays.
    static let minVisible: TimeInterval = 0.6
    /// A launch still in flight this long after it started says so.
    static let stillOpening: TimeInterval = 4

    /// Seconds from `now` until the waiting line of a launch that started at
    /// `start` is due, zero when it is already due.
    static func lineDelay(start: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0, start + showDelay - now)
    }

    /// How long a launch exit asked for at `requestedAt` must wait, when the
    /// waiting line appeared at `lineShownAt` (nil when it never did).
    /// Measured from the line alone: whether the launch has answered yet
    /// makes no difference.
    static func exitDelay(lineShownAt: TimeInterval?, requestedAt: TimeInterval) -> TimeInterval {
        guard let lineShownAt else { return 0 }
        return max(0, lineShownAt + minVisible - requestedAt)
    }
}
