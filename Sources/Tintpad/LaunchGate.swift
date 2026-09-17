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
