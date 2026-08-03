import XCTest
import simd
@testable import Hoyo

/// A beam bolt travels 115 m/s and `dt` is clamped at 0.033 s, so it advances up
/// to 3.8 m per frame. Testing only where it ended let it pass straight through
/// cars — a bug that shipped and had to be found by playing.
final class SweepTests: XCTestCase {

    private let boltSpeed: Float = 115
    private let maxDt: Float = 0.033

    /// The regression itself: a target sitting between where the bolt was and
    /// where it ended must be hit.
    func testTargetInsideTheGapIsNotTunnelledThrough() {
        let from: Float = 100
        let to = from + boltSpeed * maxDt          // 103.8
        let sweep = Sweep(from: from, to: to, x: 0, pad: 1.4)
        // dead centre of the jump, where a point test would miss entirely
        XCTAssertTrue(sweep.hits(s: 101.9, x: 0, tolerance: 2.6),
                      "a target mid-gap was missed — this is the tunnelling bug")
        for step in stride(from: Float(0), through: 1, by: 0.05) {
            let s = from + (to - from) * step
            XCTAssertTrue(sweep.hits(s: s, x: 0, tolerance: 2.6),
                          "missed a target at \(s), \(Int(step * 100))% along the sweep")
        }
    }

    /// A point-in-window test is what the sweep replaced. Demonstrating that it
    /// fails here is what proves the sweep is doing something.
    func testAPointTestWouldHaveMissed() {
        let from: Float = 100
        let to = from + boltSpeed * maxDt
        let target: Float = 101.9
        XCTAssertFalse(abs(to - target) < 1.4,
                       "the endpoint is close enough that this test proves nothing")
        XCTAssertTrue(Sweep(from: from, to: to, x: 0, pad: 1.4)
                        .hits(s: target, x: 0, tolerance: 2.6))
    }

    func testPadExtendsBothEnds() {
        let sweep = Sweep(from: 50, to: 60, x: 0, pad: 1.4)
        XCTAssertTrue(sweep.hits(s: 48.7, x: 0, tolerance: 1), "pad missing behind the start")
        XCTAssertTrue(sweep.hits(s: 61.3, x: 0, tolerance: 1), "pad missing past the end")
        XCTAssertFalse(sweep.hits(s: 48.5, x: 0, tolerance: 1))
        XCTAssertFalse(sweep.hits(s: 61.5, x: 0, tolerance: 1))
    }

    /// Tolerance is per-target — a car is wider than a coquí — so the same sweep
    /// must accept and reject on width alone.
    func testLateralToleranceIsRespected() {
        let sweep = Sweep(from: 10, to: 12, x: 0, pad: 1.4)
        XCTAssertTrue(sweep.hits(s: 11, x: 2.5, tolerance: 2.6))
        XCTAssertFalse(sweep.hits(s: 11, x: 2.7, tolerance: 2.6))
        XCTAssertFalse(sweep.hits(s: 11, x: 0.9, tolerance: 0.8), "narrow target hit too easily")
    }

    /// `lo`/`hi` are ordered rather than assumed. The original code computed them
    /// as `prev - pad` and `now + pad`, which inverts into a span that can never
    /// match if anything ever travels backwards.
    func testBackwardsTravelStillProducesAValidSpan() {
        let sweep = Sweep(from: 60, to: 50, x: 0, pad: 1.4)
        XCTAssertLessThan(sweep.lo, sweep.hi)
        XCTAssertTrue(sweep.hits(s: 55, x: 0, tolerance: 1),
                      "a reversed sweep matched nothing")
    }
}

/// The jump chain and float. Every case here is something that was wrong at some
/// point: a held button that kept the craft airborne for most of a run, and a
/// float that could be entered without paying for it.
final class JumpStateTests: XCTestCase {

    private let dt: Float = 1.0 / 60

    /// Holds the jump button for `seconds` and reports the fraction of frames spent
    /// off the ground. `nitroRegen` matches the game's own 3.5/s.
    private func airborneFraction(seconds: Float,
                                  nitro startingNitro: Float,
                                  nitroRegen: Float = 3.5) -> Float {
        var jump = JumpState()
        var nitro = startingNitro
        var frames = 0, air = 0
        while Float(frames) * dt < seconds {
            jump.advanceTimers(dt: dt)
            _ = jump.requestJump(speed: 40, nitro: &nitro)   // held down
            _ = jump.advanceMotion(dt: dt)
            if jump.airborne { air += 1 }
            frames += 1
            nitro = min(100, nitro + nitroRegen * dt)
        }
        return Float(air) / Float(frames)
    }

    /// The regression: hopping on a held button kept the craft airborne 92–95% of a
    /// run, which made every hazard that checks `airborne` unreachable. Run with no
    /// nitro so every float is denied and this measures the hop cadence alone —
    /// which is what the landing cooldown governs.
    func testHoldingJumpDoesNotKeepTheCraftPermanentlyAirborne() {
        let fraction = airborneFraction(seconds: 30, nitro: 0, nitroRegen: 0)
        XCTAssertLessThan(fraction, 0.80,
            "airborne \(Int(fraction * 100))% of the time hopping on a held button — "
            + "hazards that check `airborne` become unreachable")
    }

    /// With nitro available the same held button *should* spend most of its time up,
    /// because every third hop buys a deliberate ten-second float. Recorded so the
    /// test above is not mistaken for a cap on airtime in general.
    func testFloatingIsAllowedToDominateWhenNitroPaysForIt() {
        let fraction = airborneFraction(seconds: 30, nitro: 100)
        XCTAssertGreaterThan(fraction, 0.80,
            "floats are being denied when nitro should be affording them")
    }

    /// Which is only true because recovery is charged on landing. A cooldown set
    /// at take-off is shorter than the airtime and can never bind.
    func testCooldownIsChargedOnLandingNotTakeOff() {
        var jump = JumpState()
        var nitro: Float = 0
        let r1 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r1, .hop(chain: 1))
        XCTAssertEqual(jump.cool, 0, "a cooldown at take-off would expire mid-flight")
        // Bounded. An unbounded wait here hung the whole suite for 21 minutes when
        // the state did not reach the ground; a test must fail, never stall.
        var frames = 0
        while jump.advanceMotion(dt: dt) == nil {
            frames += 1
            if frames > 600 { return XCTFail("never landed after 10s of simulated flight") }
        }
        XCTAssertGreaterThan(jump.cool, 0.4, "no recovery charged on touchdown")
    }

    // MARK: - the chain

    func testThreeJumpsInRhythmProduceAFloat() {
        var jump = JumpState()
        var nitro: Float = 100
        let r2 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r2, .hop(chain: 1))
        land(&jump)
        let r3 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r3, .hop(chain: 2))
        land(&jump)
        let r4 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r4, .float)
        XCTAssertTrue(jump.floating)
        XCTAssertEqual(nitro, 50, "a float should cost exactly floatCost")
    }

    /// Let the window lapse and the chain must be forgotten, or a hop taken a
    /// minute later would float unexpectedly.
    func testChainExpiresAfterTheWindow() {
        var jump = JumpState()
        var nitro: Float = 100
        _ = jump.requestJump(speed: 40, nitro: &nitro)
        land(&jump)
        _ = jump.requestJump(speed: 40, nitro: &nitro)
        land(&jump)
        var elapsed: Float = 0
        while elapsed < JumpState.chainWindow + 0.2 {
            jump.advanceTimers(dt: dt)
            _ = jump.advanceMotion(dt: dt)
            elapsed += dt
        }
        XCTAssertEqual(jump.chain, 0, "chain survived its window")
        let r5 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r5, .hop(chain: 1),
                       "a stale chain floated on the next single hop")
    }

    /// A denied float must clear the chain. If it stayed armed at 3, the *next*
    /// single hop would float the moment nitro came back.
    func testDeniedFloatClearsTheChain() {
        var jump = JumpState()
        var nitro: Float = 10                              // below floatCost
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        let r6 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r6, .floatDenied)
        XCTAssertEqual(jump.chain, 0, "chain left armed after a denied float")
        XCTAssertEqual(nitro, 10, "a denied float still charged for it")
        XCTAssertFalse(jump.floating)
        land(&jump)
        nitro = 100
        let r7 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r7, .hop(chain: 1),
                       "the hop after a denied float floated unexpectedly")
    }

    // MARK: - refusals

    func testCannotJumpWhileAirborne() {
        var jump = JumpState()
        var nitro: Float = 100
        _ = jump.requestJump(speed: 40, nitro: &nitro)
        _ = jump.advanceMotion(dt: dt)
        let r8 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r8, .refused)
    }

    func testCannotJumpTooSlowly() {
        var jump = JumpState()
        var nitro: Float = 100
        let r9 = jump.requestJump(speed: 2, nitro: &nitro)
        XCTAssertEqual(r9, .refused)
        XCTAssertEqual(jump.chain, 0, "a refused jump still counted toward a float")
    }

    func testCannotJumpWhileFloating() {
        var jump = JumpState()
        var nitro: Float = 100
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        let r10 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r10, .float)
        let r11 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r11, .refused)
    }

    // MARK: - the float itself

    func testFloatRisesAndHoldsThenFalls() {
        var jump = JumpState()
        var nitro: Float = 100
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        let r12 = jump.requestJump(speed: 40, nitro: &nitro)
        XCTAssertEqual(r12, .float)

        // climbs to altitude well inside the hold
        var t: Float = 0
        while t < 4 { jump.advanceTimers(dt: dt); _ = jump.advanceMotion(dt: dt); t += dt }
        XCTAssertGreaterThan(jump.y, JumpState.floatHeight * 0.9,
                             "did not reach float altitude")
        XCTAssertTrue(jump.floating)

        // still up at the end of the advertised duration
        while t < JumpState.floatDuration - 0.3 {
            jump.advanceTimers(dt: dt); _ = jump.advanceMotion(dt: dt); t += dt
        }
        XCTAssertTrue(jump.floating, "float ended before its stated duration")

        // and comes down afterwards
        var landing: Landing?
        while landing == nil, t < JumpState.floatDuration + 8 {
            jump.advanceTimers(dt: dt)
            landing = jump.advanceMotion(dt: dt)
            t += dt
        }
        XCTAssertNotNil(landing, "never came down from a float")
        XCTAssertEqual(jump.y, 0)
    }

    /// A fall from 12 m must report a harder landing than a hop, since shake,
    /// haptics and dust are all scaled from it.
    func testFallFromFloatLandsHarderThanAHop() {
        var hop = JumpState()
        var nitro: Float = 100
        _ = hop.requestJump(speed: 40, nitro: &nitro)
        var hopLanding: Landing?
        var hopFrames = 0
        while hopLanding == nil, hopFrames < 600 {
            hopLanding = hop.advanceMotion(dt: dt); hopFrames += 1
        }
        guard let hopLanding else { return XCTFail("the hop never landed") }

        var jump = JumpState()
        nitro = 100
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        _ = jump.requestJump(speed: 40, nitro: &nitro)
        var floatLanding: Landing?
        var t: Float = 0
        while floatLanding == nil, t < 30 {
            jump.advanceTimers(dt: dt)
            floatLanding = jump.advanceMotion(dt: dt)
            t += dt
        }
        guard let floatLanding else { return XCTFail("the float never landed") }
        XCTAssertGreaterThan(floatLanding.impact, hopLanding.impact * 1.5,
            "a 12 m drop reported about the same impact as a 2.3 m hop")
    }

    func testControlFactorFavoursFloatOverAPlainHop() {
        var ground = JumpState()
        XCTAssertEqual(ground.controlFactor, 1)

        var nitro: Float = 100
        _ = ground.requestJump(speed: 40, nitro: &nitro)
        _ = ground.advanceMotion(dt: dt)
        let hopControl = ground.controlFactor

        var jump = JumpState()
        nitro = 100
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        _ = jump.requestJump(speed: 40, nitro: &nitro); land(&jump)
        _ = jump.requestJump(speed: 40, nitro: &nitro)
        _ = jump.advanceMotion(dt: dt)
        XCTAssertGreaterThan(jump.controlFactor, hopControl,
            "ten seconds of hop-level steering would be a punishment, not a reward")
        XCTAssertLessThan(jump.controlFactor, 1)
    }

    func testResetClearsEverything() {
        var jump = JumpState()
        var nitro: Float = 100
        _ = jump.requestJump(speed: 40, nitro: &nitro)
        _ = jump.advanceMotion(dt: dt)
        jump.reset()
        XCTAssertEqual(jump, JumpState(), "reset left state behind between runs")
    }

    // MARK: -

    /// Advances until the craft is genuinely on the road, so a chain can continue.
    ///
    /// Waits on `grounded`, not `!airborne`: the descent passes through the 0.02
    /// dead zone where `airborne` is already false but the landing has not fired,
    /// and stopping there leaves the next request refused.
    private func land(_ jump: inout JumpState) {
        var guardCount = 0
        while !jump.grounded {
            _ = jump.advanceMotion(dt: dt)
            guardCount += 1
            if guardCount > 10_000 { return XCTFail("never landed") }
        }
        // burn off the landing cooldown so the next request is accepted
        var cooling = 0
        while jump.cool > 0, cooling < 10_000 { jump.advanceTimers(dt: dt); cooling += 1 }
    }
}
