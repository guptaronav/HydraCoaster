import SwiftUI

/// The app's single accent — a deep water blue-teal, tuned separately per
/// color scheme so it reads as intentional rather than "dark mode inverted."
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
