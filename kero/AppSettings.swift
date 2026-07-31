//
//  AppSettings.swift
//  kero
//

import AppKit
import Combine
import Foundation
import GhosttyTheme

/// Info 面板执行 package 脚本时使用的命令前缀。
enum PackageManagerCommand: String, CaseIterable, Identifiable {
    case auto = "auto"
    case bun = "bun run"
    case npm = "npm run"
    case pnpm = "pnpm run"
    case yarn = "yarn run"
    case vp = "vp run"
    case nub = "nub run"

    var id: String { rawValue }

    /// 包管理器的显示名称（不含 run 后缀，例如 "自动识别"、"npm"、"bun"）
    var displayName: String {
        switch self {
        case .auto: return L10n.t("Auto Detect")
        case .bun: return "bun"
        case .npm: return "npm"
        case .pnpm: return "pnpm"
        case .yarn: return "yarn"
        case .vp: return "vp"
        case .nub: return "nub"
        }
    }

    /// 获取具体生效的包管理器执行命令前缀（如 "npm run"、"bun run" 等）
    func resolveCommandPrefix(for directory: String? = nil) -> String {
        if self == .auto {
            if let directory = directory, !directory.isEmpty {
                let info = SidebarProbe.detectPackageManager(directory: directory)
                return info.name == "yarn" ? "yarn run" : "\(info.name) run"
            }
            return "npm run"
        }
        return rawValue
    }

    /// 获取具体生效的包管理器显示名称（如 "npm"、"pnpm" 等）
    func resolveDisplayName(for directory: String? = nil) -> String {
        if self == .auto {
            if let directory = directory, !directory.isEmpty {
                let info = SidebarProbe.detectPackageManager(directory: directory)
                return info.name
            }
            return "npm"
        }
        return displayName
    }
}

/// Zsh 闲时标签页名称控制模式。
enum ZshIdleTitleStyle: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case defaultStyle = "default"
    case folderFirst = "folderFirst"
    case twoFolderFirst = "twoFolderFirst"
    case short = "short"
    case minimal = "minimal"

    var id: String { rawValue }

    /// 显示文案
    var displayName: String {
        switch self {
        case .defaultStyle:
            return L10n.t("Default (Do not modify)")
        case .folderFirst:
            return L10n.t("Folder first (%1~ — %n@%m)")
        case .twoFolderFirst:
            return L10n.t("2-level Folder first (%2~ — %n@%m)")
        case .short:
            return L10n.t("Short (%1~ — %n)")
        case .minimal:
            return L10n.t("Minimal (%1~)")
        }
    }

    /// 对应的 `$ZSH_THEME_TERM_TITLE_IDLE` 环境变量值，`nil` 表示不改动默认设置。
    var environmentValue: String? {
        switch self {
        case .defaultStyle:
            return nil
        case .folderFirst:
            return "%1~ — %n@%m"
        case .twoFolderFirst:
            return "%2~ — %n@%m"
        case .short:
            return "%1~ — %n"
        case .minimal:
            return "%1~"
        }
    }

    /// 根据当前目录路径与样式格式化闲时标题；`nil` 表示默认（不修改）。
    func formatTitle(for directoryPath: String) -> String? {
        guard let envPattern = environmentValue else { return nil }

        let homeDir = NSHomeDirectory()
        let relPath: String
        if directoryPath == homeDir || directoryPath == homeDir + "/" {
            relPath = "~"
        } else if directoryPath.hasPrefix(homeDir + "/") {
            relPath = "~/" + String(directoryPath.dropFirst(homeDir.count + 1))
        } else {
            relPath = directoryPath
        }

        let oneTilde: String
        let twoTilde: String
        if relPath == "~" {
            oneTilde = "~"
            twoTilde = "~"
        } else if relPath == "/" || relPath.isEmpty {
            oneTilde = "/"
            twoTilde = "/"
        } else {
            let components = relPath.split(separator: "/").map(String.init)
            oneTilde = components.last ?? (directoryPath as NSString).lastPathComponent
            if components.count >= 2 {
                twoTilde = components.suffix(2).joined(separator: "/")
            } else {
                twoTilde = oneTilde
            }
        }

        let user = NSUserName()
        let rawHost = ProcessInfo.processInfo.hostName
        let host = rawHost.components(separatedBy: ".").first ?? rawHost

        var result = envPattern
        result = result.replacingOccurrences(of: "%2~", with: twoTilde)
        result = result.replacingOccurrences(of: "%1~", with: oneTilde)
        result = result.replacingOccurrences(of: "%n", with: user)
        result = result.replacingOccurrences(of: "%m", with: host)
        return result
    }
}


/// User-configurable settings, persisted to `$HOME/.config/qjiao/config.toml`.
/// Views observe this directly; `TerminalManager` re-themes live sessions on
/// any change.
@MainActor
final class AppSettings: nonisolated ObservableObject {
    static let shared = AppSettings()

    /// Development (Debug) builds store their config under `~/.config/qjiao-dev`
    /// instead of `~/.config/qjiao`, so running a dev build alongside an
    /// installed production build doesn't clobber its settings. The two build
    /// variants also use different application data locations.
    static let configURL: URL = {
        #if DEBUG
        let directory = "qjiao-dev"
        #else
        let directory = "qjiao"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(directory)/config.toml")
    }()

    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 8...32
    /// 左右侧栏统一 chrome 字号的基准值与可调范围。
    static let defaultSidebarFontSize: Double = 13
    static let sidebarFontSizeRange: ClosedRange<Double> = 9...18
    /// Files / CWD 树默认字号，与 chrome `body` 一致。
    static let defaultFilesFontSize: Double = 13
    static let filesFontSizeRange: ClosedRange<Double> = 10...22
    static let backgroundOpacityRange: ClosedRange<Double> = 0.1...1

    /// UI language. Default is System (`system`); persisted as `ui.language`.
    @Published var language: AppLanguage {
        didSet {
            L10n.shared.setLanguage(language)
            save()
        }
    }

    /// Light/dark appearance override; `system` follows macOS.
    @Published var theme: AppTheme {
        didSet {
            applyAppearance()
            save()
        }
    }

    /// Selected Ghostty theme for dark appearance.
    @Published var themeDark: String {
        didSet { reloadThemeSelection(); save() }
    }

    /// Selected Ghostty theme for light appearance.
    @Published var themeLight: String {
        didSet { reloadThemeSelection(); save() }
    }

    /// 原生窗口面板背景的不透明度；终端表面由单独设置控制。
    @Published var windowBackgroundOpacity: Double {
        didSet {
            Theme.reloadWindowBackgroundOpacity(windowBackgroundOpacity)
            save()
        }
    }

    /// Ghostty 终端背景的不透明度。
    @Published var terminalBackgroundOpacity: Double {
        didSet { save() }
    }

    /// Terminal font family name; empty string means the bundled default
    /// (JetBrains Mono).
    @Published var fontFamily: String {
        didSet { save() }
    }

    @Published var fontSize: Double {
        didSet { save() }
    }

    /// 左右侧栏的基础字号；`SidebarTypography` 按比例缩放既有层级。
    @Published var sidebarFontSize: Double {
        didSet { save() }
    }

    /// Whether Ghostty should render terminal glyphs with thicker strokes.
    @Published var fontThicken: Bool {
        didSet { save() }
    }

    /// 是否把 Option 组合键作为终端 Alt/Meta，而不是交给 macOS 输入源生成文字。
    @Published var macosOptionAsAlt: Bool {
        didSet { save() }
    }

    /// 是否在多分屏布局中显示分屏标题栏与控制按钮（默认 false）。
    @Published var showPaneHeaders: Bool {
        didSet { save() }
    }

    /// Ctrl-Tab 切换器是否按最近使用时间 (MRU) 排序（默认 true）。
    @Published var tabSwitcherSortByRecency: Bool {
        didSet { save() }
    }

    /// 是否为终端中文字符启用内置的思源黑体等宽回退字体。
    @Published var useBundledChineseTerminalFont: Bool {
        didSet { save() }
    }

    /// Soft-wrap file editor lines to the viewport width. Off by default so
    /// long lines scroll horizontally.
    @Published var wrapLines: Bool {
        didSet { save() }
    }

    /// 是否在源码编辑器底部显示文件与格式化状态栏。
    @Published var showEditorStatusBar: Bool {
        didSet { save() }
    }

    /// 亮色外观下编辑器的配色；空字符串代表继承全局与当前项目主题。
    @Published var editorThemeLight: String {
        didSet { save() }
    }

    /// 暗色外观下编辑器的配色；空字符串代表继承全局与当前项目主题。
    @Published var editorThemeDark: String {
        didSet { save() }
    }

    /// 右侧 Files / CWD 文件树是否在文件名右侧显示文件大小。默认开启。
    @Published var displayFileSize: Bool {
        didSet { save() }
    }

    /// Files / CWD 文件树是否显示 Git 状态装饰（彩色文件名与状态徽章）。默认关闭。
    @Published var filesGitDecorations: Bool {
        didSet { save() }
    }

    /// 面板中的路径显示是否将用户目录缩短为 ~。
    @Published var displayShortDirPath: Bool {
        didSet { save() }
    }

    /// Files / CWD 文件树字体族；空字符串表示内置 Inter Variable。
    @Published var filesFontFamily: String {
        didSet { save() }
    }

    /// Files / CWD 文件树主文字字号（pt）。
    @Published var filesFontSize: Double {
        didSet { save() }
    }

    /// Restore each terminal's previous scrollback (as static, styled text)
    /// when the app relaunches, above the freshly started shell. Off by
    /// default: opt-in, and it writes captured output to disk.
    @Published var restoreTerminalHistory: Bool {
        didSet { save() }
    }

    /// 允许 libghostty 在 Prompt 输入区域中通过普通单击移动光标；默认开启。
    @Published var directClickMovesCursor: Bool {
        didSet { save() }
    }



    /// Zsh 控制的闲时标签页名称设置 ($ZSH_THEME_TERM_TITLE_IDLE)。
    @Published var zshIdleTitleStyle: ZshIdleTitleStyle {
        didSet { save() }
    }

    /// 是否在终端底部显示即时上下文帮助栏（如 Vi 编辑辅助）。
    @Published var enableTerminalHelpBar: Bool {
        didSet { save() }
    }

    /// The command prefix used by the Info panel's package script launcher.
    @Published var packageManagerCommand: PackageManagerCommand {
        didSet { save() }
    }

    /// System 面板 Reachability 探测间隔（默认 30s）。
    @Published var systemReachabilityInterval: ReachabilityInterval {
        didSet { save() }
    }

    /// 用户首选代码编辑器的 Bundle ID；空字符串表示使用检测到的第一个已安装编辑器。
    @Published var preferredCodeEditorBundleId: String {
        didSet { save() }
    }

    /// 用户首选 AI 工具的 ID（如 "desktop:com.openai.codex" 或 "cli:agy"）；空字符串表示使用检测到的首个工具。
    @Published var preferredAIToolId: String {
        didSet { save() }
    }

    /// 本地 AI headless 提供器（`LocalAI` 统一接口所用 CLI）；默认 disabled。
    ///
    /// 写入 `config.toml` 的 `ai.headless-provider`；UI 与运行时通过 `LocalAIRegistry` 同步。
    @Published var localAIHeadlessProvider: LocalAIProviderID {
        didSet { save() }
    }

    /// AI 写作语言（Git Commit、描述等生成内容）；默认英文。
    ///
    /// 写入 `config.toml` 的 `ai.writing-language`；项目可单独覆盖。
    @Published var aiWritingLanguage: AIWritingLanguage {
        didSet { save() }
    }

    /// 是否在 AI 生成的 Git Commit Message 中使用 Gitmoji emoji；默认开启。
    ///
    /// 写入 `config.toml` 的 `ai.git-commit-emoji`。
    @Published var gitCommitMessageEmoji: Bool {
        didSet { save() }
    }

    /// 用户自定义挑选的 `.app` 代码编辑器路径列表。
    @Published var customCodeEditorPaths: [String] {
        didSet { save() }
    }

    /// 用户自定义填写的 CLI 命令行 AI 工具名称列表。
    @Published var customCLITools: [String] {
        didSet { save() }
    }

    /// Script Runner 配置: JavaScript / TypeScript
    @Published var scriptRunnerJS: ScriptRunnerJSSetting {
        didSet { save() }
    }

    /// Script Runner 配置: Python
    @Published var scriptRunnerPython: ScriptRunnerPythonSetting {
        didSet { save() }
    }

    /// Script Runner 配置: Go
    @Published var scriptRunnerGo: ScriptRunnerGoSetting {
        didSet { save() }
    }

    /// Script Runner 配置: Rust
    @Published var scriptRunnerRust: ScriptRunnerRustSetting {
        didSet { save() }
    }

    /// 毛玻璃 4 核心属性定制选项：Material 材质
    @Published var visualEffectMaterial: String {
        didSet { save() }
    }

    /// 毛玻璃 4 核心属性定制选项：Blending Mode 混合模式
    @Published var visualEffectBlendingMode: String {
        didSet { save() }
    }

    /// 毛玻璃 4 核心属性定制选项：State 激活状态
    @Published var visualEffectState: String {
        didSet { save() }
    }

    /// 毛玻璃 4 核心属性定制选项：Alpha 不透明度 (0.0 ~ 1.0)
    @Published var visualEffectAlpha: Double {
        didSet { save() }
    }

    var resolvedVisualEffectMaterial: NSVisualEffectView.Material {
        switch visualEffectMaterial {
        case "sidebar": return .sidebar
        case "underWindowBackground": return .underWindowBackground
        case "hud": return .hudWindow
        case "popover": return .popover
        case "menu": return .menu
        case "headerView": return .headerView
        case "titlebar": return .titlebar
        default: return .underWindowBackground
        }
    }

    var resolvedVisualEffectBlendingMode: NSVisualEffectView.BlendingMode {
        switch visualEffectBlendingMode {
        case "withinWindow": return .withinWindow
        default: return .behindWindow
        }
    }

    var resolvedVisualEffectState: NSVisualEffectView.State? {
        switch visualEffectState {
        case "active": return .active
        case "inactive": return .inactive
        case "followsWindow": return .followsWindowActiveState
        default: return nil
        }
    }

    private init() {
        // 先加载自定义主题目录，使 knownTheme 能识别用户主题。
        _ = CustomThemeStore.shared
        let existing = TOML.parse(at: Self.configURL)
        let toml = existing ?? Self.legacyDefaults()
        language = toml["ui.language"]?.string.flatMap(AppLanguage.init(rawValue:)) ?? .system
        theme = toml["theme"]?.string.flatMap(AppTheme.init(rawValue:)) ?? .system
        themeDark = Self.knownTheme(toml["theme-dark"]?.string, fallback: Theme.defaultDarkThemeName)
        themeLight = Self.knownTheme(toml["theme-light"]?.string, fallback: Theme.defaultLightThemeName)
        windowBackgroundOpacity = Self.validOpacity(
            toml["window.background-opacity"]?.double
        )
        terminalBackgroundOpacity = Self.validOpacity(
            toml["terminal.background-opacity"]?.double
        )
        visualEffectMaterial = toml["window.effect-material"]?.string ?? "underWindowBackground"
        visualEffectBlendingMode = toml["window.effect-blending-mode"]?.string ?? "behindWindow"
        visualEffectState = toml["window.effect-state"]?.string ?? "followsApp"
        visualEffectAlpha = Self.validOpacity(toml["window.effect-alpha"]?.double)
        fontFamily = toml["font-family"]?.string ?? ""
        let size = toml["font-size"]?.double ?? Self.defaultFontSize
        fontSize = Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize
        let sidebarSize = toml["sidebar.font-size"]?.double ?? Self.defaultSidebarFontSize
        sidebarFontSize = Self.sidebarFontSizeRange.contains(sidebarSize)
            ? sidebarSize
            : Self.defaultSidebarFontSize
        fontThicken = toml["font-thicken"]?.bool ?? false
        macosOptionAsAlt = toml["terminal.macos-option-as-alt"]?.bool ?? false
        showPaneHeaders = toml["terminal.show-pane-headers"]?.bool ?? false
        tabSwitcherSortByRecency = toml["terminal.tab-switcher-sort-by-recency"]?.bool ?? false
        useBundledChineseTerminalFont = toml["terminal.use-bundled-chinese-font"]?.bool ?? true
        wrapLines = toml["editor.wrap-lines"]?.bool ?? false
        showEditorStatusBar = toml["editor.show-status-bar"]?.bool ?? true
        // 兼容上一版只有一个 editor.theme 的配置，将它迁移到匹配的亮色或暗色选项。
        let legacyEditorTheme = toml["editor.theme"]?.string
        editorThemeLight = Self.knownEditorTheme(
            toml["editor.theme-light"]?.string ?? Self.legacyEditorTheme(legacyEditorTheme, dark: false),
            dark: false
        )
        editorThemeDark = Self.knownEditorTheme(
            toml["editor.theme-dark"]?.string ?? Self.legacyEditorTheme(legacyEditorTheme, dark: true),
            dark: true
        )
        displayFileSize = toml["files.display-file-size"]?.bool ?? true
        filesGitDecorations = toml["files.git-decorations"]?.bool ?? false
        displayShortDirPath = toml["appearance.short-directory-path"]?.bool
            ?? toml["appearance.display-short-dir-path"]?.bool
            ?? toml["appearance.display-sort-dir-path"]?.bool
            ?? toml["display-sort-dir-path"]?.bool
            ?? false
        filesFontFamily = toml["files.font-family"]?.string ?? ""
        let filesSize = toml["files.font-size"]?.double ?? Self.defaultFilesFontSize
        filesFontSize = Self.filesFontSizeRange.contains(filesSize) ? filesSize : Self.defaultFilesFontSize
        restoreTerminalHistory = toml["terminal.restore-history"]?.bool ?? false
        directClickMovesCursor = toml["terminal.direct-click-moves-cursor"]?.bool ?? true
        zshIdleTitleStyle = toml["terminal.zsh-idle-title-style"]?.string
            .flatMap(ZshIdleTitleStyle.init(rawValue:))
            ?? toml["terminal.zsh-idle-title"]?.string
            .flatMap(ZshIdleTitleStyle.init(rawValue:))
            ?? .minimal
        enableTerminalHelpBar = toml["terminal.enable-help-bar"]?.bool ?? true
        preferredCodeEditorBundleId = toml["editor.preferred-code-editor"]?.string ?? ""
        preferredAIToolId = toml["ai.preferred-tool"]?.string ?? ""
        localAIHeadlessProvider = toml["ai.headless-provider"]?.string
            .flatMap(LocalAIProviderID.init(rawValue:)) ?? .disabled
        aiWritingLanguage = toml["ai.writing-language"]?.string
            .flatMap(AIWritingLanguage.init(rawValue:)) ?? .english
        // 默认 true：缺省或非法值均视为开启 Gitmoji。
        if let emojiFlag = toml["ai.git-commit-emoji"]?.bool {
            gitCommitMessageEmoji = emojiFlag
        } else {
            gitCommitMessageEmoji = true
        }
        customCodeEditorPaths = toml["editor.custom-editors"]?.array?.compactMap(\.string) ?? []
        customCLITools = toml["ai.custom-cli-tools"]?.array?.compactMap(\.string) ?? []
        packageManagerCommand = toml["terminal.package-manager"]?.string
            .flatMap(PackageManagerCommand.init(rawValue:)) ?? .auto

        scriptRunnerJS = toml["files.script-runner.javascript"]?.string
            .flatMap(ScriptRunnerJSSetting.init(rawValue:))
            ?? toml["files.script-runner-js"]?.string
            .flatMap(ScriptRunnerJSSetting.init(rawValue:))
            ?? .auto
        scriptRunnerPython = toml["files.script-runner.python"]?.string
            .flatMap(ScriptRunnerPythonSetting.init(rawValue:))
            ?? toml["files.script-runner-python"]?.string
            .flatMap(ScriptRunnerPythonSetting.init(rawValue:))
            ?? .auto
        scriptRunnerGo = toml["files.script-runner.go"]?.string
            .flatMap(ScriptRunnerGoSetting.init(rawValue:))
            ?? toml["files.script-runner-go"]?.string
            .flatMap(ScriptRunnerGoSetting.init(rawValue:))
            ?? .auto
        scriptRunnerRust = toml["files.script-runner.rust"]?.string
            .flatMap(ScriptRunnerRustSetting.init(rawValue:))
            ?? toml["files.script-runner-rust"]?.string
            .flatMap(ScriptRunnerRustSetting.init(rawValue:))
            ?? .auto
        // 优先 config.toml；无则迁移旧 UserDefaults，最后回落默认 30s。
        var needsSave = existing == nil
        if let raw = toml["system.reachability-interval"]?.string,
           let value = ReachabilityInterval(rawValue: raw) {
            systemReachabilityInterval = value
        } else if let legacy = ReachabilityStore.loadLegacyInterval() {
            systemReachabilityInterval = legacy
            ReachabilityStore.clearLegacyInterval()
            needsSave = true
        } else {
            systemReachabilityInterval = .default
        }
        applyAppearance()
        reloadThemeSelection()
        Theme.reloadWindowBackgroundOpacity(windowBackgroundOpacity)
        // 全部 stored 属性初始化完成后再同步 L10n，避免 init 早期访问 self。
        L10n.shared.setLanguage(language)
        if needsSave { save() }
    }

    private func reloadThemeSelection() {
        Theme.reloadSelection(light: themeLight, dark: themeDark)
    }

    private static func knownTheme(_ name: String?, fallback: String) -> String {
        guard let name, Theme.definition(named: name) != nil else { return fallback }
        return name
    }

    private static func knownEditorTheme(_ name: String?, dark: Bool) -> String {
        guard let name, VSCodeEditorTheme.definition(named: name)?.dark == dark else { return "" }
        return name
    }

    private static func legacyEditorTheme(_ value: String?, dark: Bool) -> String? {
        let prefix = dark ? "dark:" : "light:"
        guard let value, value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    private static func validOpacity(_ value: Double?) -> Double {
        guard let value, backgroundOpacityRange.contains(value) else { return 1 }
        return value
    }

    /// Overrides the app-wide appearance (System / Light / Dark). Project
    /// themes only swap Ghostty color pairs for the active project and never
    /// change this value.
    /// Called from `init` because `didSet` doesn't run during initialization.
    ///
    /// 同时写入 `Theme` 的偏好缓存：启动早期 `NSApp.effectiveAppearance` 可能尚未
    /// 反映系统 Dark，终端 / 动态色用缓存判断 light·dark，避免首帧反了。
    func applyAppearance() {
        Theme.setAppThemePreference(theme)
        // 使用 shared 而非可选 NSApp，确保启动路径一定写入 appearance。
        NSApplication.shared.appearance = theme.nsAppearance
    }

    func resetFont() {
        fontFamily = ""
        fontSize = Self.defaultFontSize
        sidebarFontSize = Self.defaultSidebarFontSize
        fontThicken = false
    }

    func resetToDefaults() {
        resetFont()
        useBundledChineseTerminalFont = true
        language = .system
        theme = .system
        themeDark = Theme.defaultDarkThemeName
        themeLight = Theme.defaultLightThemeName
        windowBackgroundOpacity = 1
        terminalBackgroundOpacity = 1
        visualEffectMaterial = "underWindowBackground"
        visualEffectBlendingMode = "behindWindow"
        visualEffectState = "followsApp"
        visualEffectAlpha = 1
        wrapLines = false
        showEditorStatusBar = true
        editorThemeLight = ""
        editorThemeDark = ""
        displayFileSize = true
        filesGitDecorations = false
        displayShortDirPath = false
        filesFontFamily = ""
        filesFontSize = Self.defaultFilesFontSize
        restoreTerminalHistory = false
        directClickMovesCursor = true
        macosOptionAsAlt = false
        showPaneHeaders = false
        tabSwitcherSortByRecency = false
        zshIdleTitleStyle = .minimal
        enableTerminalHelpBar = true
        packageManagerCommand = .auto
        systemReachabilityInterval = .default
        preferredCodeEditorBundleId = ""
        preferredAIToolId = ""
        localAIHeadlessProvider = .disabled
        aiWritingLanguage = .english
        gitCommitMessageEmoji = true
        customCodeEditorPaths = []
        customCLITools = []
        scriptRunnerJS = .auto
        scriptRunnerPython = .auto
        scriptRunnerGo = .auto
        scriptRunnerRust = .auto
        // 同步 LocalAI 注册表选择，避免设置页仍显示旧 provider
        LocalAIRegistry.shared.syncFromSettings()
    }

    private func save() {
        var lines: [String] = []
        // 默认跟随系统：仅在非默认语言时写回，避免污染默认配置。
        if language != .system {
            lines.append("ui.language = \(TOML.quote(language.rawValue))")
        }
        if theme != .system {
            lines.append("theme = \(TOML.quote(theme.rawValue))")
        }
        if themeDark != Theme.defaultDarkThemeName {
            lines.append("theme-dark = \(TOML.quote(themeDark))")
        }
        if themeLight != Theme.defaultLightThemeName {
            lines.append("theme-light = \(TOML.quote(themeLight))")
        }
        if windowBackgroundOpacity != 1 {
            lines.append("window.background-opacity = \(TOML.number(windowBackgroundOpacity))")
        }
        if terminalBackgroundOpacity != 1 {
            lines.append("terminal.background-opacity = \(TOML.number(terminalBackgroundOpacity))")
        }
        if visualEffectMaterial != "underWindowBackground" {
            lines.append("window.effect-material = \(TOML.quote(visualEffectMaterial))")
        }
        if visualEffectBlendingMode != "behindWindow" {
            lines.append("window.effect-blending-mode = \(TOML.quote(visualEffectBlendingMode))")
        }
        if visualEffectState != "followsApp" {
            lines.append("window.effect-state = \(TOML.quote(visualEffectState))")
        }
        if visualEffectAlpha != 1 {
            lines.append("window.effect-alpha = \(TOML.number(visualEffectAlpha))")
        }
        if !fontFamily.isEmpty {
            lines.append("font-family = \(TOML.quote(fontFamily))")
        }
        lines.append("font-size = \(TOML.number(fontSize))")
        if sidebarFontSize != Self.defaultSidebarFontSize {
            lines.append("sidebar.font-size = \(TOML.number(sidebarFontSize))")
        }
        if fontThicken { lines.append("font-thicken = true") }
        if macosOptionAsAlt {
            lines.append("terminal.macos-option-as-alt = true")
        }
        if showPaneHeaders {
            lines.append("terminal.show-pane-headers = true")
        }
        if tabSwitcherSortByRecency {
            lines.append("terminal.tab-switcher-sort-by-recency = true")
        }
        if !useBundledChineseTerminalFont {
            lines.append("terminal.use-bundled-chinese-font = false")
        }
        if wrapLines {
            lines.append("editor.wrap-lines = true")
        }
        if !showEditorStatusBar {
            lines.append("editor.show-status-bar = false")
        }
        if !editorThemeLight.isEmpty {
            lines.append("editor.theme-light = \(TOML.quote(editorThemeLight))")
        }
        if !editorThemeDark.isEmpty {
            lines.append("editor.theme-dark = \(TOML.quote(editorThemeDark))")
        }
        // 默认 true：仅在关闭时写回，避免污染默认配置文件。
        if !displayFileSize {
            lines.append("files.display-file-size = false")
        }
        if filesGitDecorations {
            lines.append("files.git-decorations = true")
        }
        if displayShortDirPath {
            lines.append("appearance.short-directory-path = true")
        }
        if !filesFontFamily.isEmpty {
            lines.append("files.font-family = \(TOML.quote(filesFontFamily))")
        }
        if filesFontSize != Self.defaultFilesFontSize {
            lines.append("files.font-size = \(TOML.number(filesFontSize))")
        }
        if restoreTerminalHistory {
            lines.append("terminal.restore-history = true")
        }
        if !directClickMovesCursor {
            lines.append("terminal.direct-click-moves-cursor = false")
        }

        if zshIdleTitleStyle != .minimal {
            lines.append("terminal.zsh-idle-title-style = \(TOML.quote(zshIdleTitleStyle.rawValue))")
        }
        if !enableTerminalHelpBar {
            lines.append("terminal.enable-help-bar = false")
        }
        if packageManagerCommand != .auto {
            lines.append("terminal.package-manager = \(TOML.quote(packageManagerCommand.rawValue))")
        }
        if scriptRunnerJS != .auto {
            lines.append("files.script-runner.javascript = \(TOML.quote(scriptRunnerJS.rawValue))")
        }
        if scriptRunnerPython != .auto {
            lines.append("files.script-runner.python = \(TOML.quote(scriptRunnerPython.rawValue))")
        }
        if scriptRunnerGo != .auto {
            lines.append("files.script-runner.go = \(TOML.quote(scriptRunnerGo.rawValue))")
        }
        if scriptRunnerRust != .auto {
            lines.append("files.script-runner.rust = \(TOML.quote(scriptRunnerRust.rawValue))")
        }
        if !preferredCodeEditorBundleId.isEmpty {
            lines.append("editor.preferred-code-editor = \(TOML.quote(preferredCodeEditorBundleId))")
        }
        if !preferredAIToolId.isEmpty {
            lines.append("ai.preferred-tool = \(TOML.quote(preferredAIToolId))")
        }
        if localAIHeadlessProvider != .disabled {
            lines.append("ai.headless-provider = \(TOML.quote(localAIHeadlessProvider.rawValue))")
        }
        // 默认英文：仅非默认时写回。
        if aiWritingLanguage != .english {
            lines.append("ai.writing-language = \(TOML.quote(aiWritingLanguage.rawValue))")
        }
        // 默认 true：仅关闭时写回。
        if !gitCommitMessageEmoji {
            lines.append("ai.git-commit-emoji = false")
        }
        if !customCodeEditorPaths.isEmpty {
            let quoted = customCodeEditorPaths.map { TOML.quote($0) }.joined(separator: ", ")
            lines.append("editor.custom-editors = [\(quoted)]")
        }
        if !customCLITools.isEmpty {
            let quoted = customCLITools.map { TOML.quote($0) }.joined(separator: ", ")
            lines.append("ai.custom-cli-tools = [\(quoted)]")
        }
        if systemReachabilityInterval != .default {
            lines.append(
                "system.reachability-interval = \(TOML.quote(systemReachabilityInterval.rawValue))"
            )
        }
        let homeConfigDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        let prodIdleTitle = homeConfigDir.appendingPathComponent("qjiao/idle_title")
        let devIdleTitle = homeConfigDir.appendingPathComponent("qjiao-dev/idle_title")
        let dir = Self.configURL.deletingLastPathComponent()
        let idleTitleFile = dir.appendingPathComponent("idle_title")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n")
                .write(to: Self.configURL, atomically: true, encoding: .utf8)
            if let envVal = zshIdleTitleStyle.environmentValue {
                try? FileManager.default.createDirectory(at: prodIdleTitle.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: devIdleTitle.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? envVal.write(to: prodIdleTitle, atomically: true, encoding: .utf8)
                try? envVal.write(to: devIdleTitle, atomically: true, encoding: .utf8)
                try? envVal.write(to: idleTitleFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: prodIdleTitle)
                try? FileManager.default.removeItem(at: devIdleTitle)
                try? FileManager.default.removeItem(at: idleTitleFile)
            }
        } catch {
            NSLog("kero: failed to write \(Self.configURL.path): \(error)")
        }
    }

    /// Settings from releases that stored config in UserDefaults.
    private static func legacyDefaults() -> [String: TOML.Value] {
        var toml: [String: TOML.Value] = [:]
        let defaults = UserDefaults.standard
        if let family = defaults.string(forKey: "terminalFontFamily") {
            toml["font-family"] = .string(family)
        }
        if defaults.object(forKey: "terminalFontSize") != nil {
            toml["font-size"] = .number(defaults.double(forKey: "terminalFontSize"))
        }
        return toml
    }
}

/// Minimal TOML support covering what the config file uses: flat and dotted
/// keys (`font-size = 15`, `terminal.restore-history = true`), string/number/
/// bool values, and `#` comments. `[table]` headers are also accepted and
/// flattened to `table.key`, matching the dotted form.
enum TOML {
    enum Value {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([Value])

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var double: Double? {
            if case .number(let n) = self { return n }
            return nil
        }

        var bool: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }

        var array: [Value]? {
            if case .array(let a) = self { return a }
            return nil
        }
    }

    static func parse(at url: URL) -> [String: Value]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var table = ""
        var result: [String: Value] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = parseValue(rawValue) else { continue }
            result[table.isEmpty ? key : "\(table).\(key)"] = value
        }
        return result
    }

    private static func parseValue(_ raw: String) -> Value? {
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            let content = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if content.isEmpty { return .array([]) }
            let items = content.split(separator: ",").compactMap { item -> Value? in
                let trimmed = item.trimmingCharacters(in: .whitespaces)
                return parseValue(trimmed)
            }
            return .array(items)
        }

        if raw.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    return .string(out)
                } else {
                    out.append(ch)
                }
            }
            return nil
        }
        // Unquoted: strip a trailing comment, then try bool/number.
        let bare = raw.split(separator: "#", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
        switch bare {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return Double(bare).map(Value.number)
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"", "\\": out.append("\\\(ch)")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    static func number(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15
            ? String(Int(n)) : String(n)
    }
}
