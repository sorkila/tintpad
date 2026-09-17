import Foundation

/// Runs a timed sequence of beats on the main actor, interruptibly.
///
/// Replaces nested `asyncAfter` chains, which cannot be cancelled: a re-summon
/// mid-arrival used to let the old chain keep firing into the new one. Every
/// `run` and `cancel` moves a generation counter, and every scheduled beat
/// checks it before firing, so only the latest sequence ever acts.
///
/// Beat times are absolute offsets from the `run` call, not gaps between
/// beats. Beats that share a time fire together, in the order given. Every
/// beat goes through the scheduler, a time-0 beat included, so state a caller
/// sets synchronously before `run` commits a frame before the first beat
/// animates away from it.
@MainActor
final class StepSequencer {
    typealias Action = @MainActor () -> Void
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    struct Beat {
        let at: TimeInterval
        let action: Action
    }

    private let schedule: Scheduler
    /// Moves on every `run` and `cancel`. A scheduled beat from an older
    /// generation stands down.
    private(set) var generation = 0

    init(schedule: @escaping Scheduler = StepSequencer.mainQueue) {
        self.schedule = schedule
    }

    static let mainQueue: Scheduler = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            MainActor.assumeIsolated { action() }
        }
    }

    /// Cancel whatever is running, then play `beats`.
    func run(_ beats: [Beat]) {
        generation &+= 1
        let current = generation
        // Stable grouping by time, so equal-time beats keep their given order
        // without relying on the scheduler's FIFO guarantees.
        var groups: [(at: TimeInterval, actions: [Action])] = []
        for beat in beats.enumerated().sorted(by: {
            $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
        }).map(\.element) {
            if let last = groups.last, last.at == beat.at {
                groups[groups.count - 1].actions.append(beat.action)
            } else {
                groups.append((beat.at, [beat.action]))
            }
        }
        for group in groups {
            schedule(group.at) { [weak self] in
                for action in group.actions {
                    // Re-checked per action: a beat may itself cancel or rerun.
                    guard let self, self.generation == current else { return }
                    action()
                }
            }
        }
    }

    /// Drop every beat that hasn't fired yet.
    func cancel() {
        generation &+= 1
    }
}
