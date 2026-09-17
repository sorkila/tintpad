import Foundation

/// When the drop's gray waiting line ("Opening Ghostty…", "Creating
/// worktree…") may appear, and how long it must then stay. Pure so the rules
/// are tested without a clock.
///
/// A warm launch answers in about 100ms. Saying "Opening …" on Return and
/// leaving a beat later flashes a line nobody can read, so the Return is
/// acknowledged wordlessly (the subject chip dims) and the line only appears
/// once the launch has visibly taken a while. Once it has appeared it stays
/// long enough to be read before the drop's launch exit begins.
///
/// The hold belongs to the drop's exit choreography only. The handoff and the
/// terminal never wait on it. Error, permission and note lines are not
/// waiting lines and take none of this: they show at once and stay until
/// acted on.
enum LaunchFeedbackTiming {
    /// A launch still in flight this long after it started shows its line.
    static let showDelay: TimeInterval = 0.35
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

    /// How long the launch exit must wait when it is asked for at
    /// `completedAt`, for a launch that started at `start` and whose waiting
    /// line appeared at `lineShownAt` (nil when it never did).
    ///
    /// A line cannot have been seen before it was due, so an earlier stamp
    /// counts from the due time.
    static func exitDelay(start: TimeInterval, lineShownAt: TimeInterval?,
                          completedAt: TimeInterval) -> TimeInterval {
        guard let lineShownAt else { return 0 }
        let shown = max(lineShownAt, start + showDelay)
        return max(0, shown + minVisible - completedAt)
    }
}
