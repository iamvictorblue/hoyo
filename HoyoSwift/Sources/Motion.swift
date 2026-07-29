import CoreMotion
import UIKit

/// Device-roll steering for `SteerMode.tilt`.
///
/// Held in landscape the device's long axis (y) is horizontal, so gravity rests
/// along ±x and steering-wheel roll shows up as `gravity.y`. Which landscape
/// we're in flips the sign, and everyone's idea of neutral differs, so the
/// baseline is captured when a run starts and an invert toggle is exposed.
final class TiltReader {
    private let manager = CMMotionManager()
    private var baseline: Double = 0
    private var haveBaseline = false
    private var sign: Double = 1

    /// Latest steering value, -1…1.
    private(set) var steer: Float = 0

    /// Written directly at the motion update rate — polling this from
    /// `updateUIView` would only sample it when SwiftUI happened to re-render.
    private weak var input: GameInput?

    var invert = UserDefaults.standard.bool(forKey: "hoyo_tiltInvert") {
        didSet { UserDefaults.standard.set(invert, forKey: "hoyo_tiltInvert") }
    }

    func attach(_ input: GameInput) { self.input = input }

    /// Degrees of roll that map to full lock.
    private let fullLockRadians = 0.42      // ~24°
    private let deadZone = 0.035

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        refreshSign()
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            if !self.haveBaseline {
                self.baseline = g.y
                self.haveBaseline = true
            }
            var raw = (g.y - self.baseline) * self.sign
            if self.invert { raw = -raw }
            let mag = abs(raw)
            guard mag > self.deadZone else { self.setSteer(0); return }
            // rescale past the dead zone so the stick doesn't jump on entry
            let scaled = (mag - self.deadZone) / (self.fullLockRadians - self.deadZone)
            self.setSteer(Float(min(1, max(0, scaled))) * (raw < 0 ? -1 : 1))
        }
    }

    private func setSteer(_ value: Float) {
        steer = value
        input?.steer = value
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        setSteer(0)
    }

    /// Re-zero on the player's current hold. Called when a run starts.
    func recalibrate() {
        haveBaseline = false
        steer = 0
        refreshSign()
    }

    private func refreshSign() {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .landscapeLeft
        sign = orientation == .landscapeRight ? -1 : 1
    }
}
