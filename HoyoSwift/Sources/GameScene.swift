import SceneKit
import SwiftUI
import simd

// MARK: - deterministic rng (same course every run, same as the JS version)

private struct Lcg {
    var seed: UInt64 = 20260727
    mutating func next() -> Float {
        seed = (seed &* 16807) % 2147483647
        return Float(seed - 1) / Float(2147483646)
    }
}

// MARK: - game controller

final class GameScene: NSObject, SCNSceneRendererDelegate {

    // course
    static let step: Float = 2
    static let count = 1801
    static let total: Float = Float(count - 1) * 2.0
    static let roadHalf: Float = 4.5

    let scene = SCNScene()
    private let state: GameState
    private let sound: SoundEngine

    private var rng = Lcg()
    private var pts: [simd_float3] = []
    private var tans: [simd_float3] = []
    private var rights: [simd_float3] = []
    private var grades: [Float] = []
    private var curvs: [Float] = []

    // dynamic nodes
    private let cameraNode = SCNNode()
    private let playerNode = SCNNode()
    private let chassisNode = SCNNode()
    private let blobNode = SCNNode()
    private var frontWheelNodes: [SCNNode] = []
    private var spinWheelNodes: [SCNNode] = []
    private var flameNodes: [SCNNode] = []
    private var brakeLightMaterial = SCNMaterial()
    private var glowMaterial = SCNMaterial()
    private var smokeSystem = SCNParticleSystem()
    private var dustSystem = SCNParticleSystem()
    private let dustNode = SCNNode()
    private var oceanNormal: SCNMaterialProperty?

    // entities
    private struct Hole { var s, x, r: Float; var passed = false; var hit = false }
    private var holes: [Hole] = []
    private struct Pickup { var s, x, baseY: Float; var node: SCNNode; var taken = false }
    private var piraguas: [Pickup] = []
    private var toolboxes: [Pickup] = []
    private struct Iguana {
        var s, x: Float; var dir: Float; var node: SCNNode
        var stateRaw = 0   // 0 wait, 1 run, 2 done
        var hit = false
    }
    private var iguanas: [Iguana] = []
    private struct Traffic {
        var s, x, v: Float; var node: SCNNode
        var cool: Float = 0; var missed = false
    }
    private var traffic: [Traffic] = []

    // sim state
    private var phase: GamePhase = .intro
    private var s: Float = 4, v: Float = 8, x: Float = 0, xd: Float = 0
    private var hp: Float = 100, nitro: Float = 60
    private var score: Float = 0, styleRun: Float = 0
    private var topSpeed: Float = 0
    private var holesHit = 0, nearMisses = 0, combo = 0
    private var cd: Float = 0
    private var cdLabel = ""
    private var streakSystem = SCNParticleSystem()
    private var shake: Float = 0, flashT: Float = 0, jolt: Float = 0
    private var driftYaw: Float = 0, leanRoll: Float = 0, pitchAng: Float = 0
    private var smokeT: Float = 0
    private var playTime: Double = 0
    private var lastTime: TimeInterval = -1
    private var camPos = simd_float3(0, 3, 8)
    private var camLook = simd_float3(0, 0, 0)
    private var fov: CGFloat = 72
    private var wheelSpin: Float = 0

    init(state: GameState, sound: SoundEngine) {
        self.state = state
        self.sound = sound
        super.init()
        buildPath()
        buildScene()
    }

    // MARK: - path

    private func buildPath() {
        var px: Float = 0, pz: Float = 0, py: Float = 0
        for i in 0..<Self.count {
            let sd = Float(i) * Self.step
            let h = 0.55 * sin(sd / 173) + 0.45 * sin(sd / 59 + 1.7)
                  + 0.5 * sin(sd / 311 + 4.0) + 0.3 * sin(sd / 47 + 2.5)
            let endFade = simd_clamp((Self.total - 100 - sd) / 260, 0, 1)
            let grade = (0.055 + 0.04 * sin(sd / 210 + 0.5) + 0.024 * sin(sd / 83)) * endFade
            pts.append(simd_float3(px, py, pz))
            grades.append(-grade)
            px += sin(h) * Self.step
            pz -= cos(h) * Self.step
            py -= grade * Self.step
        }
        let lift = 5.5 - pts[Self.count - 1].y
        for i in 0..<Self.count { pts[i].y += lift }

        var headings: [Float] = []
        for i in 0..<Self.count {
            let a = pts[max(0, i - 1)], b = pts[min(Self.count - 1, i + 1)]
            let t = simd_normalize(b - a)
            tans.append(t)
            rights.append(simd_normalize(simd_float3(-t.z, 0, t.x)))
            headings.append(atan2(t.x, -t.z))
        }
        for i in 0..<Self.count {
            let h0 = headings[max(0, i - 1)], h1 = headings[min(Self.count - 1, i + 1)]
            var dh = h1 - h0
            if dh > .pi { dh -= 2 * .pi }
            if dh < -.pi { dh += 2 * .pi }
            curvs.append(dh / (2 * Self.step))
        }
    }

    private func sample(_ dist: Float) -> (pos: simd_float3, tan: simd_float3, rgt: simd_float3) {
        var f = simd_clamp(dist / Self.step, 0, Float(Self.count) - 1.001)
        let i = Int(f); f -= Float(i)
        return (simd_mix(pts[i], pts[i + 1], simd_float3(repeating: f)),
                simd_normalize(simd_mix(tans[i], tans[i + 1], simd_float3(repeating: f))),
                simd_normalize(simd_mix(rights[i], rights[i + 1], simd_float3(repeating: f))))
    }

    private func groundY(_ i: Int, _ lat: Float) -> Float {
        let idx = min(max(i, 0), Self.count - 1)
        let p = pts[idx], sd = Float(idx) * Self.step
        let d = abs(lat) - Self.roadHalf
        if d <= 0 { return p.y }
        var yy: Float
        if lat < 0 {
            let k = 0.42 + 0.18 * sin(sd / 140 + 1) + 0.10 * sin(sd / 47)
            yy = p.y + d * k + sin(d * 0.22 + sd * 0.013) * min(d * 0.15, 4)
        } else {
            let k2 = 0.34 + 0.12 * sin(sd / 120 + 2)
            yy = p.y - d * k2 + sin(d * 0.19 + sd * 0.017) * min(d * 0.12, 3)
        }
        return max(yy, -3.6)
    }

    // MARK: - geometry helper

    private func makeGeometry(verts: [simd_float3], indices: [Int32],
                              uvs: [CGPoint]? = nil, colors: [simd_float3]? = nil,
                              material: SCNMaterial) -> SCNGeometry {
        // accumulate face normals
        var normals = [simd_float3](repeating: .zero, count: verts.count)
        var k = 0
        while k < indices.count {
            let a = Int(indices[k]), b = Int(indices[k + 1]), c = Int(indices[k + 2])
            let n = simd_cross(verts[b] - verts[a], verts[c] - verts[a])
            normals[a] += n; normals[b] += n; normals[c] += n
            k += 3
        }
        for i in 0..<normals.count {
            let len = simd_length(normals[i])
            normals[i] = len > 0.0001 ? normals[i] / len : simd_float3(0, 1, 0)
        }
        var sources = [
            SCNGeometrySource(vertices: verts.map { SCNVector3($0) }),
            SCNGeometrySource(normals: normals.map { SCNVector3($0) })
        ]
        if let uvs = uvs { sources.append(SCNGeometrySource(textureCoordinates: uvs)) }
        if let colors = colors {
            var floats: [Float] = []
            floats.reserveCapacity(colors.count * 3)
            for c in colors { floats.append(c.x); floats.append(c.y); floats.append(c.z) }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color,
                vectorCount: colors.count, usesFloatComponents: true,
                componentsPerVector: 3, bytesPerComponent: 4,
                dataOffset: 0, dataStride: 12))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: sources, elements: [element])
        geo.materials = [material]
        return geo
    }

    private func lambert(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = color
        return m
    }

    private func constant(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }

    // MARK: - scene build

    private func buildScene() {
        scene.fogStartDistance = 260
        scene.fogEndDistance = 2400
        scene.fogColor = UIColor(red: 1.0, green: 0.67, blue: 0.47, alpha: 1)
        // cubemap sky: pans with the camera, immune to fog, sun + stars baked in
        scene.background.contents = Textures.skyCubemap()

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = UIColor(red: 0.62, green: 0.5, blue: 0.58, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let sunNode = SCNNode()
        sunNode.light = SCNLight()
        sunNode.light!.type = .directional
        sunNode.light!.color = UIColor(red: 1.0, green: 0.82, blue: 0.63, alpha: 1)
        sunNode.light!.intensity = 1100
        sunNode.light!.castsShadow = true
        sunNode.light!.shadowMapSize = CGSize(width: 2048, height: 2048)
        sunNode.light!.shadowSampleCount = 4
        sunNode.light!.shadowRadius = 3
        sunNode.light!.shadowColor = UIColor(white: 0, alpha: 0.5)
        sunNode.light!.maximumShadowDistance = 150
        sunNode.eulerAngles = SCNVector3(-0.55, 0.45, 0)
        scene.rootNode.addChildNode(sunNode)

        camera()
        clouds()
        ocean()
        road()
        terrain()
        vegetation()
        props()
        potholes()
        makePiraguas()
        makeToolboxes()
        makeIguanas()
        makeTraffic()
        buildCar()
        particles()

        scene.rootNode.addChildNode(playerNode)
        playerNode.addChildNode(chassisNode)
        scene.rootNode.addChildNode(dustNode)
    }

    private func camera() {
        let cam = SCNCamera()
        cam.zNear = 0.1
        cam.zFar = 9000
        cam.fieldOfView = 72
        // post-processing: this is what sells the look on device
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        cam.bloomThreshold = 0.85
        cam.bloomIntensity = 0.9
        cam.bloomBlurRadius = 12
        cam.motionBlurIntensity = 0.45
        cam.vignettingPower = 0.7
        cam.vignettingIntensity = 0.7
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 3, 8)
        scene.rootNode.addChildNode(cameraNode)
    }

    private func clouds() {
        let container = SCNNode()
        let mat = constant(UIColor(red: 1, green: 0.8, blue: 0.72, alpha: 1))
        for _ in 0..<14 {
            let cx = (rng.next() - 0.5) * 2400
            let cy = 430 + rng.next() * 260
            let cz = -300 - rng.next() * 2700
            for _ in 0..<3 {
                let ball = SCNNode(geometry: SCNSphere(radius: 1))
                ball.geometry!.materials = [mat]
                ball.position = SCNVector3(cx + (rng.next() - 0.5) * 90,
                                           cy + (rng.next() - 0.5) * 14,
                                           cz + (rng.next() - 0.5) * 50)
                ball.scale = SCNVector3(45 + rng.next() * 70, 10 + rng.next() * 9, 26 + rng.next() * 34)
                container.addChildNode(ball)
            }
        }
        scene.rootNode.addChildNode(container.flattenedClone())
    }

    private func ocean() {
        let plane = SCNPlane(width: 9000, height: 9000)
        plane.widthSegmentCount = 110
        plane.heightSegmentCount = 110
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = UIColor(red: 0.07, green: 0.30, blue: 0.48, alpha: 1)
        m.specular.contents = UIColor(red: 1, green: 0.75, blue: 0.52, alpha: 1)
        m.shininess = 0.9
        m.normal.contents = Textures.waterNormal()
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        oceanNormal = m.normal
        // gentle swell, displaced in the vertex stage
        m.shaderModifiers = [.geometry: """
            float2 p = _geometry.position.xy;
            float t = scn_frame.time;
            _geometry.position.z += sin(p.x*0.02 + t*0.8)*sin(p.y*0.016 - t*0.6)*1.1
              + sin(p.x*0.045 + t*1.4)*0.45 + sin(p.y*0.05 + t*1.1)*0.4;
            """]
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(0, -3, -1600)
        scene.rootNode.addChildNode(node)
    }

    private func road() {
        var verts: [simd_float3] = [], uvs: [CGPoint] = [], idx: [Int32] = []
        for i in 0..<Self.count {
            let p = pts[i], r = rights[i]
            verts.append(p - r * Self.roadHalf)
            verts.append(p + r * Self.roadHalf)
            let vCoord = CGFloat(Float(i) * Self.step / 9)
            uvs.append(CGPoint(x: 0, y: vCoord))
            uvs.append(CGPoint(x: 1, y: vCoord))
            if i < Self.count - 1 {
                let a = Int32(i * 2)
                idx.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            }
        }
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.diffuse.contents = Textures.asphalt()
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .repeat
        let node = SCNNode(geometry: makeGeometry(verts: verts, indices: idx, uvs: uvs, material: mat))
        node.castsShadow = false
        scene.rootNode.addChildNode(node)

        func ribbon(_ l0: Float, _ l1: Float, _ color: UIColor, dashed: Bool) {
            var v: [simd_float3] = [], id: [Int32] = []
            var n: Int32 = 0
            for j in 0..<(Self.count - 1) {
                if dashed && (j % 8) > 3 { continue }
                let p0 = pts[j], r0 = rights[j], p1 = pts[j + 1], r1 = rights[j + 1]
                let up = simd_float3(0, 0.03, 0)
                v.append(p0 + r0 * l0 + up); v.append(p0 + r0 * l1 + up)
                v.append(p1 + r1 * l0 + up); v.append(p1 + r1 * l1 + up)
                id.append(contentsOf: [n, n + 1, n + 2, n + 1, n + 3, n + 2])
                n += 4
            }
            let node = SCNNode(geometry: makeGeometry(verts: v, indices: id, material: constant(color)))
            node.castsShadow = false
            scene.rootNode.addChildNode(node)
        }
        ribbon(-0.14, 0.14, UIColor(red: 0.79, green: 0.68, blue: 0.21, alpha: 1), dashed: true)
        ribbon(-4.32, -4.1, UIColor(white: 0.83, alpha: 1), dashed: false)
        ribbon(4.1, 4.32, UIColor(white: 0.83, alpha: 1), dashed: false)
    }

    private func terrain() {
        let latsL: [Float] = [-4.2, -7, -12, -20, -34, -60, -95, -145]
        let latsR: [Float] = [4.2, 7, 12, 20, 34, 60, 95, 145]

        func side(_ lats: [Float]) {
            var verts: [simd_float3] = [], cols: [simd_float3] = [], idx: [Int32] = []
            var rows = 0
            var i = 0
            while i < Self.count {
                let p = pts[i], r = rights[i]
                for (j, lat) in lats.enumerated() {
                    let y = j == 0 ? p.y - 0.09 : groundY(i, lat)
                    verts.append(simd_float3(p.x + r.x * lat, y, p.z + r.z * lat))
                    if y < 1.8 {
                        let l = 0.66 + 0.05 * sin(Float(i) * 0.7 + Float(j))
                        cols.append(simd_float3(0.93 * l + 0.1, 0.82 * l + 0.08, 0.55 * l))
                    } else {
                        let n = 0.5 + 0.5 * sin(Float(i) * 0.085 + Float(j) * 1.6) * sin(Float(i) * 0.041 + 2.0)
                        let ui = UIColor(hue: CGFloat(0.33 - n * 0.05), saturation: 0.58,
                                         brightness: CGFloat(0.30 + n * 0.22), alpha: 1)
                        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
                        ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
                        cols.append(simd_float3(Float(rr), Float(gg), Float(bb)))
                    }
                }
                rows += 1
                i += 2
            }
            let w = lats.count
            for row in 0..<(rows - 1) {
                for j in 0..<(w - 1) {
                    let a = Int32(row * w + j)
                    idx.append(contentsOf: [a, a + Int32(w), a + 1, a + 1, a + Int32(w), a + Int32(w) + 1])
                }
            }
            let mat = SCNMaterial()
            mat.lightingModel = .lambert
            mat.diffuse.contents = UIColor.white       // modulated by vertex colors
            let node = SCNNode(geometry: makeGeometry(verts: verts, indices: idx, colors: cols, material: mat))
            node.castsShadow = false
            scene.rootNode.addChildNode(node)
        }
        side(latsL)
        side(latsR)
    }

    // MARK: - vegetation

    /// Seven drooping fronds built as raw triangles — reads as a real palm
    /// crown instead of a starburst of boxes.
    private func palmCanopyGeometry() -> SCNGeometry {
        var verts: [simd_float3] = []
        var idx: [Int32] = []
        let fr = 7
        for i in 0..<fr {
            let a = Float(i) / Float(fr) * 2 * .pi + 0.3
            let dx = cos(a), dz = sin(a)
            let px = -dz * 0.45, pz = dx * 0.45
            let m = simd_float3(dx * 1.7, -0.2, dz * 1.7)
            let tip = simd_float3(dx * 3.2, -1.6, dz * 3.2)
            let crown = simd_float3(0, 0.15, 0)
            let base = Int32(verts.count)
            verts.append(crown)
            verts.append(simd_float3(m.x + px, m.y, m.z + pz))
            verts.append(tip)
            verts.append(crown)
            verts.append(tip)
            verts.append(simd_float3(m.x - px, m.y, m.z - pz))
            idx.append(contentsOf: [base, base + 1, base + 2, base + 3, base + 4, base + 5])
        }
        let mat = lambert(UIColor(red: 0.18, green: 0.61, blue: 0.32, alpha: 1))
        mat.isDoubleSided = true
        return makeGeometry(verts: verts, indices: idx, material: mat)
    }

    private func palmTemplate() -> SCNNode {
        let palm = SCNNode()
        let trunk = SCNNode(geometry: SCNCylinder(radius: 0.18, height: 7))
        trunk.geometry!.materials = [lambert(UIColor(red: 0.54, green: 0.42, blue: 0.27, alpha: 1))]
        trunk.position.y = 3.5
        palm.addChildNode(trunk)
        let canopy = SCNNode(geometry: palmCanopyGeometry())
        canopy.position.y = 7
        palm.addChildNode(canopy)
        return palm
    }

    private func vegetation() {
        var guard_ = 0
        // palms
        let palmContainer = SCNNode()
        let template = palmTemplate()
        var placed = 0
        while placed < 120 && guard_ < 3000 {
            guard_ += 1
            let pi = 20 + Int(rng.next() * Float(Self.count - 60))
            let lat = (rng.next() < 0.55 ? 1 : -1) * (7 + rng.next() * 45)
            let gy = groundY(pi, lat)
            if gy < -1 { continue }
            let p = pts[pi], r = rights[pi]
            let clone = template.clone()
            clone.position = SCNVector3(p.x + r.x * lat, gy - 0.3, p.z + r.z * lat)
            let sc = 0.8 + rng.next() * 0.7
            clone.scale = SCNVector3(sc, sc, sc)
            clone.eulerAngles = SCNVector3((rng.next() - 0.5) * 0.2, rng.next() * 6.28, (rng.next() - 0.5) * 0.2)
            palmContainer.addChildNode(clone)
            placed += 1
        }
        let flatPalms = palmContainer.flattenedClone()
        flatPalms.castsShadow = true
        scene.rootNode.addChildNode(flatPalms)

        // flamboyanes
        let flamContainer = SCNNode()
        let trunkMat = lambert(UIColor(red: 0.43, green: 0.32, blue: 0.22, alpha: 1))
        placed = 0; guard_ = 0
        while placed < 40 && guard_ < 2000 {
            guard_ += 1
            let fi = 30 + Int(rng.next() * Float(Self.count - 80))
            let flat = (rng.next() < 0.5 ? 1 : -1) * (6.5 + rng.next() * 26)
            let fgy = groundY(fi, flat)
            if fgy < 0 { continue }
            let fp = pts[fi], fr = rights[fi]
            let tree = SCNNode()
            let trunk = SCNNode(geometry: SCNCylinder(radius: 0.27, height: 2.6))
            trunk.geometry!.materials = [trunkMat]
            trunk.position.y = 1.3
            tree.addChildNode(trunk)
            let can = SCNNode(geometry: SCNSphere(radius: 2.4))
            can.geometry!.materials = [lambert(UIColor(hue: CGFloat(0.02 + rng.next() * 0.04),
                saturation: 0.92, brightness: 0.85, alpha: 1))]
            can.scale = SCNVector3(1, 0.55, 1)
            can.position.y = 2.9
            tree.addChildNode(can)
            let fsc = 0.8 + rng.next() * 0.9
            tree.scale = SCNVector3(fsc, fsc, fsc)
            tree.position = SCNVector3(fp.x + fr.x * flat, fgy - 0.2, fp.z + fr.z * flat)
            flamContainer.addChildNode(tree)
            placed += 1
        }
        scene.rootNode.addChildNode(flamContainer.flattenedClone())

        // casitas
        let houseContainer = SCNNode()
        let palette: [UIColor] = [
            UIColor(red: 1, green: 0.42, blue: 0.62, alpha: 1),
            UIColor(red: 0.31, green: 0.8, blue: 0.77, alpha: 1),
            UIColor(red: 1, green: 0.9, blue: 0.43, alpha: 1),
            UIColor(red: 0.58, green: 0.88, blue: 0.83, alpha: 1),
            UIColor(red: 0.95, green: 0.51, blue: 0.51, alpha: 1),
            UIColor(red: 0.66, green: 0.85, blue: 0.92, alpha: 1),
            UIColor(red: 1, green: 0.7, blue: 0.28, alpha: 1),
            UIColor(red: 0.76, green: 0.96, blue: 0.52, alpha: 1)
        ]
        placed = 0; guard_ = 0
        while placed < 30 && guard_ < 2000 {
            guard_ += 1
            let hi = 40 + Int(rng.next() * Float(Self.count - 120))
            let hlat = (rng.next() < 0.5 ? 1 : -1) * (9.5 + rng.next() * 9)
            let hgy = groundY(hi, hlat)
            if hgy < 0.5 { continue }
            let hp = pts[hi], hr = rights[hi]
            let color = palette[Int(rng.next() * Float(palette.count)) % palette.count]
            let house = SCNNode()
            let base = SCNNode(geometry: SCNBox(width: 4.2, height: 3, length: 5, chamferRadius: 0))
            base.geometry!.materials = [lambert(color)]
            base.position.y = 1.5
            house.addChildNode(base)
            let roof = SCNNode(geometry: SCNPyramid(width: 5.2, height: 1.7, length: 6))
            var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
            color.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
            roof.geometry!.materials = [lambert(UIColor(red: rr * 0.55, green: gg * 0.55, blue: bb * 0.55, alpha: 1))]
            roof.position.y = 3
            house.addChildNode(roof)
            let hsc = 0.9 + rng.next() * 0.5
            house.scale = SCNVector3(hsc, hsc, hsc)
            house.position = SCNVector3(hp.x + hr.x * hlat, hgy - 0.3, hp.z + hr.z * hlat)
            house.eulerAngles.y = atan2(tans[hi].x, -tans[hi].z) + (rng.next() - 0.5) * 0.5
            houseContainer.addChildNode(house)
            placed += 1
        }
        scene.rootNode.addChildNode(houseContainer.flattenedClone())

        // rocks + guardrail posts
        let rockContainer = SCNNode()
        let rockGeo = SCNSphere(radius: 1)
        rockGeo.isGeodesic = true
        rockGeo.segmentCount = 4
        rockGeo.materials = [lambert(UIColor(red: 0.47, green: 0.44, blue: 0.37, alpha: 1))]
        for _ in 0..<50 {
            let ri = 10 + Int(rng.next() * Float(Self.count - 30))
            let rlat = -(6 + rng.next() * 40)
            let rp = pts[ri], rr2 = rights[ri]
            let rock = SCNNode(geometry: rockGeo)
            rock.position = SCNVector3(rp.x + rr2.x * rlat, groundY(ri, rlat), rp.z + rr2.z * rlat)
            let rs = 0.5 + rng.next() * 1.6
            rock.scale = SCNVector3(rs, rs * (0.7 + rng.next() * 0.5), rs)
            rock.eulerAngles.y = rng.next() * 3
            rockContainer.addChildNode(rock)
        }
        scene.rootNode.addChildNode(rockContainer.flattenedClone())

        let postContainer = SCNNode()
        let postGeo = SCNBox(width: 0.16, height: 0.85, length: 0.16, chamferRadius: 0)
        postGeo.materials = [lambert(UIColor(white: 0.91, alpha: 1))]
        var gi = 0
        while gi < Self.count {
            let gp = pts[gi], gr = rights[gi]
            let post = SCNNode(geometry: postGeo)
            post.position = SCNVector3(gp.x + gr.x * 5.1, gp.y + 0.42, gp.z + gr.z * 5.1)
            postContainer.addChildNode(post)
            gi += 4
        }
        scene.rootNode.addChildNode(postContainer.flattenedClone())
    }

    private func props() {
        // PR flags
        let flagImg = Textures.prFlag()
        for i in 0..<10 {
            let fi = 60 + i * (Self.count - 120) / 10
            let lat: Float = i % 2 == 0 ? -6.1 : 6.1
            let p = pts[fi], r = rights[fi]
            let gy = max(groundY(fi, lat), p.y)
            let pole = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 4.4))
            pole.geometry!.materials = [lambert(UIColor(white: 0.78, alpha: 1))]
            pole.position = SCNVector3(p.x + r.x * lat, gy + 2.2, p.z + r.z * lat)
            let flag = SCNNode(geometry: SCNPlane(width: 1.6, height: 1.05))
            let fm = lambert(.white)
            fm.diffuse.contents = flagImg
            fm.isDoubleSided = true
            flag.geometry!.materials = [fm]
            flag.position = SCNVector3(0.82, 1.55, 0)
            flag.eulerAngles.y = rng.next() * 6.28
            pole.addChildNode(flag)
            scene.rootNode.addChildNode(pole)
        }

        func arch(_ i2: Int, _ text: String, _ color: UIColor) {
            let p = pts[i2], t = tans[i2]
            let grp = SCNNode()
            let postGeo = SCNCylinder(radius: 0.14, height: 6)
            postGeo.materials = [lambert(UIColor(white: 0.95, alpha: 1))]
            for xo in [Float(-5.1), Float(5.1)] {
                let post = SCNNode(geometry: postGeo)
                post.position = SCNVector3(xo, 3, 0)
                grp.addChildNode(post)
            }
            let banner = SCNNode(geometry: SCNPlane(width: 10.6, height: 1.6))
            let bm = constant(.white)
            bm.diffuse.contents = Textures.banner(text: text, background: color)
            bm.isDoubleSided = true
            banner.geometry!.materials = [bm]
            banner.position.y = 5.6
            grp.addChildNode(banner)
            grp.simdPosition = p
            grp.simdLook(at: p + t, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
            scene.rootNode.addChildNode(grp)
        }
        arch(6, "¡SALIDA!", UIColor(red: 0.88, green: 0.13, blue: 0.22, alpha: 1))
        arch(Self.count - 8, "¡META!", UIColor(red: 0, green: 0.31, blue: 0.63, alpha: 1))

        // beach umbrellas
        let umbCols: [UIColor] = [.neonPinkUI, .neonGoldUI, .neonTealUI, .sunsetOrangeUI]
        for u in 0..<6 {
            let ui = Self.count - 30 - Int(rng.next() * 40)
            let ulat = (rng.next() < 0.5 ? 1 : -1) * (6 + rng.next() * 12)
            let ugy = groundY(ui, ulat)
            if ugy < -0.5 { continue }
            let up = pts[ui], ur = rights[ui]
            let umb = SCNNode()
            let pole = SCNNode(geometry: SCNCylinder(radius: 0.04, height: 2))
            pole.geometry!.materials = [lambert(UIColor(white: 0.87, alpha: 1))]
            pole.position.y = 1
            umb.addChildNode(pole)
            let top = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 1.5, height: 0.7))
            top.geometry!.materials = [lambert(umbCols[u % 4])]
            top.position.y = 1.9
            umb.addChildNode(top)
            umb.position = SCNVector3(up.x + ur.x * ulat, ugy, up.z + ur.z * ulat)
            umb.eulerAngles.z = (rng.next() - 0.5) * 0.3
            scene.rootNode.addChildNode(umb)
        }
    }

    // MARK: - potholes (merged into two geometries)

    private func potholes() {
        var hv: [simd_float3] = [], hi_: [Int32] = []
        var rv: [simd_float3] = [], ri_: [Int32] = []
        var hn: Int32 = 0, rn2: Int32 = 0
        let seg = 12

        func addHole(_ hs: Float, _ hx: Float, _ hr: Float) {
            let (pos, tan, rgt) = sample(hs)
            let c = pos + rgt * hx
            let rot = rng.next() * 6.28
            let sq = 0.75 + rng.next() * 0.5
            hv.append(simd_float3(c.x, c.y + 0.045, c.z))
            for k in 0...seg {
                let a = rot + Float(k) / Float(seg) * 2 * .pi
                let wob = 1 + 0.18 * sin(a * 3 + rot * 7)
                let ca = cos(a) * hr * wob, sa = sin(a) * hr * sq * wob
                hv.append(simd_float3(c.x + rgt.x * ca + tan.x * sa, c.y + 0.045,
                                      c.z + rgt.z * ca + tan.z * sa))
            }
            for k in 0..<seg { hi_.append(contentsOf: [hn, hn + 1 + Int32(k), hn + 2 + Int32(k)]) }
            hn += Int32(seg + 2)
            for k in 0...seg {
                let a = rot + Float(k) / Float(seg) * 2 * .pi
                let wob = 1 + 0.18 * sin(a * 3 + rot * 7)
                let ca = cos(a) * wob, sa = sin(a) * sq * wob
                rv.append(simd_float3(c.x + (rgt.x * ca + tan.x * sa) * hr, c.y + 0.038,
                                      c.z + (rgt.z * ca + tan.z * sa) * hr))
                let r2 = hr * 1.45
                rv.append(simd_float3(c.x + (rgt.x * ca + tan.x * sa) * r2, c.y + 0.038,
                                      c.z + (rgt.z * ca + tan.z * sa) * r2))
            }
            for k in 0..<seg {
                let b = rn2 + Int32(k * 2)
                ri_.append(contentsOf: [b, b + 1, b + 2, b + 1, b + 3, b + 2])
            }
            rn2 += Int32((seg + 1) * 2)
            holes.append(Hole(s: hs, x: hx, r: hr * sq + 0.15))
        }

        var cs: Float = 230
        while cs < Self.total - 260 {
            let n = 1 + Int(rng.next() * 4)
            let gapC = (rng.next() - 0.5) * 5.4
            for _ in 0..<n {
                var tries = 0
                var hx: Float = 0
                repeat { hx = (rng.next() - 0.5) * 7.4; tries += 1 }
                while abs(hx - gapC) < 2.2 && tries < 12
                if tries >= 12 { continue }
                addHole(cs + (rng.next() - 0.5) * 12, hx, 0.55 + rng.next() * 1.0)
            }
            cs += 46 + rng.next() * 72
        }

        let holeMat = constant(UIColor(red: 0.043, green: 0.043, blue: 0.063, alpha: 1))
        let rimMat = constant(UIColor(red: 0.34, green: 0.36, blue: 0.39, alpha: 1))
        let holeNode = SCNNode(geometry: makeGeometry(verts: hv, indices: hi_, material: holeMat))
        let rimNode = SCNNode(geometry: makeGeometry(verts: rv, indices: ri_, material: rimMat))
        holeNode.castsShadow = false
        rimNode.castsShadow = false
        scene.rootNode.addChildNode(holeNode)
        scene.rootNode.addChildNode(rimNode)
    }

    // MARK: - pickups, iguanas, traffic

    private func makePiraguas() {
        let flavors: [UIColor] = [
            UIColor(red: 1, green: 0.18, blue: 0.31, alpha: 1),
            UIColor(red: 1, green: 0.54, blue: 0.1, alpha: 1),
            UIColor(red: 0.18, green: 0.42, blue: 1, alpha: 1),
            UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1),
            UIColor(red: 0.76, green: 0.23, blue: 1, alpha: 1)
        ]
        for i in 0..<24 {
            let ps = 150 + (Float(i) + rng.next() * 0.6) * (Self.total - 380) / 24
            let px2 = (rng.next() - 0.5) * 6.4
            let (pos, _, rgt) = sample(ps)
            let grp = SCNNode()
            let cup = SCNNode(geometry: SCNCone(topRadius: 0.26, bottomRadius: 0, height: 0.4))
            cup.geometry!.materials = [lambert(UIColor(red: 0.96, green: 0.94, blue: 0.9, alpha: 1))]
            grp.addChildNode(cup)
            let ice = SCNNode(geometry: SCNSphere(radius: 0.27))
            let im = SCNMaterial()
            im.lightingModel = .lambert
            im.diffuse.contents = flavors[i % flavors.count]
            im.emission.contents = flavors[i % flavors.count]
            im.emission.intensity = 1.5
            ice.geometry!.materials = [im]
            ice.position.y = 0.24
            grp.addChildNode(ice)
            let world = pos + rgt * px2
            grp.position = SCNVector3(world.x, world.y + 1.0, world.z)
            scene.rootNode.addChildNode(grp)
            piraguas.append(Pickup(s: ps, x: px2, baseY: world.y + 1.0, node: grp))
        }
    }

    private func makeToolboxes() {
        let boxMat = SCNMaterial()
        boxMat.lightingModel = .lambert
        boxMat.diffuse.contents = UIColor(red: 0.85, green: 0.21, blue: 0.18, alpha: 1)
        boxMat.emission.contents = UIColor(red: 0.85, green: 0.21, blue: 0.18, alpha: 1)
        boxMat.emission.intensity = 0.5
        let bandMat = lambert(UIColor(white: 0.95, alpha: 1))
        for i in 0..<10 {
            let ts = 380 + (Float(i) + rng.next() * 0.5) * (Self.total - 700) / 10
            let tx = (rng.next() - 0.5) * 6
            let (pos, _, rgt) = sample(ts)
            let grp = SCNNode()
            let box = SCNNode(geometry: SCNBox(width: 0.52, height: 0.34, length: 0.38, chamferRadius: 0.04))
            box.geometry!.materials = [boxMat]
            grp.addChildNode(box)
            let band = SCNNode(geometry: SCNBox(width: 0.54, height: 0.1, length: 0.4, chamferRadius: 0.02))
            band.geometry!.materials = [bandMat]
            grp.addChildNode(band)
            let world = pos + rgt * tx
            grp.position = SCNVector3(world.x, world.y + 0.9, world.z)
            scene.rootNode.addChildNode(grp)
            toolboxes.append(Pickup(s: ts, x: tx, baseY: world.y + 0.9, node: grp))
        }
    }

    private func makeIguanas() {
        for i in 0..<12 {
            let mat = lambert(UIColor(red: 0.35, green: 0.56, blue: 0.24, alpha: 1))
            let grp = SCNNode()
            let body = SCNNode(geometry: SCNBox(width: 0.34, height: 0.22, length: 0.9, chamferRadius: 0.04))
            body.geometry!.materials = [mat]; body.position.y = 0.16
            grp.addChildNode(body)
            let head = SCNNode(geometry: SCNBox(width: 0.2, height: 0.16, length: 0.3, chamferRadius: 0.03))
            head.geometry!.materials = [mat]; head.position = SCNVector3(0, 0.2, -0.55)
            grp.addChildNode(head)
            let tail = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.1, height: 1.0))
            tail.geometry!.materials = [mat]
            tail.eulerAngles.x = -.pi / 2
            tail.position = SCNVector3(0, 0.14, 0.9)
            grp.addChildNode(tail)
            scene.rootNode.addChildNode(grp)
            let igS = 400 + Float(i) * (Self.total - 700) / 12 + rng.next() * 80
            let dir: Float = rng.next() < 0.5 ? 1 : -1
            var ig = Iguana(s: igS, x: -dir * (Self.roadHalf + 1.5), dir: dir, node: grp)
            positionIguana(&ig)
            iguanas.append(ig)
        }
    }

    private func positionIguana(_ ig: inout Iguana) {
        let (pos, _, rgt) = sample(ig.s)
        let world = pos + rgt * ig.x
        ig.node.simdPosition = simd_float3(world.x, pos.y + 0.05, world.z)
        let target = ig.node.simdPosition + rgt * ig.dir
        ig.node.simdLook(at: target, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
    }

    private func trafficCar(_ color: UIColor) -> SCNNode {
        let grp = SCNNode()
        let bodyMat = SCNMaterial()
        bodyMat.lightingModel = .blinn
        bodyMat.diffuse.contents = color
        bodyMat.specular.contents = UIColor.white
        let body = SCNNode(geometry: SCNBox(width: 1.7, height: 0.5, length: 3.6, chamferRadius: 0.08))
        body.geometry!.materials = [bodyMat]; body.position.y = 0.5
        grp.addChildNode(body)
        let cabin = SCNNode(geometry: SCNBox(width: 1.5, height: 0.45, length: 1.7, chamferRadius: 0.08))
        cabin.geometry!.materials = [lambert(UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1))]
        cabin.position = SCNVector3(0, 0.95, 0.2)
        grp.addChildNode(cabin)
        let wg = SCNCylinder(radius: 0.3, height: 0.22)
        wg.materials = [lambert(UIColor(red: 0.08, green: 0.09, blue: 0.1, alpha: 1))]
        for o in [SCNVector3(-0.8, 0.3, 1.15), SCNVector3(0.8, 0.3, 1.15),
                  SCNVector3(-0.8, 0.3, -1.15), SCNVector3(0.8, 0.3, -1.15)] {
            let w = SCNNode(geometry: wg)
            w.eulerAngles.z = .pi / 2
            w.position = o
            grp.addChildNode(w)
        }
        let tl = SCNNode(geometry: SCNBox(width: 1.5, height: 0.12, length: 0.06, chamferRadius: 0))
        tl.geometry!.materials = [constant(UIColor(red: 1, green: 0.13, blue: 0.13, alpha: 1))]
        tl.position = SCNVector3(0, 0.62, 1.84)
        grp.addChildNode(tl)
        return grp
    }

    private func makeTraffic() {
        let colors: [UIColor] = [
            UIColor(white: 0.85, alpha: 1),
            UIColor(red: 0.25, green: 0.42, blue: 0.85, alpha: 1),
            UIColor(red: 0.85, green: 0.7, blue: 0.25, alpha: 1),
            UIColor(white: 0.58, alpha: 1),
            UIColor(red: 0.4, green: 0.77, blue: 0.42, alpha: 1),
            UIColor(red: 0.77, green: 0.27, blue: 0.27, alpha: 1),
            UIColor(white: 0.94, alpha: 1)
        ]
        for i in 0..<7 {
            let node = trafficCar(colors[i % colors.count])
            scene.rootNode.addChildNode(node)
            traffic.append(Traffic(s: 300 + Float(i) * 420 + rng.next() * 150,
                                   x: i % 2 == 0 ? -1.9 : 1.9,
                                   v: 11 + rng.next() * 7, node: node))
        }
    }

    // MARK: - the car

    private func buildCar() {
        let paint = SCNMaterial()
        paint.lightingModel = .blinn
        paint.diffuse.contents = UIColor(red: 0.88, green: 0.13, blue: 0.22, alpha: 1)
        paint.specular.contents = UIColor.white
        paint.shininess = 0.6

        let body = SCNNode(geometry: SCNBox(width: 1.8, height: 0.42, length: 4.0, chamferRadius: 0.08))
        body.geometry!.materials = [paint]; body.position.y = 0.5
        chassisNode.addChildNode(body)

        let hood = SCNNode(geometry: SCNBox(width: 1.7, height: 0.2, length: 1.2, chamferRadius: 0.06))
        hood.geometry!.materials = [paint]
        hood.position = SCNVector3(0, 0.62, -1.35); hood.eulerAngles.x = -0.1
        chassisNode.addChildNode(hood)

        let stripe = SCNNode(geometry: SCNBox(width: 0.5, height: 0.03, length: 4.02, chamferRadius: 0))
        stripe.geometry!.materials = [lambert(UIColor(white: 0.96, alpha: 1))]
        stripe.position.y = 0.72
        chassisNode.addChildNode(stripe)

        let glass = SCNMaterial()
        glass.lightingModel = .blinn
        glass.diffuse.contents = UIColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 1)
        glass.specular.contents = UIColor(red: 0.67, green: 0.8, blue: 1, alpha: 1)
        glass.shininess = 0.9
        let cabin = SCNNode(geometry: SCNBox(width: 1.55, height: 0.5, length: 1.8, chamferRadius: 0.1))
        cabin.geometry!.materials = [glass]
        cabin.position = SCNVector3(0, 0.96, 0.25)
        chassisNode.addChildNode(cabin)

        let skirt = SCNNode(geometry: SCNBox(width: 1.84, height: 0.12, length: 4.02, chamferRadius: 0))
        skirt.geometry!.materials = [lambert(UIColor(red: 0, green: 0.31, blue: 0.63, alpha: 1))]
        skirt.position.y = 0.3
        chassisNode.addChildNode(skirt)

        let dark = lambert(UIColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 1))
        let spoiler = SCNNode(geometry: SCNBox(width: 1.6, height: 0.06, length: 0.4, chamferRadius: 0))
        spoiler.geometry!.materials = [dark]
        spoiler.position = SCNVector3(0, 0.95, 1.95)
        chassisNode.addChildNode(spoiler)

        // wheels: steer pivot > spin node
        let tireGeo = SCNCylinder(radius: 0.34, height: 0.26)
        tireGeo.materials = [lambert(UIColor(red: 0.08, green: 0.09, blue: 0.1, alpha: 1))]
        let hubGeo = SCNCylinder(radius: 0.18, height: 0.27)
        let hubMat = SCNMaterial()
        hubMat.lightingModel = .blinn
        hubMat.diffuse.contents = UIColor(red: 0.84, green: 0.71, blue: 0.29, alpha: 1)
        hubMat.specular.contents = UIColor.white
        hubGeo.materials = [hubMat]
        for o in [(x: Float(-0.85), z: Float(-1.28), front: true), (x: Float(0.85), z: Float(-1.28), front: true),
                  (x: Float(-0.85), z: Float(1.28), front: false), (x: Float(0.85), z: Float(1.28), front: false)] {
            let steer = SCNNode()
            steer.position = SCNVector3(o.x, 0.34, o.z)
            let spin = SCNNode()
            let tire = SCNNode(geometry: tireGeo)
            tire.eulerAngles.z = .pi / 2
            let hub = SCNNode(geometry: hubGeo)
            hub.eulerAngles.z = .pi / 2
            spin.addChildNode(tire)
            spin.addChildNode(hub)
            steer.addChildNode(spin)
            chassisNode.addChildNode(steer)
            spinWheelNodes.append(spin)
            if o.front { frontWheelNodes.append(steer) }
        }

        // headlights + beams (front is -Z)
        let hlMat = constant(UIColor(red: 1, green: 0.95, blue: 0.77, alpha: 1))
        hlMat.emission.contents = UIColor(red: 1, green: 0.95, blue: 0.77, alpha: 1)
        hlMat.emission.intensity = 2.2
        for xo in [Float(-0.6), Float(0.6)] {
            let hl = SCNNode(geometry: SCNBox(width: 0.32, height: 0.14, length: 0.06, chamferRadius: 0))
            hl.geometry!.materials = [hlMat]
            hl.position = SCNVector3(xo, 0.58, -2.01)
            chassisNode.addChildNode(hl)

            let beamMat = SCNMaterial()
            beamMat.lightingModel = .constant
            beamMat.diffuse.contents = UIColor(red: 1, green: 0.93, blue: 0.69, alpha: 1)
            beamMat.transparency = 0.09
            beamMat.blendMode = .add
            beamMat.writesToDepthBuffer = false
            beamMat.isDoubleSided = true
            let beam = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 1.5, height: 11))
            beam.geometry!.materials = [beamMat]
            beam.eulerAngles.x = .pi / 2        // wide end forward (-Z)
            beam.position = SCNVector3(xo, 0.55, -7.5)
            chassisNode.addChildNode(beam)
        }

        // brake lights
        brakeLightMaterial = constant(UIColor(red: 0.33, green: 0.04, blue: 0.04, alpha: 1))
        for xo in [Float(-0.62), Float(0.62)] {
            let bl = SCNNode(geometry: SCNBox(width: 0.4, height: 0.13, length: 0.06, chamferRadius: 0))
            bl.geometry!.materials = [brakeLightMaterial]
            bl.position = SCNVector3(xo, 0.6, 2.01)
            chassisNode.addChildNode(bl)
        }

        // nitro flames (rear, +Z)
        for xo in [Float(-0.45), Float(0.45)] {
            let fm = SCNMaterial()
            fm.lightingModel = .constant
            fm.diffuse.contents = UIColor(red: 0.35, green: 0.84, blue: 1, alpha: 1)
            fm.emission.contents = UIColor(red: 0.35, green: 0.84, blue: 1, alpha: 1)
            fm.emission.intensity = 2.6
            fm.blendMode = .add
            fm.writesToDepthBuffer = false
            let flame = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.12, height: 1.0))
            flame.geometry!.materials = [fm]
            flame.eulerAngles.x = -.pi / 2     // point backward
            flame.position = SCNVector3(xo, 0.36, 2.5)
            flame.isHidden = true
            chassisNode.addChildNode(flame)
            flameNodes.append(flame)
        }

        // underglow
        glowMaterial = constant(UIColor(red: 0.07, green: 0.84, blue: 0.76, alpha: 1))
        glowMaterial.emission.contents = UIColor(red: 0.07, green: 0.84, blue: 0.76, alpha: 1)
        glowMaterial.emission.intensity = 2.0
        glowMaterial.blendMode = .add
        glowMaterial.writesToDepthBuffer = false
        glowMaterial.transparency = 0.4
        let glow = SCNNode(geometry: SCNPlane(width: 2.6, height: 4.6))
        glow.geometry!.materials = [glowMaterial]
        glow.eulerAngles.x = -.pi / 2
        glow.position.y = 0.08
        chassisNode.addChildNode(glow)

        // soft blob under the car
        let blobMat = constant(UIColor.black)
        blobMat.diffuse.contents = Textures.blobShadow()
        blobMat.transparency = 1
        blobMat.writesToDepthBuffer = false
        blobNode.geometry = SCNPlane(width: 3.4, height: 5.2)
        blobNode.geometry!.materials = [blobMat]
        blobNode.eulerAngles.x = -.pi / 2
        blobNode.castsShadow = false
        scene.rootNode.addChildNode(blobNode)
    }

    private func particles() {
        let puffImg = Textures.softCircle()

        smokeSystem.particleImage = puffImg
        smokeSystem.birthRate = 0
        smokeSystem.particleLifeSpan = 0.7
        smokeSystem.particleSize = 0.7
        smokeSystem.particleSizeVariation = 0.3
        smokeSystem.particleVelocity = 2.5
        smokeSystem.particleVelocityVariation = 1.5
        smokeSystem.spreadingAngle = 60
        smokeSystem.emittingDirection = SCNVector3(0, 1, 1)
        smokeSystem.particleColor = UIColor(white: 0.85, alpha: 0.6)
        smokeSystem.blendMode = .alpha
        let smokeNode = SCNNode()
        smokeNode.position = SCNVector3(0, 0.2, 1.9)
        smokeNode.addParticleSystem(smokeSystem)
        chassisNode.addChildNode(smokeNode)

        dustSystem.particleImage = puffImg
        dustSystem.birthRate = 0
        dustSystem.particleLifeSpan = 0.6
        dustSystem.particleSize = 0.6
        dustSystem.particleVelocity = 4
        dustSystem.particleVelocityVariation = 3
        dustSystem.spreadingAngle = 180
        dustSystem.particleColor = UIColor(red: 0.54, green: 0.48, blue: 0.36, alpha: 0.7)
        dustNode.addParticleSystem(dustSystem)

        // speed streaks: static motes hanging ahead of the car — the camera's
        // motion blur stretches them into wind streaks at speed
        streakSystem.particleImage = puffImg
        streakSystem.birthRate = 0
        streakSystem.particleLifeSpan = 1.6
        streakSystem.particleSize = 0.09
        streakSystem.particleVelocity = 0
        streakSystem.emitterShape = SCNBox(width: 26, height: 7, length: 50, chamferRadius: 0)
        streakSystem.birthLocation = .volume
        streakSystem.particleColor = UIColor(red: 1, green: 0.95, blue: 0.87, alpha: 0.65)
        streakSystem.blendMode = .additive
        let streakNode = SCNNode()
        streakNode.position = SCNVector3(0, 2.5, -26)
        streakNode.addParticleSystem(streakSystem)
        playerNode.addChildNode(streakNode)
    }

    // MARK: - game flow

    private func resetGame() {
        s = 4; v = 8; x = 0; xd = 0
        hp = 100; nitro = 60
        score = 0; styleRun = 0; combo = 0
        topSpeed = 0; holesHit = 0; nearMisses = 0
        shake = 0; flashT = 0; jolt = 0
        driftYaw = 0; leanRoll = 0; pitchAng = 0
        playTime = 0
        cd = 3.4; cdLabel = ""
        for i in 0..<holes.count { holes[i].passed = false; holes[i].hit = false }
        for i in 0..<piraguas.count {
            piraguas[i].taken = false
            piraguas[i].node.isHidden = false
        }
        for i in 0..<toolboxes.count {
            toolboxes[i].taken = false
            toolboxes[i].node.isHidden = false
        }
        for i in 0..<iguanas.count {
            iguanas[i].stateRaw = 0; iguanas[i].hit = false
            iguanas[i].x = -iguanas[i].dir * (Self.roadHalf + 1.5)
            iguanas[i].node.eulerAngles.z = 0
            positionIguana(&iguanas[i])
        }
        for i in 0..<traffic.count {
            traffic[i].s = 300 + Float(i) * 420 + rng.next() * 150
            traffic[i].cool = 0; traffic[i].missed = false
        }
        phase = .countdown
        let (pos, tan, _) = sample(s)
        camPos = pos - tan * 7 + simd_float3(0, 2.6, 0)
        camLook = pos + tan * 8
        cameraNode.simdPosition = camPos
        cameraNode.simdLook(at: camLook, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        let (carP, carT, _) = sample(s)
        playerNode.simdPosition = carP + simd_float3(0, 0.02, 0)
        playerNode.simdLook(at: carP + carT, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        DispatchQueue.main.async {
            self.state.phase = .countdown
            self.state.paused = false
            self.state.combo = 0
            self.state.countLabel = ""
            self.state.newRecordScore = false
            self.state.newRecordTime = false
        }
    }

    private func endGame(dead: Bool) {
        phase = dead ? .dead : .finished
        let mm = Int(playTime) / 60
        let ss = playTime.truncatingRemainder(dividingBy: 60)
        let timeStr = String(format: "%d:%04.1f", mm, ss)
        let sc = Int(score), top = Int(topSpeed * 3.6)
        let hh = holesHit, nm = nearMisses
        // records
        let defaults = UserDefaults.standard
        let newScoreRec = sc > defaults.integer(forKey: "hoyo_bestScore")
        if newScoreRec { defaults.set(sc, forKey: "hoyo_bestScore") }
        var newTimeRec = false
        if !dead {
            let bestTime = defaults.double(forKey: "hoyo_bestTime")
            if bestTime == 0 || playTime < bestTime {
                newTimeRec = true
                defaults.set((playTime * 10).rounded() / 10, forKey: "hoyo_bestTime")
            }
        }
        DispatchQueue.main.async {
            self.state.statTime = timeStr
            self.state.statScore = sc
            self.state.statTopSpeed = top
            self.state.statHolesHit = hh
            self.state.statNearMisses = nm
            self.state.newRecordScore = newScoreRec
            self.state.newRecordTime = newTimeRec
            self.state.refreshRecordLine()
            self.state.phase = dead ? .dead : .finished
        }
        if !dead { sound.playCoqui() } else { sound.playThunk() }
        sound.engineLevel = 0; sound.windLevel = 0; sound.skidLevel = 0; sound.nitroLevel = 0
        streakSystem.birthRate = 0
        smokeSystem.birthRate = 0
    }

    private func damage(_ amount: Float, _ msg: String?) {
        hp -= amount
        flashT = 1
        combo = 0
        if let msg = msg {
            DispatchQueue.main.async {
                self.state.popup(msg)
                self.state.combo = 0
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
        if hp <= 0 { hp = 0; endGame(dead: true) }
    }

    private func lightHaptic() {
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func popupAsync(_ msg: String) {
        DispatchQueue.main.async { self.state.popup(msg) }
    }

    // MARK: - per-frame update

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if lastTime < 0 { lastTime = time }
        let dt = Float(min(time - lastTime, 0.033))
        lastTime = time

        if state.requestStart { state.requestStart = false; sound.start(); resetGame() }
        if state.requestReset { state.requestReset = false; resetGame() }

        // scroll the water sparkle
        if let n = oceanNormal {
            let fx = Float(time * 0.015).truncatingRemainder(dividingBy: 1)
            let scaleM = SCNMatrix4MakeScale(60, 60, 1)
            n.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeTranslation(fx, fx * 0.6, 0), scaleM)
        }

        if state.paused && phase == .playing {
            sound.engineLevel = 0; sound.windLevel = 0
            sound.skidLevel = 0; sound.nitroLevel = 0
            return
        }

        switch phase {
        case .intro:
            let ft = Float(time * 22).truncatingRemainder(dividingBy: Self.total * 0.6)
            let (p1, _, r1) = sample(ft + 100)
            let target = p1 - r1 * 14 + simd_float3(0, 11, 0)
            camPos = simd_mix(camPos, target, simd_float3(repeating: 0.03))
            cameraNode.simdPosition = camPos
            let (p2, _, _) = sample(ft + 160)
            cameraNode.simdLook(at: p2, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
            return
        case .countdown:
            cd -= dt
            let lbl = cd > 2.4 ? "3" : cd > 1.4 ? "2" : cd > 0.4 ? "1" : "¡DALE!"
            if lbl != cdLabel {
                cdLabel = lbl
                sound.playBeep(final: lbl == "¡DALE!")
                DispatchQueue.main.async { self.state.countLabel = lbl }
            }
            if cd <= -0.4 {
                phase = .playing
                DispatchQueue.main.async {
                    self.state.countLabel = ""
                    self.state.phase = .playing
                }
            }
            return
        case .finished, .dead:
            return
        case .playing:
            break
        }

        playTime += Double(dt)

        // ----- physics -----
        let i = Int(simd_clamp(s / Self.step, 0, Float(Self.count - 2)))
        let grade = grades[i]
        let curv = curvs[i]
        let input = state.input
        let braking = input.brake
        let wantNitro = input.nitro && nitro > 0
        var steer: Float = 0
        if input.left { steer -= 1 }
        if input.right { steer += 1 }
        let drifting = braking && steer != 0 && v > 12
        let offroad = abs(x) > Self.roadHalf + 0.3

        var acc: Float = 9.0 - grade * 9.81 * 4
        acc -= 0.0042 * v * v
        if wantNitro { acc += 14; nitro = max(0, nitro - 26 * dt) }
        else { nitro = min(100, nitro + 3.5 * dt) }
        if braking && !drifting { acc -= 15 }
        if drifting { acc -= 5 }
        if offroad { acc -= 9 }
        v = simd_clamp(v + acc * dt, 0, wantNitro ? 64 : 50)
        topSpeed = max(topSpeed, v)
        s += v * dt

        brakeLightMaterial.diffuse.contents = braking
            ? UIColor(red: 1, green: 0.13, blue: 0.13, alpha: 1)
            : UIColor(red: 0.33, green: 0.04, blue: 0.04, alpha: 1)
        brakeLightMaterial.emission.contents = UIColor(red: 1, green: 0.13, blue: 0.13, alpha: 1)
        brakeLightMaterial.emission.intensity = braking ? 2.4 : 0
        for f in flameNodes {
            f.isHidden = !wantNitro
            if wantNitro { f.scale = SCNVector3(1, 0.7 + Float.random(in: 0...0.9), 1) }
        }

        let targetXd = steer * simd_clamp(4 + v * 0.30, 0, 16) * (drifting ? 1.35 : 1)
        let grip: Float = drifting ? 3.2 : 6.5
        xd += (targetXd - xd) * min(1, grip * dt)
        xd += -curv * v * v * dt * (drifting ? 0.45 : 0.35)
        x += xd * dt
        x = simd_clamp(x, -10, 10)

        smokeSystem.birthRate = drifting ? 90 : 0
        if drifting {
            styleRun += v * dt * 4
        } else if styleRun > 0 {
            if styleRun > 50 { popupAsync("¡WEPA! +\(Int(styleRun))") }
            score += styleRun
            styleRun = 0
        }
        score += v * dt * 1.2

        // cliff / offroad
        if abs(x) > 8.6 && v > 4 {
            sound.playThunk()
            shake = 1
            v *= 0.3
            x = simd_clamp(x, -3, 3) * 0.3; xd = 0
            damage(22, "¡AY BENDITO!")
        } else if offroad && v > 8 {
            shake = max(shake, 0.25)
            if Float.random(in: 0...1) < dt * 2.2 { damage(3, nil) }
        }

        // potholes
        for hIdx in 0..<holes.count {
            let ds = holes[hIdx].s - s
            if ds < -6 || ds > 6 { continue }
            let h = holes[hIdx]
            if !h.hit && abs(ds) < 1.8 && abs(h.x - x) < h.r + 0.75 {
                holes[hIdx].hit = true
                holesHit += 1
                v *= 0.62
                shake = 1.1; jolt = 1
                sound.playThunk()
                damage(9 + h.r * 9 + v * 0.18, "¡HOYO!")
                let (pp, _, rr3) = sample(s)
                dustNode.simdPosition = pp + rr3 * x + simd_float3(0, 0.3, 0)
                dustSystem.birthRate = 350
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.dustSystem.birthRate = 0
                }
            } else if !h.passed && !h.hit && ds < -2 {
                holes[hIdx].passed = true
                if abs(h.x - x) < h.r + 2.2 {
                    nearMisses += 1
                    combo = min(combo + 1, 5)
                    score += Float(40 * combo)
                    let c = combo
                    DispatchQueue.main.async { self.state.combo = c }
                    if combo >= 2 { popupAsync("¡CASI! x\(combo) +\(40 * combo)") }
                    else if nearMisses % 3 == 0 { popupAsync("¡CASI! +40") }
                }
            }
        }

        // toolboxes — el mecánico repairs on the fly
        for tbi in 0..<toolboxes.count {
            let tb = toolboxes[tbi]
            if !tb.taken && abs(tb.s - s) < 2.4 && abs(tb.x - x) < 1.6 {
                toolboxes[tbi].taken = true
                tb.node.isHidden = true
                hp = min(100, hp + 22)
                score += 50
                sound.playCoqui()
                lightHaptic()
                popupAsync("¡MECÁNICO! +VIDA")
            }
        }

        // piraguas
        for qi in 0..<piraguas.count {
            let q = piraguas[qi]
            if !q.taken && abs(q.s - s) < 2.4 && abs(q.x - x) < 1.6 {
                piraguas[qi].taken = true
                q.node.isHidden = true
                nitro = min(100, nitro + 35)
                score += 100
                sound.playCoqui()
                lightHaptic()
                popupAsync("¡PIRAGUA! +NITRO")
            }
        }

        // iguanas
        for gi in 0..<iguanas.count {
            let igDs = iguanas[gi].s - s
            if iguanas[gi].stateRaw == 0 && igDs > 0 && igDs < 40 + v * 2.2 { iguanas[gi].stateRaw = 1 }
            if iguanas[gi].stateRaw == 1 {
                iguanas[gi].x += iguanas[gi].dir * 7.5 * dt
                if abs(iguanas[gi].x) > Self.roadHalf + 1.5 && iguanas[gi].x * iguanas[gi].dir > 0 {
                    iguanas[gi].stateRaw = 2
                }
            }
            if !iguanas[gi].hit && iguanas[gi].stateRaw == 1 &&
               abs(igDs) < 2 && abs(iguanas[gi].x - x) < 1.2 {
                iguanas[gi].hit = true
                iguanas[gi].stateRaw = 2
                iguanas[gi].node.eulerAngles.z = 2.6
                shake = max(shake, 0.6)
                sound.playThunk()
                damage(8, "¡LA IGUANA!")
            }
            if iguanas[gi].stateRaw != 0 { positionIguana(&iguanas[gi]) }
        }

        // traffic
        for ti in 0..<traffic.count {
            traffic[ti].cool = max(0, traffic[ti].cool - dt)
            traffic[ti].s += traffic[ti].v * dt
            if traffic[ti].s > s + 600 || traffic[ti].s < s - 120 || traffic[ti].s > Self.total - 40 {
                traffic[ti].s = s + 260 + rng.next() * 320
                traffic[ti].x = rng.next() < 0.5 ? -1.9 : 1.9
                traffic[ti].v = 11 + rng.next() * 7
                traffic[ti].missed = false; traffic[ti].cool = 0
                if traffic[ti].s > Self.total - 60 { traffic[ti].s = Self.total * 2 }
            }
            let tc = traffic[ti]
            let tDs = tc.s - s
            if tc.cool <= 0 && abs(tDs) < 3.2 && abs(tc.x - x) < 1.7 {
                traffic[ti].cool = 2
                v = min(v, tc.v * 0.8)
                shake = 1.2; jolt = 1
                sound.playThunk(); sound.playHorn()
                damage(30, "¡EL TAPÓN!")
            } else if !tc.missed && tDs < -1 && tDs > -8 && abs(tc.x - x) < 3 &&
                      abs(tc.x - x) > 1.7 && v - tc.v > 12 {
                traffic[ti].missed = true
                combo = min(combo + 1, 5)
                score += Float(80 * combo)
                let c = combo
                DispatchQueue.main.async { self.state.combo = c }
                sound.playHorn()
                popupAsync("¡FUA! +\(80 * combo)")
            }
            if tDs > -150 && tDs < 700 {
                tc.node.isHidden = false
                let (pp, tt, rr4) = sample(tc.s)
                tc.node.simdPosition = pp + rr4 * tc.x
                tc.node.simdLook(at: tc.node.simdPosition + tt,
                                 up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
            } else { tc.node.isHidden = true }
        }

        if s >= Self.total - 8 { endGame(dead: false) }

        // ----- place the car -----
        let (pos, tan, rgt) = sample(s)
        let carPos = pos + rgt * x + simd_float3(0, 0.02, 0)
        playerNode.simdPosition = carPos
        playerNode.simdLook(at: carPos + tan, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))

        let tNow = Float(time)
        leanRoll += ((-steer * 0.09 - xd * 0.012) - leanRoll) * min(1, 8 * dt)
        driftYaw += ((-xd * 0.03 - (drifting ? steer * 0.5 : 0)) - driftYaw) * min(1, 6 * dt)
        pitchAng += ((braking ? 0.05 : (wantNitro ? -0.035 : 0)) - pitchAng) * min(1, 6 * dt)
        if jolt > 0 { jolt = max(0, jolt - dt * 4) }
        chassisNode.eulerAngles = SCNVector3(pitchAng + jolt * 0.08 * sin(tNow * 60), driftYaw, leanRoll)
        chassisNode.position.y = -jolt * 0.12 * abs(sin(tNow * 42))

        wheelSpin += v * dt / 0.34
        for w in spinWheelNodes { w.eulerAngles.x = -wheelSpin }
        for w in frontWheelNodes { w.eulerAngles.y = -steer * 0.35 }
        glowMaterial.transparency = CGFloat(0.3 + 0.18 * sin(tNow * 9))

        blobNode.simdPosition = simd_float3(carPos.x, pos.y + 0.03, carPos.z)
        blobNode.eulerAngles = SCNVector3(-.pi / 2, atan2(tan.x, -tan.z), 0)

        // ----- camera -----
        let camDist = 6.4 + v * 0.055
        var target = carPos - tan * camDist
        target.y += 2.2 + v * 0.012
        target += rgt * (x * 0.1)
        let k = 1 - exp(-dt * 5.5)
        camPos = simd_mix(camPos, target, simd_float3(repeating: k))
        var lookTarget = carPos + tan * 10
        lookTarget.y += 1.0
        camLook = simd_mix(camLook, lookTarget, simd_float3(repeating: k))
        var finalCam = camPos
        let rumble: Float = v > 40 ? (v - 40) * 0.004 : 0
        if shake > 0.01 {
            finalCam.x += Float.random(in: -0.5...0.5) * shake
            finalCam.y += Float.random(in: -0.45...0.45) * shake
            shake *= exp(-dt * 4)
        }
        finalCam.x += Float.random(in: -1...1) * rumble
        finalCam.y += Float.random(in: -1...1) * rumble
        cameraNode.simdPosition = finalCam
        cameraNode.simdLook(at: camLook, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        // subtle camera roll into the carve — sells the speed
        cameraNode.simdOrientation = simd_mul(cameraNode.simdOrientation,
            simd_quatf(angle: leanRoll * 0.45, axis: simd_float3(0, 0, 1)))
        let targetFov = CGFloat(72 + v * 0.6 + (wantNitro ? 4 : 0))
        fov += (min(max(targetFov, 72), 116) - fov) * CGFloat(min(1, 4.5 * dt))
        cameraNode.camera?.fieldOfView = fov

        // wind streaks fade in past ~90 km/h
        streakSystem.birthRate = v > 25 ? CGFloat((v - 25) * 6) : 0

        // ----- audio -----
        sound.engineFreq = Double(55 + v * 3.2 + (wantNitro ? 30 : 0))
        sound.engineLevel = Double(0.05 + simd_clamp(v / 64, 0, 1) * 0.075)
        sound.windLevel = Double(simd_clamp(v / 90, 0, 0.35))
        sound.skidLevel = drifting ? Double(simd_clamp(v / 140, 0, 0.22)) : 0
        sound.nitroLevel = wantNitro ? 0.05 : 0

        // pickups idle animation
        for q in piraguas where !q.taken {
            q.node.position.y = q.baseY + sin(tNow * 3 + q.s) * 0.16
            q.node.eulerAngles.y += 2.4 * dt
        }
        for tb in toolboxes where !tb.taken {
            tb.node.position.y = tb.baseY + sin(tNow * 3 + tb.s * 2) * 0.14
            tb.node.eulerAngles.y += 1.8 * dt
        }

        // ----- HUD -----
        if flashT > 0 { flashT -= dt * 2.2 }
        let hud = (speed: Int(v * 3.6), score: Int(score), hp: Double(hp), nitroV: Double(nitro),
                   prog: Double(s / Self.total), norm: Double(simd_clamp((v - 20) / 30, 0, 1)),
                   fl: Double(max(0, flashT)), nitroOn: wantNitro, time: playTime)
        DispatchQueue.main.async {
            self.state.speedKmh = hud.speed
            self.state.score = hud.score
            self.state.hp = hud.hp
            self.state.nitro = hud.nitroV
            self.state.progress = hud.prog
            self.state.speedNorm = hud.norm
            self.state.flash = hud.fl
            self.state.nitroActive = hud.nitroOn
            let mm = Int(hud.time) / 60
            let ss = hud.time.truncatingRemainder(dividingBy: 60)
            self.state.timeText = String(format: "%d:%04.1f", mm, ss)
        }
    }
}

// MARK: - UIColor bridge for the shared palette

extension UIColor {
    static let neonPinkUI = UIColor(red: 1.0, green: 0.18, blue: 0.47, alpha: 1)
    static let neonTealUI = UIColor(red: 0.07, green: 0.84, blue: 0.76, alpha: 1)
    static let neonGoldUI = UIColor(red: 1.0, green: 0.82, blue: 0.25, alpha: 1)
    static let sunsetOrangeUI = UIColor(red: 1.0, green: 0.54, blue: 0.36, alpha: 1)
}
