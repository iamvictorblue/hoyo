import XCTest
@testable import Hoyo

/// Medal thresholds have now been wrong twice, both times because they were
/// reasoned about rather than checked against what a course can actually pay.
/// The worst case shipped: Isla Verde's gold was 23,000 and its silver 15,500
/// against a course whose maximum is 12,824, so two of its three medals could not
/// be earned at any skill level and nobody noticed until a reviewer measured it.
///
/// These tests exist to make that a build failure instead of a discovery.
final class MedalTests: XCTestCase {

    /// The most a run can bank on each course: the autoplay driver made
    /// invulnerable and driven to the finish, so no crashes and no combo ever
    /// broken. Measured 2026-08-03 on the post-pursuit-nerf economy.
    ///
    /// If the economy changes these numbers go stale, and the reachability test
    /// below is what will say so. Re-measure rather than edit them to fit.
    static let measuredCeiling: [Stage: Int] = [
        .cordillera: 31_440,
        .yunque:     22_456,
        .playa:      12_824
    ]

    // MARK: - the bug that shipped

    /// Gold must be inside what the course pays, with room to spare. A threshold
    /// above the ceiling is not "hard", it is unreachable.
    func testGoldIsReachableOnEveryStage() {
        for stage in Stage.allCases {
            let ceiling = Self.measuredCeiling[stage]!
            let gold = stage.medalThresholds.gold
            XCTAssertLessThan(gold, ceiling,
                "\(stage.name): gold \(gold) exceeds the measured ceiling \(ceiling) — unearnable")
            // A gold sitting at 96% of a flawless run is nominally reachable and
            // still wrong; El Yunque was exactly there. Demand real headroom.
            XCTAssertLessThanOrEqual(Double(gold), Double(ceiling) * 0.90,
                "\(stage.name): gold \(gold) is \(Int(Double(gold) / Double(ceiling) * 100))% "
                + "of a flawless run — that is perfect-or-nothing")
        }
    }

    /// And gold should still be worth chasing rather than handed out for finishing.
    func testGoldIsNotTrivial() {
        for stage in Stage.allCases {
            let ceiling = Self.measuredCeiling[stage]!
            XCTAssertGreaterThan(Double(stage.medalThresholds.gold), Double(ceiling) * 0.65,
                "\(stage.name): gold is low enough that a mediocre run takes it")
        }
    }

    func testThresholdsAscend() {
        for stage in Stage.allCases {
            let t = stage.medalThresholds
            XCTAssertLessThan(t.bronze, t.silver, "\(stage.name): bronze not below silver")
            XCTAssertLessThan(t.silver, t.gold, "\(stage.name): silver not below gold")
            XCTAssertGreaterThan(t.bronze, 0, "\(stage.name): bronze is free")
        }
    }

    // MARK: - boundaries

    /// Exactly hitting a threshold earns that medal. `forScore` uses `>=`, and an
    /// off-by-one here is invisible in play but wrong at the moment it matters most.
    func testExactThresholdEarnsTheMedal() {
        for stage in Stage.allCases {
            let t = stage.medalThresholds
            XCTAssertEqual(Medal.forScore(t.gold, on: stage), .gold, "\(stage.name) gold edge")
            XCTAssertEqual(Medal.forScore(t.silver, on: stage), .silver, "\(stage.name) silver edge")
            XCTAssertEqual(Medal.forScore(t.bronze, on: stage), .bronze, "\(stage.name) bronze edge")
            XCTAssertEqual(Medal.forScore(t.bronze - 1, on: stage), Medal.none,
                           "\(stage.name): one short of bronze still earned one")
            XCTAssertEqual(Medal.forScore(t.gold - 1, on: stage), .silver,
                           "\(stage.name): one short of gold should be silver")
        }
    }

    func testZeroAndNegativeScoresEarnNothing() {
        for stage in Stage.allCases {
            XCTAssertEqual(Medal.forScore(0, on: stage), Medal.none)
            XCTAssertEqual(Medal.forScore(-500, on: stage), Medal.none)
        }
    }

    // MARK: - the "next medal" hint on the results screen

    /// The end screen promises "PA' ORO +N". If N were wrong the player would be
    /// told the wrong target, so check the arithmetic closes exactly.
    func testNextMedalGapLandsOnTheThreshold() {
        for stage in Stage.allCases {
            let t = stage.medalThresholds
            for score in [0, t.bronze - 1, t.bronze, t.silver - 1, t.silver, t.gold - 1] {
                guard let next = Medal.next(after: score, on: stage) else {
                    XCTFail("\(stage.name): no next medal offered at \(score)")
                    continue
                }
                XCTAssertGreaterThan(next.needed, 0,
                    "\(stage.name): offered a next medal that needs nothing at \(score)")
                XCTAssertEqual(Medal.forScore(score + next.needed, on: stage), next.medal,
                    "\(stage.name): paying the advertised \(next.needed) at \(score) "
                    + "does not actually earn \(next.medal.label)")
            }
            XCTAssertNil(Medal.next(after: t.gold, on: stage),
                         "\(stage.name): still offering a medal above gold")
        }
    }

    // MARK: - par times

    /// The finish bonus pays 90/second under par, so par above the ceiling run's
    /// time would hand out a bonus for a slow lap; far below it and it never pays.
    func testParTimesAreInAPlausibleBand() {
        for stage in Stage.allCases {
            XCTAssertGreaterThan(stage.parTime, 60, "\(stage.name): par is unreachably fast")
            XCTAssertLessThan(stage.parTime, 130, "\(stage.name): par pays out for a crawl")
        }
    }
}
