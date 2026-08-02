import UIKit
import simd

/// Every texture is generated at launch — no image assets in the bundle.
enum Textures {

    /// Six cubemap faces: sunset gradient by elevation with the sun disc,
    /// its glow, and early stars baked in. Used as the scene background, so it
    /// pans correctly with the camera and is never touched by fog.
    enum SkyMood { case sunset, rainforest, tropical, night }

    static func skyCubemap(_ mood: SkyMood = .sunset) -> [UIImage] {
        let n = 256
        let sunDir = simd_normalize(simd_float3(0.16, 0.13, -0.98))
        var faces: [UIImage] = []
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        for f in 0..<6 {
            var pixels = [UInt8](repeating: 255, count: n * n * 4)
            for y in 0..<n {
                for x in 0..<n {
                    let u = (Float(x) + 0.5) / Float(n) * 2 - 1
                    let v = (Float(y) + 0.5) / Float(n) * 2 - 1
                    var d: simd_float3
                    switch f {
                    case 0: d = simd_float3(1, -v, -u)      // +X
                    case 1: d = simd_float3(-1, -v, u)      // -X
                    case 2: d = simd_float3(u, 1, v)        // +Y
                    case 3: d = simd_float3(u, -1, -v)      // -Y
                    case 4: d = simd_float3(u, -v, 1)       // +Z
                    default: d = simd_float3(-u, -v, -1)    // -Z
                    }
                    d = simd_normalize(d)
                    if mood == .night {
                        // Caribbean night: deep blue overhead, a warm lift at the
                        // horizon from the city, a moon, and dense stars. The moon
                        // sits where the set puts its glare on the water.
                        let t = simd_clamp((d.y + 0.15) / 1.1, 0, 1)
                        var c2 = simd_mix(simd_float3(0.055, 0.085, 0.165),
                                          simd_float3(0.008, 0.014, 0.045),
                                          simd_float3(repeating: powf(t, 0.6)))
                        // Sodium haze, kept tight to the horizon: the sea is a near
                        // mirror, so a broad warm band turns the whole ocean orange.
                        if d.y < 0.07 {
                            let g = powf(1 - simd_clamp(abs(d.y) / 0.07, 0, 1), 3)
                            c2 += simd_float3(0.055, 0.028, 0.009) * g
                        }
                        let moonDir = simd_normalize(simd_float3(-0.45, 0.30, -0.84))
                        let md = simd_dot(d, moonDir)
                        if md > 0 {
                            c2 += simd_float3(0.85, 0.88, 1.0) * powf(md, 6000) * 3.2   // disc
                            c2 += simd_float3(0.35, 0.42, 0.62) * powf(md, 60) * 0.30   // halo
                        }
                        if d.y > -0.04 {
                            let h = starHash(d)
                            if h > 0.9975 {
                                let b = (h - 0.9975) / 0.0025
                                c2 += simd_float3(repeating: b * 0.95) * min(1, (d.y + 0.04) * 5)
                            }
                        }
                        let i2 = (y * n + x) * 4
                        pixels[i2] = UInt8(min(max(c2.x, 0), 1) * 255)
                        pixels[i2 + 1] = UInt8(min(max(c2.y, 0), 1) * 255)
                        pixels[i2 + 2] = UInt8(min(max(c2.z, 0), 1) * 255)
                        continue
                    }
                    if mood != .sunset {
                        // Overcast canopy light: no sun, no stars, brightest near the
                        // horizon where the mist glows. A sunset sky over a rainforest
                        // fought the biome badly.
                        var c2 = mood == .rainforest
                            ? forestSkyColor(elevation: d.y)
                            : tropicalSkyColor(elevation: d.y)
                        c2 += simd_float3(repeating: 0.02 * sinf(d.x * 40) * sinf(d.z * 40))
                        if mood == .tropical {
                            // a high sun and a few soft clouds
                            let sd2 = simd_dot(d, simd_normalize(simd_float3(0.2, 0.72, -0.66)))
                            if sd2 > 0 {
                                c2 += simd_float3(1.0, 0.98, 0.90) * powf(sd2, 2200) * 1.4
                                c2 += simd_float3(1.0, 0.96, 0.86) * powf(sd2, 90) * 0.16
                            }
                            if d.y > 0.08 {
                                let cl = cloudNoise(d)
                                if cl > 0.63 {
                                    let a = min((cl - 0.63) / 0.34, 1) * min((d.y - 0.08) * 4, 1)
                                    c2 = simd_mix(c2, simd_float3(1.0, 0.99, 0.97),
                                                  simd_float3(repeating: a * 0.6))
                                }
                            }
                        }
                        let i2 = (y * n + x) * 4
                        pixels[i2] = UInt8(min(max(c2.x, 0), 1) * 255)
                        pixels[i2 + 1] = UInt8(min(max(c2.y, 0), 1) * 255)
                        pixels[i2 + 2] = UInt8(min(max(c2.z, 0), 1) * 255)
                        pixels[i2 + 3] = 255
                        continue
                    }
                    var c = skyColor(elevation: d.y)
                    let sd = simd_dot(d, sunDir)
                    if sd > 0 {
                        c += simd_float3(1.0, 0.85, 0.55) * powf(sd, 1400) * 1.3   // disc
                        c += simd_float3(1.0, 0.55, 0.30) * powf(sd, 50) * 0.38    // glow
                    }
                    if d.y > 0.3 {
                        let h = starHash(d)
                        if h > 0.9974 {
                            let tw = Float((h - 0.9974) / 0.0026)
                            c += simd_float3(repeating: tw * min((d.y - 0.3) * 2.2, 1) * 0.85)
                        }
                    }
                    let i = (y * n + x) * 4
                    pixels[i] = UInt8(min(max(c.x, 0), 1) * 255)
                    pixels[i + 1] = UInt8(min(max(c.y, 0), 1) * 255)
                    pixels[i + 2] = UInt8(min(max(c.z, 0), 1) * 255)
                    pixels[i + 3] = 255
                }
            }
            let img: UIImage? = pixels.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n,
                                          bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: space, bitmapInfo: info),
                      let cg = ctx.makeImage() else { return nil }
                return UIImage(cgImage: cg)
            }
            if let img = img { faces.append(img) }
        }
        return faces
    }

    /// Bright Caribbean afternoon: deep blue overhead easing to a pale, hazy
    /// horizon where the sea glare is.
    private static func tropicalSkyColor(elevation e: Float) -> simd_float3 {
        let stops: [(Float, simd_float3)] = [
            (-1.00, simd_float3(0.62, 0.80, 0.88)),
            (0.00, simd_float3(0.78, 0.90, 0.95)),
            (0.10, simd_float3(0.60, 0.80, 0.93)),
            (0.35, simd_float3(0.34, 0.62, 0.88)),
            (0.70, simd_float3(0.17, 0.44, 0.80)),
            (1.00, simd_float3(0.10, 0.32, 0.70))
        ]
        for k in 0..<(stops.count - 1) {
            if e <= stops[k + 1].0 {
                let t = (e - stops[k].0) / (stops[k + 1].0 - stops[k].0)
                return simd_mix(stops[k].1, stops[k + 1].1, simd_float3(repeating: t))
            }
        }
        return stops[stops.count - 1].1
    }

    /// Cheap 3-octave value noise on the sky direction, for cloud masses.
    private static func cloudNoise(_ d: simd_float3) -> Float {
        var v: Float = 0, amp: Float = 0.5, f: Float = 2.2
        for _ in 0..<3 {
            v += amp * (0.5 + 0.5 * sinf((d.x + d.y * 0.7) * f * 5.3)
                                 * sinf((d.z - d.x * 0.5) * f * 4.7 + d.y * 2.6))
            amp *= 0.5; f *= 2.1
        }
        return v
    }

    /// Flat green-grey overcast for El Yunque.
    private static func forestSkyColor(elevation e: Float) -> simd_float3 {
        let stops: [(Float, simd_float3)] = [
            (-1.00, simd_float3(0.46, 0.52, 0.42)),
            (0.00, simd_float3(0.62, 0.68, 0.55)),
            (0.10, simd_float3(0.56, 0.62, 0.50)),
            (0.35, simd_float3(0.40, 0.47, 0.39)),
            (0.70, simd_float3(0.27, 0.33, 0.28)),
            (1.00, simd_float3(0.20, 0.25, 0.22))
        ]
        for k in 0..<(stops.count - 1) {
            if e <= stops[k + 1].0 {
                let t = (e - stops[k].0) / (stops[k + 1].0 - stops[k].0)
                return simd_mix(stops[k].1, stops[k + 1].1, simd_float3(repeating: t))
            }
        }
        return stops[stops.count - 1].1
    }

    private static func skyColor(elevation e: Float) -> simd_float3 {
        let stops: [(Float, simd_float3)] = [
            (-1.00, simd_float3(1.00, 0.67, 0.47)),
            (0.00, simd_float3(1.00, 0.67, 0.47)),
            (0.06, simd_float3(1.00, 0.83, 0.56)),
            (0.14, simd_float3(1.00, 0.54, 0.33)),
            (0.30, simd_float3(0.92, 0.29, 0.50)),
            (0.55, simd_float3(0.47, 0.16, 0.57)),
            (1.00, simd_float3(0.14, 0.07, 0.33))
        ]
        for k in 0..<(stops.count - 1) {
            if e <= stops[k + 1].0 {
                let t = (e - stops[k].0) / (stops[k + 1].0 - stops[k].0)
                return simd_mix(stops[k].1, stops[k + 1].1, simd_float3(repeating: t))
            }
        }
        return stops[stops.count - 1].1
    }

    private static func starHash(_ d: simd_float3) -> Float {
        let q = simd_float3(floorf(d.x * 180), floorf(d.y * 180), floorf(d.z * 180))
        let s = sinf(simd_dot(q, simd_float3(12.9898, 78.233, 37.719))) * 43758.5453
        return s - floorf(s)
    }

    /// Sunset gradient used as the scene background.
    static func skyGradient() -> UIImage {
        let size = CGSize(width: 16, height: 512)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors: [(CGFloat, UIColor)] = [
                (0.00, UIColor(red: 0.14, green: 0.07, blue: 0.33, alpha: 1)),
                (0.36, UIColor(red: 0.47, green: 0.16, blue: 0.57, alpha: 1)),
                (0.57, UIColor(red: 0.92, green: 0.29, blue: 0.50, alpha: 1)),
                (0.72, UIColor(red: 1.00, green: 0.54, blue: 0.33, alpha: 1)),
                (0.83, UIColor(red: 1.00, green: 0.83, blue: 0.56, alpha: 1)),
                (1.00, UIColor(red: 1.00, green: 0.67, blue: 0.47, alpha: 1))
            ]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors.map { $0.1.cgColor } as CFArray,
                                  locations: colors.map { $0.0 })!
            ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                             end: CGPoint(x: 0, y: 512), options: [])
        }
    }

    /// Asphalt: patchy resurfacing, two grades of aggregate, tar seams and
    /// hairline cracks. 512² — the road fills most of the screen, so it carries
    /// more of the look than anything else in the scene.
    static func asphalt() -> UIImage {
        let dim: CGFloat = 512
        let size = CGSize(width: dim, height: dim)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            UIColor(red: 0.185, green: 0.20, blue: 0.22, alpha: 1).setFill()
            g.fill(CGRect(origin: .zero, size: size))

            // broad tonal patches — old repairs and different asphalt batches.
            // Kept low-contrast so the 512 tile doesn't announce itself.
            for _ in 0..<24 {
                let v = CGFloat.random(in: -0.03...0.038)
                UIColor(red: 0.185 + v, green: 0.20 + v, blue: 0.22 + v,
                        alpha: .random(in: 0.3...0.7)).setFill()
                g.fill(CGRect(x: .random(in: -40...dim), y: .random(in: -40...dim),
                              width: .random(in: 70...230), height: .random(in: 60...210)))
            }

            // dark aggregate
            for _ in 0..<13000 {
                let v = CGFloat.random(in: 0.12...0.34)
                UIColor(red: v, green: v + 0.012, blue: v + 0.03,
                        alpha: .random(in: 0.18...0.7)).setFill()
                let s = CGFloat.random(in: 1...2.3)
                g.fill(CGRect(x: .random(in: 0...dim), y: .random(in: 0...dim), width: s, height: s))
            }
            // pale stone flecks catching the low sun
            for _ in 0..<1700 {
                let v = CGFloat.random(in: 0.36...0.52)
                UIColor(red: v, green: v, blue: v * 0.97, alpha: .random(in: 0.1...0.34)).setFill()
                let s = CGFloat.random(in: 1...2.6)
                g.fillEllipse(in: CGRect(x: .random(in: 0...dim), y: .random(in: 0...dim),
                                         width: s, height: s))
            }

            // tar seams — thick, glossy, darker
            g.setLineCap(.round)
            for _ in 0..<5 {
                g.setStrokeColor(UIColor(red: 0.10, green: 0.10, blue: 0.115,
                                         alpha: .random(in: 0.35...0.6)).cgColor)
                g.setLineWidth(.random(in: 2.5...5))
                var cx = CGFloat.random(in: 0...dim), cy = CGFloat.random(in: 0...dim)
                g.move(to: CGPoint(x: cx, y: cy))
                for _ in 0..<6 {
                    cx += .random(in: -60...60); cy += .random(in: 20...85)
                    g.addLine(to: CGPoint(x: cx, y: cy))
                }
                g.strokePath()
            }

            // hairline cracks
            for _ in 0..<16 {
                g.setStrokeColor(UIColor(red: 0.055, green: 0.055, blue: 0.07,
                                         alpha: .random(in: 0.3...0.6)).cgColor)
                g.setLineWidth(.random(in: 0.8...1.7))
                var cx = CGFloat.random(in: 0...dim), cy = CGFloat.random(in: 0...dim)
                g.move(to: CGPoint(x: cx, y: cy))
                for _ in 0..<5 {
                    cx += .random(in: -42...42); cy += .random(in: 0...58)
                    g.addLine(to: CGPoint(x: cx, y: cy))
                }
                g.strokePath()
            }
        }
    }

    /// Packed dirt trail: wet earth, exposed roots, embedded stones and puddles.
    static func dirtTrail() -> UIImage {
        let dim: CGFloat = 512
        return UIGraphicsImageRenderer(size: CGSize(width: dim, height: dim)).image { ctx in
            let g = ctx.cgContext
            UIColor(red: 0.31, green: 0.23, blue: 0.16, alpha: 1).setFill()
            g.fill(CGRect(x: 0, y: 0, width: dim, height: dim))

            // damp tonal patches
            for _ in 0..<30 {
                let v = CGFloat.random(in: -0.06...0.05)
                UIColor(red: 0.31 + v, green: 0.23 + v * 0.8, blue: 0.16 + v * 0.6,
                        alpha: .random(in: 0.3...0.75)).setFill()
                g.fill(CGRect(x: .random(in: -40...dim), y: .random(in: -40...dim),
                              width: .random(in: 70...240), height: .random(in: 60...200)))
            }
            // grit
            for _ in 0..<11000 {
                let v = CGFloat.random(in: 0.18...0.44)
                UIColor(red: v, green: v * 0.76, blue: v * 0.55,
                        alpha: .random(in: 0.15...0.6)).setFill()
                let sz = CGFloat.random(in: 1...2.6)
                g.fill(CGRect(x: .random(in: 0...dim), y: .random(in: 0...dim), width: sz, height: sz))
            }
            // embedded stones
            for _ in 0..<130 {
                let v = CGFloat.random(in: 0.40...0.58)
                UIColor(red: v, green: v * 0.95, blue: v * 0.88, alpha: .random(in: 0.35...0.8)).setFill()
                let r = CGFloat.random(in: 3...9)
                g.fillEllipse(in: CGRect(x: .random(in: 0...dim), y: .random(in: 0...dim),
                                         width: r, height: r * .random(in: 0.6...1.0)))
            }
            // roots crossing the path
            g.setLineCap(.round)
            for _ in 0..<9 {
                g.setStrokeColor(UIColor(red: 0.20, green: 0.14, blue: 0.09,
                                         alpha: .random(in: 0.5...0.85)).cgColor)
                g.setLineWidth(.random(in: 4...9))
                var cx = CGFloat.random(in: -20...dim), cy = CGFloat.random(in: 0...dim)
                g.move(to: CGPoint(x: cx, y: cy))
                for _ in 0..<5 {
                    cx += .random(in: 40...110); cy += .random(in: -34...34)
                    g.addLine(to: CGPoint(x: cx, y: cy))
                }
                g.strokePath()
            }
            // puddles
            for _ in 0..<16 {
                UIColor(red: 0.17, green: 0.17, blue: 0.15, alpha: .random(in: 0.3...0.6)).setFill()
                let w = CGFloat.random(in: 16...54)
                g.fillEllipse(in: CGRect(x: .random(in: 0...dim), y: .random(in: 0...dim),
                                         width: w, height: w * .random(in: 0.4...0.7)))
            }
        }
    }

    /// Wet packed sand at the tide line — ripples, shell grit, damp streaks.
    static func wetSand() -> UIImage {
        let dim: CGFloat = 512
        return UIGraphicsImageRenderer(size: CGSize(width: dim, height: dim)).image { ctx in
            let g = ctx.cgContext
            UIColor(red: 0.85, green: 0.77, blue: 0.63, alpha: 1).setFill()
            g.fill(CGRect(x: 0, y: 0, width: dim, height: dim))

            // damp patches, darker where the water has just been
            for _ in 0..<26 {
                let v = CGFloat.random(in: -0.10...0.04)
                UIColor(red: 0.85 + v, green: 0.77 + v, blue: 0.63 + v * 0.8,
                        alpha: .random(in: 0.3...0.7)).setFill()
                g.fill(CGRect(x: .random(in: -40...dim), y: .random(in: -40...dim),
                              width: .random(in: 90...260), height: .random(in: 50...170)))
            }
            // ripple lines left by the tide
            g.setLineCap(.round)
            for _ in 0..<26 {
                g.setStrokeColor(UIColor(red: 0.74, green: 0.66, blue: 0.53,
                                         alpha: .random(in: 0.25...0.55)).cgColor)
                g.setLineWidth(.random(in: 1.5...4))
                var cx: CGFloat = -20, cy = CGFloat.random(in: 0...dim)
                g.move(to: CGPoint(x: cx, y: cy))
                while cx < dim + 20 {
                    cx += .random(in: 30...70); cy += .random(in: -12...12)
                    g.addLine(to: CGPoint(x: cx, y: cy))
                }
                g.strokePath()
            }
            // grit and broken shell
            for _ in 0..<9000 {
                let v = CGFloat.random(in: 0.58...0.86)
                UIColor(red: v, green: v * 0.92, blue: v * 0.78,
                        alpha: .random(in: 0.15...0.5)).setFill()
                let sz = CGFloat.random(in: 1...2.2)
                g.fill(CGRect(x: .random(in: 0...dim), y: .random(in: 0...dim), width: sz, height: sz))
            }
            for _ in 0..<160 {
                UIColor(white: .random(in: 0.88...1.0), alpha: .random(in: 0.4...0.85)).setFill()
                let r = CGFloat.random(in: 2...5)
                g.fillEllipse(in: CGRect(x: .random(in: 0...dim), y: .random(in: 0...dim),
                                         width: r, height: r * .random(in: 0.5...0.9)))
            }
        }
    }

    /// Near-white clumpy noise, multiplied over the terrain's vertex colours so
    /// the hillsides read as vegetation rather than smooth gradients.
    static func groundDetail() -> UIImage {
        let dim: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: dim, height: dim)).image { ctx in
            let g = ctx.cgContext
            UIColor(white: 0.97, alpha: 1).setFill()
            g.fill(CGRect(x: 0, y: 0, width: dim, height: dim))
            // darker clumps
            for _ in 0..<900 {
                let v = CGFloat.random(in: 0.74...0.94)
                UIColor(white: v, alpha: .random(in: 0.25...0.7)).setFill()
                let r = CGFloat.random(in: 3...16)
                g.fillEllipse(in: CGRect(x: .random(in: -10...dim), y: .random(in: -10...dim),
                                         width: r, height: r * .random(in: 0.6...1.4)))
            }
            // fine speckle for close-up grain
            for _ in 0..<3000 {
                let v = CGFloat.random(in: 0.7...1.0)
                UIColor(white: v, alpha: .random(in: 0.15...0.45)).setFill()
                let s = CGFloat.random(in: 1...2.4)
                g.fill(CGRect(x: .random(in: 0...dim), y: .random(in: 0...dim), width: s, height: s))
            }
        }
    }

    /// Concave-looking pothole interior: near-black at the centre, lifting a
    /// little toward the lip. A real recess can't be used — the road is a flat
    /// surface with no hole cut in it, so anything below the road plane gets
    /// occluded by the road itself.
    static func holeDepth() -> UIImage {
        let dim: CGFloat = 128
        return UIGraphicsImageRenderer(size: CGSize(width: dim, height: dim)).image { ctx in
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(red: 0.015, green: 0.015, blue: 0.025, alpha: 1).cgColor,
                                           UIColor(red: 0.03, green: 0.028, blue: 0.038, alpha: 1).cgColor,
                                           UIColor(red: 0.11, green: 0.10, blue: 0.10, alpha: 1).cgColor,
                                           UIColor(red: 0.20, green: 0.18, blue: 0.16, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 0.45, 0.82, 1])!
            ctx.cgContext.drawRadialGradient(grad,
                startCenter: CGPoint(x: dim / 2, y: dim * 0.44), startRadius: 0,
                endCenter: CGPoint(x: dim / 2, y: dim / 2), endRadius: dim / 2, options: [])
        }
    }

    /// The Puerto Rican flag.
    static func prFlag() -> UIImage {
        let size = CGSize(width: 150, height: 100)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            for i in 0..<5 {
                (i % 2 == 0 ? UIColor(red: 0.88, green: 0.13, blue: 0.22, alpha: 1) : .white).setFill()
                g.fill(CGRect(x: 0, y: i * 20, width: 150, height: 20))
            }
            UIColor(red: 0, green: 0.31, blue: 0.63, alpha: 1).setFill()
            g.move(to: .zero)
            g.addLine(to: CGPoint(x: 87, y: 50))
            g.addLine(to: CGPoint(x: 0, y: 100))
            g.closePath()
            g.fillPath()
            UIColor.white.setFill()
            let star = UIBezierPath()
            for k in 0..<5 {
                var a = -CGFloat.pi / 2 + CGFloat(k) * 2 * .pi / 5
                let outer = CGPoint(x: 30 + cos(a) * 14, y: 50 + sin(a) * 14)
                if k == 0 { star.move(to: outer) } else { star.addLine(to: outer) }
                a += .pi / 5
                star.addLine(to: CGPoint(x: 30 + cos(a) * 6, y: 50 + sin(a) * 6))
            }
            star.close()
            star.fill()
        }
    }

    /// Banner with big italic text for the SALIDA / META arches.
    static func banner(text: String, background: UIColor) -> UIImage {
        let size = CGSize(width: 512, height: 84)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            background.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))
            let font = UIFont.systemFont(ofSize: 56, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .obliqueness: 0.2
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let bounds = str.boundingRect(with: size, options: [], context: nil)
            str.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                 y: (size.height - bounds.height) / 2))
        }
    }

    /// Random-bump normal map that scrolls across the ocean for sparkle.
    static func waterNormal() -> UIImage {
        let dim = 128
        let size = CGSize(width: dim, height: dim)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            // neutral normal (pointing up)
            UIColor(red: 0.5, green: 0.5, blue: 1.0, alpha: 1).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<900 {
                let nx = CGFloat.random(in: 0.32...0.68)
                let ny = CGFloat.random(in: 0.32...0.68)
                UIColor(red: nx, green: ny, blue: 1.0, alpha: 0.5).setFill()
                let r = CGFloat.random(in: 1.5...5)
                g.fillEllipse(in: CGRect(x: .random(in: 0...CGFloat(dim)),
                                         y: .random(in: 0...CGFloat(dim)),
                                         width: r, height: r))
            }
        }
    }

    /// Radial soft shadow for under the car.
    static func blobShadow() -> UIImage {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(white: 0, alpha: 0.45).cgColor,
                                           UIColor(white: 0, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(grad,
                startCenter: CGPoint(x: 64, y: 64), startRadius: 0,
                endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
    }

    /// Fresh-tar patch laid over a pothole the beam has sealed: opaque in the
    /// middle, feathering out so it blends into the surrounding asphalt.
    static func patch() -> UIImage {
        let dim: CGFloat = 128
        return UIGraphicsImageRenderer(size: CGSize(width: dim, height: dim)).image { ctx in
            let g = ctx.cgContext
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1).cgColor,
                                           UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1).cgColor,
                                           UIColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 0.7).cgColor,
                                           UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 0.62, 0.84, 1])!
            g.drawRadialGradient(grad,
                startCenter: CGPoint(x: dim / 2, y: dim / 2), startRadius: 0,
                endCenter: CGPoint(x: dim / 2, y: dim / 2), endRadius: dim / 2, options: [])
            // a few brighter aggregate specks so it doesn't read as a flat blob
            for _ in 0..<220 {
                let v = CGFloat.random(in: 0.2...0.34)
                UIColor(red: v, green: v, blue: v, alpha: .random(in: 0.2...0.6)).setFill()
                let a = CGFloat.random(in: 0...(2 * .pi)), r = CGFloat.random(in: 0...(dim * 0.42))
                g.fill(CGRect(x: dim / 2 + cos(a) * r, y: dim / 2 + sin(a) * r, width: 2, height: 2))
            }
        }
    }

    /// Soft round particle for smoke and dust.
    static func softCircle() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(white: 1, alpha: 1).cgColor,
                                           UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(grad,
                startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
        }
    }
}
