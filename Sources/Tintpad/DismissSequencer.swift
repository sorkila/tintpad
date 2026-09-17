import Foundation

/// The panel's dismissal, as a pure state machine the controller only executes.
///
/// Why a sequence and not one `orderOut`: the window server can keep the last
/// frame it composited for a window that is ordered out while AppKit still
/// believes it is on screen (the app hidden in the same turn, or the order-out
/// running inside AppKit's own deactivation pass). The capsule is black
/// against the black housing, so what stays stranded on the desktop is its
/// shadow. The fix is an order of operations:
///
///   1. **Blank.** Alpha to 0 and the drop reset to rest, so any frame the
///      server keeps from here on is fully transparent.
///   2. **Order out**, one runloop turn later, once the blank is committed.
///   3. **Hide the app**, one more turn later, returning focus to whatever
///      was frontmost before the summon.
///
/// A summon at any point cancels what hasn't happened yet: the generation
/// moves, so a blank commit still queued for the old dismissal is ignored.
struct DismissSequencer: Equatable {
    enum State: Equatable { case visible, blanking(generation: Int), hidden }
    enum Event: Equatable {
        case dismiss
        case blankCommitted(generation: Int)
        case summon
        /// The panel was ordered out outside the sequence (opening Settings),
        /// so the next summon must still restore it.
        case orderedOut
    }
    enum Effect: Equatable { case blank, orderOut, hideAppNextTurn, restoreAndOrderIn }

    private(set) var state: State = .hidden
    /// Moves on every dismissal and every summon. Anything deferred captures
    /// it and stands down if it changed in the meantime.
    private(set) var generation = 0

    var isDismissing: Bool {
        if case .blanking = state { return true } else { return false }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.visible, .dismiss):
            generation += 1
            state = .blanking(generation: generation)
            return [.blank]
        case (.blanking(let g), .blankCommitted(let committed)) where g == committed:
            state = .hidden
            return [.orderOut, .hideAppNextTurn]
        case (.blanking, .summon), (.hidden, .summon):
            generation += 1
            state = .visible
            return [.restoreAndOrderIn]
        case (.visible, .summon):
            // Already up, but the generation still moves, so a focus-loss hide
            // deferred by the controller stands down when a summon lands on top.
            generation += 1
            return []
        case (_, .orderedOut):
            generation += 1
            state = .hidden
            return []
        default:
            // Already dismissing, already hidden, or a stale commit.
            return []
        }
    }
}
