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
