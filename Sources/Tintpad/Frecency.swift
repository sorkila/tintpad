import Foundation

/// Frecency (frequency + recency) ranking using `fre`'s continuous half-life
/// decay model rather than zoxide's bucketed multipliers.
///
/// Each repo keeps a single `frecencyScore` anchored at `lastLaunchedAt`. The
/// score decays continuously: after one half-life, a visit is worth half as
/// much. This avoids the "old dir jumps to the top after one revisit" artifact
/// of bucketed schemes — recency and frequency trade off smoothly.
enum Frecency {
    /// The decayed score of a repo *as of `now`* — used for sorting/display.
    static func decayedScore(_ repo: Repo, now: Date, halfLifeDays: Double) -> Double {
        guard let last = repo.lastLaunchedAt, repo.frecencyScore > 0 else {
            return repo.frecencyScore
        }
        let elapsed = now.timeIntervalSince(last)
        let halfLife = max(halfLifeDays, 0.001) * 86_400
        let factor = pow(0.5, elapsed / halfLife)
        return repo.frecencyScore * factor
    }

    /// Record a visit: decay the stored score to `now`, add one unit, re-anchor.
    static func recordVisit(_ repo: inout Repo, now: Date, halfLifeDays: Double) {
        let current = decayedScore(repo, now: now, halfLifeDays: halfLifeDays)
        repo.frecencyScore = current + 1
        repo.lastLaunchedAt = now
        repo.launchCount += 1
    }
}
