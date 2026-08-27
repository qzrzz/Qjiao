//
//  AIToolRegistry.swift
//  kero
//
//  检测系统中已安装的 AI 桌面应用与 CLI 工具，并提供统一的"用 AI 工具打开路径"支持。
//

import AppKit
import Combine
import Foundation

// MARK: - AITool 种类

/// AI 工具类型：桌面 GUI 应用或终端 CLI 命令行工具。
enum AIToolKind: String, Codable, Sendable {
    /// 桌面 GUI 应用程序（如 Codex Desktop、Claude Desktop、Antigravity 等）。
    case desktop
    /// 命令行 CLI 工具（如 codex、agy、claude、opencode、grok 等）。
    case cli
}

// MARK: - AITool 模型

/// AI 工具描述符，代表一款检测到的桌面应用或 CLI 工具。
struct AITool: Identifiable, Equatable {
    /// 工具唯一标识符（桌面应用为 `desktop:<bundleId>`，CLI 工具为 `cli:<command>`）。
    let id: String
    /// 显示名称，如 "Codex", "Claude Code", "Antigravity", "agy"。
    let displayName: String
    /// 工具类型（.desktop / .cli）。
    let kind: AIToolKind
    /// 桌面应用 Bundle ID（Kind 为 .desktop 时使用）。
    let bundleId: String?
    /// CLI 命令名称（Kind 为 .cli 时使用），如 "agy", "claude"。
    let cliCommand: String?
    /// 无法获取图标时的回退 SF Symbol 名称。
    let symbolName: String
    /// 桌面应用在磁盘上的 URL（Kind 为 .desktop 时有效）。
    let appURL: URL?
    /// CLI 工具在系统 PATH 中的可执行文件路径（Kind 为 .cli 时有效）。
    let executablePath: String?

    /// 是否已在系统中检测到并可用。
    var isInstalled: Bool {
        switch kind {
        case .desktop:
            return appURL != nil
        case .cli:
            return executablePath != nil
        }
    }

    /// 从应用包路径或 TerminalAppIconCatalog 读取图标，生成高清实体 NSImage（支持 dark/light 切换）。
    ///
    /// - Parameters:
    ///   - size: 图标边长（逻辑点，正方形），默认 16。
    ///   - prefersLight: 外观偏好：true 表示浅色外观，false 表示深色外观；为 nil 时自动检测。
    /// - Returns: 已画好具体 Canvas 的实体像素图标；无法获取时返回 nil。
    func iconImage(size: CGFloat = 16, prefersLight: Bool? = nil) -> NSImage? {
        let targetSize = NSSize(width: size, height: size)
        let effectivePrefersLight = prefersLight ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua)

        switch kind {
        case .desktop:
            let catalog = TerminalAppIconCatalog.shared
            if let source = catalog.source(forProcessName: displayName.lowercased())
                ?? (bundleId.flatMap { catalog.source(forProcessName: $0) }),
               let rawIcon = catalog.image(for: source, pointSize: size, prefersLight: effectivePrefersLight) {
                return rawIcon.resizedHighQuality(to: targetSize)
            }
            guard let url = appURL else { return nil }
            let rawIcon = NSWorkspace.shared.icon(forFile: url.path)
            return rawIcon.resizedHighQuality(to: targetSize)

        case .cli:
            guard let cmd = cliCommand else { return nil }
            let catalog = TerminalAppIconCatalog.shared
            if let source = catalog.source(forProcessName: cmd),
               let rawIcon = catalog.image(for: source, pointSize: size, prefersLight: effectivePrefersLight) {
                return rawIcon.resizedHighQuality(to: targetSize)
            }
            return nil
        }
    }
}

// MARK: - AIToolRegistry

/// 检测并缓存系统中已安装的 AI 桌面应用与 CLI 工具。
///
/// 在主线程使用，可直接作为 `@StateObject` 或 `@ObservedObject`。
@MainActor
final class AIToolRegistry: nonisolated ObservableObject {
    /// 全局单例，与 `AppSettings.shared` 同生命周期。
    static let shared = AIToolRegistry()

    /// AI 工具原型定义（用于在 refresh 时动态探测安装状态）。
    private struct KnownToolPrototype: Sendable {
        let id: String
        let displayName: String
        let kind: AIToolKind
        let bundleId: String?
        let cliCommand: String?
        let symbolName: String
    }

    /// 所有已知预置 AI 工具的原型列表。
    private static let knownPrototypes: [KnownToolPrototype] = [
        // ── 桌面 GUI 应用
        KnownToolPrototype(id: "desktop:com.openai.codex",                displayName: "Codex",            kind: .desktop, bundleId: "com.openai.codex",                cliCommand: nil, symbolName: "cpu"),
        KnownToolPrototype(id: "desktop:com.openai.chat",                 displayName: "ChatGPT Desktop",  kind: .desktop, bundleId: "com.openai.chat",                 cliCommand: nil, symbolName: "message"),
        KnownToolPrototype(id: "desktop:com.anthropic.claude",            displayName: "Claude Code",      kind: .desktop, bundleId: "com.anthropic.claude",            cliCommand: nil, symbolName: "sparkles"),
        KnownToolPrototype(id: "desktop:com.anthropic.claudefordesktop",  displayName: "Claude Desktop",   kind: .desktop, bundleId: "com.anthropic.claudefordesktop",  cliCommand: nil, symbolName: "sparkles"),
        KnownToolPrototype(id: "desktop:dev.opencode.app",                displayName: "OpenCode",         kind: .desktop, bundleId: "dev.opencode.app",                cliCommand: nil, symbolName: "curlybraces"),
        KnownToolPrototype(id: "desktop:com.opencode.desktop",            displayName: "OpenCode App",     kind: .desktop, bundleId: "com.opencode.desktop",            cliCommand: nil, symbolName: "curlybraces"),
        KnownToolPrototype(id: "desktop:com.google.antigravity",          displayName: "Antigravity",      kind: .desktop, bundleId: "com.google.antigravity",          cliCommand: nil, symbolName: "globe.americas"),
        KnownToolPrototype(id: "desktop:com.gemini.antigravity",          displayName: "Antigravity App",  kind: .desktop, bundleId: "com.gemini.antigravity",          cliCommand: nil, symbolName: "globe.americas"),
        KnownToolPrototype(id: "desktop:com.ollama.ollama",               displayName: "Ollama",           kind: .desktop, bundleId: "com.ollama.ollama",               cliCommand: nil, symbolName: "cpu"),
        KnownToolPrototype(id: "desktop:ai.ollama.ollama",                displayName: "Ollama App",       kind: .desktop, bundleId: "ai.ollama.ollama",                cliCommand: nil, symbolName: "cpu"),

        // ── 命令行 CLI 工具
        KnownToolPrototype(id: "cli:codex",       displayName: "codex",       kind: .cli, bundleId: nil, cliCommand: "codex",       symbolName: "terminal"),
        KnownToolPrototype(id: "cli:agy",         displayName: "agy",         kind: .cli, bundleId: nil, cliCommand: "agy",         symbolName: "terminal"),
        KnownToolPrototype(id: "cli:claude",      displayName: "claude",      kind: .cli, bundleId: nil, cliCommand: "claude",      symbolName: "terminal"),
        KnownToolPrototype(id: "cli:opencode",    displayName: "opencode",    kind: .cli, bundleId: nil, cliCommand: "opencode",    symbolName: "terminal"),
        KnownToolPrototype(id: "cli:grok",        displayName: "grok",        kind: .cli, bundleId: nil, cliCommand: "grok",        symbolName: "terminal"),
        KnownToolPrototype(id: "cli:pi",          displayName: "pi",          kind: .cli, bundleId: nil, cliCommand: "pi",          symbolName: "terminal"),
        KnownToolPrototype(id: "cli:aider",       displayName: "aider",       kind: .cli, bundleId: nil, cliCommand: "aider",       symbolName: "terminal"),
        KnownToolPrototype(id: "cli:ollama",      displayName: "ollama",      kind: .cli, bundleId: nil, cliCommand: "ollama",      symbolName: "terminal"),
        KnownToolPrototype(id: "cli:copilot",     displayName: "copilot",     kind: .cli, bundleId: nil, cliCommand: "copilot",     symbolName: "terminal"),
        KnownToolPrototype(id: "cli:sgpt",        displayName: "sgpt",        kind: .cli, bundleId: nil, cliCommand: "sgpt",        symbolName: "terminal"),
        KnownToolPrototype(id: "cli:mods",        displayName: "mods",        kind: .cli, bundleId: nil, cliCommand: "mods",        symbolName: "terminal"),
        KnownToolPrototype(id: "cli:interpreter", displayName: "interpreter", kind: .cli, bundleId: nil, cliCommand: "interpreter", symbolName: "terminal"),
        KnownToolPrototype(id: "cli:fabric",      displayName: "fabric",      kind: .cli, bundleId: nil, cliCommand: "fabric",      symbolName: "terminal"),
    ]

    /// 检查指定 CLI 命令是否在系统 PATH 目录中可用，并返回绝对路径。
    private nonisolated static func findExecutable(name: String) -> String? {
        LocalAIExecutableLocator.findExecutable(name: name)
    }

    /// 系统中已检测到且可用的 AI 工具列表。
    @Published private(set) var installedTools: [AITool] = []

    /// 当前选中的首选 AI 工具 ID（从 AppSettings 读取与写回）。
    @Published var preferredToolId: String {
        didSet {
            AppSettings.shared.preferredAIToolId = preferredToolId
        }
    }

    /// 当前选中的首选 AI 工具（未指定或找不到时，回退到第一个已检测到的工具）。
    var preferredTool: AITool? {
        if let found = installedTools.first(where: { $0.id == preferredToolId }) {
            return found
        }
        return installedTools.first
    }

    private init() {
        preferredToolId = AppSettings.shared.preferredAIToolId
        refresh()
    }

    /// 重新探测并刷新已安装的 AI 工具列表。
    func refresh() {
        var list: [AITool] = []
        let ws = NSWorkspace.shared

        for proto in Self.knownPrototypes {
            switch proto.kind {
            case .desktop:
                guard let bundleId = proto.bundleId,
                      let url = ws.urlForApplication(withBundleIdentifier: bundleId) else { continue }
                list.append(
                    AITool(
                        id: proto.id,
                        displayName: proto.displayName,
                        kind: .desktop,
                        bundleId: bundleId,
                        cliCommand: nil,
                        symbolName: proto.symbolName,
                        appURL: url,
                        executablePath: nil
                    )
                )
            case .cli:
                guard let cmd = proto.cliCommand,
                      let execPath = Self.findExecutable(name: cmd) else { continue }
                list.append(
                    AITool(
                        id: proto.id,
                        displayName: proto.displayName,
                        kind: .cli,
                        bundleId: nil,
                        cliCommand: cmd,
                        symbolName: proto.symbolName,
                        appURL: nil,
                        executablePath: execPath
                    )
                )
            }
        }

        // 解析用户在设置面板中填写的自定义 CLI 工具名称
        for cmd in AppSettings.shared.customCLITools {
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // 避免与已知预设工具重复
            if !list.contains(where: { $0.cliCommand == trimmed }) {
                if let execPath = Self.findExecutable(name: trimmed) {
                    let customTool = AITool(
                        id: "cli:\(trimmed)",
                        displayName: trimmed,
                        kind: .cli,
                        bundleId: nil,
                        cliCommand: trimmed,
                        symbolName: "terminal",
                        appURL: nil,
                        executablePath: execPath
                    )
                    list.append(customTool)
                }
            }
        }

        installedTools = list
        if !preferredToolId.isEmpty,
           !installedTools.contains(where: { $0.id == preferredToolId }) {
            preferredToolId = installedTools.first?.id ?? ""
        }
    }

    /// 用指定的 AI 工具打开目标路径。
    ///
    /// - Parameters:
    ///   - path: 目标文件或目录路径。
    ///   - tool: 指定的 AI 工具（为 nil 时使用当前首选 `preferredTool`）。
    ///   - manager: 启动 CLI 工具时关联的 `TerminalManager`（用于建立终端 Tab 运行 CLI）。
    func open(path: String, with tool: AITool? = nil, terminalManager: TerminalManager? = nil) {
        guard let targetTool = tool ?? preferredTool, !path.isEmpty else { return }

        switch targetTool.kind {
        case .desktop:
            if let appURL = targetTool.appURL {
                let targetURL = URL(fileURLWithPath: path)
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: config) { _, error in
                    if let error {
                        print("[AIToolRegistry] 打开桌面应用失败: \(error.localizedDescription)")
                    }
                }
            }

        case .cli:
            guard let cmd = targetTool.cliCommand else { return }
            let cdCmd = "cd \(Self.shellQuote(path))"
            let fullCommand = "\(cdCmd) && \(cmd)"

            if let manager = terminalManager, let project = manager.selectedProject {
                // 在 Project 中新建 Session，先 cd 到目标目录，然后打开 cli（不强制锁定标题）
                let session = project.newSession(directory: path)
                session.sendCommandWhenReady("\(fullCommand)\n")
            } else {
                // 回退机制：使用 Process 直接通过 Terminal 启动
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "Terminal", path]
                try? process.run()
                // 等待退出并回收，避免僵尸进程累积（open 自身毫秒级退出）
                process.waitUntilExit()
            }
        }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" || $0 == "-" || $0 == "." }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
