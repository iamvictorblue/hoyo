import simd

/// Pure prop geometry, lifted out of `GameScene` so it can be tested.
///
/// Same reasoning as `Physics.swift`: everything in here has produced a real bug at
/// least once, and every one of those bugs was arithmetic that nobody could see.
/// A boulder documented as "wider than they are tall" came out taller than wide in
/// half its variants. A crown normalised its shading against a floor of -0.34 when
/// its own lowest vertex sat at -0.69, so all sixteen rim vertices clamped to one
/// flat tone. A comment quoting measured frond counts had been computed in float64,
/// where `sinf(x) * 43758` answers a different question entirely.
///
/// All three were found by a throwaway script that should have been a test, which is
/// what this file exists to stop happening again. These return raw vertex data rather
/// than `SCNGeometry` precisely so a test can inspect them without a renderer;
/// `GameScene` wraps them.
enum PropMeshes {

    /// Vertices, per-vertex colours and triangle indices. Colour rides the vertex
    /// stream throughout the scenery so that props can share one material — which is
    /// not a preference but a hard constraint, see `Mesh.flattening` below.
    struct Mesh {
        var verts: [simd_float3] = []
        var cols: [simd_float3] = []
        var indices: [Int32] = []

        var triangleCount: Int { indices.count / 3 }

        /// Outward-facing normal of triangle `t`, from its winding.
        func faceNormal(_ t: Int) -> simd_float3 {
            let a = verts[Int(indices[t * 3])]
            let b = verts[Int(indices[t * 3 + 1])]
            let c = verts[Int(indices[t * 3 + 2])]
            return simd_normalize(simd_cross(b - a, c - a))
        }

        /// Axis-aligned extent, for shape assertions.
        var size: simd_float3 {
            guard let first = verts.first else { return .zero }
            var lo = first, hi = first
            for v in verts { lo = simd_min(lo, v); hi = simd_max(hi, v) }
            return hi - lo
        }
    }

    /// Stable jitter for the scenery props. Prop templates are built once and cloned,
    /// so they must not draw from `worldRng`: the count of draws taken from it is part
    /// of the fixed world's contract, and one extra would move the rest of the scenery.
    ///
    /// Beware checking values out of this by hand. The `* 43758` blows the gap between
    /// `Float` and `Double` wide open, so the same expression evaluated in float64
    /// answers a different question — verify in Swift, not in a scratch script.
    static func propHash(_ a: Int, _ b: Int) -> Float {
        let s = sinf(Float(a) * 12.9898 + Float(b) * 78.233) * 43758.5453
        return s - floorf(s)
    }

    // MARK: - boulder

    /// An irregular faceted lump, flat-shaded.
    ///
    /// Every triangle carries its own three vertices on purpose: `makeGeometry`
    /// averages normals across shared ones, so sharing them would smooth the facets
    /// straight back into the sphere this replaces.
    static func boulder(variant: Int) -> Mesh {
        let t: Float = 1.618034
        var base: [simd_float3] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
            [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
            [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]
        ].map { simd_normalize(simd_float3($0[0], $0[1], $0[2])) }

        // Boulders sit — they are wider than they are tall. Both numbers below were
        // measured rather than eyeballed, because the first attempt did the opposite
        // of what it claimed: at a y-squash of 0.78–1.04 against x/z of 0.86–1.16 the
        // per-vertex jitter of ±29% simply swamped an 8% bias, and two of four
        // variants came out taller than wide. `testBouldersSitRatherThanStand` pins it.
        let squash = simd_float3(0.92 + propHash(variant, 21) * 0.24,
                                 0.60 + propHash(variant, 22) * 0.18,
                                 0.92 + propHash(variant, 23) * 0.24)
        for i in 0..<base.count {
            base[i] *= 0.82 + propHash(variant &* 53 &+ i, 29) * 0.32
            base[i] *= squash
        }

        let faces: [[Int]] = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
            [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
            [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
            [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
        ]
        var m = Mesh()
        let stone = simd_float3(0.47, 0.44, 0.37)
        for (f, tri) in faces.enumerated() {
            let a = base[tri[0]], b = base[tri[1]], c = base[tri[2]]
            let n = simd_normalize(simd_cross(b - a, c - a))
            // Sun-bleached where the face points up, damp and dark where it points
            // into the hillside.
            let up = n.y * 0.5 + 0.5
            let tone = simd_clamp(0.30 + up * 0.62
                                  + (propHash(variant, f &+ 41) - 0.5) * 0.16, 0, 1)
            let col = simd_mix(stone * 0.52, stone * 1.28, simd_float3(repeating: tone))
            let o = Int32(m.verts.count)
            m.verts.append(a); m.verts.append(b); m.verts.append(c)
            m.cols.append(col); m.cols.append(col); m.cols.append(col)
            m.indices.append(contentsOf: [o, o + 1, o + 2])
        }
        return m
    }

    // MARK: - flamboyán crown

    /// The normalising floor for the crown's shading. It has to be at or below the
    /// geometry's actual lowest vertex: it was -0.34 while the real minimum runs to
    /// -0.69, which clamped every rim vertex to `lit == 0` and flattened the rim to a
    /// single tone. `testCrownRimIsNotClamped` pins it.
    static let crownRimY: Float = -0.70
    static let crownApexY: Float = 1.45

    static func flamboyanCrown(seed: Int, tint: simd_float3) -> Mesh {
        var m = Mesh()
        m.verts.append(simd_float3(0, crownApexY, 0))
        m.cols.append(tint)
        let rings = 5, sides = 16
        // three boughs of unequal weight — this is what scallops the outline
        let l1 = 0.20 + propHash(seed, 11) * 0.10
        let l2 = 0.12 + propHash(seed, 12) * 0.10
        let ph1 = propHash(seed, 13) * 6.28, ph2 = propHash(seed, 14) * 6.28
        for r in 1...rings {
            let t = Float(r) / Float(rings)
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                let n = propHash(seed &* 97 &+ s &* 13, r &* 7 &+ 3)
                let lump = 1 + l1 * sinf(a * 3 + ph1) + l2 * sinf(a * 5 - ph2)
                let rad = 2.15 * sinf(t * .pi * 0.5) * lump * (0.86 + n * 0.28)
                let dome = crownApexY * cosf(t * .pi * 0.55) - 0.30 * t * t
                let y = dome + (n - 0.5) * 0.34
                m.verts.append(simd_float3(cos(a) * rad, y, sin(a) * rad))
                // Sunlit caps keep the tint; hollows and the underside drop to about
                // a third of it. Driving this off the jittered height is what makes
                // the bumps legible instead of a flat silhouette.
                let lit = simd_clamp((y - crownRimY) / (crownApexY - crownRimY), 0, 1)
                m.cols.append(simd_mix(tint * 0.22, tint,
                                       simd_float3(repeating: 0.12 + lit * 0.88)))
            }
        }
        // Apex fan wound so the face normal comes out +y. With the apex on the y axis
        // the y-component of cross(B-A, C-A) reduces to R_b * R_c * sin(dTheta), which
        // is positive regardless of the heights involved — so this holds even where
        // ring-1 jitter pushes a vertex above the apex, which it does for up to 6 of
        // 16 per seed.
        for s in 0..<sides {
            m.indices.append(contentsOf: [0, Int32(1 + (s + 1) % sides), Int32(1 + s)])
        }
        for r in 0..<(rings - 1) {
            for s in 0..<sides {
                let a = Int32(1 + r * sides + s)
                let b = Int32(1 + r * sides + (s + 1) % sides)
                let c = Int32(1 + (r + 1) * sides + s)
                let d = Int32(1 + (r + 1) * sides + (s + 1) % sides)
                m.indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        return m
    }

    // MARK: - tree fern

    /// A tree fern: short thick trunk, big arching fronds, understory green.
    ///
    /// El Yunque was being furnished with flamboyanes, which are a dry-lowland tree —
    /// and worse, the stage's grade desaturates their red to ochre, so each one read as
    /// a tan cap on a bare stalk. A mushroom, in a rainforest. This is what belongs
    /// there instead: squat, wide, and layered low enough to be understory rather than
    /// canopy, so it fills the bare ground that made the hillsides look mown.
    ///
    /// Single mesh, single double-sided material on purpose. The fronds are flat
    /// ribbons and need double-siding; the trunk is short and thick enough that
    /// rasterising its backfaces costs almost nothing, and keeping it to one material
    /// means one container and one draw call — see FlattenGuard.
    static func treeFern(variant: Int) -> Mesh {
        var m = Mesh()

        // trunk: stubby, fibrous, barely tapered
        let rings = 4, sides = 6
        let height: Float = 0.75 + propHash(variant, 71) * 0.85
        let lean = propHash(variant, 72) * 6.28
        let ldx = cos(lean), ldz = sin(lean)
        let bend: Float = 0.10 + propHash(variant, 73) * 0.16
        func centre(_ t: Float) -> simd_float3 {
            simd_float3(ldx * bend * t * t, height * t, ldz * bend * t * t)
        }
        for r in 0..<rings {
            let t = Float(r) / Float(rings - 1)
            let c = centre(t)
            let rad = 0.15 * (1 - 0.22 * t)
            let shade = 0.42 + 0.18 * t
            for sIdx in 0..<sides {
                let a = Float(sIdx) / Float(sides) * 2 * .pi
                m.verts.append(c + simd_float3(cos(a) * rad, 0, sin(a) * rad))
                m.cols.append(simd_float3(shade * 0.50, shade * 0.40, shade * 0.28))
            }
        }
        for r in 0..<(rings - 1) {
            for sIdx in 0..<sides {
                let a = Int32(r * sides + sIdx)
                let b = Int32(r * sides + (sIdx + 1) % sides)
                let c = Int32((r + 1) * sides + sIdx)
                let d = Int32((r + 1) * sides + (sIdx + 1) % sides)
                m.indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        // crown: a rosette that rises then arches over, so the silhouette is a fountain
        // rather than a dome. Wider than tall and low to the ground — understory.
        let crown = centre(1)
        let fronds = 7 + Int(propHash(variant, 74) * 4)
        let segs = 4
        let lo = simd_float3(0.05, 0.20, 0.07)          // shaded, near the crown
        let hi = simd_float3(0.34, 0.62, 0.20)          // the light that gets through
        for f in 0..<fronds {
            let a = Float(f) / Float(fronds) * 2 * .pi + propHash(variant, 75) * 3
            let dx = cos(a), dz = sin(a)
            let vigour = 0.75 + propHash(variant &* 17 &+ f, 79) * 0.5
            let reachMax: Float = (1.5 + propHash(variant &* 17 &+ f, 83) * 0.9) * vigour
            let riseMax: Float = 0.55 * vigour
            for k in 1...segs {
                let t = Float(k) / Float(segs)
                let tp = Float(k - 1) / Float(segs)
                func spine(_ u: Float) -> simd_float3 {
                    // up first, then over: sin gives the arch, the cubic pulls the tip down
                    let rise = riseMax * sinf(u * .pi * 0.72) - 0.42 * u * u * u
                    return crown + simd_float3(dx * u * reachMax, rise, dz * u * reachMax)
                }
                func half(_ u: Float) -> Float { 0.30 * sinf(u * .pi) * (1 - u * 0.25) + 0.02 }
                let side = simd_float3(-dz, 0, dx)
                let p0 = spine(tp), p1 = spine(t)
                let l0 = p0 + side * half(tp), r0 = p0 - side * half(tp)
                let l1 = p1 + side * half(t),  r1 = p1 - side * half(t)
                let c0 = simd_mix(lo, hi, simd_float3(repeating: tp))
                let c1 = simd_mix(lo, hi, simd_float3(repeating: t))
                let base = Int32(m.verts.count)
                m.verts.append(l0); m.verts.append(r0)
                m.verts.append(l1); m.verts.append(r1)
                m.cols.append(c0); m.cols.append(c0)
                m.cols.append(c1); m.cols.append(c1)
                m.indices.append(contentsOf: [base, base + 2, base + 1,
                                              base + 1, base + 2, base + 3])
            }
        }
        return m
    }

    // MARK: - palm

    /// Trunk and fronds come back separately, and the caller must keep them in
    /// separate containers. That is not a style preference, it is the only
    /// arrangement that renders — see `testPalmHalvesAreSeparableForFlattening`.
    static func palm(variant: Int) -> (trunk: Mesh, fronds: Mesh) {
        var trunk = Mesh()
        let rings = 9, sides = 7
        let height: Float = 7
        let leanDir = propHash(variant, 1) * 6.28
        let lean: Float = 0.9 + propHash(variant, 2) * 1.1
        let ldx = cos(leanDir), ldz = sin(leanDir)

        // Bend grows with the square of height: a palm curves up near the crown and
        // stands near-vertical at the root, which is what a straight cylinder missed.
        func trunkCentre(_ t: Float) -> simd_float3 {
            simd_float3(ldx * lean * t * t, height * t, ldz * lean * t * t)
        }

        for r in 0..<rings {
            let t = Float(r) / Float(rings - 1)
            let c = trunkCentre(t)
            // Stacked leaf scars, not a smooth pole — the ripple catches the low sun.
            let rad = 0.27 * (1 - 0.50 * t) * (0.90 + 0.10 * (sinf(t * 30) * 0.5 + 0.5))
            let shade = 0.60 + 0.26 * t          // sun-bleached toward the crown
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                trunk.verts.append(c + simd_float3(cos(a) * rad, 0, sin(a) * rad))
                trunk.cols.append(simd_float3(shade * 0.64, shade * 0.52, shade * 0.37))
            }
        }
        for r in 0..<(rings - 1) {
            for s in 0..<sides {
                let a = Int32(r * sides + s)
                let b = Int32(r * sides + (s + 1) % sides)
                let c = Int32((r + 1) * sides + s)
                let d = Int32((r + 1) * sides + (s + 1) % sides)
                trunk.indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        var fronds = Mesh()
        let crown = trunkCentre(1)
        let count = frondCount(variant: variant)
        let segs = 5
        let deadLo = simd_float3(0.38, 0.29, 0.15), deadHi = simd_float3(0.54, 0.43, 0.23)
        let liveLo = simd_float3(0.07, 0.31, 0.13), liveHi = simd_float3(0.44, 0.76, 0.27)
        for f in 0..<count {
            let a = Float(f) / Float(count) * 2 * .pi + propHash(variant, 4) * 3
            let dx = cos(a), dz = sin(a)
            // Old fronds hang, new ones near the spear stand up. Mixing the two is
            // most of what separates a palm from a green umbrella.
            let age = frondAge(variant: variant, frond: f)
            let reachMax: Float = 2.6 + age * 1.6
            let dropMax: Float = -0.4 - age * 2.8
            let dead = age > deadFrondThreshold
            func frondColor(_ t: Float) -> simd_float3 {
                simd_mix(dead ? deadLo : liveLo, dead ? deadHi : liveHi,
                         simd_float3(repeating: t))
            }
            var prevL = crown + simd_float3(0, 0.18, 0)
            var prevR = prevL
            var prevC = frondColor(0)
            for k in 1...segs {
                let t = Float(k) / Float(segs)
                let reach = t * reachMax
                let drop = dropMax * t * t                    // gravity along the frond
                let halfWidth = 0.44 * sinf(t * .pi) * (1 - t * 0.3)
                let spine = crown + simd_float3(dx * reach, 0.18 + drop, dz * reach)
                let side = simd_float3(-dz * halfWidth, 0, dx * halfWidth)
                let l = spine + side, r = spine - side
                let c = frondColor(t)
                let base = Int32(fronds.verts.count)
                fronds.verts.append(prevL); fronds.verts.append(prevR)
                fronds.verts.append(l);     fronds.verts.append(r)
                fronds.cols.append(prevC);  fronds.cols.append(prevC)
                fronds.cols.append(c);      fronds.cols.append(c)
                fronds.indices.append(contentsOf: [base, base + 2, base + 1,
                                                   base + 1, base + 2, base + 3])
                prevL = l; prevR = r; prevC = c
            }
        }
        return (trunk, fronds)
    }

    /// One or two brown fronds per crown. Measured by running the hash in Swift: at
    /// 0.87 the three variants give 3/10, 2/12 and 2/11 — a third of the lead variant
    /// brown, which with `placed % 3` cycling lands in every grove. 0.92 gives
    /// 2/10, 2/12, 1/11. `testMostFrondsAreAlive` pins it.
    static let deadFrondThreshold: Float = 0.92

    static func frondCount(variant: Int) -> Int { 10 + Int(propHash(variant, 3) * 3) }
    static func frondAge(variant: Int, frond: Int) -> Float {
        propHash(variant &* 31 &+ frond, 7)
    }
}
