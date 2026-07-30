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
    @StateObject private var tilt = TiltObserver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            GameSceneView(state: state, sound: sound, tilt: tilt)
                .ignoresSafeArea()
            HUDView(state: state, sound: sound, tilt: tilt)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            Haptics.shared.prepare()
            tilt.apply(mode: state.steerMode, input: state.input)
        }
        // Driving this from GameSceneView.updateUIView did not work: all of that
        // representable's stored properties are reference types whose identity
        // never changes, so SwiftUI treats it as unchanged and skips the update —
        // the mode only ever applied at view creation, i.e. app launch.
        .onChange(of: state.steerMode) { mode in
            tilt.apply(mode: mode, input: state.input)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active && state.phase == .playing {
                state.paused = true
            }
            // iOS suspends motion updates in the background; bring them back
            if newPhase == .active {
                tilt.apply(mode: state.steerMode, input: state.input)
            }
        }
    }
}

/// Owns the `TiltReader` so SwiftUI keeps one instance, and drives it from the
/// selected steering mode.
final class TiltObserver: ObservableObject {
    let reader = TiltReader()

    var invert: Bool {
        get { reader.invert }
        set { reader.invert = newValue; objectWillChange.send() }
    }

    var isAvailable: Bool { reader.isAvailable }

    func apply(mode: SteerMode, input: GameInput) {
        reader.attach(input)
        if mode == .tilt { reader.start() } else { reader.stop() }
    }
}

/// Wraps the SceneKit view and owns the game controller.
struct GameSceneView: UIViewRepresentable {
    let state: GameState
    let sound: SoundEngine
    let tilt: TiltObserver

    func makeCoordinator() -> GameScene {
        GameScene(state: state, sound: sound, quality: Quality.detect())
    }

    func makeUIView(context: Context) -> SCNView {
        let quality = Quality.detect()
        let view = SCNView()
        let controller = context.coordinator
        view.scene = controller.scene
        view.delegate = controller
        view.rendersContinuously = true
        view.antialiasingMode = quality.antialiasing
        view.backgroundColor = .black
        view.isPlaying = true
        UIApplication.shared.isIdleTimerDisabled = true   // no screen sleep mid-run

        // The world build — 400k sky-cubemap pixels, the terrain meshes, hundreds of
        // trees — used to run synchronously in init and froze the launch for ~5 s.
        // It builds detached on a background queue, then attaches in one main step.
        // `loadStage` runs the same path again whenever the course changes.
        state.loadStageHandler = { stage, done in
            controller.loadStage(stage, onReady: done)
        }
        // `-stage <n>` jumps straight to a course, unlocking it — for testing a
        // stage without finishing the one before it.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-stage"), i + 1 < args.count,
           let n = Int(args[i + 1]), let want = Stage(rawValue: n) {
            want.unlock()
            state.selectedStage = want
        }
        controller.loadStage(state.selectedStage) {
            view.pointOfView = controller.pointOfView
            state.loadedStage = state.selectedStage
            state.sceneReady = true
            state.refreshRecordLine()
            if ProcessInfo.processInfo.arguments.contains("-autoplay") {
                state.requestStart = true
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
