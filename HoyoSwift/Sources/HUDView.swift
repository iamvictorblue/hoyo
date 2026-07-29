import SwiftUI

// MARK: - palette

extension Color {
    static let neonPink = Color(red: 1.0, green: 0.18, blue: 0.47)
    static let neonTeal = Color(red: 0.07, green: 0.84, blue: 0.76)
    static let neonGold = Color(red: 1.0, green: 0.82, blue: 0.25)
    static let sunsetOrange = Color(red: 1.0, green: 0.54, blue: 0.36)
}

// MARK: - HUD

struct HUDView: View {
    @ObservedObject var state: GameState
    let sound: SoundEngine

    var body: some View {
        ZStack {
            // speed vignette
            RadialGradient(colors: [.clear, .clear, Color(red: 0.12, green: 0, blue: 0.16)],
                           center: .center, startRadius: 100, endRadius: 500)
                .opacity(state.speedNorm * 0.9)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // damage flash
            RadialGradient(colors: [Color.red.opacity(0.3), Color(red: 1, green: 0, blue: 0.23).opacity(0.6)],
                           center: .center, startRadius: 80, endRadius: 500)
                .opacity(state.flash * 0.8)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if state.phase == .playing || state.phase == .countdown {
                gameHUD
                touchControls
            }

            // countdown
            if !state.countLabel.isEmpty {
                CountdownView(label: state.countLabel)
                    .id(state.countLabel)
                    .allowsHitTesting(false)
            }

            // popup
            if !state.popupText.isEmpty {
                PopupView(text: state.popupText)
                    .id(state.popupID)
                    .allowsHitTesting(false)
            }

            if state.paused && state.phase == .playing {
                PauseOverlay(state: state)
            }

            switch state.phase {
            case .intro: IntroOverlay(state: state)
            case .finished: EndOverlay(state: state, title: "¡LLEGASTE!",
                                       subtitle: "SOBREVIVISTE LOS HOYOS · A LA PLAYA")
            case .dead: EndOverlay(state: state, title: "¡TE PONCHASTE!",
                                   subtitle: "LOS HOYOS GANARON ESTA VEZ")
            case .playing, .countdown: EmptyView()
            }
        }
    }

    private var gameHUD: some View {
        VStack {
            HStack(alignment: .top) {
                // damage + nitro bars
                VStack(alignment: .leading, spacing: 4) {
                    BarView(label: "CARRO", value: state.hp / 100,
                            color: state.hp > 50 ? .green : (state.hp > 25 ? .neonGold : .neonPink))
                    BarView(label: "NITRO", value: state.nitro / 100, color: .neonTeal)
                }
                .frame(width: 170)

                Spacer()

                VStack(spacing: 4) {
                    Text(state.timeText)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .sunsetOrange, radius: 8)
                    // progress
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule()
                                .fill(LinearGradient(colors: [.neonPink, .sunsetOrange, .neonGold],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * state.progress)
                        }
                    }
                    .frame(width: 220, height: 6)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(state.score)")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .italic()
                        .foregroundStyle(Color.neonTeal)
                        .shadow(color: .neonTeal.opacity(0.8), radius: 10)
                    if state.combo >= 2 {
                        Text("COMBO x\(state.combo) 🔥")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Color.sunsetOrange)
                            .shadow(color: .sunsetOrange.opacity(0.8), radius: 8)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer()

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(state.speedKmh)")
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(state.nitroActive ? Color.neonTeal :
                                     (state.speedKmh > 150 ? Color.neonGold : .white))
                    .shadow(color: .neonPink, radius: 14)
                Text("KM/H")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(Color.neonGold)
            }
        }
        .padding(.bottom, 6)
        .allowsHitTesting(false)
    }

    private var touchControls: some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Button {
                        state.paused = true
                    } label: {
                        Text("⏸")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.3), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                    }
                    Button {
                        state.musicOn.toggle()
                        sound.setMusic(on: state.musicOn)
                    } label: {
                        Text(state.musicOn ? "🎵" : "🔇")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.3), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                    }
                }
            }
            .padding(.trailing, 16)
            .padding(.top, 60)

            Spacer()

            HStack {
                HStack(spacing: 14) {
                    HoldButton(label: "◀") { state.input.left = $0 }
                    HoldButton(label: "▶") { state.input.right = $0 }
                }
                Spacer()
                HStack(spacing: 14) {
                    HoldButton(label: "🛑", tint: .red) { state.input.brake = $0 }
                    HoldButton(label: "🔥", tint: .neonTeal) { state.input.nitro = $0 }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 18)
        }
    }
}

// MARK: - components

struct BarView: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .tracking(3)
                .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.69))
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

/// A press-and-hold circular control that reports its pressed state.
struct HoldButton: View {
    let label: String
    var tint: Color = .white
    let onPress: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 30, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 78, height: 78)
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

struct PauseOverlay: View {
    @ObservedObject var state: GameState

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.01, blue: 0.09).opacity(0.72)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                Text("PAUSA")
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(.white)
                    .shadow(color: .neonPink, radius: 18)
                HStack(spacing: 18) {
                    Button {
                        state.paused = false
                    } label: {
                        Text("SEGUIR")
                            .font(.system(size: 18, weight: .black)).tracking(3)
                            .foregroundStyle(.white)
                            .padding(.vertical, 12).padding(.horizontal, 30)
                            .overlay(Capsule().stroke(Color.neonTeal, lineWidth: 2))
                            .shadow(color: .neonTeal.opacity(0.6), radius: 12)
                    }
                    Button {
                        state.paused = false
                        state.requestReset = true
                    } label: {
                        Text("REINICIAR")
                            .font(.system(size: 18, weight: .black)).tracking(3)
                            .foregroundStyle(.white)
                            .padding(.vertical, 12).padding(.horizontal, 30)
                            .overlay(Capsule().stroke(Color.neonPink, lineWidth: 2))
                            .shadow(color: .neonPink.opacity(0.6), radius: 12)
                    }
                }
            }
        }
    }
}

struct PopupView: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Text(text)
            .font(.system(size: 44, weight: .black, design: .rounded))
            .italic()
            .foregroundStyle(Color.neonGold)
            .shadow(color: .sunsetOrange, radius: 12)
            .shadow(color: Color(red: 0.7, green: 0, blue: 0.37), radius: 2, y: 3)
            .scaleEffect(shown ? 1.0 : 0.4)
            .opacity(shown ? 1 : 0)
            .offset(y: -60)
            .onAppear {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { shown = true }
                withAnimation(.easeOut(duration: 0.4).delay(0.8)) { shown = false }
            }
    }
}

// MARK: - overlays

struct IntroOverlay: View {
    @ObservedObject var state: GameState

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.02, blue: 0.18).opacity(0.92),
                                    Color(red: 0.18, green: 0.04, blue: 0.24).opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                Text("¡HOYO!")
                    .font(.system(size: 76, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(LinearGradient(colors: [.neonPink, .sunsetOrange, .neonGold, .neonTeal],
                                                    startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .neonPink.opacity(0.6), radius: 18)
                Text("CARRERA CUESTA ABAJO · ESQUIVA LOS HOYOS DE PR")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.69))
                Text("🚗 🕳️ 🦎 🌴 🍧").font(.system(size: 24)).padding(.top, 2)

                VStack(alignment: .leading, spacing: 5) {
                    row("◀ ▶", "guía el carro")
                    row("🔥", "NITRO — recarga con 🍧 piraguas")
                    row("🛑", "freno · frena + guía = drift")
                    row("🕳️", "los hoyos rompen el carro, ¡esquívalos!")
                    row("🧰", "el mecánico ambulante repara el carro")
                }
                .font(.system(size: 14))
                .padding(.top, 10)

                if !state.recordLine.isEmpty {
                    Text(state.recordLine)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.neonGold)
                        .shadow(color: .neonGold.opacity(0.6), radius: 8)
                        .padding(.top, 10)
                }

                Button { state.requestStart = true } label: {
                    Text("TOCA PA' ARRANCAR")
                        .font(.system(size: 20, weight: .black))
                        .tracking(3)
                        .foregroundStyle(.white)
                        .padding(.vertical, 13).padding(.horizontal, 38)
                        .overlay(Capsule().stroke(Color.neonPink, lineWidth: 2))
                        .shadow(color: .neonPink.opacity(0.6), radius: 14)
                }
                .padding(.top, 22)
            }
        }
    }

    private func row(_ key: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(key).font(.system(size: 14, weight: .black)).foregroundStyle(Color.neonTeal)
                .frame(width: 46, alignment: .trailing)
            Text(text).foregroundStyle(Color(red: 0.91, green: 0.87, blue: 1.0))
        }
    }
}

struct EndOverlay: View {
    @ObservedObject var state: GameState
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.02, blue: 0.18).opacity(0.92),
                                    Color(red: 0.18, green: 0.04, blue: 0.24).opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(LinearGradient(colors: [.neonPink, .sunsetOrange, .neonGold],
                                                    startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .neonPink.opacity(0.6), radius: 16)
                Text(subtitle)
                    .font(.system(size: 14, weight: .semibold)).tracking(2)
                    .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.69))

                if state.newRecordScore || state.newRecordTime {
                    VStack(spacing: 2) {
                        if state.newRecordScore {
                            Text("★ ¡NUEVO RÉCORD DE PUNTOS! ★")
                        }
                        if state.newRecordTime {
                            Text("★ ¡MEJOR TIEMPO! ★")
                        }
                    }
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color.neonTeal)
                    .shadow(color: .neonTeal.opacity(0.9), radius: 10)
                    .padding(.top, 6)
                }

                VStack(spacing: 6) {
                    stat("TIEMPO", state.statTime)
                    stat("PUNTOS", "\(state.statScore)")
                    stat("VELOCIDAD MÁXIMA", "\(state.statTopSpeed) km/h")
                    stat("HOYOS COMÍOS", "\(state.statHolesHit) · ESQUIVES \(state.statNearMisses)")
                }
                .padding(.top, 10)

                Button { state.requestReset = true } label: {
                    Text("CORRER OTRA VEZ")
                        .font(.system(size: 19, weight: .black)).tracking(3)
                        .foregroundStyle(.white)
                        .padding(.vertical, 12).padding(.horizontal, 34)
                        .overlay(Capsule().stroke(Color.neonPink, lineWidth: 2))
                        .shadow(color: .neonPink.opacity(0.6), radius: 14)
                }
                .padding(.top, 18)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.91, blue: 0.79))
            Text(value).font(.system(size: 19, weight: .black))
                .foregroundStyle(Color.neonGold)
                .shadow(color: .neonGold.opacity(0.7), radius: 8)
        }
    }
}
