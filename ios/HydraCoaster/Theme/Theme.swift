import SwiftUI

/// The app's single accent — a deep water blue-teal, tuned separately per
/// color scheme so it reads as intentional rather than "dark mode inverted."
/// Lives here (not under Today/, where it started) because the widget
/// extension needs it too (see `Theme.aqua` below) — it uses UIKit only
/// for `UIColor` trait resolution, which is linkable from widget
/// extensions, so it compiles unchanged in both targets.
extension Color {
    static let hydraAccent = Color(
        light: Color(hue: 0.53, saturation: 0.72, brightness: 0.60),
        dark: Color(hue: 0.52, saturation: 0.55, brightness: 0.80)
    )

    static let hydraAccentSoft = Color(
        light: Color(hue: 0.53, saturation: 0.30, brightness: 0.96),
        dark: Color(hue: 0.52, saturation: 0.35, brightness: 0.20)
    )

    /// Resolves to `light` or `dark` based on the active trait collection —
    /// a plain Swift alternative to an asset-catalog color set.
    init(light: Color, dark: Color) {
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// Selectable color theme (V2-T6). `aqua` is the original, one-and-only
/// look the app shipped with — it MUST stay pixel-identical to
/// `Color.hydraAccent` for existing users, so it's raw value 0 and both
/// `AppSettings.theme`'s stored default and `\.hydraTheme`'s environment
/// default. Picking any other case is purely additive.
enum Theme: Int, CaseIterable, Codable {
    case aqua = 0
    case sunset = 1
    case forest = 2
    case mono = 3

    var name: String {
        switch self {
        case .aqua: "Aqua"
        case .sunset: "Sunset"
        case .forest: "Forest"
        case .mono: "Mono"
        }
    }

    var accent: Color {
        switch self {
        case .aqua:
            .hydraAccent
        case .sunset:
            Color(
                light: Color(hue: 0.05, saturation: 0.80, brightness: 0.90),
                dark: Color(hue: 0.06, saturation: 0.72, brightness: 0.92)
            )
        case .forest:
            Color(
                light: Color(hue: 0.33, saturation: 0.62, brightness: 0.52),
                dark: Color(hue: 0.32, saturation: 0.50, brightness: 0.70)
            )
        case .mono:
            Color(
                light: Color(hue: 0, saturation: 0, brightness: 0.22),
                dark: Color(hue: 0, saturation: 0, brightness: 0.85)
            )
        }
    }
}

/// Appearance override (V2-T6): `system` (default) tracks the device;
/// `light`/`dark` force `.preferredColorScheme`.
enum Appearance: Int, CaseIterable, Codable {
    case system = 0
    case light = 1
    case dark = 2

    var name: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct HydraThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .aqua
}

extension EnvironmentValues {
    /// The active color theme, applied at the root (`RootView`) from
    /// `AppSettings.theme` — views read `theme.accent` instead of
    /// `Color.hydraAccent` directly so switching themes recolors live.
    var hydraTheme: Theme {
        get { self[HydraThemeKey.self] }
        set { self[HydraThemeKey.self] = newValue }
    }
}
