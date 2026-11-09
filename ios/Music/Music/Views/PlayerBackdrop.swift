// 用途：从歌曲封面提取主色，生成播放页的渐变底色；只取颜色，不展示封面。
import SwiftUI
import UIKit

struct ArtworkPalette {
    let primary: UIColor
    let secondary: UIColor

    static let fallback = ArtworkPalette(
        primary: UIColor(red: 0.25, green: 0.33, blue: 0.58, alpha: 1),
        secondary: UIColor(red: 0.55, green: 0.28, blue: 0.45, alpha: 1)
    )

    static func from(_ image: UIImage?) -> ArtworkPalette {
        guard let image, let cgImage = image.cgImage else { return .fallback }

        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return .fallback }
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return .fallback }

        var buckets: [Int: Bucket] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.5 else { continue }

            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let color = UIColor(red: red, green: green, blue: blue, alpha: 1)

            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var colorAlpha: CGFloat = 0
            guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &colorAlpha) else { continue }
            guard saturation > 0.06, brightness > 0.10 else { continue }
            guard brightness < 0.97 || saturation > 0.12 else { continue }

            let key = (min(11, Int(hue * 12)) << 6)
                | (min(7, Int(saturation * 8)) << 3)
                | min(7, Int(brightness * 8))
            let weight = 0.25 + Double(saturation) * 2.2 + Double(brightness) * 0.35
            buckets[key, default: Bucket()].add(red: red, green: green, blue: blue, weight: weight)
        }

        let candidates = buckets.values.compactMap { bucket -> Candidate? in
            guard bucket.weight > 0 else { return nil }
            let color = bucket.color
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return nil }
            let score = bucket.weight * (0.5 + Double(saturation) * 1.8 + Double(brightness) * 0.5)
            return Candidate(color: color, score: score, hue: hue, brightness: brightness)
        }.sorted { $0.score > $1.score }

        guard let primary = candidates.first else { return .fallback }
        let secondary = candidates.dropFirst().first { candidate in
            let gap = abs(candidate.hue - primary.hue)
            return min(gap, 1 - gap) > 0.08 && abs(candidate.brightness - primary.brightness) > 0.04
        }?.color ?? Self.shifted(primary.color)
        return ArtworkPalette(primary: primary.color, secondary: secondary)
    }

    func backgroundColors(for scheme: ColorScheme) -> (primary: Color, secondary: Color) {
        let dark = scheme == .dark
        return (
            display(primary, dark: dark, brightness: dark ? 0.30 : 0.95),
            display(secondary, dark: dark, brightness: dark ? 0.18 : 0.90)
        )
    }

    private struct Bucket {
        var weight = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0

        mutating func add(red: Double, green: Double, blue: Double, weight: Double) {
            self.weight += weight
            self.red += red * weight
            self.green += green * weight
            self.blue += blue * weight
        }

        var color: UIColor {
            UIColor(red: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        }
    }

    private struct Candidate {
        let color: UIColor
        let score: Double
        let hue: CGFloat
        let brightness: CGFloat
    }

    private static func shifted(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha), saturation > 0.02 else {
            return color
        }
        return UIColor(
            hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
            saturation: min(1, max(0.45, saturation)),
            brightness: max(0.35, brightness * 0.75),
            alpha: 1
        )
    }

    private func display(_ color: UIColor, dark: Bool, brightness: CGFloat) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var currentBrightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &currentBrightness, alpha: &alpha), saturation > 0.02 else {
            return Color(color)
        }
        let range: ClosedRange<CGFloat> = dark ? 0.35...0.72 : 0.20...0.50
        return Color(
            hue: Double(hue),
            saturation: Double(min(range.upperBound, max(range.lowerBound, saturation))),
            brightness: Double(brightness)
        )
    }
}

struct PlayerBackdrop: View {
    let palette: ArtworkPalette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = palette.backgroundColors(for: colorScheme)
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                stops: [
                    .init(color: colors.primary, location: 0),
                    .init(color: Color(.systemBackground).opacity(0.94), location: 0.48),
                    .init(color: colors.secondary, location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.34),
                    .clear,
                ],
                center: .top,
                startRadius: 0,
                endRadius: 430
            )
        }
        .ignoresSafeArea()
    }
}
