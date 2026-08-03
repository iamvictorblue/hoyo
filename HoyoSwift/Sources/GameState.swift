import Foundation
import Combine
import UIKit

enum GamePhase {
    /// `cutscene` is the one-shot escape from the base, played on first launch and
    /// on demand after that. `intro` is the title screen, which uses the same set
    /// as a looping backdrop. `arrival` is the pre-race beat: the saucer drops out
    /// of the sky onto the road before the countdown starts.
    case cutscene, intro, arrival, countdown, playing, finished, dead
}

/// How a course is played.
enum GameMode: Int {
    case race = 0       // one run of the course, timed, with a finish line
    case endless = 1    // lap it until the craft gives out

    var name: String { self == .race ? "CARRERA" : "SIN FIN" }
    var blurb: String { self == .race ? "DE PUNTA A PUNTA" : "HASTA QUE AGUANTES" }
}

/// A playable course. Each one rebuilds the world: its own path shape, surface,
/// terrain palette, scenery, hazards and quarry.
enum Stage: Int, CaseIterable {
    case cordillera = 0     // the mountain road down to the coast
    case yunque = 1         // a hiking trail through the rainforest
    case playa = 2          // wet sand along the shoreline

    var name: String {
        switch self {
        case .cordillera: return "GUAJATACA"
        case .yunque:     return "EL YUNQUE"
        case .playa:      return "ISLA VERDE"
        }
    }

    var blurb: String {
        switch self {
        case .cordillera: return "BAJADA POR EL KARSO"
        case .yunque:     return "VEREDA EN EL BOSQUE"
        case .playa:      return "ORILLA Y ARENA MOJADA"
        }
    }

    /// The real road each course runs on. PR-143 is the Ruta Panorámica along the
    /// cordillera; PR-191 is the road into El Yunque. Used as the route shield.
    var route: String {
        switch self {
        // PR-113 runs the Guajataca coast through Quebradillas; PR-191 is the road
        // into El Yunque; PR-187 starts in Isla Verde and runs east through Piñones.
        case .cordillera: return "113"
        case .yunque:     return "191"
        case .playa:      return "187"
        }
    }

    /// End-screen line for finishing, and for dying.
    var finishLine: String {
        switch self {
        case .cordillera: return "BAJASTE HASTA LA COSTA"
        case .yunque:     return "CRUZASTE EL BOSQUE COMPLETO"
        case .playa:      return "CORRISTE LA ORILLA COMPLETA"
        }
    }
    var failLine: String {
        switch self {
        case .cordillera: return "LOS HOYOS GANARON ESTA VEZ"
        case .yunque:     return "LA VEREDA GANÓ ESTA VEZ"
        case .playa:      return "LA ARENA GANÓ ESTA VEZ"
        }
    }

    /// Stage 1 is always available; the rest are earned by finishing the previous.
    var unlocked: Bool {
        if self == .cordillera { return true }
        return UserDefaults.standard.bool(forKey: "hoyo_unlocked_\(rawValue)")
    }

    func unlock() {
        UserDefaults.standard.set(true, forKey: "hoyo_unlocked_\(rawValue)")
    }

    /// The stage finishing this one opens up, if any.
    var next: Stage? { Stage(rawValue: rawValue + 1) }

    /// Records are kept per stage, and separately per mode — an endless score
    /// isn't comparable to a single run of the course.
    var bestScoreKey: String { "hoyo_bestScore_\(rawValue)" }
    var bestTimeKey: String { "hoyo_bestTime_\(rawValue)" }
    /// Position trace of the fastest run, replayed as the ghost. Written only when
    /// bestTimeKey is, so the two never disagree about which run they describe.
    var ghostKey: String { "hoyo_ghost_\(rawValue)" }
    /// The course layout the ghost was set on. A ghost recorded against a different
    /// pothole field is worse than no ghost: its racing line swerves around holes
    /// that aren't there and drives straight through ones that are, so copying it —
    /// the only thing a ghost is for — puts you in a hole.
    var ghostSeedKey: String { "hoyo_ghostSeed_\(rawValue)" }
    var endlessScoreKey: String { "hoyo_endlessScore_\(rawValue)" }
    var endlessLapKey: String { "hoyo_endlessLaps_\(rawValue)" }

    /// Target time for the finish bonus, in seconds. Beat it and every second
    /// under pays; miss it and you simply get nothing, never a penalty. Set about
    /// 15 s above a strong run on each course so the bonus is earned, not given.
    var parTime: Double {
        switch self {
        case .cordillera: return 95
        case .yunque:     return 100   // the trail is the slowest of the three
        case .playa:      return 95
        }
    }

    /// Score needed for each medal, derived from a measured ceiling rather than a
    /// model of the courses. Two earlier attempts both reasoned from content counts
    /// and both got it wrong; this one is anchored on what a run can actually bank.
    ///
    /// Method: the autoplay bot was made invulnerable and driven to the finish on
    /// each course, giving the most a run can score with no crashes and no combo
    /// ever broken. Thresholds are a fixed fraction of that ceiling — gold 85%,
    /// silver 60%, bronze 35% — so all three move together if the economy changes
    /// again, and the numbers are reproducible rather than picked.
    ///
    ///                 ceiling   near-misses   bronze   silver    gold
    ///   Guajataca      31,440        36       11,000   19,000   26,500
    ///   El Yunque      22,456        55        8,000   13,500   19,000
    ///   Isla Verde     12,824        32        4,500    7,500   11,000
    ///
    /// What the previous numbers got wrong: Isla Verde's gold was 23,000 against a
    /// 12,824 ceiling, and its silver 15,500 — both unreachable at any skill level,
    /// so only bronze existed there. El Yunque's gold sat at 96% of its ceiling,
    /// which is a flawless run or nothing.
    ///
    /// The cause was a comment claiming Yunque and Isla Verde are "within 4% of
    /// each other on every income term". They are not: near-miss income is the
    /// largest skill term and it scales with how much of the road your line covers.
    /// The Yunque trail is 4.6 m half-width against Isla Verde's 7.6, and the
    /// measured near-miss counts are 55 against 32 for a near-identical number of
    /// holes. Wide sand spreads the holes out of your line.
    ///
    /// Distance income is worth less than it looks. `0.55 + 1.45 * payNorm` per
    /// metre only beats the old flat 1.2 above roughly 127 km/h average, and the
    /// measured runs averaged 132, so it contributes a few hundred points, not
    /// thousands. The inflation that made gold trivial was the pursuit bounty loop,
    /// not this.
    var medalThresholds: (bronze: Int, silver: Int, gold: Int) {
        switch self {
        case .cordillera: return (11_000, 19_000, 26_500)
        case .yunque:     return (8_000, 13_500, 19_000)
        case .playa:      return (4_500, 7_500, 11_000)
        }
    }
}

/// The three stretches of the descent. Each one drives its own terrain palette,
/// scenery, hazard mix and haze colour, so the course reads as a journey down the
/// island rather than one long road.
enum Region: Int, CaseIterable {
    case cordillera = 0, pueblo, costa

    /// Where the region begins and ends, as a fraction of the course.
    var span: (lo: Float, hi: Float) {
        switch self {
        case .cordillera: return (0.00, 0.34)
        case .pueblo:     return (0.34, 0.68)
        case .costa:      return (0.68, 1.00)
        }
    }

    var label: String {
        switch self {
        case .cordillera: return "EL KARSO"
        case .pueblo:     return "EL PUEBLO"
        case .costa:      return "LA COSTA"
        }
    }

    var blurb: String {
        switch self {
        case .cordillera: return "MOGOTES Y CURVAS"
        case .pueblo:     return "TAPÓN Y HOYOS"
        case .costa:      return "RECTA A LA PLAYA"
        }
    }

    static func at(progress p: Float) -> Region {
        if p >= Region.costa.span.lo { return .costa }
        if p >= Region.pueblo.span.lo { return .pueblo }
        return .cordillera
    }
}

/// What kind of moment a popup is, so a hit and a celebration don't look identical.
enum PopupTone {
    case hit        // you took damage
    case pickup     // you grabbed something
    case praise     // a near miss, a combo
    case big        // a real flourish worth shouting about
}

/// How the player steers. Persisted across launches.
enum SteerMode: Int {
    case drag = 0      // analog thumb pad, bottom-left
    case tilt = 1      // device roll via CoreMotion
}

/// Live input, written by the HUD / motion manager, read by the render loop.
/// `steer` is analog in -1…1 — the old binary left/right buttons were the
/// single worst thing about how the car felt.
final class GameInput {
    var steer: Float = 0
    var brake = false
    var nitro = false
    /// Momentary — set by the jump button, cleared by the render loop once used.
    var jumpRequested = false
    /// Momentary — set by the fire button, cleared by the render loop once used.
    var fireRequested = false
}

/// One frame's worth of HUD numbers. Published as a single value so a frame
/// costs one SwiftUI invalidation instead of ten.
struct HudSnapshot: Equatable {
    var speedKmh = 0
    var score = 0
    var hp: Double = 100
    var nitro: Double = 60
    var charge: Double = 100       // beam energy
    var progress: Double = 0
    var speedNorm: Double = 0      // 0…1, drives the speed vignette
    var flash: Double = 0          // damage flash opacity
    var nitroActive = false
    var invuln = false             // post-hit grace period, blinks the car
    var comboLeft: Double = 0      // 1…0, how much of the combo window is left
    var lap = 1                    // endless only
    var lapFlash: Double = 0       // white wash that hides the lap teleport
    var floatLeft: Double = 0      // 1…0 while the triple-jump float is running
    var pendingStyle = 0           // drift points at risk right now
    var heat: Double = 0           // 0…1 wanted meter
    var chased = 0                 // cruisers currently on you
    var ghostOn = false            // a recorded ghost is on course right now
    var ghostGap: Double = 0       // metres ahead of it; negative means behind
    var timeText = "0:00.0"
}

enum Medal: Int {
    case none = 0, bronze, silver, gold

    var label: String {
        switch self {
        case .none: return ""
        case .bronze: return "BRONCE"
        case .silver: return "PLATA"
        case .gold: return "ORO"
        }
    }

    static func forScore(_ score: Int, on stage: Stage) -> Medal {
        let t = stage.medalThresholds
        if score >= t.gold { return .gold }
        if score >= t.silver { return .silver }
        if score >= t.bronze { return .bronze }
        return .none
    }

    /// The next medal up and what it costs, for showing a target on the end screen.
    static func next(after score: Int, on stage: Stage) -> (medal: Medal, needed: Int)? {
        let t = stage.medalThresholds
        if score < t.bronze { return (.bronze, t.bronze - score) }
        if score < t.silver { return (.silver, t.silver - score) }
        if score < t.gold { return (.gold, t.gold - score) }
        return nil
    }
}

/// Observable bridge between the render loop and SwiftUI.
final class GameState: ObservableObject {
    @Published var phase: GamePhase = .intro
    @Published var hud = HudSnapshot()
    @Published var combo: Int = 0
    @Published var popupText: String = ""
    @Published var popupTone: PopupTone = .praise
    @Published var popupID: Int = 0
    @Published var musicOn = true
    @Published var paused = false
    @Published var countLabel: String = ""      // "3" "2" "1" "¡DALE!"
    @Published var sceneReady = false           // false while the world builds

    /// Shown once, on a player's first launch. Jump and the beam are the two least
    /// guessable mechanics and nothing else explains them.
    @Published var showHowTo: Bool = !UserDefaults.standard.bool(forKey: "hoyo_sawHowTo")

    func dismissHowTo() {
        showHowTo = false
        UserDefaults.standard.set(true, forKey: "hoyo_sawHowTo")
    }

    /// The escape plays itself on a first launch and is opt-in after that.
    var sawIntro: Bool { UserDefaults.standard.bool(forKey: "hoyo_sawIntro") }
    func markIntroSeen() { UserDefaults.standard.set(true, forKey: "hoyo_sawIntro") }

    /// Drops the ghost for a stage so the next run draws a fresh course. Locking the
    /// layout to the ghost is what makes the rematch fair, but without this the
    /// course would never change again once a time was set.
    func rerollCourse(_ stage: Stage) {
        let d = UserDefaults.standard
        d.removeObject(forKey: stage.ghostKey)
        d.removeObject(forKey: stage.ghostSeedKey)
        objectWillChange.send()
    }

    var hasGhost: Bool {
        UserDefaults.standard.data(forKey: selectedStage.ghostKey) != nil
    }


    /// Which course the player has picked, and which one is actually loaded.
    @Published var mode: GameMode = GameMode(
        rawValue: UserDefaults.standard.integer(forKey: "hoyo_mode")) ?? .race {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "hoyo_mode") }
    }
    @Published var selectedStage: Stage = .cordillera
    @Published var loadedStage: Stage = .cordillera
    /// Set on the end screen when finishing a stage opened the next one.
    @Published var unlockedStage: Stage?

    // region announcement
    @Published var regionLabel = ""
    @Published var regionBlurb = ""
    @Published var regionID = 0

    @Published var lapLabel = ""
    @Published var lapID = 0

    func showLap(_ n: Int) {
        lapLabel = "VUELTA \(n)"
        lapID += 1
    }

    func showRegion(_ r: Region) {
        regionLabel = r.label
        regionBlurb = r.blurb
        regionID += 1
    }

    @Published var steerMode: SteerMode = SteerMode(
        rawValue: UserDefaults.standard.integer(forKey: "hoyo_steerMode")) ?? .drag {
        didSet { UserDefaults.standard.set(steerMode.rawValue, forKey: "hoyo_steerMode") }
    }

    // records
    @Published var recordLine: String = ""
    @Published var newRecordScore = false
    @Published var newRecordTime = false

    // final-screen stats
    @Published var statTime = ""
    @Published var statScore = 0
    @Published var statTopSpeed = 0
    @Published var statHolesHit = 0
    @Published var statNearMisses = 0
    @Published var statMedal: Medal = .none
    @Published var statTimeBonus = 0
    @Published var statSeed: UInt64 = 0
    @Published var statFinished = false
    @Published var statLaps = 1

    /// Mirrors the system Reduce Motion switch. This game leans hard on camera
    /// shake, motion blur, camera roll, a flashing damage overlay and a full-screen
    /// white wash every lap — all of which are exactly what that setting exists to
    /// turn down.
    @Published private(set) var reduceMotion = UIAccessibility.isReduceMotionEnabled

    private var motionObserver: NSObjectProtocol?

    init() {
        motionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reduceMotion = UIAccessibility.isReduceMotionEnabled
        }
    }

    deinit {
        if let o = motionObserver { NotificationCenter.default.removeObserver(o) }
    }

    let input = GameInput()

    /// Installed by GameSceneView so the start button can rebuild the world for a
    /// different course. It can't go through updateUIView — that representable's
    /// stored properties are all reference types whose identity never changes, so
    /// SwiftUI skips the update entirely.
    var loadStageHandler: ((Stage, @escaping () -> Void) -> Void)?

    /// Set by HUD buttons; the game controller polls these.
    ///
    /// Deliberately not `@Published`. The render loop clears them, and publishing
    /// from off the main thread fires `objectWillChange` where SwiftUI forbids it.
    /// `skipCutscene`/`requestCutscene` were `@Published` and cleared from
    /// `renderer(_:updateAtTime:)`, which is that exact violation.
    var requestStart = false
    var requestReset = false
    var requestTitle = false
    /// Set by a tap during the cutscene, and by the title's replay button.
    var skipCutscene = false
    var requestCutscene = false

    func popup(_ text: String, _ tone: PopupTone = .praise) {
        popupText = text
        popupTone = tone
        popupID += 1
    }

    func refreshRecordLine() {
        recordLine = Self.makeRecordLine(for: selectedStage, mode: mode)
    }

    static func makeRecordLine(for stage: Stage, mode: GameMode) -> String {
        let d = UserDefaults.standard
        var parts: [String] = []
        if mode == .endless {
            let best = d.integer(forKey: stage.endlessScoreKey)
            let laps = d.integer(forKey: stage.endlessLapKey)
            if best > 0 { parts.append("RÉCORD \(best) pts") }
            if laps > 0 { parts.append("\(laps) VUELTAS") }
        } else {
            let best = d.integer(forKey: stage.bestScoreKey)
            let time = d.double(forKey: stage.bestTimeKey)
            if best > 0 { parts.append("RÉCORD \(best) pts") }
            if time > 0 {
                let mm = Int(time) / 60
                let ss = time.truncatingRemainder(dividingBy: 60)
                parts.append(String(format: "MEJOR TIEMPO %d:%04.1f", mm, ss))
            }
        }
        return parts.joined(separator: "  ·  ")
    }
}
