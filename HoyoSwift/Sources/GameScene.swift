import SceneKit
import SwiftUI
import Metal
import simd

// MARK: - deterministic rng

/// Park–Miller LCG. Two instances are used: one seeded once for the *world*
/// (road path, terrain, vegetation, props — built a single time), and one
/// reseeded per run for the *hazard layout*, so no two races are the same.
struct Lcg {
    var seed: UInt64
    init(_ s: UInt64) {
        let m = s % 2147483647
        seed = m == 0 ? 1 : m
    }
    mutating func next() -> Float {
        seed = (seed &* 16807) % 2147483647
        return Float(seed - 1) / Float(2147483646)
    }
}

// MARK: - render quality tiers

/// SceneKit's HDR pipeline plus 4× MSAA plus a 2048 shadow map is a lot to ask
/// of an A12. Pick the budget from the GPU family instead of hoping.
enum Quality {
    case low, medium, high

    static func detect() -> Quality {
        guard let device = MTLCreateSystemDefaultDevice() else { return .low }
        if device.supportsFamily(.apple8) { return .high }        // A15 and up
        if device.supportsFamily(.apple6) { return .medium }      // A13 / A14
        return .low
    }

    var antialiasing: SCNAntialiasingMode {
        switch self {
        case .high: return .multisampling4X
        case .medium: return .multisampling2X
        case .low: return .none
        }
    }

    var shadowMapSize: CGFloat {
        switch self {
        case .high: return 2048
        case .medium: return 1536
        case .low: return 1024
        }
    }

    var motionBlur: CGFloat {
        switch self {
        case .high: return 0.35
        case .medium: return 0.25
        case .low: return 0
        }
    }

    /// Skid-trail segments per wheel.
    var skidSegments: Int {
        switch self {
        case .high: return 52
        case .medium: return 36
        case .low: return 22
        }
    }

    var streakScale: CGFloat {
        switch self {
        case .high: return 1.0
        case .medium: return 0.7
        case .low: return 0.4
        }
    }
}

// MARK: - game controller

final class GameScene: NSObject, SCNSceneRendererDelegate {

    // course
    static let step: Float = 2
    static let count = 1801
    static let total: Float = Float(count - 1) * 2.0
    /// Four lanes of ~3.4 m — 13.6 m of asphalt, up from 11 (and 9 originally).
    static let roadHalf: Float = 6.8
    static let laneCount = 4
    /// Dirt shoulder between the asphalt edge and the guardrail — slow and
    /// scrapey, but recoverable.
    static let shoulderWidth: Float = 1.7
    /// Hard boundary. The guardrail posts are drawn exactly here so the limit you
    /// hit is the limit you can see.
    static var barrier: Float { roadHalf + shoulderWidth }
    /// Centre of each of the four lanes.
    static var laneCentres: [Float] {
        let w = roadHalf / Float(laneCount)          // half a lane
        return [-3 * w, -w, w, 3 * w]
    }
    /// Flat sea bed the terrain bottoms out on, and the water level just above it.
    static let seaFloor: Float = -6.5
    static let seaLevel: Float = -6.0

    let scene = SCNScene()
    private let state: GameState
    private let sound: SoundEngine
    private let quality: Quality

    private var worldRng = Lcg(20260727)
    private var runRng = Lcg(1)
    private var runSeed: UInt64 = 0

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
    private var ufoLightRing = SCNNode()
    private let policeRedMat: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(red: 1, green: 0.12, blue: 0.18, alpha: 1)
        m.emission.contents = UIColor(red: 1, green: 0.12, blue: 0.18, alpha: 1)
        return m
    }()
    private let policeBlueMat: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(red: 0.20, green: 0.42, blue: 1, alpha: 1)
        m.emission.contents = UIColor(red: 0.20, green: 0.42, blue: 1, alpha: 1)
        return m
    }()
    private var flameNodes: [SCNNode] = []
    private var brakeLightMaterial = SCNMaterial()
    private var glowMaterial = SCNMaterial()
    private var smokeSystem = SCNParticleSystem()
    private var dustSystem = SCNParticleSystem()
    private let dustNode = SCNNode()
    private var sparkSystem = SCNParticleSystem()
    private let sparkNode = SCNNode()
    private var oceanNormal: SCNMaterialProperty?
    private let holeNode = SCNNode()
    private let rimNode = SCNNode()

    // skid trail — a pool of unit quads, transform-only (no per-frame geometry churn)
    private var skidNodes: [SCNNode] = []
    private var skidAge: [Float] = []
    private var skidCursor = 0
    private var lastSkidL: simd_float3?
    private var lastSkidR: simd_float3?
    private var skidTimer: Float = 0
    private static let skidInterval: Float = 0.06
    /// Derived from the pool size: if marks outlived the ring buffer, the cursor
    /// would recycle a slot that was still supposed to be on screen and the tail
    /// of the trail would teleport to the front.
    private var skidLife: Float { Float(quality.skidSegments) * Self.skidInterval * 0.95 }

    // entities
    private struct Hole { var s, x, r: Float; var passed = false; var hit = false
                          /// sealed by the beam — no longer does damage
                          var zapped = false }
    private var holes: [Hole] = []
    private struct Pickup { var s: Float = 0, x: Float = 0, baseY: Float = 0
                            var node: SCNNode; var taken = false }
    private var piraguas: [Pickup] = []
    private var toolboxes: [Pickup] = []
    private struct Iguana {
        var s: Float = 0, x: Float = 0; var dir: Float = 1; var node: SCNNode
        var stateRaw = 0   // 0 wait, 1 run, 2 done
        var hit = false
    }
    private var iguanas: [Iguana] = []
    private struct Traffic {
        var s: Float = 0, x: Float = 0, v: Float = 0; var node: SCNNode
        var cool: Float = 0; var missed = false
        /// Lateral velocity while being shoved aside, and the yaw it picks up.
        var vx: Float = 0, spin: Float = 0
        var clearedByJump = false
        var isPolice = false
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
    private var invuln: Float = 0
    // jump
    private var jumpY: Float = 0        // height above the road
    private var jumpVel: Float = 0
    private var jumpCool: Float = 0
    // beam
    private var charge: Float = 100
    private var fireCool: Float = 0
    private struct Bolt { var s: Float = 0, x: Float = 0; var node: SCNNode; var live = false }
    private var bolts: [Bolt] = []
    private var boltCursor = 0
    private var patchNodes: [SCNNode] = []
    private var patchCursor = 0
    private static let boltSpeed: Float = 115
    private static let shotCost: Float = 32
    private var airborne: Bool { jumpY > 0.02 }
    private static let gravity: Float = 26
    private static let jumpImpulse: Float = 8.4
    private var dustT: Float = 0
    private var sparkT: Float = 0
    private var rumbleHapticT: Float = 0
    private var driftYaw: Float = 0, leanRoll: Float = 0, pitchAng: Float = 0
    private var playTime: Double = 0
    private var lastTime: TimeInterval = -1
    private var camPos = simd_float3(0, 3, 8)
    private var camLook = simd_float3(0, 0, 0)
    private var fov: CGFloat = 62
    private var wheelSpin: Float = 0
    private var hudClock: Float = 0
    private var lastCombo = -1
    private var lastRegion: Region?

    /// Haze colour per region — cool violet high up, dusty warm through town,
    /// bright sea-peach on the coast.
    private var arrivalT: Float = 0
    private var introT: Float = 0
    private var introSet = SCNNode()
    private let introUfo = SCNNode()
    private var introUfoRing = SCNNode()
    private var searchlights: [SCNNode] = []

    private static let regionFog: [simd_float3] = [
        simd_float3(0.86, 0.58, 0.62),
        simd_float3(1.00, 0.66, 0.44),
        simd_float3(1.00, 0.78, 0.58)
    ]

    /// Camera framing. The old values sat 6.4–10 m back with a 72° lens, which
    /// shrank the car to a few percent of the screen.
    private static let baseFov: CGFloat = 62

    /// `-autoplay` launch argument: self-driving smoke-test mode.
    static let autoplay = ProcessInfo.processInfo.arguments.contains("-autoplay")

    /// `-startAt <metres>`: drop in partway down the course. Handy for looking at
    /// the pueblo or the costa without surviving the whole descent first.
    static let startOffset: Float = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-startAt"), i + 1 < args.count,
           let v = Float(args[i + 1]) {
            return simd_clamp(v, 40, total - 200)
        }
        return 40
    }()

    init(state: GameState, sound: SoundEngine, quality: Quality) {
        self.state = state
        self.sound = sound
        self.quality = quality
        super.init()
        buildPath()
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

    // MARK: - regions

    private static func smoothStep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = simd_clamp((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Blend weights for (cordillera, pueblo, costa) at a course fraction. The
    /// crossfade is deliberately wide — hard region seams look like a mistake.
    private static func regionWeights(_ p: Float) -> simd_float3 {
        let fade: Float = 0.055                       // ~200 m either side
        let pueblo = Region.pueblo.span.lo, costa = Region.costa.span.lo
        let a = 1 - smoothStep(pueblo - fade, pueblo + fade, p)
        let c = smoothStep(costa - fade, costa + fade, p)
        return simd_float3(a, max(0, 1 - a - c), c)
    }

    /// A world-build index drawn from inside one region's span.
    private func indexIn(_ region: Region, _ rng: inout Lcg, inset: Float = 0.01) -> Int {
        let s = region.span
        let f = (s.lo + inset) + rng.next() * max(0.01, (s.hi - inset) - (s.lo + inset))
        return min(Self.count - 4, max(4, Int(f * Float(Self.count))))
    }

    /// Picks a region from three weights.
    private func pickRegion(_ rng: inout Lcg, _ w: simd_float3) -> Region {
        let r = rng.next() * (w.x + w.y + w.z)
        if r < w.x { return .cordillera }
        if r < w.x + w.y { return .pueblo }
        return .costa
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
            // Gentler seaward slope (was 0.34) so the ground reaches the water
            // line much further out — the sea used to lap almost at the road edge
            // wherever the road ran low.
            let k2 = 0.20 + 0.07 * sin(sd / 120 + 2)
            yy = p.y - d * k2 + sin(d * 0.19 + sd * 0.017) * min(d * 0.12, 3)
        }
        return max(yy, Self.seaFloor)
    }

    // MARK: - geometry helpers

    private func makeGeometry(verts: [simd_float3], indices: [Int32],
                              uvs: [CGPoint]? = nil, colors: [simd_float3]? = nil,
                              material: SCNMaterial) -> SCNGeometry {
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

    // MARK: - world build (runs off the main thread)

    /// Everything expensive — the sky cubemap's 400k `powf` calls, the road and
    /// terrain meshes, 120 palms — happens here, on a background queue, into a
    /// *detached* node. `attach` then hooks it up in one main-thread step.
    /// Building straight into a live scene from another thread would race the
    /// renderer; building detached does not.
    func buildWorld() -> (world: SCNNode, sky: [UIImage]) {
        let world = SCNNode()
        let sky = Textures.skyCubemap()

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = UIColor(red: 0.50, green: 0.42, blue: 0.50, alpha: 1)
        world.addChildNode(ambient)

        let sunNode = SCNNode()
        sunNode.light = SCNLight()
        sunNode.light!.type = .directional
        sunNode.light!.color = UIColor(red: 1.0, green: 0.82, blue: 0.63, alpha: 1)
        sunNode.light!.intensity = 1280
        sunNode.light!.castsShadow = true
        sunNode.light!.shadowMapSize = CGSize(width: quality.shadowMapSize,
                                              height: quality.shadowMapSize)
        sunNode.light!.shadowSampleCount = quality == .low ? 1 : 4
        sunNode.light!.shadowRadius = 3
        sunNode.light!.shadowColor = UIColor(white: 0, alpha: 0.5)
        sunNode.light!.maximumShadowDistance = 150
        sunNode.eulerAngles = SCNVector3(-0.55, 0.45, 0)
        world.addChildNode(sunNode)

        camera(world)
        clouds(world)
        ocean(world)
        road(world)
        terrain(world)
        vegetation(world)
        props(world)
        makePiraguas(world)
        makeToolboxes(world)
        makeIguanas(world)
        makeTraffic(world)
        buildCar()
        skidPool(world)
        beamPools(world)
        particles()
        buildIntroSet(world)

        world.addChildNode(holeNode)
        world.addChildNode(rimNode)
        world.addChildNode(playerNode)
        playerNode.addChildNode(chassisNode)
        world.addChildNode(dustNode)
        world.addChildNode(sparkNode)
        world.addChildNode(blobNode)

        return (world, sky)
    }

    /// Gates the render loop until the world is fully installed. Without it the
    /// intro camera code would be posing `cameraNode` on the render thread while
    /// the background build was still parenting and configuring that same node.
    private var worldAttached = false

    /// Main thread: install the finished world.
    func attach(world: SCNNode, sky: [UIImage]) {
        scene.fogStartDistance = 280
        scene.fogEndDistance = 2400
        scene.fogDensityExponent = 1.6
        scene.fogColor = UIColor(red: 1.0, green: 0.67, blue: 0.47, alpha: 1)
        scene.background.contents = sky
        // Same cubemap as the image-based lighting source, so the car's paint and
        // glass actually reflect the sunset instead of a flat specular dot. Only
        // the physicallyBased materials sample it.
        scene.lightingEnvironment.contents = sky
        scene.lightingEnvironment.intensity = 0.85
        scene.rootNode.addChildNode(world)
        worldAttached = true
    }

    var pointOfView: SCNNode { cameraNode }

    private func camera(_ parent: SCNNode) {
        let cam = SCNCamera()
        cam.zNear = 0.1
        cam.zFar = 9000
        cam.fieldOfView = Self.baseFov
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        // Bloom was set so low (threshold 0.85) that the headlights smeared into
        // a white blob directly over the car. Raised, dimmed, and widened.
        cam.bloomThreshold = 1.05
        cam.bloomIntensity = 0.55
        cam.bloomBlurRadius = 18
        cam.motionBlurIntensity = quality.motionBlur
        cam.vignettingPower = 0.55
        cam.vignettingIntensity = 0.45
        cam.saturation = 1.12
        cam.contrast = 0.08
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 3, 8)
        parent.addChildNode(cameraNode)
    }

    private func clouds(_ parent: SCNNode) {
        let container = SCNNode()
        // lambert rather than constant, so the sun actually shapes them instead
        // of leaving flat beige blobs pasted on the sky
        let mat = lambert(UIColor(red: 1, green: 0.86, blue: 0.80, alpha: 1))
        for _ in 0..<14 {
            let cx = (worldRng.next() - 0.5) * 2400
            let cy = 430 + worldRng.next() * 260
            let cz = -300 - worldRng.next() * 2700
            for _ in 0..<3 {
                let ball = SCNNode(geometry: SCNSphere(radius: 1))
                ball.geometry!.materials = [mat]
                ball.position = SCNVector3(cx + (worldRng.next() - 0.5) * 90,
                                           cy + (worldRng.next() - 0.5) * 14,
                                           cz + (worldRng.next() - 0.5) * 50)
                ball.scale = SCNVector3(45 + worldRng.next() * 70,
                                        10 + worldRng.next() * 9,
                                        26 + worldRng.next() * 34)
                container.addChildNode(ball)
            }
        }
        let flat = container.flattenedClone()
        flat.castsShadow = false
        parent.addChildNode(flat)
    }

    private func ocean(_ parent: SCNNode) {
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
        m.shaderModifiers = [.geometry: """
            float2 p = _geometry.position.xy;
            float t = scn_frame.time;
            _geometry.position.z += sin(p.x*0.02 + t*0.8)*sin(p.y*0.016 - t*0.6)*1.1
              + sin(p.x*0.045 + t*1.4)*0.45 + sin(p.y*0.05 + t*1.1)*0.4;
            """]
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(0, Self.seaLevel, -1600)
        node.castsShadow = false
        parent.addChildNode(node)
    }

    private func road(_ parent: SCNNode) {
        var verts: [simd_float3] = [], uvs: [CGPoint] = [], idx: [Int32] = []
        for i in 0..<Self.count {
            let p = pts[i], r = rights[i]
            verts.append(p - r * Self.roadHalf)
            verts.append(p + r * Self.roadHalf)
            let vCoord = CGFloat(Float(i) * Self.step / 9)
            // keep the asphalt tile square now that the road is wider than the
            // 9 m the V scale assumes, otherwise the speckle stretches sideways
            let uMax = CGFloat(Self.roadHalf * 2 / 9)
            uvs.append(CGPoint(x: 0, y: vCoord))
            uvs.append(CGPoint(x: uMax, y: vCoord))
            if i < Self.count - 1 {
                let a = Int32(i * 2)
                idx.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            }
        }
        let mat = SCNMaterial()
        // blinn + a low warm specular gives the asphalt a grazing sheen under the
        // low sun; pure lambert read as dead grey
        mat.lightingModel = .blinn
        mat.diffuse.contents = Textures.asphalt()
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .repeat
        mat.specular.contents = UIColor(red: 0.42, green: 0.30, blue: 0.22, alpha: 1)
        mat.shininess = 0.16
        let node = SCNNode(geometry: makeGeometry(verts: verts, indices: idx, uvs: uvs, material: mat))
        node.castsShadow = false
        parent.addChildNode(node)

        /// `dash` of 0 draws a solid stripe; otherwise it draws for the first half
        /// of every `dash` segments — 8 for the centre line, 2 for rumble strips.
        func ribbon(_ l0: Float, _ l1: Float, _ color: UIColor, dash: Int) {
            var v: [simd_float3] = [], id: [Int32] = []
            var n: Int32 = 0
            for j in 0..<(Self.count - 1) {
                if dash > 0 && (j % dash) >= dash / 2 { continue }
                let p0 = pts[j], r0 = rights[j], p1 = pts[j + 1], r1 = rights[j + 1]
                let up = simd_float3(0, 0.03, 0)
                v.append(p0 + r0 * l0 + up); v.append(p0 + r0 * l1 + up)
                v.append(p1 + r1 * l0 + up); v.append(p1 + r1 * l1 + up)
                id.append(contentsOf: [n, n + 1, n + 2, n + 1, n + 3, n + 2])
                n += 4
            }
            let node = SCNNode(geometry: makeGeometry(verts: v, indices: id, material: constant(color)))
            node.castsShadow = false
            parent.addChildNode(node)
        }
        ribbon(-0.14, 0.14, UIColor(red: 0.79, green: 0.68, blue: 0.21, alpha: 1), dash: 8)
        // white dashed dividers splitting each side into two lanes
        let mid = Self.roadHalf / 2
        ribbon(-mid - 0.11, -mid + 0.11, UIColor(white: 0.8, alpha: 1), dash: 8)
        ribbon(mid - 0.11, mid + 0.11, UIColor(white: 0.8, alpha: 1), dash: 8)
        let edgeOuter = Self.roadHalf - 0.18, edgeInner = Self.roadHalf - 0.4
        ribbon(-edgeOuter, -edgeInner, UIColor(white: 0.83, alpha: 1), dash: 0)
        ribbon(edgeInner, edgeOuter, UIColor(white: 0.83, alpha: 1), dash: 0)
        // rumble strips just past the asphalt edge: the boundary should be
        // something you feel and hear approaching, not a surprise
        let rumbleIn = Self.roadHalf, rumbleOut = Self.roadHalf + 0.62
        ribbon(-rumbleOut, -rumbleIn, UIColor(white: 0.70, alpha: 1), dash: 2)
        ribbon(rumbleIn, rumbleOut, UIColor(white: 0.70, alpha: 1), dash: 2)
    }

    /// Grass / rock / sand blend driven by local slope plus three octaves of
    /// cheap sinusoidal noise. The old two-branch version left the hillsides a
    /// flat olive wall.
    private func terrainColor(_ i: Int, _ lat: Float, _ y: Float) -> simd_float3 {
        let sd = Float(i) * Self.step
        if y < 1.6 {
            let l = 0.66 + 0.05 * sin(Float(i) * 0.7 + lat)
            return simd_float3(0.93 * l + 0.1, 0.82 * l + 0.08, 0.55 * l)
        }
        let n = 0.5
            + 0.26 * sin(sd * 0.031 + lat * 0.11)
            + 0.14 * sin(sd * 0.087 - lat * 0.23)
            + 0.08 * sin(sd * 0.190 + lat * 0.41)

        let dLat: Float = 1.5
        let slope = abs(groundY(i, lat + dLat) - groundY(i, lat - dLat)) / (2 * dLat)

        // Ground tone per region: deep wet green up in the cordillera, dry and
        // yellowed through the pueblo, pale and sun-bleached down on the costa.
        let w = Self.regionWeights(sd / Self.total)
        let hue = CGFloat(w.x * 0.325 + w.y * 0.215 + w.z * 0.275) - CGFloat(n * 0.05)
        let sat = CGFloat(w.x * 0.56 + w.y * 0.44 + w.z * 0.36) + CGFloat(n * 0.16)
        let bri = CGFloat(w.x * 0.27 + w.y * 0.34 + w.z * 0.40) + CGFloat(n * 0.26)
        let ui = UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        let green = simd_float3(Float(rr), Float(gg), Float(bb))

        let rock = simd_float3(0.40, 0.36, 0.32) * (0.80 + n * 0.42)
        // the cordillera is the rocky one — bare stone shows on gentler slopes there
        let rockThreshold = w.x * 0.42 + w.y * 0.62 + w.z * 0.78
        let rockAmt = simd_clamp((slope - rockThreshold) / 0.9, 0, 0.82)
        return simd_mix(green, rock, simd_float3(repeating: rockAmt))
    }

    /// Built once and shared by both terrain sides.
    private static let groundTexture = Textures.groundDetail()
    /// Rebuilt pothole meshes reuse this rather than regenerating it every race.
    private static let holeTexture = Textures.holeDepth()

    private func terrain(_ parent: SCNNode) {
        // denser near the road, where you can actually see the silhouette
        // first band hugs the asphalt edge, second sits exactly on the guardrail
        // line so the posts stand on a real terrain vertex rather than floating
        let e = Self.roadHalf - 0.3, b = Self.barrier
        // Both sides now run far enough out to close the horizon. The old strips
        // stopped at 145 m, and past that edge was nothing — so on the seaward
        // side you could see straight over the lip to the ocean plane hundreds of
        // metres below, which read as the sea leaking into the bottom of frame.
        let latsL: [Float] = [-e, -b, -9.5, -13, -18, -25, -35, -49, -68, -95, -145, -240]
        let latsR: [Float] = [e, b, 9.5, 13, 18, 25, 35, 49, 68, 95, 145, 330, 900]

        func side(_ lats: [Float], flip: Bool) {
            var verts: [simd_float3] = [], cols: [simd_float3] = [], idx: [Int32] = []
            var uvs: [CGPoint] = []
            var rows = 0
            var i = 0
            while i < Self.count {
                let p = pts[i], r = rights[i]
                for (j, lat) in lats.enumerated() {
                    let y = j == 0 ? p.y - 0.09 : groundY(i, lat)
                    verts.append(simd_float3(p.x + r.x * lat, y, p.z + r.z * lat))
                    cols.append(terrainColor(i, lat, y))
                    // planar UVs from (distance along road, lateral offset), so the
                    // detail texture tiles every 12 m in both directions
                    uvs.append(CGPoint(x: CGFloat(lat / 12),
                                       y: CGFloat(Float(i) * Self.step / 12)))
                }
                rows += 1
                i += 2
            }
            let w = lats.count
            for row in 0..<(rows - 1) {
                for j in 0..<(w - 1) {
                    let a = Int32(row * w + j)
                    let b = a + Int32(w)        // next row, same band
                    let c = a + 1               // same row, next band outward
                    let d = b + 1
                    // Both sides used to share this one index order — but +j walks
                    // in opposite world directions (lats are negative on the left,
                    // positive on the right), so the right side came out wound
                    // backwards: normals pointing down, so it never caught the sun,
                    // and back-facing, so grazing angles culled it and you saw
                    // straight through the ground.
                    if flip {
                        idx.append(contentsOf: [a, c, b, c, d, b])
                    } else {
                        idx.append(contentsOf: [a, b, c, c, b, d])
                    }
                }
            }
            let mat = SCNMaterial()
            mat.lightingModel = .lambert
            // detail texture multiplies against the per-vertex colours, which keep
            // driving hue (grass / rock / sand); the texture only adds grain
            mat.diffuse.contents = Self.groundTexture
            mat.diffuse.wrapS = .repeat
            mat.diffuse.wrapT = .repeat
            let node = SCNNode(geometry: makeGeometry(verts: verts, indices: idx,
                                                      uvs: uvs, colors: cols, material: mat))
            node.castsShadow = false
            parent.addChildNode(node)
        }
        side(latsL, flip: false)
        side(latsR, flip: true)
    }

    // MARK: - vegetation

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

    private func vegetation(_ parent: SCNNode) {
        var guard_ = 0
        let palmContainer = SCNNode()
        let template = palmTemplate()
        var placed = 0
        while placed < 130 && guard_ < 3000 {
            guard_ += 1
            // palms belong to the coast, with a scattering inland
            let pi = indexIn(pickRegion(&worldRng, simd_float3(0.22, 0.16, 0.62)), &worldRng)
            let lat = (worldRng.next() < 0.55 ? 1 : -1) * (Self.barrier + 1.2 + worldRng.next() * 45)
            let gy = groundY(pi, lat)
            if gy < -1 { continue }
            let p = pts[pi], r = rights[pi]
            let clone = template.clone()
            clone.position = SCNVector3(p.x + r.x * lat, gy - 0.3, p.z + r.z * lat)
            let sc = 0.8 + worldRng.next() * 0.7
            clone.scale = SCNVector3(sc, sc, sc)
            clone.eulerAngles = SCNVector3((worldRng.next() - 0.5) * 0.2,
                                           worldRng.next() * 6.28,
                                           (worldRng.next() - 0.5) * 0.2)
            palmContainer.addChildNode(clone)
            placed += 1
        }
        let flatPalms = palmContainer.flattenedClone()
        flatPalms.castsShadow = true
        parent.addChildNode(flatPalms)

        // flamboyanes
        let flamGroups = (0..<5).map { _ in SCNNode() }
        // Geometry and materials are shared across a small set of shades. Creating
        // a fresh canopy material per tree gave the container ~46 distinct
        // materials, and flattenedClone() silently returns nothing once a
        // container has that many — which is why the flamboyanes and the casitas
        // never appeared on screen at all.
        let flamTrunkGeo = SCNCylinder(radius: 0.27, height: 2.6)
        flamTrunkGeo.materials = [lambert(UIColor(red: 0.43, green: 0.32, blue: 0.22, alpha: 1))]
        let canopyGeos: [SCNGeometry] = (0..<5).map { k in
            let g = SCNSphere(radius: 2.4)
            g.materials = [lambert(UIColor(hue: CGFloat(0.02 + Double(k) * 0.011),
                                           saturation: 0.92, brightness: 0.85, alpha: 1))]
            return g
        }
        placed = 0; guard_ = 0
        while placed < 46 && guard_ < 2000 {
            guard_ += 1
            // flamboyanes line the pueblo and the lower mountain
            let fi = indexIn(pickRegion(&worldRng, simd_float3(0.34, 0.50, 0.16)), &worldRng)
            let flat = (worldRng.next() < 0.5 ? 1 : -1) * (Self.barrier + 0.8 + worldRng.next() * 26)
            let fgy = groundY(fi, flat)
            if fgy < 0 { continue }
            let fp = pts[fi], fr = rights[fi]
            let tree = SCNNode()
            let trunk = SCNNode(geometry: flamTrunkGeo)
            trunk.position.y = 1.3
            tree.addChildNode(trunk)
            let shade = Int(worldRng.next() * 5) % 5
            let can = SCNNode(geometry: canopyGeos[shade])
            can.scale = SCNVector3(1, 0.55, 1)
            can.position.y = 2.9
            tree.addChildNode(can)
            let fsc = 0.8 + worldRng.next() * 0.9
            tree.scale = SCNVector3(fsc, fsc, fsc)
            tree.position = SCNVector3(fp.x + fr.x * flat, fgy - 0.2, fp.z + fr.z * flat)
            flamGroups[shade].addChildNode(tree)
            placed += 1
        }
        for g in flamGroups where g.childNodes.count > 0 {
            parent.addChildNode(g)      // see the casitas note below
        }

        // casitas — one container per palette colour, so each ends up with just a
        // base + roof material. Flattening a single mixed container produced
        // nothing at all, which is why the casitas were never on screen.
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
        // one shared geometry per palette colour, for the same flattening reason
        let baseGeos: [SCNGeometry] = palette.map { c in
            let g = SCNBox(width: 4.2, height: 3, length: 5, chamferRadius: 0)
            g.materials = [lambert(c)]
            return g
        }
        let roofGeos: [SCNGeometry] = palette.map { c in
            var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
            c.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
            let g = SCNPyramid(width: 5.2, height: 1.7, length: 6)
            g.materials = [lambert(UIColor(red: rr * 0.55, green: gg * 0.55,
                                           blue: bb * 0.55, alpha: 1))]
            return g
        }
        let houseGroups = (0..<palette.count).map { _ in SCNNode() }
        placed = 0; guard_ = 0
        // 54 casitas, heavily clustered in the pueblo and pulled in tight to the
        // road there so it actually reads as driving through a town
        while placed < 54 && guard_ < 3000 {
            guard_ += 1
            let hr_ = pickRegion(&worldRng, simd_float3(0.13, 0.74, 0.13))
            let hi = indexIn(hr_, &worldRng)
            let spread: Float = hr_ == .pueblo ? 6 : 12
            let hlat = (worldRng.next() < 0.5 ? 1 : -1)
                     * (Self.barrier + (hr_ == .pueblo ? 2.0 : 3.5) + worldRng.next() * spread)
            let hgy = groundY(hi, hlat)
            if hgy < 0.5 { continue }
            let hp = pts[hi], hr = rights[hi]
            let ci = Int(worldRng.next() * Float(palette.count)) % palette.count
            let house = SCNNode()
            let base = SCNNode(geometry: baseGeos[ci])
            base.position.y = 1.5
            house.addChildNode(base)
            let roof = SCNNode(geometry: roofGeos[ci])
            roof.position.y = 3
            house.addChildNode(roof)
            let hsc = 0.9 + worldRng.next() * 0.5
            house.scale = SCNVector3(hsc, hsc, hsc)
            house.position = SCNVector3(hp.x + hr.x * hlat, hgy - 0.3, hp.z + hr.z * hlat)
            house.eulerAngles.y = atan2(tans[hi].x, -tans[hi].z) + (worldRng.next() - 0.5) * 0.5
            houseGroups[ci].addChildNode(house)
            placed += 1
        }
        // Added unflattened on purpose. flattenedClone() silently yields nothing
        // for these — not a material-count issue (grouping per colour, so two
        // materials each, fails identically), so rather than keep guessing at
        // SceneKit's flattening rules these stay as plain nodes. ~108 of them,
        // sharing 16 cached geometries so the renderer can still batch by
        // material. The casitas were invisible for the entire life of the port.
        for g in houseGroups where g.childNodes.count > 0 {
            parent.addChildNode(g)
        }

        // rocks + guardrail posts
        let rockContainer = SCNNode()
        let rockGeo = SCNSphere(radius: 1)
        rockGeo.isGeodesic = true
        rockGeo.segmentCount = 4
        rockGeo.materials = [lambert(UIColor(red: 0.47, green: 0.44, blue: 0.37, alpha: 1))]
        for _ in 0..<64 {
            // boulders are a cordillera thing — landslide country
            let ri = indexIn(pickRegion(&worldRng, simd_float3(0.68, 0.22, 0.10)), &worldRng)
            let rlat = -(Self.barrier + 0.8 + worldRng.next() * 40)
            let rp = pts[ri], rr2 = rights[ri]
            let rock = SCNNode(geometry: rockGeo)
            rock.position = SCNVector3(rp.x + rr2.x * rlat, groundY(ri, rlat), rp.z + rr2.z * rlat)
            let rs = 0.5 + worldRng.next() * 1.6
            rock.scale = SCNVector3(rs, rs * (0.7 + worldRng.next() * 0.5), rs)
            rock.eulerAngles.y = worldRng.next() * 3
            rockContainer.addChildNode(rock)
        }
        parent.addChildNode(rockContainer.flattenedClone())

        let postContainer = SCNNode()
        let postGeo = SCNBox(width: 0.16, height: 0.85, length: 0.16, chamferRadius: 0)
        postGeo.materials = [lambert(UIColor(white: 0.91, alpha: 1))]
        // Both sides now, and sitting on `barrier` — previously there was a single
        // line of posts at 5.1 and the actual death boundary was an invisible
        // cliff out at 8.6, so the rail you could see meant nothing.
        var gi = 0
        while gi < Self.count {
            let gp = pts[gi], gr = rights[gi]
            for side in [Float(-1), Float(1)] {
                let lat = side * Self.barrier
                let post = SCNNode(geometry: postGeo)
                post.position = SCNVector3(gp.x + gr.x * lat,
                                           groundY(gi, lat) + 0.42,
                                           gp.z + gr.z * lat)
                postContainer.addChildNode(post)
            }
            gi += 4
        }
        parent.addChildNode(postContainer.flattenedClone())

        // A continuous beam between the posts. Isolated posts read as scenery;
        // a rail reads as a wall you must not cross, which is the whole point of
        // having a boundary you can see.
        let railMat = SCNMaterial()
        railMat.lightingModel = .physicallyBased
        railMat.diffuse.contents = UIColor(white: 0.74, alpha: 1)
        railMat.metalness.contents = 0.85
        railMat.roughness.contents = 0.34
        railMat.isDoubleSided = true
        for side in [Float(-1), Float(1)] {
            var rvv: [simd_float3] = [], rii: [Int32] = []
            var n: Int32 = 0
            let lat = side * Self.barrier
            var i = 0
            while i < Self.count - 2 {
                let p0 = pts[i], r0 = rights[i]
                let p1 = pts[i + 2], r1 = rights[i + 2]
                let y0 = groundY(i, lat), y1 = groundY(i + 2, lat)
                let b0 = simd_float3(p0.x + r0.x * lat, y0 + 0.46, p0.z + r0.z * lat)
                let b1 = simd_float3(p1.x + r1.x * lat, y1 + 0.46, p1.z + r1.z * lat)
                rvv.append(b0); rvv.append(b0 + simd_float3(0, 0.30, 0))
                rvv.append(b1); rvv.append(b1 + simd_float3(0, 0.30, 0))
                rii.append(contentsOf: [n, n + 1, n + 2, n + 1, n + 3, n + 2])
                n += 4
                i += 2
            }
            let rail = SCNNode(geometry: makeGeometry(verts: rvv, indices: rii, material: railMat))
            rail.castsShadow = false
            parent.addChildNode(rail)
        }
    }

    private func props(_ parent: SCNNode) {
        let flagImg = Textures.prFlag()
        for i in 0..<10 {
            let fi = 60 + i * (Self.count - 120) / 10
            let lat: Float = (i % 2 == 0 ? -1 : 1) * (Self.barrier + 1.4)
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
            flag.eulerAngles.y = worldRng.next() * 6.28
            pole.addChildNode(flag)
            parent.addChildNode(pole)
        }

        func arch(_ i2: Int, _ text: String, _ color: UIColor) {
            let p = pts[i2], t = tans[i2]
            let grp = SCNNode()
            let postGeo = SCNCylinder(radius: 0.14, height: 6)
            postGeo.materials = [lambert(UIColor(white: 0.95, alpha: 1))]
            let archHalf = Self.barrier + 0.5
            for xo in [-archHalf, archHalf] {
                let post = SCNNode(geometry: postGeo)
                post.position = SCNVector3(xo, 3, 0)
                grp.addChildNode(post)
            }
            let banner = SCNNode(geometry: SCNPlane(width: CGFloat(archHalf * 2 + 0.4), height: 1.6))
            let bm = constant(.white)
            bm.diffuse.contents = Textures.banner(text: text, background: color)
            bm.isDoubleSided = true
            banner.geometry!.materials = [bm]
            banner.position.y = 5.6
            grp.addChildNode(banner)
            grp.simdPosition = p
            grp.simdLook(at: p + t, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
            parent.addChildNode(grp)
        }
        // sits just ahead of the 40 m starting point
        // Pueblo street lamps. Warm emissive heads against the sunset, which the
        // HDR bloom picks up — the cheapest way to make the town feel inhabited.
        let lampContainer = SCNNode()
        let lampPoleMat = lambert(UIColor(white: 0.42, alpha: 1))
        let lampHeadMat = constant(UIColor(red: 1.0, green: 0.86, blue: 0.60, alpha: 1))
        lampHeadMat.emission.contents = UIColor(red: 1.0, green: 0.80, blue: 0.48, alpha: 1)
        lampHeadMat.emission.intensity = 1.9
        let poleGeo = SCNCylinder(radius: 0.09, height: 5.4)
        poleGeo.materials = [lampPoleMat]
        let headGeo = SCNBox(width: 0.62, height: 0.2, length: 0.34, chamferRadius: 0.07)
        headGeo.materials = [lampHeadMat]
        let pSpan = Region.pueblo.span
        var li = Int(pSpan.lo * Float(Self.count))
        let lEnd = Int(pSpan.hi * Float(Self.count))
        while li < lEnd {
            for side in [Float(-1), Float(1)] {
                let lat = side * (Self.barrier + 1.1)
                let lp = pts[li], lr = rights[li]
                let gy = groundY(li, lat)
                let lamp = SCNNode()
                let pole = SCNNode(geometry: poleGeo)
                pole.position.y = 2.7
                lamp.addChildNode(pole)
                let head = SCNNode(geometry: headGeo)
                head.position = SCNVector3(-side * 0.34, 5.3, 0)
                lamp.addChildNode(head)
                lamp.position = SCNVector3(lp.x + lr.x * lat, gy, lp.z + lr.z * lat)
                lamp.eulerAngles.y = atan2(lr.x, -lr.z)
                lampContainer.addChildNode(lamp)
            }
            li += 15                       // ~30 m spacing
        }
        parent.addChildNode(lampContainer.flattenedClone())

        arch(24, "¡SALIDA!", UIColor(red: 0.88, green: 0.13, blue: 0.22, alpha: 1))
        arch(Self.count - 8, "¡META!", UIColor(red: 0, green: 0.31, blue: 0.63, alpha: 1))

        let umbCols: [UIColor] = [.neonPinkUI, .neonGoldUI, .neonTealUI, .sunsetOrangeUI]
        for u in 0..<6 {
            let ui = Self.count - 30 - Int(worldRng.next() * 40)
            let ulat = (worldRng.next() < 0.5 ? 1 : -1) * (Self.barrier + 0.5 + worldRng.next() * 12)
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
            umb.eulerAngles.z = (worldRng.next() - 0.5) * 0.3
            parent.addChildNode(umb)
        }
    }

    // MARK: - hazard layout (reseeded every run)

    /// Generates the pothole field and re-places pickups, iguanas and traffic
    /// from `runRng`. Called on the render thread from `resetGame`, which is the
    /// sanctioned place to mutate the graph, so rebuilding the two merged
    /// pothole meshes here is safe.
    private func layoutHazards() {
        holes.removeAll(keepingCapacity: true)

        var hv: [simd_float3] = [], hi_: [Int32] = [], huv: [CGPoint] = []
        var rv: [simd_float3] = [], ri_: [Int32] = []
        var hn: Int32 = 0, rn2: Int32 = 0
        let seg = 12

        func addHole(_ hs: Float, _ hx: Float, _ hr: Float) {
            let (pos, tan, rgt) = sample(hs)
            let c = pos + rgt * hx
            let rot = runRng.next() * 6.28
            let sq = 0.75 + runRng.next() * 0.5
            hv.append(simd_float3(c.x, c.y + 0.045, c.z))
            huv.append(CGPoint(x: 0.5, y: 0.5))
            for k in 0...seg {
                let a = rot + Float(k) / Float(seg) * 2 * .pi
                let wob = 1 + 0.18 * sin(a * 3 + rot * 7)
                let ca = cos(a) * hr * wob, sa = sin(a) * hr * sq * wob
                hv.append(simd_float3(c.x + rgt.x * ca + tan.x * sa, c.y + 0.045,
                                      c.z + rgt.z * ca + tan.z * sa))
                // unit-circle UV so the depth gradient maps centre-out regardless
                // of how the rim is wobbled or squashed
                huv.append(CGPoint(x: CGFloat(0.5 + 0.5 * cos(a)),
                                   y: CGFloat(0.5 + 0.5 * sin(a))))
            }
            for k in 0..<seg { hi_.append(contentsOf: [hn, hn + 1 + Int32(k), hn + 2 + Int32(k)]) }
            hn += Int32(seg + 2)
            for k in 0...seg {
                let a = rot + Float(k) / Float(seg) * 2 * .pi
                let wob = 1 + 0.18 * sin(a * 3 + rot * 7)
                let ca = cos(a) * wob, sa = sin(a) * sq * wob
                rv.append(simd_float3(c.x + (rgt.x * ca + tan.x * sa) * hr, c.y + 0.038,
                                      c.z + (rgt.z * ca + tan.z * sa) * hr))
                let r2 = hr * 1.62
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

        // density and cluster size ramp with distance — the back half of the
        // mountain should feel worse than the top
        // Per-region character: the cordillera throws a few big landslide craters,
        // the pueblo is a dense minefield of small municipal hoyos, the costa opens
        // up into long clean stretches so the run finishes fast.
        var cs: Float = 230
        while cs < Self.total - 260 {
            let prog = cs / Self.total
            let w = Self.regionWeights(prog)
            let clusterMax = w.x * 2.4 + w.y * 4.2 + w.z * 1.9
            let radiusMax  = w.x * 1.30 + w.y * 0.80 + w.z * 0.95
            let spacing    = w.x * 74 + w.y * 40 + w.z * 104
            let n = 1 + Int(runRng.next() * clusterMax)
            let gapC = (runRng.next() - 0.5) * (Self.roadHalf * 1.2)
            for _ in 0..<n {
                var tries = 0
                var hx: Float = 0
                repeat { hx = (runRng.next() - 0.5) * (Self.roadHalf * 2 - 1.6); tries += 1 }
                while abs(hx - gapC) < 2.2 && tries < 12
                if tries >= 12 { continue }
                addHole(cs + (runRng.next() - 0.5) * 12, hx, 0.5 + runRng.next() * radiusMax)
            }
            cs += spacing * (0.62 + runRng.next() * 0.7)
        }

        // Rim is much brighter and warmer than before (was 0.34 grey against
        // 0.22 asphalt — invisible at 200 km/h) and slightly emissive so it
        // still reads inside the hillside shadows.
        let holeMat = SCNMaterial()
        holeMat.lightingModel = .constant
        holeMat.diffuse.contents = Self.holeTexture
        let rimMat = constant(UIColor(red: 0.66, green: 0.62, blue: 0.55, alpha: 1))
        rimMat.emission.contents = UIColor(red: 0.30, green: 0.24, blue: 0.18, alpha: 1)
        holeNode.geometry = makeGeometry(verts: hv, indices: hi_, uvs: huv, material: holeMat)
        rimNode.geometry = makeGeometry(verts: rv, indices: ri_, material: rimMat)
        holeNode.castsShadow = false
        rimNode.castsShadow = false

        // pickups
        for i in 0..<piraguas.count {
            let ps = 150 + (Float(i) + runRng.next() * 0.6) * (Self.total - 380) / Float(piraguas.count)
            let px2 = (runRng.next() - 0.5) * (Self.roadHalf * 2 - 2.6)
            let (pos, _, rgt) = sample(ps)
            let world = pos + rgt * px2
            piraguas[i].s = ps
            piraguas[i].x = px2
            piraguas[i].baseY = world.y + 1.0
            piraguas[i].taken = false
            piraguas[i].node.position = SCNVector3(world.x, world.y + 1.0, world.z)
            piraguas[i].node.isHidden = false
        }
        for i in 0..<toolboxes.count {
            let ts = 380 + (Float(i) + runRng.next() * 0.5) * (Self.total - 700) / Float(toolboxes.count)
            let tx = (runRng.next() - 0.5) * (Self.roadHalf * 2 - 3)
            let (pos, _, rgt) = sample(ts)
            let world = pos + rgt * tx
            toolboxes[i].s = ts
            toolboxes[i].x = tx
            toolboxes[i].baseY = world.y + 0.9
            toolboxes[i].taken = false
            toolboxes[i].node.position = SCNVector3(world.x, world.y + 0.9, world.z)
            toolboxes[i].node.isHidden = false
        }
        // iguanas are country creatures — mountain and coast, barely any in town
        let iguanaRegions: [Region] = [.cordillera, .cordillera, .cordillera, .cordillera,
                                       .cordillera, .pueblo, .pueblo,
                                       .costa, .costa, .costa, .costa, .costa]
        for i in 0..<iguanas.count {
            let span = iguanaRegions[i % iguanaRegions.count].span
            let f = span.lo + 0.06 + runRng.next() * max(0.05, (span.hi - 0.06) - (span.lo + 0.06))
            iguanas[i].s = f * Self.total
            iguanas[i].dir = runRng.next() < 0.5 ? 1 : -1
            iguanas[i].stateRaw = 0
            iguanas[i].hit = false
            iguanas[i].x = -iguanas[i].dir * (Self.roadHalf + 1.5)
            iguanas[i].node.eulerAngles.z = 0
            positionIguana(&iguanas[i])
        }
        for i in 0..<traffic.count {
            traffic[i].s = 300 + Float(i) * 420 + runRng.next() * 150
            traffic[i].x = Self.laneCentres[Int(runRng.next() * 4) % 4]
            traffic[i].v = 11 + runRng.next() * 7
            traffic[i].cool = 0
            traffic[i].missed = false
        }
    }

    // MARK: - pickups, iguanas, traffic (nodes only; layout assigns positions)

    private func makePiraguas(_ parent: SCNNode) {
        let flavors: [UIColor] = [
            UIColor(red: 1, green: 0.18, blue: 0.31, alpha: 1),
            UIColor(red: 1, green: 0.54, blue: 0.1, alpha: 1),
            UIColor(red: 0.18, green: 0.42, blue: 1, alpha: 1),
            UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1),
            UIColor(red: 0.76, green: 0.23, blue: 1, alpha: 1)
        ]
        for i in 0..<26 {
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
            parent.addChildNode(grp)
            piraguas.append(Pickup(node: grp))
        }
    }

    private func makeToolboxes(_ parent: SCNNode) {
        let boxMat = SCNMaterial()
        boxMat.lightingModel = .lambert
        boxMat.diffuse.contents = UIColor(red: 0.85, green: 0.21, blue: 0.18, alpha: 1)
        boxMat.emission.contents = UIColor(red: 0.85, green: 0.21, blue: 0.18, alpha: 1)
        boxMat.emission.intensity = 0.5
        let bandMat = lambert(UIColor(white: 0.95, alpha: 1))
        // 14, up from 10 — with the damage rebalance the mechanic is the main
        // way a long run stays alive
        for _ in 0..<14 {
            let grp = SCNNode()
            let box = SCNNode(geometry: SCNBox(width: 0.52, height: 0.34, length: 0.38, chamferRadius: 0.04))
            box.geometry!.materials = [boxMat]
            grp.addChildNode(box)
            let band = SCNNode(geometry: SCNBox(width: 0.54, height: 0.1, length: 0.4, chamferRadius: 0.02))
            band.geometry!.materials = [bandMat]
            grp.addChildNode(band)
            parent.addChildNode(grp)
            toolboxes.append(Pickup(node: grp))
        }
    }

    private func makeIguanas(_ parent: SCNNode) {
        for _ in 0..<12 {
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
            parent.addChildNode(grp)
            iguanas.append(Iguana(node: grp))
        }
    }

    private func positionIguana(_ ig: inout Iguana) {
        let (pos, _, rgt) = sample(ig.s)
        let world = pos + rgt * ig.x
        ig.node.simdPosition = simd_float3(world.x, pos.y + 0.05, world.z)
        let target = ig.node.simdPosition + rgt * ig.dir
        ig.node.simdLook(at: target, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
    }

    private func trafficCar(_ color: UIColor, police: Bool = false) -> SCNNode {
        let grp = SCNNode()
        if police {
            // roof light bar; the two materials are shared across every cruiser so
            // one pair of emission writes per frame flashes all of them in sync
            let bar = SCNNode(geometry: SCNBox(width: 1.0, height: 0.1, length: 0.22, chamferRadius: 0.03))
            bar.geometry!.materials = [lambert(UIColor(white: 0.12, alpha: 1))]
            bar.position = SCNVector3(0, 1.24, 0.2)
            grp.addChildNode(bar)
            let lensGeoL = SCNBox(width: 0.42, height: 0.14, length: 0.24, chamferRadius: 0.04)
            lensGeoL.materials = [policeRedMat]
            let left = SCNNode(geometry: lensGeoL)
            left.position = SCNVector3(-0.26, 1.3, 0.2)
            grp.addChildNode(left)
            let lensGeoR = SCNBox(width: 0.42, height: 0.14, length: 0.24, chamferRadius: 0.04)
            lensGeoR.materials = [policeBlueMat]
            let right = SCNNode(geometry: lensGeoR)
            right.position = SCNVector3(0.26, 1.3, 0.2)
            grp.addChildNode(right)
        }
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

    private func makeTraffic(_ parent: SCNNode) {
        let colors: [UIColor] = [
            UIColor(white: 0.85, alpha: 1),
            UIColor(red: 0.25, green: 0.42, blue: 0.85, alpha: 1),
            UIColor(red: 0.85, green: 0.7, blue: 0.25, alpha: 1),
            UIColor(white: 0.58, alpha: 1),
            UIColor(red: 0.4, green: 0.77, blue: 0.42, alpha: 1),
            UIColor(red: 0.77, green: 0.27, blue: 0.27, alpha: 1),
            UIColor(white: 0.94, alpha: 1)
        ]
        // two of the nine are cruisers — they hunt the saucer, so they belong here
        for i in 0..<9 {
            let police = (i == 2 || i == 6)
            let node = trafficCar(police ? UIColor(white: 0.93, alpha: 1) : colors[i % colors.count],
                                  police: police)
            parent.addChildNode(node)
            var t = Traffic(node: node)
            t.isPolice = police
            traffic.append(t)
        }
    }

    // MARK: - skid marks

    /// A ring buffer of unit quads. Each drift segment reuses a slot by
    /// transform only — no geometry is rebuilt while driving.
    private func skidPool(_ parent: SCNNode) {
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(red: 0.04, green: 0.036, blue: 0.04, alpha: 1)
        // asphalt is already dark (~0.22), so a timid mark is invisible
        mat.transparency = 0.7
        mat.writesToDepthBuffer = false
        mat.blendMode = .alpha
        let geo = SCNPlane(width: 1, height: 1)
        geo.materials = [mat]

        let n = quality.skidSegments * 2      // two rear wheels
        let container = SCNNode()
        for _ in 0..<n {
            let node = SCNNode(geometry: geo)
            node.castsShadow = false
            node.isHidden = true
            node.opacity = 0
            container.addChildNode(node)
            skidNodes.append(node)
        }
        skidAge = [Float](repeating: -1, count: n)
        parent.addChildNode(container)
    }

    // MARK: - beam

    /// Bolts and tar patches are both pooled and driven by transform only, like the
    /// skid trail — nothing is allocated once a race is running.
    private func beamPools(_ parent: SCNNode) {
        let boltMat = SCNMaterial()
        boltMat.lightingModel = .constant
        boltMat.diffuse.contents = UIColor(red: 0.60, green: 1, blue: 0.72, alpha: 1)
        boltMat.emission.contents = UIColor(red: 0.60, green: 1, blue: 0.72, alpha: 1)
        boltMat.emission.intensity = 2.0
        boltMat.blendMode = .add
        boltMat.writesToDepthBuffer = false
        let boltGeo = SCNSphere(radius: 0.17)
        boltGeo.materials = [boltMat]

        let container = SCNNode()
        for _ in 0..<10 {
            let n = SCNNode(geometry: boltGeo)
            n.scale = SCNVector3(1, 1, 4.5)      // stretched along travel
            n.castsShadow = false
            n.isHidden = true
            container.addChildNode(n)
            bolts.append(Bolt(node: n))
        }

        let patchMat = SCNMaterial()
        patchMat.lightingModel = .constant
        patchMat.diffuse.contents = Textures.patch()
        patchMat.writesToDepthBuffer = false
        let patchGeo = SCNPlane(width: 1, height: 1)
        patchGeo.materials = [patchMat]
        for _ in 0..<24 {
            let n = SCNNode(geometry: patchGeo)
            n.castsShadow = false
            n.isHidden = true
            container.addChildNode(n)
            patchNodes.append(n)
        }
        parent.addChildNode(container)
    }

    private func clearBeam() {
        for i in 0..<bolts.count {
            bolts[i].live = false
            bolts[i].node.isHidden = true
        }
        for n in patchNodes { n.isHidden = true }
        boltCursor = 0
        patchCursor = 0
        charge = 100
        fireCool = 0
    }

    private func fireBolt() {
        guard charge >= Self.shotCost, fireCool <= 0 else { return }
        charge -= Self.shotCost
        fireCool = 0.20
        sound.playZap()
        Haptics.shared.tap(intensity: 0.34, sharpness: 0.95)
        bolts[boltCursor].s = s + 3.5
        bolts[boltCursor].x = x
        bolts[boltCursor].live = true
        bolts[boltCursor].node.isHidden = false
        boltCursor = (boltCursor + 1) % bolts.count
    }

    /// Lays a tar patch over a sealed hole. The pothole field is two merged
    /// meshes, so an individual hole can't be hidden — covering it is what makes
    /// the seal read.
    private func layPatch(over hole: Hole) {
        let (pos, tan, rgt) = sample(hole.s)
        let c = pos + rgt * hole.x
        let n = patchNodes[patchCursor]
        n.simdPosition = simd_float3(c.x, c.y + 0.055, c.z)
        let flat = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        let yaw = simd_quatf(angle: atan2(tan.x, -tan.z), axis: simd_float3(0, 1, 0))
        n.simdOrientation = simd_mul(yaw, flat)
        let d = hole.r * 2.9
        n.scale = SCNVector3(d, d, 1)
        n.isHidden = false
        patchCursor = (patchCursor + 1) % patchNodes.count
    }

    private func updateBolts(_ dt: Float) {
        for i in 0..<bolts.count where bolts[i].live {
            // Swept span for this frame. A point-in-window test missed constantly:
            // at 115 m/s with dt capped at 0.033 a bolt jumps 3.8 m, further than
            // any sane hit window, so it tunnelled straight through targets.
            let prevS = bolts[i].s
            bolts[i].s += Self.boltSpeed * dt
            let bs = bolts[i].s, bx = bolts[i].x
            let lo = prevS - 1.4, hi = bs + 1.4

            if bs - s > 95 || bs > Self.total {
                bolts[i].live = false; bolts[i].node.isHidden = true; continue
            }

            var struck = false

            // traffic first — a car is the bigger target and the better payoff
            for ti in 0..<traffic.count {
                let tc = traffic[ti]
                guard tc.s < Self.total, tc.s > s - 4 else { continue }
                if tc.s >= lo && tc.s <= hi && abs(tc.x - bx) < 2.6 {
                    traffic[ti].vx = (tc.x >= bx ? 1 : -1) * 13
                    traffic[ti].spin = 1.1
                    traffic[ti].v *= 0.62
                    traffic[ti].cool = 1.5
                    score += tc.isPolice ? 240 : 130
                    combo = min(combo + 1, 5)
                    popupAsync(tc.isPolice ? "¡LA JARA!" : "¡FUEGO!")
                    sound.playThunk()
                    struck = true
                    break
                }
            }

            // otherwise seal a pothole ahead
            if !struck {
                for hIdx in 0..<holes.count {
                    let h = holes[hIdx]
                    guard !h.zapped, !h.hit, h.s > s else { continue }
                    if h.s >= lo && h.s <= hi && abs(h.x - bx) < h.r + 1.8 {
                        holes[hIdx].zapped = true
                        layPatch(over: h)
                        score += 70
                        popupAsync("¡TAPADO! +70")
                        struck = true
                        break
                    }
                }
            }

            if struck {
                let (hp2, _, hr2) = sample(bs)
                sparkNode.simdPosition = hp2 + hr2 * bx + simd_float3(0, 0.45, 0)
                sparkSystem.birthRate = 600
                sparkT = 0.09
                bolts[i].live = false
                bolts[i].node.isHidden = true
                continue
            }

            // place it
            let (bp, bt, br) = sample(bs)
            let world = bp + br * bx + simd_float3(0, 0.75, 0)
            bolts[i].node.simdPosition = world
            bolts[i].node.simdLook(at: world + bt, up: simd_float3(0, 1, 0),
                                   localFront: simd_float3(0, 0, -1))
        }
    }

    private func clearSkids() {
        for i in 0..<skidNodes.count {
            skidNodes[i].isHidden = true
            skidAge[i] = -1
        }
        skidCursor = 0
        lastSkidL = nil
        lastSkidR = nil
    }

    private func emitSkidSegment(from a: simd_float3, to b: simd_float3, tan: simd_float3) {
        let d = b - a
        // Orient along the road, not along the raw contact-patch delta. While
        // drifting that delta is dominated by *lateral* travel, which turned the
        // trail into diagonal slashes; the lateral offset between consecutive
        // segments is what should show the trail curving.
        let forward = abs(simd_dot(d, tan))
        let len = max(forward, 0.35) * 1.18
        guard len < 40 else { return }
        let node = skidNodes[skidCursor]
        let mid = (a + b) * 0.5
        node.simdPosition = simd_float3(mid.x, mid.y + 0.025, mid.z)
        // Compose explicitly: pitch the quad flat in its own space, *then* yaw it
        // about world Y. Setting eulerAngles composes in an order that leaves the
        // quad skewed rather than lying flat and aligned.
        let flat = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        let yaw = simd_quatf(angle: atan2(tan.x, -tan.z), axis: simd_float3(0, 1, 0))
        node.simdOrientation = simd_mul(yaw, flat)
        node.scale = SCNVector3(0.28, len, 1)
        node.isHidden = false
        node.opacity = 1
        skidAge[skidCursor] = 0
        skidCursor = (skidCursor + 1) % skidNodes.count
    }

    private func updateSkids(_ dt: Float) {
        for i in 0..<skidAge.count where skidAge[i] >= 0 {
            skidAge[i] += dt
            let a = skidAge[i]
            if a >= skidLife {
                skidAge[i] = -1
                skidNodes[i].isHidden = true
            } else if a > skidLife * 0.55 {
                let f = 1 - (a - skidLife * 0.55) / (skidLife * 0.45)
                skidNodes[i].opacity = CGFloat(max(0, f))
            }
        }
    }

    // MARK: - the car

    /// Builds a saucer hull. Shared by the player craft and the intro cutscene, so
    /// the thing escaping Area 51 is visibly the thing you then drive.
    /// Returns the rotating light ring so the caller can spin it.
    private func ufoHull(scale: Float = 1) -> (node: SCNNode, lightRing: SCNNode) {
        let craft = SCNNode()

        let hullMat = SCNMaterial()
        hullMat.lightingModel = .physicallyBased
        // brushed rather than mirror — at 0.92 metalness the hull reflected so much
        // of the sunset cubemap that the saucer read pink instead of metallic
        hullMat.diffuse.contents = UIColor(white: 0.80, alpha: 1)
        hullMat.metalness.contents = 0.58
        hullMat.roughness.contents = 0.34

        let underMat = SCNMaterial()
        underMat.lightingModel = .physicallyBased
        underMat.diffuse.contents = UIColor(white: 0.26, alpha: 1)
        underMat.metalness.contents = 0.85
        underMat.roughness.contents = 0.38

        // upper and lower shells, squashed spheres
        let top = SCNNode(geometry: SCNSphere(radius: 1.25))
        top.geometry!.materials = [hullMat]
        top.scale = SCNVector3(1, 0.30, 1)
        top.position.y = 0.66
        craft.addChildNode(top)

        let under = SCNNode(geometry: SCNSphere(radius: 1.20))
        under.geometry!.materials = [underMat]
        under.scale = SCNVector3(1, 0.22, 1)
        under.position.y = 0.54
        craft.addChildNode(under)

        // rim
        let rim = SCNNode(geometry: SCNTorus(ringRadius: 1.34, pipeRadius: 0.14))
        rim.geometry!.materials = [hullMat]
        rim.position.y = 0.62
        craft.addChildNode(rim)

        // cockpit dome
        let domeMat = SCNMaterial()
        domeMat.lightingModel = .physicallyBased
        domeMat.diffuse.contents = UIColor(red: 0.22, green: 0.92, blue: 0.80, alpha: 1)
        domeMat.metalness.contents = 0.30
        domeMat.roughness.contents = 0.05
        domeMat.emission.contents = UIColor(red: 0.06, green: 0.42, blue: 0.38, alpha: 1)
        let dome = SCNNode(geometry: SCNSphere(radius: 0.56))
        dome.geometry!.materials = [domeMat]
        dome.scale = SCNVector3(1, 0.9, 1)
        dome.position.y = 0.90
        craft.addChildNode(dome)

        // rotating ring of lights — one shared emissive material so it can flatten
        let lightRing = SCNNode()
        let lampMat = constant(UIColor(red: 1, green: 0.86, blue: 0.42, alpha: 1))
        lampMat.emission.contents = UIColor(red: 1, green: 0.80, blue: 0.30, alpha: 1)
        lampMat.emission.intensity = 1.5
        let lampGeo = SCNSphere(radius: 0.11)
        lampGeo.materials = [lampMat]
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * .pi
            let lamp = SCNNode(geometry: lampGeo)
            lamp.position = SCNVector3(cos(a) * 1.18, 0.5, sin(a) * 1.18)
            lightRing.addChildNode(lamp)
        }
        craft.addChildNode(lightRing)

        craft.scale = SCNVector3(scale, scale, scale)
        return (craft, lightRing)
    }

    // MARK: - Area 51 intro cutscene

    private struct IntroKey { var t: Float; var p: simd_float3 }

    /// Parked well clear of the course and outside the ocean plane's footprint, so
    /// the set can never be seen from the road and vice versa.
    private static let introOrigin = simd_float3(6000, 0, 6000)
    private static let introLoop: Float = 11.5

    /// The craft climbs out of the hangar at lower-left and exits upper-right, so
    /// it stays clear of the centred title block instead of hiding behind it.
    /// Breaks cover quickly, then spends the back half of the loop climbing away
    /// through the right of frame, where the centred title block isn't.
    private static let ufoPath: [IntroKey] = [
        IntroKey(t: 0.0,  p: simd_float3(-40,  4.5, -26)),  // sitting in the hangar mouth
        IntroKey(t: 3.0,  p: simd_float3(-38,  7.0, -25)),  // spooling up
        IntroKey(t: 4.4,  p: simd_float3(-31, 15.0, -23)),  // breaks cover
        IntroKey(t: 6.8,  p: simd_float3(-14, 24.0, -10)),  // hauls right, over the wire
        IntroKey(t: 11.5, p: simd_float3( 16, 34.0,  22))   // straight over the camera
    ]
    /// Locked-off wide shot. A moving camera was impossible to compose blind; a
    /// fixed frame with a slow drift reads like a poster and always works.
    private static let introCam = simd_float3(2, 12, 42)
    private static let introBaseLook = simd_float3(-24, 11, -26)

    private static func samplePath(_ keys: [IntroKey], _ t: Float) -> simd_float3 {
        if t <= keys[0].t { return keys[0].p }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            if t <= b.t {
                let u = simd_clamp((t - a.t) / (b.t - a.t), 0, 1)
                let e = u * u * (3 - 2 * u)           // ease in/out
                return simd_mix(a.p, b.p, simd_float3(repeating: e))
            }
        }
        return keys[keys.count - 1].p
    }

    private func buildIntroSet(_ parent: SCNNode) {
        let set = SCNNode()
        set.simdPosition = Self.introOrigin

        // desert floor
        let groundMat = SCNMaterial()
        groundMat.lightingModel = .lambert
        groundMat.diffuse.contents = Self.groundTexture
        groundMat.diffuse.wrapS = .repeat
        groundMat.diffuse.wrapT = .repeat
        groundMat.diffuse.contentsTransform = SCNMatrix4MakeScale(90, 90, 1)
        groundMat.multiply.contents = UIColor(red: 0.86, green: 0.72, blue: 0.50, alpha: 1)
        let ground = SCNNode(geometry: SCNPlane(width: 1400, height: 1400))
        ground.geometry!.materials = [groundMat]
        ground.eulerAngles.x = -.pi / 2
        ground.castsShadow = false
        set.addChildNode(ground)

        // hangar: box plus a barrel roof
        let wallMat = lambert(UIColor(white: 0.52, alpha: 1))
        let hangar = SCNNode(geometry: SCNBox(width: 34, height: 11, length: 20, chamferRadius: 0))
        hangar.geometry!.materials = [wallMat]
        hangar.position = SCNVector3(-38, 5.5, -34)
        set.addChildNode(hangar)
        let roof = SCNNode(geometry: SCNCylinder(radius: 10.2, height: 34))
        roof.geometry!.materials = [lambert(UIColor(white: 0.60, alpha: 1))]
        roof.eulerAngles.z = .pi / 2
        roof.position = SCNVector3(-38, 11, -34)
        set.addChildNode(roof)
        // open doorway the craft slips out of
        let doorway = SCNNode(geometry: SCNBox(width: 11, height: 9, length: 0.6, chamferRadius: 0))
        doorway.geometry!.materials = [constant(UIColor(red: 0.03, green: 0.04, blue: 0.05, alpha: 1))]
        doorway.position = SCNVector3(-40, 4.6, -23.8)
        set.addChildNode(doorway)

        // perimeter fence
        let fencePostGeo = SCNBox(width: 0.3, height: 4.4, length: 0.3, chamferRadius: 0)
        fencePostGeo.materials = [lambert(UIColor(white: 0.44, alpha: 1))]
        let meshMat = SCNMaterial()
        meshMat.lightingModel = .constant
        meshMat.diffuse.contents = UIColor(white: 0.72, alpha: 1)
        meshMat.transparency = 0.16
        meshMat.isDoubleSided = true
        meshMat.writesToDepthBuffer = false
        var fx: Float = -90
        while fx <= 90 {
            let post = SCNNode(geometry: fencePostGeo)
            post.position = SCNVector3(fx, 2.2, 20)
            set.addChildNode(post)
            fx += 6
        }
        let mesh = SCNNode(geometry: SCNPlane(width: 180, height: 4.2))
        mesh.geometry!.materials = [meshMat]
        mesh.position = SCNVector3(0, 2.1, 20)
        mesh.castsShadow = false
        set.addChildNode(mesh)

        // warning sign on the fence
        let signMat = constant(.white)
        signMat.diffuse.contents = Textures.banner(text: "AREA 51",
            background: UIColor(red: 0.55, green: 0.09, blue: 0.10, alpha: 1))
        signMat.isDoubleSided = true
        let sign = SCNNode(geometry: SCNPlane(width: 7.5, height: 1.25))
        sign.geometry!.materials = [signMat]
        sign.position = SCNVector3(-15, 2.9, 19.8)
        set.addChildNode(sign)

        // radio masts with red beacons
        let mastMat = lambert(UIColor(white: 0.38, alpha: 1))
        let beaconMat = constant(UIColor(red: 1, green: 0.15, blue: 0.12, alpha: 1))
        beaconMat.emission.contents = UIColor(red: 1, green: 0.15, blue: 0.12, alpha: 1)
        beaconMat.emission.intensity = 1.8
        for mx in [Float(-46), Float(34)] {
            let mast = SCNNode(geometry: SCNCylinder(radius: 0.34, height: 30))
            mast.geometry!.materials = [mastMat]
            mast.position = SCNVector3(mx, 15, -46)
            set.addChildNode(mast)
            let beacon = SCNNode(geometry: SCNSphere(radius: 0.7))
            beacon.geometry!.materials = [beaconMat]
            beacon.position = SCNVector3(mx, 30.4, -46)
            set.addChildNode(beacon)
        }

        // searchlights: a yaw pivot at the head, beam cone pointing down -Z
        let beamMat = SCNMaterial()
        beamMat.lightingModel = .constant
        beamMat.diffuse.contents = UIColor(red: 0.60, green: 0.78, blue: 0.95, alpha: 1)
        beamMat.transparency = 0.05
        beamMat.blendMode = .add
        beamMat.writesToDepthBuffer = false
        beamMat.isDoubleSided = true
        let headMat = constant(UIColor(red: 1, green: 0.97, blue: 0.86, alpha: 1))
        headMat.emission.contents = UIColor(red: 1, green: 0.97, blue: 0.86, alpha: 1)
        headMat.emission.intensity = 0.5
        for sx in [Float(-30), Float(6), Float(40)] {
            let pole = SCNNode(geometry: SCNCylinder(radius: 0.26, height: 7))
            pole.geometry!.materials = [mastMat]
            pole.position = SCNVector3(sx, 3.5, 12)
            set.addChildNode(pole)

            let pivot = SCNNode()
            pivot.position = SCNVector3(sx, 7.2, 12)
            let head = SCNNode(geometry: SCNSphere(radius: 0.34))
            head.geometry!.materials = [headMat]
            pivot.addChildNode(head)
            let beamH: Float = 110
            let beam = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 2.4, height: CGFloat(beamH)))
            beam.geometry!.materials = [beamMat]
            beam.eulerAngles.x = .pi / 2         // apex toward +Z…
            beam.position = SCNVector3(0, 0, -beamH / 2)   // …shifted so it sits at the head
            beam.castsShadow = false
            pivot.addChildNode(beam)
            set.addChildNode(pivot)
            searchlights.append(pivot)
        }

        // cruisers parked at the gate
        for (i, px) in [Float(-16), Float(2), Float(20)].enumerated() {
            let car = trafficCar(UIColor(white: 0.93, alpha: 1), police: true)
            car.position = SCNVector3(px, 0, 15)
            car.eulerAngles.y = Float(i) * 0.35 - 0.35
            set.addChildNode(car)
        }

        // the craft itself — same hull the player flies
        let built = ufoHull(scale: 2.4)
        introUfoRing = built.lightRing
        introUfo.addChildNode(built.node)
        set.addChildNode(introUfo)

        introSet = set
        parent.addChildNode(set)
    }

    // MARK: - arrival (pre-race)

    private static let arrivalDur: Float = 3.7

    /// The saucer drops out of the sky onto the start of the mountain road, and the
    /// camera settles from a wide reveal into the chase rig the countdown uses — so
    /// the hand-off into the countdown is seamless.
    private func updateArrival(_ dt: Float) {
        arrivalT += dt
        let p = simd_clamp(arrivalT / Self.arrivalDur, 0, 1)
        let (pos, tan, _) = sample(s)

        // descend fast, then ease into the road
        let fall = 1 - p
        let altitude = 62 * fall * fall * fall
        let carPos = pos + simd_float3(0, 0.02 + altitude, 0)
        playerNode.simdPosition = carPos
        playerNode.simdLook(at: carPos + tan, up: simd_float3(0, 1, 0),
                            localFront: simd_float3(0, 0, -1))
        // spin down out of a hard rotation as it settles
        chassisNode.eulerAngles = SCNVector3(0, fall * fall * 16, 0)
        chassisNode.position.y = 0
        ufoLightRing.eulerAngles.y += dt * (2 + fall * 22)
        for f in flameNodes { f.isHidden = p > 0.92 }

        blobNode.simdPosition = simd_float3(pos.x, pos.y + 0.03, pos.z)
        blobNode.eulerAngles = SCNVector3(-.pi / 2, atan2(tan.x, -tan.z), 0)
        let shadowScale = 1 / (1 + altitude * 0.42)
        blobNode.scale = SCNVector3(shadowScale, shadowScale, 1)
        blobNode.opacity = CGFloat(simd_clamp(1 - altitude * 0.02, 0.25, 1))

        // camera: wide and high, easing to exactly where the countdown wants it
        let ease = p * p * (3 - 2 * p)
        let wide = pos - tan * 30 + simd_float3(0, 30, 0)
        let tight = pos - tan * 7 + simd_float3(0, 2.6, 0)
        cameraNode.simdPosition = simd_mix(wide, tight, simd_float3(repeating: ease))
        let lookAtCraft = carPos
        let lookAhead = pos + tan * 8
        cameraNode.simdLook(at: simd_mix(lookAtCraft, lookAhead,
                                        simd_float3(repeating: simd_smoothstep(0.55, 1.0, p))),
                            up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        cameraNode.camera?.fieldOfView = CGFloat(66 - 4 * ease)

        // touchdown
        if arrivalT >= Self.arrivalDur {
            sound.playThunk()
            Haptics.shared.crash(intensity: 0.7)
            shake = 0.9
            dustNode.simdPosition = pos + simd_float3(0, 0.3, 0)
            dustSystem.birthRate = 420
            dustT = 0.28
            phase = .countdown
            DispatchQueue.main.async { self.state.phase = .countdown }
        }
    }

    /// Drives the looping escape. Called from the `.intro` branch of the frame.
    private func updateIntro(_ dt: Float) {
        introT += dt
        if introT > Self.introLoop { introT -= Self.introLoop }

        // dry desert dusk while we're at the base
        scene.fogColor = UIColor(red: 0.84, green: 0.62, blue: 0.48, alpha: 1)
        // the gate cruisers' bars flash here too — the race loop isn't running
        let flash = sin(introT * 9) > 0
        policeRedMat.emission.intensity = flash ? 2.2 : 0.05
        policeBlueMat.emission.intensity = flash ? 0.05 : 2.2

        let o = Self.introOrigin
        let ufoLocal = Self.samplePath(Self.ufoPath, introT)
        let ufoWorld = o + ufoLocal
        introUfo.simdPosition = ufoLocal

        // bank into the direction of travel, sampled from the path itself
        let ahead = Self.samplePath(Self.ufoPath, min(Self.introLoop, introT + 0.12))
        let vel = ahead - ufoLocal
        let speed = simd_length(vel)
        if speed > 0.001 {
            let dir = vel / speed
            introUfo.eulerAngles = SCNVector3(-dir.y * 0.5, atan2(dir.x, -dir.z), -dir.x * 0.42)
        }
        introUfoRing.eulerAngles.y += dt * 4.5

        // Fixed position with a slow drift, but the aim eases from the base to the
        // craft as it climbs — a fully locked frame kept losing the saucer.
        let drift = simd_float3(sin(introT * 0.28) * 1.1, sin(introT * 0.21) * 0.5, 0)
        cameraNode.simdPosition = o + Self.introCam + drift
        let attention = Self.smoothStep(3.2, 5.6, introT)
        var look = simd_mix(Self.introBaseLook, ufoLocal, simd_float3(repeating: attention))
        look.x -= 7                       // bias left so the craft frames right of centre
        cameraNode.simdLook(at: o + look, up: simd_float3(0, 1, 0),
                            localFront: simd_float3(0, 0, -1))
        cameraNode.camera?.fieldOfView = 60

        // searchlights sweep, then lock on once it's airborne
        for (i, light) in searchlights.enumerated() {
            let phase = Float(i) * 2.1
            if introT > 4.0 {
                light.simdLook(at: ufoWorld, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
            } else {
                let sweep = sin(introT * 0.8 + phase) * 0.9
                light.eulerAngles = SCNVector3(-0.85, sweep, 0)
            }
        }

        // A little dust as it breaks cover. The race's rate (320) threw puffs big
        // enough to completely hide the craft at this camera distance.
        if introT > 2.8 && introT < 4.6 {
            dustNode.simdPosition = o + simd_float3(ufoLocal.x, 0.3, ufoLocal.z)
            dustSystem.birthRate = 55
        } else if introT < 0.2 || introT > 4.6 {
            dustSystem.birthRate = 0
        }
    }

    private func buildCar() {
        let built = ufoHull()
        chassisNode.addChildNode(built.node)
        ufoLightRing = built.lightRing

        // A soft pool of light on the asphalt ahead, in place of headlights.
        // On playerNode rather than the chassis so it stays flat on the road while
        // the hull banks and pitches.
        let poolMat = SCNMaterial()
        poolMat.lightingModel = .constant
        poolMat.diffuse.contents = Textures.softCircle()
        poolMat.multiply.contents = UIColor(red: 0.62, green: 1, blue: 0.86, alpha: 1)
        poolMat.blendMode = .add
        poolMat.writesToDepthBuffer = false
        poolMat.transparency = 0.22
        let pool = SCNNode(geometry: SCNPlane(width: 7, height: 16))
        pool.geometry!.materials = [poolMat]
        pool.eulerAngles.x = -.pi / 2
        pool.position = SCNVector3(0, 0.045, -9.5)
        pool.castsShadow = false
        playerNode.addChildNode(pool)

        // rear brake glow — a strip on the trailing rim
        brakeLightMaterial = constant(UIColor(red: 0.33, green: 0.04, blue: 0.04, alpha: 1))
        let brakeBar = SCNNode(geometry: SCNBox(width: 1.3, height: 0.1, length: 0.1, chamferRadius: 0.04))
        brakeBar.geometry!.materials = [brakeLightMaterial]
        brakeBar.position = SCNVector3(0, 0.58, 1.24)
        chassisNode.addChildNode(brakeBar)

        // three downward-angled thrusters for nitro
        for xo in [Float(-0.62), Float(0), Float(0.62)] {
            let fm = SCNMaterial()
            fm.lightingModel = .constant
            fm.diffuse.contents = UIColor(red: 0.45, green: 1, blue: 0.82, alpha: 1)
            fm.emission.contents = UIColor(red: 0.45, green: 1, blue: 0.82, alpha: 1)
            fm.emission.intensity = 1.7
            fm.blendMode = .add
            fm.writesToDepthBuffer = false
            let flame = SCNNode(geometry: SCNCone(topRadius: 0.09, bottomRadius: 0, height: 1.1))
            flame.geometry!.materials = [fm]
            flame.eulerAngles.x = -1.15          // back and down
            flame.position = SCNVector3(xo, 0.34, 1.05)
            flame.isHidden = true
            flame.castsShadow = false
            chassisNode.addChildNode(flame)
            flameNodes.append(flame)
        }

        // hover field on the road beneath the craft
        glowMaterial = SCNMaterial()
        glowMaterial.lightingModel = .constant
        glowMaterial.diffuse.contents = Textures.softCircle()
        glowMaterial.multiply.contents = UIColor(red: 0.24, green: 0.96, blue: 0.72, alpha: 1)
        glowMaterial.blendMode = .add
        glowMaterial.writesToDepthBuffer = false
        glowMaterial.transparency = 0.5
        let glow = SCNNode(geometry: SCNPlane(width: 4.2, height: 4.2))
        glow.geometry!.materials = [glowMaterial]
        glow.eulerAngles.x = -.pi / 2
        glow.position.y = 0.06
        glow.castsShadow = false
        chassisNode.addChildNode(glow)

        let blobMat = constant(UIColor.black)
        blobMat.diffuse.contents = Textures.blobShadow()
        blobMat.transparency = 1
        blobMat.writesToDepthBuffer = false
        blobNode.geometry = SCNPlane(width: 3.6, height: 3.6)   // round, like the craft
        blobNode.geometry!.materials = [blobMat]
        blobNode.eulerAngles.x = -.pi / 2
        blobNode.castsShadow = false
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

        // guardrail sparks
        sparkSystem.particleImage = puffImg
        sparkSystem.birthRate = 0
        sparkSystem.particleLifeSpan = 0.32
        sparkSystem.particleLifeSpanVariation = 0.2
        sparkSystem.particleSize = 0.075
        sparkSystem.particleVelocity = 9
        sparkSystem.particleVelocityVariation = 7
        sparkSystem.spreadingAngle = 65
        sparkSystem.emittingDirection = SCNVector3(0, 0.35, 1)
        sparkSystem.acceleration = SCNVector3(0, -14, 0)
        sparkSystem.particleColor = UIColor(red: 1, green: 0.78, blue: 0.32, alpha: 1)
        sparkSystem.particleColorVariation = SCNVector4(0.04, 0.2, 0.2, 0)
        sparkSystem.blendMode = .additive
        sparkNode.addParticleSystem(sparkSystem)

        streakSystem.particleImage = puffImg
        streakSystem.birthRate = 0
        streakSystem.particleLifeSpan = 1.2
        streakSystem.particleSize = 0.07
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
        // Start 40 m in, not 4. The chase camera sits ~6 m behind the car, so at
        // s = 4 it was positioned behind s = 0 — behind where the road and terrain
        // meshes begin — and looked off the back edge of the world straight at the
        // ocean plane a couple of hundred metres below.
        s = Self.startOffset; v = 8; x = 0; xd = 0
        hp = 100; nitro = 60
        score = 0; styleRun = 0; combo = 0; lastCombo = -1
        topSpeed = 0; holesHit = 0; nearMisses = 0
        shake = 0; flashT = 0; jolt = 0; invuln = 0; dustT = 0
        jumpY = 0; jumpVel = 0; jumpCool = 0
        driftYaw = 0; leanRoll = 0; pitchAng = 0
        playTime = 0
        hudClock = 0
        lastRegion = nil            // so the first region announces itself
        cd = 3.4; cdLabel = ""
        fov = Self.baseFov
        clearSkids()
        clearBeam()
        dustSystem.birthRate = 0
        // the base is 6 km away and fully fogged, but there's no reason to keep
        // paying for it once the race starts
        introSet.isHidden = true

        // fresh course every race
        runSeed = UInt64.random(in: 1..<2147483646)
        runRng = Lcg(runSeed)
        layoutHazards()

        phase = .arrival
        arrivalT = 0
        let (pos, tan, _) = sample(s)
        camPos = pos - tan * 7 + simd_float3(0, 2.6, 0)
        camLook = pos + tan * 8
        cameraNode.simdPosition = camPos
        cameraNode.simdLook(at: camLook, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        playerNode.simdPosition = pos + simd_float3(0, 0.02, 0)
        playerNode.simdLook(at: pos + tan, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        let seed = runSeed
        DispatchQueue.main.async {
            self.state.phase = .arrival
            self.state.paused = false
            self.state.combo = 0
            self.state.countLabel = ""
            self.state.newRecordScore = false
            self.state.newRecordTime = false
            self.state.statSeed = seed
            self.state.hud = HudSnapshot()
        }
    }

    private func endGame(dead: Bool) {
        phase = dead ? .dead : .finished
        let mm = Int(playTime) / 60
        let ss = playTime.truncatingRemainder(dividingBy: 60)
        let timeStr = String(format: "%d:%04.1f", mm, ss)
        let sc = Int(score), top = Int(topSpeed * 3.6)
        let hh = holesHit, nm = nearMisses
        let medal = Medal.forScore(sc)
        let defaults = UserDefaults.standard
        // A run that skipped part of the course isn't a record. Without this the
        // -startAt debug flag writes nonsense best times.
        let eligible = Self.startOffset <= 40
        let newScoreRec = eligible && sc > defaults.integer(forKey: "hoyo_bestScore")
        if newScoreRec { defaults.set(sc, forKey: "hoyo_bestScore") }
        var newTimeRec = false
        if !dead && eligible {
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
            self.state.statMedal = medal
            self.state.statFinished = !dead
            self.state.newRecordScore = newScoreRec
            self.state.newRecordTime = newTimeRec
            self.state.refreshRecordLine()
            self.state.phase = dead ? .dead : .finished
        }
        if !dead { sound.playCoqui() } else { sound.playThunk() }
        sound.engineLevel = 0; sound.windLevel = 0; sound.skidLevel = 0
        sound.nitroLevel = 0; sound.rumbleLevel = 0
        streakSystem.birthRate = 0
        smokeSystem.birthRate = 0
        sparkSystem.birthRate = 0
        dustSystem.birthRate = 0
    }

    /// Collision damage. `grace` hits are ignored while the post-hit invulnerable
    /// window is open — without it a pothole cluster chain-killed you in a
    /// single second, which is what made the old balance feel unfair.
    private func damage(_ amount: Float, _ msg: String?, grace: Bool = true) {
        if grace && invuln > 0 { return }
        if grace { invuln = 0.85 }
        hp -= amount
        flashT = 1
        combo = 0
        if let msg = msg {
            Haptics.shared.crash(intensity: min(1, 0.45 + amount / 40))
            DispatchQueue.main.async {
                self.state.popup(msg)
                self.state.combo = 0
            }
            lastCombo = 0
        }
        if hp <= 0 { hp = 0; endGame(dead: true) }
    }

    private func popupAsync(_ msg: String) {
        DispatchQueue.main.async { self.state.popup(msg) }
    }

    // MARK: - per-frame update

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard worldAttached else { return }
        if lastTime < 0 { lastTime = time }
        let dt = Float(min(time - lastTime, 0.033))
        lastTime = time

        if state.requestStart { state.requestStart = false; sound.start(); resetGame() }
        if state.requestReset { state.requestReset = false; resetGame() }

        if let n = oceanNormal {
            let fx = Float(time * 0.015).truncatingRemainder(dividingBy: 1)
            let scaleM = SCNMatrix4MakeScale(60, 60, 1)
            n.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeTranslation(fx, fx * 0.6, 0), scaleM)
        }

        if state.paused && phase == .playing {
            sound.engineLevel = 0; sound.windLevel = 0
            sound.skidLevel = 0; sound.nitroLevel = 0; sound.rumbleLevel = 0
            return
        }

        switch phase {
        case .intro:
            updateIntro(dt)
            return
        case .arrival:
            updateArrival(dt)
            if dustT > 0 { dustT -= dt; if dustT <= 0 { dustSystem.birthRate = 0 } }
            return
        case .countdown:
            cd -= dt
            let lbl = cd > 2.4 ? "3" : cd > 1.4 ? "2" : cd > 0.4 ? "1" : "¡DALE!"
            if lbl != cdLabel {
                cdLabel = lbl
                sound.playBeep(final: lbl == "¡DALE!")
                Haptics.shared.tap(intensity: lbl == "¡DALE!" ? 0.9 : 0.5,
                                   sharpness: lbl == "¡DALE!" ? 0.9 : 0.5)
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
            updateSkids(dt)
            return
        case .playing:
            break
        }

        playTime += Double(dt)
        if invuln > 0 { invuln = max(0, invuln - dt) }

        // ----- physics -----
        let i = Int(simd_clamp(s / Self.step, 0, Float(Self.count - 2)))
        let grade = grades[i]
        let curv = curvs[i]
        var steerIn = state.input.steer
        var brakeIn = state.input.brake
        var nitroIn = state.input.nitro
        if Self.autoplay {
            // Smoke-test driver, same idea as the web build's `?autoplay`. A PD
            // controller tracks a weaving lane target so it stays on the asphalt
            // instead of driving off the mountain, while still sweeping the full
            // analog steering range and brake-drifting periodically.
            // The lane controller stays in charge the whole time so the car never
            // drives off the mountain; brake pulses are what tip it into a drift
            // (brake + steer), which is what lays the skid marks.
            let t = Float(playTime)
            let laneTarget = sin(t * 0.7) * 2.4
            steerIn = simd_clamp((laneTarget - x) * 0.42 - xd * 0.14, -1, 1)
            // short pulses only: holding the brake bleeds speed below the drift
            // threshold and nothing ever slides
            // short pulses only: holding the brake bleeds speed below the drift
            // threshold and nothing ever slides
            brakeIn = t > 5 && t.truncatingRemainder(dividingBy: 6) < 2.0
            nitroIn = !brakeIn && t.truncatingRemainder(dividingBy: 6) > 3.5
        }
        let braking = brakeIn
        let wantNitro = nitroIn && nitro > 0
        let steer = simd_clamp(steerIn, -1, 1)
        let drifting = braking && abs(steer) > 0.28 && v > 12
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
        brakeLightMaterial.emission.intensity = braking ? 1.6 : 0
        for f in flameNodes {
            f.isHidden = !wantNitro
            if wantNitro { f.scale = SCNVector3(1, 0.7 + Float.random(in: 0...0.9), 1) }
        }

        // ----- beam -----
        if fireCool > 0 { fireCool = max(0, fireCool - dt) }
        charge = min(100, charge + 15 * dt)          // ~3 shots then a short wait
        if state.input.fireRequested {
            state.input.fireRequested = false
            fireBolt()
        }
        if Self.autoplay {
            // smoke-test driver shoots on a steady cadence
            let ft = Float(playTime)
            if ft > 4 && ft.truncatingRemainder(dividingBy: 1.6) < dt * 1.5 { fireBolt() }
        }
        updateBolts(dt)

        // ----- jump -----
        if jumpCool > 0 { jumpCool = max(0, jumpCool - dt) }
        var jumpFired = false
        if state.input.jumpRequested {
            state.input.jumpRequested = false
            if !airborne && jumpCool <= 0 && v > 6 {
                jumpVel = Self.jumpImpulse
                jumpCool = 0.35
                jumpFired = true
                sound.playJump()
                Haptics.shared.tap(intensity: 0.6, sharpness: 0.4)
            }
        }
        if Self.autoplay && !airborne && jumpCool <= 0 && v > 20 {
            // smoke-test driver hops periodically so the mechanic gets exercised
            let t = Float(playTime)
            if t > 6 && t.truncatingRemainder(dividingBy: 4) < dt * 1.5 {
                jumpVel = Self.jumpImpulse; jumpCool = 0.35; jumpFired = true; sound.playJump()
            }
        }
        _ = jumpFired
        if airborne || jumpVel > 0 {
            jumpVel -= Self.gravity * dt
            jumpY += jumpVel * dt
            if jumpY <= 0 {
                // landing
                jumpY = 0; jumpVel = 0
                shake = max(shake, 0.55)
                sound.playThunk()
                Haptics.shared.crash(intensity: 0.55)
                let (lp, _, lr) = sample(s)
                dustNode.simdPosition = lp + lr * x + simd_float3(0, 0.25, 0)
                dustSystem.birthRate = 260
                dustT = 0.16
            }
        }

        // steering authority drops off the ground — you commit to a line mid-air
        let airFactor: Float = airborne ? 0.34 : 1
        let targetXd = steer * simd_clamp(4 + v * 0.30, 0, 19) * (drifting ? 1.35 : 1) * airFactor
        let grip: Float = (drifting ? 3.2 : 6.5) * (airborne ? 0.4 : 1)
        xd += (targetXd - xd) * min(1, grip * dt)
        xd += -curv * v * v * dt * (drifting ? 0.45 : 0.35)
        x += xd * dt
        x = simd_clamp(x, -Self.barrier, Self.barrier)

        smokeSystem.birthRate = drifting ? 90 : 0
        if drifting {
            styleRun += v * dt * 4
        } else if styleRun > 0 {
            if styleRun > 50 { popupAsync("¡WEPA! +\(Int(styleRun))") }
            score += styleRun
            styleRun = 0
        }
        score += v * dt * 1.2

        // ----- skid trail -----
        let (skidPos, skidTan, skidRgt) = sample(s)
        let contactL = skidPos + skidRgt * (x - 0.85) - skidTan * 1.28
        let contactR = skidPos + skidRgt * (x + 0.85) - skidTan * 1.28
        if drifting && !offroad {
            skidTimer += dt
            if let l = lastSkidL, let r = lastSkidR, skidTimer >= Self.skidInterval {
                emitSkidSegment(from: l, to: contactL, tan: skidTan)
                emitSkidSegment(from: r, to: contactR, tan: skidTan)
                lastSkidL = contactL; lastSkidR = contactR
                skidTimer = 0
            } else if lastSkidL == nil {
                lastSkidL = contactL; lastSkidR = contactR
            }
        } else {
            lastSkidL = nil; lastSkidR = nil; skidTimer = 0
        }
        updateSkids(dt)

        // cliff / offroad
        // Guardrail. The old rule fired at |x| > 8.6 — 3.8 m past the visible
        // posts — then teleported you back to near the centre line, which read as
        // the game randomly yanking the car. Now you scrape along the rail where
        // you can see it, losing speed and (on the grace timer) some health.
        if abs(x) >= Self.barrier {
            let side: Float = x > 0 ? 1 : -1
            x = side * (Self.barrier - 0.04)
            // Bounce off it: reverse the lateral velocity with a floor, so even a
            // glancing scrape shoves the car back toward the asphalt instead of
            // letting you ride the rail.
            xd = -side * max(abs(xd) * 0.6, 4.5)
            if v > 6 {
                v *= 0.78
                shake = max(shake, 0.9)
                sound.playThunk()
                let (rp, _, rr5) = sample(s)
                sparkNode.simdPosition = rp + rr5 * x + simd_float3(0, 0.5, 0)
                sparkSystem.birthRate = 900
                sparkT = 0.12
                damage(9, "¡AY BENDITO!")
            }
        } else if offroad && v > 8 {
            shake = max(shake, 0.25)
            // scrape damage bypasses the grace window: it's small and continuous,
            // and shouldn't be free just because you clipped a pothole a moment ago
            if Float.random(in: 0...1) < dt * 2.2 { damage(2, nil, grace: false) }
        }

        // potholes
        for hIdx in 0..<holes.count {
            let ds = holes[hIdx].s - s
            if ds < -6 || ds > 6 { continue }
            let h = holes[hIdx]
            if !h.hit && !h.zapped && abs(ds) < 1.8 && abs(h.x - x) < h.r + 0.75 {
                holes[hIdx].hit = true
                // flying over a hoyo is the whole point of being able to jump
                if airborne {
                    nearMisses += 1
                    combo = min(combo + 1, 5)
                    score += Float(60 * combo)
                    popupAsync("¡VOLANDO! +\(60 * combo)")
                } else if invuln <= 0 {
                    holesHit += 1
                    v *= 0.62
                    shake = 1.1; jolt = 1
                    sound.playThunk()
                    // was 9 + r*9 + v*0.18 ≈ 25–30 per hit on a 100 HP car
                    damage(5 + h.r * 5 + v * 0.10, "¡HOYO!")
                    let (pp, _, rr3) = sample(s)
                    dustNode.simdPosition = pp + rr3 * x + simd_float3(0, 0.3, 0)
                    dustSystem.birthRate = 350
                    dustT = 0.14
                }
            } else if !h.passed && !h.hit && ds < -2 {
                holes[hIdx].passed = true
                if abs(h.x - x) < h.r + 2.2 {
                    nearMisses += 1
                    combo = min(combo + 1, 5)
                    score += Float(40 * combo)
                    if combo >= 2 { popupAsync("¡CASI! x\(combo) +\(40 * combo)") }
                    else if nearMisses % 3 == 0 { popupAsync("¡CASI! +40") }
                }
            }
        }

        // the dust puff used to be cancelled by a stale dispatched timer when two
        // holes landed close together; it's frame-driven now
        if dustT > 0 {
            dustT -= dt
            if dustT <= 0 { dustSystem.birthRate = 0 }
        }
        if sparkT > 0 {
            sparkT -= dt
            if sparkT <= 0 { sparkSystem.birthRate = 0 }
        }

        // toolboxes
        for tbi in 0..<toolboxes.count {
            let tb = toolboxes[tbi]
            if !tb.taken && abs(tb.s - s) < 2.4 && abs(tb.x - x) < 1.6 {
                toolboxes[tbi].taken = true
                tb.node.isHidden = true
                hp = min(100, hp + 26)
                score += 50
                sound.playCoqui()
                Haptics.shared.tap(intensity: 0.5, sharpness: 0.35)
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
                Haptics.shared.tap(intensity: 0.4, sharpness: 0.7)
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
                damage(5, "¡LA IGUANA!")
            }
            if iguanas[gi].stateRaw != 0 { positionIguana(&iguanas[gi]) }
        }

        // traffic
        for ti in 0..<traffic.count {
            traffic[ti].cool = max(0, traffic[ti].cool - dt)
            traffic[ti].s += traffic[ti].v * dt
            // being shoved: slide sideways, yaw with it, then settle
            if abs(traffic[ti].vx) > 0.01 {
                traffic[ti].x += traffic[ti].vx * dt
                traffic[ti].spin += traffic[ti].vx * dt * 0.5
                traffic[ti].vx *= exp(-dt * 1.6)
                if abs(traffic[ti].x) > Self.barrier - 0.5 {
                    // shunted off the road entirely — recycle it
                    traffic[ti].s = Self.total * 3
                }
            } else if abs(traffic[ti].spin) > 0.001 {
                traffic[ti].spin *= exp(-dt * 2.2)
            }
            if traffic[ti].s > s + 600 || traffic[ti].s < s - 120 || traffic[ti].s > Self.total - 40 {
                // el tapón is a town problem: cars bunch up tight through the
                // pueblo and thin out on the mountain and the coastal run-in
                let w = Self.regionWeights(s / Self.total)
                let gap = w.x * 300 + w.y * 130 + w.z * 260
                traffic[ti].s = s + gap * (0.7 + runRng.next() * 0.9)
                traffic[ti].x = Self.laneCentres[Int(runRng.next() * 4) % 4]
                // and it crawls slower in town
                traffic[ti].v = (w.y > 0.5 ? 8 : 11) + runRng.next() * 7
                traffic[ti].missed = false; traffic[ti].cool = 0
                traffic[ti].vx = 0; traffic[ti].spin = 0
                traffic[ti].clearedByJump = false
                if traffic[ti].s > Self.total - 60 { traffic[ti].s = Self.total * 2 }
            }
            let tc = traffic[ti]
            let tDs = tc.s - s
            if tc.cool <= 0 && abs(tDs) < 3.2 && abs(tc.x - x) < 1.7 {
                let closing = v - tc.v
                if jumpY > 0.85 {
                    // sailed clean over the roof
                    if !tc.clearedByJump {
                        traffic[ti].clearedByJump = true
                        combo = min(combo + 1, 5)
                        score += Float(150 * combo)
                        sound.playHorn()
                        popupAsync("¡POR ENCIMA! +\(150 * combo)")
                    }
                } else if closing > 16 {
                    // hit it hard enough to shove it out of the lane rather than
                    // bounce off it — the tapón is traffic, not a wall
                    traffic[ti].cool = 1.2
                    let side: Float = tc.x >= x ? 1 : -1
                    traffic[ti].vx = side * (5.5 + closing * 0.14)
                    traffic[ti].v *= 0.86
                    v *= 0.9
                    shake = max(shake, 0.85); jolt = 0.7
                    sound.playThunk(); sound.playHorn()
                    let (cp, _, cr) = sample(s)
                    sparkNode.simdPosition = cp + cr * x + simd_float3(0, 0.55, 0)
                    sparkSystem.birthRate = 700
                    sparkT = 0.1
                    score += tc.isPolice ? 250 : 120
                    damage(6, tc.isPolice ? "¡LA JARA!" : "¡QUÍTATE!")
                } else {
                    traffic[ti].cool = 2
                    v = min(v, tc.v * 0.8)
                    shake = 1.2; jolt = 1
                    sound.playThunk(); sound.playHorn()
                    damage(16, "¡EL TAPÓN!")
                }
            } else if !tc.missed && tDs < -1 && tDs > -8 && abs(tc.x - x) < 3 &&
                      abs(tc.x - x) > 1.7 && v - tc.v > 12 {
                traffic[ti].missed = true
                combo = min(combo + 1, 5)
                score += Float(80 * combo)
                sound.playHorn()
                popupAsync("¡FUA! +\(80 * combo)")
            }
            if tDs > -150 && tDs < 700 {
                tc.node.isHidden = false
                let (pp, tt, rr4) = sample(tc.s)
                tc.node.simdPosition = pp + rr4 * tc.x
                tc.node.simdLook(at: tc.node.simdPosition + tt,
                                 up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
                if abs(tc.spin) > 0.001 {
                    tc.node.simdOrientation = simd_mul(tc.node.simdOrientation,
                        simd_quatf(angle: tc.spin, axis: simd_float3(0, 1, 0)))
                }
            } else { tc.node.isHidden = true }
        }

        if s >= Self.total - 8 { endGame(dead: false) }

        // ----- place the car -----
        let (pos, tan, rgt) = sample(s)
        let groundPos = pos + rgt * x + simd_float3(0, 0.02, 0)
        let carPos = groundPos + simd_float3(0, jumpY, 0)
        playerNode.simdPosition = carPos
        playerNode.simdLook(at: carPos + tan, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))

        let tNow = Float(time)
        leanRoll += ((-steer * 0.09 - xd * 0.012) - leanRoll) * min(1, 8 * dt)
        driftYaw += ((-xd * 0.03 - (drifting ? steer * 0.5 : 0)) - driftYaw) * min(1, 6 * dt)
        // nose up as it leaves the ground, nose down on the way back in
        let airPitch: Float = airborne ? simd_clamp(-jumpVel * 0.030, -0.16, 0.16) : 0
        pitchAng += ((braking ? 0.05 : (wantNitro ? -0.035 : 0)) + airPitch - pitchAng)
                  * min(1, 6 * dt)
        if jolt > 0 { jolt = max(0, jolt - dt * 4) }
        chassisNode.eulerAngles = SCNVector3(pitchAng + jolt * 0.08 * sin(tNow * 60), driftYaw, leanRoll)
        // idle hover bob, plus the impact jolt
        chassisNode.position.y = sin(tNow * 2.3) * 0.055 - jolt * 0.12 * abs(sin(tNow * 42))
        // blink through the grace window so the player can read that it's active
        chassisNode.opacity = invuln > 0 ? CGFloat(0.45 + 0.55 * abs(sin(tNow * 22))) : 1

        // the ring spins faster the harder the craft is working
        wheelSpin += (1.4 + v * 0.09) * dt
        ufoLightRing.eulerAngles.y = wheelSpin

        // every cruiser's bar flashes off one shared pair of materials
        let flash = sin(tNow * 9) > 0
        policeRedMat.emission.intensity = flash ? 2.2 : 0.05
        policeBlueMat.emission.intensity = flash ? 0.05 : 2.2
        glowMaterial.transparency = CGFloat(0.42 + 0.14 * sin(tNow * 9))

        // shadow stays on the road and shrinks as the car climbs, which is what
        // actually communicates height
        blobNode.simdPosition = simd_float3(groundPos.x, pos.y + 0.03, groundPos.z)
        blobNode.eulerAngles = SCNVector3(-.pi / 2, atan2(tan.x, -tan.z), 0)
        let shadowScale = 1 / (1 + jumpY * 0.42)
        blobNode.scale = SCNVector3(shadowScale, shadowScale, 1)
        blobNode.opacity = CGFloat(simd_clamp(1 - jumpY * 0.22, 0.3, 1))

        // ----- camera -----
        // closer and tighter than the original 6.4–10 m / 72° rig, so the car is
        // a real presence on screen instead of a distant speck
        let camDist = 4.5 + v * 0.028
        var target = carPos - tan * camDist
        target.y += 1.70 + v * 0.009
        target += rgt * (x * 0.1)
        let k = 1 - exp(-dt * 5.5)
        camPos = simd_mix(camPos, target, simd_float3(repeating: k))
        var lookTarget = carPos + tan * 12
        lookTarget.y += 1.15
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
        cameraNode.simdOrientation = simd_mul(cameraNode.simdOrientation,
            simd_quatf(angle: leanRoll * 0.45, axis: simd_float3(0, 0, 1)))
        // A gentler ramp than the original 72 + v*0.6 → 116. Widening to ~100 at
        // top speed shrank the car right back down at exactly the moment you most
        // need to read it against the road.
        let targetFov = Self.baseFov + CGFloat(v * 0.32) + (wantNitro ? 4 : 0)
        fov += (min(max(targetFov, Self.baseFov), 86) - fov) * CGFloat(min(1, 4.5 * dt))
        cameraNode.camera?.fieldOfView = fov

        streakSystem.birthRate = v > 25 ? CGFloat((v - 25) * 4) * quality.streakScale : 0

        // ----- audio -----
        // Six gears instead of one long rising whine: pitch climbs through each
        // gear and drops on the shift, which is most of what sells acceleration.
        let gearSpan: Float = 64.0 / 6
        let gear = min(5, Int(v / gearSpan))
        let inGear = (v - Float(gear) * gearSpan) / gearSpan
        sound.engineFreq = Double(52 + inGear * 118 + Float(gear) * 9 + (wantNitro ? 26 : 0))
        sound.engineLevel = Double(0.05 + simd_clamp(v / 64, 0, 1) * 0.075)
        sound.windLevel = Double(simd_clamp(v / 90, 0, 0.35))
        sound.skidLevel = drifting ? Double(simd_clamp(v / 140, 0, 0.22)) : 0
        sound.nitroLevel = wantNitro ? 0.05 : 0
        sound.rumbleLevel = offroad ? Double(simd_clamp(v / 55, 0, 0.32)) : 0

        // matching haptic while you're on the strips / dirt
        if offroad && v > 8 {
            rumbleHapticT -= dt
            if rumbleHapticT <= 0 {
                Haptics.shared.rumble(duration: 0.22, intensity: min(0.75, 0.3 + v / 90))
                rumbleHapticT = 0.2
            }
        } else {
            rumbleHapticT = 0
        }

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
        // One batched snapshot at ~30 Hz. The old code fired ten separate
        // @Published writes every frame — sixty dispatches and ~600 SwiftUI
        // invalidations a second for numbers that change by a pixel.
        if combo != lastCombo {
            let c = combo
            lastCombo = c
            DispatchQueue.main.async { self.state.combo = c }
        }
        // region crossing
        let region = Region.at(progress: s / Self.total)
        if region != lastRegion {
            lastRegion = region
            sound.playCoqui()
            DispatchQueue.main.async { self.state.showRegion(region) }
        }

        hudClock += dt
        if hudClock >= 1.0 / 30.0 {
            hudClock = 0
            // drift the haze toward the current region's colour
            let rw = Self.regionWeights(s / Self.total)
            let fog = Self.regionFog[0] * rw.x + Self.regionFog[1] * rw.y + Self.regionFog[2] * rw.z
            scene.fogColor = UIColor(red: CGFloat(fog.x), green: CGFloat(fog.y),
                                     blue: CGFloat(fog.z), alpha: 1)
            let mm = Int(playTime) / 60
            let ss = playTime.truncatingRemainder(dividingBy: 60)
            var snap = HudSnapshot()
            snap.speedKmh = Int(v * 3.6)
            snap.score = Int(score)
            snap.hp = Double(hp)
            snap.nitro = Double(nitro)
            snap.charge = Double(charge)
            snap.progress = Double(s / Self.total)
            snap.speedNorm = Double(simd_clamp((v - 20) / 30, 0, 1))
            snap.flash = Double(max(0, flashT))
            snap.nitroActive = wantNitro
            snap.invuln = invuln > 0
            snap.timeText = String(format: "%d:%04.1f", mm, ss)
            DispatchQueue.main.async { self.state.hud = snap }
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
