import CoreGraphics
import Foundation

/// Parses the color strings used throughout packs and documents.
///
/// Accepted forms:
/// - Hex: `#RGB`, `#RRGGBB`, `#RRGGBBAA`
/// - Tokens: `accent`, `accentLight`, `accentDark`, `paper`, `ink`, `white`, `black`, `clear`
/// - Any of the above with an opacity suffix: `accent@0.25`, `#000000@0.1`
public enum ColorSpec {
    public struct Palette: Sendable {
        public var accent: CGColor
        public var paper: CGColor
        public var ink: CGColor

        public init(accent: CGColor, paper: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), ink: CGColor = CGColor(srgbRed: 0.11, green: 0.106, blue: 0.18, alpha: 1)) {
            self.accent = accent
            self.paper = paper
            self.ink = ink
        }

        public static let standard = Palette(accent: ColorSpec.hex("#F76CA0")!)
    }

    public static func color(_ spec: String?, palette: Palette) -> CGColor? {
        guard var spec = spec?.trimmingCharacters(in: .whitespaces), !spec.isEmpty else { return nil }
        var alpha: CGFloat?
        if let at = spec.lastIndex(of: "@") {
            alpha = Double(spec[spec.index(after: at)...]).map { CGFloat($0) }
            spec = String(spec[..<at])
        }
        let base: CGColor?
        switch spec {
        case "accent": base = palette.accent
        case "accentLight": base = mix(palette.accent, with: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), amount: 0.65)
        case "accentDark": base = mix(palette.accent, with: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), amount: 0.35)
        case "paper": base = palette.paper
        case "ink": base = palette.ink
        case "white": base = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case "black": base = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case "clear": base = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        default: base = hex(spec)
        }
        guard let base else { return nil }
        if let alpha { return base.copy(alpha: base.alpha * alpha) }
        return base
    }

    public static func hex(_ string: String) -> CGColor? {
        guard let rgba = components(string) else { return nil }
        return CGColor(srgbRed: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
    }

    public static func components(_ string: String) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        var s = string.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return (r, g, b, a)
    }

    public static func hexString(r: CGFloat, g: CGFloat, b: CGFloat) -> String {
        func clamp(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    public static func mix(_ a: CGColor, with b: CGColor, amount: CGFloat) -> CGColor {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ca = a.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        let cb = b.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        func at(_ c: [CGFloat], _ i: Int) -> CGFloat { i < c.count ? c[i] : (c.count == 2 ? c[0] : 1) }
        return CGColor(
            srgbRed: at(ca, 0) + (at(cb, 0) - at(ca, 0)) * amount,
            green: at(ca, 1) + (at(cb, 1) - at(ca, 1)) * amount,
            blue: at(ca, 2) + (at(cb, 2) - at(ca, 2)) * amount,
            alpha: at(ca, 3)
        )
    }

    /// Relative luminance, used to pick legible text over a color.
    public static func luminance(_ color: CGColor) -> CGFloat {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let c = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        guard c.count >= 3 else { return c.first ?? 0 }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }
}
