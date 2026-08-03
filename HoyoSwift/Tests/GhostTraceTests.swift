import XCTest
import simd
@testable import Hoyo

/// The ghost trace is the only binary data the game persists. A mistake here is
/// not a visual glitch — it is a corrupt read of something an earlier build wrote,
/// or a crash on someone's saved run.
final class GhostTraceTests: XCTestCase {

    /// `Data(buffer:)` writes *strides*, not sizes. Swift's `SIMD3<Float>` is a
    /// padded four-lane vector, so size and stride are both 16 and there is no gap
    /// between samples — which is exactly why the byte-for-byte round trip below is
    /// exact. Pinned because it is invisible in the source and the encoder would
    /// silently write a different layout if it ever changed: `Data(buffer:)` emits
    /// stride-sized elements, so a 12-byte size would leave a 4-byte hole per
    /// sample and every sample after the first would decode from the wrong offset.
    func testLayoutHasNoPaddingGap() {
        XCTAssertEqual(GhostTrace.stride, 16)
        XCTAssertEqual(MemoryLayout<SIMD3<Float>>.size, MemoryLayout<SIMD3<Float>>.stride,
                       "a size/stride gap would put a hole between serialised samples")
    }

    func testRoundTripIsExact() {
        let samples: [SIMD3<Float>] = (0..<400).map {
            SIMD3(Float($0) * 4.31, sinf(Float($0) * 0.07) * 3.2, Float($0 % 7) * 0.9)
        }
        guard let back = GhostTrace.decode(GhostTrace.encode(samples)) else {
            return XCTFail("a trace this encoder just produced failed to decode")
        }
        XCTAssertEqual(back.count, samples.count)
        for (i, (a, b)) in zip(samples, back).enumerated() {
            XCTAssertEqual(a.x, b.x, "sample \(i) distance drifted")
            XCTAssertEqual(a.y, b.y, "sample \(i) lateral drifted")
            XCTAssertEqual(a.z, b.z, "sample \(i) height drifted")
        }
    }

    /// A run's length in samples must equal its length in ghostStep intervals, or
    /// playback — which indexes on race time — drifts against the recording.
    func testSampleCountMatchesRaceTime() {
        let step = 0.1                     // GameScene.ghostStep
        let seconds = 97.2                 // a real recorded run
        let expected = Int(seconds / step) // 972
        let samples = [SIMD3<Float>](repeating: .zero, count: expected)
        XCTAssertEqual(GhostTrace.encode(samples).count, expected * GhostTrace.stride,
                       "a \(seconds)s run should serialise to \(expected) samples")
    }

    // MARK: - blobs we should refuse

    /// A truncated write, or a blob from a build that stored a different layout.
    /// Returning a partial trace would replay a ghost that silently ends early.
    func testTruncatedBlobIsRejected() {
        let samples: [SIMD3<Float>] = (0..<10).map { SIMD3(Float($0), 0, 0) }
        var data = GhostTrace.encode(samples)
        data.removeLast(5)                 // not a whole number of samples
        XCTAssertNil(GhostTrace.decode(data))
    }

    func testEmptyBlobIsRejected() {
        XCTAssertNil(GhostTrace.decode(Data()))
    }

    /// Anything that happens to be stride-aligned decodes; that is accepted, and
    /// the reason it is safe is that playback clamps. Documented so the next person
    /// knows it is deliberate rather than an oversight.
    func testGarbageThatIsStrideAlignedStillDecodes() {
        let junk = Data(repeating: 0xFF, count: GhostTrace.stride * 3)
        XCTAssertNotNil(GhostTrace.decode(junk),
                        "stride-aligned junk decodes by design — sample() clamps it")
    }

    /// NaN and infinity must survive decode rather than trapping, because
    /// `sample()` clamps them downstream. A trap here would crash on load.
    func testNonFiniteValuesDoNotTrap() {
        let samples: [SIMD3<Float>] = [
            SIMD3(.nan, 0, 0), SIMD3(.infinity, 0, 0), SIMD3(-.infinity, 1, 2)
        ]
        guard let back = GhostTrace.decode(GhostTrace.encode(samples)) else {
            return XCTFail("non-finite samples failed to decode")
        }
        XCTAssertEqual(back.count, 3)
        XCTAssertTrue(back[0].x.isNaN)
        XCTAssertTrue(back[1].x.isInfinite)
    }
}
