import simd

/// Pure gameplay maths, lifted out of `GameScene` so it can be tested.
///
/// Everything here has produced a real bug at least once. `GameScene` is a
/// 4,400-line renderer delegate whose state is private and only observable by
/// playing the game, which is exactly why these particular mistakes survived
/// review: a bolt that passes through a car, a hazard that hurts you 12 m above
/// it, a jump chain that fires when it should not.

// MARK: - swept collision

/// The span a fast-moving object covered during one frame.
///
/// A point-in-window test is not enough here. A beam bolt travels 115 m/s and
/// `dt` is clamped at 0.033 s to survive frame hitches, so it advances up to
/// 3.8 m per frame — further than any sane hit window. Testing only where it
/// *ended* let it tunnel straight through cars.
struct Sweep {
    let lo: Float
    let hi: Float
    let x: Float

    /// - Parameters:
    ///   - from: distance along the course at the start of the frame
    ///   - to: distance at the end of the frame
    ///   - x: lateral position
    ///   - pad: slack added at both ends, covering the target's own half-length
    ///
    /// `from` and `to` are ordered rather than assumed, so this stays correct for
    /// anything travelling backwards relative to the course.
    init(from: Float, to: Float, x: Float, pad: Float) {
        lo = min(from, to) - pad
        hi = max(from, to) + pad
        self.x = x
    }

    /// True when a target anywhere in the swept span is within `tolerance`
    /// laterally. `tolerance` is per-target: a car is wider than a coquí.
    func hits(s: Float, x targetX: Float, tolerance: Float) -> Bool {
        s >= lo && s <= hi && abs(targetX - x) < tolerance
    }
}

// MARK: - jump, chain and float

/// What a jump request produced, so the caller can pick the sound, the haptic and
/// the popup without re-deriving the decision.
enum JumpOutcome: Equatable {
    /// Not moving fast enough, still airborne, or still in the landing cooldown.
    case refused
    /// An ordinary hop. `chain` is how many are now banked toward a float.
    case hop(chain: Int)
    /// The third hop in the rhythm, traded for altitude.
    case float
    /// Three were banked but there was not enough nitro to spend, so it hopped
    /// and the chain reset. Distinct from `hop` because it needs to say why.
    case floatDenied
}

/// Reported on the frame the craft touches down, so the caller can scale the
/// shake, the haptic and the dust to the drop rather than using one fixed thump.
struct Landing: Equatable {
    /// 0…1, from a light hop to a fall out of a full float.
    let impact: Float
}

/// The vertical state of the craft: hop, chain, float, fall, land.
///
/// Extracted because every part of it has been wrong at some point. The chain
/// once counted a jump that never fired; the float once left the craft able to
/// collect pickups from 12 m up; and the landing cooldown was charged at take-off
/// where, being shorter than the airtime, it could never bind — which let a held
/// button keep the craft airborne for 92% of a run.
struct JumpState: Equatable {
    // tuning, matching the values GameScene used before extraction
    static let gravity: Float = 24
    static let impulse: Float = 10.6
    /// How long a banked hop stays banked. 3.0, up from 2.0, on playtest evidence.
    ///
    /// The chain indicator went in first on the theory that the chain was hard because
    /// it was invisible rather than because it was tight. That turned out to be only
    /// half right: with the ring on the SALTA button the chain is legible and still
    /// hard to complete, which is what this number is for.
    ///
    /// The arithmetic says why. A hop is airborne for 2 * impulse / gravity = 0.88 s and
    /// lands with a cooldown of 0.42 + 0.25 * impact, so 0.48 to 0.67 s. Against a 2.0 s
    /// window that left roughly half a second per hop to register the landing, wait out
    /// the cooldown and tap again — three times consecutively. At 3.0 the same margin is
    /// about 1.5 s, which is a reaction window rather than a rhythm test.
    ///
    /// Widening this does not make the float cheap: `floatCost` is the real gate, and it
    /// competes with the pursuit for the same nitro bar. This only stops the entry being
    /// a dexterity check on top of that.
    static let chainWindow: Float = 3.0
    static let floatDuration: Float = 10
    static let floatHeight: Float = 12
    /// Spent to enter a float, so the chase and the float compete for one bar.
    ///
    /// 30, down from 50. Widening the chain window made the chain complete, and logging
    /// every attempt across a run then showed both completions refused for nitro — 28
    /// and 0 against a cost of 50. Half the bar is more than a move costs to be worth
    /// using: it regenerates at 3.5/s, so 50 meant fourteen seconds of not touching
    /// boost, in a game whose whole verb is going fast.
    ///
    /// At 30 it is nine seconds of restraint, or one piragua (+35) with change. Still a
    /// real spend against the pursuit, which draws on the same bar, but affordable to
    /// someone who has decided to fly.
    static let floatCost: Float = 30
    /// Minimum forward speed for a jump to be allowed at all.
    static let minSpeed: Float = 6

    var y: Float = 0
    var vel: Float = 0
    /// Charged on landing, not on take-off. See the type comment.
    var cool: Float = 0
    var chain: Int = 0
    var chainT: Float = 0
    var floatT: Float = 0

    /// Visibly off the ground. A gameplay predicate with a dead zone — collision
    /// code uses it to decide whether you cleared a pothole — and deliberately
    /// *not* the same thing as `grounded`.
    var airborne: Bool { y > 0.02 }
    /// Actually touching the road. Only true after a landing has been processed.
    ///
    /// The distinction matters: a descending craft passes through the 0.02 dead
    /// zone where `airborne` is already false but it has not landed. Granting a
    /// jump there cancels the descent one frame before touchdown, so the landing
    /// never fires, `cool` is never charged, and a held button re-launches every
    /// airtime — 98% of a run in the air. That is the real mechanism behind the
    /// held-jump exploit; charging the cooldown on landing did nothing, because
    /// the landing was never reached.
    var grounded: Bool { y <= 0 }
    var floating: Bool { floatT > 0 }

    /// 1 on the ground, less in the air — how much steering authority the craft
    /// has. Floating keeps most of it, because ten seconds of no control would be
    /// a punishment rather than a reward.
    var controlFactor: Float { floating ? 0.7 : (airborne ? 0.34 : 1) }

    mutating func reset() { self = JumpState() }

    /// - Parameter nitro: available nitro, decremented by `floatCost` on a float.
    mutating func requestJump(speed: Float, nitro: inout Float) -> JumpOutcome {
        guard grounded, cool <= 0, speed > Self.minSpeed, !floating else { return .refused }
        chain += 1
        chainT = Self.chainWindow
        if chain >= 3 {
            guard nitro >= Self.floatCost else {
                // Reset so a denied float does not leave the chain armed, which
                // would make the *next* single hop float unexpectedly.
                chain = 0
                vel = Self.impulse
                return .floatDenied
            }
            chain = 0
            chainT = 0
            nitro -= Self.floatCost
            floatT = Self.floatDuration
            vel = 0
            return .float
        }
        vel = Self.impulse
        return .hop(chain: chain)
    }

    /// Timers only. Split from motion because the caller must decay the cooldown
    /// *before* reading a jump request and integrate height *after* acting on it —
    /// a single combined step would shift jump responsiveness by one frame in one
    /// direction or the other.
    mutating func advanceTimers(dt: Float) {
        if cool > 0 { cool = max(0, cool - dt) }
        if chainT > 0 {
            chainT -= dt
            if chainT <= 0 { chain = 0 }
        }
    }

    /// Integrates height. Returns a `Landing` only on the frame of touchdown.
    mutating func advanceMotion(dt: Float) -> Landing? {
        if floating {
            floatT -= dt
            y += (Self.floatHeight - y) * min(1, 2.4 * dt)
            vel = 0
            if floatT <= 0 {
                floatT = 0
                vel = -1                    // nudge into the fall
            }
            return nil
        }

        // `y > 0`, not `airborne`. `airborne` carries a 0.02 dead zone because it is
        // a gameplay predicate — is the craft visibly off the ground — and using it
        // to decide whether to integrate deadlocks the craft.
        //
        // A hop is symmetric, so it returns to almost exactly y = 0. With a fixed
        // 1/60 step it lands on y = 3.6e-07: inside the dead zone, so `airborne` is
        // false, while `vel` is -10.2 so `vel > 0` is false too. Neither flying nor
        // landed, and nothing moves it again. The craft then re-launches every
        // frame because the landing that charges `cool` never happens — which is
        // the real cause of the "airborne 95% of a run" bug that moving the
        // cooldown to touchdown did not actually fix.
        //
        // Live play hides it: real dt varies, so y usually overshoots past zero.
        guard y > 0 || vel > 0 else { return nil }
        vel -= Self.gravity * dt
        y += vel * dt
        guard y <= 0 else { return nil }

        let impact = simd_clamp(-vel / Self.gravity, 0.25, 1)
        y = 0
        vel = 0
        // Recovery is charged here: a take-off cooldown shorter than the airtime
        // can never bind, which is what let a held button stay airborne forever.
        cool = 0.42 + 0.25 * impact
        return Landing(impact: impact)
    }
}
