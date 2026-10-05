import NoteEngine
import SwiftUI
import UIKit

/// The app's color themes. Each has light and dark palettes and a matching app icon.
///
/// Keep the cases in sync with `THEMES` in Scripts/render_icon.py and the alternate
/// icon names in project.yml.
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case iris, graphite, ocean, sage, lagoon, ember, cherry, rose, honey, plum, indigo, sepia

    static let `default` = AppTheme.iris

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    /// Alternate icon name; nil selects the primary icon.
    var iconName: String? { self == .default ? nil : "AppIcon-\(name)" }
    var previewImage: String { "IconPreview-\(name)" }

    /// Semantic colors for one appearance.
    struct Palette {
        var accent: String
        var secondaryAccent: String
        var groupedBackground: String
        var elevatedSurface: String
        var canvasBackdrop: String
    }

    var light: Palette {
        switch self {
        case .iris: return Palette(accent: "#6A45E0", secondaryAccent: "#C2477E", groupedBackground: "#EDECF6", elevatedSurface: "#FFFFFF", canvasBackdrop: "#DFDDEA")
        case .graphite: return Palette(accent: "#3A3A3C", secondaryAccent: "#6E6E73", groupedBackground: "#ECECF0", elevatedSurface: "#FFFFFF", canvasBackdrop: "#DCDCE1")
        case .ocean: return Palette(accent: "#0A62C9", secondaryAccent: "#00808A", groupedBackground: "#EAEDF5", elevatedSurface: "#FFFFFF", canvasBackdrop: "#DADEE8")
        case .sage: return Palette(accent: "#2E7650", secondaryAccent: "#5F7226", groupedBackground: "#EBEEF1", elevatedSurface: "#FFFFFF", canvasBackdrop: "#DCDFE2")
        case .lagoon: return Palette(accent: "#00747F", secondaryAccent: "#2D63B5", groupedBackground: "#EAEEF3", elevatedSurface: "#FFFFFF", canvasBackdrop: "#DADFE5")
        case .ember: return Palette(accent: "#B8471A", secondaryAccent: "#9A5B00", groupedBackground: "#F0ECEF", elevatedSurface: "#FFFFFF", canvasBackdrop: "#E3DDE0")
        case .cherry: return Palette(accent: "#BE1E3D", secondaryAccent: "#8F3A6E", groupedBackground: "#F0EBF0", elevatedSurface: "#FFFFFF", canvasBackdrop: "#E3DBE1")
        case .rose: return Palette(accent: "#B5336D", secondaryAccent: "#7A4FC2", groupedBackground: "#F0EBF2", elevatedSurface: "#FFFFFF", canvasBackdrop: "#E3DCE4")
        case .honey: return Palette(accent: "#8C5A00", secondaryAccent: "#B5471E", groupedBackground: "#EEEDEE", elevatedSurface: "#FFFFFF", canvasBackdrop: "#E1DEDE")
        case .plum: return Palette(accent: "#7E3A9C", secondaryAccent: "#B5336D", groupedBackground: "#EEECF4", elevatedSurface: "#FFFFFF", canvasBackdrop: "#E0DCE6")
        case .indigo: return Palette(accent: "#3D4DB7", secondaryAccent: "#00747F", groupedBackground: "#ECECF5", elevatedSurface: "#FFFFFF", canvasBackdrop: "#DDDDE7")
        case .sepia: return Palette(accent: "#7F5537", secondaryAccent: "#4F6B4A", groupedBackground: "#EEEDF0", elevatedSurface: "#FFFFFF", canvasBackdrop: "#E0DEE1")
        }
    }

    var dark: Palette {
        switch self {
        case .iris: return Palette(accent: "#A08BFF", secondaryAccent: "#F28AB5", groupedBackground: "#060509", elevatedSurface: "#232229", canvasBackdrop: "#13121A")
        case .graphite: return Palette(accent: "#D1D1D6", secondaryAccent: "#98989D", groupedBackground: "#070707", elevatedSurface: "#252527", canvasBackdrop: "#161618")
        case .ocean: return Palette(accent: "#5AA9FF", secondaryAccent: "#4FD1D9", groupedBackground: "#030609", elevatedSurface: "#1F2329", canvasBackdrop: "#10141A")
        case .sage: return Palette(accent: "#6CCB98", secondaryAccent: "#B5CC6A", groupedBackground: "#040705", elevatedSurface: "#202524", canvasBackdrop: "#111615")
        case .lagoon: return Palette(accent: "#4FCFD6", secondaryAccent: "#7FAEFF", groupedBackground: "#030707", elevatedSurface: "#1F2527", canvasBackdrop: "#0F1618")
        case .ember: return Palette(accent: "#FF9466", secondaryAccent: "#F5B54A", groupedBackground: "#090504", elevatedSurface: "#272222", canvasBackdrop: "#181312")
        case .cherry: return Palette(accent: "#FF6F87", secondaryAccent: "#E58ABF", groupedBackground: "#090405", elevatedSurface: "#272023", canvasBackdrop: "#181114")
        case .rose: return Palette(accent: "#F584B4", secondaryAccent: "#B79BFF", groupedBackground: "#090506", elevatedSurface: "#272126", canvasBackdrop: "#181216")
        case .honey: return Palette(accent: "#F2B53A", secondaryAccent: "#FF9A6B", groupedBackground: "#080602", elevatedSurface: "#27241F", canvasBackdrop: "#181410")
        case .plum: return Palette(accent: "#D08BF0", secondaryAccent: "#F584B4", groupedBackground: "#070508", elevatedSurface: "#252228", canvasBackdrop: "#161219")
        case .indigo: return Palette(accent: "#8D9BFF", secondaryAccent: "#4FCFD6", groupedBackground: "#050509", elevatedSurface: "#222229", canvasBackdrop: "#12131A")
        case .sepia: return Palette(accent: "#D7A982", secondaryAccent: "#A3C29A", groupedBackground: "#080605", elevatedSurface: "#252323", canvasBackdrop: "#161414")
        }
    }

    // MARK: Dynamic colors

    private func dynamic(_ key: KeyPath<Palette, String>) -> Color {
        Color(UIColor { traits in
            let palette = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(Color(hex: palette[keyPath: key]))
        })
    }

    /// Tint for controls, links, and selection.
    var accent: Color { dynamic(\.accent) }
    /// A second hue for highlights that should not read as "selected".
    var secondaryAccent: Color { dynamic(\.secondaryAccent) }
    /// Behind grouped lists and forms; close to the system grouped background.
    var groupedBackground: Color { dynamic(\.groupedBackground) }
    /// Cards and rows on top of the grouped background.
    var elevatedSurface: Color { dynamic(\.elevatedSurface) }
    /// Behind pages in the editor.
    var canvasBackdrop: Color { dynamic(\.canvasBackdrop) }

    /// Label color on a prominent accent fill. Dark-mode accents are light, so labels go dark.
    var onAccent: Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: "#0B0B0F")) : .white })
    }

    /// The light accent as a plain hex, for new notes and folders.
    var accentHex: String { light.accent }

    /// A curated set of colors for folders and notebooks that sits well with every theme.
    static let itemColors = ["#6A45E0", "#3D4DB7", "#0A62C9", "#00747F", "#2E7650", "#8C5A00", "#B8471A", "#BE1E3D", "#B5336D", "#7E3A9C", "#7F5537", "#3A3A3C"]

    // MARK: Persistence

    static let storageKey = "theme"
    static let matchIconKey = "matchAppIcon"

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .default
    }

    /// Switches the app icon to this theme's, if the user wants icons to follow the theme.
    /// iOS shows its own confirmation alert, so callers should do this once, not per swatch.
    @MainActor
    func applyIconIfNeeded(completion: @escaping (Error?) -> Void = { _ in }) {
        guard UIApplication.shared.supportsAlternateIcons,
              UserDefaults.standard.object(forKey: Self.matchIconKey) as? Bool ?? true,
              UIApplication.shared.alternateIconName != iconName else { return completion(nil) }
        UIApplication.shared.setAlternateIconName(iconName, completionHandler: completion)
    }
}

/// System, light, or dark, from Settings › Appearance.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension EnvironmentValues {
    @Entry var theme: AppTheme = .default
}

/// Corner radii used across the app, so nested shapes stay concentric.
enum Radius {
    static let thumb: CGFloat = 6
    static let tile: CGFloat = 10
    static let card: CGFloat = 14
    static let panel: CGFloat = 20
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

extension Date {
    /// Notes-style dates: a time today, "Yesterday", the weekday this week, then a short date.
    var libraryDescription: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: Date()), self > week {
            return formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(self, equalTo: Date(), toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(date: .numeric, time: .omitted)
    }
}
