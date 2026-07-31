import SwiftUI

// MARK: - palette

extension Color {
    static let neonPink = Color(red: 1.0, green: 0.18, blue: 0.47)
    static let neonTeal = Color(red: 0.07, green: 0.84, blue: 0.76)
    static let neonGold = Color(red: 1.0, green: 0.82, blue: 0.25)
    static let sunsetOrange = Color(red: 1.0, green: 0.54, blue: 0.36)
    static let creamText = Color(red: 1, green: 0.85, blue: 0.69)
    /// Signage: a cream enamel field and the near-black ink used on road markers.
    static let signField = Color(red: 0.96, green: 0.94, blue: 0.88)
    static let signInk = Color(red: 0.09, green: 0.07, blue: 0.10)
}

// MARK: - type system
//
// SF Pro's width axis (iOS 16+) gives tall, narrow signage type without shipping a
// font file, which keeps the project's no-assets rule. Display is compressed black
// — roadside lettering, not a friendly app; labels are condensed heavy caps; every
// number is monospaced so columns align and live values don't jitter.

extension Font {
    /// Display: Helvetica Neue Condensed Black, which ships with iOS so nothing has
    /// to be bundled. The classic poster and road-sign face — SF's compressed black
    /// read as videogame lettering, which is the opposite of what this wants.
    static func display(_ size: CGFloat) -> Font {
        .custom("HelveticaNeue-CondensedBlack", fixedSize: size)
    }
    /// Labels: upright Helvetica Bold, tracked wide. Condensed at 9–12pt gets muddy.
    static func label(_ size: CGFloat) -> Font {
        .custom("HelveticaNeue-Bold", fixedSize: size)
    }
    /// Data stays monospaced on purpose. Helvetica has no monospace, and tabular
    /// figures aren't guaranteed — a speedometer whose digits shift width as it
    /// counts is far more distracting than a second face. Grotesque display over a
    /// mono data face is a normal editorial pairing anyway.
    static func data(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }
}

// MARK: - wordmark

/// The brand: the two O's in HOYO are literally potholes — dark core, warm gritty
/// rim, the same read as the ones in the road. A game named after a hole should
/// have holes in its name.
struct PotholeO: View {
    let cap: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .fill(LinearGradient(
                    colors: [Color(red: 0.74, green: 0.69, blue: 0.60),
                             Color(red: 0.48, green: 0.43, blue: 0.37)],
                    startPoint: .top, endPoint: .bottom))
            Ellipse()
                .fill(RadialGradient(
                    colors: [Color(red: 0.02, green: 0.02, blue: 0.03),
                             Color(red: 0.10, green: 0.09, blue: 0.11)],
                    center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: cap * 0.42))
                .padding(cap * 0.13)
        }
        .frame(width: cap * 0.66, height: cap)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
    }
}

struct Wordmark: View {
    var size: CGFloat = 74

    /// SF's cap height is about 0.72 em.
    private var cap: CGFloat { size * 0.715 }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.012) {
            Text("¡H").font(.display(size))
            hole
            Text("Y").font(.display(size))
            hole
            Text("!").font(.display(size))
        }
        .foregroundStyle(LinearGradient(
            colors: [.neonPink, .sunsetOrange, .neonGold],
            startPoint: .leading, endPoint: .trailing))
        .shadow(color: .black.opacity(0.8), radius: 9, y: 3)
        .shadow(color: .neonPink.opacity(0.4), radius: 24)
    }

    private var hole: some View {
        PotholeO(cap: cap)
            .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
    }
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
                ArrivalCard(stage: state.loadedStage)
                    .allowsHitTesting(false)
            }

            if !state.countLabel.isEmpty {
                CountdownView(label: state.countLabel, calm: state.reduceMotion)
                    .id(state.countLabel)
                    .allowsHitTesting(false)
            }

            if !state.popupText.isEmpty {
                PopupView(text: state.popupText, tone: state.popupTone, calm: state.reduceMotion)
                    .id(state.popupID)
                    .allowsHitTesting(false)
            }

            // covers the lap teleport
            if state.hud.lapFlash > 0.001 {
                Color.white
                    .opacity(state.hud.lapFlash)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if !state.lapLabel.isEmpty && state.phase == .playing {
                RegionBanner(label: state.lapLabel, blurb: "SIGUE DÁNDOLE", calm: state.reduceMotion)
                    .id(state.lapID)
                    .allowsHitTesting(false)
            }

            if !state.regionLabel.isEmpty && state.phase == .playing {
                RegionBanner(label: state.regionLabel, blurb: state.regionBlurb, calm: state.reduceMotion)
                    .id(state.regionID)
                    .allowsHitTesting(false)
            }

            if state.paused && state.phase == .playing {
                PauseOverlay(state: state, tilt: tilt)
            }

            switch state.phase {
            case .intro:
                IntroOverlay(state: state, tilt: tilt)
                if state.showHowTo && state.sceneReady { HowToCard(state: state) }
            case .finished: EndOverlay(state: state, title: "¡LLEGASTE!",
                                       subtitle: state.loadedStage.finishLine)
            case .dead: EndOverlay(state: state, title: "GAME OVER",
                                   subtitle: state.loadedStage.failLine)
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
                            // deep red rather than neon pink at the bottom: it reads
                            // apart from the gold by brightness, not just hue
                            color: state.hud.hp > 50 ? .green
                                 : (state.hud.hp > 25 ? .neonGold
                                    : Color(red: 0.92, green: 0.18, blue: 0.12)),
                            showValue: true)
                    BarView(label: "NITRO", value: state.hud.nitro / 100, color: .neonTeal)
                    BarView(label: "RAYO", value: state.hud.charge / 100, color: .neonGold)
                }
                .frame(width: 168)

                Spacer()

                VStack(spacing: 5) {
                    HStack(spacing: 8) {
                        RouteShield(route: state.loadedStage.route, compact: true)
                            .scaleEffect(0.62)
                            .frame(width: 30, height: 22)
                        if state.mode == .endless {
                            Text("V\(state.hud.lap)")
                                .font(.data(19))
                                .foregroundStyle(Color.neonGold)
                        }
                        Text(state.hud.timeText)
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule()
                                .fill(LinearGradient(colors: [.neonPink, .sunsetOrange, .neonGold],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * state.hud.progress)
                            // region boundaries, so the bar shows how far into the
                            // cordillera / pueblo / costa you are
                            ForEach(state.loadedStage == .cordillera
                                    ? Array(Region.allCases.dropFirst()) : [],
                                    id: \.rawValue) { r in
                                Rectangle()
                                    .fill(.white.opacity(0.55))
                                    .frame(width: 1.5, height: 8)
                                    .offset(x: geo.size.width * CGFloat(r.span.lo))
                            }
                        }
                    }
                    .frame(width: 216, height: 6)

                    if state.hud.ghostOn {
                        let ahead = state.hud.ghostGap >= 0
                        HStack(spacing: 5) {
                            Image(systemName: ahead ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .black))
                            Text("\(ahead ? "+" : "")\(Int(state.hud.ghostGap)) m")
                                .font(.data(12))
                        }
                        .foregroundStyle(ahead ? Color.neonTeal : Color.neonPink)
                        .padding(.vertical, 3).padding(.horizontal, 9)
                        .background(.black.opacity(0.3), in: Capsule())
                        .padding(.top, 4)
                    }

                    if state.hud.floatLeft > 0 {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("FLOTANDO")
                                .font(.label(11)).tracking(3)
                            ZStack(alignment: .leading) {
                                Capsule().fill(.black.opacity(0.35))
                                Capsule().fill(Color.neonTeal)
                                    .frame(width: 46 * state.hud.floatLeft)
                            }
                            .frame(width: 46, height: 4)
                        }
                        .foregroundStyle(Color.neonTeal)
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        .background(.black.opacity(0.35), in: Capsule())
                        .shadow(color: .neonTeal.opacity(0.5), radius: 10)
                        .padding(.top, 4)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.hud.score.formatted())
                        .font(.data(30))
                        .foregroundStyle(Color.neonTeal)
                        .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                    // The combo bleeds away, so it needs a visible fuse — otherwise
                    // losing it reads as the game punishing you at random.
                    if state.combo >= 2 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("COMBO x\(state.combo)")
                                .font(.label(15))
                                .foregroundStyle(Color.sunsetOrange)
                                .shadow(color: .sunsetOrange.opacity(0.8), radius: 8)
                            ZStack(alignment: .trailing) {
                                Capsule().fill(.white.opacity(0.14))
                                Capsule()
                                    .fill(state.hud.comboLeft < 0.3
                                          ? Color.neonPink : Color.sunsetOrange)
                                    .frame(width: 74 * state.hud.comboLeft)
                            }
                            .frame(width: 74, height: 3)
                        }
                    }

                    // what a crash would cost you right now
                    if state.hud.pendingStyle > 40 {
                        Text("+\(state.hud.pendingStyle.formatted())")
                            .font(.data(15))
                            .foregroundStyle(Color.neonGold)
                            .shadow(color: .neonGold.opacity(0.7), radius: 8)
                    }
                    if state.hud.invuln {
                        Text("INMUNE")
                            .font(.label(13)).tracking(2)
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
                // left: the dashboard reading sits above the steering pad, in the
                // space the fire button used to occupy
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(state.hud.speedKmh)")
                            .font(.data(44))
                            .foregroundStyle(state.hud.nitroActive ? Color.neonTeal :
                                             (state.hud.speedKmh > 150 ? Color.neonGold : .white))
                            .shadow(color: .black.opacity(0.8), radius: 4, y: 2)
                        Text("KM/H")
                            .font(.label(13))
                            .tracking(3)
                            .foregroundStyle(Color.neonGold)
                    }
                    .allowsHitTesting(false)
                    .padding(.leading, 6)

                    if state.steerMode == .drag {
                        SteerPad { state.input.steer = $0 }
                    } else {
                        TiltHint()
                    }
                }

                Spacer()

                // right: a 2x2 pad. The two held controls sit on the bottom row where
                // the thumb rests; the two taps sit above, with fire on the outside
                // corner where it's easiest to reach.
                VStack(spacing: 11) {
                    HStack(spacing: 11) {
                        TapButton(symbol: "arrow.up.circle.fill", tint: .neonGold, caption: "SALTA") {
                            state.input.jumpRequested = true
                        }
                        TapButton(symbol: "bolt.fill", tint: .neonTeal, caption: "RAYO") {
                            state.input.fireRequested = true
                        }
                    }
                    HStack(spacing: 11) {
                        HoldButton(symbol: "octagon.fill", tint: .red, caption: "FRENO") { state.input.brake = $0 }
                        HoldButton(symbol: "flame.fill", tint: .neonTeal, caption: "NITRO") { state.input.nitro = $0 }
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
    /// Shows the number alongside the bar. Colour is a weak channel on its own —
    /// green/gold/pink is the most common confusion axis — so health carries length,
    /// hue and a figure.
    var showValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.label(10))
                    .tracking(3)
                    .foregroundStyle(Color.creamText.opacity(0.85))
                if showValue {
                    Text("\(Int(value * 100))")
                        .font(.data(10))
                        .foregroundStyle(color)
                }
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.black.opacity(0.45))
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .stroke(.white.opacity(0.18), lineWidth: 1))
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * value))
                        .padding(1.5)
                }
            }
            .frame(height: 9)
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
    let stage: Stage
    @State private var shown = false

    var body: some View {
        VStack(spacing: 4) {
            Text("PUERTO RICO")
                .font(.display(44))
                .tracking(4)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 8, y: 2)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .neonGold, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 250, height: 2)
            Text(stage.name)
                .font(.label(13)).tracking(5)
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

// MARK: - signage kit
//
// The screens are built out of Puerto Rican roadside signage rather than generic
// arcade neon. Each course runs on a real road — PR-143 is the Ruta Panorámica
// through the cordillera, PR-191 is the road into El Yunque — so a route shield
// labels a stage the way a road sign labels a road. Numbers are monospaced
// throughout: odometers and kilometre markers are, and it makes columns align.

/// The signature element. Doubles as the stage selector and as the marker for the
/// course you just ran.
struct RouteShield: View {
    let route: String
    var selected = true
    var compact = false

    private var w: CGFloat { compact ? 46 : 58 }

    var body: some View {
        VStack(spacing: 0) {
            Text("PR")
                .font(.system(size: compact ? 8 : 10, weight: .heavy))
                .tracking(2)
                .foregroundStyle(Color.signInk.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 1 : 2)
                .background(Color.signInk.opacity(0.12))
            Text(route)
                .font(.data(compact ? 20 : 26))
                .foregroundStyle(Color.signInk)
                .padding(.bottom, compact ? 2 : 3)
        }
        .frame(width: w)
        .background(selected ? Color.signField : Color.signField.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(selected ? Color.neonTeal : Color.signInk.opacity(0.5),
                    lineWidth: selected ? 2.5 : 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(selected ? 1 : 0.55)
    }
}

/// Course selector. Only shown once a second course exists, so a first-time
/// player still sees the stripped-back title.
struct StagePicker: View {
    @ObservedObject var state: GameState

    var body: some View {
        HStack(spacing: 9) {
            ForEach(Stage.allCases.filter { $0.unlocked }, id: \.rawValue) { st in
                Button {
                    state.selectedStage = st
                    state.refreshRecordLine()
                } label: {
                    HStack(spacing: 8) {
                        RouteShield(route: st.route, selected: state.selectedStage == st,
                                    compact: true)
                        Text(st.name)
                            .font(.label(12)).tracking(2)
                            .foregroundStyle(state.selectedStage == st
                                             ? Color.white : Color.white.opacity(0.45))
                    }
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .padding(.leading, 4)
                    .background(state.selectedStage == st
                                ? Color.white.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

/// A label/value line. The value is monospaced and right-aligned so a column of
/// them reads like a results slip.
struct StatLine: View {
    let label: String
    let value: String
    var accent: Color = .neonGold
    var wide: CGFloat = 176

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.label(11)).tracking(2)
                .foregroundStyle(Color.creamText.opacity(0.8))
            Spacer(minLength: 8)
            Text(value)
                .font(.data(17))
                .foregroundStyle(accent)
        }
        .frame(width: wide)
    }
}

/// Primary action. The only thing besides the wordmark allowed to glow.
struct SignButton: View {
    let title: String
    var color: Color = .neonTeal
    var filled = true
    let action: () -> Void

    init(_ title: String, color: Color = .neonTeal, filled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title; self.color = color; self.filled = filled; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "play.fill").font(.system(size: 11, weight: .black))
                Text(title).font(.display(19)).tracking(2)
            }
            .foregroundStyle(filled ? Color.signInk : color)
            .padding(.vertical, 12).padding(.horizontal, 24)
            .background(filled ? color : Color.black.opacity(0.4), in: Capsule())
            .overlay(Capsule().stroke(color, lineWidth: filled ? 0 : 2))
            .shadow(color: filled ? color.opacity(0.55) : .clear, radius: 14)
        }
    }
}

/// A quiet secondary action — no glow, no fill.
struct GhostButton: View {
    let title: String
    var color: Color = .white
    let action: () -> Void

    init(_ title: String, color: Color = .white, action: @escaping () -> Void) {
        self.title = title; self.color = color; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.label(14)).tracking(3)
                .foregroundStyle(color.opacity(0.85))
                .padding(.vertical, 10).padding(.horizontal, 20)
                .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1.5))
        }
    }
}

/// Hairline rule under a screen title, in the accent of that screen.
struct SignRule: View {
    var color: Color = .neonGold
    var width: CGFloat = 150

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [color, color.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: 2)
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
    var caption: String? = nil
    let onTap: () -> Void
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 3) {
            glyph
            if let caption {
                Text(caption).font(.label(9)).tracking(1)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var glyph: some View {
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
    var caption: String? = nil
    let onPress: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 3) {
            glyph
            if let caption {
                Text(caption).font(.label(9)).tracking(1)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var glyph: some View {
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
    var calm = false
    @State private var shown = false

    var body: some View {
        Text(label)
            .font(.display(132))
            .foregroundStyle(Color.neonGold)
            .shadow(color: .sunsetOrange, radius: 22)
            .shadow(color: Color(red: 0.7, green: 0, blue: 0.37), radius: 3, y: 5)
            .scaleEffect(shown || calm ? 1.0 : 2.2)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(calm ? .easeOut(duration: 0.18)
                                   : .spring(response: 0.22, dampingFraction: 0.62)) { shown = true }
                withAnimation(.easeOut(duration: 0.3).delay(0.65)) { shown = false }
            }
    }
}

/// Slides in when you cross into a new stretch of the descent. Deliberately
/// styled apart from the gold score popups so it doesn't read as points.
struct RegionBanner: View {
    let label: String
    let blurb: String
    var calm = false
    @State private var shown = false

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.display(38))
                .tracking(1)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.85), radius: 6, y: 2)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .neonTeal, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 220, height: 2)
            Text(blurb)
                .font(.label(13)).tracking(4)
                .foregroundStyle(Color.neonTeal)
                .shadow(color: .black.opacity(0.8), radius: 4)
        }
        .offset(x: (shown || calm) ? 0 : -60, y: -18)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(calm ? .easeOut(duration: 0.3)
                               : .spring(response: 0.42, dampingFraction: 0.78)) { shown = true }
            withAnimation(.easeOut(duration: 0.5).delay(2.1)) { shown = false }
        }
    }
}

struct PopupView: View {
    let text: String
    var tone: PopupTone = .praise
    var calm = false
    @State private var shown = false

    private var size: CGFloat {
        switch tone {
        case .hit: return 34
        case .pickup: return 30
        case .praise: return 37
        case .big: return 48
        }
    }
    private var paint: AnyShapeStyle {
        switch tone {
        case .hit:    return AnyShapeStyle(Color.neonPink)
        case .pickup: return AnyShapeStyle(Color.neonTeal)
        case .praise: return AnyShapeStyle(Color.neonGold)
        case .big:    return AnyShapeStyle(LinearGradient(
            colors: [.neonGold, .sunsetOrange, .neonPink],
            startPoint: .leading, endPoint: .trailing))
        }
    }
    private var glow: Color {
        switch tone {
        case .hit: return .neonPink
        case .pickup: return .neonTeal
        default: return .sunsetOrange
        }
    }

    var body: some View {
        Text(text)
            .font(.display(size * 1.18))
            .foregroundStyle(paint)
            .shadow(color: .black.opacity(0.75), radius: 5, y: 2)
            .shadow(color: glow.opacity(0.7), radius: 14)
            .scaleEffect(shown || calm ? 1.0 : (tone == .big ? 0.3 : 0.55))
            .rotationEffect(.degrees(shown || calm ? 0 : (tone == .hit ? -6 : 3)))
            .opacity(shown ? 1 : 0)
            .offset(y: -96)
            .onAppear {
                // Reduce Motion: fade in place instead of springing and rotating
                withAnimation(calm ? .easeOut(duration: 0.2)
                                   : .spring(response: tone == .big ? 0.3 : 0.24,
                                             dampingFraction: tone == .big ? 0.5 : 0.62)) {
                    shown = true
                }
                withAnimation(.easeOut(duration: 0.4).delay(tone == .big ? 1.0 : 0.8)) {
                    shown = false
                }
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
            // Light enough to still see the road you're going back to.
            Color(red: 0.04, green: 0.01, blue: 0.09).opacity(0.62)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Text("EN PAUSA")
                    .font(.display(38)).tracking(5)
                    .foregroundStyle(.white)
                SignRule(color: .neonTeal, width: 130)
                    .padding(.top, 6)

                VStack(spacing: 7) {
                    Text("CONTROL")
                        .font(.label(10)).tracking(4)
                        .foregroundStyle(.white.opacity(0.4))
                    SteerModePicker(state: state, tilt: tilt)
                }
                .padding(.top, 22)

                SignButton("SEGUIR") { state.paused = false }
                    .padding(.top, 24)

                HStack(spacing: 10) {
                    GhostButton("DE NUEVO", color: .neonPink) {
                        state.paused = false
                        state.requestReset = true
                    }
                    GhostButton("AL INICIO") {
                        state.paused = false
                        state.requestTitle = true
                    }
                }
                .padding(.top, 10)

                // reachable again, not just on the very first launch
                Button { state.showHowTo = true; state.requestTitle = true } label: {
                    Text("CÓMO SE JUEGA")
                        .font(.label(10)).tracking(2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.top, 12)
            }
            .padding(.vertical, 26).padding(.horizontal, 40)
            .background(Color(red: 0.07, green: 0.03, blue: 0.13).opacity(0.9),
                        in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.12), lineWidth: 1))
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
    @State private var entered = false

    private var multiStage: Bool {
        Stage.allCases.contains { $0 != .cordillera && $0.unlocked }
    }
    /// Race only — see `endGame`.
    private var bestMedal: Medal {
        guard state.mode == .race else { return .none }
        return Medal.forScore(UserDefaults.standard.integer(forKey: state.selectedStage.bestScoreKey),
                              on: state.selectedStage)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Two scrims doing different jobs: a broad diagonal that keeps the
            // escape legible top-right, and a tighter one anchoring the plinth so
            // the type never sits on moving scenery.
            LinearGradient(colors: [.clear,
                                    Color(red: 0.05, green: 0.02, blue: 0.11).opacity(0.42),
                                    Color(red: 0.04, green: 0.01, blue: 0.09).opacity(0.86)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
                .ignoresSafeArea()
            LinearGradient(colors: [Color.black.opacity(0.55), .clear],
                           startPoint: .bottom, endPoint: .top)
                .frame(height: 260)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()

            HStack(alignment: .bottom, spacing: 0) {
                // a hairline spine the whole plinth hangs off
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Color.neonGold.opacity(0.55)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2)
                    .frame(maxHeight: 150, alignment: .bottom)
                    .padding(.trailing, 16)
                    .opacity(entered ? 1 : 0)

                VStack(alignment: .leading, spacing: 0) {
                    Wordmark(size: 80)
                        .opacity(entered ? 1 : 0)
                        .offset(y: entered ? 0 : 14)

                    HStack(spacing: 10) {
                        Text("CARRERA CUESTA ABAJO")
                            .font(.label(11)).tracking(4)
                            .foregroundStyle(Color.creamText)
                        Text("PUERTO RICO")
                            .font(.label(11)).tracking(4)
                            .foregroundStyle(Color.neonGold)
                    }
                    .padding(.top, 10)
                    .opacity(entered ? 1 : 0)

                    HStack(spacing: 9) {
                        ForEach([GameMode.race, GameMode.endless], id: \.rawValue) { m in
                            Button {
                                state.mode = m
                                state.refreshRecordLine()
                            } label: {
                                Text(m.name)
                                    .font(.label(11)).tracking(2)
                                    .foregroundStyle(state.mode == m ? .black : .white.opacity(0.5))
                                    .padding(.vertical, 6).padding(.horizontal, 14)
                                    .background(state.mode == m ? Color.neonGold : Color.white.opacity(0.08),
                                                in: Capsule())
                                    .overlay(Capsule().stroke(state.mode == m
                                                              ? Color.neonGold : .white.opacity(0.25),
                                                              lineWidth: 1.5))
                            }
                        }
                        Text(state.mode.blurb)
                            .font(.label(9)).tracking(2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.top, 18)

                    if multiStage {
                        StagePicker(state: state).padding(.top, 12)
                    } else {
                        HStack(spacing: 10) {
                            RouteShield(route: Stage.cordillera.route, compact: true)
                            Text(Stage.cordillera.blurb)
                                .font(.label(10)).tracking(2)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.top, 12)
                    }

                    // records, quiet — a stat line, not a headline
                    HStack(spacing: 12) {
                        if bestMedal != .none {
                            Text(bestMedal.label)
                                .font(.label(10)).tracking(2)
                                .foregroundStyle(Color.neonGold.opacity(0.9))
                                .padding(.vertical, 3).padding(.horizontal, 7)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.neonGold.opacity(0.4), lineWidth: 1))
                        }
                        if !state.recordLine.isEmpty {
                            Text(state.recordLine)
                                .font(.data(11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .padding(.top, 14)

                    if state.sceneReady {
                        SignButton("TOCA PA' ARRANCAR") {
                            tilt.reader.recalibrate()
                            if state.selectedStage != state.loadedStage,
                               let load = state.loadStageHandler {
                                let want = state.selectedStage
                                state.sceneReady = false
                                load(want) {
                                    state.loadedStage = want
                                    state.sceneReady = true
                                    state.refreshRecordLine()
                                    state.requestStart = true
                                }
                            } else {
                                state.requestStart = true
                            }
                        }
                        .padding(.top, 20)
                    } else {
                        LoadingLabel().padding(.top, 24)
                    }
                }
            }
            .padding(.leading, 30)
            .padding(.bottom, 26)
        }
        .onAppear {
            // one orchestrated entrance rather than scattered effects
            withAnimation(.easeOut(duration: 0.55).delay(0.1)) { entered = true }
        }
    }
}

/// First-run explainer. Says what each control is *for*, not just its name — the
/// captions on the buttons already handle naming.
struct HowToCard: View {
    @ObservedObject var state: GameState

    private let rows: [(String, String, String)] = [
        ("arrowtriangle.left.and.line.vertical.and.arrowtriangle.right", "GUÍA",
         "desliza el pad pa' virar"),
        ("octagon.fill", "FRENO", "frena, y con guía haces drift"),
        ("flame.fill", "NITRO", "corre más · las piraguas lo llenan"),
        ("arrow.up.circle.fill", "SALTA", "brinca los hoyos y los carros"),
        ("arrow.up.to.line", "A VOLAR", "brinca tres veces seguidas y flotas"),
        ("bolt.fill", "RAYO", "tapa los hoyos y tumba carros")
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("CÓMO SE JUEGA")
                    .font(.display(30)).tracking(3)
                    .foregroundStyle(.white)
                SignRule(color: .neonGold, width: 150).padding(.top, 4)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(rows, id: \.1) { row in
                        HStack(spacing: 11) {
                            Image(systemName: row.0)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.neonTeal)
                                .frame(width: 20)
                            Text(row.1)
                                .font(.label(12)).tracking(2)
                                .foregroundStyle(.white)
                                .frame(width: 54, alignment: .leading)
                            Text(row.2)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.creamText.opacity(0.85))
                        }
                    }
                }
                .padding(.top, 16)

                SignButton("DALE") { state.dismissHowTo() }
                    .padding(.top, 20)
            }
            .padding(.vertical, 24).padding(.horizontal, 34)
            .background(Color(red: 0.07, green: 0.03, blue: 0.13).opacity(0.94),
                        in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.12), lineWidth: 1))
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

    private var medalColor: Color {
        switch state.statMedal {
        case .gold:   return .neonGold
        case .silver: return Color(white: 0.84)
        case .bronze: return Color(red: 0.80, green: 0.52, blue: 0.26)
        case .none:   return .clear
        }
    }
    private var accent: Color { state.statFinished ? .neonTeal : .neonPink }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(red: 0.06, green: 0.02, blue: 0.12).opacity(0.78),
                                    Color(red: 0.05, green: 0.02, blue: 0.10).opacity(0.95)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
                .ignoresSafeArea()

            HStack(alignment: .bottom, spacing: 40) {
                // left: outcome + the numbers, as a results slip
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.display(52))
                        .foregroundStyle(.white)
                        .shadow(color: accent.opacity(0.5), radius: 18)
                    SignRule(color: accent, width: 170)
                        .padding(.top, 3)
                    Text(subtitle)
                        .font(.label(11)).tracking(3)
                        .foregroundStyle(Color.creamText.opacity(0.85))
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 5) {
                        if state.mode == .endless {
                            StatLine(label: "VUELTAS", value: "\(state.statLaps)")
                        }
                        StatLine(label: "TIEMPO", value: state.statTime)
                        // Only when it paid — a "+0" every run teaches nothing and
                        // reads as a penalty for finishing.
                        if state.statTimeBonus > 0 {
                            StatLine(label: "BONO",
                                     value: "+\(state.statTimeBonus.formatted())",
                                     accent: Color.neonGold)
                        }
                        StatLine(label: "PUNTOS", value: state.statScore.formatted())
                        StatLine(label: "MÁXIMA", value: "\(state.statTopSpeed) km/h")
                        StatLine(label: "HOYOS / ESQUIVES",
                                 value: "\(state.statHolesHit) / \(state.statNearMisses)",
                                 accent: Color.creamText)
                    }
                    .padding(.top, 14)

                    HStack(spacing: 10) {
                        SignButton("OTRA VEZ", color: accent) {
                            state.requestReset = true
                        }
                        GhostButton("AL INICIO") {
                            state.requestTitle = true
                        }
                    }
                    .padding(.top, 18)
                }

                // right: route shield, medal stamp, and anything newly earned
                VStack(alignment: .leading, spacing: 12) {
                    RouteShield(route: state.loadedStage.route)

                    if state.mode == .race,
                       let up = Medal.next(after: state.statScore, on: state.loadedStage) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("PA' \(up.medal.label)")
                                .font(.label(9)).tracking(3)
                                .foregroundStyle(.white.opacity(0.4))
                            Text("+\(up.needed.formatted())")
                                .font(.data(15))
                                .foregroundStyle(Color.creamText.opacity(0.9))
                        }
                    }

                    if state.statMedal != .none {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("MEDALLA")
                                .font(.label(9)).tracking(3)
                                .foregroundStyle(.white.opacity(0.4))
                            Text(state.statMedal.label)
                                .font(.display(26)).tracking(1)
                                .foregroundStyle(medalColor)
                        }
                    }

                    if state.newRecordScore || state.newRecordTime {
                        VStack(alignment: .leading, spacing: 1) {
                            if state.newRecordScore {
                                Text("RÉCORD DE PUNTOS")
                                    .font(.system(size: 9, weight: .heavy)).tracking(2)
                            }
                            if state.newRecordTime {
                                Text("MEJOR TIEMPO")
                                    .font(.system(size: 9, weight: .heavy)).tracking(2)
                            }
                        }
                        .foregroundStyle(Color.neonGold)
                    }

                    if let opened = state.unlockedStage {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NUEVA RUTA")
                                .font(.label(9)).tracking(3)
                                .foregroundStyle(.white.opacity(0.4))
                            HStack(spacing: 7) {
                                RouteShield(route: opened.route, compact: true)
                                Text(opened.name)
                                    .font(.display(15))
                                    .foregroundStyle(Color.neonTeal)
                            }
                        }
                    }

                    Text(verbatim: "PISTA #\(state.statSeed % 100000)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.bottom, 4)
            }
            .padding(.leading, 34)
            .padding(.bottom, 26)
        }
    }
}
