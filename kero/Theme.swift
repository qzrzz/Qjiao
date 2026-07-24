//
//  Theme.swift
//  kero
//

import AppKit
import Combine
import GhosttyTheme
import os

/// The user's light/dark preference. Applied by overriding `NSApp.appearance`,
/// which drives windows that follow the global project setting. A project can
/// override its own window appearance without changing this app-wide value.
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

/// 项目级主题选择。项目可以继承全局设置，也可以固定使用一个暗色或
/// 亮色 Ghostty 主题；主题名称由 GhosttyTheme 产品目录提供。
enum ProjectTheme: Equatable, Codable {
    case global
    case dark(name: String)
    case light(name: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    private enum Kind: String, Codable {
        case global
        case dark
        case light
    }

    init(from decoder: any Decoder) throws {
        // Accept the short-lived mode-only representation used before
        // project themes gained their nested catalog menus.
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            switch legacy {
            case "global": self = .global
            case "dark": self = .dark(name: Theme.defaultDarkThemeName)
            case "light": self = .light(name: Theme.defaultLightThemeName)
            default: throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown project theme: \(legacy)"
            )
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .global:
            self = .global
        case .dark:
            self = .dark(name: try container.decode(String.self, forKey: .name))
        case .light:
            self = .light(name: try container.decode(String.self, forKey: .name))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(Kind.global, forKey: .kind)
        case .dark(let name):
            try container.encode(Kind.dark, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .light(let name):
            try container.encode(Kind.light, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .global: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }

    var themeName: String? {
        switch self {
        case .global: return nil
        case .dark(let name), .light(let name): return name
        }
    }

    var isDark: Bool? {
        switch self {
        case .global: return nil
        case .dark: return true
        case .light: return false
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
/// The `NSColor` properties adapt to the active window appearance; terminal
/// sessions use `terminal(dark:)` and re-apply when appearance changes.
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
    /// The active project's explicit theme names. nil means that the window
    /// should resolve colors from the global light/dark selections.
    private static let projectSelection = OSAllocatedUnfairLock(
        initialState: (light: nil as String?, dark: nil as String?)
    )

    nonisolated static func definition(named name: String) -> GhosttyThemeDefinition? {
        if name == defaultLightThemeName { return defaultLight }
        if name == defaultDarkThemeName { return defaultDark }
        return GhosttyThemeCatalog.theme(named: name)
    }

    /// 返回全局亮/暗主题定义；项目主题预览需要同时展示这两个选择。
    @MainActor static func globalDefinition(dark: Bool) -> GhosttyThemeDefinition {
        selection.withLock { dark ? $0.dark : $0.light }
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

    /// Applies the selected project's theme names to the active window. The
    /// window appearance still controls whether the light or dark definition
    /// is requested; this override only replaces that definition's name.
    @MainActor
    static func reloadProjectSelection(_ projectTheme: ProjectTheme?) {
        let resolved: (light: String?, dark: String?)
        switch projectTheme {
        case .dark(let name): resolved = (light: nil, dark: name)
        case .light(let name): resolved = (light: name, dark: nil)
        default: resolved = (light: nil, dark: nil)
        }
        projectSelection.withLock { $0 = resolved }
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
        let theme = resolvedDefinition(dark: dark)
        return theme.name == (dark ? defaultDarkThemeName : defaultLightThemeName)
    }

    static func sidebarFill(dark: Bool) -> NSColor {
        let theme = resolvedDefinition(dark: dark)
        return theme.sidebarNSColor
    }

    /// Resolves the global theme pair without an active project override;
    /// Settings previews use this so they show what the pickers control.
    static func globalTerminal(dark: Bool) -> KeroTerminalTheme {
        let theme = selection.withLock { dark ? $0.dark : $0.light }
        return KeroTerminalTheme(
            background: theme.backgroundNSColor,
            foreground: theme.foregroundNSColor,
            cursor: theme.cursorNSColor,
            ansi: theme.paletteValues
        )
    }

    static func globalSidebarFill(dark: Bool) -> NSColor {
        let theme = selection.withLock { dark ? $0.dark : $0.light }
        return theme.sidebarNSColor
    }

    static func terminal(dark: Bool) -> KeroTerminalTheme {
        let theme = resolvedDefinition(dark: dark)
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
            return resolve(resolvedDefinition(dark: dark))
        }
    }

    private static func resolvedDefinition(dark: Bool) -> GhosttyThemeDefinition {
        let global = selection.withLock { dark ? $0.dark : $0.light }
        let projectName = projectSelection.withLock { dark ? $0.dark : $0.light }
        guard let projectName, let project = definition(named: projectName) else {
            return global
        }
        return project
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

/// 主题菜单中的精选分组；完整目录仍通过“全部…”入口保留。
enum ThemeMenuCatalog {
    static let lightPrimary = [
        Theme.defaultLightThemeName,
        "Adwaita",
        "Apple System Colors Light",
        "Atom One Light",
        "GitHub",
        "Ayu Light",
        "Cursor Light",
        "GitLab Light"
    ]
    static let lightCool = [
        "Monospace Light",
        "Neobones Light",
        "Nord Light"
    ]
    static let lightWarm = [
        "Dayfox",
        "Dawnfox",
        "Gruvbox Light Hard",
        "Monokai Pro Light Sun",
        "Violet Light"
    ]

    static let darkPrimary = [
        Theme.defaultDarkThemeName,
        "Atom",
        "Atom One Dark",
        "One Dark Two",
        "One Half Dark",
        "Adventure",
        "GitLab Dark",
        "Ghostty Default Style Dark",
        "GitHub Dark",
        "12-bit Rainbow",
        "0x96f",
        "Afterglow",
        "Apple System Colors",
        "Argonaut"
    ]
    static let darkCool = [
        "Aardvark Blue",
        "Adventure Time",
        "Alien Blood",
        "Aura",
        "Atelier Sulphurpool",
        "Black Metal (Burzum)",
        "Pandora"
    ]
    static let darkWarm = [
        "3024 Night",
        "Belafonte Night",
        "branch"
    ]

    static func primary(dark: Bool) -> [String] {
        dark ? darkPrimary : lightPrimary
    }

    static func cool(dark: Bool) -> [String] {
        dark ? darkCool : lightCool
    }

    static func warm(dark: Bool) -> [String] {
        dark ? darkWarm : lightWarm
    }

    static func all(dark: Bool) -> [String] {
        let defaultName = dark ? Theme.defaultDarkThemeName : Theme.defaultLightThemeName
        return [defaultName]
            + GhosttyThemeCatalog.allThemes.filter { $0.isDark == dark }.map(\.name)
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

@MainActor
enum ThemePreviewImageRenderer {
    static func image(for themes: [GhosttyThemeDefinition]) -> NSImage {
        let imageSize = NSSize(width: 32, height: 18)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let context = NSGraphicsContext.current?.cgContext
        context?.setShouldAntialias(true)
        let gap: CGFloat = themes.count > 1 ? 1 : 0
        let swatchWidth = (imageSize.width - gap * CGFloat(max(themes.count - 1, 0)))
            / CGFloat(max(themes.count, 1))

        for (index, theme) in themes.enumerated() {
            let rect = NSRect(
                x: CGFloat(index) * (swatchWidth + gap), y: 0,
                width: swatchWidth, height: imageSize.height
            )
            draw(theme: theme, in: rect)
        }

        return image
    }

    private static func draw(theme: GhosttyThemeDefinition, in rect: NSRect) {
        let background = NSBezierPath(
            roundedRect: rect, xRadius: 3, yRadius: 3
        )
        theme.backgroundNSColor.setFill()
        background.fill()

        let lineX = rect.minX + 3
        let lineWidth = rect.width - 6
        drawLine(
            color: theme.foregroundNSColor,
            rect: NSRect(x: lineX, y: rect.minY + 11, width: lineWidth * 0.68, height: 2)
        )
        drawLine(
            color: theme.foregroundNSColor.withAlphaComponent(0.65),
            rect: NSRect(x: lineX, y: rect.minY + 7, width: lineWidth * 0.48, height: 2)
        )
        // Qjiao 的激活图标与文件夹均使用 Theme.cursor，即此主题的 accentNSColor。
        drawLine(
            color: theme.accentNSColor,
            rect: NSRect(x: lineX, y: rect.minY + 3, width: lineWidth * 0.82, height: 3)
        )
    }

    private static func drawLine(color: NSColor, rect: NSRect) {
        color.setFill()
        NSBezierPath(
            roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2
        ).fill()
    }
}
