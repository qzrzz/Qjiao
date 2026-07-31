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

    /// 从应用包路径或 TerminalAppIconCatalog 读取图标，生成高清实体 NSImage。
    ///
    /// - Parameter size: 图标边长（逻辑点，正方形），默认 16。
    /// - Returns: 已画好具体 Canvas 的实体像素图标；无法获取时返回 nil。
    func iconImage(size: CGFloat = 16) -> NSImage? {
        let targetSize = NSSize(width: size, height: size)

        switch kind {
        case .desktop:
            guard let url = appURL else { return nil }
            let rawIcon = NSWorkspace.shared.icon(forFile: url.path)
            var proposedRect = CGRect(origin: .zero, size: targetSize)
            if let cgImage = rawIcon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                bitmapRep.size = targetSize
                let image = NSImage(size: targetSize)
                image.addRepresentation(bitmapRep)
                return image
            }
            let image = NSImage(size: targetSize)
            image.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            rawIcon.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
            image.unlockFocus()
            return image

        case .cli:
            guard let cmd = cliCommand else { return nil }
            // 尝试通过 TerminalAppIconCatalog 读取配置的专属图标（如 material icon / 本地图标文件）
            if let source = TerminalAppIconCatalog.shared.source(forProcessName: cmd),
               let rawIcon = TerminalAppIconCatalog.shared.image(for: source, pointSize: size) {
                var proposedRect = CGRect(origin: .zero, size: targetSize)
                if let cgImage = rawIcon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                    bitmapRep.size = targetSize
                    let image = NSImage(size: targetSize)
                    image.addRepresentation(bitmapRep)
                    return image
                }
                return rawIcon
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

    /// 常见 PATH 路径列表，用于探测 CLI 可执行文件。
    private nonisolated static let commonPathDirectories: [String] = {
        var dirs = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dirs.append("\(home)/.bun/bin")
        dirs.append("\(home)/.cargo/bin")
        dirs.append("\(home)/.local/bin")
        dirs.append("\(home)/.npm-global/bin")
        // pi：curl 安装脚本在无系统 node 时自带的独立 node
        dirs.append("\(home)/.local/share/pi-node/current/bin")
        dirs.append("\(home)/.gemini/antigravity/bin")
        dirs.append("\(home)/.antigravity/bin")
        dirs.append("\(home)/.opencode/bin")
        dirs.append("\(home)/.claude/bin")

        // 尝试解析用户 PATH 环境变量中的额外路径
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            let envDirs = envPath.split(separator: ":").map(String.init)
            for d in envDirs where !dirs.contains(d) {
                dirs.append(d)
            }
        }
        return dirs
    }()

    /// 检查指定 CLI 命令是否在系统 PATH 目录中可用，并返回绝对路径。
    private nonisolated static func findExecutable(name: String) -> String? {
        let fm = FileManager.default
        for dir in commonPathDirectories {
            let path = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// 所有已知 AI 工具原型定义（按桌面应用与 CLI 分组排列）。
    private nonisolated static let knownTools: [AITool] = {
        let ws = NSWorkspace.shared

        /// 构造桌面 GUI 应用定义
        func desktop(_ bundleId: String, name: String, symbol: String) -> AITool {
            let url = ws.urlForApplication(withBundleIdentifier: bundleId)
            return AITool(
                id: "desktop:\(bundleId)",
                displayName: name,
                kind: .desktop,
                bundleId: bundleId,
                cliCommand: nil,
                symbolName: symbol,
                appURL: url,
                executablePath: nil
            )
        }

        /// 构造 CLI 工具定义
        func cli(_ command: String, name: String, symbol: String) -> AITool {
            let path = findExecutable(name: command)
            return AITool(
                id: "cli:\(command)",
                displayName: name,
                kind: .cli,
                bundleId: nil,
                cliCommand: command,
                symbolName: symbol,
                appURL: nil,
                executablePath: path
            )
        }

        return [
            // ── 桌面 GUI 应用
            desktop("com.openai.codex",                name: "Codex",            symbol: "cpu"),
            desktop("com.openai.chat",                 name: "ChatGPT Desktop",  symbol: "message"),
            desktop("com.anthropic.claude",            name: "Claude Code",      symbol: "sparkles"),
            desktop("com.anthropic.claudefordesktop",  name: "Claude Desktop",   symbol: "sparkles"),
            desktop("dev.opencode.app",                name: "OpenCode",         symbol: "curlybraces"),
            desktop("com.opencode.desktop",            name: "OpenCode App",     symbol: "curlybraces"),
            desktop("com.google.antigravity",          name: "Antigravity",      symbol: "globe.americas"),
            desktop("com.gemini.antigravity",          name: "Antigravity App",  symbol: "globe.americas"),

            // ── 命令行 CLI 工具
            cli("codex",       name: "codex",       symbol: "terminal"),
            cli("agy",         name: "agy",         symbol: "terminal"),
            cli("claude",      name: "claude",      symbol: "terminal"),
            cli("opencode",    name: "opencode",    symbol: "terminal"),
            cli("grok",        name: "grok",        symbol: "terminal"),
            cli("pi",          name: "pi",          symbol: "terminal"),
            cli("aider",       name: "aider",       symbol: "terminal"),
            cli("ollama",      name: "ollama",      symbol: "terminal"),
            cli("copilot",     name: "copilot",     symbol: "terminal"),
            cli("sgpt",        name: "sgpt",        symbol: "terminal"),
            cli("mods",        name: "mods",        symbol: "terminal"),
            cli("interpreter", name: "interpreter", symbol: "terminal"),
            cli("fabric",      name: "fabric",      symbol: "terminal"),
        ]
    }()

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
        var list = Self.knownTools.filter(\.isInstalled)

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
            let cdCmd = "cd \(shellQuote(path))"
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
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" || $0 == "-" || $0 == "." }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
