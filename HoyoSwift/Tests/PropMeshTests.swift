import XCTest
import SceneKit
import simd
@testable import Hoyo

/// Every test here is a bug that shipped.
///
/// The three geometry ones were all found by the same throwaway script late in
/// review, after the code was already committed — a boulder that stood up, a crown
/// whose rim clamped flat, and a comment full of float64 numbers that described
/// nothing. The flattening one is worse: it removed every palm from every stage and
/// survived several rounds of screenshot checking, because a scene missing its
/// vegetation looks exactly like a frame that never had any in shot.
final class PropMeshTests: XCTestCase {

    private let variants = 0..<4

    // MARK: - boulder

    /// `PropMeshes.boulder` documents "boulders sit — they are wider than they are
    /// tall". The first version did the opposite: ±29% per-vertex jitter swamped an
    /// 8% y-bias and two of the four variants came out taller than wide (measured
    /// 0.69, 1.02, 0.73, 1.01). A comment cannot enforce a shape; this can.
    func testBouldersSitRatherThanStand() {
        for v in variants {
            let s = PropMeshes.boulder(variant: v).size
            let ratio = s.y / max(s.x, s.z)
            XCTAssertLessThan(ratio, 0.95,
                              "boulder variant \(v) is as tall as it is wide (ratio \(ratio)) — "
                              + "it is supposed to sit, not stand")
        }
    }

    /// `rockMat` is single-sided, so one inward-facing triangle is a hole you can see
    /// straight through the rock.
    func testBoulderFacesAllPointOutward() {
        for v in variants {
            let m = PropMeshes.boulder(variant: v)
            let centre = m.verts.reduce(simd_float3.zero, +) / Float(m.verts.count)
            for t in 0..<m.triangleCount {
                let a = m.verts[Int(m.indices[t * 3])]
                XCTAssertGreaterThan(simd_dot(m.faceNormal(t), simd_normalize(a - centre)), 0,
                                     "boulder variant \(v) face \(t) faces inward — "
                                     + "a single-sided material renders that as a hole")
            }
        }
    }

    // MARK: - flamboyán crown

    /// The crown normalises its shading as `(y - rimY) / (apexY - rimY)` and clamps.
    /// `rimY` was -0.34 while the geometry's real minimum runs to about -0.69, so all
    /// sixteen rim vertices of every crown pinned to `lit == 0` and the rim came out
    /// one flat tone — losing exactly the jitter-driven shading the mesh exists for.
    func testCrownRimIsNotClamped() {
        for seed in 0..<5 {
            let m = PropMeshes.flamboyanCrown(seed: seed, tint: simd_float3(1, 0.2, 0.1))
            let lowest = m.verts.map(\.y).min() ?? 0
            XCTAssertGreaterThanOrEqual(
                lowest, PropMeshes.crownRimY,
                "crown seed \(seed) reaches \(lowest), below the shading floor of "
                + "\(PropMeshes.crownRimY) — everything under it clamps to one flat tone")
        }
    }

    /// The apex fan's winding is claimed to produce +y normals for any ring heights,
    /// which matters because ring-1 jitter does push vertices above the apex.
    func testCrownApexFanFacesUp() {
        for seed in 0..<5 {
            let m = PropMeshes.flamboyanCrown(seed: seed, tint: simd_float3(1, 0.2, 0.1))
            for t in 0..<16 {                      // the fan is the first `sides` tris
                XCTAssertGreaterThan(m.faceNormal(t).y, 0,
                                     "crown seed \(seed) apex triangle \(t) faces down")
            }
        }
    }

    // MARK: - palm

    /// A comment once claimed measured frond counts that had been computed in float64.
    /// `sinf(x) * 43758` amplifies the Float/Double gap so far that the two disagree
    /// completely, so the quoted numbers described nothing the app rendered. The point
    /// of the threshold is "one or two brown fronds", not a third of the crown.
    func testMostFrondsAreAlive() {
        for v in 0..<3 {
            let count = PropMeshes.frondCount(variant: v)
            let dead = (0..<count).filter {
                PropMeshes.frondAge(variant: v, frond: $0) > PropMeshes.deadFrondThreshold
            }.count
            XCTAssertGreaterThan(count, 0, "palm variant \(v) has no fronds")
            XCTAssertLessThanOrEqual(dead, 2,
                                     "palm variant \(v) has \(dead) of \(count) fronds brown — "
                                     + "the crown is supposed to be alive")
        }
    }

    func testPalmHasBothHalves() {
        for v in 0..<3 {
            let m = PropMeshes.palm(variant: v)
            XCTAssertFalse(m.trunk.verts.isEmpty, "palm variant \(v) has no trunk")
            XCTAssertFalse(m.fronds.verts.isEmpty, "palm variant \(v) has no fronds")
        }
    }

    // MARK: - the flattening contract

    /// The regression that removed every palm from every stage.
    ///
    /// The trunk and the fronds need different materials — the fronds are ribbons and
    /// must be double-sided, the trunk is a closed tube that should keep backface
    /// culling. Putting both in one node and flattening the container of those nodes
    /// returns a geometry with zero elements, silently, and the whole grove disappears
    /// while the scene graph still looks healthy.
    ///
    /// The flattening itself cannot be asserted here: `flattenedClone()` yields an
    /// empty geometry in any process without a live renderer, including this one, so
    /// even a correct single-material container comes back empty. Verified that the
    /// hard way — the first version of this test failed on the *passing* case. What is
    /// testable is the material count that decides it, which is what the production
    /// code now checks before it flattens anything.
    func testMixedMaterialContainerIsDetectedBeforeFlattening() {
        let mesh = PropMeshes.palm(variant: 0)
        func geometry(_ m: PropMeshes.Mesh, doubleSided: Bool) -> SCNGeometry {
            let mat = SCNMaterial()
            mat.isDoubleSided = doubleSided
            let src = SCNGeometrySource(vertices: m.verts.map { SCNVector3($0) })
            let el = SCNGeometryElement(indices: m.indices, primitiveType: .triangles)
            let g = SCNGeometry(sources: [src], elements: [el])
            g.materials = [mat]
            return g
        }
        let trunk = geometry(mesh.trunk, doubleSided: false)
        let fronds = geometry(mesh.fronds, doubleSided: true)

        // What the game does now: one material per container, safe to flatten.
        let trunks = SCNNode()
        for _ in 0..<8 { trunks.addChildNode(SCNNode(geometry: trunk)) }
        XCTAssertEqual(FlattenGuard.distinctMaterials(in: trunks), 1,
                       "a container of trunks should hold exactly one material")

        // What the game did, and what emptied every grove.
        let mixed = SCNNode()
        for _ in 0..<8 {
            let palm = SCNNode()
            palm.addChildNode(SCNNode(geometry: trunk))
            palm.addChildNode(SCNNode(geometry: fronds))
            mixed.addChildNode(palm)
        }
        XCTAssertEqual(FlattenGuard.distinctMaterials(in: mixed), 2,
                       "the mixed-material arrangement must be detectable — this is the "
                       + "shape that silently deletes the props")
    }

    /// Identity, not equality: SceneKit groups by material object, so two materials
    /// that look the same still defeat flattening.
    func testTwoIdenticalLookingMaterialsStillCountAsTwo() {
        let node = SCNNode()
        for _ in 0..<2 {
            let g = SCNSphere(radius: 1)
            g.materials = [SCNMaterial()]          // fresh object each time
            node.addChildNode(SCNNode(geometry: g))
        }
        XCTAssertEqual(FlattenGuard.distinctMaterials(in: node), 2)
    }
}

/// The wind weights. Every number here is invisible in the running game — a wrong one shows up
/// as foliage that bends slightly oddly, which nobody would ever trace back to arithmetic. That
/// is the exact failure class this file was created for.
final class SwayTests: XCTestCase {

    /// Parity with `verts` is the one that matters most. `makeGeometry` builds a texcoord
    /// source from this array and the shader indexes it per vertex, so a short array is read
    /// off the end.
    func testSwayIsParallelToVerts() {
        let palm = PropMeshes.palm(variant: 0)
        XCTAssertEqual(palm.fronds.sway.count, palm.fronds.verts.count)
        XCTAssertEqual(palm.trunk.sway.count, palm.trunk.verts.count)
        let fern = PropMeshes.treeFern(variant: 0)
        XCTAssertEqual(fern.sway.count, fern.verts.count)
        let crown = PropMeshes.flamboyanCrown(seed: 0, tint: simd_float3(1, 0, 0))
        XCTAssertEqual(crown.sway.count, crown.verts.count)
    }

    /// A palm trunk is a 7 m post. If any of its vertices picked up a weight the whole tree
    /// would lean in the wind, which reads as inflatable rather than windswept.
    func testPalmTrunkIsPinned() {
        for v in 0..<3 {
            let trunk = PropMeshes.palm(variant: v).trunk
            XCTAssertEqual(trunk.sway.max(), 0, "trunk variant \(v) should not bend")
        }
    }

    /// Fronds must reach full weight at the tip and start at zero where they meet the crown.
    /// A non-zero base detaches the frond from the trunk; a tip below 1 wastes the range and
    /// makes the wind constant harder to reason about.
    func testFrondsRunFromPinnedBaseToFreeTip() {
        for v in 0..<3 {
            let f = PropMeshes.palm(variant: v).fronds
            XCTAssertEqual(f.sway.min() ?? -1, 0, accuracy: 1e-6,
                           "frond base should be welded to the crown, variant \(v)")
            XCTAssertEqual(f.sway.max() ?? 0, 1, accuracy: 1e-6,
                           "frond tip should reach full travel, variant \(v)")
        }
    }

    /// Squared, not linear. The midpoint of a frond must move appreciably less than half as
    /// far as the tip, which is what makes it read as a stiff shaft that whips at the end
    /// rather than a rubber band bending evenly.
    func testFrondFalloffIsSquared() {
        let f = PropMeshes.palm(variant: 0).fronds
        // 5 segments, so t = 0.4 is the closest sample to the middle: 0.4^2 = 0.16.
        XCTAssertTrue(f.sway.contains { abs($0 - 0.16) < 1e-5 },
                      "expected a 0.16 weight from squared falloff, got \(Set(f.sway).sorted())")
    }

    /// Ferns are understory, sheltered by 300 palms of canopy, and they are also the closest
    /// foliage to the camera. Their ceiling is deliberately well under the palms'.
    func testFernIsShelteredAndItsTrunkPinned() {
        for v in 0..<4 {
            let m = PropMeshes.treeFern(variant: v)
            let peak = m.sway.max() ?? 0
            XCTAssertLessThanOrEqual(peak, 0.56, "fern variant \(v) bends too hard: \(peak)")
            XCTAssertGreaterThan(peak, 0.3, "fern variant \(v) barely moves: \(peak)")
            // The first `rings * sides` vertices are the trunk, appended before the crown.
            XCTAssertEqual(m.sway.prefix(24).max(), 0, "fern trunk should be planted")
        }
    }

    /// A poinciana canopy pivots on a thick bole: the apex travels, the rim is the hinge.
    func testFlamboyanApexMovesMostAndRimLeast() {
        let c = PropMeshes.flamboyanCrown(seed: 3, tint: simd_float3(1, 0.2, 0.1))
        XCTAssertEqual(c.sway.first, 1, "the apex vertex is emitted first and should be free")
        // Ring 5 of 5 is the rim, the last `sides` vertices.
        XCTAssertEqual(c.sway.suffix(16).max() ?? -1, 0, accuracy: 1e-6,
                       "the outer ring is the hinge and should not travel")
    }
}

/// The shared wind. These constants are now read from two places — the Metal shader that bends
/// the foliage and the Swift that leans the rain — so the numbers here are a contract rather
/// than a tuning knob, and a drift between the two is invisible in a screenshot.
final class WindTests: XCTestCase {

    /// The envelope must stay strictly positive. It multiplies the bend, so a zero crossing
    /// would flip the wind's direction mid-gust — the canopy snapping the other way with no
    /// gust front, which reads as a glitch rather than as weather.
    func testGustNeverReachesZeroOrExceedsOne() {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for i in 0..<4000 {
            let t = Float(i) * 0.05
            for ph in stride(from: Float(0), to: 40, by: 3.7) {
                let g = GameScene.Wind.gust(t: t, ph: ph)
                lo = min(lo, g); hi = max(hi, g)
            }
        }
        XCTAssertGreaterThan(lo, 0.05, "gust dipped to \(lo) — the wind would reverse")
        XCTAssertLessThanOrEqual(hi, 1.001, "gust peaked at \(hi)")
    }

    /// Bend has to stay inside roughly -1...1 because the amplitudes are quoted in metres of
    /// travel at weight 1. If it can reach 2 then a palm frond moves 0.6 m rather than 0.3 and
    /// the numbers in the call sites stop meaning what their comments say.
    func testBendStaysWithinItsQuotedRange() {
        var peak: Float = 0
        for i in 0..<8000 {
            let t = Float(i) * 0.03
            for ph in stride(from: Float(0), to: 40, by: 2.3) {
                peak = max(peak, abs(GameScene.Wind.bend(t: t, ph: ph)))
            }
        }
        XCTAssertLessThanOrEqual(peak, 1.0, "bend peaked at \(peak), so every amplitude lies")
        XCTAssertGreaterThan(peak, 0.7, "bend only reached \(peak) — the wind barely blows")
    }

    /// Neighbouring trees must not move as one plate. Ten metres apart is a normal spacing in
    /// these groves, and at the phase rate chosen they should be visibly out of step.
    func testTreesTenMetresApartAreOutOfPhase() {
        let a = GameScene.Wind.phase(x: 0, z: 0)
        let b = GameScene.Wind.phase(x: 10, z: 0)
        XCTAssertGreaterThan(abs(b - a), 1.5,
                             "10 m apart gives only \(abs(b - a)) rad — the grove moves as one")
    }

    /// Two points a couple of metres apart — across one crown — should lag slightly rather
    /// than sit a half cycle apart, so the near side leads the far side.
    func testOneCrownLagsButDoesNotInvert() {
        let d = abs(GameScene.Wind.phase(x: 2, z: 0) - GameScene.Wind.phase(x: 0, z: 0))
        XCTAssertGreaterThan(d, 0.15, "no internal lag: the crown moves as a plate")
        XCTAssertLessThan(d, 1.2, "\(d) rad across one crown would tear it in half")
    }
}
