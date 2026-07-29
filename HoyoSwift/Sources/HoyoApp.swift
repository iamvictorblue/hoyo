import SwiftUI
import SceneKit

@main
struct HoyoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var state = GameState()
    @StateObject private var sound = SoundEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            GameSceneView(state: state, sound: sound)
                .ignoresSafeArea()
            HUDView(state: state, sound: sound)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active && state.phase == .playing {
                state.paused = true
            }
        }
    }
}

/// Wraps the SceneKit view and owns the game controller.
struct GameSceneView: UIViewRepresentable {
    let state: GameState
    let sound: SoundEngine

    func makeCoordinator() -> GameScene {
        GameScene(state: state, sound: sound)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.delegate = context.coordinator
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        view.isPlaying = true
        UIApplication.shared.isIdleTimerDisabled = true   // no screen sleep mid-run
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
