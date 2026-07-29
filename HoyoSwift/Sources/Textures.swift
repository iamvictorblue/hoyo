import UIKit

/// Every texture is generated at launch — no image assets in the bundle.
enum Textures {

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
