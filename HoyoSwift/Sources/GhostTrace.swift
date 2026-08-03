import Foundation
import simd

/// Encoding for the ghost's recorded path — one `SIMD3<Float>` of
/// `(distance, lateral offset, height)` per `GameScene.ghostStep` of race time.
///
/// Pulled out of `GameScene` so it can be tested. It is the only part of the game
/// that persists binary data, so a mistake here is not a visual glitch: it is a
/// corrupt or crashing read of something written by an earlier build.
enum GhostTrace {
    /// 16 on every Apple platform — `SIMD3<Float>` is 12 bytes of data padded to a
    /// 16-byte stride. `Data(buffer:)` writes strides, not sizes, so encode and
    /// decode must agree on this or every sample after the first is misread.
    static let stride = MemoryLayout<SIMD3<Float>>.stride

    static func encode(_ samples: [SIMD3<Float>]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Returns nil rather than a partial trace when the blob is not a whole number
    /// of samples — a truncated write, or a blob from a build that stored something
    /// else. Copies into a fresh array instead of binding memory in place: `Data`
    /// from `UserDefaults` carries no alignment guarantee, and `SIMD3<Float>` wants
    /// 16-byte alignment.
    static func decode(_ data: Data) -> [SIMD3<Float>]? {
        guard !data.isEmpty, data.count % stride == 0 else { return nil }
        var out = [SIMD3<Float>](repeating: .zero, count: data.count / stride)
        let copied: Int = out.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst)
        }
        guard copied == data.count else { return nil }
        return out
    }
}
