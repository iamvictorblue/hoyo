import XCTest
@testable import Hoyo

/// The migration rewrites real records, so it gets tested before it runs on a
/// device. The failure mode it exists to prevent already happened twice: the
/// scoring economy changed underneath stored scores and nothing recorded which
/// rules a given number was set under.
final class SaveSchemaTests: XCTestCase {

    private var d: UserDefaults!

    override func setUp() {
        super.setUp()
        // An isolated suite, so a test run cannot touch the simulator's real save.
        d = UserDefaults(suiteName: "hoyo.tests.\(UUID().uuidString)")
    }

    /// A player upgrading from a pre-versioning build: scores move aside, and the
    /// things the economy does not affect stay exactly where they were.
    func testUpgradeArchivesScoresButKeepsTimesAndUnlocks() {
        d.set(22_603, forKey: Stage.cordillera.bestScoreKey)
        d.set(79.6, forKey: Stage.cordillera.bestTimeKey)
        d.set(true, forKey: "hoyo_unlocked_1")
        d.set(Data([1, 2, 3, 4]), forKey: Stage.cordillera.ghostKey)

        SaveSchema.migrateIfNeeded(d)

        XCTAssertNil(d.object(forKey: Stage.cordillera.bestScoreKey),
                     "a score from the old economy is still being shown as a target")
        XCTAssertEqual(SaveSchema.archivedScore(for: .cordillera, d), 22_603,
                       "the old score was destroyed rather than archived")
        XCTAssertEqual(d.double(forKey: Stage.cordillera.bestTimeKey), 79.6,
                       "a lap time is a lap time — the economy does not change it")
        XCTAssertTrue(d.bool(forKey: "hoyo_unlocked_1"), "progress was lost")
        XCTAssertNotNil(d.data(forKey: Stage.cordillera.ghostKey),
                        "the ghost was discarded; course geometry did not change")
    }

    func testFreshInstallArchivesNothing() {
        SaveSchema.migrateIfNeeded(d)
        XCTAssertEqual(d.integer(forKey: "hoyo_schemaVersion"), SaveSchema.current)
        XCTAssertNil(SaveSchema.archivedScore(for: .cordillera, d))
    }

    /// Launching repeatedly must not re-archive an already-migrated save, which
    /// would wipe scores set legitimately under the current rules.
    func testMigrationIsIdempotent() {
        d.set(9_000, forKey: Stage.playa.bestScoreKey)
        SaveSchema.migrateIfNeeded(d)
        XCTAssertNil(d.object(forKey: Stage.playa.bestScoreKey))

        d.set(11_500, forKey: Stage.playa.bestScoreKey)   // earned under v2
        SaveSchema.migrateIfNeeded(d)
        SaveSchema.migrateIfNeeded(d)
        XCTAssertEqual(d.integer(forKey: Stage.playa.bestScoreKey), 11_500,
                       "a second launch archived a score set under the current rules")
    }

    func testEndlessScoresAreArchivedToo() {
        d.set(6_182, forKey: Stage.playa.endlessScoreKey)
        d.set(3, forKey: Stage.playa.endlessLapKey)
        SaveSchema.migrateIfNeeded(d)
        XCTAssertNil(d.object(forKey: Stage.playa.endlessScoreKey))
        XCTAssertEqual(d.integer(forKey: Stage.playa.endlessLapKey), 3,
                       "lap count is a distance, not a score — it should survive")
    }
}
