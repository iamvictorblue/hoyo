import Foundation
import Combine
import UIKit

enum GamePhase {
    /// `arrival` is the pre-race beat: the saucer drops out of the sky onto the
    /// mountain road before the countdown starts.
    case intro, arrival, countdown, playing, finished, dead
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
    var endlessScoreKey: String { "hoyo_endlessScore_\(rawValue)" }
    var endlessLapKey: String { "hoyo_endlessLaps_\(rawValue)" }

    /// Score needed for each medal. These are anchored on measurement, not on a
    /// model of the courses — an earlier model reasoned from near-miss geometry,
    /// concluded Yunque should score highest, and set its thresholds 18% above
    /// Guajataca's. Real play says the opposite.
    ///
    /// Every course is 3,600 m and pays the same skill-independent floor: 4,320
    /// for distance (score is `v * dt * 1.2`, which integrates to 1.2 x distance
    /// regardless of speed) plus 26 piraguas and 14 toolboxes, so 7,620 in all.
    ///
    /// Instrumented spawn counts for what differs:
    ///
    ///                 holes   cars          critters      road half-width
    ///   Guajataca      127    pool of 9       —                6.8
    ///   El Yunque      107    none          70 / 5,820 pts      4.6
    ///   Isla Verde     111    none          62 / 5,480 pts      7.6
    ///
    /// - Guajataca is the only course with traffic, and a car pays 150 x combo to
    ///   clear (750 at cap) or 120–250 to ram. That single term outweighs the
    ///   near-miss geometry the old model was built on, and it is why Guajataca
    ///   has the richest economy despite the widest tolerances.
    /// - Yunque and Isla Verde are within 4% of each other on every income term.
    ///   Their thresholds should differ only by how hard each is to survive, and
    ///   the Yunque trail is a third the width of Isla Verde's sand with the same
    ///   number of holes in it — so it gets the lower bar, not the higher one.
    ///
    /// Gold sits slightly above a strong run on each course, so it stays a chase.
    var medalThresholds: (bronze: Int, silver: Int, gold: Int) {
        switch self {
        case .cordillera: return (9_000, 18_000, 27_000)
        case .yunque:     return (7_500, 14_500, 21_500)
        case .playa:      return (8_000, 15_500, 23_000)
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
    var requestStart = false
    var requestReset = false
    var requestTitle = false

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
