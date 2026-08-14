import XCTest
@testable import Hoyo

/// The career line is the one piece of the game's UI whose *absence* is a designed state, and
/// the only way to be sure of that is to assert it. Everything else here guards the fact that
/// these are the numbers a long-time player judges the app by — they must never go backwards
/// and must never appear before they mean anything.
final class CareerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Career.reset()
    }

    override func tearDown() {
        Career.reset()
        super.tearDown()
    }

    /// A fresh install must show nothing rather than a row of zeroes. "0 KM · 0 HOYOS" on the
    /// title screen reads as a broken save, which is the opposite of the reassurance the line
    /// exists to give.
    func testSilentUntilThreeRuns() {
        XCTAssertNil(Career.line, "a fresh install should have no career line")
        Career.add("runs", 1)
        Career.add("m", 3602)
        XCTAssertNil(Career.line, "one run is not a career")
        Career.add("runs", 1)
        XCTAssertNil(Career.line, "two runs is not a career")
        Career.add("runs", 1)
        XCTAssertNotNil(Career.line, "three runs is enough to be worth saying")
    }

    /// Distance is banked in metres and shown in kilometres. Reporting 3 km after three laps
    /// of a 3.6 km course would be visibly wrong to anyone who has played it.
    func testMetresRenderAsKilometres() {
        Career.add("runs", 3)
        Career.add("m", 3602 * 3)
        XCTAssertEqual(Career.line?.contains("10 KM"), true,
                       "10,806 m should read as 10 KM, got \(Career.line ?? "nil")")
    }

    /// The optional clauses are omitted at zero, not printed as "0 TAPADOS". A player who has
    /// never fired the beam should not be shown a running total of a thing they have not done.
    func testOptionalClausesAppearOnlyWhenEarned() {
        Career.add("runs", 3)
        Career.add("holes", 12)
        let bare = Career.line ?? ""
        XCTAssertFalse(bare.contains("TAPADOS"), "unearned clause should be absent, got \(bare)")
        XCTAssertFalse(bare.contains("VUELOS"), "unearned clause should be absent, got \(bare)")

        Career.add("sealed", 4)
        Career.add("floats", 2)
        let full = Career.line ?? ""
        XCTAssertTrue(full.contains("4 TAPADOS"), full)
        XCTAssertTrue(full.contains("2 VUELOS"), full)
    }

    /// Totals accumulate across calls. `add` reads-modifies-writes a single key, so a bug here
    /// would silently overwrite rather than accumulate and a career would never exceed its
    /// most recent run.
    func testTotalsAccumulate() {
        Career.add("holes", 5)
        Career.add("holes", 7)
        XCTAssertEqual(Career.holes, 12)
    }

    /// A zero increment must not write. `endGame` calls `add` for all five counters on every
    /// run, most of which are usually zero, and a write per counter per run is a pointless
    /// synchronous defaults flush on the frame a run ends.
    func testZeroDoesNotWrite() {
        Career.add("sealed", 0)
        XCTAssertNil(UserDefaults.standard.object(forKey: "hoyo_life_sealed"),
                     "adding zero should leave the key unset")
    }
}

/// `RunTrace.isEmpty` is what stops the results screen drawing a graph of nothing. A run that
/// ends in the first few metres has no shape to show, and four buckets of a 96-bucket axis is
/// under 5% of the course.
final class RunTraceTests: XCTestCase {

    func testTooShortToDraw() {
        XCTAssertTrue(RunTrace().isEmpty, "a default trace has nothing in it")
        XCTAssertTrue(RunTrace(speed: [0.1, 0.2, 0.3], hurt: [], end: 3).isEmpty,
                      "dying in the first metres should suppress the graph")
        XCTAssertFalse(RunTrace(speed: [0.1, 0.2, 0.3, 0.4, 0.5], hurt: [], end: 4).isEmpty,
                       "five buckets is a shape")
    }
}
