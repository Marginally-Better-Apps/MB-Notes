import NoteEngine
import SwiftUI
import UIKit

/// The brand palette, taken from the app icon so the app feels like the icon you tapped.
enum Brand {
    static let peach = Color(hex: "#FFA678")
    static let pink = Color(hex: "#F76CA0")
    static let violet = Color(hex: "#8056F6")
    static let ink = Color(hex: "#4C3AD6")
    static let star = Color(hex: "#FFC428")
    static let night = Color(hex: "#1C1B2E")

    static let gradient = LinearGradient(colors: [peach, pink, violet], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Default accent for new notebooks and folders, cycling through the palette.
    static let accentHexes = ["#F76CA0", "#8056F6", "#FFA678", "#4C3AD6", "#2EB8A6", "#3E8EDE", "#FFB020", "#3FB37F"]
}

extension Color {
    init(hex: String) {
        let c = ColorSpec.components(hex) ?? (0.5, 0.5, 0.5, 1)
        self.init(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: c.3)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return ColorSpec.hexString(r: r, g: g, b: b)
    }
}

/// A soft, moving brand backdrop that glass surfaces float over.
struct BrandBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var intensity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let wobble = Float(sin(t / 6) * 0.08)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + wobble, 0.5 - wobble], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: scheme == .dark ? darkColors : lightColors
            )
            .opacity(intensity)
        }
        .ignoresSafeArea()
    }

    private var lightColors: [Color] {
        [Brand.peach.opacity(0.35), Brand.pink.opacity(0.22), Brand.violet.opacity(0.25),
         Color(hex: "#FFF6F0"), Color(hex: "#FFF7FB"), Brand.pink.opacity(0.15),
         Brand.violet.opacity(0.18), Color(hex: "#F7F3FF"), Brand.peach.opacity(0.2)]
    }

    private var darkColors: [Color] {
        [Color(hex: "#3A2448"), Color(hex: "#2B2350"), Color(hex: "#1C1B2E"),
         Color(hex: "#24203A"), Color(hex: "#1C1B2E"), Color(hex: "#2E2148"),
         Color(hex: "#1C1B2E"), Color(hex: "#2A1F3D"), Color(hex: "#1A1828")]
    }
}

/// Alternate app icons. Keep in sync with Scripts/render_icon.py and project.yml.
enum AppIconTheme: String, CaseIterable, Identifiable {
    case sunset, midnight, mint, ocean, lemonade, bubblegum, kraft, graphite

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// nil selects the primary icon.
    var iconName: String? { self == .sunset ? nil : "AppIcon-\(title)" }
    var previewImage: String { "IconPreview-\(title)" }

    static var current: AppIconTheme {
        guard let name = UIApplication.shared.alternateIconName else { return .sunset }
        return allCases.first { $0.iconName == name } ?? .sunset
    }
}
