import AppKit
import SwiftUI

// Ports src/electron/public/styles.css's custom properties. Its header
// comment carries the app's whole design thesis, so it's worth repeating
// here verbatim:
//
//   sbx-helper — colour carries permission and nothing else.
//   Deep amber = the agent can write here. Steel blue = read-only.
//   Everything path-shaped is monospace, because paths are this app's content.
//
// `actool` is absent from this toolchain (no Xcode, no asset catalog), so
// every color is defined in Swift as a dynamic `NSColor` that resolves
// against the current appearance, rather than a catalog color set.
enum Theme {
    // MARK: - Colors (light / dark from styles.css :root and its
    // prefers-color-scheme: dark override)

    static let paper = dynamic(light: 0xFBFBFA, dark: 0x17191C)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1E2124)
    static let ink = dynamic(light: 0x1C2024, dark: 0xEDEEF0)
    static let muted = dynamic(light: 0x6B7280, dark: 0x9AA1A9)
    static let hairline = dynamic(light: 0xDFE1E4, dark: 0x2C3034)
    static let hairlineStrong = dynamic(light: 0xC7CBD1, dark: 0x3A3F44)

    // Deep amber — the agent can write here.
    static let write = dynamic(light: 0x9A5B00, dark: 0xE3A64C)
    static let writeBg = dynamic(light: 0xFBF0DE, dark: 0x332510)
    static let writeStrong = dynamic(light: 0x7A4700, dark: 0xF0BC72)

    // Steel blue — read-only.
    static let read = dynamic(light: 0x3B6E8F, dark: 0x7FB2D6)
    static let readBg = dynamic(light: 0xE8F1F6, dark: 0x142330)
    static let readStrong = dynamic(light: 0x2C5570, dark: 0x9EC6E3)

    static let danger = dynamic(light: 0xB4432F, dark: 0xE28372)
    static let focus = dynamic(light: 0x3B6E8F, dark: 0x7FB2D6)

    // MARK: - Metrics (styles.css)

    static let radius: CGFloat = 4
    static let badgeRadius: CGFloat = 3

    /// Row indent — `app.js:222`: `8 + depth * 16`px.
    static let indentBase: CGFloat = 8
    static let indentPerLevel: CGFloat = 16
    static let disclosureWidth: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 3

    /// Everything path-shaped is monospace, because paths are this app's
    /// content — the design thesis above, made literal.
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    // MARK: - Dynamic color construction

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
