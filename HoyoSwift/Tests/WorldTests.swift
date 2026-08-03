import XCTest
@testable import Hoyo

/// The deterministic pieces the world is built from. `Lcg` in particular is load
/// bearing in a way that is easy to miss: the course mesh is generated from a
/// fixed seed, and the ghost replays an `(s, x, y)` trace against whatever course
/// the seed produces. If `Lcg` ever changed output for a given seed, every stored
/// ghost and every stored best time would silently refer to a road that no longer
/// exists.
final class LcgTests: XCTestCase {

    /// Same seed, same sequence — the property the whole persistence model rests on.
    func testSameSeedGivesSameSequence() {
        var a = Lcg(20260727), b = Lcg(20260727)
        for i in 0..<500 {
            XCTAssertEqual(a.next(), b.next(), "diverged at draw \(i)")
        }
    }

    func testDifferentSeedsDiverge() {
        var a = Lcg(1), b = Lcg(2)
        let left = (0..<50).map { _ in a.next() }
        let right = (0..<50).map { _ in b.next() }
        XCTAssertNotEqual(left, right)
    }

    /// Every call site treats the result as a 0…1 fraction — spawn positions, hole
    /// radii, building heights. A value outside that range would place geometry
    /// off the course rather than fail loudly.
    func testOutputStaysInUnitRange() {
        var rng = Lcg(20260727)
        for i in 0..<20_000 {
            let v = rng.next()
            XCTAssertGreaterThanOrEqual(v, 0, "draw \(i) below 0")
            XCTAssertLessThanOrEqual(v, 1, "draw \(i) above 1")
        }
    }

    /// Seed 0 would make a Park–Miller generator emit zero forever, so the
    /// initialiser remaps it. Worth pinning: the failure is a completely flat
    /// course rather than a crash.
    func testZeroSeedDoesNotCollapse() {
        var rng = Lcg(0)
        let draws = (0..<20).map { _ in rng.next() }
        XCTAssertGreaterThan(Set(draws).count, 15, "seed 0 collapsed to a constant")
    }

    /// A multiplicative generator that ever reaches its modulus is stuck. 2147483647
    /// is the modulus, so this is the one seed that must be remapped too.
    func testModulusSeedDoesNotCollapse() {
        var rng = Lcg(2147483647)
        let draws = (0..<20).map { _ in rng.next() }
        XCTAssertGreaterThan(Set(draws).count, 15, "modulus seed collapsed")
    }

    /// Rough uniformity. Not a statistics suite — just enough to catch a generator
    /// that has degenerated into a narrow band, which would cluster every pothole
    /// in the same part of the road.
    func testDrawsAreRoughlySpread() {
        var rng = Lcg(4242)
        var buckets = [Int](repeating: 0, count: 10)
        for _ in 0..<10_000 { buckets[min(Int(rng.next() * 10), 9)] += 1 }
        for (i, count) in buckets.enumerated() {
            XCTAssertGreaterThan(count, 600, "bucket \(i) starved: \(count)/10000")
            XCTAssertLessThan(count, 1_400, "bucket \(i) crowded: \(count)/10000")
        }
    }
}

/// Regions drive the terrain palette, the hazard mix and the banner. Gaps or
/// overlaps in their spans would leave a stretch of road with no region.
final class RegionTests: XCTestCase {

    func testSpansTileTheCourseWithoutGaps() {
        let ordered: [Region] = [.cordillera, .pueblo, .costa]
        XCTAssertEqual(ordered.first!.span.lo, 0, "course does not start in a region")
        XCTAssertEqual(ordered.last!.span.hi, 1, "course does not end in a region")
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertEqual(a.span.hi, b.span.lo, accuracy: 0.0001,
                           "gap or overlap between \(a.label) and \(b.label)")
        }
    }

    func testEveryPointOnTheCourseResolvesToItsSpan() {
        for i in 0...1000 {
            let p = Float(i) / 1000
            let r = Region.at(progress: p)
            XCTAssertGreaterThanOrEqual(p, r.span.lo - 0.0001,
                                        "progress \(p) mapped to \(r.label), which starts later")
            // hi is exclusive except at the very end of the course
            XCTAssertLessThanOrEqual(p, r.span.hi + 0.0001,
                                     "progress \(p) mapped to \(r.label), which ends earlier")
        }
    }

    /// Boundaries belong to the region starting there, matching the `>=` in `at`.
    func testBoundaryBelongsToTheLaterRegion() {
        XCTAssertEqual(Region.at(progress: Region.pueblo.span.lo), .pueblo)
        XCTAssertEqual(Region.at(progress: Region.costa.span.lo), .costa)
    }

    /// Progress is clamped upstream, but a negative or over-unity value should still
    /// land somewhere rather than fall through.
    func testOutOfRangeProgressStillResolves() {
        XCTAssertEqual(Region.at(progress: -0.5), .cordillera)
        XCTAssertEqual(Region.at(progress: 2.0), .costa)
    }
}

/// Every stage stores six separate values under string keys. A collision would
/// silently overwrite one record with another — a best time read as a score, or
/// one stage's ghost replayed on a different course.
final class StageKeyTests: XCTestCase {

    func testAllPersistenceKeysAreUnique() {
        var seen: [String: String] = [:]
        for stage in Stage.allCases {
            let keys = [
                ("bestScore", stage.bestScoreKey),
                ("bestTime", stage.bestTimeKey),
                ("ghost", stage.ghostKey),
                ("ghostSeed", stage.ghostSeedKey),
                ("endlessScore", stage.endlessScoreKey),
                ("endlessLap", stage.endlessLapKey)
            ]
            for (name, key) in keys {
                if let owner = seen[key] {
                    XCTFail("key '\(key)' used by both \(owner) and \(stage.name).\(name)")
                }
                seen[key] = "\(stage.name).\(name)"
            }
        }
        XCTAssertEqual(seen.count, Stage.allCases.count * 6)
    }

    /// `ghostKey` and `ghostSeedKey` must not be prefixes that could be confused,
    /// and neither may collide with the un-suffixed legacy keys still in the plist.
    func testKeysDoNotCollideWithLegacyGlobals() {
        let legacy = ["hoyo_bestScore", "hoyo_bestTime", "hoyo_mode", "hoyo_sawIntro"]
        for stage in Stage.allCases {
            for key in [stage.bestScoreKey, stage.bestTimeKey, stage.ghostKey,
                        stage.ghostSeedKey, stage.endlessScoreKey, stage.endlessLapKey] {
                XCTAssertFalse(legacy.contains(key), "\(key) shadows a legacy global")
            }
        }
    }

    /// Stage 1 is always playable; the others are earned. A regression here would
    /// either lock the player out entirely or hand them the whole game.
    func testFirstStageIsAlwaysUnlocked() {
        XCTAssertTrue(Stage.cordillera.unlocked)
    }

    func testStageChainIsComplete() {
        XCTAssertEqual(Stage.cordillera.next, .yunque)
        XCTAssertEqual(Stage.yunque.next, .playa)
        XCTAssertNil(Stage.playa.next, "last stage points at a stage that does not exist")
    }
}
