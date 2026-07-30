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

    private var coquiBuffer: AVAudioPCMBuffer?
    private var thunkBuffer: AVAudioPCMBuffer?
    private var hornBuffer: AVAudioPCMBuffer?
    private var beepBuffer: AVAudioPCMBuffer?
    private var beepHiBuffer: AVAudioPCMBuffer?
    private var jumpBuffer: AVAudioPCMBuffer?
    private var zapBuffer: AVAudioPCMBuffer?

    func start() {
        guard !started else { return }
        started = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}

        sampleRate = 44100
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)

        var phase1 = 0.0, phase2 = 0.0, rumblePhase = 0.0
        var lpEngine = 0.0, lpWind = 0.0, bpSkid = 0.0, lastNoise = 0.0
        var lpRumble = 0.0
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

                let sample = lpEngine * eLvl + lpWind * wLvl * 2.2
                           + skid * sLvl + hp * nLvl
                           + lpRumble * rLvl * chop * 3.0
                buf[frame] = Float(max(-1, min(1, sample)))
            }
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.attach(musicPlayer)
        engine.attach(fxPlayer)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(musicPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(fxPlayer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9

        coquiBuffer = renderCoqui()
        thunkBuffer = renderThunk()
        hornBuffer = renderHorn()
        beepBuffer = renderBeep(freq: 850, dur: 0.12)
        beepHiBuffer = renderBeep(freq: 1420, dur: 0.3)
        jumpBuffer = renderJump()
        zapBuffer = renderZap()
        let bar = renderDembowBar()

        do {
            try engine.start()
            musicPlayer.volume = 0.28
            fxPlayer.volume = 1.0
            if let bar = bar {
                musicPlayer.scheduleBuffer(bar, at: nil, options: .loops)
                musicPlayer.play()
            }
            fxPlayer.play()
        } catch {}
    }

    func setMusic(on: Bool) {
        musicPlayer.volume = on ? 0.28 : 0
    }

    func playCoqui() { if let b = coquiBuffer { fxPlayer.scheduleBuffer(b) } }
    func playThunk() { if let b = thunkBuffer { fxPlayer.scheduleBuffer(b) } }
    func playHorn()  { if let b = hornBuffer { fxPlayer.scheduleBuffer(b) } }
    func playJump()  { if let b = jumpBuffer { fxPlayer.scheduleBuffer(b) } }
    func playZap()   { if let b = zapBuffer { fxPlayer.scheduleBuffer(b) } }
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

    /// One bar of dembow at 108 BPM: kick + bass on 0/4/8/12,
    /// snares on 3/6/11/14, hats on the offbeats.
    private func renderDembowBar() -> AVAudioPCMBuffer? {
        let stepDur = 60.0 / 108.0 / 4.0
        let barDur = stepDur * 16
        guard let (buf, d, n) = makeBuffer(seconds: barDur) else { return nil }
        let bass: [Double] = [55, 55, 65.41, 49]
        var rng = SystemRandomNumberGenerator()

        for (k, step) in [0, 4, 8, 12].enumerated() {
            let t0 = Double(step) * stepDur
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
                d[i] += Float(s * env * 0.22)
            }
        }
        for step in [3, 6, 11, 14] {
            let i0 = Int(Double(step) * stepDur * sampleRate)
            var bp = 0.0
            for j in 0..<Int(0.11 * sampleRate) {
                let i = i0 + j
                if i >= n { break }
                let t = Double(j) / sampleRate
                let env = max(0, 1 - t / 0.11)
                let noise = Double.random(in: -1...1, using: &rng)
                bp += 0.3 * (noise - bp)
                d[i] += Float(((noise - bp) * 0.5 + sin(2 * .pi * 210 * t) * 0.35) * env * env * 0.45)
            }
        }
        for step in [2, 6, 10, 14] {
            let i0 = Int(Double(step) * stepDur * sampleRate)
            var last = 0.0
            for j in 0..<Int(0.04 * sampleRate) {
                let i = i0 + j
                if i >= n { break }
                let t = Double(j) / sampleRate
                let env = max(0, 1 - t / 0.04)
                let noise = Double.random(in: -1...1, using: &rng)
                d[i] += Float((noise - last) * env * 0.12)
                last = noise
            }
        }
        return buf
    }
}
