import AVFoundation
import Combine

/// All audio is synthesized — no assets. A source node runs the continuous
/// engine + wind + skid layers; the dembow beat is rendered once into a PCM
/// buffer and looped; one-shot effects are pre-rendered buffers.
/// (ObservableObject only so SwiftUI keeps a single instance via @StateObject.)
final class SoundEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let musicPlayer = AVAudioPlayerNode()
    private let fxPlayer = AVAudioPlayerNode()
    private let ambientPlayer = AVAudioPlayerNode()
    private var sourceNode: AVAudioSourceNode?
    private var format: AVAudioFormat!
    private var sampleRate: Double = 44100
    private var started = false

    // written from the render/game loop, read on the audio thread.
    // (benign data race on aligned doubles — arcade audio, not a bank ledger)
    var engineFreq: Double = 55
    var engineLevel: Double = 0
    var windLevel: Double = 0
    var skidLevel: Double = 0
    var nitroLevel: Double = 0
    /// Rumble-strip / off-asphalt buzz: lowpassed noise gated at ~34 Hz.
    var rumbleLevel: Double = 0
    /// Canopy bed for El Yunque: fine highpassed hiss, like leaves and light rain.
    var forestLevel: Double = 0
    /// Shore bed for Isla Verde: lowpassed noise breathing on a ~9 s swell.
    var surfLevel: Double = 0

    private var coquiBuffer: AVAudioPCMBuffer?
    private var thunkBuffer: AVAudioPCMBuffer?
    private var hornBuffer: AVAudioPCMBuffer?
    private var beepBuffer: AVAudioPCMBuffer?
    private var beepHiBuffer: AVAudioPCMBuffer?
    private var jumpBuffer: AVAudioPCMBuffer?
    private var zapBuffer: AVAudioPCMBuffer?
    private var floatBuffer: AVAudioPCMBuffer?
    private var sirenBuffer: AVAudioPCMBuffer?
    private var thunderBuffer: AVAudioPCMBuffer?
    private var cordilleraPhrase: AVAudioPCMBuffer?
    private var stagePhrases: [Int: AVAudioPCMBuffer] = [:]
    private var loadedPhrase: Stage?

    /// Optional real music, one loop per course, played instead of the synth phrase
    /// when the file is present. Its own node and its own stereo connection: the rest
    /// of the engine runs mono at 44.1k, and downmixing a music bed to mono to fit
    /// that would throw away the one thing a written track has over a rendered one.
    private let trackPlayer = AVAudioPlayerNode()
    private var trackFormat: AVAudioFormat!
    private var trackCache: [Int: AVAudioPCMBuffer] = [:]
    private var loadedTrack: Stage?
    private var musicOn = true

    /// Louder than the synth phrase's 0.28, because a mastered track sits at a much
    /// lower peak-to-average than four bars of synthesized dembow. This is the dial to
    /// turn if music fights the engine — the engine already owns the low end.
    private static let trackVolume: Float = 0.34

    /// Swaps the groove and the ambient bed to match the course. Phrases are
    /// rendered on first use and kept — each is a couple of seconds of PCM.
    func setStage(_ stage: Stage) {
        guard started else { return }
        // A written loop wins if one shipped for this course.
        if loadedTrack == stage { return }
        if startTrack(for: stage) { return }
        guard loadedPhrase != stage else { return }
        loadedTrack = nil
        trackPlayer.stop()
        loadedPhrase = stage
        let buf: AVAudioPCMBuffer?
        if stage == .cordillera {
            buf = cordilleraPhrase
        } else if let cached = stagePhrases[stage.rawValue] {
            buf = cached
        } else {
            let made = renderPhrase(for: stage)
            if let made { stagePhrases[stage.rawValue] = made }
            buf = made
        }
        guard let buf else { return }
        musicPlayer.stop()
        musicPlayer.scheduleBuffer(buf, at: nil, options: .loops)
        musicPlayer.play()
    }

    // MARK: - optional written music

    /// Bundle filename stem for a course's music, e.g. `music-yunque`.
    ///
    /// Deliberately not derived from `Stage.name`, which is display text ("EL YUNQUE")
    /// and is free to change with the Spanish without anyone thinking about filenames.
    private func trackStem(_ stage: Stage) -> String {
        switch stage {
        case .cordillera: return "music-cordillera"
        case .yunque:     return "music-yunque"
        case .playa:      return "music-playa"
        }
    }

    /// Reads a bundled loop for the course, or nil if none shipped.
    ///
    /// Prefers uncompressed. AAC and MP3 both prepend encoder padding, and a
    /// sample-exact loop with a few thousand samples of silence welded to the front
    /// audibly hiccups on every repeat — which is the one thing a driving game's
    /// backing loop cannot do. WAV and AIFF have no such priming.
    private func loadTrack(for stage: Stage) -> AVAudioPCMBuffer? {
        let stem = trackStem(stage)
        for ext in ["wav", "aiff", "aif", "caf", "m4a", "mp3"] {
            guard let url = Bundle.main.url(forResource: stem, withExtension: ext) else { continue }
            if let buf = readLoop(url) { return buf }
        }
        return nil
    }

    /// Decodes a file into the track node's own stereo format.
    ///
    /// The conversion is not optional. A file is whatever the person who made it
    /// exported — 48k, or mono, or 24-bit — and `AVAudioPlayerNode` will only play
    /// buffers matching the format its connection was made with. Without this step a
    /// 48k export simply fails to schedule, silently.
    private func readLoop(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)
        else { return nil }
        do { try file.read(into: input) } catch { return nil }

        if inFormat.sampleRate == trackFormat.sampleRate,
           inFormat.channelCount == trackFormat.channelCount,
           inFormat.commonFormat == trackFormat.commonFormat {
            return input
        }
        guard let converter = AVAudioConverter(from: inFormat, to: trackFormat) else { return nil }
        // Round up, and leave slack: resampling 48k to 44.1k is not an integer ratio and
        // a capacity computed exactly will drop the tail, which is precisely the sample
        // a seamless loop needs.
        let ratio = trackFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: trackFormat, frameCapacity: capacity)
        else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Starts the written loop for a course, if there is one. Returns whether it did,
    /// so callers can fall back to the synth phrase.
    @discardableResult
    private func startTrack(for stage: Stage) -> Bool {
        let buf: AVAudioPCMBuffer?
        if let cached = trackCache[stage.rawValue] {
            buf = cached
        } else if let loaded = loadTrack(for: stage) {
            trackCache[stage.rawValue] = loaded
            buf = loaded
        } else {
            buf = nil
        }
        guard let buf else { return false }
        loadedTrack = stage
        // The synth groove and the written track are alternatives, never a layer.
        musicPlayer.stop()
        loadedPhrase = nil
        trackPlayer.stop()
        trackPlayer.scheduleBuffer(buf, at: nil, options: .loops)
        trackPlayer.volume = musicOn ? Self.trackVolume : 0
        trackPlayer.play()
        return true
    }

    /// A call, an alarm or Siri deactivates the session. Without this the engine
    /// stays silent for the rest of the run — the game keeps playing, mute.
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.engine.pause()
            case .ended:
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try self.engine.start()
                } catch {}
            @unknown default:
                break
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        // `.playback`, not `.ambient`. Under `.ambient` the hardware mute switch
        // silences everything, and this game's entire soundscape — engine, wind,
        // surf, the music phrases — is synthesised at runtime rather than being
        // incidental decoration. A player who flips the switch by habit was getting
        // a silent game with no way to tell why.
        //
        // The trade is that it now interrupts whatever else was playing, which is
        // the normal bargain for a game with real audio.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
        observeInterruptions()

        sampleRate = 44100
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)

        var phase1 = 0.0, phase2 = 0.0, rumblePhase = 0.0
        var lpEngine = 0.0, lpWind = 0.0, bpSkid = 0.0, lastNoise = 0.0
        var lpRumble = 0.0
        var lpSurf = 0.0, hpForest = 0.0, lastForest = 0.0, surfPhase = 0.0
        var rng = SystemRandomNumberGenerator()

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buf = ablPointer.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let f1 = self.engineFreq / self.sampleRate
            let f2 = (self.engineFreq * 1.007 + 3) / self.sampleRate
            let eLvl = self.engineLevel, wLvl = self.windLevel
            let sLvl = self.skidLevel, nLvl = self.nitroLevel
            let rLvl = self.rumbleLevel
            let fLvl = self.forestLevel, suLvl = self.surfLevel
            let surfStep = 1.0 / (9.0 * self.sampleRate)
            let rumbleStep = 34.0 / self.sampleRate
            for frame in 0..<Int(frameCount) {
                phase1 += f1; if phase1 >= 1 { phase1 -= 1 }
                phase2 += f2; if phase2 >= 1 { phase2 -= 1 }
                let saw = (phase1 * 2 - 1) + (phase2 * 2 - 1)
                lpEngine += 0.09 * (saw - lpEngine)              // ~600 Hz one-pole

                let noise = Double.random(in: -1...1, using: &rng)
                lpWind += 0.03 * (noise - lpWind)                 // rumbly wind
                let hp = noise - lastNoise                        // crude highpass hiss
                lastNoise = noise
                bpSkid += 0.25 * (noise - bpSkid)
                let skid = (noise - bpSkid)                       // mid-band screech

                // rumble strips: heavy lowpassed noise chopped by a slow square,
                // which is what makes it read as ridges rather than static
                lpRumble += 0.055 * (noise - lpRumble)
                rumblePhase += rumbleStep; if rumblePhase >= 1 { rumblePhase -= 1 }
                let chop = rumblePhase < 0.55 ? 1.0 : 0.25

                // canopy: bright hiss, no low end
                hpForest = noise - lastForest
                lastForest = noise
                // shore: dark noise on a slow swell, so it breathes rather than sits
                lpSurf += 0.012 * (noise - lpSurf)
                surfPhase += surfStep; if surfPhase >= 1 { surfPhase -= 1 }
                let swell = 0.45 + 0.55 * pow(0.5 + 0.5 * sin(2 * .pi * surfPhase), 2)

                let sample = lpEngine * eLvl + lpWind * wLvl * 2.2
                           + skid * sLvl + hp * nLvl
                           + lpRumble * rLvl * chop * 3.0
                           + hpForest * fLvl * 0.5
                           + lpSurf * suLvl * swell * 5.0
                buf[frame] = Float(max(-1, min(1, sample)))
            }
            return noErr
        }
        sourceNode = node

        trackFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)

        engine.attach(node)
        engine.attach(trackPlayer)
        engine.attach(musicPlayer)
        engine.attach(fxPlayer)
        engine.attach(ambientPlayer)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(musicPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(trackPlayer, to: engine.mainMixerNode, format: trackFormat)
        engine.connect(fxPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(ambientPlayer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9

        coquiBuffer = renderCoqui()
        thunkBuffer = renderThunk()
        hornBuffer = renderHorn()
        beepBuffer = renderBeep(freq: 850, dur: 0.12)
        beepHiBuffer = renderBeep(freq: 1420, dur: 0.3)
        jumpBuffer = renderJump()
        zapBuffer = renderZap()
        floatBuffer = renderFloat()
        sirenBuffer = renderSiren()
        thunderBuffer = renderThunder()
        cordilleraPhrase = renderPhrase(for: .cordillera)

        do {
            try engine.start()
            musicPlayer.volume = 0.28
            fxPlayer.volume = 1.0
            if let bar = cordilleraPhrase {
                musicPlayer.scheduleBuffer(bar, at: nil, options: .loops)
                musicPlayer.play()
                loadedPhrase = .cordillera
            }
            // Then hand over to a real track if one shipped. Done in this order rather
            // than instead of the above so a missing or unreadable file degrades to the
            // synth groove rather than to silence.
            startTrack(for: .cordillera)
            fxPlayer.volume = 1.0
            ambientPlayer.volume = 0.22
            fxPlayer.play()
            ambientPlayer.play()
        } catch {}
    }

    func setMusic(on: Bool) {
        musicOn = on
        musicPlayer.volume = on ? 0.28 : 0
        trackPlayer.volume = on ? Self.trackVolume : 0
    }

    func playCoqui() { if let b = coquiBuffer { fxPlayer.scheduleBuffer(b) } }
    /// Same chirp, played low in the mix as atmosphere rather than as feedback.
    func playCoquiAmbient() { if let b = coquiBuffer { ambientPlayer.scheduleBuffer(b) } }
    func playThunk() { if let b = thunkBuffer { fxPlayer.scheduleBuffer(b) } }
    func playHorn()  { if let b = hornBuffer { fxPlayer.scheduleBuffer(b) } }
    func playJump()  { if let b = jumpBuffer { fxPlayer.scheduleBuffer(b) } }
    func playZap()   { if let b = zapBuffer { fxPlayer.scheduleBuffer(b) } }
    func playFloat() { if let b = floatBuffer { fxPlayer.scheduleBuffer(b) } }
    func playSiren() { if let b = sirenBuffer { fxPlayer.scheduleBuffer(b) } }
    /// Distant thunder over El Yunque. Played on the ambient bed rather than the effects
    /// player: it is weather, not feedback, and it should not duck a hit or a pickup.
    func playThunder() { if let b = thunderBuffer { ambientPlayer.scheduleBuffer(b) } }
    func playBeep(final: Bool) {
        if let b = final ? beepHiBuffer : beepBuffer { fxPlayer.scheduleBuffer(b) }
    }

    // MARK: - offline synthesis

    private func makeBuffer(seconds: Double) -> (AVAudioPCMBuffer, UnsafeMutablePointer<Float>, Int)? {
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        for i in 0..<Int(frames) { data[i] = 0 }
        return (buf, data, Int(frames))
    }

    /// The coquí's two-note "ko-KEE" as exponential sine sweeps.
    private func renderCoqui() -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: 0.45) else { return nil }
        addSweep(d, n, start: 0.02, dur: 0.11, f0: 880, f1: 1350, amp: 0.16)
        addSweep(d, n, start: 0.19, dur: 0.18, f0: 1400, f1: 2350, amp: 0.16)
        return buf
    }

    private func renderThunk() -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: 0.3) else { return nil }
        addSweep(d, n, start: 0, dur: 0.2, f0: 95, f1: 30, amp: 0.55)
        var lp = 0.0
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = max(0, 1 - t / 0.24)
            lp += 0.05 * (Double.random(in: -1...1, using: &rng) - lp)
            d[i] += Float(lp * env * env * 0.9)
        }
        return buf
    }

    /// Distant thunder: a long, soft-edged roll rather than a crack.
    ///
    /// A nearby strike is a sharp transient, and that is the wrong sound here — the
    /// lightning is somewhere over the ridge, not on the trail, so what reaches you is
    /// low-passed noise with a slow attack and a very long tail. Two decaying rumbles
    /// slightly apart, because real thunder arrives as overlapping reflections off the
    /// terrain and a single envelope reads as a wave breaking.
    private func renderThunder() -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: 2.6) else { return nil }
        var lp1 = 0.0, lp2 = 0.0
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let noise = Double.random(in: -1...1, using: &rng)
            // two one-pole lowpasses in series: a single pass still passes enough high
            // end to sound like static rather than distance
            lp1 += 0.010 * (noise - lp1)
            lp2 += 0.016 * (lp1 - lp2)
            // slow swell in, long decay out, and a second roll behind the first
            let swell = min(1, t / 0.28)
            let body = exp(-t * 1.5)
            let echo = t > 0.55 ? exp(-(t - 0.55) * 1.1) * 0.55 : 0
            d[i] += Float(lp2 * swell * (body + echo) * 9.0)
        }
        return buf
    }

    private func renderBeep(freq: Double, dur: Double) -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: dur + 0.02) else { return nil }
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = max(0, 1 - t / dur)
            let sq: Double = sin(2 * .pi * freq * t) > 0 ? 1 : -1
            d[i] = Float(sq * env * 0.09)
        }
        return buf
    }

    /// Suspension unloading: a rising filtered-noise whoosh with a soft thump
    /// under it, so the hop has some weight rather than sounding like a chirp.
    private func renderJump() -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: 0.3) else { return nil }
        addSweep(d, n, start: 0, dur: 0.16, f0: 150, f1: 520, amp: 0.20)
        var bp = 0.0
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = max(0, 1 - t / 0.22)
            let noise = Double.random(in: -1...1, using: &rng)
            // sweep the band upward over the hop
            bp += (0.10 + t * 0.9) * (noise - bp)
            d[i] += Float(bp * env * env * 0.5)
        }
        return buf
    }

    /// Beam shot: a fast falling sweep with a short bright click on the front, so
    /// it cuts through the engine layer without needing much level.
    private func renderZap() -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: 0.2) else { return nil }
        addSweep(d, n, start: 0, dur: 0.13, f0: 1750, f1: 260, amp: 0.13)
        var rng = SystemRandomNumberGenerator()
        var last = 0.0
        for i in 0..<min(n, Int(0.03 * sampleRate)) {
            let t = Double(i) / sampleRate
            let env = max(0, 1 - t / 0.03)
            let noise = Double.random(in: -1...1, using: &rng)
            d[i] += Float((noise - last) * env * env * 0.10)
            last = noise
        }
        return buf
    }

    /// Antigravity: a long rising sweep with a shimmer over it, so the third hop is
    /// audibly a different event from the two that set it up.
    private func renderFloat() -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: 1.1) else { return nil }
        addSweep(d, n, start: 0, dur: 0.9, f0: 110, f1: 880, amp: 0.16)
        addSweep(d, n, start: 0.06, dur: 0.85, f0: 165, f1: 1320, amp: 0.09)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = min(t / 0.1, 1) * max(0, 1 - t / 1.1)
            // slow tremolo on top of the sweep
            d[i] += Float(sin(2 * .pi * 1760 * t) * sin(2 * .pi * 7 * t) * env * 0.035)
        }
        return buf
    }

    /// Two-tone wail. Deliberately not a loop: it announces the cruiser arriving
    /// and then gets out of the way of the engine bed.
    private func renderSiren() -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: 1.6) else { return nil }
        for i in 0..<n {
            let t = Double(i) / sampleRate
            // alternates roughly three times across the buffer
            let hi = Int(t / 0.26) % 2 == 0
            let f = hi ? 780.0 : 580.0
            let env = min(t / 0.05, 1) * max(0, 1 - t / 1.6)
            var v = sin(2 * .pi * f * t) * 0.10
            v += sin(2 * .pi * f * 2 * t) * 0.035     // a little grit
            d[i] += Float(v * env)
        }
        return buf
    }

    private func renderHorn() -> AVAudioPCMBuffer? {
        guard let (buf, d, n) = makeBuffer(seconds: 0.26) else { return nil }
        for freq in [392.0, 494.0] {
            for i in 0..<n {
                let t = Double(i) / sampleRate
                let env = t < 0.2 ? 1.0 : max(0, 1 - (t - 0.2) / 0.06)
                let sq: Double = sin(2 * .pi * freq * t) > 0 ? 1 : -1
                d[i] += Float(sq * env * 0.05)
            }
        }
        return buf
    }

    private func addSweep(_ d: UnsafeMutablePointer<Float>, _ n: Int,
                          start: Double, dur: Double, f0: Double, f1: Double, amp: Double) {
        let i0 = Int(start * sampleRate)
        let count = Int(dur * sampleRate)
        var phase = 0.0
        for k in 0..<count {
            let i = i0 + k
            if i >= n { break }
            let u = Double(k) / Double(count)
            let f = f0 * pow(f1 / f0, u)
            phase += f / sampleRate
            let env = min(u / 0.15, 1) * (1 - u)
            d[i] += Float(sin(2 * .pi * phase) * env * amp)
        }
    }

    /// Four bars of dembow at 108 BPM rather than one. A single looping bar is the
    /// most fatiguing thing you can put under a game — the bass walks across the
    /// phrase and the last bar carries a snare fill, so it breathes.
    /// One looping phrase per course.
    ///
    /// Guajataca keeps the dembow the game shipped with. El Yunque drops the tempo
    /// and most of the kicks and hands the groove to wood and shaker, so it reads as
    /// something played rather than programmed. Isla Verde lifts the tempo, thins the
    /// low end and puts the weight on offbeats.
    private func renderPhrase(for stage: Stage) -> AVAudioPCMBuffer? {
        let bpm: Double
        switch stage {
        case .cordillera: bpm = 108
        case .yunque:     bpm = 96
        case .playa:      bpm = 116
        }
        let stepDur = 60.0 / bpm / 4.0
        let bars = 4
        let barDur = stepDur * 16
        guard let (buf, d, n) = makeBuffer(seconds: barDur * Double(bars)) else { return nil }
        // a walking bass line across the phrase instead of the same four notes
        var bassLine: [[Double]] = [
            [55, 55, 65.41, 49],
            [55, 55, 73.42, 49],
            [49, 49, 65.41, 58.27],
            [55, 65.41, 73.42, 82.41]
        ]
        // the beach sits a fifth up and lighter; the forest drops and simplifies
        if stage == .playa {
            bassLine = bassLine.map { $0.map { $0 * 1.5 } }
        } else if stage == .yunque {
            bassLine = [[49, 49, 55, 49], [49, 49, 58.27, 49],
                        [43.65, 43.65, 55, 49], [49, 55, 58.27, 49]]
        }
        let kickSteps: [Int]
        let bassAmp: Double
        switch stage {
        case .cordillera: kickSteps = [0, 4, 8, 12]; bassAmp = 0.22
        case .yunque:     kickSteps = [0, 8];        bassAmp = 0.13
        case .playa:      kickSteps = [0, 6, 8];     bassAmp = 0.15
        }
        var rng = SystemRandomNumberGenerator()

        for bar in 0..<bars {
        let barOffset = Double(bar) * barDur
        let bass = bassLine[bar]

        for (k, step) in kickSteps.enumerated() {
            let t0 = barOffset + Double(step) * stepDur
            addSweep(d, n, start: t0, dur: 0.14, f0: 135, f1: 42, amp: 0.8)
            // bass: filtered saw approximated by first 3 harmonics
            let i0 = Int(t0 * sampleRate)
            let count = Int(0.3 * sampleRate)
            let f = bass[k % 4]
            for j in 0..<count {
                let i = i0 + j
                if i >= n { break }
                let t = Double(j) / sampleRate
                let env = min(t / 0.015, 1) * max(0, 1 - t / 0.3)
                var s = 0.0
                for h in 1...3 { s += sin(2 * .pi * f * Double(h) * t) / Double(h) }
                d[i] += Float(s * env * bassAmp)
            }
        }
        // the fourth bar gets extra hits — a turnaround into the next phrase
        var snareSteps = bar == bars - 1 ? [3, 6, 11, 13, 14, 15] : [3, 6, 11, 14]
        if stage == .yunque {
            // busier and syncopated, like hands on a drum rather than a snare
            snareSteps = bar == bars - 1 ? [2, 3, 6, 7, 10, 11, 13, 14, 15]
                                         : [2, 3, 6, 10, 11, 14]
        } else if stage == .playa {
            snareSteps = bar == bars - 1 ? [3, 7, 11, 13, 15] : [3, 7, 11, 15]
        }
        for step in snareSteps {
            let i0 = Int((barOffset + Double(step) * stepDur) * sampleRate)
            var bp = 0.0
            for j in 0..<Int(0.11 * sampleRate) {
                let i = i0 + j
                if i >= n { break }
                let t = Double(j) / sampleRate
                let env = max(0, 1 - t / 0.11)
                let noise = Double.random(in: -1...1, using: &rng)
                bp += 0.3 * (noise - bp)
                switch stage {
                case .yunque:
                    // wood: mostly pitched body, very little noise
                    d[i] += Float(((noise - bp) * 0.16
                                   + sin(2 * .pi * 340 * t) * 0.5
                                   + sin(2 * .pi * 505 * t) * 0.22)
                                  * env * env * 0.34)
                case .playa:
                    // rim/clave: bright and short
                    d[i] += Float(((noise - bp) * 0.28
                                   + sin(2 * .pi * 900 * t) * 0.45)
                                  * env * env * env * 0.30)
                case .cordillera:
                    d[i] += Float(((noise - bp) * 0.5 + sin(2 * .pi * 210 * t) * 0.35)
                                  * env * env * 0.45)
                }
            }
        }
        let hatSteps: [Int]
        switch stage {
        case .cordillera: hatSteps = [2, 6, 10, 14]
        case .yunque:     hatSteps = [1, 3, 5, 7, 9, 11, 13, 15]   // shaker, every off
        case .playa:      hatSteps = [2, 4, 6, 10, 12, 14]
        }
        let hatLen = stage == .yunque ? 0.055 : 0.04
        let hatAmp = stage == .yunque ? 0.075 : (stage == .playa ? 0.10 : 0.12)
        for step in hatSteps {
            let i0 = Int((barOffset + Double(step) * stepDur) * sampleRate)
            var last = 0.0
            for j in 0..<Int(hatLen * sampleRate) {
                let i = i0 + j
                if i >= n { break }
                let t = Double(j) / sampleRate
                let env = max(0, 1 - t / hatLen)
                let noise = Double.random(in: -1...1, using: &rng)
                d[i] += Float((noise - last) * env * hatAmp)
                last = noise
            }
        }
        }
        return buf
    }
}
