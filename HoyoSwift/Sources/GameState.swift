import Foundation
import Combine

enum GamePhase {
    case intro, playing, finished, dead
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
}
