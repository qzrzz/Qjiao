//
//  Theme.swift
//  kero
//

import AppKit
import Combine
import GhosttyTheme
import os

/// The user's light/dark preference. Applied by overriding `NSApp.appearance`,
/// which drives every window, the dynamic colors below, and — through
/// `NSApp.effectiveAppearance` — the terminal theme.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` hands the appearance back to macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Colors a terminal session needs, resolved for one appearance.
struct KeroTerminalTheme {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    /// The 16 ANSI colors (normal, then bright) as `RRGGBB` strings.
    let ansi: [String]
}

/// App theme, loosely based on GitHub Dark / GitHub Light.
/// The `NSColor` properties are dynamic and adapt to the system appearance;
/// terminal sessions use `terminal(dark:)` and re-apply on appearance change.
final class ThemeChanges: nonisolated ObservableObject {}

/// Resolves Ghostty themes into terminal and native-window colors.
enum Theme {
    static let defaultDarkThemeName = "Default Dark"
    static let defaultLightThemeName = "Default Light"
    @MainActor static let changes = ThemeChanges()

    private static let defaultDark = makeDefault(
        name: defaultDarkThemeName, source: "GitHub Dark Default", dark: true
    )
    private static let defaultLight = makeDefault(
        name: defaultLightThemeName, source: "GitHub Light Default", dark: false
    )
    private static let selection = OSAllocatedUnfairLock(
        initialState: (light: defaultLight, dark: defaultDark)
    )

    nonisolated static func definition(named name: String) -> GhosttyThemeDefinition? {
        if name == defaultLightThemeName { return defaultLight }
        if name == defaultDarkThemeName { return defaultDark }
        return GhosttyThemeCatalog.theme(named: name)
    }

    @MainActor
    static func reloadSelection(light: String, dark: String) {
        let resolved = (
            light: definition(named: light) ?? defaultLight,
            dark: definition(named: dark) ?? defaultDark
        )
        selection.withLock { $0 = resolved }
        changes.objectWillChange.send()
    }

    static var background: NSColor { dynamic { $0.backgroundNSColor } }
    static var sidebar: NSColor { dynamic { $0.sidebarNSColor } }
    static var cursor: NSColor { dynamic { $0.accentNSColor } }
    static var accent: NSColor { cursor }
    static var divider: NSColor {
        dynamic { theme in
            theme.name == defaultDarkThemeName || theme.name == defaultLightThemeName
                ? NSColor.labelColor.withAlphaComponent(0.06)
                : theme.surfaceNSColor(elevation: 0.08)
        }
    }

    static func isDefault(dark: Bool) -> Bool {
        let theme = selection.withLock { dark ? $0.dark : $0.light }
        return theme.name == (dark ? defaultDarkThemeName : defaultLightThemeName)
    }

    static func sidebarFill(dark: Bool) -> NSColor {
        let theme = selection.withLock { dark ? $0.dark : $0.light }
        return theme.sidebarNSColor
    }

    static func terminal(dark: Bool) -> KeroTerminalTheme {
        let theme = selection.withLock { dark ? $0.dark : $0.light }
        return KeroTerminalTheme(
            background: theme.backgroundNSColor,
            foreground: theme.foregroundNSColor,
            cursor: theme.cursorNSColor,
            ansi: theme.paletteValues
        )
    }

    static func hex(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    private static func dynamic(
        _ resolve: @escaping @Sendable (GhosttyThemeDefinition) -> NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let theme = selection.withLock { dark ? $0.dark : $0.light }
            return resolve(theme)
        }
    }

    private static func makeDefault(
        name: String, source: String, dark: Bool
    ) -> GhosttyThemeDefinition {
        guard let base = GhosttyThemeCatalog.theme(named: source) else {
            return GhosttyThemeDefinition(
                name: name,
                background: dark ? "0d1117" : "ffffff",
                foreground: dark ? "e6edf3" : "1f2328"
            )
        }
        return GhosttyThemeDefinition(
            name: name,
            background: base.background,
            foreground: base.foreground,
            cursorColor: base.cursorColor,
            cursorText: base.cursorText,
            selectionBackground: base.selectionBackground,
            selectionForeground: base.selectionForeground,
            palette: base.palette
        )
    }

}

nonisolated extension GhosttyThemeDefinition {
    var backgroundNSColor: NSColor { Self.nsColor(background) }
    var foregroundNSColor: NSColor { Self.nsColor(foreground) }
    var cursorNSColor: NSColor {
        cursorColor.map(Self.nsColor) ?? accentNSColor
    }
    var accentNSColor: NSColor {
        (palette[4] ?? cursorColor).map(Self.nsColor) ?? foregroundNSColor
    }
    var sidebarNSColor: NSColor {
        if name == Theme.defaultDarkThemeName { return Self.nsColor("010409") }
        if name == Theme.defaultLightThemeName { return Self.nsColor("f6f8fa") }
        return backgroundNSColor
    }
    func surfaceNSColor(elevation: CGFloat) -> NSColor {
        backgroundNSColor.blended(withFraction: elevation, of: foregroundNSColor)
            ?? backgroundNSColor
    }
    var paletteValues: [String] {
        (0..<16).map { index in palette[index] ?? (index < 8 ? "808080" : "c0c0c0") }
    }
    private static func nsColor(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return .magenta }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
