//
//  TerminalAppIcon.swift
//  kero
//
//  终端前台进程图标：按进程可执行文件名匹配 Material Icon Theme 或
//  本地 SVG（含 Iconify Boxicons Brands 等 vendored 资源）。
//  配置见 kero/TerminalAppIcons/apps.json 与用户侧 terminal-app-icons.json。
//

import AppKit
import SwiftUI

// MARK: - Source

/// 解析后的终端应用图标来源；可哈希以便按尺寸缓存 NSImage。
enum TerminalAppIconSource: Hashable, Sendable {
    /// Material Icon Theme 逻辑名（如 `nodejs`、`claude`）。
    case material(String)
    /// 本地 SVG 绝对路径。
    case svgFile(path: String)
}

// MARK: - Catalog

/// 加载 `apps.json` 与 SVG，按进程名解析图标；图标与匹配表均缓存。
@MainActor
final class TerminalAppIconCatalog {
    static let shared = TerminalAppIconCatalog()

    private struct Manifest: Decodable {
        var version: Int?
        var apps: [AppEntry]
    }

    private struct AppEntry: Decodable {
        var label: String?
        var match: [String]?
        var matchPrefix: [String]?
        var material: String?
        var iconify: String?
        var svg: String?
    }

    private struct ResolvedRule {
        let source: TerminalAppIconSource
    }

    /// 精确匹配：lowercased process name → 规则（用户配置优先，后写覆盖）。
    private var exactMap: [String: ResolvedRule] = [:]
    /// 前缀匹配：按前缀长度降序，避免短前缀抢先。
    private var prefixRules: [(prefix: String, rule: ResolvedRule)] = []
    /// NSImage 缓存：source + pointSize。
    private var imageCache: [String: NSImage] = [:]
    /// SVG 是否应按 template 绘制（含 currentColor 的单色品牌图标）。
    private var templateFlags: [String: Bool] = [:]

    private let bundledIconsDirectory: URL?
    private let userIconsDirectory: URL

    private init() {
        let bundle = Bundle.main
        bundledIconsDirectory = Self.locateBundledIconsDirectory(in: bundle)
        userIconsDirectory = Self.userConfigDirectory()
            .appendingPathComponent("terminal-app-icons", isDirectory: true)

        reload()
    }

    /// 重新加载内置与用户配置（修改配置文件后可调用）。
    func reload() {
        exactMap.removeAll(keepingCapacity: true)
        prefixRules.removeAll(keepingCapacity: true)
        // 不丢 imageCache：SVG 路径不变时复用光栅结果。

        if let bundled = Self.locateBundledManifest(in: Bundle.main) {
            applyManifest(at: bundled, isUser: false)
        }
        let userManifest = Self.userConfigDirectory()
            .appendingPathComponent("terminal-app-icons.json")
        if FileManager.default.fileExists(atPath: userManifest.path) {
            applyManifest(at: userManifest, isUser: true)
        }

        prefixRules.sort { $0.prefix.count > $1.prefix.count }
    }

    /// 按进程可执行文件 basename 查找图标来源；未配置时返回 nil。
    /// 支持精确名、配置的 `matchPrefix`，以及版本化二进制（`grok-0.2.1-macos-…` → `grok`）。
    func source(forProcessName processName: String) -> TerminalAppIconSource? {
        let key = Self.normalizeProcessName(processName)
        if key.isEmpty { return nil }
        if let rule = exactMap[key] { return rule.source }
        // 版本化 / 平台后缀：`grok-0.2.112-macos-aarch64`、`codex-aarch64-apple-darwin`
        if let stem = Self.commandStem(key), let rule = exactMap[stem] {
            return rule.source
        }
        for item in prefixRules where key.hasPrefix(item.prefix) {
            return item.rule.source
        }
        return nil
    }

    /// 对多个候选进程名依次匹配（前台组 / 子进程树），返回第一个命中。
    func source(forProcessNames processNames: [String]) -> TerminalAppIconSource? {
        for name in processNames {
            if let source = source(forProcessName: name) {
                return source
            }
        }
        return nil
    }

    /// 规范化：小写，去掉开头的 `-`（login shell 常见 `-zsh`）。
    private static func normalizeProcessName(_ name: String) -> String {
        var key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("-") {
            key.removeFirst()
        }
        // 路径误入时只取 basename
        if key.contains("/") {
            key = (key as NSString).lastPathComponent
        }
        return key
    }

    /// `grok-0.2.112-macos-aarch64` → `grok`；无 `-` 时返回 nil。
    private static func commandStem(_ normalized: String) -> String? {
        guard let dash = normalized.firstIndex(of: "-") else { return nil }
        let stem = String(normalized[..<dash])
        // 过短的 stem（如 `c`）不可靠
        guard stem.count >= 2 else { return nil }
        return stem
    }

    /// 加载指定来源的图标；`pointSize` 为显示逻辑点。
    func image(for source: TerminalAppIconSource, pointSize: CGFloat) -> NSImage? {
        let sizeKey = String(format: "%.1f", pointSize)
        let cacheKey: String
        switch source {
        case .material(let name):
            cacheKey = "material:\(name)@\(sizeKey)"
        case .svgFile(let path):
            cacheKey = "svg:\(path)@\(sizeKey)"
        }
        if let hit = imageCache[cacheKey] { return hit }

        let image: NSImage?
        switch source {
        case .material(let name):
            image = MaterialFileIconCatalog.shared.image(named: name, pointSize: pointSize)
        case .svgFile(let path):
            image = loadSVG(path: path, pointSize: pointSize)
        }
        if let image {
            imageCache[cacheKey] = image
        }
        return image
    }

    /// 单色（currentColor）SVG 应用 template 渲染，便于随主题着色。
    func isTemplate(_ source: TerminalAppIconSource) -> Bool {
        switch source {
        case .material:
            return false
        case .svgFile(let path):
            if let cached = templateFlags[path] { return cached }
            let flag = Self.svgUsesCurrentColor(path: path)
            templateFlags[path] = flag
            return flag
        }
    }

    // MARK: - Load config

    private func applyManifest(at url: URL, isUser: Bool) {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            #if DEBUG
            print("TerminalAppIcon: failed to load \(url.path)")
            #endif
            return
        }

        for entry in manifest.apps {
            guard let source = resolveSource(entry, isUser: isUser) else { continue }
            let rule = ResolvedRule(source: source)
            for raw in entry.match ?? [] {
                let key = raw.lowercased()
                guard !key.isEmpty else { continue }
                // 用户配置覆盖内置；同一文件内后者覆盖前者。
                exactMap[key] = rule
            }
            for raw in entry.matchPrefix ?? [] {
                let prefix = raw.lowercased()
                guard !prefix.isEmpty else { continue }
                if isUser {
                    prefixRules.removeAll { $0.prefix == prefix }
                } else if prefixRules.contains(where: { $0.prefix == prefix }) {
                    continue
                }
                prefixRules.append((prefix, rule))
            }
        }
    }

    private func resolveSource(_ entry: AppEntry, isUser: Bool) -> TerminalAppIconSource? {
        // 优先级：svg > iconify > material
        if let svg = entry.svg?.trimmingCharacters(in: .whitespacesAndNewlines), !svg.isEmpty {
            if let url = locateSVG(fileName: svg, preferUser: isUser) {
                return .svgFile(path: url.path)
            }
        }
        if let iconify = entry.iconify?.trimmingCharacters(in: .whitespacesAndNewlines), !iconify.isEmpty {
            let fileName = Self.iconifyFileName(iconify)
            if let url = locateSVG(fileName: fileName, preferUser: isUser) {
                return .svgFile(path: url.path)
            }
        }
        if let material = entry.material?.trimmingCharacters(in: .whitespacesAndNewlines), !material.isEmpty {
            return .material(material)
        }
        return nil
    }

    private func locateSVG(fileName: String, preferUser: Bool) -> URL? {
        let fm = FileManager.default
        let candidates: [URL] = preferUser
            ? [
                userIconsDirectory.appendingPathComponent(fileName),
                bundledIconsDirectory?.appendingPathComponent(fileName),
            ].compactMap { $0 }
            : [
                bundledIconsDirectory?.appendingPathComponent(fileName),
                userIconsDirectory.appendingPathComponent(fileName),
            ].compactMap { $0 }

        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private func loadSVG(path: String, pointSize: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let base = NSImage(contentsOf: url) else { return nil }
        let sized = base.copy() as? NSImage ?? base
        sized.size = NSSize(width: pointSize, height: pointSize)
        if Self.svgUsesCurrentColor(path: path) {
            sized.isTemplate = true
        }
        return sized
    }

    // MARK: - Paths

    private static func userConfigDirectory() -> URL {
        AppSettings.configURL.deletingLastPathComponent()
    }

    private static func locateBundledManifest(in bundle: Bundle) -> URL? {
        let candidates: [URL?] = [
            bundle.url(forResource: "apps", withExtension: "json", subdirectory: "TerminalAppIcons"),
            bundle.url(forResource: "apps", withExtension: "json"),
            bundle.resourceURL?.appendingPathComponent("TerminalAppIcons/apps.json"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func locateBundledIconsDirectory(in bundle: Bundle) -> URL? {
        let fm = FileManager.default
        // 同步根可能保留 TerminalAppIcons/icons，也可能把 SVG 摊平到 Resources。
        let candidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("TerminalAppIcons/icons", isDirectory: true),
            bundle.resourceURL?.appendingPathComponent("icons", isDirectory: true),
            bundle.resourceURL,
        ]
        // 用内置 apps.json 引用过的 Iconify 文件探测可用目录。
        let probes = ["bxl-openai.svg", "bxl-xai.svg", "bxl-github.svg"]
        for dir in candidates.compactMap({ $0 }) {
            if probes.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
                return dir
            }
        }
        return nil
    }

    /// `bxl:openai` → `bxl-openai.svg`
    static func iconifyFileName(_ iconify: String) -> String {
        let trimmed = iconify.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".svg") { return trimmed }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return "\(parts[0])-\(parts[1]).svg"
        }
        return "\(trimmed).svg"
    }

    private static func svgUsesCurrentColor(path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count < 512_000,
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.range(of: "currentColor", options: .caseInsensitive) != nil
    }
}

// MARK: - Process name

enum TerminalProcessIdentity {
    private static let shellNames: Set<String> = [
        "zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash",
        "login", "script", "env",
    ]

    /// 读取进程可执行路径的 basename；失败时回退 `proc_name`。
    nonisolated static func executableBaseName(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLen > 0 {
            let path = String(cString: pathBuffer)
            let base = (path as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLen = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLen > 0 {
            let name = String(cString: nameBuffer)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// 收集前台进程组 leader 与 shell 子进程树中的可执行名，用于图标匹配。
    /// `foregroundPgid` 来自 Ghostty 的 `tcgetpgrp`，不一定等于实际业务进程 PID。
    nonisolated static func foregroundExecutableNames(
        shellPid: pid_t,
        foregroundPgid: pid_t
    ) -> [String] {
        var ordered: [String] = []
        var seenNames = Set<String>()
        var seenPids = Set<pid_t>()

        func consider(_ pid: pid_t) {
            guard pid > 1, !seenPids.contains(pid) else { return }
            seenPids.insert(pid)
            guard let base = executableBaseName(pid: pid) else { return }
            let key = base.lowercased()
            // 跳过 shell / login 本身，避免盖住真实前台程序。
            let normalized = key.hasPrefix("-") ? String(key.dropFirst()) : key
            if shellNames.contains(normalized) { return }
            if seenNames.insert(base).inserted {
                ordered.append(base)
            }
        }

        // 1) 前台进程组 leader（常见情况 leader == 业务进程）
        consider(foregroundPgid)

        // 2) shell 子进程树（深度有限）：覆盖 spawn 出的真实二进制、管道成员等
        var queue: [(pid: pid_t, depth: Int)] = [(shellPid, 0)]
        var index = 0
        while index < queue.count {
            let item = queue[index]
            index += 1
            if item.depth >= 5 { continue }
            for child in listChildPids(item.pid) {
                // 优先看仍处于前台进程组的孩子；其余子进程也记录，便于 node→native 包装。
                consider(child)
                if item.depth + 1 < 5 {
                    queue.append((child, item.depth + 1))
                }
            }
        }

        return ordered
    }

    /// `proc_listchildpids`：返回直接子进程 PID 列表。
    nonisolated private static func listChildPids(_ pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        // 先探测需要的字节数；失败时用固定上限再试一次。
        let probe = proc_listchildpids(pid, nil, 0)
        let byteCount: Int
        if probe > 0 {
            byteCount = Int(probe)
        } else {
            byteCount = 64 * MemoryLayout<pid_t>.size
        }
        var buffer = [pid_t](repeating: 0, count: max(1, byteCount / MemoryLayout<pid_t>.size))
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return 0 }
            return proc_listchildpids(pid, base, Int32(ptr.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.size
        return Array(buffer.prefix(count)).filter { $0 > 0 }
    }
}

// MARK: - SwiftUI

/// 终端应用图标视图；找不到资源时回退 SF Symbol `terminal`。
struct TerminalAppIconView: View {
    let source: TerminalAppIconSource
    var size: CGFloat = 12
    var isSelected: Bool = true

    var body: some View {
        let catalog = TerminalAppIconCatalog.shared
        if let image = catalog.image(for: source, pointSize: size) {
            let template = catalog.isTemplate(source)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .renderingMode(template ? .template : .original)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(
                    template
                        ? AnyShapeStyle(isSelected ? Color(nsColor: Theme.cursor) : Color.secondary)
                        : AnyShapeStyle(Color.primary)
                )
                .opacity(isSelected || template ? 1 : 0.72)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.85, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: Theme.cursor) : Color.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
