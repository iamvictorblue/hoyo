import Foundation
import Combine

enum GamePhase {
    case intro, countdown, playing, finished, dead
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
        case .cordillera: return "LA CORDILLERA"
        case .pueblo:     return "EL PUEBLO"
        case .costa:      return "LA COSTA"
        }
    }

    var blurb: String {
        switch self {
        case .cordillera: return "CURVAS Y DERRUMBES"
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
}

/// One frame's worth of HUD numbers. Published as a single value so a frame
/// costs one SwiftUI invalidation instead of ten.
struct HudSnapshot: Equatable {
    var speedKmh = 0
    var score = 0
    var hp: Double = 100
    var nitro: Double = 60
    var progress: Double = 0
    var speedNorm: Double = 0      // 0…1, drives the speed vignette
    var flash: Double = 0          // damage flash opacity
    var nitroActive = false
    var invuln = false             // post-hit grace period, blinks the car
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

    static func forScore(_ score: Int) -> Medal {
        if score >= 26000 { return .gold }
        if score >= 16000 { return .silver }
        if score >= 8000 { return .bronze }
        return .none
    }
}

/// Observable bridge between the render loop and SwiftUI.
final class GameState: ObservableObject {
    @Published var phase: GamePhase = .intro
    @Published var hud = HudSnapshot()
    @Published var combo: Int = 0
    @Published var popupText: String = ""
    @Published var popupID: Int = 0
    @Published var musicOn = true
    @Published var paused = false
    @Published var countLabel: String = ""      // "3" "2" "1" "¡DALE!"
    @Published var sceneReady = false           // false while the world builds

    // region announcement
    @Published var regionLabel = ""
    @Published var regionBlurb = ""
    @Published var regionID = 0

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
    @Published var recordLine: String = GameState.makeRecordLine()
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

    let input = GameInput()

    /// Set by HUD buttons; the game controller polls these.
    var requestStart = false
    var requestReset = false

    func popup(_ text: String) {
        popupText = text
        popupID += 1
    }

    func refreshRecordLine() {
        recordLine = Self.makeRecordLine()
    }

    static func makeRecordLine() -> String {
        let best = UserDefaults.standard.integer(forKey: "hoyo_bestScore")
        let time = UserDefaults.standard.double(forKey: "hoyo_bestTime")
        var parts: [String] = []
        if best > 0 { parts.append("RÉCORD \(best) pts") }
        if time > 0 {
            let mm = Int(time) / 60
            let ss = time.truncatingRemainder(dividingBy: 60)
            parts.append(String(format: "MEJOR TIEMPO %d:%04.1f", mm, ss))
        }
        return parts.joined(separator: "  ·  ")
    }
}
