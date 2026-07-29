import CoreHaptics
import UIKit

/// Haptics with a Core Haptics fast path and a prepared-UIKit fallback.
///
/// The old code built a fresh `UIImpactFeedbackGenerator` per hit, which pays
/// the actuator warm-up cost every time and lands late. Here the engine (or the
/// generators) stay warm, and calls are serialized off the render thread.
final class Haptics {
    static let shared = Haptics()

    private var engine: CHHapticEngine?
    private let queue = DispatchQueue(label: "hoyo.haptics", qos: .userInitiated)
    private var supportsCore = false

    // fallback generators, kept warm
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)

    private init() {}

    func prepare() {
        supportsCore = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        if supportsCore {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let e = try CHHapticEngine()
                    // The engine can be torn down by the system (backgrounding,
                    // audio session churn); bring it back rather than going silent.
                    e.stoppedHandler = { [weak self] _ in self?.restart() }
                    e.resetHandler = { [weak self] in self?.restart() }
                    try e.start()
                    self.engine = e
                } catch {
                    self.supportsCore = false
                }
            }
        }
        DispatchQueue.main.async {
            self.light.prepare(); self.medium.prepare(); self.heavy.prepare()
        }
    }

    private func restart() {
        queue.async { [weak self] in
            try? self?.engine?.start()
        }
    }

    /// A single tap. `intensity` and `sharpness` are 0…1.
    func tap(intensity: Float, sharpness: Float) {
        guard supportsCore, engine != nil else {
            fallback(intensity: intensity)
            return
        }
        play(events: [transient(at: 0, intensity: intensity, sharpness: sharpness)])
    }

    /// A heavier two-stage thud for pothole / traffic impacts.
    func crash(intensity: Float) {
        guard supportsCore, engine != nil else {
            fallback(intensity: intensity)
            return
        }
        play(events: [
            transient(at: 0, intensity: intensity, sharpness: 0.85),
            transient(at: 0.07, intensity: intensity * 0.6, sharpness: 0.3)
        ])
    }

    /// Short continuous buzz — used for running off the asphalt.
    func rumble(duration: TimeInterval, intensity: Float) {
        guard supportsCore, engine != nil else { return }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            .init(parameterID: .hapticIntensity, value: intensity),
            .init(parameterID: .hapticSharpness, value: 0.2)
        ], relativeTime: 0, duration: duration)
        play(events: [event])
    }

    private func transient(at t: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            .init(parameterID: .hapticIntensity, value: max(0, min(1, intensity))),
            .init(parameterID: .hapticSharpness, value: max(0, min(1, sharpness)))
        ], relativeTime: t)
    }

    private func play(events: [CHHapticEvent]) {
        queue.async { [weak self] in
            guard let engine = self?.engine else { return }
            do {
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                // a dropped haptic is not worth reporting
            }
        }
    }

    private func fallback(intensity: Float) {
        DispatchQueue.main.async {
            if intensity > 0.7 { self.heavy.impactOccurred() }
            else if intensity > 0.4 { self.medium.impactOccurred() }
            else { self.light.impactOccurred() }
        }
    }
}
