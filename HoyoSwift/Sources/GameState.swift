import Foundation
import Combine

enum GamePhase {
    case intro, countdown, playing, finished, dead
}

/// Live input flags, written by the SwiftUI buttons, read by the render loop.
final class GameInput {
    var left = false
    var right = false
    var brake = false
    var nitro = false
}

/// Observable HUD state. The render loop pushes into this on the main queue.
final class GameState: ObservableObject {
    @Published var phase: GamePhase = .intro
    @Published var speedKmh: Int = 0
    @Published var score: Int = 0
    @Published var combo: Int = 0
    @Published var hp: Double = 100
    @Published var nitro: Double = 60
    @Published var timeText: String = "0:00.0"
    @Published var progress: Double = 0
    @Published var speedNorm: Double = 0        // 0…1 for the vignette
    @Published var flash: Double = 0            // damage flash opacity
    @Published var nitroActive = false
    @Published var popupText: String = ""
    @Published var popupID: Int = 0
    @Published var musicOn = true
    @Published var paused = false
    @Published var countLabel: String = ""      // "3" "2" "1" "¡DALE!"

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
        return parts.isEmpty ? "" : "🏆 " + parts.joined(separator: " · ")
    }
}
