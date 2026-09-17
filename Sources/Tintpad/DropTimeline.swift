import Foundation

/// Why the drop is leaving. Each reason gets its own exit.
enum DismissReason: Equatable, CaseIterable {
    /// Return launched something: content leaves, the capsule shrinks back
    /// into the bead and is absorbed by the housing.
    case launch
    /// Esc: the same absorption, slightly quicker.
    case escape
    /// A click elsewhere: a quiet fade, nothing theatrical about losing focus.
    case focusLoss
}

/// The drop's beat tables: when each step of the arrival and of every exit
/// happens, in seconds from the start of the sequence. The numbers live here
/// and nowhere else, and `StepSequencer` plays them.
enum DropTimeline {
    enum Step: Equatable {
        // Arrival
        /// The bead swells at the housing's lip.
        case bead
        /// The bead expands in place into the capsule.
        case spread
        /// The search region and token strip arrive.
        case contentA
        /// The contract arrives.
        case contentB
        /// Reduce Motion: everything at once, crossfaded.
        case crossfadeIn
        // Exits
        /// Content leaves.
        case contentOut
        /// The capsule contracts back toward the bead.
        case shrink
        /// The bead is pulled into the housing.
        case absorb
        /// Opacity only.
        case fade
        /// The panel-level dismissal takes over (`DismissSequencer`).
        case close
    }

    struct Beat: Equatable {
        let at: TimeInterval
        let step: Step
    }

    static func arrival(reduceMotion: Bool) -> [Beat] {
        if reduceMotion { return [Beat(at: 0, step: .crossfadeIn)] }
        return [
            Beat(at: 0, step: .bead),
            Beat(at: 0.07, step: .spread),
            Beat(at: 0.17, step: .contentA),
            Beat(at: 0.20, step: .contentB),
        ]
    }

    static func exit(_ reason: DismissReason, reduceMotion: Bool) -> [Beat] {
        if reduceMotion {
            return [Beat(at: 0, step: .fade), Beat(at: 0.13, step: .close)]
        }
        switch reason {
        case .launch:
            return [
                Beat(at: 0, step: .contentOut),
                Beat(at: 0, step: .shrink),
                Beat(at: 0.20, step: .absorb),
                Beat(at: 0.29, step: .close),
            ]
        case .escape:
            // The same film as a launch, a touch quicker (the shrink step
            // itself runs 0.20 here against 0.24 for a launch).
            return [
                Beat(at: 0, step: .contentOut),
                Beat(at: 0, step: .shrink),
                Beat(at: 0.17, step: .absorb),
                Beat(at: 0.26, step: .close),
            ]
        case .focusLoss:
            return [
                Beat(at: 0, step: .fade),
                Beat(at: 0.15, step: .close),
            ]
        }
    }
}
