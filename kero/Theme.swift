//
//  Theme.swift
//  kero
//

import AppKit
import Combine
import GhosttyTheme
import os
import SwiftUI

/// The user's light/dark preference. Applied by overriding `NSApp.appearance`,
/// which drives every window's chrome and which side of the light/dark color
/// pair is active. Project themes only override the *colors* for each side.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.t("System")
        case .light: return L10n.t("Light")
        case .dark: return L10n.t("Dark")
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

    /// SwiftUI 根视图用的 `preferredColorScheme`；`.system` 为 `nil` 跟随系统。
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 项目级配色覆盖：与全局 Settings 一样分 **Light / Dark** 两套，
/// 随当前外观环境切换；`nil` 表示该侧跟随全局 `theme-light` / `theme-dark`。
///
/// 不强制窗口亮暗——亮暗仍由 `AppTheme`（System / Light / Dark）决定。
struct ProjectTheme: Equatable, Codable {
    /// 亮色环境下的 Ghostty 主题名；`nil` = 跟随全局 Light colors。
    var light: String?
    /// 暗色环境下的 Ghostty 主题名；`nil` = 跟随全局 Dark colors。
    var dark: String?

    static let global = ProjectTheme(light: nil, dark: nil)

    /// 两侧都未覆盖时视为完全跟随全局。
    var followsGlobal: Bool { light == nil && dark == nil }

    func withLight(_ name: String?) -> ProjectTheme {
        ProjectTheme(light: name, dark: dark)
    }

    func withDark(_ name: String?) -> ProjectTheme {
        ProjectTheme(light: light, dark: name)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case light
        case dark
    }

    /// 旧版用 kind 表示「强制某一侧外观 + 单套主题」，读入时迁成对应侧覆盖。
    private enum LegacyKind: String, Codable {
        case global
        case dark
        case light
    }

    init(light: String? = nil, dark: String? = nil) {
        self.light = light
        self.dark = dark
    }

    init(from decoder: any Decoder) throws {
        // 极早期：纯字符串 "global" / "dark" / "light"
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            switch legacy {
            case "global":
                self = .global
            case "dark":
                self = ProjectTheme(light: nil, dark: Theme.defaultDarkThemeName)
            case "light":
                self = ProjectTheme(light: Theme.defaultLightThemeName, dark: nil)
            default:
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown project theme: \(legacy)"
                )
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 旧版：{ "kind": "dark"|"light"|"global", "name": "..." } — 只覆盖对应侧
        if let kind = try? container.decode(LegacyKind.self, forKey: .kind) {
            switch kind {
            case .global:
                self = .global
            case .dark:
                self = ProjectTheme(
                    light: nil,
                    dark: try container.decode(String.self, forKey: .name)
                )
            case .light:
                self = ProjectTheme(
                    light: try container.decode(String.self, forKey: .name),
                    dark: nil
                )
            }
            return
        }
        // 现行：{ "light": "...", "dark": "..." }，缺省键为跟随全局
        light = try container.decodeIfPresent(String.self, forKey: .light)
        dark = try container.decodeIfPresent(String.self, forKey: .dark)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if followsGlobal {
            try container.encode(LegacyKind.global, forKey: .kind)
            return
        }
        try container.encodeIfPresent(light, forKey: .light)
        try container.encodeIfPresent(dark, forKey: .dark)
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

/// 当前活动项目对全局 Light/Dark 配色的覆盖摘要（设置页提示用）。
struct ProjectThemeOverrideSummary: Equatable {
    /// 项目显示名；未知时为 nil。
    var projectName: String?
    /// 亮色侧覆盖主题名；nil = 跟随全局。
    var lightOverride: String?
    /// 暗色侧覆盖主题名；nil = 跟随全局。
    var darkOverride: String?

    var isActive: Bool { lightOverride != nil || darkOverride != nil }
}

/// App theme, loosely based on GitHub Dark / GitHub Light.
/// The `NSColor` properties adapt to the active window appearance; terminal
/// sessions use `terminal(dark:)` and re-apply when appearance changes.
final class ThemeChanges: nonisolated ObservableObject {}

/// 缓存中的自定义主题快照，供任意线程解析窗口 / 终端色。
private struct CustomThemeSnapshot: Sendable {
    let name: String
    let isDark: Bool
    let background: String
    let foreground: String
    let accent: String
    let ghosttyTheme: String
    let followBackground: Bool

    var windowDefinition: GhosttyThemeDefinition {
        GhosttyThemeDefinition(
            name: name,
            background: background,
            foreground: foreground,
            cursorColor: accent,
            cursorText: background,
            selectionBackground: accent,
            selectionForeground: foreground,
            palette: [4: accent]
        )
    }

    var sidebarNSColor: NSColor {
        let bg = GhosttyThemeDefinition.nsColorPublic(background)
        if isDark {
            return bg.blended(withFraction: 0.28, of: .black) ?? bg
        }
        let gray = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1)
        return bg.blended(withFraction: 0.55, of: gray) ?? bg
    }

    func surfaceNSColor(elevation: CGFloat) -> NSColor {
        let bg = GhosttyThemeDefinition.nsColorPublic(background)
        let fg = GhosttyThemeDefinition.nsColorPublic(foreground)
        return bg.blended(withFraction: elevation, of: fg) ?? bg
    }
}

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
    /// 当前活动项目的 light/dark 配色名覆盖；某一侧为 nil 时用全局 selection。
    private static let projectSelection = OSAllocatedUnfairLock(
        initialState: (light: nil as String?, dark: nil as String?)
    )
    /// 产生当前覆盖的项目显示名（无覆盖时为 nil）。
    private static let projectOverrideName = OSAllocatedUnfairLock(
        initialState: nil as String?
    )
    /// 原生窗口背景层的透明度；终端表面另由 Ghostty 配置控制。
    private static let windowBackgroundOpacity = OSAllocatedUnfairLock(initialState: 1.0)
    /// 自定义主题线程安全快照（name → snapshot）。
    private static let customSnapshots = OSAllocatedUnfairLock(
        initialState: [String: CustomThemeSnapshot]()
    )
    /// 全局 AppTheme 缓存：启动早期 / 非主线程解析 dark·light 时不依赖尚未就绪的 `NSApp.appearance`。
    private static let appThemePreference = OSAllocatedUnfairLock(initialState: AppTheme.system)

    /// 按名称解析主题：自定义主题优先（窗口合成定义），其次内置 Default，再 Ghostty 目录。
    nonisolated static func definition(named name: String) -> GhosttyThemeDefinition? {
        if let custom = customSnapshots.withLock({ $0[name] }) {
            return custom.windowDefinition
        }
        return builtinOrGhosttyDefinition(named: name)
    }

    /// 仅内置 Default + Ghostty 目录（不含用户自定义），供自定义主题绑定终端配色时使用。
    nonisolated static func builtinOrGhosttyDefinition(named name: String) -> GhosttyThemeDefinition? {
        if name == defaultLightThemeName { return defaultLight }
        if name == defaultDarkThemeName { return defaultDark }
        return GhosttyThemeCatalog.theme(named: name)
    }

    /// 从 CustomThemeStore 同步快照；App 启动与自定义主题增删改后调用。
    @MainActor
    static func reloadCustomThemes(_ themes: [CustomTheme]) {
        let map = Dictionary(uniqueKeysWithValues: themes.map { theme in
            (
                theme.name,
                CustomThemeSnapshot(
                    name: theme.name,
                    isDark: theme.isDark,
                    background: theme.background,
                    foreground: theme.foreground,
                    accent: theme.accent,
                    ghosttyTheme: theme.ghosttyTheme,
                    followBackground: theme.followBackground
                )
            )
        })
        customSnapshots.withLock { $0 = map }
    }

    /// 主线程解析自定义主题实体。
    @MainActor
    static func customTheme(named name: String) -> CustomTheme? {
        CustomThemeStore.shared.theme(named: name)
    }

    private nonisolated static func customSnapshot(named name: String) -> CustomThemeSnapshot? {
        customSnapshots.withLock { $0[name] }
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

    /// 套用当前活动项目的 light/dark 配色覆盖（不改变亮暗外观本身）。
    /// - Parameters:
    ///   - projectTheme: 项目配置；`nil` 或 `followsGlobal` 时清空覆盖。
    ///   - projectName: 用于设置页提示的项目显示名。
    @MainActor
    static func reloadProjectSelection(
        _ projectTheme: ProjectTheme?,
        projectName: String? = nil
    ) {
        let theme = projectTheme ?? .global
        projectSelection.withLock {
            $0 = (light: theme.light, dark: theme.dark)
        }
        projectOverrideName.withLock {
            $0 = theme.followsGlobal ? nil : projectName
        }
        changes.objectWillChange.send()
    }

    /// 当前是否存在项目级配色覆盖（供设置页提示）。
    @MainActor
    static var hasProjectThemeOverride: Bool {
        let sel = projectSelection.withLock { $0 }
        return sel.light != nil || sel.dark != nil
    }

    /// 设置页用的项目覆盖摘要；无覆盖时为 `nil`。
    @MainActor
    static var projectThemeOverrideSummary: ProjectThemeOverrideSummary? {
        let sel = projectSelection.withLock { $0 }
        guard sel.light != nil || sel.dark != nil else { return nil }
        let name = projectOverrideName.withLock { $0 }
        return ProjectThemeOverrideSummary(
            projectName: name,
            lightOverride: sel.light,
            darkOverride: sel.dark
        )
    }

    /// 写入全局亮暗偏好（与 `AppSettings.theme` 同步）；供任意线程的 `resolvedIsDark` 读取。
    static func setAppThemePreference(_ theme: AppTheme) {
        appThemePreference.withLock { $0 = theme }
    }

    /// 当前缓存的 AppTheme（system / light / dark）。
    static var appThemePreferenceValue: AppTheme {
        appThemePreference.withLock { $0 }
    }

    /// 解析给定 `NSAppearance` 是否为 dark 系（含 high-contrast / vibrant 变体）。
    static func isDarkAppearance(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 系统外观是否为 Dark（不读 `NSApp`，避免启动瞬间 effectiveAppearance 仍为默认 light）。
    /// `AppleInterfaceStyle == "Dark"` 表示深色；键缺失表示浅色。
    static func systemPrefersDark() -> Bool {
        guard let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") else {
            return false
        }
        return style.caseInsensitiveCompare("Dark") == .orderedSame
    }

    /// 解析「此刻应按 dark 还是 light 配色」。
    ///
    /// 优先级：
    /// 1. 用户强制 Light / Dark（`AppTheme`，不依赖启动时尚未就绪的 NSApp）
    /// 2. 已入窗视图的 `window.effectiveAppearance`
    /// 3. System 模式下用 `AppleInterfaceStyle`（启动早期比 `NSApp.effectiveAppearance` 更准）
    /// 4. 最后回落 `NSApp.effectiveAppearance`
    static func resolvedIsDark(for view: NSView? = nil) -> Bool {
        switch appThemePreference.withLock({ $0 }) {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            break
        }

        if let window = view?.window {
            return isDarkAppearance(window.effectiveAppearance)
        }

        // 启动早期视图可能尚未入窗；`NSApp.effectiveAppearance` 有时仍停在默认 aqua。
        // `AppleInterfaceStyle` 在 AppKit 完成激活前即可读：有值为 Dark，缺省为 Light。
        if NSApp.windows.isEmpty {
            return systemPrefersDark()
        }

        let fromApp = isDarkAppearance(NSApp.effectiveAppearance)
        // 系统为 Dark 但 NSApp 仍报 light 时（启动竞态），以系统偏好为准。
        if systemPrefersDark(), !fromApp {
            return true
        }
        return fromApp
    }

    @MainActor
    static func reloadWindowBackgroundOpacity(_ opacity: Double) {
        windowBackgroundOpacity.withLock { $0 = opacity }
        changes.objectWillChange.send()
    }

    static var background: NSColor {
        dynamic { theme in
            theme.backgroundNSColor.withAlphaComponent(windowBackgroundOpacity.withLock { $0 })
        }
    }
    static var sidebar: NSColor {
        dynamic { theme in
            let base = customSidebarColor(for: theme) ?? theme.sidebarNSColor
            return base.withAlphaComponent(windowBackgroundOpacity.withLock { $0 })
        }
    }
    /// 窗口主文字色：自定义主题的「文本色」，或当前 Ghostty 主题的 foreground。
    static var foreground: NSColor { dynamic { $0.foregroundNSColor } }
    /// 次要文字：主文字向背景轻混，贴近系统 secondary 的对比度。
    static var secondaryForeground: NSColor {
        dynamic { theme in
            theme.foregroundNSColor.blended(withFraction: 0.40, of: theme.backgroundNSColor)
                ?? theme.foregroundNSColor.withAlphaComponent(0.62)
        }
    }
    static var cursor: NSColor { dynamic { $0.accentNSColor } }
    static var accent: NSColor { cursor }
    static var divider: NSColor {
        dynamic { theme in
            if theme.name == defaultDarkThemeName || theme.name == defaultLightThemeName {
                return NSColor.labelColor.withAlphaComponent(0.06)
            }
            if let custom = customSurfaceColor(for: theme, elevation: 0.08) {
                return custom
            }
            return theme.surfaceNSColor(elevation: 0.08)
        }
    }

    /// SwiftUI 主文字（跟随当前主题 foreground）。
    static var primaryColor: Color { Color(nsColor: foreground) }
    /// SwiftUI 次要文字。
    static var secondaryColor: Color { Color(nsColor: secondaryForeground) }

    static func isDefault(dark: Bool) -> Bool {
        let theme = resolvedDefinition(dark: dark)
        return theme.name == (dark ? defaultDarkThemeName : defaultLightThemeName)
    }

    static func sidebarFill(dark: Bool) -> NSColor {
        let theme = resolvedDefinition(dark: dark)
        return customSidebarColor(for: theme) ?? theme.sidebarNSColor
    }

    private nonisolated static func customSidebarColor(
        for theme: GhosttyThemeDefinition
    ) -> NSColor? {
        customSnapshot(named: theme.name)?.sidebarNSColor
    }

    private nonisolated static func customSurfaceColor(
        for theme: GhosttyThemeDefinition, elevation: CGFloat
    ) -> NSColor? {
        customSnapshot(named: theme.name)?.surfaceNSColor(elevation: elevation)
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

    /// 终端配色：自定义主题使用其绑定的 Ghostty 主题；否则与窗口定义一致。
    /// `followBackground` 开启时终端背景改为自定义背景色。
    static func terminal(dark: Bool) -> KeroTerminalTheme {
        let name = resolvedThemeName(dark: dark)
        if let custom = customSnapshot(named: name),
           let ghostty = builtinOrGhosttyDefinition(named: custom.ghosttyTheme)
        {
            var colors = terminalTheme(ghostty)
            if custom.followBackground {
                colors = KeroTerminalTheme(
                    background: GhosttyThemeDefinition.nsColorPublic(custom.background),
                    foreground: colors.foreground,
                    cursor: colors.cursor,
                    ansi: colors.ansi
                )
            }
            return colors
        }
        return terminalTheme(resolvedDefinition(dark: dark))
    }

    /// 解析指定外观的编辑器配色。空名称代表继承项目级主题覆盖后的窗口主题。
    static func editorTerminal(
        _ themeName: String, dark: Bool
    ) -> (colors: KeroTerminalTheme, isDark: Bool) {
        if let vscode = VSCodeEditorTheme.definition(named: themeName) {
            return (
                KeroTerminalTheme(
                    background: vscode.background,
                    foreground: vscode.foreground,
                    cursor: vscode.cursor,
                    ansi: Array(repeating: hex(vscode.foreground), count: 16)
                ),
                vscode.dark
            )
        }
        // 编辑器独立主题仅接受内置 VS Code 主题；其他值（包括旧 Ghostty
        // 编辑器配置）回退为当前窗口解析出的全局或项目主题。
        return (terminal(dark: dark), dark)
    }

    private static func terminalTheme(_ theme: GhosttyThemeDefinition) -> KeroTerminalTheme {
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
            // 强制 Light/Dark 时以偏好为准，避免动态色在启动时按错误 appearance 取样。
            let dark: Bool
            switch appThemePreference.withLock({ $0 }) {
            case .dark: dark = true
            case .light: dark = false
            case .system: dark = isDarkAppearance(appearance)
            }
            return resolve(resolvedDefinition(dark: dark))
        }
    }

    /// 当前生效的主题名（项目覆盖优先，否则全局 selection）。
    private static func resolvedThemeName(dark: Bool) -> String {
        let global = selection.withLock { dark ? $0.dark : $0.light }
        let projectName = projectSelection.withLock { dark ? $0.dark : $0.light }
        if let projectName, definition(named: projectName) != nil {
            return projectName
        }
        return global.name
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

    /// 用户自定义主题名（按 dark/light 过滤）。须在主线程调用。
    @MainActor
    static func custom(dark: Bool) -> [String] {
        CustomThemeStore.shared.themes(dark: dark).map(\.name)
    }

    static func primary(dark: Bool) -> [String] {
        dark ? darkPrimary : lightPrimary
    }

    static func cool(dark: Bool) -> [String] {
        dark ? darkCool : lightCool
    }

    static func warm(dark: Bool) -> [String] {
        dark ? darkWarm : lightWarm
    }

    /// Ghostty 内置 + Default；不含自定义（自定义单独成组）。
    static func all(dark: Bool) -> [String] {
        let defaultName = dark ? Theme.defaultDarkThemeName : Theme.defaultLightThemeName
        return [defaultName]
            + GhosttyThemeCatalog.allThemes.filter { $0.isDark == dark }.map(\.name)
    }

    /// 完整列表（自定义在前），用于「全部…」子菜单。
    @MainActor
    static func allIncludingCustom(dark: Bool) -> [String] {
        custom(dark: dark) + all(dark: dark)
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
    /// 供 CustomThemeSnapshot 等非扩展路径复用。
    static func nsColorPublic(_ hex: String) -> NSColor { nsColor(hex) }

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
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            return NSImage(size: imageSize)
        }

        bitmapRep.size = imageSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let cgContext = context.cgContext
        context.imageInterpolation = .high
        cgContext.interpolationQuality = .high
        cgContext.setShouldAntialias(true)
        cgContext.setAllowsAntialiasing(true)

        cgContext.scaleBy(x: scale, y: scale)

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

        NSGraphicsContext.restoreGraphicsState()

        let finalImage = NSImage(size: imageSize)
        finalImage.addRepresentation(bitmapRep)
        return finalImage
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
