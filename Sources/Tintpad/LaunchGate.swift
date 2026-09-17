import Foundation

/// What a launch gesture (⏎, a click on a tile, ⌘1–⌘9, ⌘0) may do right now.
/// Pure so the double-launch rules can be tested without a palette.
enum LaunchGate {
    enum Disposition: Equatable {
        /// Nothing is running and nothing is showing, go ahead.
        case launch
        /// A launch is already underway, a queued key must not start another.
        case ignore
        /// A finished launch left a note (Warp). The gesture acknowledges it
        /// and closes the drop, it never launches the same thing twice.
        case closeOnly
    }

    /// - Parameters:
    ///   - inFlight: a launch has been requested and has not returned yet.
    ///   - dismissing: an exit is playing, or has played and the panel is on
    ///     its way out. It stays true until the next summon.
    ///   - noteShown: a completed launch left a note in the drop.
    static func returnDisposition(inFlight: Bool, dismissing: Bool, noteShown: Bool) -> Disposition {
        if inFlight || dismissing { return .ignore }
        if noteShown { return .closeOnly }
        return .launch
    }
}

/// Where a launch's answer lands once its handoff returns. Pure so the rules
/// for a drop that has moved on (Esc, a click elsewhere, a re-summon) are
/// tested without a palette.
enum LaunchAnswerPolicy {
    enum Disposition: Equatable {
        /// The drop that started the launch is still up: close, show the
        /// note, or show the error line, as usual.
        case land
        /// A success whose drop has gone, or a newer drop that is up: nothing
        /// to say, the terminal opening is the answer.
        case silent
        /// A failure from an older summon while a newer drop is up and idle:
        /// say it there now, with the failed launch's repo as the subject,
        /// rather than at some arbitrary later summon.
        case reportNow
        /// A failure while no drop is up (hidden, or its exit playing): hold
        /// it for the next summon, if that comes soon (`deferredLifetime`).
        case deferUntilSummon
    }

    /// A held failure older than this is dropped on summon. Past it, the
    /// line would name a launch the user no longer has in mind.
    static let deferredLifetime: TimeInterval = 30

    /// - Parameters:
    ///   - succeeded: the handoff answered with success.
    ///   - ownDrop: the drop showing now is the summon that started the launch.
    ///   - dropPresent: a drop is visible and not playing an exit.
    ///   - dropBusy: that drop is asking something of its own (a confirm, a
    ///     permission line, a worktree or prompt capture), which an old
    ///     failure must not overwrite.
    static func disposition(succeeded: Bool, ownDrop: Bool,
                            dropPresent: Bool, dropBusy: Bool) -> Disposition {
        if ownDrop && dropPresent { return .land }
        if succeeded { return .silent }
        if dropPresent && !dropBusy { return .reportNow }
        return .deferUntilSummon
    }

    /// Whether a held failure still surfaces on a summon `age` seconds later.
    static func surfacesDeferred(age: TimeInterval) -> Bool {
        age <= deferredLifetime
    }
}
