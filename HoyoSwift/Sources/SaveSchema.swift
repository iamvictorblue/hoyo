import Foundation

/// Versioning for everything the game persists.
///
/// This exists because the problem already happened twice. Medal thresholds were
/// re-anchored once from content counts and again from measured ceilings, and the
/// scoring economy changed underneath them — speed-weighted distance income, a
/// finish bonus, then a rebalanced pursuit bounty. Each time, the numbers already
/// in `UserDefaults` silently meant something different from the numbers being
/// written next to them, with nothing recording which era a given score came from.
///
/// A score is only comparable to the rules it was set under. Keeping the version
/// alongside the data is what makes it possible to change the rules again without
/// either corrupting the record or quietly lying about it.
enum SaveSchema {
    /// Bump on any change that alters what a stored value *means*.
    ///
    /// 1 — original economy: distance income a flat 1.2/m, no finish bonus,
    ///     cruiser bounties at 300 x combo and unbounded.
    /// 2 — current: speed-weighted distance, 90/s finish bonus under par, flat 260
    ///     cruiser bounty, and medal thresholds anchored on measured ceilings.
    static let current = 2

    private static let versionKey = "hoyo_schemaVersion"

    /// Per-stage score keys, which are the only values whose meaning the economy
    /// changes. Times, unlocks and the ghost trace are all still valid across it:
    /// a lap time is a lap time, and the course geometry is generated from a fixed
    /// seed that has not moved.
    private static var scoreKeys: [String] {
        Stage.allCases.flatMap { [$0.bestScoreKey, $0.endlessScoreKey] }
            + ["hoyo_bestScore"]
    }

    /// Runs once at launch, before anything reads a record.
    static func migrateIfNeeded(_ d: UserDefaults = .standard) {
        let stored = d.integer(forKey: versionKey)
        guard stored != current else { return }

        if stored == 0 {
            // Either a fresh install or a build from before versioning existed.
            // Distinguished by whether any record is present at all.
            let hasHistory = scoreKeys.contains { d.object(forKey: $0) != nil }
            if hasHistory { retireScores(d, from: "pre-versioning") }
        } else if stored < current {
            retireScores(d, from: "v\(stored)")
        }

        d.set(current, forKey: versionKey)
    }

    /// Moves scores aside rather than deleting them. They are not comparable to the
    /// new economy, so leaving them in place would show a record nobody can chase
    /// and hand out medals the run never earned — but they are also the only trace
    /// of what someone actually did, so they are archived, not destroyed.
    private static func retireScores(_ d: UserDefaults, from era: String) {
        for key in scoreKeys {
            guard let value = d.object(forKey: key) else { continue }
            d.set(value, forKey: "\(key)_archived_\(era)")
            d.removeObject(forKey: key)
        }
    }

    /// Archived records from an earlier economy, for anything that wants to show
    /// them as history rather than as a target.
    static func archivedScore(for stage: Stage, _ d: UserDefaults = .standard) -> Int? {
        let matches = d.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(stage.bestScoreKey)_archived_") }
        return matches.compactMap { d.object(forKey: $0) as? Int }.max()
    }
}
