import UIKit
import simd

/// Every texture is generated at launch — no image assets in the bundle.
enum Textures {

    /// Six cubemap faces: sunset gradient by elevation with the sun disc,
    /// its glow, and early stars baked in. Used as the scene background, so it
    /// pans correctly with the camera and is never touched by fog.
    static func skyCubemap() -> [UIImage] {
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

    /// Speckled asphalt with hairline cracks, tiled along the road.
    static func asphalt() -> UIImage {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            UIColor(red: 0.20, green: 0.22, blue: 0.24, alpha: 1).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<5200 {
                let v = CGFloat.random(in: 0.16...0.34)
                UIColor(red: v, green: v + 0.015, blue: v + 0.035,
                        alpha: .random(in: 0.25...0.75)).setFill()
                g.fill(CGRect(x: .random(in: 0...255), y: .random(in: 0...255),
                              width: 1.6, height: 1.6))
            }
            g.setStrokeColor(UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 0.5).cgColor)
            g.setLineWidth(1)
            for _ in 0..<7 {
                var cx = CGFloat.random(in: 0...255), cy = CGFloat.random(in: 0...255)
                g.move(to: CGPoint(x: cx, y: cy))
                for _ in 0..<5 {
                    cx += .random(in: -23...23); cy += .random(in: 0...30)
                    g.addLine(to: CGPoint(x: cx, y: cy))
                }
                g.strokePath()
            }
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
