import SwiftUI

// MARK: - palette

extension Color {
    static let neonPink = Color(red: 1.0, green: 0.18, blue: 0.47)
    static let neonTeal = Color(red: 0.07, green: 0.84, blue: 0.76)
    static let neonGold = Color(red: 1.0, green: 0.82, blue: 0.25)
    static let sunsetOrange = Color(red: 1.0, green: 0.54, blue: 0.36)
    static let creamText = Color(red: 1, green: 0.85, blue: 0.69)
}

// MARK: - HUD

struct HUDView: View {
    @ObservedObject var state: GameState
    let sound: SoundEngine
    let tilt: TiltObserver

    var body: some View {
        ZStack {
            // speed vignette
            RadialGradient(colors: [.clear, .clear, Color(red: 0.12, green: 0, blue: 0.16)],
                           center: .center, startRadius: 100, endRadius: 500)
                .opacity(state.hud.speedNorm * 0.9)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // damage flash
            RadialGradient(colors: [Color.red.opacity(0.3), Color(red: 1, green: 0, blue: 0.23).opacity(0.6)],
                           center: .center, startRadius: 80, endRadius: 500)
                .opacity(state.hud.flash * 0.8)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if state.phase == .playing || state.phase == .countdown {
                gameHUD
                touchControls
            }

            if state.phase == .arrival {
                ArrivalCard()
                    .allowsHitTesting(false)
            }

            if !state.countLabel.isEmpty {
                CountdownView(label: state.countLabel)
                    .id(state.countLabel)
                    .allowsHitTesting(false)
            }

            if !state.popupText.isEmpty {
                PopupView(text: state.popupText)
                    .id(state.popupID)
                    .allowsHitTesting(false)
            }

            if !state.regionLabel.isEmpty && state.phase == .playing {
                RegionBanner(label: state.regionLabel, blurb: state.regionBlurb)
                    .id(state.regionID)
                    .allowsHitTesting(false)
            }

            if state.paused && state.phase == .playing {
                PauseOverlay(state: state, tilt: tilt)
            }

            switch state.phase {
            case .intro: IntroOverlay(state: state, tilt: tilt)
            case .finished: EndOverlay(state: state, title: "¡LLEGASTE!",
                                       subtitle: "SOBREVIVISTE LOS HOYOS · A LA PLAYA")
            case .dead: EndOverlay(state: state, title: "¡TE PONCHASTE!",
                                   subtitle: "LOS HOYOS GANARON ESTA VEZ")
            case .playing, .countdown, .arrival: EmptyView()
            }
        }
    }

    // Top row only — the speed readout moved to the bottom-right dashboard so
    // nothing sits in the road ahead of the car.
    private var gameHUD: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    BarView(label: "CARRO", value: state.hud.hp / 100,
                            color: state.hud.hp > 50 ? .green
                                 : (state.hud.hp > 25 ? .neonGold : .neonPink))
                    BarView(label: "NITRO", value: state.hud.nitro / 100, color: .neonTeal)
                    BarView(label: "RAYO", value: state.hud.charge / 100, color: .neonGold)
                }
                .frame(width: 168)

                Spacer()

                VStack(spacing: 5) {
                    Text(state.hud.timeText)
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .sunsetOrange, radius: 8)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule()
                                .fill(LinearGradient(colors: [.neonPink, .sunsetOrange, .neonGold],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * state.hud.progress)
                            // region boundaries, so the bar shows how far into the
                            // cordillera / pueblo / costa you are
                            ForEach(Region.allCases.dropFirst(), id: \.rawValue) { r in
                                Rectangle()
                                    .fill(.white.opacity(0.55))
                                    .frame(width: 1.5, height: 8)
                                    .offset(x: geo.size.width * CGFloat(r.span.lo))
                            }
                        }
                    }
                    .frame(width: 216, height: 6)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(state.hud.score)")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .italic()
                        .monospacedDigit()
                        .foregroundStyle(Color.neonTeal)
                        .shadow(color: .neonTeal.opacity(0.8), radius: 10)
                    if state.combo >= 2 {
                        Text("COMBO x\(state.combo)")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(Color.sunsetOrange)
                            .shadow(color: .sunsetOrange.opacity(0.8), radius: 8)
                    }
                    if state.hud.invuln {
                        Text("INMUNE")
                            .font(.system(size: 12, weight: .black)).tracking(2)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 168, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var touchControls: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    IconButton("pause.fill") { state.paused = true }
                    IconButton(state.musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                        state.musicOn.toggle()
                        sound.setMusic(on: state.musicOn)
                    }
                }
            }
            .padding(.trailing, 20)
            .padding(.top, 74)

            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    TapButton(symbol: "bolt.fill", tint: .neonGold) {
                        state.input.fireRequested = true
                    }
                    if state.steerMode == .drag {
                        SteerPad { state.input.steer = $0 }
                    } else {
                        TiltHint()
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 10) {
                    // dashboard: speed reads next to the controls, not over the road
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(state.hud.speedKmh)")
                            .font(.system(size: 50, weight: .black, design: .rounded))
                            .italic()
                            .monospacedDigit()
                            .foregroundStyle(state.hud.nitroActive ? Color.neonTeal :
                                             (state.hud.speedKmh > 150 ? Color.neonGold : .white))
                            .shadow(color: .black.opacity(0.8), radius: 4, y: 2)
                        Text("KM/H")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .tracking(3)
                            .foregroundStyle(Color.neonGold)
                    }
                    .allowsHitTesting(false)

                    HStack(spacing: 12) {
                        TapButton(symbol: "arrow.up.circle.fill", tint: .neonGold) {
                            state.input.jumpRequested = true
                        }
                        HoldButton(symbol: "octagon.fill", tint: .red) { state.input.brake = $0 }
                        HoldButton(symbol: "flame.fill", tint: .neonTeal) { state.input.nitro = $0 }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - components

struct IconButton: View {
    let symbol: String
    let action: () -> Void

    init(_ symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.35), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
        }
    }
}

struct BarView: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .tracking(3)
                .foregroundStyle(Color.creamText)
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.42))
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                GeometryReader { geo in
                    Capsule()
                        .fill(color)
                        .shadow(color: color, radius: 6)
                        .frame(width: max(0, geo.size.width * value))
                }
            }
            .frame(height: 12)
        }
    }
}

/// Analog steering. The original two arrow buttons were on/off, so the car only
/// ever knew full lock — this reports a continuous -1…1 from the thumb's
/// position across the pad.
struct SteerPad: View {
    let onSteer: (Float) -> Void
    @State private var value: Float = 0
    @State private var active = false

    private let padWidth: CGFloat = 218
    private let padHeight: CGFloat = 94
    private let thumb: CGFloat = 58

    private var travel: CGFloat { padWidth / 2 - thumb / 2 - 6 }

    var body: some View {
        ZStack {
            Capsule().fill(.black.opacity(0.34))
                .overlay(Capsule().stroke(.white.opacity(active ? 0.55 : 0.26), lineWidth: 2))

            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(width: 2, height: 24)

            HStack {
                Image(systemName: "arrowtriangle.left.fill")
                Spacer()
                Image(systemName: "arrowtriangle.right.fill")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 14)

            Circle()
                .fill(active ? Color.neonPink.opacity(0.85) : Color.white.opacity(0.5))
                .frame(width: thumb, height: thumb)
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
                .shadow(color: active ? .neonPink : .clear, radius: 14)
                .offset(x: CGFloat(value) * travel)
        }
        .frame(width: padWidth, height: padHeight)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    active = true
                    let raw = (g.location.x - padWidth / 2) / travel
                    let clamped = Float(min(1, max(-1, raw)))
                    value = clamped
                    onSteer(clamped)
                }
                .onEnded { _ in
                    active = false
                    value = 0
                    onSteer(0)
                }
        )
    }
}

/// Location card over the arrival drop — the beat that says the saucer got from
/// Area 51 to the island.
struct ArrivalCard: View {
    @State private var shown = false

    var body: some View {
        VStack(spacing: 4) {
            Text("PUERTO RICO")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .italic()
                .tracking(6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 8, y: 2)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .neonGold, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 250, height: 2)
            Text("LA CORDILLERA")
                .font(.system(size: 12, weight: .heavy)).tracking(5)
                .foregroundStyle(Color.neonGold)
                .shadow(color: .black.opacity(0.85), radius: 5)
        }
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 1.08)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { shown = true }
            withAnimation(.easeIn(duration: 0.5).delay(2.7)) { shown = false }
        }
    }
}

struct TiltHint: View {
    var body: some View {
        Text("INCLINA PA' GUIAR")
            .font(.system(size: 12, weight: .heavy)).tracking(2)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.vertical, 10).padding(.horizontal, 16)
            .background(.black.opacity(0.28), in: Capsule())
            .frame(height: 94)
    }
}

/// Momentary circular control — fires once on touch-down. Used for the jump,
/// which is an impulse rather than something you hold.
struct TapButton: View {
    let symbol: String
    var tint: Color = .white
    let onTap: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(pressed ? .white : tint)
            .frame(width: 76, height: 76)
            .background(pressed ? Color.neonGold.opacity(0.45) : Color.black.opacity(0.35),
                        in: Circle())
            .overlay(Circle().stroke(pressed ? Color.neonGold : tint.opacity(0.5), lineWidth: 2))
            .shadow(color: pressed ? .neonGold : .clear, radius: 12)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onTap() }
                    }
                    .onEnded { _ in pressed = false }
            )
    }
}

/// A press-and-hold circular control that reports its pressed state.
struct HoldButton: View {
    let symbol: String
    var tint: Color = .white
    let onPress: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(pressed ? .white : tint)
            .frame(width: 76, height: 76)
            .background(pressed ? Color.neonPink.opacity(0.5) : Color.black.opacity(0.35),
                        in: Circle())
            .overlay(Circle().stroke(pressed ? Color.neonPink : tint.opacity(0.5), lineWidth: 2))
            .shadow(color: pressed ? .neonPink : .clear, radius: 12)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onPress(true) }
                    }
                    .onEnded { _ in
                        pressed = false; onPress(false)
                    }
            )
    }
}

struct CountdownView: View {
    let label: String
    @State private var shown = false

    var body: some View {
        Text(label)
            .font(.system(size: 110, weight: .black, design: .rounded))
            .italic()
            .foregroundStyle(Color.neonGold)
            .shadow(color: .sunsetOrange, radius: 22)
            .shadow(color: Color(red: 0.7, green: 0, blue: 0.37), radius: 3, y: 5)
            .scaleEffect(shown ? 1.0 : 2.2)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) { shown = true }
                withAnimation(.easeOut(duration: 0.3).delay(0.65)) { shown = false }
            }
    }
}

/// Slides in when you cross into a new stretch of the descent. Deliberately
/// styled apart from the gold score popups so it doesn't read as points.
struct RegionBanner: View {
    let label: String
    let blurb: String
    @State private var shown = false

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .italic()
                .tracking(2)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.85), radius: 6, y: 2)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .neonTeal, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 220, height: 2)
            Text(blurb)
                .font(.system(size: 12, weight: .heavy)).tracking(4)
                .foregroundStyle(Color.neonTeal)
                .shadow(color: .black.opacity(0.8), radius: 4)
        }
        .offset(x: shown ? 0 : -60, y: -18)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { shown = true }
            withAnimation(.easeOut(duration: 0.5).delay(2.1)) { shown = false }
        }
    }
}

struct PopupView: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Text(text)
            .font(.system(size: 40, weight: .black, design: .rounded))
            .italic()
            .foregroundStyle(Color.neonGold)
            .shadow(color: .sunsetOrange, radius: 12)
            .shadow(color: Color(red: 0.7, green: 0, blue: 0.37), radius: 2, y: 3)
            .scaleEffect(shown ? 1.0 : 0.4)
            .opacity(shown ? 1 : 0)
            .offset(y: -96)
            .onAppear {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { shown = true }
                withAnimation(.easeOut(duration: 0.4).delay(0.8)) { shown = false }
            }
    }
}

/// Shared control-scheme switch, offered on the intro and in the pause menu.
struct SteerModePicker: View {
    @ObservedObject var state: GameState
    let tilt: TiltObserver

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                pill("PAD", active: state.steerMode == .drag) { state.steerMode = .drag }
                if tilt.isAvailable {
                    pill("INCLINAR", active: state.steerMode == .tilt) { state.steerMode = .tilt }
                }
            }
            if state.steerMode == .tilt {
                Button {
                    tilt.invert.toggle()
                } label: {
                    Text(tilt.invert ? "SENTIDO: INVERTIDO" : "SENTIDO: NORMAL")
                        .font(.system(size: 11, weight: .heavy)).tracking(2)
                        .foregroundStyle(Color.creamText)
                }
            }
        }
    }

    private func pill(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .black)).tracking(2)
                .foregroundStyle(active ? .black : .white)
                .padding(.vertical, 8).padding(.horizontal, 18)
                .background(active ? Color.neonTeal : Color.white.opacity(0.09), in: Capsule())
                .overlay(Capsule().stroke(active ? Color.neonTeal : .white.opacity(0.3), lineWidth: 1.5))
        }
    }
}

struct PauseOverlay: View {
    @ObservedObject var state: GameState
    let tilt: TiltObserver

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.01, blue: 0.09).opacity(0.72)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text("PAUSA")
                    .font(.system(size: 50, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(.white)
                    .shadow(color: .neonPink, radius: 18)

                // the only place controls are switched, now that the title screen
                // is stripped back — so it needs a label
                VStack(spacing: 8) {
                    Text("CONTROL")
                        .font(.system(size: 10, weight: .heavy)).tracking(4)
                        .foregroundStyle(.white.opacity(0.45))
                    SteerModePicker(state: state, tilt: tilt)
                }

                HStack(spacing: 18) {
                    CapsuleButton("SEGUIR", color: .neonTeal) { state.paused = false }
                    CapsuleButton("REINICIAR", color: .neonPink) {
                        state.paused = false
                        state.requestReset = true
                    }
                }
            }
        }
    }
}

struct CapsuleButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    init(_ title: String, color: Color, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .black)).tracking(3)
                .foregroundStyle(.white)
                .padding(.vertical, 12).padding(.horizontal, 30)
                .overlay(Capsule().stroke(color, lineWidth: 2))
                .shadow(color: color.opacity(0.6), radius: 12)
        }
    }
}

// MARK: - overlays

struct IntroOverlay: View {
    @ObservedObject var state: GameState
    let tilt: TiltObserver

    var body: some View {
        ZStack {
            // Light enough to read the Area 51 escape playing behind it. Legibility
            // comes from the text's own shadows rather than from dimming the scene.
            LinearGradient(colors: [Color(red: 0.08, green: 0.02, blue: 0.18).opacity(0.44),
                                    Color(red: 0.16, green: 0.03, blue: 0.22).opacity(0.30)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Text("¡HOYO!")
                    .font(.system(size: 82, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(LinearGradient(colors: [.neonPink, .sunsetOrange, .neonGold, .neonTeal],
                                                    startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .black.opacity(0.7), radius: 10, y: 3)
                    .shadow(color: .neonPink.opacity(0.6), radius: 22)

                Text("CARRERA CUESTA ABAJO POR PUERTO RICO")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(5)
                    .foregroundStyle(Color.creamText)
                    .shadow(color: .black.opacity(0.8), radius: 4)
                    .padding(.top, 6)

                // The one thing a new player can't discover on their own.
                Text("FRENO + GUÍA = DRIFT")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.top, 20)

                if !state.recordLine.isEmpty {
                    Text(state.recordLine)
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Color.neonGold)
                        .shadow(color: .neonGold.opacity(0.5), radius: 8)
                        .padding(.top, 10)
                }

                if state.sceneReady {
                    Button {
                        tilt.reader.recalibrate()
                        state.requestStart = true
                    } label: {
                        Text("TOCA PA' ARRANCAR")
                            .font(.system(size: 19, weight: .black))
                            .tracking(3)
                            .foregroundStyle(.white)
                            .padding(.vertical, 14).padding(.horizontal, 38)
                            .background(.black.opacity(0.35), in: Capsule())
                            .overlay(Capsule().stroke(Color.neonPink, lineWidth: 2))
                            .shadow(color: .neonPink.opacity(0.6), radius: 14)
                    }
                    .padding(.top, 26)
                } else {
                    LoadingLabel()
                        .padding(.top, 26)
                }
            }
        }
    }
}

struct LoadingLabel: View {
    @State private var dots = 0

    var body: some View {
        Text("CARGANDO" + String(repeating: ".", count: dots))
            .font(.system(size: 16, weight: .black)).tracking(3)
            .foregroundStyle(Color.creamText)
            .frame(width: 220)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    dots = (dots + 1) % 4
                }
            }
    }
}

struct EndOverlay: View {
    @ObservedObject var state: GameState
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.02, blue: 0.18).opacity(0.90),
                                    Color(red: 0.18, green: 0.04, blue: 0.24).opacity(0.84)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(LinearGradient(colors: [.neonPink, .sunsetOrange, .neonGold],
                                                    startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .neonPink.opacity(0.6), radius: 16)
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold)).tracking(2)
                    .foregroundStyle(Color.creamText)

                if state.statMedal != .none {
                    VStack(spacing: 1) {
                        Text("MEDALLA")
                            .font(.system(size: 9, weight: .heavy)).tracking(4)
                            .foregroundStyle(.white.opacity(0.45))
                        Text(state.statMedal.label)
                            .font(.system(size: 26, weight: .black)).tracking(3)
                            .foregroundStyle(medalColor)
                            .shadow(color: medalColor.opacity(0.8), radius: 12)
                    }
                    .padding(.top, 6)
                }

                if state.newRecordScore || state.newRecordTime {
                    VStack(spacing: 2) {
                        if state.newRecordScore { Text("¡NUEVO RÉCORD DE PUNTOS!") }
                        if state.newRecordTime { Text("¡MEJOR TIEMPO!") }
                    }
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color.neonTeal)
                    .shadow(color: .neonTeal.opacity(0.9), radius: 10)
                    .padding(.top, 2)
                }

                HStack(spacing: 26) {
                    stat("TIEMPO", state.statTime)
                    stat("PUNTOS", "\(state.statScore)")
                    stat("MÁXIMA", "\(state.statTopSpeed) km/h")
                }
                .padding(.top, 8)

                stat("HOYOS COMÍOS", "\(state.statHolesHit) · ESQUIVES \(state.statNearMisses)")

                // verbatim: interpolating an integer into Text localises it, and
                // a track id reads oddly as "42,250"
                Text(verbatim: "PISTA #\(state.statSeed % 100000)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 2)

                CapsuleButton("CORRER OTRA VEZ", color: .neonPink) {
                    state.requestReset = true
                }
                .padding(.top, 12)
            }
        }
    }

    private var medalColor: Color {
        switch state.statMedal {
        case .gold:   return .neonGold
        case .silver: return Color(white: 0.84)
        case .bronze: return Color(red: 0.80, green: 0.52, blue: 0.26)
        case .none:   return .clear
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(1)
                .foregroundStyle(Color(red: 1, green: 0.91, blue: 0.79))
            Text(value).font(.system(size: 18, weight: .black))
                .foregroundStyle(Color.neonGold)
                .shadow(color: .neonGold.opacity(0.7), radius: 8)
        }
    }
}
