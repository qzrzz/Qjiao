//
//  CustomTheme.swift
//  kero
//
//  用户自定义主题：窗口 chrome 由背景/文本/强调色生成，终端配色绑定 Ghostty 主题。
//  文件保存在配置目录下 themes/{id}.json。
//

import AppKit
import Combine
import Foundation
import GhosttyTheme

/// 用户自定义主题定义。
///
/// - 窗口界面色：`background` 作主背景/侧栏基色，`foreground` 作主/次文字，
///   `accent` 作强调与激活态；侧栏与分割线等由三色推导。
/// - 终端色：使用 `ghosttyTheme` 指定的 Ghostty 主题完整 palette；
///   可选 `followBackground` 将终端背景改为自定义背景色。
/// - `isDark`：决定出现在 Dark colors 还是 Light colors 选择器中。
struct CustomTheme: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    /// 显示名，同时作为 Settings / 项目主题选择器中的选项 key（须全局唯一）。
    var name: String
    var isDark: Bool
    /// 窗口背景，hex `RRGGBB`（可带 `#`）。
    var background: String
    /// 窗口主文本色。
    var foreground: String
    /// 强调色（光标、激活图标、链接等）。
    var accent: String
    /// 终端使用的 Ghostty 主题名。
    var ghosttyTheme: String
    /// 为 true 时终端背景使用本主题的 `background`，其余仍用 Ghostty palette。
    var followBackground: Bool

    init(
        id: UUID = UUID(),
        name: String,
        isDark: Bool,
        background: String,
        foreground: String,
        accent: String,
        ghosttyTheme: String,
        followBackground: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.background = Self.normalizeHex(background)
        self.foreground = Self.normalizeHex(foreground)
        self.accent = Self.normalizeHex(accent)
        self.ghosttyTheme = ghosttyTheme
        self.followBackground = followBackground
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isDark, background, foreground, accent, ghosttyTheme, followBackground
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isDark = try container.decode(Bool.self, forKey: .isDark)
        background = Self.normalizeHex(try container.decode(String.self, forKey: .background))
        foreground = Self.normalizeHex(try container.decode(String.self, forKey: .foreground))
        accent = Self.normalizeHex(try container.decode(String.self, forKey: .accent))
        ghosttyTheme = try container.decode(String.self, forKey: .ghosttyTheme)
        // 旧 JSON 无此字段时视为关闭。
        followBackground = try container.decodeIfPresent(Bool.self, forKey: .followBackground) ?? false
    }

    /// 用于菜单预览与窗口 chrome 的合成 Ghostty 定义（不含完整终端 palette）。
    var windowDefinition: GhosttyThemeDefinition {
        GhosttyThemeDefinition(
            name: name,
            background: background,
            foreground: foreground,
            cursorColor: accent,
            cursorText: background,
            selectionBackground: accent,
            selectionForeground: foreground,
            // index 4 是 `accentNSColor` 的回退源。
            palette: [4: accent]
        )
    }

    var backgroundNSColor: NSColor { Self.nsColor(background) }
    var foregroundNSColor: NSColor { Self.nsColor(foreground) }
    var accentNSColor: NSColor { Self.nsColor(accent) }

    /// 侧栏略深于（暗色）或略灰于（亮色）主背景，贴近 Default 主题观感。
    var sidebarNSColor: NSColor {
        let bg = backgroundNSColor
        if isDark {
            return bg.blended(withFraction: 0.28, of: .black) ?? bg
        }
        // 亮色：向中性灰轻推，避免纯白侧栏与内容区完全同色。
        let gray = NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1)
        return bg.blended(withFraction: 0.55, of: gray) ?? bg
    }

    func surfaceNSColor(elevation: CGFloat) -> NSColor {
        backgroundNSColor.blended(withFraction: elevation, of: foregroundNSColor)
            ?? backgroundNSColor
    }

    /// 规范化为小写无 `#` 的 6 位 hex；非法值回退为黑色。
    static func normalizeHex(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        s = s.lowercased()
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return "000000" }
        return s
    }

    static func nsColor(_ hex: String) -> NSColor {
        let digits = normalizeHex(hex)
        guard let value = Int(digits, radix: 16) else { return .magenta }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    static func hex(from color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }

    /// 新建主题时的默认配色（随 dark/light）；名称自动避开已有主题。
    @MainActor
    static func makeDraft(isDark: Bool, name: String = "") -> CustomTheme {
        let resolvedName: String
        if name.isEmpty {
            let base = isDark ? "Custom Dark" : "Custom Light"
            if CustomThemeStore.shared.isNameAvailable(base) {
                resolvedName = base
            } else {
                var index = 2
                while !CustomThemeStore.shared.isNameAvailable("\(base) \(index)") {
                    index += 1
                }
                resolvedName = "\(base) \(index)"
            }
        } else {
            resolvedName = name
        }
        if isDark {
            return CustomTheme(
                name: resolvedName,
                isDark: true,
                background: "0d1117",
                foreground: "e6edf3",
                accent: "2f81f7",
                ghosttyTheme: Theme.defaultDarkThemeName
            )
        }
        return CustomTheme(
            name: resolvedName,
            isDark: false,
            background: "ffffff",
            foreground: "1f2328",
            accent: "0969da",
            ghosttyTheme: Theme.defaultLightThemeName
        )
    }
}

// MARK: - Store

/// 读写 `~/.config/qjiao/themes/*.json`，并在变更时通知主题系统。
@MainActor
final class CustomThemeStore: ObservableObject {
    static let shared = CustomThemeStore()

    @Published private(set) var themes: [CustomTheme] = []

    /// `…/themes/`（Debug 为 `qjiao-dev`）。
    static var directoryURL: URL {
        AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("themes", isDirectory: true)
    }

    private init() {
        reload()
    }

    func reload() {
        let dir = Self.directoryURL
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            themes = []
            Theme.reloadCustomThemes([])
            return
        }
        let decoder = JSONDecoder()
        var loaded: [CustomTheme] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let theme = try? decoder.decode(CustomTheme.self, from: data)
            else { continue }
            loaded.append(theme)
        }
        themes = loaded.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        Theme.reloadCustomThemes(themes)
    }

    func theme(named name: String) -> CustomTheme? {
        themes.first { $0.name == name }
    }

    func theme(id: UUID) -> CustomTheme? {
        themes.first { $0.id == id }
    }

    func themes(dark: Bool) -> [CustomTheme] {
        themes.filter { $0.isDark == dark }
    }

    /// 名称是否可用：非空、不与其他自定义主题冲突、不与内置/Ghostty 主题重名。
    func isNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == Theme.defaultDarkThemeName || trimmed == Theme.defaultLightThemeName {
            return false
        }
        if themes.contains(where: { $0.name == trimmed && $0.id != id }) {
            return false
        }
        // 与 Ghostty 目录重名会掩盖内置主题，禁止。
        if GhosttyThemeCatalog.theme(named: trimmed) != nil {
            return false
        }
        return true
    }

    @discardableResult
    func save(_ theme: CustomTheme) throws -> CustomTheme {
        var theme = theme
        theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        theme.background = CustomTheme.normalizeHex(theme.background)
        theme.foreground = CustomTheme.normalizeHex(theme.foreground)
        theme.accent = CustomTheme.normalizeHex(theme.accent)
        guard isNameAvailable(theme.name, excluding: theme.id) else {
            throw CustomThemeError.duplicateName(theme.name)
        }
        // ghostty 回退：无效名时用默认
        if Theme.builtinOrGhosttyDefinition(named: theme.ghosttyTheme) == nil {
            theme.ghosttyTheme = theme.isDark
                ? Theme.defaultDarkThemeName
                : Theme.defaultLightThemeName
        }

        let dir = Self.directoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(theme.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: url, options: .atomic)

        if let index = themes.firstIndex(where: { $0.id == theme.id }) {
            let oldName = themes[index].name
            themes[index] = theme
            if oldName != theme.name {
                // 先更新快照再改名引用，避免中间态解析失败。
                Theme.reloadCustomThemes(themes)
                renameSelectionIfNeeded(from: oldName, to: theme.name)
            }
        } else {
            themes.append(theme)
        }
        themes.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        Theme.reloadCustomThemes(themes)
        notifyThemeChanged()
        return theme
    }

    func delete(id: UUID) throws {
        guard let theme = theme(id: id) else { return }
        let url = Self.directoryURL.appendingPathComponent("\(id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        themes.removeAll { $0.id == id }
        Theme.reloadCustomThemes(themes)
        clearSelectionIfNeeded(named: theme.name, wasDark: theme.isDark)
        notifyThemeChanged()
    }

    private func renameSelectionIfNeeded(from old: String, to new: String) {
        let settings = AppSettings.shared
        if settings.themeDark == old { settings.themeDark = new }
        if settings.themeLight == old { settings.themeLight = new }
        TerminalManager.remapProjectThemeName(from: old, to: new)
    }

    private func clearSelectionIfNeeded(named name: String, wasDark: Bool) {
        let settings = AppSettings.shared
        if settings.themeDark == name {
            settings.themeDark = Theme.defaultDarkThemeName
        }
        if settings.themeLight == name {
            settings.themeLight = Theme.defaultLightThemeName
        }
        // 删除后项目侧改回跟随全局。
        TerminalManager.remapProjectThemeName(from: name, to: nil)
        _ = wasDark
    }

    private func notifyThemeChanged() {
        // 重新套用当前全局选择，让窗口 / 终端立刻反映自定义主题改动。
        Theme.reloadSelection(
            light: AppSettings.shared.themeLight,
            dark: AppSettings.shared.themeDark
        )
        Theme.changes.objectWillChange.send()
        TerminalManager.refreshAllAppearances()
        objectWillChange.send()
    }
}

enum CustomThemeError: LocalizedError {
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return L10n.format("A theme named \"%@\" already exists.", name)
        }
    }
}
