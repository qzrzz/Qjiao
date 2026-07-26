//
//  CodeEditorRegistry.swift
//  kero
//
//  检测系统中已安装的代码编辑器，并提供统一的"用编辑器打开"动作。
//

import AppKit
import Combine
import Foundation

// MARK: - CodeEditor 模型

/// 代码编辑器描述符，代表一款可检测到的编辑器。
struct CodeEditor: Identifiable, Equatable {
    /// Bundle ID，同时作为唯一标识符。
    let bundleId: String
    /// 显示名称，如 "VS Code"。
    let displayName: String
    /// 用于界面的 SF Symbol 图标名称。
    let symbolName: String
    /// 应用程序在磁盘上的 URL（nil 表示未安装）。
    let appURL: URL?

    var id: String { bundleId }
    /// 是否已安装。
    var isInstalled: Bool { appURL != nil }
}

// MARK: - CodeEditorRegistry

/// 检测并缓存系统中已安装的代码编辑器列表。
///
/// 在主线程使用，可直接作为 `@StateObject` 或 `@ObservedObject`。
@MainActor
final class CodeEditorRegistry: nonisolated ObservableObject {
    /// 全局单例，与 `AppSettings.shared` 同生命周期。
    static let shared = CodeEditorRegistry()

    /// 所有已知编辑器（按优先级排列）——始终包含全部条目，安装状态由 `isInstalled` 判断。
    private static let knownEditors: [CodeEditor] = {
        let ws = NSWorkspace.shared
        /// 从 bundle ID 解析安装 URL 并构造 CodeEditor。
        func make(
            _ bundleId: String,
            name: String,
            symbol: String
        ) -> CodeEditor {
            let url = ws.urlForApplication(withBundleIdentifier: bundleId)
            return CodeEditor(
                bundleId: bundleId,
                displayName: name,
                symbolName: symbol,
                appURL: url
            )
        }

        return [
            make("com.microsoft.VSCode",          name: "VS Code",        symbol: "chevron.left.forwardslash.chevron.right"),
            make("com.microsoft.VSCodeInsiders",   name: "VS Code Insiders", symbol: "chevron.left.forwardslash.chevron.right"),
            make("com.todesktop.230313mzl4w4u92",  name: "Cursor",         symbol: "cursorarrow.rays"),
            make("com.exafunction.windsurf",        name: "Windsurf",       symbol: "wind"),
            make("dev.zed.Zed",                     name: "Zed",            symbol: "bolt"),
            make("dev.zed.Zed-Preview",             name: "Zed Preview",    symbol: "bolt"),
            make("com.sublimetext.4",               name: "Sublime Text",   symbol: "s.circle"),
            make("com.sublimetext.3",               name: "Sublime Text 3", symbol: "s.circle"),
            make("com.jetbrains.WebStorm",          name: "WebStorm",       symbol: "globe"),
            make("com.jetbrains.intellij",          name: "IntelliJ IDEA",  symbol: "globe"),
            make("com.jetbrains.PyCharm",           name: "PyCharm",        symbol: "globe"),
            make("com.jetbrains.CLion",             name: "CLion",          symbol: "globe"),
            make("com.jetbrains.GoLand",            name: "GoLand",         symbol: "globe"),
            make("com.jetbrains.PhpStorm",          name: "PhpStorm",       symbol: "globe"),
            make("com.jetbrains.RubyMine",          name: "RubyMine",       symbol: "globe"),
            make("com.jetbrains.rider",             name: "Rider",          symbol: "globe"),
            make("com.jetbrains.AndroidStudio",     name: "Android Studio", symbol: "globe"),
            make("com.github.atom",                 name: "Atom",           symbol: "a.circle"),
            make("com.panic.Nova",                  name: "Nova",           symbol: "n.circle"),
            make("com.barebones.BBEdit",            name: "BBEdit",         symbol: "b.circle"),
            make("com.coteditor.CotEditor",         name: "CotEditor",      symbol: "c.circle"),
            make("com.macromates.TextMate",         name: "TextMate",       symbol: "t.circle"),
            make("com.apple.dt.Xcode",              name: "Xcode",          symbol: "hammer"),
        ]
    }()

    /// 系统中已安装的编辑器列表（已过滤掉未安装的）。
    @Published private(set) var installedEditors: [CodeEditor] = []

    /// 当前选中的默认编辑器 bundle ID（从 AppSettings 读取）。
    @Published var preferredBundleId: String {
        didSet {
            // 同步写回 AppSettings 以持久化。
            AppSettings.shared.preferredCodeEditorBundleId = preferredBundleId
        }
    }

    /// 当前选中的默认编辑器（首选已安装、未安装则回退到第一个已安装的编辑器）。
    var preferredEditor: CodeEditor? {
        // 先按 bundle ID 查找已安装编辑器。
        if let found = installedEditors.first(where: { $0.bundleId == preferredBundleId }) {
            return found
        }
        // 回退到第一个已安装编辑器。
        return installedEditors.first
    }

    private init() {
        preferredBundleId = AppSettings.shared.preferredCodeEditorBundleId
        refresh()
    }

    /// 刷新已安装编辑器列表（在 launch 或每次显示时调用一次即可）。
    func refresh() {
        installedEditors = Self.knownEditors.filter(\.isInstalled)
        // 校验当前首选是否仍安装；若未安装则自动切换到第一个已安装的。
        if !preferredBundleId.isEmpty,
           !installedEditors.contains(where: { $0.bundleId == preferredBundleId }) {
            preferredBundleId = installedEditors.first?.bundleId ?? ""
        }
    }

    /// 用指定编辑器打开路径。
    ///
    /// - Parameters:
    ///   - path: 要打开的文件或目录路径。
    ///   - editor: 目标编辑器；传 nil 时使用 `preferredEditor`。
    func open(path: String, with editor: CodeEditor? = nil) {
        let target = editor ?? preferredEditor
        guard !path.isEmpty, let target, let appURL = target.appURL else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
