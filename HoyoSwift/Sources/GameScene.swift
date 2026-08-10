import SceneKit
import SwiftUI
import Metal
import simd

// MARK: - deterministic rng

/// Park–Miller LCG. Two instances are used: one seeded once for the *world*
/// (road path, terrain, vegetation, props — built a single time), and one
/// reseeded per run for the *hazard layout*, so no two races are the same.
struct Lcg {
    var seed: UInt64
    init(_ s: UInt64) {
        let m = s % 2147483647
        seed = m == 0 ? 1 : m
    }
    mutating func next() -> Float {
        seed = (seed &* 16807) % 2147483647
        return Float(seed - 1) / Float(2147483646)
    }
}

// MARK: - render quality tiers

/// SceneKit's HDR pipeline plus 4× MSAA plus a 2048 shadow map is a lot to ask
/// of an A12. Pick the budget from the GPU family instead of hoping.
enum Quality {
    case low, medium, high

    static func detect() -> Quality {
        guard let device = MTLCreateSystemDefaultDevice() else { return .low }
        if device.supportsFamily(.apple8) { return .high }        // A15 and up
        if device.supportsFamily(.apple6) { return .medium }      // A13 / A14
        return .low
    }

    var antialiasing: SCNAntialiasingMode {
        switch self {
        case .high: return .multisampling4X
        case .medium: return .multisampling2X
        case .low: return .none
        }
    }

    var shadowMapSize: CGFloat {
        switch self {
        case .high: return 2048
        case .medium: return 1536
        case .low: return 1024
        }
    }

    var motionBlur: CGFloat {
        switch self {
        case .high: return 0.35
        case .medium: return 0.25
        case .low: return 0
        }
    }

    /// Skid-trail segments per wheel.
    var skidSegments: Int {
        switch self {
        case .high: return 52
        case .medium: return 36
        case .low: return 22
        }
    }

    var streakScale: CGFloat {
        switch self {
        case .high: return 1.0
        case .medium: return 0.7
        case .low: return 0.4
        }
    }
}

// MARK: - game controller

final class GameScene: NSObject, SCNSceneRendererDelegate {

    // course
    static let step: Float = 2
    static let count = 1801
    static let total: Float = Float(count - 1) * 2.0
    /// The stage currently loaded. Static because the course constants below are
    /// read as statics from dozens of call sites; threading an instance through all
    /// of them would be churn for no benefit, and exactly one GameScene is alive.
    static var currentStage: Stage = .cordillera

    /// Stage 1 is four lanes of ~3.4 m; the Yunque trail is a single narrow path.
    static var roadHalf: Float {
        switch currentStage {
        case .yunque: return 4.6        // a footpath
        case .playa:  return 7.6        // open sand, wider than the road
        case .cordillera: return 6.8
        }
    }
    static var laneCount: Int { currentStage == .cordillera ? 4 : 1 }
    /// Verge between the surface edge and the boundary — slow and scrapey, but
    /// recoverable.
    static var shoulderWidth: Float {
        switch currentStage {
        case .yunque: return 1.3
        case .playa:  return 2.6        // loose dry sand before the dune
        case .cordillera: return 1.7
        }
    }
    /// Hard boundary. The guardrail posts are drawn exactly here so the limit you
    /// hit is the limit you can see.
    static var barrier: Float { roadHalf + shoulderWidth }
    /// Centre of each lane. The trail has no lanes, so traffic (which is disabled
    /// there anyway) would just sit on the centreline.
    static var laneCentres: [Float] {
        guard laneCount > 1 else { return [0] }
        let w = roadHalf / Float(laneCount)          // half a lane
        return [-3 * w, -w, w, 3 * w]
    }
    /// Flat sea bed the terrain bottoms out on, and the water level just above it.
    static let seaFloor: Float = -6.5
    static let seaLevel: Float = -6.0

    let scene = SCNScene()
    private let state: GameState
    private let sound: SoundEngine
    private let quality: Quality

    private var worldRng = Lcg(20260727)
    private var runRng = Lcg(1)
    private var runSeed: UInt64 = 0

    private var pts: [simd_float3] = []
    private var tans: [simd_float3] = []
    private var rights: [simd_float3] = []
    private var grades: [Float] = []
    private var curvs: [Float] = []

    // dynamic nodes
    private let cameraNode = SCNNode()
    private let playerNode = SCNNode()
    private let chassisNode = SCNNode()
    private let blobNode = SCNNode()
    private let ghostNode = SCNNode()
    private var frontWheelNodes: [SCNNode] = []
    private var spinWheelNodes: [SCNNode] = []
    private var ufoLightRing = SCNNode()
    private let policeRedMat: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(red: 1, green: 0.12, blue: 0.18, alpha: 1)
        m.emission.contents = UIColor(red: 1, green: 0.12, blue: 0.18, alpha: 1)
        return m
    }()
    private let policeBlueMat: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(red: 0.20, green: 0.42, blue: 1, alpha: 1)
        m.emission.contents = UIColor(red: 0.20, green: 0.42, blue: 1, alpha: 1)
        return m
    }()
    private var flameNodes: [SCNNode] = []
    private var brakeLightMaterial = SCNMaterial()
    private var glowMaterial = SCNMaterial()

    /// Hover-field opacity, and the amount the render loop pulses it either side.
    ///
    /// Both numbers live here because the field is set in two places and only one of
    /// them wins. Setting `glowMaterial.transparency` where the craft is built looks
    /// like it controls the field, but the render loop reassigns it every frame — so
    /// a build-time value is overwritten before the first frame is drawn. That is
    /// not hypothetical: dimming the field at build time to stop it blowing out
    /// under bloom was dead on arrival, and the bloom radius had already been given
    /// back on the strength of it.
    ///
    /// The field is additive, always on, and 4.2 m across, and the three nitro cones
    /// are additive too and land on the same pixels. That pair is what tips the road
    /// under the craft past the bloom threshold. Paying for it here rather than with
    /// a smaller global bloom radius is what keeps the distant lamps, beacons and
    /// police flashers glowing — they exist as bloom and nothing else.
    private static let hoverFieldOpacity: CGFloat = 0.30
    private static let hoverFieldPulse: Float = 0.10
    private var smokeSystem = SCNParticleSystem()
    private var dustSystem = SCNParticleSystem()
    private let dustNode = SCNNode()
    private var sparkSystem = SCNParticleSystem()
    private let sparkNode = SCNNode()
    private var oceanNormal: SCNMaterialProperty?
    private let holeNode = SCNNode()
    private let rimNode = SCNNode()

    // skid trail — a pool of unit quads, transform-only (no per-frame geometry churn)
    private var skidNodes: [SCNNode] = []
    private var skidAge: [Float] = []
    private var skidCursor = 0
    private var lastSkidL: simd_float3?
    private var lastSkidR: simd_float3?
    private var skidTimer: Float = 0
    private static let skidInterval: Float = 0.06
    /// Derived from the pool size: if marks outlived the ring buffer, the cursor
    /// would recycle a slot that was still supposed to be on screen and the tail
    /// of the trail would teleport to the front.
    private var skidLife: Float { Float(quality.skidSegments) * Self.skidInterval * 0.95 }

    // entities
    private struct Hole { var s, x, r: Float; var passed = false; var hit = false
                          /// sealed by the beam — no longer does damage
                          var zapped = false }
    private var holes: [Hole] = []
    private struct Pickup { var s: Float = 0, x: Float = 0, baseY: Float = 0
                            var node: SCNNode; var taken = false }
    private var piraguas: [Pickup] = []
    private var toolboxes: [Pickup] = []
    private struct Iguana {
        var s: Float = 0, x: Float = 0; var dir: Float = 1; var node: SCNNode
        var stateRaw = 0   // 0 wait, 1 run, 2 done
        var hit = false
    }
    private var iguanas: [Iguana] = []
    private struct Traffic {
        var s: Float = 0, x: Float = 0, v: Float = 0; var node: SCNNode
        var cool: Float = 0; var missed = false
        /// Lateral velocity while being shoved aside, and the yaw it picks up.
        var vx: Float = 0, spin: Float = 0
        var clearedByJump = false
        var isPolice = false
    }
    private var traffic: [Traffic] = []

    // MARK: - la policía
    /// Cruisers that hunt you, as opposed to `traffic`, which merely exists. They
    /// are their own pool because traffic is cordillera-only and the chase is the
    /// story on every course.
    private struct Pursuer {
        var s: Float = 0, x: Float = 0, v: Float = 0
        var node: SCNNode
        var live = false
        var life: Float = 0      // seconds before it loses interest
        var ramCool: Float = 0
        var spin: Float = 0
    }
    private var pursuers: [Pursuer] = []
    /// 0…100. Rises while you hold a combo, so the better the run goes the more
    /// attention it draws. Full spawns a cruiser and spends most of itself.
    private var heat: Float = 0
    /// Minimum seconds between spawns. Without it a kill frees a slot while heat is
    /// still pinned at 100, so the replacement arrived on the very next frame.
    private var spawnCool: Float = 0
    private static let spawnGap: Float = 9
    private static let pursuerLife: Float = 20
    /// Flat, and it does not touch the combo. Paying `300 * combo` for a kill that
    /// also called `bumpCombo()` made the chase self-sustaining: a bigger combo
    /// raised heat gain, which spawned the next cruiser sooner, which paid more.
    private static let pursuerBounty = 260

    // MARK: - Yunque quarry

    private enum CritterKind: Int, CaseIterable {
        case coqui, lagartijo, hiker, sanpedrito, boa, gaviota, juey

        var points: Int {
            switch self {
            case .coqui: return 40
            case .lagartijo: return 60
            case .hiker: return 90
            case .sanpedrito: return 130
            case .boa: return 160
            case .gaviota: return 90
            case .juey: return 110
            }
        }
        var label: String {
            switch self {
            case .coqui: return "¡COQUÍ!"
            case .lagartijo: return "¡LAGARTIJO!"
            case .hiker: return "¡PERDÓN!"
            case .sanpedrito: return "¡SAN PEDRITO!"
            case .boa: return "¡LA BOA!"
            case .gaviota: return "¡GAVIOTA!"
            case .juey: return "¡JUEY!"
            }
        }
        /// What running into one costs. The small ones just scatter.
        var contactDamage: Float {
            switch self {
            case .hiker: return 8
            case .boa: return 12
            case .juey: return 6
            default: return 0
            }
        }
        /// Arcade scale, not life scale. At 150 km/h a life-sized coquí is a
        /// couple of pixels — you can't aim at what you can't see.
        var displayScale: Float {
            switch self {
            case .coqui: return 3.0
            case .lagartijo: return 2.4
            case .hiker: return 1.45
            case .sanpedrito: return 2.8
            case .boa: return 1.9
            case .gaviota: return 2.2
            case .juey: return 2.6
            }
        }

        /// How many of each are scattered along the trail.
        var count: Int {
            switch self {
            case .coqui: return 22
            case .lagartijo: return 14
            case .hiker: return 14
            case .sanpedrito: return 12
            case .boa: return 8
            case .gaviota: return 18
            case .juey: return 16
            }
        }
    }

    /// Each course has its own quarry.
    private static func quarry(for stage: Stage) -> [CritterKind] {
        switch stage {
        case .cordillera: return []
        case .yunque:     return [.coqui, .lagartijo, .hiker, .sanpedrito, .boa]
        case .playa:      return [.gaviota, .juey, .hiker, .lagartijo]
        }
    }

    private struct Critter {
        var kind: CritterKind
        var s: Float = 0, x: Float = 0
        var node: SCNNode
        var alive = true
        var hitPlayer = false
        var dir: Float = 1
        var phase: Float = 0
        var baseY: Float = 0
    }
    private var critters: [Critter] = []

    // sim state
    private var phase: GamePhase = .intro
    private var s: Float = 4, v: Float = 8, x: Float = 0, xd: Float = 0
    private var hp: Float = 100, nitro: Float = 60
    private var score: Float = 0, styleRun: Float = 0
    private var topSpeed: Float = 0
    private var holesHit = 0, nearMisses = 0, combo = 0
    /// Counts down; the combo drops a step when it hits zero. Without this the
    /// multiplier was sticky at x5 forever, so playing safe and scoring well were
    /// the same thing — there was no greed in the game.
    private var comboTimer: Float = 0
    // endless
    private var mode: GameMode = .race
    private var lap = 1
    /// White wash that covers the lap teleport. The course is a descent, so wrapping
    /// from sea level back to the mountain top is a visible jump unless the screen is
    /// opaque at the moment it happens. Starts above 1 so there's a guaranteed run of
    /// fully-white frames before the world moves under the player.
    private var lapFlash: Float = 0
    private var lapWrapPending = false
    /// How long the current drift has been held. Longer drifts pay more, which is
    /// what makes losing one hurt.
    private var driftTime: Float = 0
    private var cd: Float = 0
    private var cdLabel = ""
    private var streakSystem = SCNParticleSystem()
    private var shake: Float = 0, flashT: Float = 0, jolt: Float = 0
    private var invuln: Float = 0
    // jump
    /// The craft's vertical state. Lives in `JumpState` so the chain/float rules
    /// can be tested; the accessors below keep the old names for the many read
    /// sites elsewhere in this file.
    private var jump = JumpState()
    private var jumpY: Float {           // height above the road
        get { jump.y } set { jump.y = newValue }
    }
    private var jumpVel: Float { get { jump.vel } set { jump.vel = newValue } }
    private var jumpCool: Float { get { jump.cool } set { jump.cool = newValue } }
    // ghost — the fastest run played back alongside this one
    /// One sample per `ghostStep` of race time: course distance, lateral offset,
    /// height. Indexed rather than time-stamped, so `ghostPlay[i]` is exactly
    /// `i * ghostStep` seconds into the run and playback can never drift.
    private static let ghostStep: Double = 0.1
    private var ghostRec: [SIMD3<Float>] = []
    private var ghostPlay: [SIMD3<Float>] = []
    private var ghostGap: Float = 0
    // beam
    private var charge: Float = 100
    private var fireCool: Float = 0
    private struct Bolt { var s: Float = 0, x: Float = 0, y: Float = 0.75; var node: SCNNode; var live = false }
    private var bolts: [Bolt] = []
    private var boltCursor = 0
    private var patchNodes: [SCNNode] = []
    private var patchCursor = 0
    private static let boltSpeed: Float = 115
    private static let shotCost: Float = 46
    private var airborne: Bool { jump.airborne }
    private static let gravity = JumpState.gravity

    // Chain three hops and the craft remembers what it is. Window is generous
    // enough to be repeatable but tight enough to be a deliberate rhythm: a hop
    // lasts ~0.88 s, so you have roughly a second on the ground to go again.
    private static let floatDuration = JumpState.floatDuration
    private static let floatHeight = JumpState.floatHeight
    private var jumpChain: Int { get { jump.chain } set { jump.chain = newValue } }
    private var floatT: Float { get { jump.floatT } set { jump.floatT = newValue } }
    private var floating: Bool { jump.floating }
    private var dustT: Float = 0
    private var sparkT: Float = 0
    private var rumbleHapticT: Float = 0
    private var coquiT: Float = 2
    private var driftYaw: Float = 0, leanRoll: Float = 0, pitchAng: Float = 0
    private var playTime: Double = 0
    private var lastTime: TimeInterval = -1
    private var camPos = simd_float3(0, 3, 8)
    private var camLook = simd_float3(0, 0, 0)
    private var fov: CGFloat = 62
    private var wheelSpin: Float = 0
    private var hudClock: Float = 0
    private var lastCombo = -1
    private var lastRegion: Region?

    /// Haze colour per region — cool violet high up, dusty warm through town,
    /// bright sea-peach on the coast.
    private var arrivalT: Float = 0
    private var introT: Float = 0
    private var cutsceneT: Float = 0
    private var resultsT: Float = 0
    private var resultsArmed = false
    private var introSet = SCNNode()
    private let introUfo = SCNNode()
    private var introUfoRing = SCNNode()
    private var searchlights: [SCNNode] = []
    private var introSea: SCNNode?
    private var introFoam: SCNNode?
    private var cityBeacons: [SCNNode] = []
    private var lighthouse: SCNNode?
    private var introMoon: SCNLight?

    private static let regionFog: [simd_float3] = [
        simd_float3(0.86, 0.58, 0.62),
        simd_float3(1.00, 0.66, 0.44),
        simd_float3(1.00, 0.78, 0.58)
    ]

    /// Camera framing. The old values sat 6.4–10 m back with a 72° lens, which
    /// shrank the car to a few percent of the screen.
    private static let baseFov: CGFloat = 62

    /// `-autoplay` launch argument: self-driving smoke-test mode.
    static let autoplay = ProcessInfo.processInfo.arguments.contains("-autoplay")

    /// `-showpause`: pauses itself shortly after the run starts, so the pause
    /// screen can be inspected without a touch.
    static let showPause = ProcessInfo.processInfo.arguments.contains("-showpause")

    /// `-inspect <prop>`: parks the camera on the first live instance of a prop and
    /// holds it there, so a small one can actually be looked at. Understands
    /// `piragua`, `toolbox`, `traffic` and `iguana`. Use it with `-autoplay`.
    ///
    /// This exists because verifying the pickups by screenshot did not work, and the
    /// reason it did not work is structural rather than bad luck: the self-driving
    /// controller holds the centre of the road, the pickups sit off-lane, and at
    /// roughly half a metre across they are a handful of pixels on the rare frame
    /// they appear at all. Sampling a recorded run at 4 fps — 221 frames — produced
    /// no usable close-up of either pickup. Anything smaller than a casita needs the
    /// camera taken to it.
    static let inspectTarget: String? = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-inspect"), i + 1 < args.count { return args[i + 1] }
        return nil
    }()

    /// `-startAt <metres>`: drop in partway down the course. Handy for looking at
    /// the pueblo or the costa without surviving the whole descent first.
    static let startOffset: Float = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-startAt"), i + 1 < args.count,
           let v = Float(args[i + 1]) {
            return simd_clamp(v, 40, total - 200)
        }
        return 40
    }()

    init(state: GameState, sound: SoundEngine, quality: Quality) {
        self.state = state
        self.sound = sound
        self.quality = quality
        super.init()
        buildPath()
    }

    // MARK: - path

    private func buildPath() {
        pts.removeAll(keepingCapacity: true); tans.removeAll(keepingCapacity: true)
        rights.removeAll(keepingCapacity: true); grades.removeAll(keepingCapacity: true)
        curvs.removeAll(keepingCapacity: true)
        let trail = Self.currentStage == .yunque
        let shore = Self.currentStage == .playa
        var px: Float = 0, pz: Float = 0, py: Float = 0
        for i in 0..<Self.count {
            let sd = Float(i) * Self.step
            // The trail twists far harder and drops far less than the road — short
            // periods, big amplitude, shallow grade.
            let h = trail
                ? 0.95 * sin(sd / 89) + 0.72 * sin(sd / 37 + 2.1)
                    + 0.5 * sin(sd / 151 + 0.6) + 0.34 * sin(sd / 23 + 3.4)
                : shore
                ? 0.42 * sin(sd / 420) + 0.30 * sin(sd / 190 + 1.2)
                    + 0.16 * sin(sd / 95 + 2.8)
                : 0.55 * sin(sd / 173) + 0.45 * sin(sd / 59 + 1.7)
                    + 0.5 * sin(sd / 311 + 4.0) + 0.3 * sin(sd / 47 + 2.5)
            let endFade = simd_clamp((Self.total - 100 - sd) / 260, 0, 1)
            let grade = trail
                ? (0.028 + 0.020 * sin(sd / 150) + 0.014 * sin(sd / 61)) * endFade
                : shore
                ? (0.004 + 0.003 * sin(sd / 260)) * endFade
                : (0.055 + 0.04 * sin(sd / 210 + 0.5) + 0.024 * sin(sd / 83)) * endFade
            pts.append(simd_float3(px, py, pz))
            grades.append(-grade)
            px += sin(h) * Self.step
            pz -= cos(h) * Self.step
            py -= grade * Self.step
        }
        let lift = 5.5 - pts[Self.count - 1].y
        for i in 0..<Self.count { pts[i].y += lift }

        var headings: [Float] = []
        for i in 0..<Self.count {
            let a = pts[max(0, i - 1)], b = pts[min(Self.count - 1, i + 1)]
            let t = simd_normalize(b - a)
            tans.append(t)
            rights.append(simd_normalize(simd_float3(-t.z, 0, t.x)))
            headings.append(atan2(t.x, -t.z))
        }
        for i in 0..<Self.count {
            let h0 = headings[max(0, i - 1)], h1 = headings[min(Self.count - 1, i + 1)]
            var dh = h1 - h0
            if dh > .pi { dh -= 2 * .pi }
            if dh < -.pi { dh += 2 * .pi }
            curvs.append(dh / (2 * Self.step))
        }
    }

    // MARK: - regions

    private static func smoothStep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = simd_clamp((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Blend weights for (cordillera, pueblo, costa) at a course fraction. The
    /// crossfade is deliberately wide — hard region seams look like a mistake.
    private static func regionWeights(_ p: Float) -> simd_float3 {
        let fade: Float = 0.055                       // ~200 m either side
        let pueblo = Region.pueblo.span.lo, costa = Region.costa.span.lo
        let a = 1 - smoothStep(pueblo - fade, pueblo + fade, p)
        let c = smoothStep(costa - fade, costa + fade, p)
        return simd_float3(a, max(0, 1 - a - c), c)
    }

    /// A world-build index drawn from inside one region's span.
    private func indexIn(_ region: Region, _ rng: inout Lcg, inset: Float = 0.01) -> Int {
        let s = region.span
        let f = (s.lo + inset) + rng.next() * max(0.01, (s.hi - inset) - (s.lo + inset))
        return min(Self.count - 4, max(4, Int(f * Float(Self.count))))
    }

    /// Picks a region from three weights.
    private func pickRegion(_ rng: inout Lcg, _ w: simd_float3) -> Region {
        let r = rng.next() * (w.x + w.y + w.z)
        if r < w.x { return .cordillera }
        if r < w.x + w.y { return .pueblo }
        return .costa
    }

    private func sample(_ dist: Float) -> (pos: simd_float3, tan: simd_float3, rgt: simd_float3) {
        var f = simd_clamp(dist / Self.step, 0, Float(Self.count) - 1.001)
        let i = Int(f); f -= Float(i)
        return (simd_mix(pts[i], pts[i + 1], simd_float3(repeating: f)),
                simd_normalize(simd_mix(tans[i], tans[i + 1], simd_float3(repeating: f))),
                simd_normalize(simd_mix(rights[i], rights[i + 1], simd_float3(repeating: f))))
    }

    private func groundY(_ i: Int, _ lat: Float) -> Float {
        let idx = min(max(i, 0), Self.count - 1)
        let p = pts[idx], sd = Float(idx) * Self.step
        let d = abs(lat) - Self.roadHalf
        if d <= 0 { return p.y }
        var yy: Float
        if Self.currentStage == .playa {
            // low dune inland, then the sand shelves gently into the water
            if lat < 0 {
                let k = 0.10 + 0.06 * sin(sd / 90 + 1)
                yy = p.y + min(d * k, 7) + sin(d * 0.13 + sd * 0.02) * min(d * 0.10, 1.6)
            } else {
                yy = p.y - d * 0.075 - max(0, d - 16) * 0.10
            }
            return max(yy, Self.seaFloor)
        }
        if lat < 0 {
            let k = 0.42 + 0.18 * sin(sd / 140 + 1) + 0.10 * sin(sd / 47)
            yy = p.y + d * k + sin(d * 0.22 + sd * 0.013) * min(d * 0.15, 4)
        } else {
            // Gentler seaward slope (was 0.34) so the ground reaches the water
            // line much further out — the sea used to lap almost at the road edge
            // wherever the road ran low.
            let k2 = 0.20 + 0.07 * sin(sd / 120 + 2)
            yy = p.y - d * k2 + sin(d * 0.19 + sd * 0.017) * min(d * 0.12, 3)
        }
        return max(yy, Self.seaFloor)
    }

    // MARK: - geometry helpers

    private func makeGeometry(verts: [simd_float3], indices: [Int32],
                              uvs: [CGPoint]? = nil, colors: [simd_float3]? = nil,
                              material: SCNMaterial) -> SCNGeometry {
        var normals = [simd_float3](repeating: .zero, count: verts.count)
        var k = 0
        while k < indices.count {
            let a = Int(indices[k]), b = Int(indices[k + 1]), c = Int(indices[k + 2])
            let n = simd_cross(verts[b] - verts[a], verts[c] - verts[a])
            normals[a] += n; normals[b] += n; normals[c] += n
            k += 3
        }
        for i in 0..<normals.count {
            let len = simd_length(normals[i])
            normals[i] = len > 0.0001 ? normals[i] / len : simd_float3(0, 1, 0)
        }
        var sources = [
            SCNGeometrySource(vertices: verts.map { SCNVector3($0) }),
            SCNGeometrySource(normals: normals.map { SCNVector3($0) })
        ]
        if let uvs = uvs { sources.append(SCNGeometrySource(textureCoordinates: uvs)) }
        if let colors = colors {
            var floats: [Float] = []
            floats.reserveCapacity(colors.count * 3)
            for c in colors { floats.append(c.x); floats.append(c.y); floats.append(c.z) }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color,
                vectorCount: colors.count, usesFloatComponents: true,
                componentsPerVector: 3, bytesPerComponent: 4,
                dataOffset: 0, dataStride: 12))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: sources, elements: [element])
        geo.materials = [material]
        return geo
    }

    /// Scenery surface. Physically based rather than lambert so everything in the
    /// frame answers to the same light — the road, the terrain and the craft are all
    /// PBR now, and lambert geometry beside them ignores specular entirely, which is
    /// what made the casitas and palms read as pasted on rather than lit.
    ///
    /// Kept matte by default. This is a stylised game and the flat-colour scenery is
    /// part of its look; the point is not to make it glossy but to have it sit in the
    /// same lighting as its surroundings.
    private func lambert(_ color: UIColor, roughness: CGFloat = 0.86) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 0.0
        m.roughness.contents = roughness
        return m
    }

    private func constant(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }

    // MARK: - world build (runs off the main thread)

    /// Everything expensive — the sky cubemap's 400k `powf` calls, the road and
    /// terrain meshes, 120 palms — happens here, on a background queue, into a
    /// *detached* node. `attach` then hooks it up in one main-thread step.
    /// Building straight into a live scene from another thread would race the
    /// renderer; building detached does not.
    func buildWorld() -> (world: SCNNode, sky: [UIImage]) {
        let world = SCNNode()
        // The intro set is a night coastline, so it sits under a night sky; the
        // stage's own sky swaps in when the race starts. Cordillera races under the
        // sunset, which is why it is built here rather than only in the switch.
        // The night sky belongs to the intro set, which is the same on every course,
        // so it is built once for the process rather than per stage load. The sunset
        // is only needed by cordillera — building it for the other two was six faces
        // of the powf loop thrown away.
        introSky = Self.nightSky
        let sky: [UIImage]
        switch Self.currentStage {
        case .yunque:
            sky = Textures.skyCubemap(.rainforest); raceSky = sky
        case .playa:
            sky = Textures.skyCubemap(.tropical);   raceSky = sky
        case .cordillera:
            sky = Textures.skyCubemap(.sunset);     raceSky = sky
        }

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        switch Self.currentStage {
        case .yunque:
            ambient.light!.color = UIColor(red: 0.34, green: 0.42, blue: 0.34, alpha: 1)
        case .playa:
            // sky bounce off water and pale sand: cool and bright
            ambient.light!.color = UIColor(red: 0.50, green: 0.58, blue: 0.66, alpha: 1)
        case .cordillera:
            ambient.light!.color = UIColor(red: 0.50, green: 0.42, blue: 0.50, alpha: 1)
        }
        world.addChildNode(ambient)

        let sunNode = SCNNode()
        sunNode.light = SCNLight()
        sunNode.light!.type = .directional
        // dappled, weaker light under the canopy
        switch Self.currentStage {
        case .yunque:
            sunNode.light!.color = UIColor(red: 0.82, green: 0.92, blue: 0.76, alpha: 1)
            sunNode.light!.intensity = 760
        case .playa:
            sunNode.light!.color = UIColor(red: 1.0, green: 0.98, blue: 0.93, alpha: 1)
            sunNode.light!.intensity = 1450
        case .cordillera:
            sunNode.light!.color = UIColor(red: 1.0, green: 0.82, blue: 0.63, alpha: 1)
            sunNode.light!.intensity = 1280
        }
        sunNode.light!.castsShadow = true
        sunNode.light!.shadowMapSize = CGSize(width: quality.shadowMapSize,
                                              height: quality.shadowMapSize)
        sunNode.light!.shadowSampleCount = quality == .low ? 1 : 4
        sunNode.light!.shadowRadius = 3
        sunNode.light!.shadowColor = UIColor(white: 0, alpha: 0.5)
        sunNode.light!.maximumShadowDistance = 150
        sunNode.eulerAngles = SCNVector3(-0.55, 0.45, 0)
        world.addChildNode(sunNode)

        // Rim light from low and behind. A single overhead key left everything
        // reading flat against a bright sky; this puts an edge on the craft, the
        // canopy and the guardrail so they separate from the background.
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        switch Self.currentStage {
        case .yunque:
            rim.light!.color = UIColor(red: 0.62, green: 0.82, blue: 0.70, alpha: 1)
            rim.light!.intensity = 420
        case .playa:
            rim.light!.color = UIColor(red: 0.72, green: 0.86, blue: 1.0, alpha: 1)
            rim.light!.intensity = 480
        case .cordillera:
            rim.light!.color = UIColor(red: 1.0, green: 0.55, blue: 0.42, alpha: 1)
            rim.light!.intensity = 620
        }
        rim.light!.castsShadow = false
        rim.eulerAngles = SCNVector3(-0.12, .pi - 0.35, 0)
        world.addChildNode(rim)

        // gentle bounce from below, so undersides aren't dead black
        let bounce = SCNNode()
        bounce.light = SCNLight()
        bounce.light!.type = .directional
        bounce.light!.color = Self.currentStage == .playa
            ? UIColor(red: 0.34, green: 0.40, blue: 0.46, alpha: 1)   // light off wet sand
            : UIColor(red: 0.30, green: 0.26, blue: 0.34, alpha: 1)
        bounce.light!.intensity = 220
        bounce.light!.castsShadow = false
        bounce.eulerAngles = SCNVector3(1.15, 0.2, 0)
        world.addChildNode(bounce)

        buildCameraObject()
        clouds(world)
        ocean(world)
        road(world)
        terrain(world)
        vegetation(world)
        props(world)
        makePiraguas(world)
        makeToolboxes(world)
        makeIguanas(world)
        makeTraffic(world)
        makePursuers(world)
        makeCritters(world)
        buildCar()
        skidPool(world)
        beamPools(world)
        particles()
        buildIntroSet(world)

        world.addChildNode(holeNode)
        world.addChildNode(rimNode)
        world.addChildNode(playerNode)
        playerNode.addChildNode(chassisNode)
        world.addChildNode(dustNode)
        world.addChildNode(sparkNode)
        world.addChildNode(blobNode)
        buildGhost(world)

        return (world, sky)
    }

    /// Gates the render loop until the world is fully installed. Without it the
    /// intro camera code would be posing `cameraNode` on the render thread while
    /// the background build was still parenting and configuring that same node.
    private var worldAttached = false
    /// Kept so a stage change can tear the previous world back out.
    private var worldRoot: SCNNode?
    /// Built on the background queue, installed on main. See `camera(_:)`.
    private var pendingCamera: SCNCamera?
    /// Set when the loaded stage wants a different sky from the intro's.
    private var raceSky: [UIImage]?
    private var introSky: [UIImage]?
    /// Stage-independent, and the most expensive texture in the project, so it is
    /// generated once per process instead of once per stage load.
    private static let nightSky: [UIImage] = Textures.skyCubemap(.night)

    /// Everything a stage build appends to. Cleared before rebuilding, otherwise a
    /// second stage would stack its geometry and entities on top of the first.
    private func clearForRebuild() {
        holes.removeAll()
        piraguas.removeAll(); toolboxes.removeAll()
        iguanas.removeAll(); traffic.removeAll(); critters.removeAll()
        pursuers.removeAll()
        bolts.removeAll(); patchNodes.removeAll()
        skidNodes.removeAll(); skidAge.removeAll()
        searchlights.removeAll()
        cityBeacons.removeAll()
        introSea = nil; introFoam = nil; lighthouse = nil; introMoon = nil
        flameNodes.removeAll(); frontWheelNodes.removeAll(); spinWheelNodes.removeAll()
        // these nodes persist across stages, so their children must be shed
        for n in [chassisNode, playerNode, dustNode, sparkNode, introUfo, ghostNode] {
            n.childNodes.forEach { $0.removeFromParentNode() }
        }
        blobNode.geometry = nil
    }

    /// Tears down whatever is loaded and builds the requested stage off the main
    /// thread, exactly as the first load does.
    func loadStage(_ stage: Stage, onReady: @escaping () -> Void) {
        let t0 = CFAbsoluteTimeGetCurrent()
        worldAttached = false
        phase = .intro
        introT = 0
        Self.currentStage = stage
        worldRoot?.removeFromParentNode()
        worldRoot = nil
        clearForRebuild()
        worldRng = Lcg(20260727)
        buildPath()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let built = self.buildWorld()
            let tBuilt = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                self.attach(world: built.world, sky: built.sky)
                self.worldRoot = built.world
                let tDone = CFAbsoluteTimeGetCurrent()
                // read with: devicectl device process launch --console
                print(String(format: "HOYO-PERF stage=%@ build=%.2fs attach=%.2fs total=%.2fs",
                             String(describing: stage), tBuilt - t0, tDone - tBuilt, tDone - t0))
                onReady()
            }
        }
    }

    /// Main thread: install the finished world.
    /// The stage's own air. Its own function because `nightAtmosphere()` runs every
    /// frame of the title and cutscene and overwrites all four properties; without
    /// somewhere to restore them from, every race after the first title screen ran
    /// with the night's 900/4600 distances — which erased the Yunque canopy mist
    /// and Isla Verde's sea haze entirely.
    func applyStageFog() {
        switch Self.currentStage {
        case .playa:
            // clear tropical air with sea haze far out
            scene.fogStartDistance = 420
            scene.fogEndDistance = 3200
            scene.fogDensityExponent = 1.4
            scene.fogColor = UIColor(red: 0.80, green: 0.90, blue: 0.94, alpha: 1)
        case .yunque:
            // thick canopy mist: you can't see far in there
            scene.fogStartDistance = 40
            scene.fogEndDistance = 520
            scene.fogDensityExponent = 1.9
            scene.fogColor = UIColor(red: 0.42, green: 0.55, blue: 0.42, alpha: 1)
        case .cordillera:
            scene.fogStartDistance = 280
            scene.fogEndDistance = 2400
            scene.fogDensityExponent = 1.6
            scene.fogColor = UIColor(red: 1.0, green: 0.67, blue: 0.47, alpha: 1)
        }
    }

    func attach(world: SCNNode, sky: [UIImage]) {
        applyStageFog()
        // Starts on the intro set, so it opens under the night sky; `resetGame`
        // swaps in the race sky when a run begins.
        scene.background.contents = introSky ?? sky
        // Same cubemap as the image-based lighting source, so the car's paint and
        // glass actually reflect the sunset instead of a flat specular dot. Only
        // the physicallyBased materials sample it.
        // Matches the background. Lighting the night coastline with the sunset
        // cubemap turned the whole set orange.
        scene.lightingEnvironment.contents = introSky ?? sky
        scene.lightingEnvironment.intensity = 0.85
        // `cameraNode` is a long-lived node that SCNView holds as its pointOfView, so
        // it must only ever be touched on the main thread. The camera *object* is
        // built during the background pass; wiring and parenting happen here.
        if let cam = pendingCamera {
            cameraNode.camera = cam
            pendingCamera = nil
        }
        cameraNode.position = SCNVector3(0, 3, 8)
        world.addChildNode(cameraNode)
        scene.rootNode.addChildNode(world)
        worldAttached = true
    }

    var pointOfView: SCNNode { cameraNode }

    /// The colour grade currently installed. Swapped when the look changes — on
    /// stage load, and when the night set gives way to a race — never per frame,
    /// since building an SCNTechnique allocates a render pipeline.
    private var postLook: PostFX.Look?

    /// Set by `GameSceneView`; the view owns `SCNView.technique`, which is main
    /// thread only, so the swap is dispatched rather than applied here.
    var applyTechnique: ((SCNTechnique) -> Void)?

    private func updatePostFX() {
        let want: PostFX.Look = (phase == .cutscene || phase == .intro)
            ? .night : PostFX.Look.racing(Self.currentStage)
        guard want != postLook else { return }

        guard let tech = PostFX.technique(for: want) else {
            // SceneKit rejected the technique, or the Metal function is missing
            // from the default library. Latch anyway: `PostFX` memoises rejections,
            // so retrying can only ever fail again.
            //
            // The fallback matters more than it used to. While the camera carried
            // its own saturation, contrast and vignette, losing the grade cost the
            // per-stage look and nothing else. Neutralising the camera — correct,
            // since the two were double-applying — made the grade the only thing
            // deciding the look, so the same failure now renders a completely flat
            // frame with no way back. This puts an approximation of the old camera
            // grade on instead, so the worst case degrades to the pre-grade look
            // rather than to no look at all.
            postLook = want
            installFallbackGrade()
            return
        }
        // Not latched on this path: `applyTechnique` is wired by the view before
        // the world attaches, so this should be unreachable, but retrying next
        // frame is free and beats latching a look that never got applied.
        guard let apply = applyTechnique else { return }
        postLook = want
        DispatchQueue.main.async { apply(tech) }
    }

    /// Only for the case where the colour grade could not be built at all. Restores
    /// roughly what `buildCameraObject` used to set before `PostFX` took the look
    /// over; see the call site for why this exists.
    private func installFallbackGrade() {
        guard let cam = cameraNode.camera else { return }
        cam.saturation = 1.14
        cam.contrast = 0.10
        cam.vignettingPower = 0.55
        cam.vignettingIntensity = 0.45
    }

    private func buildCameraObject() {
        let cam = SCNCamera()
        cam.zNear = 0.1
        cam.zFar = 9000
        cam.fieldOfView = Self.baseFov
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        // Bloom was set so low (threshold 0.85) that the headlights smeared into
        // a white blob directly over the car. Raised and dimmed — but the 18-point
        // radius that came with that fix re-created the blob from the other side:
        // the hover field and the nitro thrusters are both additive and both sit
        // under the craft, so they saturate the same pixels and bloom pooled them
        // into a white hole over the road, right where the next pothole has to be
        // read.
        //
        // Cutting the radius to 9 did clear it, and was the wrong instrument. A
        // halo's footprint goes with the square of the radius, so 18 → 9 leaves a
        // quarter of the glow area — and it charges that to every emissive in the
        // scene, including the far-field ones that exist *only* as bloom: the
        // pueblo street lamps, the rooftop beacons in the cutscene, the lighthouse,
        // the police flashers. A near-field problem with two known sources should
        // be paid for by those two sources, so the dimming moved to the hover field
        // itself (see `glowMaterial`) and the radius came most of the way back.
        cam.bloomThreshold = 0.98
        cam.bloomIntensity = 0.52
        cam.bloomBlurRadius = 14
        cam.motionBlurIntensity = quality.motionBlur
        // Saturation, contrast and the vignette all belong to the grade in
        // PostFX.metal. They used to be set here too, and the technique was added on
        // top without clearing them, so every one of the three ran twice: saturation
        // came out at 1.14 * 1.12 = 1.2768 — the two compose as a clean product
        // because mix(luma, col, s) preserves luma — and two vignettes stacked into
        // a hard tunnel. The camera is the neutral HDR source now; the grade is the
        // only place the look is decided, and it is the only one that can vary by
        // stage, which is why the duplication was resolved in this direction.
        //
        // Note this does *not* explain the plum cast on the asphalt, which an
        // earlier version of this comment claimed. That comes from `lift` in
        // PostFX.metal, applied as lift * (1 - col) so it bites hardest on the
        // darkest surface in frame, and cordillera's lift is magenta. Saturation
        // amplified it; it did not cause it, and the lift is untouched here.
        cam.saturation = 1.0
        cam.contrast = 0.0
        cam.vignettingIntensity = 0.0
        // Contact darkening. Without it every object floated — the craft, the trees
        // and the guardrail posts all met the ground with no shading at all.
        if quality != .low {
            cam.screenSpaceAmbientOcclusionIntensity = 0.85
            cam.screenSpaceAmbientOcclusionRadius = 1.3
            cam.screenSpaceAmbientOcclusionBias = 0.02
            cam.screenSpaceAmbientOcclusionDepthThreshold = 0.35
        }
        // Handed to `attach` rather than assigned here: this runs on the background
        // build queue, and `cameraNode` is live as the view's pointOfView from the
        // second stage load onward. Mutating it here raced SceneKit's render pass.
        pendingCamera = cam
    }

    private func clouds(_ parent: SCNNode) {
        guard Self.currentStage == .cordillera else { return }
        let container = SCNNode()
        // lambert rather than constant, so the sun actually shapes them instead
        // of leaving flat beige blobs pasted on the sky
        let mat = lambert(UIColor(red: 1, green: 0.86, blue: 0.80, alpha: 1))
        for _ in 0..<14 {
            let cx = (worldRng.next() - 0.5) * 2400
            let cy = 430 + worldRng.next() * 260
            let cz = -300 - worldRng.next() * 2700
            for _ in 0..<3 {
                let ball = SCNNode(geometry: SCNSphere(radius: 1))
                ball.geometry!.materials = [mat]
                ball.position = SCNVector3(cx + (worldRng.next() - 0.5) * 90,
                                           cy + (worldRng.next() - 0.5) * 14,
                                           cz + (worldRng.next() - 0.5) * 50)
                ball.scale = SCNVector3(45 + worldRng.next() * 70,
                                        10 + worldRng.next() * 9,
                                        26 + worldRng.next() * 34)
                container.addChildNode(ball)
            }
        }
        let flat = container.flattenedClone()
        flat.castsShadow = false
        parent.addChildNode(flat)
    }

    private func ocean(_ parent: SCNNode) {
        guard Self.currentStage != .yunque else { return }
        let beach = Self.currentStage == .playa
        let plane = SCNPlane(width: 9000, height: 9000)
        plane.widthSegmentCount = 110
        plane.heightSegmentCount = 110
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = beach
            ? UIColor(red: 0.10, green: 0.62, blue: 0.66, alpha: 1)   // Caribbean turquoise
            : UIColor(red: 0.07, green: 0.30, blue: 0.48, alpha: 1)
        m.specular.contents = UIColor(red: 1, green: 0.75, blue: 0.52, alpha: 1)
        m.shininess = 0.9
        m.normal.contents = Textures.waterNormal()
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        oceanNormal = m.normal
        m.shaderModifiers = [.geometry: """
            float2 p = _geometry.position.xy;
            float t = scn_frame.time;
            _geometry.position.z += sin(p.x*0.02 + t*0.8)*sin(p.y*0.016 - t*0.6)*1.1
              + sin(p.x*0.045 + t*1.4)*0.45 + sin(p.y*0.05 + t*1.1)*0.4;
            """]
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(0, Self.seaLevel, -1600)
        node.castsShadow = false
        parent.addChildNode(node)
    }

    private func road(_ parent: SCNNode) {
        var verts: [simd_float3] = [], uvs: [CGPoint] = [], idx: [Int32] = []
        for i in 0..<Self.count {
            let p = pts[i], r = rights[i]
            verts.append(p - r * Self.roadHalf)
            verts.append(p + r * Self.roadHalf)
            let vCoord = CGFloat(Float(i) * Self.step / 9)
            // keep the asphalt tile square now that the road is wider than the
            // 9 m the V scale assumes, otherwise the speckle stretches sideways
            let uMax = CGFloat(Self.roadHalf * 2 / 9)
            uvs.append(CGPoint(x: 0, y: vCoord))
            uvs.append(CGPoint(x: uMax, y: vCoord))
            if i < Self.count - 1 {
                let a = Int32(i * 2)
                idx.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            }
        }
        // The road is the largest surface in every frame and was the only major one
        // still on a legacy lighting model — blinn, one flat specular colour, and no
        // surface relief whatsoever, while the craft and the sea were already PBR.
        // Physically based with a derived normal map is what lets the aggregate
        // actually catch the low sun instead of being painted-on grain.
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.metalness.contents = 0.0

        let roughness: CGFloat
        let relief: Float
        switch Self.currentStage {
        case .yunque:
            // dry packed dirt: rough, and the most relief of the three
            roughness = 0.90; relief = 5.0
        case .playa:
            // Wet sand. Glossy at a grazing angle, and that sheen is most of the
            // read — a previous version set it and then had it overwritten two lines
            // later by an unconditional specular, so it never once rendered.
            // 0.26 was too glossy: the specular blew out the middle distance and
            // erased the sand grain entirely under the bright tropical sky. Still
            // clearly the wettest of the three surfaces.
            roughness = 0.44; relief = 1.6
        case .cordillera:
            roughness = 0.72; relief = 4.2
        }

        let surface = Self.roadSurface(Self.currentStage, relief: relief)
        mat.diffuse.contents = surface.diffuse
        mat.roughness.contents = roughness
        if let n = surface.normal {
            mat.normal.contents = n
            mat.normal.wrapS = .repeat
            mat.normal.wrapT = .repeat
            mat.normal.intensity = 0.9
        }
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .repeat
        let node = SCNNode(geometry: makeGeometry(verts: verts, indices: idx, uvs: uvs, material: mat))
        node.castsShadow = false
        parent.addChildNode(node)

        /// `dash` of 0 draws a solid stripe; otherwise it draws for the first half
        /// of every `dash` segments — 8 for the centre line, 2 for rumble strips.
        func ribbon(_ l0: Float, _ l1: Float, _ color: UIColor, dash: Int) {
            var v: [simd_float3] = [], id: [Int32] = []
            var n: Int32 = 0
            for j in 0..<(Self.count - 1) {
                if dash > 0 && (j % dash) >= dash / 2 { continue }
                let p0 = pts[j], r0 = rights[j], p1 = pts[j + 1], r1 = rights[j + 1]
                let up = simd_float3(0, 0.03, 0)
                v.append(p0 + r0 * l0 + up); v.append(p0 + r0 * l1 + up)
                v.append(p1 + r1 * l0 + up); v.append(p1 + r1 * l1 + up)
                id.append(contentsOf: [n, n + 1, n + 2, n + 1, n + 3, n + 2])
                n += 4
            }
            let node = SCNNode(geometry: makeGeometry(verts: v, indices: id, material: constant(color)))
            node.castsShadow = false
            parent.addChildNode(node)
        }
        // A dirt trail has no paint and no rumble strips; its edge is just where the
        // undergrowth starts.
        if Self.currentStage == .cordillera {
            ribbon(-0.14, 0.14, UIColor(red: 0.79, green: 0.68, blue: 0.21, alpha: 1), dash: 8)
            let mid = Self.roadHalf / 2
            ribbon(-mid - 0.11, -mid + 0.11, UIColor(white: 0.8, alpha: 1), dash: 8)
            ribbon(mid - 0.11, mid + 0.11, UIColor(white: 0.8, alpha: 1), dash: 8)
            let edgeOuter = Self.roadHalf - 0.18, edgeInner = Self.roadHalf - 0.4
            ribbon(-edgeOuter, -edgeInner, UIColor(white: 0.83, alpha: 1), dash: 0)
            ribbon(edgeInner, edgeOuter, UIColor(white: 0.83, alpha: 1), dash: 0)
            let rumbleIn = Self.roadHalf, rumbleOut = Self.roadHalf + 0.62
            ribbon(-rumbleOut, -rumbleIn, UIColor(white: 0.70, alpha: 1), dash: 2)
            ribbon(rumbleIn, rumbleOut, UIColor(white: 0.70, alpha: 1), dash: 2)
        }
    }

    /// Grass / rock / sand blend driven by local slope plus three octaves of
    /// cheap sinusoidal noise. The old two-branch version left the hillsides a
    /// flat olive wall.
    private func terrainColor(_ i: Int, _ lat: Float, _ y: Float) -> simd_float3 {
        let sd = Float(i) * Self.step
        if y < 1.6 && Self.currentStage != .yunque {
            let l = 0.66 + 0.05 * sin(Float(i) * 0.7 + lat)
            return simd_float3(0.93 * l + 0.1, 0.82 * l + 0.08, 0.55 * l)
        }
        let n = 0.5
            + 0.26 * sin(sd * 0.031 + lat * 0.11)
            + 0.14 * sin(sd * 0.087 - lat * 0.23)
            + 0.08 * sin(sd * 0.190 + lat * 0.41)

        let dLat: Float = 1.5
        let slope = abs(groundY(i, lat + dLat) - groundY(i, lat - dLat)) / (2 * dLat)

        // Beach: pale sand at the water's edge easing into muted dune vegetation
        // inland — sea oats and sea grape, not lawn.
        if Self.currentStage == .playa {
            let sand = simd_float3(0.87, 0.79, 0.64) * (0.92 + n * 0.16)
            let dune = simd_float3(0.42, 0.55, 0.33) * (0.84 + n * 0.34)
            let inland = simd_clamp((-lat - 4) / 26, 0, 1)
            return simd_mix(sand, dune, simd_float3(repeating: inland * 0.92))
        }

        // El Yunque is one biome the whole way: deep, wet, saturated green with
        // very little bare rock. No region drift.
        if Self.currentStage == .yunque {
            let ui = UIColor(hue: CGFloat(0.335 - n * 0.035),
                             saturation: CGFloat(0.62 + n * 0.16),
                             brightness: CGFloat(0.13 + n * 0.19), alpha: 1)
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            ui.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let jungle = simd_float3(Float(r2), Float(g2), Float(b2))
            let wetRock = simd_float3(0.26, 0.27, 0.23) * (0.85 + n * 0.3)
            let amt = simd_clamp((slope - 0.95) / 1.1, 0, 0.6)
            return simd_mix(jungle, wetRock, simd_float3(repeating: amt))
        }

        // Ground tone per region: deep wet green up in the cordillera, dry and
        // yellowed through the pueblo, pale and sun-bleached down on the costa.
        let w = Self.regionWeights(sd / Self.total)
        let hue = CGFloat(w.x * 0.325 + w.y * 0.215 + w.z * 0.275) - CGFloat(n * 0.05)
        let sat = CGFloat(w.x * 0.56 + w.y * 0.44 + w.z * 0.36) + CGFloat(n * 0.16)
        let bri = CGFloat(w.x * 0.27 + w.y * 0.34 + w.z * 0.40) + CGFloat(n * 0.26)
        let ui = UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        let green = simd_float3(Float(rr), Float(gg), Float(bb))

        let rock = simd_float3(0.40, 0.36, 0.32) * (0.80 + n * 0.42)
        // the cordillera is the rocky one — bare stone shows on gentler slopes there
        let rockThreshold = w.x * 0.42 + w.y * 0.62 + w.z * 0.78
        let rockAmt = simd_clamp((slope - rockThreshold) / 0.9, 0, 0.82)
        return simd_mix(green, rock, simd_float3(repeating: rockAmt))
    }

    /// Built once and shared by both terrain sides.
    private static let groundTexture = Textures.groundDetail()
    /// Derived once per process. The terrain mesh is rebuilt on every stage load, so
    /// deriving this alongside it would repeat a 512² Sobel for no reason.
    private static let groundNormal = Textures.normalMap(from: groundTexture, strength: 3.4)

    /// Road surfaces, built once per stage and kept. The road and terrain meshes are
    /// rebuilt on every stage load, and regenerating an identical texture plus its
    /// Sobel each time is what took stage load from 2.8s to 14.8s.
    private static var roadSurfaceCache: [Stage: (diffuse: UIImage, normal: UIImage?)] = [:]

    private static func roadSurface(_ stage: Stage, relief: Float)
        -> (diffuse: UIImage, normal: UIImage?) {
        if let hit = roadSurfaceCache[stage] { return hit }
        let diffuse: UIImage
        switch stage {
        case .yunque: diffuse = Textures.dirtTrail()
        case .playa:  diffuse = Textures.wetSand()
        case .cordillera: diffuse = Textures.asphalt()
        }
        let made = (diffuse, Textures.normalMap(from: diffuse, strength: relief))
        roadSurfaceCache[stage] = made
        return made
    }
    /// Rebuilt pothole meshes reuse this rather than regenerating it every race.
    private static let holeTexture = Textures.holeDepth()

    private func terrain(_ parent: SCNNode) {
        // denser near the road, where you can actually see the silhouette
        // first band hugs the asphalt edge, second sits exactly on the guardrail
        // line so the posts stand on a real terrain vertex rather than floating
        // step of 1 (every 2 m) rather than 2 (every 4 m) near the road: the long
        // flat triangles were the most obvious low-poly tell, worst on the trail
        let rowStep = 1
        let e = Self.roadHalf - 0.3, b = Self.barrier
        // Both sides now run far enough out to close the horizon. The old strips
        // stopped at 145 m, and past that edge was nothing — so on the seaward
        // side you could see straight over the lip to the ocean plane hundreds of
        // metres below, which read as the sea leaking into the bottom of frame.
        let latsL: [Float] = [-e, -b, -8.5, -11.5, -15.5, -21, -29, -40, -56,
                              -80, -120, -240]
        let latsR: [Float] = [e, b, 8.5, 11.5, 15.5, 21, 29, 40, 56,
                              80, 120, 200, 900]

        func side(_ lats: [Float], flip: Bool) {
            var verts: [simd_float3] = [], cols: [simd_float3] = [], idx: [Int32] = []
            var uvs: [CGPoint] = []
            var rows = 0
            var i = 0
            while i < Self.count {
                let p = pts[i], r = rights[i]
                for (j, lat) in lats.enumerated() {
                    let y = j == 0 ? p.y - 0.09 : groundY(i, lat)
                    verts.append(simd_float3(p.x + r.x * lat, y, p.z + r.z * lat))
                    cols.append(terrainColor(i, lat, y))
                    // planar UVs from (distance along road, lateral offset), so the
                    // detail texture tiles every 12 m in both directions
                    uvs.append(CGPoint(x: CGFloat(lat / 7),
                                       y: CGFloat(Float(i) * Self.step / 7)))
                }
                rows += 1
                i += rowStep
            }
            let w = lats.count
            for row in 0..<(rows - 1) {
                for j in 0..<(w - 1) {
                    let a = Int32(row * w + j)
                    let b = a + Int32(w)        // next row, same band
                    let c = a + 1               // same row, next band outward
                    let d = b + 1
                    // Both sides used to share this one index order — but +j walks
                    // in opposite world directions (lats are negative on the left,
                    // positive on the right), so the right side came out wound
                    // backwards: normals pointing down, so it never caught the sun,
                    // and back-facing, so grazing angles culled it and you saw
                    // straight through the ground.
                    if flip {
                        idx.append(contentsOf: [a, c, b, c, d, b])
                    } else {
                        idx.append(contentsOf: [a, b, c, c, b, d])
                    }
                }
            }
            // The hills fill more of the frame than the road does and were the
            // largest surface still on lambert — the flattest model available, so a
            // hillside lit only by vertex colour and flat grain. PBR with the same
            // derived-relief trick as the road gives the grass and pebbles something
            // to catch the low sun with.
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.metalness.contents = 0.0
            // ground is not shiny; a low value here made the hillsides look wet
            mat.roughness.contents = 0.92
            // detail texture multiplies against the per-vertex colours, which keep
            // driving hue (grass / rock / sand); the texture only adds grain
            mat.diffuse.contents = Self.groundTexture
            mat.diffuse.wrapS = .repeat
            mat.diffuse.wrapT = .repeat
            if let n = Self.groundNormal {
                mat.normal.contents = n
                mat.normal.wrapS = .repeat
                mat.normal.wrapT = .repeat
                mat.normal.intensity = 0.75
            }
            let node = SCNNode(geometry: makeGeometry(verts: verts, indices: idx,
                                                      uvs: uvs, colors: cols, material: mat))
            node.castsShadow = false
            parent.addChildNode(node)
        }
        side(latsL, flip: false)
        side(latsR, flip: true)
    }

    // MARK: - vegetation

    /// Stable jitter for the scenery props — palms, flamboyán crowns, boulders and
    /// the boulder placement tilt. Prop templates are built once and cloned, so
    /// they must not draw from `worldRng`: the count of draws taken from it is part
    /// of the fixed world's contract, and one extra would shift every later draw
    /// and move the rest of the scenery.
    ///
    /// Beware when checking values out of this by hand. The `* 43758` blows the gap
    /// between `Float` and `Double` wide open, so the same expression evaluated in
    /// float64 answers a different question — verify in Swift, not in a scratch
    /// script.
    private static func propHash(_ a: Int, _ b: Int) -> Float {
        let s = sinf(Float(a) * 12.9898 + Float(b) * 78.233) * 43758.5453
        return s - floorf(s)
    }

    /// The mound of shaved ice on a piragua: a peak, not a ball.
    ///
    /// This was an `SCNSphere` parked on the cone, which reads as a scoop of ice
    /// cream. A piragua is shaved ice packed into a peak with syrup poured over the
    /// top, so the colour belongs in a gradient running down the mound — saturated
    /// at the crown where the syrup pools, clean ice near the paper — rather than
    /// flat across a globe. That gradient is the whole tell, and it costs nothing
    /// but the vertex stream.
    ///
    /// Apex-first with rings widening downward, which is the same arrangement as
    /// `flamboyanCrownGeometry` — so the winding below is that function's, which was
    /// checked for outward normals rather than guessed at.
    private func piraguaIceGeometry(flavor: simd_float3,
                                    material: SCNMaterial) -> SCNGeometry {
        let rings = 6, sides = 12
        // Squat and full, not tall and pointed. At 0.46 high against a 0.30 base with
        // a 0.65 falloff this came to a peak that read as a candle flame — shaved ice
        // is heaped, and it slumps. Wider than the cup it sits on, too, so it
        // overhangs the paper the way a real one does.
        let height: Float = 0.33, baseR: Float = 0.32
        // A pale tint of the flavour, not white. Running the gradient down to near
        // white washed the whole mound out to cream once the emission was added on
        // top, and a piragua's colour is the thing you recognise it by from three
        // hundred metres back. Syrup soaks all the way through shaved ice; it is
        // only *denser* at the crown.
        let ice = simd_mix(flavor, simd_float3(repeating: 1), simd_float3(repeating: 0.50))
        var verts: [simd_float3] = [simd_float3(0, height, 0)]
        var cols: [simd_float3] = [flavor]
        var idx: [Int32] = []
        for r in 1...rings {
            let t = Float(r) / Float(rings)
            // 0.5 rather than 0.65: rounder shoulders, so it heaps instead of tapering
            let rad = baseR * powf(t, 0.50)
            let y = height * (1 - t)
            let c = simd_mix(flavor, ice, simd_float3(repeating: powf(t, 0.85)))
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                verts.append(simd_float3(cosf(a) * rad, y, sinf(a) * rad))
                cols.append(c)
            }
        }
        for s in 0..<sides {
            idx.append(contentsOf: [0, Int32(1 + (s + 1) % sides), Int32(1 + s)])
        }
        for r in 0..<(rings - 1) {
            for s in 0..<sides {
                let a = Int32(1 + r * sides + s)
                let b = Int32(1 + r * sides + (s + 1) % sides)
                let c = Int32(1 + (r + 1) * sides + s)
                let d = Int32(1 + (r + 1) * sides + (s + 1) % sides)
                idx.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        return makeGeometry(verts: verts, indices: idx, colors: cols, material: material)
    }

    /// A guardrail post: tapered, weathered at the foot, wider across the road than
    /// through it.
    ///
    /// These were world-axis-aligned `SCNBox`es in flat 0.91 white, and two things
    /// gave them away. Nothing rotated them to the road, so on every curve each post
    /// sat skew to the rail it carries and the line read as tics scattered along the
    /// verge. And near-white against the terrain made them glow — a galvanised post
    /// is mid-grey, dirty at the foot where the road throws grit up it, and bright
    /// only along the top edge. Both of those are free: the tone runs in the vertex
    /// stream, and orienting is one assignment at the call site.
    private func guardrailPostGeometry(timber: Bool, material: SCNMaterial) -> SCNGeometry {
        // half-width across the road, half-depth through it, height, tone
        let rings: [(Float, Float, Float, Float)] = [
            (0.10, 0.06, 0.00, 0.00),
            (0.095, 0.057, 0.22, 0.45),
            (0.088, 0.053, 0.55, 0.90),
            (0.082, 0.050, 0.85, 1.00)
        ]
        let low  = timber ? simd_float3(0.20, 0.14, 0.09) : simd_float3(0.28, 0.27, 0.24)
        let high = timber ? simd_float3(0.47, 0.34, 0.21) : simd_float3(0.78, 0.79, 0.78)

        var verts: [simd_float3] = []
        var cols: [simd_float3] = []
        var idx: [Int32] = []
        for (hw, hd, y, tone) in rings {
            let c = simd_mix(low, high, simd_float3(repeating: tone))
            for (sx, sz) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                verts.append(simd_float3(sx * hw, y, sz * hd))
                cols.append(c)
            }
        }
        for r in 0..<(rings.count - 1) {
            for s in 0..<4 {
                let a = Int32(r * 4 + s)
                let b = Int32(r * 4 + (s + 1) % 4)
                let c = Int32((r + 1) * 4 + s)
                let d = Int32((r + 1) * 4 + (s + 1) % 4)
                idx.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        // cap, so the top isn't an open hole seen from the camera's height
        let top = Int32((rings.count - 1) * 4)
        idx.append(contentsOf: [top, top + 1, top + 2, top, top + 2, top + 3])
        return makeGeometry(verts: verts, indices: idx, colors: cols, material: material)
    }

    /// A boulder: an irregular faceted lump, flat-shaded.
    ///
    /// These were `SCNSphere(isGeodesic: true, segmentCount: 6)` in one flat grey —
    /// a regular icosphere, so every rock on the mountain was the same evenly
    /// rounded shape in the same tone, and they read as brown hexagons pasted onto
    /// the hillside. What makes a boulder legible is that its faces are flat and
    /// each catches the light differently, so this pushes an icosahedron's twelve
    /// vertices in and out along their own radii, squashes the result, and emits
    /// every triangle with its own three vertices.
    ///
    /// The duplication is the whole point. `makeGeometry` averages normals across
    /// shared vertices, so sharing them here would smooth the facets straight back
    /// into the sphere this is replacing. 20 faces, 60 vertices — cheaper than
    /// keeping it round, and more subdivision would only undo the angularity.
    private func boulderGeometry(variant: Int, material: SCNMaterial) -> SCNGeometry {
        let t: Float = 1.618034
        var base: [simd_float3] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
            [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
            [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]
        ].map { simd_normalize(simd_float3($0[0], $0[1], $0[2])) }

        // Boulders sit — they are wider than they are tall. Both numbers below were
        // measured rather than eyeballed, because the first attempt at this did the
        // opposite of what it says: at a y-squash of 0.78–1.04 against x/z of
        // 0.86–1.16, the per-vertex jitter of ±29% simply swamped an 8% bias, and
        // two of the four variants came out *taller* than wide (ratios 0.69, 1.02,
        // 0.73, 1.01). Deepening the squash and taming the jitter to ±16% gives
        // 0.55, 0.72, 0.55, 0.72 — all sitting, still irregular. The placement loop
        // then applies its own y-squash on top, so these stay mild.
        let squash = simd_float3(0.92 + Self.propHash(variant, 21) * 0.24,
                                 0.60 + Self.propHash(variant, 22) * 0.18,
                                 0.92 + Self.propHash(variant, 23) * 0.24)
        for i in 0..<base.count {
            base[i] *= 0.82 + Self.propHash(variant &* 53 &+ i, 29) * 0.32
            base[i] *= squash
        }

        let faces: [[Int]] = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
            [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
            [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
            [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
        ]
        var verts: [simd_float3] = []
        var cols: [simd_float3] = []
        var idx: [Int32] = []
        let stone = simd_float3(0.47, 0.44, 0.37)
        for (f, tri) in faces.enumerated() {
            let a = base[tri[0]], b = base[tri[1]], c = base[tri[2]]
            let n = simd_normalize(simd_cross(b - a, c - a))
            // Sun-bleached and lichened where the face points up, damp and dark
            // where it points into the hillside.
            let up = n.y * 0.5 + 0.5
            let tone = simd_clamp(0.30 + up * 0.62
                                  + (Self.propHash(variant, f &+ 41) - 0.5) * 0.16, 0, 1)
            let col = simd_mix(stone * 0.52, stone * 1.28, simd_float3(repeating: tone))
            let o = Int32(verts.count)
            verts.append(a); verts.append(b); verts.append(c)
            cols.append(col); cols.append(col); cols.append(col)
            idx.append(contentsOf: [o, o + 1, o + 2])
        }
        return makeGeometry(verts: verts, indices: idx, colors: cols, material: material)
    }

    /// Flamboyán crown: a lumpy mass of bloom, not a ball and not a parasol.
    ///
    /// Two wrong answers preceded this one. It started as an `SCNSphere` squashed to
    /// 0.55, which read as a red lollipop on a stick — a perfect ellipse is the one
    /// silhouette no tree has. Replacing that with a wide smooth dome swapped one
    /// giveaway for a worse one: at 2.5 radius against a 1.1 rise, with a clean rim
    /// and a single flat red, it was a beach umbrella.
    ///
    /// What actually reads as a poinciana is the surface, not the outline. A tree in
    /// bloom is thousands of small flowers over dark foliage, so it is bumpy and its
    /// shading runs from near-black in the hollows to bright scarlet on the sunlit
    /// caps. Both come from per-vertex jitter here: radius and height are pushed
    /// around by a hash, and the colour is driven off the resulting height, so the
    /// lumps shade themselves. Taller and narrower than the umbrella version, too.
    ///
    /// Colour rides the vertex stream so all five shades share one white material.
    /// That is about the shading, not batching — the grove is added unflattened, so
    /// the draw count is the same either way (see the call site).
    private func flamboyanCrownGeometry(seed: Int, tint: simd_float3,
                                        material: SCNMaterial) -> SCNGeometry {
        // rimY is the normalising floor for the shading below, so it has to be the
        // geometry's actual lowest point, not an estimate of it. It was -0.34 while
        // the real minimum across the five seeds runs -0.63 to -0.69, which clamped
        // all 16 rim vertices of every crown to lit == 0 — the rim came out one flat
        // tone, losing exactly the jitter-driven shading this is all for.
        let apexY: Float = 1.45, rimY: Float = -0.70
        var verts: [simd_float3] = [simd_float3(0, apexY, 0)]
        var cols: [simd_float3] = [tint]
        var idx: [Int32] = []
        let rings = 5, sides = 16
        // three boughs of unequal weight — this is what scallops the outline
        let l1 = 0.20 + Self.propHash(seed, 11) * 0.10
        let l2 = 0.12 + Self.propHash(seed, 12) * 0.10
        let ph1 = Self.propHash(seed, 13) * 6.28, ph2 = Self.propHash(seed, 14) * 6.28
        for r in 1...rings {
            let t = Float(r) / Float(rings)
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                let n = Self.propHash(seed &* 97 &+ s &* 13, r &* 7 &+ 3)
                let lump = 1 + l1 * sinf(a * 3 + ph1) + l2 * sinf(a * 5 - ph2)
                let rad = 2.15 * sinf(t * .pi * 0.5) * lump * (0.86 + n * 0.28)
                let dome = apexY * cosf(t * .pi * 0.55) - 0.30 * t * t
                let y = dome + (n - 0.5) * 0.34
                verts.append(simd_float3(cos(a) * rad, y, sin(a) * rad))
                // Sunlit caps keep the tint; hollows and the underside drop to about
                // a third of it. Driving this off the jittered height is what makes
                // the bumps legible instead of a flat silhouette. The floor is 0.12
                // rather than 0.30 because the mix bottoms out at tint * (0.22 +
                // 0.78 * floor) — at 0.30 the darkest part of a crown was still
                // tint * 0.45, a mid red, and the shading barely read.
                let lit = simd_clamp((y - rimY) / (apexY - rimY), 0, 1)
                cols.append(simd_mix(tint * 0.22, tint,
                                     simd_float3(repeating: 0.12 + lit * 0.88)))
            }
        }
        // Apex fan wound so the face normal comes out +y. With the apex on the y
        // axis the y-component of cross(B-A, C-A) reduces to
        // R_b * R_c * sin(theta_s+1 - theta_s), which is positive regardless of the
        // heights involved — so this ordering holds even where ring-1 jitter pushes
        // a vertex above the apex, which it does for up to 6 of 16 per seed.
        for s in 0..<sides {
            idx.append(contentsOf: [0, Int32(1 + (s + 1) % sides), Int32(1 + s)])
        }
        for r in 0..<(rings - 1) {
            for s in 0..<sides {
                let a = Int32(1 + r * sides + s)
                let b = Int32(1 + r * sides + (s + 1) % sides)
                let c = Int32(1 + (r + 1) * sides + s)
                let d = Int32(1 + (r + 1) * sides + (s + 1) % sides)
                idx.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        return makeGeometry(verts: verts, indices: idx, colors: cols, material: material)
    }

    /// A whole palm — curved tapering trunk and crown — as a two-part template.
    ///
    /// The previous version was an `SCNCylinder` trunk with nine identical ribbons
    /// in one flat green, and it read as a cardboard cutout from any distance. Two
    /// reasons, both fixed here: a palm's silhouette *is* the curve and taper of its
    /// trunk, and a real crown is never one colour — it runs dark at the crown to
    /// bright at the tips, with a couple of dead brown fronds hanging under it.
    ///
    /// Colour is carried in the vertex stream rather than in extra materials,
    /// because the whole container is flattened and `flattenedClone()` quietly
    /// returns nothing once a node accumulates too many distinct materials — the bug
    /// that kept the flamboyanes and the casitas off screen entirely.
    ///
    /// Trunk and fronds are separate nodes on purpose, and it is only two materials,
    /// which is what the original palm had and flattened fine. Merging them into one
    /// geometry forced one material over both, and the fronds need `isDoubleSided`
    /// — which then also uncalled backface culling on the trunk, a closed tube whose
    /// backfaces are never visible. That is half the palm's triangles rasterised
    /// twice for nothing, 300 palms deep on Yunque.
    private func palmTemplate(variant: Int, trunkMaterial: SCNMaterial,
                              frondMaterial: SCNMaterial) -> SCNNode {
        var verts: [simd_float3] = []
        var cols: [simd_float3] = []
        var idx: [Int32] = []

        let rings = 9, sides = 7
        let height: Float = 7
        let leanDir = Self.propHash(variant, 1) * 6.28
        let lean: Float = 0.9 + Self.propHash(variant, 2) * 1.1
        let ldx = cos(leanDir), ldz = sin(leanDir)

        // Bend grows with the square of height: a palm curves up near the crown and
        // stands near-vertical at the root, which is what a straight cylinder missed.
        func trunkCentre(_ t: Float) -> simd_float3 {
            simd_float3(ldx * lean * t * t, height * t, ldz * lean * t * t)
        }

        for r in 0..<rings {
            let t = Float(r) / Float(rings - 1)
            let c = trunkCentre(t)
            // Stacked leaf scars, not a smooth pole — the ripple catches the low sun.
            let rad = 0.27 * (1 - 0.50 * t) * (0.90 + 0.10 * (sinf(t * 30) * 0.5 + 0.5))
            let shade = 0.60 + 0.26 * t          // sun-bleached toward the crown
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                verts.append(c + simd_float3(cos(a) * rad, 0, sin(a) * rad))
                cols.append(simd_float3(shade * 0.64, shade * 0.52, shade * 0.37))
            }
        }
        for r in 0..<(rings - 1) {
            for s in 0..<sides {
                let a = Int32(r * sides + s)
                let b = Int32(r * sides + (s + 1) % sides)
                let c = Int32((r + 1) * sides + s)
                let d = Int32((r + 1) * sides + (s + 1) % sides)
                idx.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        let trunkGeo = makeGeometry(verts: verts, indices: idx, colors: cols,
                                    material: trunkMaterial)
        verts.removeAll(); cols.removeAll(); idx.removeAll()

        // Crown seated on the trunk tip, so the lean carries all the way through.
        let crown = trunkCentre(1)
        let fronds = 10 + Int(Self.propHash(variant, 3) * 3)
        let segs = 5
        let deadLo = simd_float3(0.38, 0.29, 0.15), deadHi = simd_float3(0.54, 0.43, 0.23)
        let liveLo = simd_float3(0.07, 0.31, 0.13), liveHi = simd_float3(0.44, 0.76, 0.27)
        for f in 0..<fronds {
            let a = Float(f) / Float(fronds) * 2 * .pi + Self.propHash(variant, 4) * 3
            let dx = cos(a), dz = sin(a)
            // Old fronds hang, new ones near the spear stand up. Mixing the two is
            // most of what separates a palm from a green umbrella.
            let age = Self.propHash(variant &* 31 &+ f, 7)
            let reachMax: Float = 2.6 + age * 1.6
            let dropMax: Float = -0.4 - age * 2.8
            // One or two brown fronds per crown. Measured by running this hash in
            // Swift, which matters: `sinf(...) * 43758` amplifies the gap between
            // Float and Double so far that a float64 check of the same expression
            // reports entirely different crowns. At 0.87 the three variants give
            // 3/10, 2/12 and 2/11 — a third of the lead variant brown, and with
            // `placed % 3` cycling that lands in every grove. 0.92 gives 2/10,
            // 2/12, 1/11.
            let dead = age > 0.92
            func frondColor(_ t: Float) -> simd_float3 {
                simd_mix(dead ? deadLo : liveLo, dead ? deadHi : liveHi,
                         simd_float3(repeating: t))
            }
            var prevL = crown + simd_float3(0, 0.18, 0)
            var prevR = prevL
            var prevC = frondColor(0)
            for k in 1...segs {
                let t = Float(k) / Float(segs)
                let reach = t * reachMax
                let drop = dropMax * t * t                    // gravity along the frond
                let halfWidth = 0.44 * sinf(t * .pi) * (1 - t * 0.3)
                let spine = crown + simd_float3(dx * reach, 0.18 + drop, dz * reach)
                let side = simd_float3(-dz * halfWidth, 0, dx * halfWidth)
                let l = spine + side, r = spine - side
                let c = frondColor(t)
                let base = Int32(verts.count)
                verts.append(prevL); verts.append(prevR)
                verts.append(l);     verts.append(r)
                cols.append(prevC);  cols.append(prevC)
                cols.append(c);      cols.append(c)
                idx.append(contentsOf: [base, base + 2, base + 1,
                                        base + 1, base + 2, base + 3])
                prevL = l; prevR = r; prevC = c
            }
        }

        let palm = SCNNode()
        palm.addChildNode(SCNNode(geometry: trunkGeo))
        palm.addChildNode(SCNNode(geometry: makeGeometry(verts: verts, indices: idx,
                                                         colors: cols,
                                                         material: frondMaterial)))
        return palm
    }

    private func vegetation(_ parent: SCNNode) {
        var guard_ = 0
        let palmContainer = SCNNode()
        // Three silhouettes, one shared material. Instance scale and yaw alone left
        // every palm on the coast an obvious copy of its neighbour; varying the
        // trunk's lean direction and curve is what breaks up a row of them. The
        // single material is deliberate — see palmGeometry on the flattening limit.
        // Two materials, both white with the hue in the vertex stream. Only the
        // fronds are double-sided; the trunk is a closed tube and culling its
        // backfaces is free.
        let palmTrunkMat = lambert(.white)
        let palmFrondMat = lambert(.white)
        palmFrondMat.isDoubleSided = true
        let palmTemplates = (0..<3).map {
            palmTemplate(variant: $0, trunkMaterial: palmTrunkMat,
                         frondMaterial: palmFrondMat)
        }
        var placed = 0
        let treeTarget = Self.currentStage == .yunque ? 300
                       : (Self.currentStage == .playa ? 240 : 130)
        while placed < treeTarget && guard_ < 6000 {
            guard_ += 1
            // palms belong to the coast, with a scattering inland
            let pi = indexIn(pickRegion(&worldRng, simd_float3(0.22, 0.16, 0.62)), &worldRng)
            // rainforest crowds the path; the coast road lets it breathe
            let lat = (worldRng.next() < 0.55 ? 1 : -1)
                    * (Self.barrier + (Self.currentStage == .yunque ? 0.5 : 1.2)
                       + worldRng.next() * (Self.currentStage == .yunque ? 26 : 45))
            let gy = groundY(pi, lat)
            if gy < -1 { continue }
            let p = pts[pi], r = rights[pi]
            // Variant off the placement counter, not worldRng. Drawing here would
            // shift every later draw in this function and move the flamboyanes,
            // casitas and rocks — worldRng is the fixed world's seed, and the count
            // of draws taken from it is part of that contract.
            let clone = palmTemplates[placed % 3].clone()
            clone.position = SCNVector3(p.x + r.x * lat, gy - 0.3, p.z + r.z * lat)
            let sc = Self.currentStage == .yunque
                ? 1.3 + worldRng.next() * 1.1        // rainforest canopy is tall
                : 0.8 + worldRng.next() * 0.7
            clone.scale = SCNVector3(sc, sc, sc)
            clone.eulerAngles = SCNVector3((worldRng.next() - 0.5) * 0.2,
                                           worldRng.next() * 6.28,
                                           (worldRng.next() - 0.5) * 0.2)
            palmContainer.addChildNode(clone)
            placed += 1
        }
        let flatPalms = palmContainer.flattenedClone()
        flatPalms.castsShadow = true
        parent.addChildNode(flatPalms)

        // flamboyanes
        let flamGroups = (0..<5).map { _ in SCNNode() }
        // Geometry and materials are shared across a small set of shades. Creating
        // a fresh canopy material per tree gave the container ~46 distinct
        // materials, and flattenedClone() silently returns nothing once a
        // container has that many — which is why the flamboyanes and the casitas
        // never appeared on screen at all.
        // Flared base — a poinciana's trunk widens sharply where it meets the ground.
        let flamTrunkGeo = SCNCone(topRadius: 0.21, bottomRadius: 0.40, height: 2.6)
        flamTrunkGeo.materials = [lambert(UIColor(red: 0.43, green: 0.32, blue: 0.22, alpha: 1))]
        // One white material for all five shades — the tint rides the vertex stream.
        // Note this does *not* reduce draw calls: `flamGroups` are added unflattened
        // below, so the grove stays one node per trunk and crown either way. The
        // reason to share is that the tint has to live in the vertices for the
        // self-shading to work at all, and once it does, five materials would be
        // five copies of the same white.
        let flamMat = lambert(.white)
        flamMat.isDoubleSided = true      // the rim dips below the eye line downhill
        let canopyGeos: [SCNGeometry] = (0..<5).map { k in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(hue: CGFloat(0.02 + Double(k) * 0.011),
                    saturation: 0.92, brightness: 0.85, alpha: 1)
                .getRed(&r, green: &g, blue: &b, alpha: &a)
            return flamboyanCrownGeometry(seed: k,
                                          tint: simd_float3(Float(r), Float(g), Float(b)),
                                          material: flamMat)
        }
        placed = 0; guard_ = 0
        // flamboyanes are an inland tree; the shoreline gets palms instead
        let flamTarget = Self.currentStage == .playa ? 0 : 46
        while placed < flamTarget && guard_ < 2000 {
            guard_ += 1
            // flamboyanes line the pueblo and the lower mountain
            let fi = indexIn(pickRegion(&worldRng, simd_float3(0.34, 0.50, 0.16)), &worldRng)
            let flat = (worldRng.next() < 0.5 ? 1 : -1) * (Self.barrier + 0.8 + worldRng.next() * 26)
            let fgy = groundY(fi, flat)
            if fgy < 0 { continue }
            let fp = pts[fi], fr = rights[fi]
            let tree = SCNNode()
            let trunk = SCNNode(geometry: flamTrunkGeo)
            trunk.position.y = 1.3
            tree.addChildNode(trunk)
            let shade = Int(worldRng.next() * 5) % 5
            let can = SCNNode(geometry: canopyGeos[shade])
            // No y-squash any more: the crown geometry is already an umbrella, and
            // scaling it flat on top of that collapsed the droop the shape is for.
            can.position.y = 2.6
            tree.addChildNode(can)
            let fsc = 0.8 + worldRng.next() * 0.9
            tree.scale = SCNVector3(fsc, fsc, fsc)
            tree.position = SCNVector3(fp.x + fr.x * flat, fgy - 0.2, fp.z + fr.z * flat)
            flamGroups[shade].addChildNode(tree)
            placed += 1
        }
        for g in flamGroups where g.childNodes.count > 0 {
            parent.addChildNode(g)      // see the casitas note below
        }

        // casitas — one container per palette colour, so each ends up with just a
        // base + roof material. Flattening a single mixed container produced
        // nothing at all, which is why the casitas were never on screen.
        let palette: [UIColor] = [
            UIColor(red: 1, green: 0.42, blue: 0.62, alpha: 1),
            UIColor(red: 0.31, green: 0.8, blue: 0.77, alpha: 1),
            UIColor(red: 1, green: 0.9, blue: 0.43, alpha: 1),
            UIColor(red: 0.58, green: 0.88, blue: 0.83, alpha: 1),
            UIColor(red: 0.95, green: 0.51, blue: 0.51, alpha: 1),
            UIColor(red: 0.66, green: 0.85, blue: 0.92, alpha: 1),
            UIColor(red: 1, green: 0.7, blue: 0.28, alpha: 1),
            UIColor(red: 0.76, green: 0.96, blue: 0.52, alpha: 1)
        ]
        // 54 casitas, heavily clustered in the pueblo and pulled in tight to the road
        // there so it actually reads as driving through a town. Guajataca only —
        // `Region.pueblo` is just a fraction of the path, so without this gate the
        // houses were also appearing along the Yunque trail and on the beach.
        //
        // Resolved before the geometry rather than beside the placement loop, so the
        // other two stages skip building the facades entirely. Each one rasterises
        // 2,600 specks into a screen-scale context; eight of them is ~14 MB and a
        // visible slice of stage load, and on Yunque and the beach every byte of it
        // was thrown away unused. The loop itself takes no `worldRng` draws when the
        // target is zero, so gating the work above it leaves the world untouched.
        let houseTarget = Self.currentStage == .cordillera ? 54 : 0

        // one shared geometry per palette colour, for the same flattening reason
        let baseGeos: [SCNGeometry] = houseTarget == 0 ? [] : palette.map { c in
            let g = SCNBox(width: 4.2, height: 3, length: 5, chamferRadius: 0)
            let m = lambert(.white)
            m.diffuse.contents = Textures.casitaFacade(wall: c)
            g.materials = [m]
            return g
        }
        // Zinc, not a darkened wall. Roofs here were the base colour at 0.55, which
        // made every house a two-tone block of one hue — the one thing real casitas
        // never are, since the roof is corrugated metal and the walls are painted.
        // Rust-red and weathered galvanised, alternating down the palette.
        let roofGeos: [SCNGeometry] = houseTarget == 0 ? [] : palette.enumerated().map { k, _ in
            let zinc = k % 2 == 0
                ? UIColor(red: 0.54, green: 0.25, blue: 0.17, alpha: 1)   // rusted red
                : UIColor(red: 0.60, green: 0.62, blue: 0.60, alpha: 1)   // galvanised
            let g = SCNPyramid(width: 5.2, height: 1.7, length: 6)
            g.materials = [lambert(zinc, roughness: 0.62)]
            return g
        }
        let houseGroups = (0..<palette.count).map { _ in SCNNode() }
        placed = 0; guard_ = 0
        while placed < houseTarget && guard_ < 3000 {
            guard_ += 1
            let hr_ = pickRegion(&worldRng, simd_float3(0.13, 0.74, 0.13))
            let hi = indexIn(hr_, &worldRng)
            let spread: Float = hr_ == .pueblo ? 6 : 12
            let hlat = (worldRng.next() < 0.5 ? 1 : -1)
                     * (Self.barrier + (hr_ == .pueblo ? 2.0 : 3.5) + worldRng.next() * spread)
            let hgy = groundY(hi, hlat)
            if hgy < 0.5 { continue }
            let hp = pts[hi], hr = rights[hi]
            let ci = Int(worldRng.next() * Float(palette.count)) % palette.count
            let house = SCNNode()
            let base = SCNNode(geometry: baseGeos[ci])
            base.position.y = 1.5
            house.addChildNode(base)
            let roof = SCNNode(geometry: roofGeos[ci])
            roof.position.y = 3
            house.addChildNode(roof)
            let hsc = 0.9 + worldRng.next() * 0.5
            house.scale = SCNVector3(hsc, hsc, hsc)
            house.position = SCNVector3(hp.x + hr.x * hlat, hgy - 0.3, hp.z + hr.z * hlat)
            house.eulerAngles.y = atan2(tans[hi].x, -tans[hi].z) + (worldRng.next() - 0.5) * 0.5
            houseGroups[ci].addChildNode(house)
            placed += 1
        }
        // Added unflattened on purpose. flattenedClone() silently yields nothing
        // for these — not a material-count issue (grouping per colour, so two
        // materials each, fails identically), so rather than keep guessing at
        // SceneKit's flattening rules these stay as plain nodes. ~108 of them,
        // sharing 16 cached geometries so the renderer can still batch by
        // material. The casitas were invisible for the entire life of the port.
        for g in houseGroups where g.childNodes.count > 0 {
            parent.addChildNode(g)
        }

        // rocks + guardrail. A beach has no rail — the sea and the dune are the
        // boundary, which is the whole point of the stage.
        let wantRail = Self.currentStage != .playa
        let rockContainer = SCNNode()
        let rockMat = lambert(.white)
        let rockGeos = (0..<4).map { boulderGeometry(variant: $0, material: rockMat) }
        // Landslide country: the mountain road and the forest trail, never the sand.
        // This loop was ungated, so boulders were turning up on the beach too.
        let rockTarget = Self.currentStage == .playa ? 0 : 64
        for k in 0..<rockTarget {
            let ri = indexIn(pickRegion(&worldRng, simd_float3(0.68, 0.22, 0.10)), &worldRng)
            let rlat = -(Self.barrier + 0.8 + worldRng.next() * 40)
            let rp = pts[ri], rr2 = rights[ri]
            let rock = SCNNode(geometry: rockGeos[k % 4])
            rock.position = SCNVector3(rp.x + rr2.x * rlat, groundY(ri, rlat), rp.z + rr2.z * rlat)
            let rs = 0.5 + worldRng.next() * 1.6
            rock.scale = SCNVector3(rs, rs * (0.7 + worldRng.next() * 0.5), rs)
            rock.eulerAngles.y = worldRng.next() * 3
            // Deterministic tilt off the counter, so boulders sit at angles instead
            // of all standing on the same axis. Not from worldRng — the draw count
            // in this loop is part of the fixed world's contract.
            rock.eulerAngles.x = (Self.propHash(k, 61) - 0.5) * 0.5
            rock.eulerAngles.z = (Self.propHash(k, 67) - 0.5) * 0.5
            rockContainer.addChildNode(rock)
        }
        parent.addChildNode(rockContainer.flattenedClone())

        let postContainer = SCNNode()
        let postGeo = guardrailPostGeometry(timber: Self.currentStage == .yunque,
                                            material: lambert(.white))
        // Both sides now, and sitting on `barrier` — previously there was a single
        // line of posts at 5.1 and the actual death boundary was an invisible
        // cliff out at 8.6, so the rail you could see meant nothing.
        var gi = 0
        while gi < Self.count {
            let gp = pts[gi], gr = rights[gi]
            for side in [Float(-1), Float(1)] where wantRail {
                let lat = side * Self.barrier
                let post = SCNNode(geometry: postGeo)
                // Sits on the ground rather than centred on it: the geometry runs
                // from y = 0 up, where the box it replaced was centre-origin.
                post.position = SCNVector3(gp.x + gr.x * lat,
                                           groundY(gi, lat),
                                           gp.z + gr.z * lat)
                // Square to the road. Without this the posts stayed world-aligned
                // while the rail followed the curve, so every bend showed them skew
                // to the thing they hold up.
                post.eulerAngles.y = atan2(tans[gi].x, -tans[gi].z)
                postContainer.addChildNode(post)
            }
            gi += 4
        }
        parent.addChildNode(postContainer.flattenedClone())

        // A continuous beam between the posts. Isolated posts read as scenery;
        // a rail reads as a wall you must not cross, which is the whole point of
        // having a boundary you can see.
        let railMat = SCNMaterial()
        if Self.currentStage == .yunque {
            // a rough timber handrail, not galvanised steel
            railMat.lightingModel = .lambert
            railMat.diffuse.contents = UIColor(red: 0.40, green: 0.28, blue: 0.18, alpha: 1)
        } else {
            railMat.lightingModel = .physicallyBased
            // Weathered galvanised, not chrome. At metalness 0.85 / roughness 0.34
            // this was mirror enough that it took its colour almost entirely from
            // the sunset cubemap and ran the length of the course as a salmon-pink
            // ribbon. Zinc coating is dull and the sea air here does not leave it
            // polished; pulling the metalness down and the roughness up lets its own
            // grey come through with only a warm cast on top.
            // Metalness is the whole story here. At 0.85 the beam took its colour
            // from the sunset cubemap and ran the length of the course as a salmon
            // ribbon; 0.42 barely moved it. The posts beside it, at metalness 0,
            // read correctly as pale grey under the same light — so the beam goes
            // nearly diffuse too, with a cool cast in the albedo to sit against the
            // warm key rather than soak it up. Zinc coating is matte and the sea air
            // here does not leave it polished.
            railMat.diffuse.contents = UIColor(red: 0.63, green: 0.65, blue: 0.67, alpha: 1)
            railMat.metalness.contents = 0.18
            railMat.roughness.contents = 0.72
        }
        railMat.isDoubleSided = true
        for side in [Float(-1), Float(1)] where wantRail {
            var rvv: [simd_float3] = [], rii: [Int32] = []
            var n: Int32 = 0
            let lat = side * Self.barrier
            var i = 0
            while i < Self.count - 2 {
                let p0 = pts[i], r0 = rights[i]
                let p1 = pts[i + 2], r1 = rights[i + 2]
                let y0 = groundY(i, lat), y1 = groundY(i + 2, lat)
                let b0 = simd_float3(p0.x + r0.x * lat, y0 + 0.46, p0.z + r0.z * lat)
                let b1 = simd_float3(p1.x + r1.x * lat, y1 + 0.46, p1.z + r1.z * lat)
                rvv.append(b0); rvv.append(b0 + simd_float3(0, 0.30, 0))
                rvv.append(b1); rvv.append(b1 + simd_float3(0, 0.30, 0))
                rii.append(contentsOf: [n, n + 1, n + 2, n + 1, n + 3, n + 2])
                n += 4
                i += 2
            }
            let rail = SCNNode(geometry: makeGeometry(verts: rvv, indices: rii, material: railMat))
            rail.castsShadow = false
            parent.addChildNode(rail)
        }
    }

    private func props(_ parent: SCNNode) {
        let flagImg = Textures.prFlag()
        for i in 0..<10 {
            let fi = 60 + i * (Self.count - 120) / 10
            let lat: Float = (i % 2 == 0 ? -1 : 1) * (Self.barrier + 1.4)
            let p = pts[fi], r = rights[fi]
            let gy = max(groundY(fi, lat), p.y)
            let pole = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 4.4))
            pole.geometry!.materials = [lambert(UIColor(white: 0.78, alpha: 1))]
            pole.position = SCNVector3(p.x + r.x * lat, gy + 2.2, p.z + r.z * lat)
            let flag = SCNNode(geometry: SCNPlane(width: 1.6, height: 1.05))
            let fm = lambert(.white)
            fm.diffuse.contents = flagImg
            fm.isDoubleSided = true
            flag.geometry!.materials = [fm]
            flag.position = SCNVector3(0.82, 1.55, 0)
            flag.eulerAngles.y = worldRng.next() * 6.28
            pole.addChildNode(flag)
            parent.addChildNode(pole)
        }

        func arch(_ i2: Int, _ text: String, _ color: UIColor) {
            let p = pts[i2], t = tans[i2]
            let grp = SCNNode()
            let postGeo = SCNCylinder(radius: 0.14, height: 6)
            postGeo.materials = [lambert(UIColor(white: 0.95, alpha: 1))]
            let archHalf = Self.barrier + 0.5
            for xo in [-archHalf, archHalf] {
                let post = SCNNode(geometry: postGeo)
                post.position = SCNVector3(xo, 3, 0)
                grp.addChildNode(post)
            }
            let banner = SCNNode(geometry: SCNPlane(width: CGFloat(archHalf * 2 + 0.4), height: 1.6))
            let bm = constant(.white)
            bm.diffuse.contents = Textures.banner(text: text, background: color)
            bm.isDoubleSided = true
            banner.geometry!.materials = [bm]
            banner.position.y = 5.6
            grp.addChildNode(banner)
            grp.simdPosition = p
            grp.simdLook(at: p + t, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
            parent.addChildNode(grp)
        }
        // sits just ahead of the 40 m starting point
        // Pueblo street lamps. Warm emissive heads against the sunset, which the
        // HDR bloom picks up — the cheapest way to make the town feel inhabited.
        let lampContainer = SCNNode()
        let wantLamps = Self.currentStage == .cordillera
        let lampPoleMat = lambert(UIColor(white: 0.42, alpha: 1))
        let lampHeadMat = constant(UIColor(red: 1.0, green: 0.86, blue: 0.60, alpha: 1))
        lampHeadMat.emission.contents = UIColor(red: 1.0, green: 0.80, blue: 0.48, alpha: 1)
        lampHeadMat.emission.intensity = 1.9
        let poleGeo = SCNCylinder(radius: 0.09, height: 5.4)
        poleGeo.materials = [lampPoleMat]
        let headGeo = SCNBox(width: 0.62, height: 0.2, length: 0.34, chamferRadius: 0.07)
        headGeo.materials = [lampHeadMat]
        let pSpan = Region.pueblo.span
        var li = Int(pSpan.lo * Float(Self.count))
        let lEnd = Int(pSpan.hi * Float(Self.count))
        while li < lEnd && wantLamps {
            for side in [Float(-1), Float(1)] {
                let lat = side * (Self.barrier + 1.1)
                let lp = pts[li], lr = rights[li]
                let gy = groundY(li, lat)
                let lamp = SCNNode()
                let pole = SCNNode(geometry: poleGeo)
                pole.position.y = 2.7
                lamp.addChildNode(pole)
                let head = SCNNode(geometry: headGeo)
                head.position = SCNVector3(-side * 0.34, 5.3, 0)
                lamp.addChildNode(head)
                lamp.position = SCNVector3(lp.x + lr.x * lat, gy, lp.z + lr.z * lat)
                lamp.eulerAngles.y = atan2(lr.x, -lr.z)
                lampContainer.addChildNode(lamp)
            }
            li += 15                       // ~30 m spacing
        }
        parent.addChildNode(lampContainer.flattenedClone())

        arch(24, "¡SALIDA!", UIColor(red: 0.88, green: 0.13, blue: 0.22, alpha: 1))
        arch(Self.count - 8, "¡META!", UIColor(red: 0, green: 0.31, blue: 0.63, alpha: 1))

        let umbCols: [UIColor] = [.neonPinkUI, .neonGoldUI, .neonTealUI, .sunsetOrangeUI]
        let wantUmbrellas = Self.currentStage != .yunque
        for u in 0..<6 where wantUmbrellas {
            let ui = Self.count - 30 - Int(worldRng.next() * 40)
            let ulat = (worldRng.next() < 0.5 ? 1 : -1) * (Self.barrier + 0.5 + worldRng.next() * 12)
            let ugy = groundY(ui, ulat)
            if ugy < -0.5 { continue }
            let up = pts[ui], ur = rights[ui]
            let umb = SCNNode()
            let pole = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 2))
            pole.geometry!.materials = [lambert(UIColor(white: 0.87, alpha: 1))]
            pole.position.y = 1
            umb.addChildNode(pole)
            let top = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 1.5, height: 0.7))
            top.geometry!.materials = [lambert(umbCols[u % 4])]
            top.position.y = 1.9
            umb.addChildNode(top)
            umb.position = SCNVector3(up.x + ur.x * ulat, ugy, up.z + ur.z * ulat)
            umb.eulerAngles.z = (worldRng.next() - 0.5) * 0.3
            parent.addChildNode(umb)
        }
    }

    // MARK: - hazard layout (reseeded every run)

    /// Generates the pothole field and re-places pickups, iguanas and traffic
    /// from `runRng`. Called on the render thread from `resetGame`, which is the
    /// sanctioned place to mutate the graph, so rebuilding the two merged
    /// pothole meshes here is safe.
    private func layoutHazards() {
        holes.removeAll(keepingCapacity: true)

        var hv: [simd_float3] = [], hi_: [Int32] = [], huv: [CGPoint] = []
        var rv: [simd_float3] = [], ri_: [Int32] = []
        var hn: Int32 = 0, rn2: Int32 = 0
        let seg = 12

        func addHole(_ hs: Float, _ hx: Float, _ hr: Float) {
            let (pos, tan, rgt) = sample(hs)
            let c = pos + rgt * hx
            let rot = runRng.next() * 6.28
            let sq = 0.75 + runRng.next() * 0.5
            hv.append(simd_float3(c.x, c.y + 0.045, c.z))
            huv.append(CGPoint(x: 0.5, y: 0.5))
            for k in 0...seg {
                let a = rot + Float(k) / Float(seg) * 2 * .pi
                let wob = 1 + 0.18 * sin(a * 3 + rot * 7)
                let ca = cos(a) * hr * wob, sa = sin(a) * hr * sq * wob
                hv.append(simd_float3(c.x + rgt.x * ca + tan.x * sa, c.y + 0.045,
                                      c.z + rgt.z * ca + tan.z * sa))
                // unit-circle UV so the depth gradient maps centre-out regardless
                // of how the rim is wobbled or squashed
                huv.append(CGPoint(x: CGFloat(0.5 + 0.5 * cos(a)),
                                   y: CGFloat(0.5 + 0.5 * sin(a))))
            }
            for k in 0..<seg { hi_.append(contentsOf: [hn, hn + 1 + Int32(k), hn + 2 + Int32(k)]) }
            hn += Int32(seg + 2)
            for k in 0...seg {
                let a = rot + Float(k) / Float(seg) * 2 * .pi
                let wob = 1 + 0.18 * sin(a * 3 + rot * 7)
                let ca = cos(a) * wob, sa = sin(a) * sq * wob
                rv.append(simd_float3(c.x + (rgt.x * ca + tan.x * sa) * hr, c.y + 0.038,
                                      c.z + (rgt.z * ca + tan.z * sa) * hr))
                let r2 = hr * 1.62
                rv.append(simd_float3(c.x + (rgt.x * ca + tan.x * sa) * r2, c.y + 0.038,
                                      c.z + (rgt.z * ca + tan.z * sa) * r2))
            }
            for k in 0..<seg {
                let b = rn2 + Int32(k * 2)
                ri_.append(contentsOf: [b, b + 1, b + 2, b + 1, b + 3, b + 2])
            }
            rn2 += Int32((seg + 1) * 2)
            holes.append(Hole(s: hs, x: hx, r: hr * sq + 0.15))
        }

        // density and cluster size ramp with distance — the back half of the
        // mountain should feel worse than the top
        // Per-region character: the cordillera throws a few big landslide craters,
        // the pueblo is a dense minefield of small municipal hoyos, the costa opens
        // up into long clean stretches so the run finishes fast.
        var cs: Float = 230
        while cs < Self.total - 260 {
            let prog = cs / Self.total
            let w = Self.regionWeights(prog)
            // Endless laps tighten the whole field. Capped so a long run stays
            // playable rather than becoming an unbroken wall of holes.
            let lapK = min(Float(lap - 1), 6)
            let clusterMax = (w.x * 2.4 + w.y * 4.2 + w.z * 1.9) + lapK * 0.45
            let radiusMax  = (w.x * 1.30 + w.y * 0.80 + w.z * 0.95) + lapK * 0.06
            let spacing    = (w.x * 74 + w.y * 40 + w.z * 104) * pow(0.9, lapK)
            let n = 1 + Int(runRng.next() * clusterMax)
            let gapC = (runRng.next() - 0.5) * (Self.roadHalf * 1.2)
            for _ in 0..<n {
                var tries = 0
                var hx: Float = 0
                repeat { hx = (runRng.next() - 0.5) * (Self.roadHalf * 2 - 1.6); tries += 1 }
                while abs(hx - gapC) < 2.2 && tries < 12
                if tries >= 12 { continue }
                addHole(cs + (runRng.next() - 0.5) * 12, hx, 0.5 + runRng.next() * radiusMax)
            }
            cs += spacing * (0.62 + runRng.next() * 0.7)
        }

        // Rim is much brighter and warmer than before (was 0.34 grey against
        // 0.22 asphalt — invisible at 200 km/h) and slightly emissive so it
        // still reads inside the hillside shadows.
        let holeMat = SCNMaterial()
        holeMat.lightingModel = .constant
        holeMat.diffuse.contents = Self.holeTexture
        let rimMat = constant(UIColor(red: 0.66, green: 0.62, blue: 0.55, alpha: 1))
        rimMat.emission.contents = UIColor(red: 0.30, green: 0.24, blue: 0.18, alpha: 1)
        holeNode.geometry = makeGeometry(verts: hv, indices: hi_, uvs: huv, material: holeMat)
        rimNode.geometry = makeGeometry(verts: rv, indices: ri_, material: rimMat)
        holeNode.castsShadow = false
        rimNode.castsShadow = false

        // pickups
        for i in 0..<piraguas.count {
            let ps = 150 + (Float(i) + runRng.next() * 0.6) * (Self.total - 380) / Float(piraguas.count)
            let px2 = (runRng.next() - 0.5) * (Self.roadHalf * 2 - 2.6)
            let (pos, _, rgt) = sample(ps)
            let world = pos + rgt * px2
            piraguas[i].s = ps
            piraguas[i].x = px2
            piraguas[i].baseY = world.y + 1.0
            piraguas[i].taken = false
            piraguas[i].node.position = SCNVector3(world.x, world.y + 1.0, world.z)
            piraguas[i].node.isHidden = false
        }
        for i in 0..<toolboxes.count {
            let ts = 380 + (Float(i) + runRng.next() * 0.5) * (Self.total - 700) / Float(toolboxes.count)
            let tx = (runRng.next() - 0.5) * (Self.roadHalf * 2 - 3)
            let (pos, _, rgt) = sample(ts)
            let world = pos + rgt * tx
            toolboxes[i].s = ts
            toolboxes[i].x = tx
            toolboxes[i].baseY = world.y + 0.9
            toolboxes[i].taken = false
            toolboxes[i].node.position = SCNVector3(world.x, world.y + 0.9, world.z)
            toolboxes[i].node.isHidden = false
        }
        // iguanas are country creatures — mountain and coast, barely any in town
        let iguanaRegions: [Region] = [.cordillera, .cordillera, .cordillera, .cordillera,
                                       .cordillera, .pueblo, .pueblo,
                                       .costa, .costa, .costa, .costa, .costa]
        for i in 0..<iguanas.count {
            let span = iguanaRegions[i % iguanaRegions.count].span
            let f = span.lo + 0.06 + runRng.next() * max(0.05, (span.hi - 0.06) - (span.lo + 0.06))
            iguanas[i].s = f * Self.total
            iguanas[i].dir = runRng.next() < 0.5 ? 1 : -1
            iguanas[i].stateRaw = 0
            iguanas[i].hit = false
            iguanas[i].x = -iguanas[i].dir * (Self.roadHalf + 1.5)
            iguanas[i].node.eulerAngles.z = 0
            positionIguana(&iguanas[i])
        }
        layoutCritters()
        for i in 0..<traffic.count {
            traffic[i].s = 300 + Float(i) * 420 + runRng.next() * 150
            traffic[i].x = Self.laneCentres[Int(runRng.next() * 4) % 4]
            traffic[i].v = 11 + runRng.next() * 7
            traffic[i].cool = 0
            traffic[i].missed = false
        }
    }

    // MARK: - pickups, iguanas, traffic (nodes only; layout assigns positions)

    private func makePiraguas(_ parent: SCNNode) {
        let flavors: [UIColor] = [
            UIColor(red: 1, green: 0.18, blue: 0.31, alpha: 1),
            UIColor(red: 1, green: 0.54, blue: 0.1, alpha: 1),
            UIColor(red: 0.18, green: 0.42, blue: 1, alpha: 1),
            UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1),
            UIColor(red: 0.76, green: 0.23, blue: 1, alpha: 1)
        ]
        // One cup geometry and one ice geometry per flavour, built up front and
        // shared. The old loop created a fresh SCNMaterial per piragua — 26 of them
        // for 5 distinct colours.
        //
        // A blunt tip rather than a true point: a paper cone sits in a holder, and a
        // needle-sharp cone reads as a party hat. Shorter and narrower than the ice
        // above it — at 0.30 x 0.40 the paper was as big as the mound, and on a real
        // piragua the ice is the object and the cup is what you hold it by.
        let cupGeo = SCNCone(topRadius: 0.26, bottomRadius: 0.05, height: 0.30)
        cupGeo.materials = [lambert(UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1))]
        let iceGeos: [SCNGeometry] = flavors.map { c in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            // Emission stays on the flavour and stays bright: these are pickups on a
            // 3.6 km course and have to be spottable from a long way back. It is the
            // diffuse, carrying the vertex gradient, that does the describing.
            let m = SCNMaterial()
            m.lightingModel = .lambert
            m.diffuse.contents = UIColor.white
            m.emission.contents = c
            // 0.42, down from 1.5. Emission is flat across a mesh, so every point of
            // it flattens the vertex gradient underneath — at 0.95 the mound was one
            // uniform slab of colour and the syrup gradient was invisible, which the
            // `-inspect` camera showed immediately and no amount of screenshotting a
            // run ever would have. The lost distance-visibility is bought back in the
            // albedo instead: the ice tint sits at 0.50 toward white rather than
            // 0.62, so the whole mound is more saturated to begin with.
            m.emission.intensity = 0.42
            return piraguaIceGeometry(flavor: simd_float3(Float(r), Float(g), Float(b)),
                                      material: m)
        }
        for i in 0..<26 {
            let grp = SCNNode()
            let cup = SCNNode(geometry: cupGeo)
            grp.addChildNode(cup)
            let ice = SCNNode(geometry: iceGeos[i % iceGeos.count])
            ice.position.y = 0.10          // sunk just below the rim, so it sits *in* the cup
            grp.addChildNode(ice)
            parent.addChildNode(grp)
            piraguas.append(Pickup(node: grp))
        }
    }

    private func makeToolboxes(_ parent: SCNNode) {
        let boxMat = SCNMaterial()
        boxMat.lightingModel = .lambert
        boxMat.diffuse.contents = UIColor(red: 0.85, green: 0.21, blue: 0.18, alpha: 1)
        boxMat.emission.contents = UIColor(red: 0.85, green: 0.21, blue: 0.18, alpha: 1)
        boxMat.emission.intensity = 0.5
        let bandMat = lambert(UIColor(white: 0.95, alpha: 1))
        // The handle is what turns a red box into a toolbox. Everything else about
        // this prop already read — the colour, the lid seam — but the silhouette was
        // a chamfered cube, and at speed a silhouette is most of what a player gets.
        // Steel rather than the body's red, so it separates against it.
        let handleMat = lambert(UIColor(white: 0.62, alpha: 1), roughness: 0.55)
        let uprightGeo = SCNBox(width: 0.035, height: 0.075, length: 0.035, chamferRadius: 0.01)
        uprightGeo.materials = [handleMat]
        let barGeo = SCNBox(width: 0.30, height: 0.035, length: 0.055, chamferRadius: 0.015)
        barGeo.materials = [handleMat]
        // 14, up from 10 — with the damage rebalance the mechanic is the main
        // way a long run stays alive
        for _ in 0..<14 {
            let grp = SCNNode()
            let box = SCNNode(geometry: SCNBox(width: 0.52, height: 0.34, length: 0.38, chamferRadius: 0.04))
            box.geometry!.materials = [boxMat]
            grp.addChildNode(box)
            let band = SCNNode(geometry: SCNBox(width: 0.54, height: 0.1, length: 0.4, chamferRadius: 0.02))
            band.geometry!.materials = [bandMat]
            grp.addChildNode(band)
            for xo in [Float(-0.12), 0.12] {
                let up = SCNNode(geometry: uprightGeo)
                up.position = SCNVector3(xo, 0.205, 0)
                grp.addChildNode(up)
            }
            let bar = SCNNode(geometry: barGeo)
            bar.position = SCNVector3(0, 0.253, 0)
            grp.addChildNode(bar)
            parent.addChildNode(grp)
            toolboxes.append(Pickup(node: grp))
        }
    }

    private func makeIguanas(_ parent: SCNNode) {
        for _ in 0..<12 {
            let mat = lambert(UIColor(red: 0.35, green: 0.56, blue: 0.24, alpha: 1))
            let grp = SCNNode()
            let body = SCNNode(geometry: SCNBox(width: 0.34, height: 0.22, length: 0.9, chamferRadius: 0.04))
            body.geometry!.materials = [mat]; body.position.y = 0.16
            grp.addChildNode(body)
            let head = SCNNode(geometry: SCNBox(width: 0.2, height: 0.16, length: 0.3, chamferRadius: 0.03))
            head.geometry!.materials = [mat]; head.position = SCNVector3(0, 0.2, -0.55)
            grp.addChildNode(head)
            let tail = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.1, height: 1.0))
            tail.geometry!.materials = [mat]
            tail.eulerAngles.x = -.pi / 2
            tail.position = SCNVector3(0, 0.14, 0.9)
            grp.addChildNode(tail)
            parent.addChildNode(grp)
            iguanas.append(Iguana(node: grp))
        }
    }

    private func positionIguana(_ ig: inout Iguana) {
        let (pos, _, rgt) = sample(ig.s)
        let world = pos + rgt * ig.x
        ig.node.simdPosition = simd_float3(world.x, pos.y + 0.05, world.z)
        let target = ig.node.simdPosition + rgt * ig.dir
        ig.node.simdLook(at: target, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
    }

    private func trafficCar(_ color: UIColor, police: Bool = false) -> SCNNode {
        let grp = SCNNode()
        if police {
            // roof light bar; the two materials are shared across every cruiser so
            // one pair of emission writes per frame flashes all of them in sync
            let bar = SCNNode(geometry: SCNBox(width: 1.0, height: 0.1, length: 0.22, chamferRadius: 0.03))
            bar.geometry!.materials = [lambert(UIColor(white: 0.12, alpha: 1))]
            bar.position = SCNVector3(0, 1.24, 0.2)
            grp.addChildNode(bar)
            let lensGeoL = SCNBox(width: 0.42, height: 0.14, length: 0.24, chamferRadius: 0.04)
            lensGeoL.materials = [policeRedMat]
            let left = SCNNode(geometry: lensGeoL)
            left.position = SCNVector3(-0.26, 1.3, 0.2)
            grp.addChildNode(left)
            let lensGeoR = SCNBox(width: 0.42, height: 0.14, length: 0.24, chamferRadius: 0.04)
            lensGeoR.materials = [policeBlueMat]
            let right = SCNNode(geometry: lensGeoR)
            right.position = SCNVector3(0.26, 1.3, 0.2)
            grp.addChildNode(right)
        }
        // Car paint, physically based like everything else in the frame. This was
        // the last `.blinn` surface in the scene — the pass that moved the scenery
        // to PBR "so the whole frame answers to one light" missed the traffic, so
        // nine cars sat in the middle of the road lit by different rules than the
        // road under them. Low metalness with a tight roughness is clearcoat-ish
        // without going chrome.
        let bodyMat = SCNMaterial()
        bodyMat.lightingModel = .physicallyBased
        bodyMat.diffuse.contents = color
        bodyMat.metalness.contents = 0.12
        bodyMat.roughness.contents = 0.32
        let body = SCNNode(geometry: SCNBox(width: 1.7, height: 0.5, length: 3.6, chamferRadius: 0.08))
        body.geometry!.materials = [bodyMat]; body.position.y = 0.5
        grp.addChildNode(body)
        let cabin = SCNNode(geometry: SCNBox(width: 1.5, height: 0.45, length: 1.7, chamferRadius: 0.08))
        cabin.geometry!.materials = [lambert(UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1))]
        cabin.position = SCNVector3(0, 0.95, 0.2)
        grp.addChildNode(cabin)
        let wg = SCNCylinder(radius: 0.3, height: 0.22)
        wg.materials = [lambert(UIColor(red: 0.08, green: 0.09, blue: 0.1, alpha: 1))]
        for o in [SCNVector3(-0.8, 0.3, 1.15), SCNVector3(0.8, 0.3, 1.15),
                  SCNVector3(-0.8, 0.3, -1.15), SCNVector3(0.8, 0.3, -1.15)] {
            let w = SCNNode(geometry: wg)
            w.eulerAngles.z = .pi / 2
            w.position = o
            grp.addChildNode(w)
        }
        // Tail lights carry emission now, not just a flat constant colour. You spend
        // the whole race closing on the backs of these, and at sunset an unlit red
        // rectangle reads as a sticker — this is the one part of a car ahead that
        // should pick up the bloom. Kept under the brake lights' 1.6 because these
        // are always on rather than a moment of braking.
        let tlMat = constant(UIColor(red: 1, green: 0.13, blue: 0.13, alpha: 1))
        tlMat.emission.contents = UIColor(red: 1, green: 0.16, blue: 0.12, alpha: 1)
        tlMat.emission.intensity = 1.1
        let tl = SCNNode(geometry: SCNBox(width: 1.5, height: 0.12, length: 0.06, chamferRadius: 0))
        tl.geometry!.materials = [tlMat]
        tl.position = SCNVector3(0, 0.62, 1.84)
        grp.addChildNode(tl)
        return grp
    }

    /// Heat, spawning, and the chase. The escalation is deliberate: holding a big
    /// combo is what draws them, so the mechanic that had no downside now has one.
    private func updatePursuit(_ dt: Float) {
        let active = pursuers.reduce(0) { $0 + ($1.live ? 1 : 0) }
        if spawnCool > 0 { spawnCool = max(0, spawnCool - dt) }

        // Heat builds while you are stringing things together and bleeds off when
        // you stop. Gain is deliberately shallow: on a course where near-misses fire
        // constantly the old rate held combo at the cap and heat pinned at 100 for
        // the entire run, so the chase was a permanent state rather than a
        // consequence of a hot streak.
        if combo >= 3 {
            heat += dt * (2.5 + Float(combo) * 1.5)
        } else {
            heat -= dt * 14
        }
        heat = simd_clamp(heat, 0, 100)

        // Spends the whole meter, and a floor between spawns. Subtracting a fixed
        // amount left it near the threshold and refilled almost immediately.
        if heat >= 100, spawnCool <= 0, active < pursuers.count {
            heat = 0
            spawnCool = Self.spawnGap
            spawnPursuer()
        }

        for i in 0..<pursuers.count where pursuers[i].live {
            var p = pursuers[i]
            p.life -= dt
            if p.ramCool > 0 { p.ramCool -= dt }

            // It comes from behind but does not stay there: with a chase camera you
            // would never see it, and the beam only fires forward, so a cruiser
            // sitting on your bumper is damage you can neither see nor answer. It
            // overtakes into frame and harasses from in front, where it can be shot.
            let gap = s - p.s
            let target = s + 13
            let want = v + simd_clamp((target - p.s) * 0.35, -9, 15)
            p.v += (want - p.v) * min(1, 2.2 * dt)
            p.v = simd_clamp(p.v, 0, 70)
            p.s += p.v * dt
            // slide into your lane
            p.x += simd_clamp(x - p.x, -1, 1) * dt * 3.4
            p.x = simd_clamp(p.x, -Self.barrier, Self.barrier)

            // Ram. Airborne is a genuine escape: they cannot follow you up.
            if p.ramCool <= 0, !airborne, abs(p.s - s) < 3.4, abs(p.x - x) < 1.9 {
                p.ramCool = 1.7
                let side: Float = x >= p.x ? 1 : -1
                xd += side * 7
                v *= 0.9
                shake = max(shake, 0.9)
                sound.playThunk()
                damage(9, "¡LA POLICÍA!", tone: .hit)
            }

            // Gives up if you break away, or once it has had its run at you.
            if p.life <= 0 || gap > 150 {
                p.live = false
                p.node.isHidden = true
            }
            pursuers[i] = p
            positionPursuer(pursuers[i])
        }
    }

    private func spawnPursuer() {
        guard let i = pursuers.firstIndex(where: { !$0.live }) else { return }
        pursuers[i].live = true
        pursuers[i].s = max(0, s - 58)
        pursuers[i].x = x
        pursuers[i].v = v
        pursuers[i].life = Self.pursuerLife
        pursuers[i].ramCool = 0
        pursuers[i].spin = 0
        pursuers[i].node.isHidden = false
        positionPursuer(pursuers[i])
        sound.playSiren()
        Haptics.shared.crash(intensity: 0.6)
        popupAsync("¡TE VIO LA POLICÍA!", .hit)
    }

    private func positionPursuer(_ p: Pursuer) {
        let (pp, pt, pr) = sample(p.s)
        p.node.simdPosition = pp + pr * p.x
        p.node.simdLook(at: pp + pr * p.x + pt, up: simd_float3(0, 1, 0),
                        localFront: simd_float3(0, 0, -1))
        if p.spin != 0 { p.node.eulerAngles.y += p.spin }
    }

    private func clearPursuit() {
        heat = 0
        spawnCool = 0
        for i in 0..<pursuers.count {
            pursuers[i].live = false
            pursuers[i].node.isHidden = true
        }
    }

    private func makePursuers(_ parent: SCNNode) {
        for _ in 0..<2 {
            let node = trafficCar(UIColor(white: 0.93, alpha: 1), police: true)
            node.isHidden = true
            parent.addChildNode(node)
            pursuers.append(Pursuer(node: node))
        }
    }

    private func makeTraffic(_ parent: SCNNode) {
        guard Self.currentStage == .cordillera else { return }
        let colors: [UIColor] = [
            UIColor(white: 0.85, alpha: 1),
            UIColor(red: 0.25, green: 0.42, blue: 0.85, alpha: 1),
            UIColor(red: 0.85, green: 0.7, blue: 0.25, alpha: 1),
            UIColor(white: 0.58, alpha: 1),
            UIColor(red: 0.4, green: 0.77, blue: 0.42, alpha: 1),
            UIColor(red: 0.77, green: 0.27, blue: 0.27, alpha: 1),
            UIColor(white: 0.94, alpha: 1)
        ]
        // two of the nine are cruisers — they hunt the saucer, so they belong here
        for i in 0..<9 {
            let police = (i == 2 || i == 6)
            let node = trafficCar(police ? UIColor(white: 0.93, alpha: 1) : colors[i % colors.count],
                                  police: police)
            parent.addChildNode(node)
            var t = Traffic(node: node)
            t.isPolice = police
            traffic.append(t)
        }
    }

    // MARK: - skid marks

    /// A ring buffer of unit quads. Each drift segment reuses a slot by
    /// transform only — no geometry is rebuilt while driving.
    private func skidPool(_ parent: SCNNode) {
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(red: 0.04, green: 0.036, blue: 0.04, alpha: 1)
        // asphalt is already dark (~0.22), so a timid mark is invisible
        mat.transparency = 0.7
        mat.writesToDepthBuffer = false
        mat.blendMode = .alpha
        let geo = SCNPlane(width: 1, height: 1)
        geo.materials = [mat]

        let n = quality.skidSegments * 2      // two rear wheels
        let container = SCNNode()
        for _ in 0..<n {
            let node = SCNNode(geometry: geo)
            node.castsShadow = false
            node.isHidden = true
            node.opacity = 0
            container.addChildNode(node)
            skidNodes.append(node)
        }
        skidAge = [Float](repeating: -1, count: n)
        parent.addChildNode(container)
    }

    // MARK: - critter models

    private func critterNode(_ kind: CritterKind) -> SCNNode {
        let grp = SCNNode()
        switch kind {
        case .coqui:
            let m = lambert(UIColor(red: 0.44, green: 0.72, blue: 0.30, alpha: 1))
            let body = SCNNode(geometry: SCNSphere(radius: 0.14))
            body.geometry!.materials = [m]
            body.scale = SCNVector3(1, 0.82, 1.15)
            body.position.y = 0.13
            grp.addChildNode(body)
            let eyeMat = constant(UIColor(white: 0.05, alpha: 1))
            for ex in [Float(-0.06), Float(0.06)] {
                let eye = SCNNode(geometry: SCNSphere(radius: 0.035))
                eye.geometry!.materials = [eyeMat]
                eye.position = SCNVector3(ex, 0.2, -0.1)
                grp.addChildNode(eye)
            }

        case .lagartijo:
            let m = lambert(UIColor(red: 0.42, green: 0.36, blue: 0.22, alpha: 1))
            let body = SCNNode(geometry: SCNBox(width: 0.14, height: 0.09, length: 0.4,
                                                chamferRadius: 0.03))
            body.geometry!.materials = [m]; body.position.y = 0.07
            grp.addChildNode(body)
            let head = SCNNode(geometry: SCNBox(width: 0.1, height: 0.08, length: 0.14,
                                                chamferRadius: 0.02))
            head.geometry!.materials = [m]; head.position = SCNVector3(0, 0.09, -0.26)
            grp.addChildNode(head)
            let tail = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.44))
            tail.geometry!.materials = [m]
            tail.eulerAngles.x = -.pi / 2
            tail.position = SCNVector3(0, 0.06, 0.42)
            grp.addChildNode(tail)

        case .hiker:
            // torso, head, pack, and two legs that swing
            let shirt = lambert(UIColor(red: 0.90, green: 0.42, blue: 0.28, alpha: 1))
            let torso = SCNNode(geometry: SCNBox(width: 0.34, height: 0.52, length: 0.22,
                                                 chamferRadius: 0.07))
            torso.geometry!.materials = [shirt]; torso.position.y = 1.06
            grp.addChildNode(torso)
            let head = SCNNode(geometry: SCNSphere(radius: 0.15))
            head.geometry!.materials = [lambert(UIColor(red: 0.72, green: 0.53, blue: 0.38, alpha: 1))]
            head.position.y = 1.46
            grp.addChildNode(head)
            let pack = SCNNode(geometry: SCNBox(width: 0.28, height: 0.32, length: 0.16,
                                                chamferRadius: 0.05))
            pack.geometry!.materials = [lambert(UIColor(red: 0.24, green: 0.40, blue: 0.28, alpha: 1))]
            pack.position = SCNVector3(0, 1.10, 0.18)
            grp.addChildNode(pack)
            let legMat = lambert(UIColor(red: 0.20, green: 0.24, blue: 0.34, alpha: 1))
            for lx in [Float(-0.10), Float(0.10)] {
                let hip = SCNNode()
                hip.position = SCNVector3(lx, 0.78, 0)
                let leg = SCNNode(geometry: SCNBox(width: 0.13, height: 0.76, length: 0.14,
                                                   chamferRadius: 0.05))
                leg.geometry!.materials = [legMat]
                leg.position.y = -0.38
                hip.addChildNode(leg)
                grp.addChildNode(hip)
            }

        case .sanpedrito:
            // Puerto Rican tody: green back, red throat, stubby wings
            let green = lambert(UIColor(red: 0.30, green: 0.72, blue: 0.32, alpha: 1))
            let body = SCNNode(geometry: SCNSphere(radius: 0.12))
            body.geometry!.materials = [green]
            body.scale = SCNVector3(1, 0.9, 1.3)
            grp.addChildNode(body)
            let throat = SCNNode(geometry: SCNSphere(radius: 0.07))
            throat.geometry!.materials = [lambert(UIColor(red: 0.90, green: 0.16, blue: 0.18, alpha: 1))]
            throat.position = SCNVector3(0, -0.03, -0.10)
            grp.addChildNode(throat)
            let beak = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.16))
            beak.geometry!.materials = [constant(UIColor(white: 0.14, alpha: 1))]
            beak.eulerAngles.x = .pi / 2
            beak.position = SCNVector3(0, 0, -0.2)
            grp.addChildNode(beak)
            for wx in [Float(-1), Float(1)] {
                let pivot = SCNNode()
                pivot.position = SCNVector3(wx * 0.08, 0.03, 0)
                let wing = SCNNode(geometry: SCNBox(width: 0.22, height: 0.02, length: 0.12,
                                                    chamferRadius: 0.01))
                wing.geometry!.materials = [green]
                wing.position = SCNVector3(wx * 0.12, 0, 0)
                pivot.addChildNode(wing)
                grp.addChildNode(pivot)
            }

        case .gaviota:
            // white body, grey wings, yellow beak
            let white = lambert(UIColor(white: 0.95, alpha: 1))
            let body = SCNNode(geometry: SCNSphere(radius: 0.13))
            body.geometry!.materials = [white]
            body.scale = SCNVector3(1, 0.86, 1.5)
            grp.addChildNode(body)
            let head = SCNNode(geometry: SCNSphere(radius: 0.085))
            head.geometry!.materials = [white]
            head.position = SCNVector3(0, 0.06, -0.17)
            grp.addChildNode(head)
            let beak = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.028, height: 0.13))
            beak.geometry!.materials = [constant(UIColor(red: 0.98, green: 0.76, blue: 0.20, alpha: 1))]
            beak.eulerAngles.x = .pi / 2
            beak.position = SCNVector3(0, 0.05, -0.28)
            grp.addChildNode(beak)
            let wingMat = lambert(UIColor(white: 0.72, alpha: 1))
            for wx in [Float(-1), Float(1)] {
                let pivot = SCNNode()
                pivot.position = SCNVector3(wx * 0.09, 0.04, 0)
                let wing = SCNNode(geometry: SCNBox(width: 0.34, height: 0.02, length: 0.15,
                                                    chamferRadius: 0.01))
                wing.geometry!.materials = [wingMat]
                wing.position = SCNVector3(wx * 0.18, 0, 0)
                pivot.addChildNode(wing)
                grp.addChildNode(pivot)
            }

        case .juey:
            // land crab: wide flat shell, two claws, scuttles sideways
            let shellMat = lambert(UIColor(red: 0.42, green: 0.30, blue: 0.55, alpha: 1))
            let shell = SCNNode(geometry: SCNSphere(radius: 0.16))
            shell.geometry!.materials = [shellMat]
            shell.scale = SCNVector3(1.5, 0.55, 1.1)
            shell.position.y = 0.11
            grp.addChildNode(shell)
            for cx in [Float(-1), Float(1)] {
                let claw = SCNNode(geometry: SCNSphere(radius: 0.075))
                claw.geometry!.materials = [shellMat]
                claw.scale = SCNVector3(1.5, 0.8, 0.9)
                claw.position = SCNVector3(cx * 0.26, 0.10, -0.13)
                grp.addChildNode(claw)
            }
            let eyeMat = constant(UIColor(white: 0.06, alpha: 1))
            for ex in [Float(-0.055), Float(0.055)] {
                let eye = SCNNode(geometry: SCNSphere(radius: 0.028))
                eye.geometry!.materials = [eyeMat]
                eye.position = SCNVector3(ex, 0.20, -0.10)
                grp.addChildNode(eye)
            }

        case .boa:
            // a chain of segments; the update pass undulates them
            let m = lambert(UIColor(red: 0.34, green: 0.30, blue: 0.22, alpha: 1))
            let segGeo = SCNSphere(radius: 0.15)
            segGeo.materials = [m]
            for k in 0..<7 {
                let seg = SCNNode(geometry: segGeo)
                let t = Float(k) / 6
                let sc = 1 - t * 0.55
                seg.scale = SCNVector3(sc, sc * 0.75, sc)
                seg.position = SCNVector3(0, 0.12, Float(k) * 0.26)
                grp.addChildNode(seg)
            }
        }
        let sc = kind.displayScale
        grp.scale = SCNVector3(sc, sc, sc)
        return grp
    }

    private func makeCritters(_ parent: SCNNode) {
        for kind in Self.quarry(for: Self.currentStage) {
            for _ in 0..<kind.count {
                let n = critterNode(kind)
                parent.addChildNode(n)
                critters.append(Critter(kind: kind, node: n))
            }
        }
    }

    /// Scatters the quarry along the trail. Called per run from `layoutHazards`.
    private func layoutCritters() {
        guard !critters.isEmpty else { return }
        for i in 0..<critters.count {
            let kind = critters[i].kind
            let f = 0.05 + runRng.next() * 0.90
            critters[i].s = f * Self.total
            critters[i].dir = runRng.next() < 0.5 ? -1 : 1
            critters[i].alive = true
            critters[i].hitPlayer = false
            critters[i].phase = runRng.next() * 6.28
            critters[i].node.isHidden = false
            switch kind {
            case .coqui, .lagartijo:
                // small things sit at the trail's edge and dart across it
                critters[i].x = critters[i].dir * (Self.roadHalf - 0.4)
                critters[i].baseY = 0
            case .hiker:
                critters[i].x = (runRng.next() - 0.5) * (Self.roadHalf * 1.3)
                critters[i].baseY = 0
            case .boa:
                critters[i].x = critters[i].dir * (Self.roadHalf + 0.6)
                critters[i].baseY = 0
            case .sanpedrito, .gaviota:
                critters[i].x = (runRng.next() - 0.5) * (Self.roadHalf * 1.5)
                critters[i].baseY = 1.5 + runRng.next() * 0.9
            case .juey:
                critters[i].x = critters[i].dir * (Self.roadHalf - 0.6)
                critters[i].baseY = 0
            }
        }
    }

    private func updateCritters(_ dt: Float, _ tNow: Float) {
        guard !critters.isEmpty else { return }
        for i in 0..<critters.count {
            let ds = critters[i].s - s
            // cull far away: cheap, and there are ~70 of them
            if ds < -40 || ds > 420 {
                critters[i].node.isHidden = true
                continue
            }
            guard critters[i].alive else { continue }
            critters[i].node.isHidden = false
            critters[i].phase += dt

            let kind = critters[i].kind
            switch kind {
            case .coqui:
                // hops in place
                critters[i].baseY = abs(sin(critters[i].phase * 3.1)) * 0.22
            case .lagartijo:
                // darts across when you get close, like the iguanas
                if ds < 34 && ds > -2 {
                    critters[i].x += critters[i].dir * -9 * dt
                }
            case .hiker:
                // walking away from you up the trail
                critters[i].s += 1.9 * dt
            case .boa:
                if ds < 46 && ds > -4 {
                    critters[i].x += critters[i].dir * -1.9 * dt
                }
            case .juey:
                // scuttles sideways whenever you get close
                if ds < 30 && ds > -2 { critters[i].x += critters[i].dir * -5.5 * dt }
            case .sanpedrito, .gaviota:
                critters[i].x += critters[i].dir * 3.4 * dt
                critters[i].baseY += sin(critters[i].phase * 4.2) * 0.6 * dt
                if abs(critters[i].x) > Self.roadHalf * 1.6 { critters[i].dir *= -1 }
            }

            // place it on the trail
            let (cp, ct, cr) = sample(critters[i].s)
            let world = cp + cr * critters[i].x + simd_float3(0, critters[i].baseY, 0)
            let node = critters[i].node
            node.simdPosition = world
            switch kind {
            case .coqui:
                node.simdLook(at: world - ct, up: simd_float3(0, 1, 0),
                              localFront: simd_float3(0, 0, -1))
            case .hiker:
                node.simdLook(at: world + ct, up: simd_float3(0, 1, 0),
                              localFront: simd_float3(0, 0, -1))
                // swing the legs
                let swing = sin(critters[i].phase * 7) * 0.5
                if node.childNodes.count >= 5 {
                    node.childNodes[3].eulerAngles.x = swing
                    node.childNodes[4].eulerAngles.x = -swing
                }
            case .lagartijo, .boa, .juey:
                // facing the way it's crossing
                let target = world + cr * critters[i].dir * -1
                node.simdLook(at: target, up: simd_float3(0, 1, 0),
                              localFront: simd_float3(0, 0, -1))
                if kind == .boa {
                    for (k, seg) in node.childNodes.enumerated() {
                        seg.position.x = sin(critters[i].phase * 4 - Float(k) * 0.8) * 0.14
                    }
                }
            case .sanpedrito, .gaviota:
                node.simdLook(at: world + cr * critters[i].dir, up: simd_float3(0, 1, 0),
                              localFront: simd_float3(0, 0, -1))
                let flap = sin(critters[i].phase * 22) * 0.7
                for (k, w) in node.childNodes.enumerated() where k >= 3 {
                    w.eulerAngles.z = (k == 3 ? flap : -flap)
                }
            }

            // running into the bigger ones hurts
            if !critters[i].hitPlayer, kind.contactDamage > 0,
               abs(ds) < 1.8, abs(critters[i].x - x) < 0.9 + kind.displayScale * 0.34,
               !airborne {
                critters[i].hitPlayer = true
                shake = max(shake, 0.55)
                sound.playThunk()
                damage(kind.contactDamage, kind == .boa ? "¡LA BOA!" : "¡CUIDAO!", tone: .hit)
            }
        }
    }

    /// Zapped by the beam.
    private func killCritter(_ i: Int, at bs: Float, _ bx: Float) {
        let kind = critters[i].kind
        critters[i].alive = false
        critters[i].node.isHidden = true
        score += Float(kind.points)
        bumpCombo()
        popupAsync("\(kind.label) +\(kind.points)", .big)
        sound.playCoqui()
        let (cp, _, cr) = sample(bs)
        sparkNode.simdPosition = cp + cr * bx + simd_float3(0, 0.5, 0)
        sparkSystem.birthRate = 520
        sparkT = 0.1
    }

    // MARK: - beam

    /// Bolts and tar patches are both pooled and driven by transform only, like the
    /// skid trail — nothing is allocated once a race is running.
    private func beamPools(_ parent: SCNNode) {
        let boltMat = SCNMaterial()
        boltMat.lightingModel = .constant
        boltMat.diffuse.contents = UIColor(red: 0.60, green: 1, blue: 0.72, alpha: 1)
        boltMat.emission.contents = UIColor(red: 0.60, green: 1, blue: 0.72, alpha: 1)
        boltMat.emission.intensity = 2.0
        boltMat.blendMode = .add
        boltMat.writesToDepthBuffer = false
        let boltGeo = SCNSphere(radius: 0.17)
        boltGeo.materials = [boltMat]

        let container = SCNNode()
        for _ in 0..<10 {
            let n = SCNNode(geometry: boltGeo)
            n.scale = SCNVector3(1, 1, 4.5)      // stretched along travel
            n.castsShadow = false
            n.isHidden = true
            container.addChildNode(n)
            bolts.append(Bolt(node: n))
        }

        let patchMat = SCNMaterial()
        patchMat.lightingModel = .constant
        patchMat.diffuse.contents = Textures.patch()
        patchMat.writesToDepthBuffer = false
        let patchGeo = SCNPlane(width: 1, height: 1)
        patchGeo.materials = [patchMat]
        for _ in 0..<24 {
            let n = SCNNode(geometry: patchGeo)
            n.castsShadow = false
            n.isHidden = true
            container.addChildNode(n)
            patchNodes.append(n)
        }
        parent.addChildNode(container)
    }

    private func clearBeam() {
        for i in 0..<bolts.count {
            bolts[i].live = false
            bolts[i].node.isHidden = true
        }
        for n in patchNodes { n.isHidden = true }
        boltCursor = 0
        patchCursor = 0
        charge = 100
        fireCool = 0
    }

    private func fireBolt() {
        guard charge >= Self.shotCost, fireCool <= 0 else { return }
        charge -= Self.shotCost
        fireCool = 0.28
        sound.playZap()
        Haptics.shared.tap(intensity: 0.34, sharpness: 0.95)
        bolts[boltCursor].s = s + 3.5
        bolts[boltCursor].x = x
        // Fired from the craft, not the pavement: while floating that is 12 m up,
        // and the bolt slopes down to road height as it travels.
        bolts[boltCursor].y = jumpY + 0.75
        bolts[boltCursor].live = true
        bolts[boltCursor].node.isHidden = false
        boltCursor = (boltCursor + 1) % bolts.count
    }

    /// Lays a tar patch over a sealed hole. The pothole field is two merged
    /// meshes, so an individual hole can't be hidden — covering it is what makes
    /// the seal read.
    private func layPatch(over hole: Hole) {
        let (pos, tan, rgt) = sample(hole.s)
        let c = pos + rgt * hole.x
        let n = patchNodes[patchCursor]
        n.simdPosition = simd_float3(c.x, c.y + 0.055, c.z)
        let flat = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        let yaw = simd_quatf(angle: atan2(tan.x, -tan.z), axis: simd_float3(0, 1, 0))
        n.simdOrientation = simd_mul(yaw, flat)
        let d = hole.r * 2.9
        n.scale = SCNVector3(d, d, 1)
        n.isHidden = false
        patchCursor = (patchCursor + 1) % patchNodes.count
    }

    private func updateBolts(_ dt: Float) {
        for i in 0..<bolts.count where bolts[i].live {
            // Swept span for this frame. A point-in-window test missed constantly:
            // at 115 m/s with dt capped at 0.033 a bolt jumps 3.8 m, further than
            // any sane hit window, so it tunnelled straight through targets.
            let prevS = bolts[i].s
            bolts[i].s += Self.boltSpeed * dt
            let bs = bolts[i].s, bx = bolts[i].x
            let sweep = Sweep(from: prevS, to: bs, x: bx, pad: 1.4)

            if bs - s > 95 || bs > Self.total {
                bolts[i].live = false; bolts[i].node.isHidden = true; continue
            }

            var struck = false

            // Cruisers first: they are the thing actively hurting you, so a shot
            // that could hit either should always take the pursuer. The payout is
            // flat and does not build combo — shaking a tail is meant to be relief,
            // not the most profitable thing you can do with a beam charge.
            for pi in 0..<pursuers.count where pursuers[pi].live {
                let pc = pursuers[pi]
                if sweep.hits(s: pc.s, x: pc.x, tolerance: 2.6) {
                    pursuers[pi].live = false
                    pursuers[pi].node.isHidden = true
                    // Award computed before the bump and reused, or the popup reads
                    // the raised combo and advertises a tier more than it paid.
                    score += Float(Self.pursuerBounty)
                    sound.playThunk()
                    popupAsync("¡LA TUMBASTE! +\(Self.pursuerBounty)", .big)
                    Haptics.shared.crash(intensity: 0.7)
                    struck = true
                    break
                }
            }

            // traffic next — a car is the bigger target and the better payoff
            if !struck {
            for ti in 0..<traffic.count {
                let tc = traffic[ti]
                guard tc.s < Self.total, tc.s > s - 4 else { continue }
                if sweep.hits(s: tc.s, x: tc.x, tolerance: 2.6) {
                    traffic[ti].vx = (tc.x >= bx ? 1 : -1) * 13
                    traffic[ti].spin = 1.1
                    traffic[ti].v *= 0.62
                    traffic[ti].cool = 1.5
                    score += tc.isPolice ? 240 : 130
                    bumpCombo()
                    popupAsync(tc.isPolice ? "¡LA POLICÍA!" : "¡FUEGO!", .big)
                    sound.playThunk()
                    struck = true
                    break
                }
            }
            }

            // Yunque quarry
            if !struck {
                for ci in 0..<critters.count {
                    guard critters[ci].alive else { continue }
                    let cs = critters[ci].s
                    guard cs > s - 2 else { continue }
                    let tol = 1.1 + critters[ci].kind.displayScale * 0.38
                    if sweep.hits(s: cs, x: critters[ci].x, tolerance: tol) {
                        killCritter(ci, at: cs, bx)
                        struck = true
                        break
                    }
                }
            }

            // otherwise seal a pothole ahead
            if !struck {
                for hIdx in 0..<holes.count {
                    let h = holes[hIdx]
                    guard !h.zapped, !h.hit, h.s > s else { continue }
                    if sweep.hits(s: h.s, x: h.x, tolerance: h.r + 1.8) {
                        holes[hIdx].zapped = true
                        layPatch(over: h)
                        score += 70
                        popupAsync("\(Shout.one(Shout.sealed)) +70", .pickup)
                        struck = true
                        break
                    }
                }
            }

            if struck {
                let (hp2, _, hr2) = sample(bs)
                sparkNode.simdPosition = hp2 + hr2 * bx + simd_float3(0, 0.45, 0)
                sparkSystem.birthRate = 600
                sparkT = 0.09
                bolts[i].live = false
                bolts[i].node.isHidden = true
                continue
            }

            // place it
            // 3.2/s left a bolt fired from float altitude still ~5 m up at its
            // target; this reaches road level within about 15 m of travel
            bolts[i].y += (0.75 - bolts[i].y) * min(1, 9.0 * dt)
            let (bp, bt, br) = sample(bs)
            let world = bp + br * bx + simd_float3(0, bolts[i].y, 0)
            bolts[i].node.simdPosition = world
            bolts[i].node.simdLook(at: world + bt, up: simd_float3(0, 1, 0),
                                   localFront: simd_float3(0, 0, -1))
        }
    }

    private func clearSkids() {
        for i in 0..<skidNodes.count {
            skidNodes[i].isHidden = true
            skidAge[i] = -1
        }
        skidCursor = 0
        lastSkidL = nil
        lastSkidR = nil
    }

    private func emitSkidSegment(from a: simd_float3, to b: simd_float3, tan: simd_float3) {
        let d = b - a
        // Orient along the road, not along the raw contact-patch delta. While
        // drifting that delta is dominated by *lateral* travel, which turned the
        // trail into diagonal slashes; the lateral offset between consecutive
        // segments is what should show the trail curving.
        let forward = abs(simd_dot(d, tan))
        let len = max(forward, 0.35) * 1.18
        guard len < 40 else { return }
        let node = skidNodes[skidCursor]
        let mid = (a + b) * 0.5
        node.simdPosition = simd_float3(mid.x, mid.y + 0.025, mid.z)
        // Compose explicitly: pitch the quad flat in its own space, *then* yaw it
        // about world Y. Setting eulerAngles composes in an order that leaves the
        // quad skewed rather than lying flat and aligned.
        let flat = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        let yaw = simd_quatf(angle: atan2(tan.x, -tan.z), axis: simd_float3(0, 1, 0))
        node.simdOrientation = simd_mul(yaw, flat)
        node.scale = SCNVector3(0.28, len, 1)
        node.isHidden = false
        node.opacity = 1
        skidAge[skidCursor] = 0
        skidCursor = (skidCursor + 1) % skidNodes.count
    }

    private func updateSkids(_ dt: Float) {
        for i in 0..<skidAge.count where skidAge[i] >= 0 {
            skidAge[i] += dt
            let a = skidAge[i]
            if a >= skidLife {
                skidAge[i] = -1
                skidNodes[i].isHidden = true
            } else if a > skidLife * 0.55 {
                let f = 1 - (a - skidLife * 0.55) / (skidLife * 0.45)
                skidNodes[i].opacity = CGFloat(max(0, f))
            }
        }
    }

    // MARK: - the car

    /// Builds a saucer hull. Shared by the player craft and the intro cutscene, so
    /// the thing escaping Area 51 is visibly the thing you then drive.
    /// Returns the rotating light ring so the caller can spin it.
    private func ufoHull(scale: Float = 1) -> (node: SCNNode, lightRing: SCNNode) {
        let craft = SCNNode()

        let hullMat = SCNMaterial()
        hullMat.lightingModel = .physicallyBased
        // brushed rather than mirror — at 0.92 metalness the hull reflected so much
        // of the sunset cubemap that the saucer read pink instead of metallic
        hullMat.diffuse.contents = UIColor(white: 0.80, alpha: 1)
        hullMat.metalness.contents = 0.58
        hullMat.roughness.contents = 0.34

        // Fresnel rim light. The craft sits centre-frame against the road for the
        // whole run and had no edge definition at all — a brushed grey hull over
        // grey asphalt, separated only by the underglow beneath it. This adds a
        // teal edge that falls off toward the middle of the hull, so the silhouette
        // reads at any speed and against any of the three surfaces.
        //
        // `_surface.view` and `_surface.normal` are both in view space here, so the
        // dot product is the facing ratio directly, no extra transform needed.
        let rimLight = """
            float facing = saturate(dot(normalize(_surface.normal),
                                        normalize(_surface.view)));
            // Tighter falloff and about half the gain of the first attempt: the hull
            // is already a bright PBR surface, so 1.15 pushed it to blown-out white
            // and lost the brushed metal underneath.
            float rim = pow(1.0 - facing, 4.2);
            _output.color.rgb += float3(0.08, 0.72, 0.62) * rim * 0.62;
            """
        hullMat.shaderModifiers = [.fragment: rimLight]

        let underMat = SCNMaterial()
        underMat.lightingModel = .physicallyBased
        underMat.diffuse.contents = UIColor(white: 0.26, alpha: 1)
        underMat.metalness.contents = 0.85
        underMat.roughness.contents = 0.38
        underMat.shaderModifiers = [.fragment: rimLight]

        // upper and lower shells, squashed spheres
        let top = SCNNode(geometry: SCNSphere(radius: 1.25))
        top.geometry!.materials = [hullMat]
        top.scale = SCNVector3(1, 0.30, 1)
        top.position.y = 0.66
        craft.addChildNode(top)

        let under = SCNNode(geometry: SCNSphere(radius: 1.20))
        under.geometry!.materials = [underMat]
        under.scale = SCNVector3(1, 0.22, 1)
        under.position.y = 0.54
        craft.addChildNode(under)

        // rim
        let rim = SCNNode(geometry: SCNTorus(ringRadius: 1.34, pipeRadius: 0.14))
        rim.geometry!.materials = [hullMat]
        rim.position.y = 0.62
        craft.addChildNode(rim)

        // cockpit dome
        let domeMat = SCNMaterial()
        domeMat.lightingModel = .physicallyBased
        domeMat.diffuse.contents = UIColor(red: 0.22, green: 0.92, blue: 0.80, alpha: 1)
        domeMat.metalness.contents = 0.30
        domeMat.roughness.contents = 0.05
        domeMat.emission.contents = UIColor(red: 0.06, green: 0.42, blue: 0.38, alpha: 1)
        let dome = SCNNode(geometry: SCNSphere(radius: 0.56))
        dome.geometry!.materials = [domeMat]
        dome.scale = SCNVector3(1, 0.9, 1)
        dome.position.y = 0.90
        craft.addChildNode(dome)

        // rotating ring of lights — one shared emissive material so it can flatten
        let lightRing = SCNNode()
        let lampMat = constant(UIColor(red: 1, green: 0.86, blue: 0.42, alpha: 1))
        lampMat.emission.contents = UIColor(red: 1, green: 0.80, blue: 0.30, alpha: 1)
        lampMat.emission.intensity = 1.5
        let lampGeo = SCNSphere(radius: 0.11)
        lampGeo.materials = [lampMat]
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * .pi
            let lamp = SCNNode(geometry: lampGeo)
            lamp.position = SCNVector3(cos(a) * 1.18, 0.5, sin(a) * 1.18)
            lightRing.addChildNode(lamp)
        }
        craft.addChildNode(lightRing)

        craft.scale = SCNVector3(scale, scale, scale)
        return (craft, lightRing)
    }

    // MARK: - Area 51 intro cutscene

    private struct IntroKey { var t: Float; var p: simd_float3 }

    /// Parked well clear of the course and outside the ocean plane's footprint, so
    /// the set can never be seen from the road and vice versa.
    private static let introOrigin = simd_float3(6000, 0, 6000)
    private static let introLoop: Float = 11.5

    /// The arrival, in world space. It comes down out of the cloud deck far out to
    /// sea, sheds altitude across the bay, skims the water, crosses the beach and
    /// rises over the city — where the title finds it.
    private static let ufoPath: [IntroKey] = [
        IntroKey(t: 0.0,  p: simd_float3(-520, 430, 1500)),   // above the deck, inbound
        IntroKey(t: 2.6,  p: simd_float3(-370, 268, 1080)),   // punches cloud
        IntroKey(t: 5.4,  p: simd_float3(-190,  96,  640)),   // bay opens up below
        IntroKey(t: 7.6,  p: simd_float3( -80,  22,  330)),   // levels off at sea level
        IntroKey(t: 9.6,  p: simd_float3( -22,  14,  120)),   // skims in toward the sand
        IntroKey(t: 11.2, p: simd_float3(  26,  30,   34)),   // crosses the surf
        IntroKey(t: 12.4, p: simd_float3(  52,  44,   12))    // settles into title framing
    ]

    /// One camera setup per beat. Cutting between framings is both more filmic than
    /// a single continuous move and far easier to compose blind — each shot only has
    /// to work for its own two seconds.
    private struct Shot {
        let t0: Float, t1: Float
        let from: simd_float3, to: simd_float3          // camera travel
        let lookFrom: simd_float3, lookTo: simd_float3  // aim travel
        let fov: CGFloat
        /// Track the craft instead of the fixed aim, 0…1.
        let follow: Float
    }
    private static let shots: [Shot] = [
        // 1. wide on the cloud deck. The craft is a speck against sky, then isn't.
        Shot(t0: 0.0, t1: 3.4,
             from: simd_float3(-190, 396, 830), to: simd_float3(-140, 366, 760),
             lookFrom: simd_float3(-430, 300, 1180), lookTo: simd_float3(-380, 270, 1080),
             fov: 46, follow: 0.78),
        // 2. behind and above, as the bay and the skyline resolve underneath
        Shot(t0: 3.4, t1: 7.0,
             from: simd_float3(-330, 214, 900), to: simd_float3(-186, 118, 560),
             lookFrom: simd_float3(-120, 40, 120), lookTo: simd_float3(-60, 24, -60),
             fov: 58, follow: 0.5),
        // 3. low on the water as it comes past, city lights behind it
        Shot(t0: 7.0, t1: 9.9,
             from: simd_float3(-168, 30, 236), to: simd_float3(-74, 22, 136),
             lookFrom: simd_float3(-60, 18, 60), lookTo: simd_float3(-30, 14, -40),
             fov: 64, follow: 0.82),
        // 4. from the shallows, crossing the surf and rising into the title frame
        Shot(t0: 9.9, t1: 12.4,
             from: simd_float3(54, 26, 120), to: introCam,
             lookFrom: simd_float3(-6, 20, 20), lookTo: introBaseLook,
             fov: 60, follow: 0.55)
    ]

    /// Where the title screen sits once the arrival is over: over the sand looking
    /// back at the skyline, with the craft hovering off to the right of the type.
    private static let introCam = simd_float3(30, 40, 78)
    private static let introBaseLook = simd_float3(-40, 40, -180)

    // ---- one-shot cutscene ----
    private static let cutsceneDur: Float = 12.4
    /// One constant for the sea's normal tiling. It was set in two places with two
    /// different values and the per-frame drift silently won.
    private static let seaTile: Float = 300
    private static let touchSea: Float = 7.6     // levels off just above the water

    private static func samplePath(_ keys: [IntroKey], _ t: Float) -> simd_float3 {
        if t <= keys[0].t { return keys[0].p }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            if t <= b.t {
                let u = simd_clamp((t - a.t) / (b.t - a.t), 0, 1)
                let e = u * u * (3 - 2 * u)           // ease in/out
                return simd_mix(a.p, b.p, simd_float3(repeating: e))
            }
        }
        return keys[keys.count - 1].p
    }

    /// The night coastline the craft arrives over. Replaces the Area 51 desert:
    /// a grey hangar in flat sand had nothing to do with a game whose whole
    /// identity is Puerto Rico, and a dark sea under a moon gives the lighting
    /// something to do. Doubles as the title backdrop.
    private func buildIntroSet(_ parent: SCNNode) {
        let set = SCNNode()
        set.simdPosition = Self.introOrigin

        // ---- sea ----
        // PBR and nearly smooth so it mirrors the moon and the craft's own glow;
        // the normal map is the only thing giving it surface.
        let seaMat = SCNMaterial()
        seaMat.lightingModel = .physicallyBased
        seaMat.diffuse.contents = UIColor(red: 0.004, green: 0.011, blue: 0.026, alpha: 1)
        seaMat.metalness.contents = 0.0
        seaMat.roughness.contents = 0.30
        seaMat.normal.contents = Textures.waterNormal()
        seaMat.normal.wrapS = .repeat
        seaMat.normal.wrapT = .repeat
        seaMat.normal.contentsTransform = SCNMatrix4MakeScale(Self.seaTile, Self.seaTile, 1)
        seaMat.normal.intensity = 1.6
        let sea = SCNNode(geometry: SCNPlane(width: 5200, height: 5200))
        sea.geometry!.materials = [seaMat]
        sea.eulerAngles.x = -.pi / 2
        sea.castsShadow = false
        set.addChildNode(sea)
        introSea = sea

        // ---- the island: a dark landmass across the far side of the water ----
        let landMat = lambert(UIColor(red: 0.020, green: 0.026, blue: 0.030, alpha: 1))
        let land = SCNNode(geometry: SCNBox(width: 3000, height: 10, length: 1000,
                                            chamferRadius: 0))
        land.geometry!.materials = [landMat]
        land.simdPosition = simd_float3(0, -3, -640)   // top sits at y = 2
        set.addChildNode(land)

        // beach: a pale strip where the land meets the water
        let sandMat = SCNMaterial()
        sandMat.lightingModel = .lambert
        sandMat.diffuse.contents = Textures.wetSand()
        sandMat.diffuse.wrapS = .repeat
        sandMat.diffuse.wrapT = .repeat
        sandMat.diffuse.contentsTransform = SCNMatrix4MakeScale(60, 6, 1)
        sandMat.multiply.contents = UIColor(red: 0.10, green: 0.105, blue: 0.125, alpha: 1)
        let beach = SCNNode(geometry: SCNPlane(width: 2600, height: 130))
        beach.geometry!.materials = [sandMat]
        beach.eulerAngles.x = -.pi / 2
        beach.simdPosition = simd_float3(0, 1.6, -118)
        beach.castsShadow = false
        set.addChildNode(beach)

        // surf line — additive foam where the water meets the sand
        let foamMat = SCNMaterial()
        foamMat.lightingModel = .constant
        foamMat.diffuse.contents = Textures.softCircle()
        foamMat.multiply.contents = UIColor(red: 0.55, green: 0.72, blue: 0.80, alpha: 1)
        foamMat.blendMode = .add
        foamMat.writesToDepthBuffer = false
        let foam = SCNNode(geometry: SCNPlane(width: 2600, height: 46))
        foam.geometry!.materials = [foamMat]
        foam.eulerAngles.x = -.pi / 2
        foam.simdPosition = simd_float3(0, 1.9, -52)
        foam.castsShadow = false
        set.addChildNode(foam)
        introFoam = foam

        // ---- the city: blocks with lit windows, thickening toward the middle ----
        let blockMat = lambert(UIColor(red: 0.055, green: 0.060, blue: 0.080, alpha: 1))
        var cityRng = Lcg(90210)
        for i in 0..<150 {
            let bx: Float = (cityRng.next() - 0.5) * 2100
            let bz: Float = -230 - cityRng.next() * 560
            // taller toward the centre of frame, so the skyline has a shape
            let central: Float = 1 - min(abs(bx) / 1050, 1)
            let h: Float = 16 + cityRng.next() * (26 + central * 92)
            let w: Float = 14 + cityRng.next() * 22
            let b = SCNNode(geometry: SCNBox(width: CGFloat(w), height: CGFloat(h),
                                             length: CGFloat(w * 0.8), chamferRadius: 0))
            b.geometry!.materials = [blockMat]
            b.simdPosition = simd_float3(bx, 2 + h / 2, bz)
            set.addChildNode(b)

            // window light: one emissive face rather than per-window geometry —
            // 150 buildings of real windows would cost more than the whole race.
            let lit = SCNMaterial()
            lit.lightingModel = .constant
            let warm: Float = cityRng.next()
            let wg: CGFloat = CGFloat(0.66 + warm * 0.20)
            let wb: CGFloat = CGFloat(0.30 + warm * 0.30)
            lit.diffuse.contents = UIColor(red: 0.95, green: wg, blue: wb, alpha: 1)
            lit.transparency = CGFloat(0.30 + cityRng.next() * 0.45)
            lit.blendMode = .add
            lit.writesToDepthBuffer = false
            let face = SCNNode(geometry: SCNPlane(width: CGFloat(w * 0.82),
                                                  height: CGFloat(h * 0.74)))
            face.geometry!.materials = [lit]
            face.simdPosition = simd_float3(bx, 2 + h / 2, bz + w * 0.41)
            face.castsShadow = false
            set.addChildNode(face)
            if i % 9 == 0 {
                // a red aircraft beacon on the tall ones
                let bc = SCNNode(geometry: SCNSphere(radius: 1.5))
                let bm = constant(UIColor(red: 1, green: 0.16, blue: 0.13, alpha: 1))
                bm.emission.contents = UIColor(red: 1, green: 0.16, blue: 0.13, alpha: 1)
                bm.emission.intensity = 2.4
                bc.geometry!.materials = [bm]
                bc.simdPosition = simd_float3(bx, 2 + h + 2, bz)
                set.addChildNode(bc)
                cityBeacons.append(bc)
            }
        }

        // ---- El Morro: headland, fort, and the lighthouse that sweeps ----
        let head = SCNNode(geometry: SCNBox(width: 300, height: 54, length: 210,
                                            chamferRadius: 8))
        head.geometry!.materials = [lambert(UIColor(red: 0.055, green: 0.062, blue: 0.058, alpha: 1))]
        head.simdPosition = simd_float3(-560, 8, -170)
        set.addChildNode(head)
        // the fort's stepped bastion, lit warm from below like the real thing
        let fortMat = lambert(UIColor(red: 0.16, green: 0.145, blue: 0.115, alpha: 1))
        // Written out rather than driven from a tuple array: a heterogeneous tuple
        // literal here sent the type checker into an effectively infinite solve.
        let tiers: [SIMD4<Float>] = [
            SIMD4(-560, 40, -170, 160),
            SIMD4(-560, 54, -182, 112),
            SIMD4(-560, 66, -192, 72)
        ]
        let tierH: [CGFloat] = [16, 13, 11]
        for (k, spec) in tiers.enumerated() {
            let side = CGFloat(spec.w)
            let tier = SCNNode(geometry: SCNBox(width: side, height: tierH[k],
                                                length: side * 0.62, chamferRadius: 1))
            tier.geometry!.materials = [fortMat]
            tier.simdPosition = simd_float3(spec.x, spec.y, spec.z)
            set.addChildNode(tier)
        }
        // garita — the sentry box that is the island's whole visual shorthand
        let garita = SCNNode(geometry: SCNCylinder(radius: 7, height: 17))
        garita.geometry!.materials = [fortMat]
        garita.simdPosition = simd_float3(-644, 50, -150)
        set.addChildNode(garita)
        let dome = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 8.4, height: 11))
        dome.geometry!.materials = [fortMat]
        dome.simdPosition = simd_float3(-644, 64, -150)
        set.addChildNode(dome)

        let lampMat = constant(UIColor(red: 1, green: 0.93, blue: 0.74, alpha: 1))
        lampMat.emission.contents = UIColor(red: 1, green: 0.93, blue: 0.74, alpha: 1)
        lampMat.emission.intensity = 2.2
        let lamp = SCNNode(geometry: SCNSphere(radius: 3.2))
        lamp.geometry!.materials = [lampMat]
        lamp.simdPosition = simd_float3(-560, 80, -192)
        set.addChildNode(lamp)
        // Sweeping beam. A cone read as a solid white bar across the sky at any
        // opacity that made it visible at all, so this is a flat additive blade
        // that turns edge-on and effectively disappears half of every rotation.
        let sweepMat = SCNMaterial()
        sweepMat.lightingModel = .constant
        sweepMat.diffuse.contents = Textures.softCircle()
        sweepMat.multiply.contents = UIColor(red: 1, green: 0.95, blue: 0.80, alpha: 1)
        sweepMat.transparency = 0.16
        sweepMat.blendMode = .add
        sweepMat.writesToDepthBuffer = false
        sweepMat.isDoubleSided = true
        let sweepPivot = SCNNode()
        sweepPivot.simdPosition = simd_float3(-560, 80, -192)
        let beamLen: Float = 560
        let sweep = SCNNode(geometry: SCNPlane(width: 26, height: CGFloat(beamLen)))
        sweep.geometry!.materials = [sweepMat]
        sweep.eulerAngles.x = .pi / 2
        sweep.simdPosition = simd_float3(0, 0, -beamLen / 2)
        sweep.castsShadow = false
        sweepPivot.addChildNode(sweep)
        set.addChildNode(sweepPivot)
        lighthouse = sweepPivot

        // ---- cloud deck the craft punches through on the way in ----
        let cloudMat = SCNMaterial()
        cloudMat.lightingModel = .constant
        cloudMat.diffuse.contents = Textures.softCircle()
        cloudMat.multiply.contents = UIColor(red: 0.30, green: 0.34, blue: 0.50, alpha: 1)
        cloudMat.blendMode = .add
        cloudMat.writesToDepthBuffer = false
        var cloudRng = Lcg(4242)
        for _ in 0..<26 {
            let cw: CGFloat = CGFloat(260 + cloudRng.next() * 420)
            let ch: CGFloat = CGFloat(200 + cloudRng.next() * 300)
            let c = SCNNode(geometry: SCNPlane(width: cw, height: ch))
            c.geometry!.materials = [cloudMat]
            c.eulerAngles.x = -.pi / 2
            let cx: Float = (cloudRng.next() - 0.5) * 1700
            let cy: Float = 250 + cloudRng.next() * 90
            let cz: Float = 500 + cloudRng.next() * 1100
            c.simdPosition = simd_float3(cx, cy, cz)
            c.castsShadow = false
            set.addChildNode(c)
        }

        let moon = SCNLight()
        moon.type = .directional
        moon.color = UIColor(red: 0.62, green: 0.72, blue: 0.98, alpha: 1)
        moon.intensity = 300
        moon.castsShadow = false
        let moonNode = SCNNode()
        moonNode.light = moon
        introMoon = moon
        // aimed along the moon direction baked into the night cubemap
        moonNode.simdLook(at: simd_float3(0.45, -0.30, 0.84), up: simd_float3(0, 1, 0),
                          localFront: simd_float3(0, 0, -1))
        set.addChildNode(moonNode)

        // the craft itself — same hull the player flies
        let built = ufoHull(scale: 4.2)
        introUfoRing = built.lightRing
        introUfo.addChildNode(built.node)
        set.addChildNode(introUfo)

        // Its own light, so it actually illuminates the water it skims. The set is
        // otherwise lit only by emissive materials.
        let glow = SCNLight()
        glow.type = .omni
        glow.color = UIColor(red: 0.45, green: 1.0, blue: 0.85, alpha: 1)
        glow.intensity = 2600
        glow.attenuationEndDistance = 260
        let glowNode = SCNNode()
        glowNode.light = glow
        introUfo.addChildNode(glowNode)

        introSet = set
        parent.addChildNode(set)
    }

    // MARK: - arrival (pre-race)

    private static let arrivalDur: Float = 3.7

    /// The saucer drops out of the sky onto the start of the mountain road, and the
    /// camera settles from a wide reveal into the chase rig the countdown uses — so
    /// the hand-off into the countdown is seamless.
    private func updateArrival(_ dt: Float) {
        arrivalT += dt
        let p = simd_clamp(arrivalT / Self.arrivalDur, 0, 1)
        let (pos, tan, _) = sample(s)

        // descend fast, then ease into the road
        let fall = 1 - p
        let altitude = 62 * fall * fall * fall
        let carPos = pos + simd_float3(0, 0.02 + altitude, 0)
        playerNode.simdPosition = carPos
        playerNode.simdLook(at: carPos + tan, up: simd_float3(0, 1, 0),
                            localFront: simd_float3(0, 0, -1))
        // spin down out of a hard rotation as it settles
        chassisNode.eulerAngles = SCNVector3(0, fall * fall * 16, 0)
        chassisNode.position.y = 0
        ufoLightRing.eulerAngles.y += dt * (2 + fall * 22)
        for f in flameNodes { f.isHidden = p > 0.92 }

        blobNode.simdPosition = simd_float3(pos.x, pos.y + 0.03, pos.z)
        blobNode.eulerAngles = SCNVector3(-.pi / 2, atan2(tan.x, -tan.z), 0)
        let shadowScale = 1 / (1 + altitude * 0.42)
        blobNode.scale = SCNVector3(shadowScale, shadowScale, 1)
        blobNode.opacity = CGFloat(simd_clamp(1 - altitude * 0.02, 0.25, 1))

        // camera: wide and high, easing to exactly where the countdown wants it
        let ease = p * p * (3 - 2 * p)
        let wide = pos - tan * 30 + simd_float3(0, 30, 0)
        let tight = pos - tan * 7 + simd_float3(0, 2.6, 0)
        cameraNode.simdPosition = simd_mix(wide, tight, simd_float3(repeating: ease))
        let lookAtCraft = carPos
        let lookAhead = pos + tan * 8
        cameraNode.simdLook(at: simd_mix(lookAtCraft, lookAhead,
                                        simd_float3(repeating: simd_smoothstep(0.55, 1.0, p))),
                            up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        cameraNode.camera?.fieldOfView = CGFloat(66 - 4 * ease)

        // touchdown
        if arrivalT >= Self.arrivalDur {
            sound.playThunk()
            Haptics.shared.crash(intensity: 0.7)
            shake = 0.9
            dustNode.simdPosition = pos + simd_float3(0, 0.3, 0)
            dustSystem.birthRate = 420
            dustT = 0.28
            phase = .countdown
            DispatchQueue.main.async { self.state.phase = .countdown }
        }
    }

    /// Drives the looping escape. Called from the `.intro` branch of the frame.
    /// The arrival. Four shots with hard cuts between them, over the night coastline.
    private func updateCutscene(_ dt: Float) {
        cutsceneT += dt
        let t = cutsceneT
        let ufoLocal = Self.samplePath(Self.ufoPath, t)
        introUfo.simdPosition = ufoLocal

        // Bank into the direction of travel. The descent is steep, so pitch has to
        // read as well as roll or it looks like it is sliding down an invisible ramp.
        let ahead = Self.samplePath(Self.ufoPath, min(Self.cutsceneDur, t + 0.16))
        let vel = ahead - ufoLocal
        let sp = simd_length(vel)
        if sp > 0.001 {
            let dir = vel / sp
            introUfo.eulerAngles = SCNVector3(-dir.y * 0.85, atan2(dir.x, -dir.z), -dir.x * 0.55)
        }
        // spins up as it descends, eases once it is level over the water
        let descend = Self.smoothStep(0, Self.touchSea, t)
        introUfoRing.eulerAngles.y += dt * (2 + 7 * descend)

        nightAtmosphere()
        placeCutsceneCamera(t, ufoLocal: ufoLocal)
        animateCoast(t)

        // Entry burn while it is still shedding altitude; nothing once it levels off.
        if t < Self.touchSea {
            dustNode.simdPosition = Self.introOrigin + ufoLocal
            dustSystem.birthRate = 140
        } else {
            dustSystem.birthRate = 0
        }

        if t >= Self.cutsceneDur || state.skipCutscene { endCutscene() }
    }

    /// Night air over the water. Reaches much further than any race fog: the
    /// opening shot is 1.5 km out, and haze at race distances turned the sea into a
    /// flat sheet of whatever colour the last stage happened to leave behind.
    private func nightAtmosphere() {
        scene.fogColor = UIColor(red: 0.020, green: 0.032, blue: 0.070, alpha: 1)
        scene.fogStartDistance = 900
        scene.fogEndDistance = 4600
        scene.fogDensityExponent = 1.5
    }

    /// Ambient life in the set, shared by the cutscene and the title backdrop so the
    /// coast does not freeze the moment the arrival ends.
    private func animateCoast(_ t: Float) {
        lighthouse?.eulerAngles.y = t * 0.55
        // beacons blink out of phase — a whole skyline flashing in unison reads fake
        for (i, b) in cityBeacons.enumerated() {
            let on = sin(t * 2.1 + Float(i) * 1.7) > 0.55
            b.geometry?.firstMaterial?.emission.intensity = on ? 2.6 : 0.15
        }
        introFoam?.opacity = CGFloat(0.55 + 0.25 * sin(t * 0.9))
        // the sea drifts, so the moon smear is never perfectly still
        if let n = introSea?.geometry?.firstMaterial?.normal {
            let f = (t * 0.006).truncatingRemainder(dividingBy: 1)
            n.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeTranslation(f, f * 0.4, 0),
                                                 SCNMatrix4MakeScale(Self.seaTile,
                                                                     Self.seaTile, 1))
        }
    }

    /// Shared by the first frame and every later one: `attach` parks the camera at
    /// the world origin, 6 km from the set, so anything that starts the cutscene
    /// must place it in the same step or the opening frame renders black.
    private func placeCutsceneCamera(_ t: Float, ufoLocal: simd_float3) {
        let o = Self.introOrigin
        // Reduce Motion holds the final, closest setup for the whole run instead of
        // cutting between four of them and diving 430 m. The arrival still plays —
        // the craft still flies its path — but the camera stops moving under it.
        if state.reduceMotion {
            let shot = Self.shots[Self.shots.count - 1]
            cameraNode.simdPosition = o + shot.to
            let look = simd_mix(shot.lookTo, ufoLocal, simd_float3(repeating: 0.85))
            cameraNode.simdLook(at: o + look, up: simd_float3(0, 1, 0),
                                localFront: simd_float3(0, 0, -1))
            cameraNode.camera?.fieldOfView = shot.fov
            return
        }
        let shot = Self.shots.last { t >= $0.t0 } ?? Self.shots[0]
        let u = simd_clamp((t - shot.t0) / (shot.t1 - shot.t0), 0, 1)
        let e = u * u * (3 - 2 * u)                     // ease within the shot
        cameraNode.simdPosition = o + simd_mix(shot.from, shot.to, simd_float3(repeating: e))
        let staged = simd_mix(shot.lookFrom, shot.lookTo, simd_float3(repeating: e))
        // Each shot blends its composed aim with the craft's real position, so the
        // framing stays deliberate but the subject never drifts out of it.
        let look = simd_mix(staged, ufoLocal, simd_float3(repeating: shot.follow))
        cameraNode.simdLook(at: o + look, up: simd_float3(0, 1, 0),
                            localFront: simd_float3(0, 0, -1))
        cameraNode.camera?.fieldOfView = shot.fov
    }

    /// Arms the arrival from the top. Safe to call from the title at any time.
    func startCutscene() {
        cutsceneT = 0
        // Marked on entry, not on completion: force-quitting partway through used to
        // leave the flag unset, so the cutscene replayed on every launch forever.
        DispatchQueue.main.async { self.state.markIntroSeen() }
        introSet.isHidden = false
        introMoon?.intensity = 300
        if let sky = introSky {
            scene.background.contents = sky
            scene.lightingEnvironment.contents = sky
        }
        introUfo.simdPosition = Self.samplePath(Self.ufoPath, 0)
        placeCutsceneCamera(0, ufoLocal: Self.samplePath(Self.ufoPath, 0))
        phase = .cutscene
        DispatchQueue.main.async {
            self.state.skipCutscene = false
            self.state.phase = .cutscene
        }
    }

    private func endCutscene() {
        cutsceneT = 0
        introT = 0
        dustSystem.birthRate = 0
        phase = .intro
        DispatchQueue.main.async {
            self.state.skipCutscene = false
            self.state.markIntroSeen()
            self.state.phase = .intro
        }
    }

    private func updateIntro(_ dt: Float) {
        introT += dt

        nightAtmosphere()

        // The craft holds station off to the right of the type, breathing rather
        // than flying. The old backdrop replayed the escape on an 11.5 s loop, which
        // hard-cut the craft from high-right back down to the hangar every time.
        let hoverBase = Self.samplePath(Self.ufoPath, Self.cutsceneDur)
        let bob = simd_float3(sin(introT * 0.37) * 2.4,
                              sin(introT * 0.53) * 1.5,
                              sin(introT * 0.29) * 1.8)
        introUfo.simdPosition = hoverBase + bob
        introUfo.eulerAngles = SCNVector3(sin(introT * 0.45) * 0.05,
                                          0.5 + sin(introT * 0.23) * 0.12,
                                          sin(introT * 0.31) * 0.06)
        introUfoRing.eulerAngles.y += dt * 2.2

        // slow drift, so the frame is alive without ever recomposing itself
        let drift = simd_float3(sin(introT * 0.19) * 3.2, sin(introT * 0.14) * 1.4, 0)
        cameraNode.simdPosition = Self.introOrigin + Self.introCam + drift
        cameraNode.simdLook(at: Self.introOrigin + Self.introBaseLook,
                            up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        cameraNode.camera?.fieldOfView = 60

        animateCoast(introT)
        dustSystem.birthRate = 0
    }


    /// Arms the ghost for a fresh run. Race mode only: endless wraps the course, so
    /// a trace indexed on distance would teleport at every lap line.
    private func loadGhost() {
        ghostRec.removeAll(keepingCapacity: true)
        ghostRec.reserveCapacity(1400)
        ghostPlay = []
        ghostGap = 0
        ghostNode.isHidden = true
        guard mode == .race, Self.startOffset <= 40,
              let data = UserDefaults.standard.data(forKey: Self.currentStage.ghostKey),
              let trace = GhostTrace.decode(data)
        else { return }
        ghostPlay = trace
    }

    /// One sample per `ghostStep`, indexed off race time rather than accumulated,
    /// so a dropped frame shifts nothing. Capped so a very long run cannot grow it
    /// without bound.
    private func recordGhost() {
        guard mode == .race, Self.startOffset <= 40, ghostRec.count < 3000 else { return }
        let want = Int(playTime / Self.ghostStep)
        while ghostRec.count <= want {
            ghostRec.append(SIMD3(s, x, jumpY))
        }
    }

    /// Places the ghost at where the record run was at this moment. Once its trace
    /// runs out it has finished the course, so it leaves rather than freezing.
    private func playGhost() {
        guard !ghostPlay.isEmpty else { ghostNode.isHidden = true; return }
        let t = playTime / Self.ghostStep
        let i = Int(t)
        guard i >= 0, i + 1 < ghostPlay.count else {
            ghostNode.isHidden = true
            return
        }
        let f = Float(t - Double(i))
        let a = ghostPlay[i], b = ghostPlay[i + 1]
        let g = a + (b - a) * f
        let (gp, gt, gr) = sample(g.x)
        ghostNode.isHidden = false
        ghostNode.simdPosition = gp + gr * g.y + simd_float3(0, g.z + 0.35, 0)
        ghostNode.simdLook(at: gp + gr * g.y + gt + simd_float3(0, g.z + 0.35, 0),
                           up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        ghostGap = s - g.x
        // Neck and neck it sits exactly on top of your craft and hides it, which is
        // precisely when you least want the view blocked. Fade it out up close.
        ghostNode.opacity = CGFloat(simd_clamp((abs(ghostGap) - 2.5) / 9, 0, 1))
    }

    /// The ghost is the same hull as the player's, flattened to a flat teal shell so
    /// it reads as a trace rather than a second craft you might mistake for traffic.
    /// It never collides — nothing looks at this node but the renderer.
    private func buildGhost(_ parent: SCNNode) {
        let built = ufoHull()
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(red: 0.35, green: 1, blue: 0.86, alpha: 1)
        mat.transparency = 0.28
        mat.writesToDepthBuffer = false
        mat.isDoubleSided = true
        built.node.enumerateHierarchy { n, _ in
            n.geometry?.materials = [mat]
            n.castsShadow = false
        }
        ghostNode.addChildNode(built.node)
        ghostNode.isHidden = true
        // draw after the world so it reads as an overlay through scenery
        ghostNode.renderingOrder = 10
        parent.addChildNode(ghostNode)
    }

    private func buildCar() {
        let built = ufoHull()
        chassisNode.addChildNode(built.node)
        ufoLightRing = built.lightRing

        // A soft pool of light on the asphalt ahead, in place of headlights.
        // On playerNode rather than the chassis so it stays flat on the road while
        // the hull banks and pitches.
        let poolMat = SCNMaterial()
        poolMat.lightingModel = .constant
        poolMat.diffuse.contents = Textures.softCircle()
        poolMat.multiply.contents = UIColor(red: 0.62, green: 1, blue: 0.86, alpha: 1)
        poolMat.blendMode = .add
        poolMat.writesToDepthBuffer = false
        poolMat.transparency = 0.22
        let pool = SCNNode(geometry: SCNPlane(width: 7, height: 16))
        pool.geometry!.materials = [poolMat]
        pool.eulerAngles.x = -.pi / 2
        pool.position = SCNVector3(0, 0.045, -9.5)
        pool.castsShadow = false
        playerNode.addChildNode(pool)

        // rear brake glow — a strip on the trailing rim
        brakeLightMaterial = constant(UIColor(red: 0.33, green: 0.04, blue: 0.04, alpha: 1))
        let brakeBar = SCNNode(geometry: SCNBox(width: 1.3, height: 0.1, length: 0.1, chamferRadius: 0.04))
        brakeBar.geometry!.materials = [brakeLightMaterial]
        brakeBar.position = SCNVector3(0, 0.58, 1.24)
        chassisNode.addChildNode(brakeBar)

        // three downward-angled thrusters for nitro
        for xo in [Float(-0.62), Float(0), Float(0.62)] {
            let fm = SCNMaterial()
            fm.lightingModel = .constant
            fm.diffuse.contents = UIColor(red: 0.45, green: 1, blue: 0.82, alpha: 1)
            fm.emission.contents = UIColor(red: 0.45, green: 1, blue: 0.82, alpha: 1)
            fm.emission.intensity = 1.7
            fm.blendMode = .add
            fm.writesToDepthBuffer = false
            let flame = SCNNode(geometry: SCNCone(topRadius: 0.09, bottomRadius: 0, height: 1.1))
            flame.geometry!.materials = [fm]
            flame.eulerAngles.x = -1.15          // back and down
            flame.position = SCNVector3(xo, 0.34, 1.05)
            flame.isHidden = true
            flame.castsShadow = false
            chassisNode.addChildNode(flame)
            flameNodes.append(flame)
        }

        // hover field on the road beneath the craft
        glowMaterial = SCNMaterial()
        glowMaterial.lightingModel = .constant
        glowMaterial.diffuse.contents = Textures.softCircle()
        glowMaterial.multiply.contents = UIColor(red: 0.24, green: 0.96, blue: 0.72, alpha: 1)
        glowMaterial.blendMode = .add
        glowMaterial.writesToDepthBuffer = false
        glowMaterial.transparency = Self.hoverFieldOpacity
        let glow = SCNNode(geometry: SCNPlane(width: 4.2, height: 4.2))
        glow.geometry!.materials = [glowMaterial]
        glow.eulerAngles.x = -.pi / 2
        glow.position.y = 0.06
        glow.castsShadow = false
        chassisNode.addChildNode(glow)

        let blobMat = constant(UIColor.black)
        blobMat.diffuse.contents = Textures.blobShadow()
        blobMat.transparency = 1
        blobMat.writesToDepthBuffer = false
        blobNode.geometry = SCNPlane(width: 3.6, height: 3.6)   // round, like the craft
        blobNode.geometry!.materials = [blobMat]
        blobNode.eulerAngles.x = -.pi / 2
        blobNode.castsShadow = false
    }

    private func particles() {
        let puffImg = Textures.softCircle()

        smokeSystem.particleImage = puffImg
        smokeSystem.birthRate = 0
        smokeSystem.particleLifeSpan = 0.7
        smokeSystem.particleSize = 0.7
        smokeSystem.particleSizeVariation = 0.3
        smokeSystem.particleVelocity = 2.5
        smokeSystem.particleVelocityVariation = 1.5
        smokeSystem.spreadingAngle = 60
        smokeSystem.emittingDirection = SCNVector3(0, 1, 1)
        smokeSystem.particleColor = UIColor(white: 0.85, alpha: 0.6)
        smokeSystem.blendMode = .alpha
        let smokeNode = SCNNode()
        smokeNode.position = SCNVector3(0, 0.2, 1.9)
        smokeNode.addParticleSystem(smokeSystem)
        chassisNode.addChildNode(smokeNode)

        dustSystem.particleImage = puffImg
        dustSystem.birthRate = 0
        dustSystem.particleLifeSpan = 0.6
        dustSystem.particleSize = 0.6
        dustSystem.particleVelocity = 4
        dustSystem.particleVelocityVariation = 3
        dustSystem.spreadingAngle = 180
        dustSystem.particleColor = UIColor(red: 0.54, green: 0.48, blue: 0.36, alpha: 0.7)
        dustNode.addParticleSystem(dustSystem)

        // guardrail sparks
        sparkSystem.particleImage = puffImg
        sparkSystem.birthRate = 0
        sparkSystem.particleLifeSpan = 0.32
        sparkSystem.particleLifeSpanVariation = 0.2
        sparkSystem.particleSize = 0.075
        sparkSystem.particleVelocity = 9
        sparkSystem.particleVelocityVariation = 7
        sparkSystem.spreadingAngle = 65
        sparkSystem.emittingDirection = SCNVector3(0, 0.35, 1)
        sparkSystem.acceleration = SCNVector3(0, -14, 0)
        sparkSystem.particleColor = UIColor(red: 1, green: 0.78, blue: 0.32, alpha: 1)
        sparkSystem.particleColorVariation = SCNVector4(0.04, 0.2, 0.2, 0)
        sparkSystem.blendMode = .additive
        sparkNode.addParticleSystem(sparkSystem)

        streakSystem.particleImage = puffImg
        streakSystem.birthRate = 0
        streakSystem.particleLifeSpan = 1.2
        streakSystem.particleSize = 0.07
        streakSystem.particleVelocity = 0
        streakSystem.emitterShape = SCNBox(width: 26, height: 7, length: 50, chamferRadius: 0)
        streakSystem.birthLocation = .volume
        streakSystem.particleColor = UIColor(red: 1, green: 0.95, blue: 0.87, alpha: 0.65)
        streakSystem.blendMode = .additive
        let streakNode = SCNNode()
        streakNode.position = SCNVector3(0, 2.5, -26)
        streakNode.addParticleSystem(streakSystem)
        playerNode.addChildNode(streakNode)
    }

    // MARK: - game flow

    private func resetGame() {
        // Start 40 m in, not 4. The chase camera sits ~6 m behind the car, so at
        // s = 4 it was positioned behind s = 0 — behind where the road and terrain
        // meshes begin — and looked off the back edge of the world straight at the
        // ocean plane a couple of hundred metres below.
        s = Self.startOffset; v = 8; x = 0; xd = 0
        hp = 100; nitro = 60
        score = 0; styleRun = 0; combo = 0; lastCombo = -1
        comboTimer = 0; driftTime = 0
        mode = state.mode
        lap = 1; lapFlash = 0; lapWrapPending = false
        topSpeed = 0; holesHit = 0; nearMisses = 0
        shake = 0; flashT = 0; jolt = 0; invuln = 0; dustT = 0
        jump.reset()
        chassisNode.opacity = 1
        driftYaw = 0; leanRoll = 0; pitchAng = 0
        loadGhost()
        clearPursuit()
        playTime = 0
        hudClock = 0
        coquiT = 2
        lastRegion = nil            // so the first region announces itself
        cd = 3.4; cdLabel = ""
        fov = Self.baseFov
        clearSkids()
        clearBeam()
        dustSystem.birthRate = 0
        sparkSystem.birthRate = 0
        // the base is 6 km away and fully fogged, but there's no reason to keep
        // paying for it once the race starts
        introSet.isHidden = true
        // Not just hidden: a directional light in a hidden subtree may still light
        // the scene, which would put a blue fill over the sunset course.
        introMoon?.intensity = 0
        if let rs = raceSky {
            scene.background.contents = rs
            scene.lightingEnvironment.contents = rs
        }
        applyStageFog()

        // A ghost is a rematch, so it has to be the same course. Once a stage has a
        // best time, its layout is the one that time was set on; without a ghost the
        // course is fresh every race. `PISTA #` on the end screen shows which.
        let d = UserDefaults.standard
        let savedSeed = UInt64(bitPattern: Int64(d.integer(forKey: Self.currentStage.ghostSeedKey)))
        let haveGhost = d.data(forKey: Self.currentStage.ghostKey) != nil
        if mode == .race, Self.startOffset <= 40, haveGhost, savedSeed != 0 {
            runSeed = savedSeed
        } else {
            runSeed = UInt64.random(in: 1..<2147483646)
        }
        runRng = Lcg(runSeed)
        layoutHazards()

        phase = .arrival
        arrivalT = 0
        let (pos, tan, _) = sample(s)
        camPos = pos - tan * 7 + simd_float3(0, 2.6, 0)
        camLook = pos + tan * 8
        cameraNode.simdPosition = camPos
        cameraNode.simdLook(at: camLook, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        playerNode.simdPosition = pos + simd_float3(0, 0.02, 0)
        playerNode.simdLook(at: pos + tan, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        let seed = runSeed
        let st = Self.currentStage
        DispatchQueue.main.async {
            self.sound.setStage(st)
            self.state.phase = .arrival
            self.state.paused = false
            self.state.combo = 0
            self.state.countLabel = ""
            self.state.regionLabel = ""
            self.state.regionBlurb = ""
            self.state.lapLabel = ""
            self.state.newRecordScore = false
            self.state.newRecordTime = false
            self.state.unlockedStage = nil
            self.state.statSeed = seed
            self.state.hud = HudSnapshot()
        }
    }

    /// Abandons the run and goes back to the title, putting the Area 51 loop and
    /// its dusk sky back the way `attach` left them.
    private func returnToTitle() {
        phase = .intro
        introT = 0
        lastRegion = nil
        introSet.isHidden = false
        introMoon?.intensity = 300
        if let sky = introSky {
            scene.background.contents = sky
            scene.lightingEnvironment.contents = sky
        }
        sound.engineLevel = 0; sound.windLevel = 0; sound.skidLevel = 0
        sound.nitroLevel = 0; sound.rumbleLevel = 0
        sound.forestLevel = 0; sound.surfLevel = 0
        streakSystem.birthRate = 0; smokeSystem.birthRate = 0
        sparkSystem.birthRate = 0; dustSystem.birthRate = 0
        clearSkids()
        clearBeam()
        DispatchQueue.main.async {
            self.state.phase = .intro
            self.state.paused = false
            self.state.countLabel = ""
            self.state.regionLabel = ""
            self.state.popupText = ""
            self.state.combo = 0
            self.state.unlockedStage = nil
            self.state.refreshRecordLine()
        }
    }

    /// Next lap of an endless run. Keeps score, combo and damage — the attrition is
    /// what eventually ends the run — but relays the whole hazard field harder.
    private func beginLap() {
        lap += 1
        s = Self.startOffset
        v = min(v, 34)                       // carry momentum, but not all of it
        jump.reset()
        x = 0; xd = 0
        // The wrap moves you back to the start, so a live cruiser's gap becomes
        // hugely negative and `gap > 150` can never retire it: it would sit out its
        // full life invisible at the far end while the HUD showed POLICÍA x1.
        clearPursuit()
        hp = min(100, hp + 12)               // surviving a lap is worth a little back
        invuln = 1.2                         // don't die to the first hole of a lap
        clearSkids()
        // Seed the region tracker to wherever the lap restarts rather than clearing
        // it. Clearing made the region re-announce on the same frame the lap banner
        // appeared, and the two drew on top of each other. The next region still
        // announces normally once you cross into it.
        lastRegion = Region.at(progress: Self.startOffset / Self.total)
        runSeed = UInt64.random(in: 1..<2147483646)
        runRng = Lcg(runSeed)
        layoutHazards()
        let n = lap
        DispatchQueue.main.async {
            self.state.showLap(n)
            self.state.statSeed = self.runSeed
        }
    }

    /// A hero shot of the craft while the results read out. Freezing the chase
    /// camera wherever the run happened to stop is the single biggest tell that a
    /// results screen is a UI panel rather than the end of a run.
    private func updateResultsCamera(_ dt: Float) {
        if !resultsArmed { armResults() }
        resultsT += dt
        let t = resultsT
        // eases in from wherever the chase camera was, so the cut is not a jump
        let settle: Float = Self.smoothStep(0, 1.6, t)
        let (cp, ctan, crgt) = sample(s)
        let focusY: Float = 1.5 + jumpY * 0.4
        let focus: simd_float3 = cp + crgt * x + simd_float3(0, focusY, 0)

        // slow orbit, drifting up and back — a finished run gets a rising crane,
        // a wreck gets a lower, tighter, slightly sunken angle
        let win: Bool = phase == .finished
        // A full revolution swung the camera straight into the hillside the road is
        // cut through, and out the far side of the finish banner. This sways within
        // a bounded arc behind the craft instead, which keeps the course in shot and
        // the camera out of the terrain.
        // Capped: the screen has no timeout, and an uncapped drift left the craft an
        // unreadable smudge for anyone who sat on their results.
        let drift: Double = state.reduceMotion ? 0 : min(Double(t), 12)
        let radius: Float = win ? Float(7.0 + drift * 0.10) : Float(6.4 + drift * 0.06)
        let height: Float = win ? Float(2.2 + drift * 0.10) : Float(1.6)
        // The results screen has no skip, so an unavoidable moving camera is worse
        // here than anywhere else in the game. Reduce Motion gets a near-still shot.
        let calm: Bool = state.reduceMotion
        let swayRate: Float = calm ? 0.06 : (win ? 0.24 : 0.18)
        let swayAmp: Float = calm ? 0.12 : 0.55
        let ang: Float = 3.35 + sinf(t * swayRate) * swayAmp
        let orbit = simd_float3(sinf(ang) * radius, height, cosf(ang) * radius)
        // orbit in the road's own frame, so the craft stays against the course
        let want: simd_float3 = focus + crgt * orbit.x
            + simd_float3(0, orbit.y, 0) + ctan * orbit.z

        let from: simd_float3 = cameraNode.simdPosition
        let k: Float = settle * 0.06 + 0.01
        cameraNode.simdPosition = simd_mix(from, want, simd_float3(repeating: k))
        // Aim left of the craft so the craft reads right of centre, clear of the
        // results text. Offsetting along the camera's own right vector keeps that
        // true at every point in the orbit, which a world-space nudge would not.
        let up = simd_float3(0, 1, 0)
        let fwd: simd_float3 = simd_normalize(focus - cameraNode.simdPosition)
        let camRight: simd_float3 = simd_normalize(simd_cross(fwd, up))
        cameraNode.simdLook(at: focus - camRight * 1.4, up: up,
                            localFront: simd_float3(0, 0, -1))
        let fovNow: CGFloat = Self.baseFov - 8 + CGFloat(settle) * 2
        cameraNode.camera?.fieldOfView = fovNow

        // the hull keeps turning over, so the shot is never actually still
        let spin: Float = state.reduceMotion ? 0 : (win ? 0.22 : 0.05)
        chassisNode.eulerAngles.y += dt * spin
        if win && !state.reduceMotion { ufoLightRing.eulerAngles.y += dt * 1.6 }
    }

    private func endGame(dead: Bool) {
        // Neither call site returns from the frame, so without this a fatal hit in
        // the last 8 m ran endGame(dead: true) and then endGame(dead: false) in the
        // same frame — awarding the finish bonus, the best time, the ghost trace and
        // the next stage unlock for a run that killed you. Two damage sources in one
        // frame could also double-fire and erase the record badge.
        guard phase == .playing else { return }
        phase = dead ? .dead : .finished
        resultsT = 0
        resultsArmed = false
        for f in flameNodes { f.isHidden = true }
        ghostNode.isHidden = true
        clearPursuit()
        let mm = Int(playTime) / 60
        let ss = playTime.truncatingRemainder(dividingBy: 60)
        let timeStr = String(format: "%d:%04.1f", mm, ss)
        // Finishing under par pays 90 a second. Only on a completed race — there is
        // no finish line in endless, and dying is not a fast time. Gated on
        // startOffset for the same reason the records are: dropping in at 3,300 m
        // with -startAt finishes in 9 s and would bank a 7,700-point "bonus".
        var bonus = 0
        if !dead && mode == .race && Self.startOffset <= 40 {
            bonus = max(0, Int((Self.currentStage.parTime - playTime) * 90))
            score += Float(bonus)
        }
        let sc = Int(score), top = Int(topSpeed * 3.6)
        let hh = holesHit, nm = nearMisses
        let medal = mode == .endless ? .none : Medal.forScore(sc, on: Self.currentStage)
        let defaults = UserDefaults.standard
        // A run that skipped part of the course isn't a record. Without this the
        // -startAt debug flag writes nonsense best times.
        let eligible = Self.startOffset <= 40
        let stage = Self.currentStage
        let endless = mode == .endless
        let scoreKey = endless ? stage.endlessScoreKey : stage.bestScoreKey
        let newScoreRec = eligible && sc > defaults.integer(forKey: scoreKey)
        if newScoreRec { defaults.set(sc, forKey: scoreKey) }
        if endless, lap > defaults.integer(forKey: stage.endlessLapKey) {
            defaults.set(lap, forKey: stage.endlessLapKey)
        }
        var newTimeRec = false
        if !dead && eligible && !endless {
            let bestTime = defaults.double(forKey: stage.bestTimeKey)
            if bestTime == 0 || playTime < bestTime {
                newTimeRec = true
                defaults.set((playTime * 10).rounded() / 10, forKey: stage.bestTimeKey)
                // The trace belongs to this run, so it is written with the time it
                // describes and never separately.
                defaults.set(GhostTrace.encode(ghostRec), forKey: stage.ghostKey)
                defaults.set(Int(Int64(bitPattern: runSeed)), forKey: stage.ghostSeedKey)
            }
        }
        // finishing a stage opens the next one
        var opened: Stage?
        if !dead, eligible, !endless, let nxt = stage.next, !nxt.unlocked {
            nxt.unlock()
            opened = nxt
        }
        DispatchQueue.main.async {
            self.state.statTime = timeStr
            self.state.statScore = sc
            self.state.statTopSpeed = top
            self.state.statHolesHit = hh
            self.state.statNearMisses = nm
            self.state.statMedal = medal
            self.state.statTimeBonus = bonus
            self.state.statFinished = !dead
            self.state.statLaps = self.lap
            self.state.newRecordScore = newScoreRec
            self.state.newRecordTime = newTimeRec
            self.state.unlockedStage = opened
            self.state.refreshRecordLine()
            self.state.phase = dead ? .dead : .finished
        }
        if !dead { sound.playCoqui() } else { sound.playThunk() }
    }

    /// Runs on the first `.finished`/`.dead` frame rather than inside `endGame`.
    /// endGame is called from the middle of a playing frame and that frame then runs
    /// to completion, so anything silenced there was immediately re-armed: the
    /// engine kept droning, wind streaks kept emitting, a dust plume from the fatal
    /// pothole sat where the results camera orbits, and the invulnerability blink
    /// re-froze the hull part-transparent for the whole hero shot.
    private func armResults() {
        resultsArmed = true
        chassisNode.opacity = 1
        sound.engineLevel = 0; sound.windLevel = 0; sound.skidLevel = 0
        sound.nitroLevel = 0; sound.rumbleLevel = 0
        sound.forestLevel = 0; sound.surfLevel = 0
        streakSystem.birthRate = 0
        smokeSystem.birthRate = 0
        sparkSystem.birthRate = 0
        dustSystem.birthRate = 0
        dustT = 0
        clearBeam()
    }

    /// Collision damage. `grace` hits are ignored while the post-hit invulnerable
    /// window is open — without it a pothole cluster chain-killed you in a
    /// single second, which is what made the old balance feel unfair.
    private func damage(_ amount: Float, _ msg: String?, tone: PopupTone = .hit,
                        grace: Bool = true) {
        if grace && invuln > 0 { return }
        if grace { invuln = 0.85 }
        hp -= amount
        flashT = 1
        combo = 0
        comboTimer = 0
        // Style points were banked the instant you stopped drifting and survived a
        // crash untouched, so a drift never cost anything. Now it's at risk until
        // you come out of it clean — and losing a big one is the headline, not the
        // name of whatever you hit.
        var headline = msg
        if styleRun > 40 {
            headline = "¡SE FUE! -\(Int(styleRun))"
        }
        styleRun = 0
        driftTime = 0
        if let msg = headline {
            Haptics.shared.crash(intensity: min(1, 0.45 + amount / 40))
            DispatchQueue.main.async {
                self.state.popup(msg, tone)
                self.state.combo = 0
            }
            lastCombo = 0
        }
        if hp <= 0 { hp = 0; endGame(dead: true) }
    }

    /// Shorter at higher combo: x1 gets ~4 s of slack, x5 gets ~2.6 s.
    private var comboWindow: Float { max(2.5, 4.4 - Float(combo) * 0.35) }

    private func bumpCombo() {
        combo = min(combo + 1, 5)
        comboTimer = comboWindow
    }

    private func popupAsync(_ msg: String, _ tone: PopupTone = .praise) {
        DispatchQueue.main.async { self.state.popup(msg, tone) }
    }

    /// Shouts, in Puerto Rican Spanish. Pools rather than single strings, so the
    /// game doesn't say the exact same thing every time something happens.
    private enum Shout {
        // "¡RAYOS!" was dubbed-cartoon Spanish, not anything anyone says here.
        // "cantazo" is the PR word for a hard knock, and "¡ño!" is the sound you
        // actually make when you hit one.
        static let pothole   = ["¡HOYO!", "¡ÑO!", "¡ESE HOYO!", "¡QUÉ CANTAZO!"]
        static let nearMiss  = ["¡CASI!", "¡POR POCO!", "¡QUÉ CHULO!", "¡CHÉVERE!",
                                "¡POR UN PELO!"]
        static let drift     = ["¡WEPA!", "¡ESO ES!", "¡BRUTAL!", "¡DIABLO!"]
        static let piragua   = ["¡PIRAGUA!", "¡FRÍO FRÍO!", "¡QUÉ RICO!"]
        static let mechanic  = ["¡MECÁNICO!", "¡ARREGLAO!", "¡COMO NUEVA!"]
        // "¡abre!" is what you actually shout at someone in your lane
        static let shove     = ["¡QUÍTATE!", "¡ABRE!", "¡MUÉVETE!"]
        static let overCar   = ["¡POR ENCIMA!", "¡VOLANDO BAJITO!"]
        static let sealed    = ["¡TAPADO!", "¡ARREGLAO!"]
        static let overHole  = ["¡VOLANDO!", "¡NI LO TOCÓ!"]
        static let rail      = ["¡AY BENDITO!", "¡CUIDAO!", "¡ACHO!"]
        static func one(_ pool: [String]) -> String { pool.randomElement() ?? pool[0] }
    }

    // MARK: - per-frame update

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard worldAttached else { return }
        if lastTime < 0 { lastTime = time }
        let dt = Float(min(time - lastTime, 0.033))
        lastTime = time

        if state.requestStart { state.requestStart = false; sound.start(); resetGame() }
        if state.requestReset { state.requestReset = false; resetGame() }
        if state.requestTitle { state.requestTitle = false; returnToTitle() }
        if state.requestCutscene {
            state.requestCutscene = false
            startCutscene()
        }

        updatePostFX()

        if let n = oceanNormal {
            let fx = Float(time * 0.015).truncatingRemainder(dividingBy: 1)
            let scaleM = SCNMatrix4MakeScale(60, 60, 1)
            n.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeTranslation(fx, fx * 0.6, 0), scaleM)
        }

        if state.paused && phase == .playing {
            sound.engineLevel = 0; sound.windLevel = 0
            sound.skidLevel = 0; sound.nitroLevel = 0; sound.rumbleLevel = 0
            return
        }

        switch phase {
        case .cutscene:
            updateCutscene(dt)
            return
        case .intro:
            updateIntro(dt)
            return
        case .arrival:
            updateArrival(dt)
            if dustT > 0 { dustT -= dt; if dustT <= 0 { dustSystem.birthRate = 0 } }
            return
        case .countdown:
            cd -= dt
            let lbl = cd > 2.4 ? "3" : cd > 1.4 ? "2" : cd > 0.4 ? "1" : "¡DALE!"
            if lbl != cdLabel {
                cdLabel = lbl
                sound.playBeep(final: lbl == "¡DALE!")
                Haptics.shared.tap(intensity: lbl == "¡DALE!" ? 0.9 : 0.5,
                                   sharpness: lbl == "¡DALE!" ? 0.9 : 0.5)
                DispatchQueue.main.async { self.state.countLabel = lbl }
            }
            if cd <= -0.4 {
                phase = .playing
                DispatchQueue.main.async {
                    self.state.countLabel = ""
                    self.state.phase = .playing
                }
            }
            return
        case .finished, .dead:
            updateSkids(dt)
            updateResultsCamera(dt)
            return
        case .playing:
            break
        }

        playTime += Double(dt)
        if invuln > 0 { invuln = max(0, invuln - dt) }

        // the multiplier bleeds away unless you keep threading hazards
        if combo > 0 {
            comboTimer -= dt
            if comboTimer <= 0 {
                combo -= 1
                comboTimer = combo > 0 ? comboWindow : 0
            }
        }
        if Self.showPause, playTime > 2.5, !state.paused {
            DispatchQueue.main.async { self.state.paused = true }
        }

        // ----- physics -----
        let i = Int(simd_clamp(s / Self.step, 0, Float(Self.count - 2)))
        let grade = grades[i]
        let curv = curvs[i]
        var steerIn = state.input.steer
        var brakeIn = state.input.brake
        var nitroIn = state.input.nitro
        if Self.autoplay {
            // Smoke-test driver, same idea as the web build's `?autoplay`. A PD
            // controller tracks a weaving lane target so it stays on the asphalt
            // instead of driving off the mountain, while still sweeping the full
            // analog steering range and brake-drifting periodically.
            // The lane controller stays in charge the whole time so the car never
            // drives off the mountain; brake pulses are what tip it into a drift
            // (brake + steer), which is what lays the skid marks.
            let t = Float(playTime)
            let laneTarget = sin(t * 0.7) * 2.4
            steerIn = simd_clamp((laneTarget - x) * 0.42 - xd * 0.14, -1, 1)
            // short pulses only: holding the brake bleeds speed below the drift
            // threshold and nothing ever slides
            // short pulses only: holding the brake bleeds speed below the drift
            // threshold and nothing ever slides
            brakeIn = t > 5 && t.truncatingRemainder(dividingBy: 6) < 2.0
            nitroIn = !brakeIn && t.truncatingRemainder(dividingBy: 6) > 3.5
        }
        let braking = brakeIn
        let wantNitro = nitroIn && nitro > 0
        let steer = simd_clamp(steerIn, -1, 1)
        let drifting = braking && abs(steer) > 0.28 && v > 12
        let offroad = abs(x) > Self.roadHalf + 0.3 && !airborne

        var acc: Float = 9.0 - grade * 9.81 * 4
        acc -= 0.0042 * v * v
        if wantNitro { acc += 14; nitro = max(0, nitro - 26 * dt) }
        else { nitro = min(100, nitro + 3.5 * dt) }
        if braking && !drifting { acc -= 15 }
        if drifting { acc -= 5 }
        if offroad { acc -= 9 }
        v = simd_clamp(v + acc * dt, 0, wantNitro ? 64 : 50)
        topSpeed = max(topSpeed, v)
        s += v * dt

        brakeLightMaterial.diffuse.contents = braking
            ? UIColor(red: 1, green: 0.13, blue: 0.13, alpha: 1)
            : UIColor(red: 0.33, green: 0.04, blue: 0.04, alpha: 1)
        brakeLightMaterial.emission.contents = UIColor(red: 1, green: 0.13, blue: 0.13, alpha: 1)
        brakeLightMaterial.emission.intensity = braking ? 1.6 : 0
        for f in flameNodes {
            let lit = wantNitro || floating
            f.isHidden = !lit
            // floating holds a steady thruster; nitro flickers
            if lit { f.scale = SCNVector3(1, wantNitro ? 0.7 + Float.random(in: 0...0.9) : 1.15, 1) }
        }

        // ----- beam -----
        if fireCool > 0 { fireCool = max(0, fireCool - dt) }
        charge = min(100, charge + 10 * dt)          // 2 shots, then ~4.6 s a shot
        if state.input.fireRequested {
            state.input.fireRequested = false
            fireBolt()
        }
        if Self.autoplay {
            // smoke-test driver shoots on a steady cadence
            let ft = Float(playTime)
            if ft > 4 && ft.truncatingRemainder(dividingBy: 1.6) < dt * 1.5 { fireBolt() }
        }
        updateBolts(dt)
        updatePursuit(dt)
        recordGhost()
        playGhost()

        // ----- jump -----
        // Timers first, request second, motion last — see JumpState.advanceTimers.
        jump.advanceTimers(dt: dt)
        if state.input.jumpRequested {
            state.input.jumpRequested = false
            switch jump.requestJump(speed: v, nitro: &nitro) {
            case .refused:
                break
            case .hop:
                sound.playJump()
                Haptics.shared.tap(intensity: 0.6, sharpness: 0.4)
            case .float:
                sound.playFloat()
                Haptics.shared.crash(intensity: 0.8)
                popupAsync("¡A VOLAR!", .big)
            case .floatDenied:
                popupAsync("SIN NITRO", .hit)
                sound.playJump()
                Haptics.shared.tap(intensity: 0.6, sharpness: 0.4)
            }
        }
        if Self.autoplay && !airborne && jumpCool <= 0 && v > 20 && !floating {
            // Bursts of three rather than a lone hop every few seconds: a single hop
            // can never chain, so the float would go untested headlessly.
            let t = Float(playTime)
            if t > 6 && t.truncatingRemainder(dividingBy: 9) < 3.2 {
                state.input.jumpRequested = true
            }
        }
        if let landing = jump.advanceMotion(dt: dt) {
            // a drop from float altitude hits far harder than a hop
            let impact = landing.impact
            shake = max(shake, 0.4 + impact * 0.75)
            sound.playThunk()
            Haptics.shared.crash(intensity: 0.4 + impact * 0.5)
            let (lp, _, lr) = sample(s)
            dustNode.simdPosition = lp + lr * x + simd_float3(0, 0.25, 0)
            dustSystem.birthRate = 220 + 420 * CGFloat(impact)
            dustT = 0.16 + 0.14 * impact
        }

        // steering authority drops off the ground — you commit to a line mid-air
        let airFactor: Float = floating ? 0.7 : (airborne ? 0.34 : 1)
        let targetXd = steer * simd_clamp(4 + v * 0.30, 0, 19) * (drifting ? 1.35 : 1) * airFactor
        let grip: Float = (drifting ? 3.2 : 6.5) * (floating ? 0.75 : (airborne ? 0.4 : 1))
        xd += (targetXd - xd) * min(1, grip * dt)
        xd += -curv * v * v * dt * (drifting ? 0.45 : 0.35)
        x += xd * dt
        x = simd_clamp(x, -Self.barrier, Self.barrier)

        smokeSystem.birthRate = drifting ? 90 : 0
        if drifting {
            // escalating rate: a long drift is worth far more than two short ones,
            // which is the whole reason not to bail early
            driftTime += dt
            styleRun += v * dt * (3 + min(driftTime, 6) * 1.1)
        } else if styleRun > 0 {
            driftTime = 0
            if styleRun > 50 { popupAsync("\(Shout.one(Shout.drift)) +\(Int(styleRun))", .big) }
            score += styleRun
            styleRun = 0
        }
        // Distance income used to be a flat `v * dt * 1.2`, which integrates to
        // 1.2 x distance — the same 4,320 on every course no matter how you drove.
        // Speed paid nothing on its own in a game about going downhill fast. Now
        // the rate per metre scales with speed, so a hard run banks roughly three
        // times what a crawl does over the same ground.
        let payNorm = simd_clamp((v - 22) / 30, 0, 1)
        score += v * dt * (0.55 + 1.45 * payNorm)

        // ----- skid trail -----
        let (skidPos, skidTan, skidRgt) = sample(s)
        let contactL = skidPos + skidRgt * (x - 0.85) - skidTan * 1.28
        let contactR = skidPos + skidRgt * (x + 0.85) - skidTan * 1.28
        if drifting && !offroad {
            skidTimer += dt
            if let l = lastSkidL, let r = lastSkidR, skidTimer >= Self.skidInterval {
                emitSkidSegment(from: l, to: contactL, tan: skidTan)
                emitSkidSegment(from: r, to: contactR, tan: skidTan)
                lastSkidL = contactL; lastSkidR = contactR
                skidTimer = 0
            } else if lastSkidL == nil {
                lastSkidL = contactL; lastSkidR = contactR
            }
        } else {
            lastSkidL = nil; lastSkidR = nil; skidTimer = 0
        }
        updateSkids(dt)
        updateCritters(dt, Float(time))

        // cliff / offroad
        // Guardrail. The old rule fired at |x| > 8.6 — 3.8 m past the visible
        // posts — then teleported you back to near the centre line, which read as
        // the game randomly yanking the car. Now you scrape along the rail where
        // you can see it, losing speed and (on the grace timer) some health.
        if abs(x) >= Self.barrier {
            let side: Float = x > 0 ? 1 : -1
            x = side * (Self.barrier - 0.04)
            // Bounce off it: reverse the lateral velocity with a floor, so even a
            // glancing scrape shoves the car back toward the asphalt instead of
            // letting you ride the rail.
            xd = -side * max(abs(xd) * 0.6, 4.5)
            // Above rail height the craft is over it, not scraping it. Containment
            // stays (the whole world is built around x), the punishment does not.
            if v > 6 && jumpY < 1.6 {
                v *= 0.78
                shake = max(shake, 0.9)
                sound.playThunk()
                let (rp, _, rr5) = sample(s)
                sparkNode.simdPosition = rp + rr5 * x + simd_float3(0, 0.5, 0)
                sparkSystem.birthRate = 900
                sparkT = 0.12
                damage(9, Shout.one(Shout.rail), tone: .hit)
            }
        } else if offroad && v > 8 {
            shake = max(shake, 0.25)
            // scrape damage bypasses the grace window: it's small and continuous,
            // and shouldn't be free just because you clipped a pothole a moment ago
            if Float.random(in: 0...1) < dt * 2.2 { damage(2, nil, grace: false) }
        }

        // potholes
        for hIdx in 0..<holes.count {
            let ds = holes[hIdx].s - s
            if ds < -6 || ds > 6 { continue }
            let h = holes[hIdx]
            if !h.hit && !h.zapped && abs(ds) < 1.8 && abs(h.x - x) < h.r + 0.75 {
                holes[hIdx].hit = true
                // flying over a hoyo is the whole point of being able to jump
                if airborne {
                    nearMisses += 1
                    bumpCombo()
                    score += Float(60 * combo)
                    popupAsync("\(Shout.one(Shout.overHole)) +\(60 * combo)", .big)
                } else if invuln <= 0 {
                    holesHit += 1
                    v *= 0.62
                    shake = 1.1; jolt = 1
                    sound.playThunk()
                    // was 9 + r*9 + v*0.18 ≈ 25–30 per hit on a 100 HP car
                    damage(5 + h.r * 5 + v * 0.10, Shout.one(Shout.pothole), tone: .hit)
                    let (pp, _, rr3) = sample(s)
                    dustNode.simdPosition = pp + rr3 * x + simd_float3(0, 0.3, 0)
                    dustSystem.birthRate = 350
                    dustT = 0.14
                }
            } else if !h.passed && !h.hit && ds < -2 {
                holes[hIdx].passed = true
                if abs(h.x - x) < h.r + 2.2 {
                    nearMisses += 1
                    bumpCombo()
                    score += Float(40 * combo)
                    if combo >= 2 { popupAsync("\(Shout.one(Shout.nearMiss)) x\(combo) +\(40 * combo)", .praise) }
                    else if nearMisses % 3 == 0 { popupAsync("\(Shout.one(Shout.nearMiss)) +40", .praise) }
                }
            }
        }

        // the dust puff used to be cancelled by a stale dispatched timer when two
        // holes landed close together; it's frame-driven now
        if dustT > 0 {
            dustT -= dt
            if dustT <= 0 { dustSystem.birthRate = 0 }
        }
        if sparkT > 0 {
            sparkT -= dt
            if sparkT <= 0 { sparkSystem.birthRate = 0 }
        }

        // toolboxes
        for tbi in 0..<toolboxes.count {
            let tb = toolboxes[tbi]
            if !tb.taken && abs(tb.s - s) < 2.4 && abs(tb.x - x) < 1.6 && jumpY < 2.5 {
                toolboxes[tbi].taken = true
                tb.node.isHidden = true
                hp = min(100, hp + 26)
                score += 50
                sound.playCoqui()
                Haptics.shared.tap(intensity: 0.5, sharpness: 0.35)
                popupAsync("\(Shout.one(Shout.mechanic)) +VIDA", .pickup)
            }
        }

        // piraguas
        for qi in 0..<piraguas.count {
            let q = piraguas[qi]
            if !q.taken && abs(q.s - s) < 2.4 && abs(q.x - x) < 1.6 && jumpY < 2.5 {
                piraguas[qi].taken = true
                q.node.isHidden = true
                nitro = min(100, nitro + 35)
                score += 100
                sound.playCoqui()
                Haptics.shared.tap(intensity: 0.4, sharpness: 0.7)
                popupAsync("\(Shout.one(Shout.piragua)) +NITRO", .pickup)
            }
        }

        // iguanas
        for gi in 0..<iguanas.count {
            let igDs = iguanas[gi].s - s
            if iguanas[gi].stateRaw == 0 && igDs > 0 && igDs < 40 + v * 2.2 { iguanas[gi].stateRaw = 1 }
            if iguanas[gi].stateRaw == 1 {
                iguanas[gi].x += iguanas[gi].dir * 7.5 * dt
                if abs(iguanas[gi].x) > Self.roadHalf + 1.5 && iguanas[gi].x * iguanas[gi].dir > 0 {
                    iguanas[gi].stateRaw = 2
                }
            }
            if !iguanas[gi].hit && iguanas[gi].stateRaw == 1 &&
               abs(igDs) < 2 && abs(iguanas[gi].x - x) < 1.2 && !airborne {
                iguanas[gi].hit = true
                iguanas[gi].stateRaw = 2
                iguanas[gi].node.eulerAngles.z = 2.6
                shake = max(shake, 0.6)
                sound.playThunk()
                damage(5, "¡LA IGUANA!", tone: .hit)
            }
            if iguanas[gi].stateRaw != 0 { positionIguana(&iguanas[gi]) }
        }

        // traffic
        for ti in 0..<traffic.count where Self.currentStage != .yunque {
            traffic[ti].cool = max(0, traffic[ti].cool - dt)
            traffic[ti].s += traffic[ti].v * dt
            // being shoved: slide sideways, yaw with it, then settle
            if abs(traffic[ti].vx) > 0.01 {
                traffic[ti].x += traffic[ti].vx * dt
                traffic[ti].spin += traffic[ti].vx * dt * 0.5
                traffic[ti].vx *= exp(-dt * 1.6)
                if abs(traffic[ti].x) > Self.barrier - 0.5 {
                    // shunted off the road entirely — recycle it
                    traffic[ti].s = Self.total * 3
                }
            } else if abs(traffic[ti].spin) > 0.001 {
                traffic[ti].spin *= exp(-dt * 2.2)
            }
            if traffic[ti].s > s + 600 || traffic[ti].s < s - 120 || traffic[ti].s > Self.total - 40 {
                // el tapón is a town problem: cars bunch up tight through the
                // pueblo and thin out on the mountain and the coastal run-in
                let w = Self.regionWeights(s / Self.total)
                let gap = (w.x * 300 + w.y * 130 + w.z * 260) * pow(0.88, min(Float(lap - 1), 6))
                traffic[ti].s = s + gap * (0.7 + runRng.next() * 0.9)
                traffic[ti].x = Self.laneCentres[Int(runRng.next() * 4) % 4]
                // and it crawls slower in town
                traffic[ti].v = (w.y > 0.5 ? 8 : 11) + runRng.next() * 7
                traffic[ti].missed = false; traffic[ti].cool = 0
                traffic[ti].vx = 0; traffic[ti].spin = 0
                traffic[ti].clearedByJump = false
                if traffic[ti].s > Self.total - 60 { traffic[ti].s = Self.total * 2 }
            }
            let tc = traffic[ti]
            let tDs = tc.s - s
            if tc.cool <= 0 && abs(tDs) < 3.2 && abs(tc.x - x) < 1.7 {
                let closing = v - tc.v
                if jumpY > 0.85 {
                    // sailed clean over the roof
                    if !tc.clearedByJump {
                        traffic[ti].clearedByJump = true
                        bumpCombo()
                        score += Float(150 * combo)
                        sound.playHorn()
                        popupAsync("\(Shout.one(Shout.overCar)) +\(150 * combo)", .big)
                    }
                } else if closing > 16 && !tc.clearedByJump {
                    // hit it hard enough to shove it out of the lane rather than
                    // bounce off it — the tapón is traffic, not a wall
                    traffic[ti].cool = 1.2
                    let side: Float = tc.x >= x ? 1 : -1
                    traffic[ti].vx = side * (5.5 + closing * 0.14)
                    traffic[ti].v *= 0.86
                    v *= 0.9
                    shake = max(shake, 0.85); jolt = 0.7
                    sound.playThunk(); sound.playHorn()
                    let (cp, _, cr) = sample(s)
                    sparkNode.simdPosition = cp + cr * x + simd_float3(0, 0.55, 0)
                    sparkSystem.birthRate = 700
                    sparkT = 0.1
                    score += tc.isPolice ? 250 : 120
                    damage(6, tc.isPolice ? "¡LA POLICÍA!" : Shout.one(Shout.shove), tone: .big)
                } else {
                    traffic[ti].cool = 2
                    v = min(v, tc.v * 0.8)
                    shake = 1.2; jolt = 1
                    sound.playThunk(); sound.playHorn()
                    damage(16, "¡EL TAPÓN!", tone: .hit)
                }
            } else if !tc.missed && tDs < -1 && tDs > -8 && abs(tc.x - x) < 3 &&
                      abs(tc.x - x) > 1.7 && v - tc.v > 12 {
                traffic[ti].missed = true
                bumpCombo()
                score += Float(80 * combo)
                sound.playHorn()
                popupAsync("¡FUA! +\(80 * combo)", .praise)
            }
            if tDs > -150 && tDs < 700 {
                tc.node.isHidden = false
                let (pp, tt, rr4) = sample(tc.s)
                tc.node.simdPosition = pp + rr4 * tc.x
                tc.node.simdLook(at: tc.node.simdPosition + tt,
                                 up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
                if abs(tc.spin) > 0.001 {
                    tc.node.simdOrientation = simd_mul(tc.node.simdOrientation,
                        simd_quatf(angle: tc.spin, axis: simd_float3(0, 1, 0)))
                }
            } else { tc.node.isHidden = true }
        }

        if s >= Self.total - 8 {
            if mode == .endless {
                if !lapWrapPending {
                    lapWrapPending = true
                    lapFlash = 1.45
                    sound.playCoqui()
                    Haptics.shared.tap(intensity: 0.7, sharpness: 0.5)
                }
                s = Self.total - 8          // hold at the line while the wash covers
            } else {
                endGame(dead: false)
            }
        }
        if lapFlash > 0 {
            lapFlash = max(0, lapFlash - dt * 2.1)
            // teleport only once the wash has actually been on screen a few frames
            if lapWrapPending && lapFlash <= 1.0 {
                lapWrapPending = false
                beginLap()
            }
        }

        // ----- place the car -----
        let (pos, tan, rgt) = sample(s)
        let groundPos = pos + rgt * x + simd_float3(0, 0.02, 0)
        let carPos = groundPos + simd_float3(0, jumpY, 0)
        playerNode.simdPosition = carPos
        playerNode.simdLook(at: carPos + tan, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))

        let tNow = Float(time)
        leanRoll += ((-steer * 0.09 - xd * 0.012) - leanRoll) * min(1, 8 * dt)
        driftYaw += ((-xd * 0.03 - (drifting ? steer * 0.5 : 0)) - driftYaw) * min(1, 6 * dt)
        // nose up as it leaves the ground, nose down on the way back in
        let airPitch: Float = airborne ? simd_clamp(-jumpVel * 0.030, -0.16, 0.16) : 0
        pitchAng += ((braking ? 0.05 : (wantNitro ? -0.035 : 0)) + airPitch - pitchAng)
                  * min(1, 6 * dt)
        if jolt > 0 { jolt = max(0, jolt - dt * 4) }
        chassisNode.eulerAngles = SCNVector3(pitchAng + jolt * 0.08 * sin(tNow * 60), driftYaw, leanRoll)
        // idle hover bob, plus the impact jolt
        chassisNode.position.y = sin(tNow * 2.3) * 0.055 - jolt * 0.12 * abs(sin(tNow * 42))
        // blink through the grace window so the player can read that it's active
        chassisNode.opacity = invuln > 0 ? CGFloat(0.45 + 0.55 * abs(sin(tNow * 22))) : 1

        // the ring spins faster the harder the craft is working
        wheelSpin += (1.4 + v * 0.09) * dt
        ufoLightRing.eulerAngles.y = wheelSpin

        // every cruiser's bar flashes off one shared pair of materials
        let flash = sin(tNow * 9) > 0
        policeRedMat.emission.intensity = flash ? 2.2 : 0.05
        policeBlueMat.emission.intensity = flash ? 0.05 : 2.2
        glowMaterial.transparency = Self.hoverFieldOpacity
            + CGFloat(Self.hoverFieldPulse * sin(tNow * 9))

        // shadow stays on the road and shrinks as the car climbs, which is what
        // actually communicates height
        blobNode.simdPosition = simd_float3(groundPos.x, pos.y + 0.03, groundPos.z)
        blobNode.eulerAngles = SCNVector3(-.pi / 2, atan2(tan.x, -tan.z), 0)
        let shadowScale = 1 / (1 + jumpY * 0.42)
        blobNode.scale = SCNVector3(shadowScale, shadowScale, 1)
        blobNode.opacity = CGFloat(simd_clamp(1 - jumpY * 0.22, 0.3, 1))

        // ----- camera -----
        // closer and tighter than the original 6.4–10 m / 72° rig, so the car is
        // a real presence on screen instead of a distant speck
        // Pull IN under boost rather than drifting out. Distance barely grows with
        // speed and nitro actively closes it, so the craft gets bigger when you're
        // going fastest — which is when you most want to see it.
        // Floating puts the craft 12 m up; the deck-level rig would leave it off the
        // bottom of the frame, so pull back and climb with it.
        let liftK = simd_clamp((jumpY - 3) / (Self.floatHeight - 3), 0, 1)
        let camDist = 4.3 + v * 0.018 - (wantNitro ? 0.85 : 0) + liftK * 7
        var target = carPos - tan * camDist
        target.y += 1.62 + v * 0.007 + liftK * 3.5
        target += rgt * (x * 0.1)
        let k = 1 - exp(-dt * 5.5)
        camPos = simd_mix(camPos, target, simd_float3(repeating: k))
        var lookTarget = carPos + tan * 12
        lookTarget.y += 1.15
        camLook = simd_mix(camLook, lookTarget, simd_float3(repeating: k))
        var finalCam = camPos
        // Reduce Motion: the shake and the high-speed rumble are the two things most
        // likely to make someone put the phone down. Damping is still tracked so the
        // gameplay timing is identical — only the camera displacement is dropped.
        let calm = state.reduceMotion
        let rumble: Float = (v > 40 && !calm) ? (v - 40) * 0.004 : 0
        if shake > 0.01 {
            if !calm {
                finalCam.x += Float.random(in: -0.5...0.5) * shake
                finalCam.y += Float.random(in: -0.45...0.45) * shake
            }
            shake *= exp(-dt * 4)
        }
        finalCam.x += Float.random(in: -1...1) * rumble
        finalCam.y += Float.random(in: -1...1) * rumble
        cameraNode.simdPosition = finalCam
        cameraNode.simdLook(at: camLook, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        if !calm {
            cameraNode.simdOrientation = simd_mul(cameraNode.simdOrientation,
                simd_quatf(angle: leanRoll * 0.45, axis: simd_float3(0, 0, 1)))
        }
        // Gentler again. The ramp reached 86° under boost, and a wide lens is what
        // was making the craft feel distant at speed — the sense of speed comes
        // from motion blur, wind streaks and camera rumble, not from lens width.
        let targetFov = Self.baseFov + CGFloat(v * 0.19) + (wantNitro ? 2 : 0)
        fov += (min(max(targetFov, Self.baseFov), 77) - fov) * CGFloat(min(1, 4.5 * dt))
        cameraNode.camera?.fieldOfView = calm ? Self.baseFov + (fov - Self.baseFov) * 0.35 : fov
        cameraNode.camera?.motionBlurIntensity = calm ? 0 : quality.motionBlur

        streakSystem.birthRate = v > 25 ? CGFloat((v - 25) * 4) * quality.streakScale : 0

        // Coquís calling in the background. On the island at dusk this is the
        // ambience, not a sound effect — sparse in town, constant in the forest.
        switch Self.currentStage {
        case .yunque:
            sound.forestLevel = 0.05
            sound.surfLevel = 0
        case .playa:
            sound.forestLevel = 0
            sound.surfLevel = 0.045
        case .cordillera:
            sound.forestLevel = 0
            sound.surfLevel = 0
        }

        // Coquís call in the forest and up on the mountain. The shore has surf and
        // gaviotas instead — a coquí on open sand at midday would be wrong.
        if Self.currentStage != .playa {
            coquiT -= dt
            if coquiT <= 0 {
                sound.playCoquiAmbient()
                let inTown = Self.currentStage == .cordillera
                    && Region.at(progress: s / Self.total) == .pueblo
                let base: Float = Self.currentStage == .yunque ? 1.4 : (inTown ? 5.0 : 2.4)
                coquiT = base + Float.random(in: 0...2.4)
            }
        }

        // ----- audio -----
        // Six gears instead of one long rising whine: pitch climbs through each
        // gear and drops on the shift, which is most of what sells acceleration.
        let gearSpan: Float = 64.0 / 6
        let gear = min(5, Int(v / gearSpan))
        let inGear = (v - Float(gear) * gearSpan) / gearSpan
        sound.engineFreq = Double(52 + inGear * 118 + Float(gear) * 9 + (wantNitro ? 26 : 0))
        // Halved — the saw pair sits right in the ear and read as a drone. Wind and
        // the gear steps carry the sense of speed; the motor just needs to be there.
        sound.engineLevel = Double(0.026 + simd_clamp(v / 64, 0, 1) * 0.042)
        sound.windLevel = Double(simd_clamp(v / 90, 0, 0.35))
        sound.skidLevel = drifting ? Double(simd_clamp(v / 140, 0, 0.22)) : 0
        sound.nitroLevel = wantNitro ? 0.035 : 0
        sound.rumbleLevel = offroad ? Double(simd_clamp(v / 55, 0, 0.32)) : 0

        // matching haptic while you're on the strips / dirt
        if offroad && v > 8 {
            rumbleHapticT -= dt
            if rumbleHapticT <= 0 {
                Haptics.shared.rumble(duration: 0.22, intensity: min(0.75, 0.3 + v / 90))
                rumbleHapticT = 0.2
            }
        } else {
            rumbleHapticT = 0
        }

        for q in piraguas where !q.taken {
            q.node.position.y = q.baseY + sin(tNow * 3 + q.s) * 0.16
            q.node.eulerAngles.y += 2.4 * dt
        }
        for tb in toolboxes where !tb.taken {
            tb.node.position.y = tb.baseY + sin(tNow * 3 + tb.s * 2) * 0.14
            tb.node.eulerAngles.y += 1.8 * dt
        }

        // ----- HUD -----
        if flashT > 0 { flashT -= dt * 2.2 }
        // One batched snapshot at ~30 Hz. The old code fired ten separate
        // @Published writes every frame — sixty dispatches and ~600 SwiftUI
        // invalidations a second for numbers that change by a pixel.
        if combo != lastCombo {
            let c = combo
            lastCombo = c
            DispatchQueue.main.async { self.state.combo = c }
        }
        // region crossing — the descent's three stretches. El Yunque is one biome,
        // so it just names itself on the first frame.
        if Self.currentStage != .cordillera {
            if lastRegion == nil {
                lastRegion = .cordillera
                sound.playCoqui()
                let st = Self.currentStage
                DispatchQueue.main.async {
                    self.state.regionLabel = st.name
                    self.state.regionBlurb = st.blurb
                    self.state.regionID += 1
                }
            }
        } else {
            let region = Region.at(progress: s / Self.total)
            if region != lastRegion {
                lastRegion = region
                sound.playCoqui()
                DispatchQueue.main.async { self.state.showRegion(region) }
            }
        }

        hudClock += dt
        if hudClock >= 1.0 / 30.0 {
            hudClock = 0
            // drift the haze toward the current region's colour (stage 1 only —
            // the rainforest keeps its own mist)
            if Self.currentStage == .cordillera {
            let rw = Self.regionWeights(s / Self.total)
            let fog = Self.regionFog[0] * rw.x + Self.regionFog[1] * rw.y + Self.regionFog[2] * rw.z
            scene.fogColor = UIColor(red: CGFloat(fog.x), green: CGFloat(fog.y),
                                     blue: CGFloat(fog.z), alpha: 1)
            }
            let mm = Int(playTime) / 60
            let ss = playTime.truncatingRemainder(dividingBy: 60)
            var snap = HudSnapshot()
            snap.speedKmh = Int(v * 3.6)
            snap.score = Int(score)
            snap.hp = Double(hp)
            snap.nitro = Double(nitro)
            snap.charge = Double(charge)
            snap.comboLeft = combo > 0 ? Double(simd_clamp(comboTimer / comboWindow, 0, 1)) : 0
            snap.pendingStyle = Int(styleRun)
            snap.heat = Double(heat / 100)
            snap.chased = pursuers.reduce(0) { $0 + ($1.live ? 1 : 0) }
            snap.ghostOn = !ghostNode.isHidden
            snap.ghostGap = Double(ghostGap)
            snap.lap = lap
            snap.lapFlash = Double(min(1, lapFlash)) * (state.reduceMotion ? 0.45 : 1)
            snap.floatLeft = Double(floatT / Self.floatDuration)
            snap.progress = Double(s / Self.total)
            snap.speedNorm = Double(simd_clamp((v - 20) / 30, 0, 1)) * (state.reduceMotion ? 0.4 : 1)
            snap.flash = Double(max(0, flashT)) * (state.reduceMotion ? 0.30 : 1)
            snap.nitroActive = wantNitro
            snap.invuln = invuln > 0
            snap.timeText = String(format: "%d:%04.1f", mm, ss)
            DispatchQueue.main.async { self.state.hud = snap }
        }

        // Last thing in the frame, so every camera path above has already run and
        // this simply wins. See `inspectTarget`.
        if let want = Self.inspectTarget { holdInspectCamera(want) }
    }

    /// Parks the camera on the first instance of a prop, for `-inspect`.
    ///
    /// Deliberately at the end of the frame rather than as an early return: the prop
    /// arrays are only populated and positioned once the world has built and a run
    /// has laid the hazards out, so the game has to be allowed to do all of that.
    /// Pair it with `-autoplay`; the craft drives off and the camera stays here.
    private func holdInspectCamera(_ want: String) {
        let target: SCNNode?
        switch want {
        case "piragua": target = piraguas.first(where: { !$0.node.isHidden })?.node
        case "toolbox": target = toolboxes.first(where: { !$0.node.isHidden })?.node
        case "traffic": target = traffic.first?.node
        case "iguana":  target = iguanas.first?.node
        default:        target = nil
        }
        guard let node = target else { return }
        let p = node.simdWorldPosition
        // Close and slightly above, off to one side so the silhouette reads against
        // the road rather than head-on. A 0.5 m prop needs a long lens this close or
        // perspective distortion does the describing instead of the geometry.
        cameraNode.simdPosition = p + simd_float3(1.25, 0.55, 1.85)
        cameraNode.simdLook(at: p, up: simd_float3(0, 1, 0),
                            localFront: simd_float3(0, 0, -1))
        cameraNode.camera?.fieldOfView = 46
        cameraNode.camera?.motionBlurIntensity = 0
    }
}

// MARK: - UIColor bridge for the shared palette

extension UIColor {
    static let neonPinkUI = UIColor(red: 1.0, green: 0.18, blue: 0.47, alpha: 1)
    static let neonTealUI = UIColor(red: 0.07, green: 0.84, blue: 0.76, alpha: 1)
    static let neonGoldUI = UIColor(red: 1.0, green: 0.82, blue: 0.25, alpha: 1)
    static let sunsetOrangeUI = UIColor(red: 1.0, green: 0.54, blue: 0.36, alpha: 1)
}
