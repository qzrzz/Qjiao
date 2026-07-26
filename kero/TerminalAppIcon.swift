//
//  TerminalAppIcon.swift
//  kero
//
//  终端前台进程图标：按进程可执行文件名匹配 Material Icon Theme 或
//  本地图标文件（PNG / SVG 等，含 Iconify Boxicons Brands）。
//  配置见 kero/TerminalAppIcons/apps.json 与用户侧 terminal-app-icons.json。
//

import AppKit
import SwiftUI

// MARK: - Source

/// 解析后的终端应用图标来源；可哈希以便按尺寸缓存 NSImage。
enum TerminalAppIconSource: Hashable, Sendable {
    /// Material Icon Theme 逻辑名（如 `nodejs`、`claude`）。
    case material(String)
    /// 本地图标文件绝对路径（`.png` / `.svg` / `.icns` 等）。
    case imageFile(path: String)
}

// MARK: - Catalog

/// 加载 `apps.json` 与图标文件，按进程名解析；图标与匹配表均缓存。
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
        /// 推荐：`icons/` 下的文件名，如 `antigravity-color.png`、`rsbuild.svg`。
        var icon: String?
        /// 兼容旧字段，等同于 `icon`。
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
        // 不丢 imageCache：文件路径不变时复用光栅结果。

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

    /// 对多个候选名匹配图标。优先具体 CLI（rsbuild），弱化 node/npm 等运行时。
    func source(forProcessNames processNames: [String]) -> TerminalAppIconSource? {
        var weakRuntimeSource: TerminalAppIconSource?
        for name in processNames {
            guard let source = source(forProcessName: name) else { continue }
            if Self.isWeakRuntimeName(name) {
                if weakRuntimeSource == nil { weakRuntimeSource = source }
                continue
            }
            return source
        }
        return weakRuntimeSource
    }

    /// node/npm 等：仅在没有更具体 CLI 名时才作为图标。
    nonisolated static func isWeakRuntimeName(_ name: String) -> Bool {
        var key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("-") { key.removeFirst() }
        if key.contains("/") {
            key = (key as NSString).lastPathComponent
        }
        for ext in ["js", "mjs", "cjs", "ts"] {
            if key.hasSuffix("." + ext) {
                key = String(key.dropLast(ext.count + 1))
            }
        }
        if key.hasPrefix("python") { return true }
        return [
            "node", "nodejs", "bun", "deno",
            "npm", "npx", "pnpm", "yarn", "bunx",
            "tsx", "ts-node", "ruby", "php", "perl", "lua",
        ].contains(key)
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
        // npm scope：@rsbuild → rsbuild
        if key.hasPrefix("@") {
            key.removeFirst()
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
        case .imageFile(let path):
            cacheKey = "file:\(path)@\(sizeKey)"
        }
        if let hit = imageCache[cacheKey] { return hit }

        let image: NSImage?
        switch source {
        case .material(let name):
            image = MaterialFileIconCatalog.shared.image(named: name, pointSize: pointSize)
        case .imageFile(let path):
            image = loadImageFile(path: path, pointSize: pointSize)
        }
        if let image {
            imageCache[cacheKey] = image
        }
        return image
    }

    /// 单色（currentColor）SVG 应用 template 渲染，便于随主题着色；PNG 等位图始终原色。
    func isTemplate(_ source: TerminalAppIconSource) -> Bool {
        switch source {
        case .material:
            return false
        case .imageFile(let path):
            if let cached = templateFlags[path] { return cached }
            let flag = path.lowercased().hasSuffix(".svg") && Self.svgUsesCurrentColor(path: path)
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
            guard let source = resolveSource(entry, isUser: isUser) else {
                #if DEBUG
                print("TerminalAppIcon: skip entry \(entry.label ?? entry.match?.first ?? "?") — no resolvable icon")
                #endif
                continue
            }
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
        // 优先级：icon（推荐）> svg（兼容）> iconify > material
        let fileName = [entry.icon, entry.svg]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let fileName, let url = locateIconFile(fileName: fileName, preferUser: isUser) {
            return .imageFile(path: url.path)
        }
        if let iconify = entry.iconify?.trimmingCharacters(in: .whitespacesAndNewlines), !iconify.isEmpty {
            let name = Self.iconifyFileName(iconify)
            if let url = locateIconFile(fileName: name, preferUser: isUser) {
                return .imageFile(path: url.path)
            }
        }
        if let material = entry.material?.trimmingCharacters(in: .whitespacesAndNewlines), !material.isEmpty {
            return .material(material)
        }
        return nil
    }

    private func locateIconFile(fileName: String, preferUser: Bool) -> URL? {
        let fm = FileManager.default
        // 允许 `icons/foo.png` 或直接 `foo.png`
        let relative = fileName.hasPrefix("icons/") ? fileName : fileName
        let bare = (relative as NSString).lastPathComponent
        let candidates: [URL] = preferUser
            ? [
                userIconsDirectory.appendingPathComponent(bare),
                userIconsDirectory.appendingPathComponent(relative),
                bundledIconsDirectory?.appendingPathComponent(bare),
                bundledIconsDirectory?.appendingPathComponent(relative),
            ].compactMap { $0 }
            : [
                bundledIconsDirectory?.appendingPathComponent(bare),
                bundledIconsDirectory?.appendingPathComponent(relative),
                userIconsDirectory.appendingPathComponent(bare),
                userIconsDirectory.appendingPathComponent(relative),
            ].compactMap { $0 }

        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private func loadImageFile(path: String, pointSize: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let base = NSImage(contentsOf: url) else { return nil }
        let sized = base.copy() as? NSImage ?? base
        // 保持宽高比：以较长边缩放到 pointSize。
        let src = sized.size
        if src.width > 0, src.height > 0 {
            let scale = pointSize / max(src.width, src.height)
            sized.size = NSSize(width: src.width * scale, height: src.height * scale)
        } else {
            sized.size = NSSize(width: pointSize, height: pointSize)
        }
        if path.lowercased().hasSuffix(".svg"), Self.svgUsesCurrentColor(path: path) {
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
        // 同步根可能保留 TerminalAppIcons/icons，也可能把图标摊平到 Resources。
        let candidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("TerminalAppIcons/icons", isDirectory: true),
            bundle.resourceURL?.appendingPathComponent("icons", isDirectory: true),
            bundle.resourceURL,
        ]
        // 用若干已知文件探测可用目录（含 SVG 与 PNG）。
        let probes = [
            "bxl-openai.svg", "bxl-xai.svg", "bxl-github.svg",
            "rsbuild.svg", "antigravity-color.png",
        ]
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

    private static let scriptExtensions = [
        ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".py", ".rb", ".mjs",
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

    /// 收集前台进程组内所有进程的可执行名 / 脚本名，用于图标匹配。
    ///
    /// `foregroundPgid` 来自 Ghostty 的 `tcgetpgrp`（进程组 ID，不等于业务 PID）。
    /// 典型：`npm run dev` 的组长是 npm，真正的 `node …/rsbuild` 是同组其它进程；
    /// 必须枚举整组，不能只看 leader，也不能依赖不可靠的 `proc_listchildpids`。
    nonisolated static func foregroundExecutableNames(
        shellPid: pid_t,
        foregroundPgid: pid_t
    ) -> [String] {
        var ordered: [String] = []
        var seenNames = Set<String>()
        var seenPids = Set<pid_t>()

        func appendName(_ raw: String) {
            let key = raw.lowercased()
            let normalized = key.hasPrefix("-") ? String(key.dropFirst()) : key
            if normalized.isEmpty || shellNames.contains(normalized) { return }
            if seenNames.insert(normalized).inserted {
                ordered.append(raw)
            }
        }

        func consider(_ pid: pid_t) {
            guard pid > 1, !seenPids.contains(pid) else { return }
            seenPids.insert(pid)
            for name in identityCandidates(pid: pid) {
                appendName(name)
            }
        }

        // 1) 前台进程组内全部 PID（含 npm 拉起的 node/rsbuild）
        for pid in pids(inProcessGroup: foregroundPgid) {
            consider(pid)
        }
        // 2) 组 leader 兜底（组查询失败时）
        consider(foregroundPgid)
        // 3) shell 自身（一般无业务意义，忽略）
        _ = shellPid

        return ordered
    }

    /// `KERN_PROC_PGRP`：枚举同一进程组的全部 PID。
    nonisolated private static func pids(inProcessGroup pgid: pid_t) -> [pid_t] {
        guard pgid > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = size / stride
        guard count > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var sz = size
        let ok = procs.withUnsafeMutableBufferPointer { buf -> Bool in
            sysctl(&mib, 4, buf.baseAddress, &sz, nil, 0) == 0
        }
        guard ok else { return [] }
        let n = sz / stride
        return procs.prefix(n).map(\.kp_proc.p_pid).filter { $0 > 1 }
    }

    /// 单个进程的匹配候选：argv 路径片段（`…/@rsbuild/core/bin/rsbuild.js`）优先于可执行名 `node`。
    nonisolated private static func identityCandidates(pid: pid_t) -> [String] {
        guard let execBase = executableBaseName(pid: pid) else { return [] }
        var names: [String] = []
        func appendUnique(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if !names.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                names.append(t)
            }
        }

        // 始终扫 argv：`node …/rsbuild`、`node …/@rsbuild/core/bin/rsbuild.js`
        for arg in processArguments(pid: pid) {
            if arg.hasPrefix("-") { continue }
            if arg.contains("="), !arg.contains("/") { continue }
            // npm 有时把整句塞进一个 argv：`npm run dev`
            let pieces: [String]
            if arg.contains("/"), !arg.contains(" ") {
                pieces = [arg]
            } else {
                pieces = arg.split(whereSeparator: \.isWhitespace).map(String.init)
            }
            for piece in pieces {
                if piece.hasPrefix("-") { continue }
                for token in pathMatchTokens(piece) {
                    appendUnique(token)
                }
            }
        }
        appendUnique(execBase)
        return names
    }

    nonisolated private static func isInterpreter(_ baseName: String) -> Bool {
        TerminalAppIconCatalog.isWeakRuntimeName(baseName)
    }

    /// 从参数路径抽出可匹配 token：basename、路径段、去掉 `@` 的 scope（@rsbuild）。
    nonisolated private static func pathMatchTokens(_ arg: String) -> [String] {
        var tokens: [String] = []
        func appendToken(_ raw: String) {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if t.hasPrefix("@") { t = String(t.dropFirst()) }
            let lower = t.lowercased()
            for ext in scriptExtensions where lower.hasSuffix(ext) {
                t = String(t.dropLast(ext.count))
                break
            }
            guard t.count >= 2 else { return }
            let key = t.lowercased()
            // 过滤路径噪音，避免 `dev` / `bin` 误匹配。
            let noise: Set<String> = [
                "bin", "lib", "dist", "src", "node_modules", "packages", "cli",
                "index", "main", "run", "dev", "build", "start", "test", "preview",
                "core", "dist-types", "types", "scripts", "cmd", "commands",
            ]
            if noise.contains(key) { return }
            if isInterpreter(key) || shellNames.contains(key) { return }
            if !tokens.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                tokens.append(t)
            }
        }

        appendToken((arg as NSString).lastPathComponent)
        if arg.contains("/") {
            for part in arg.split(separator: "/", omittingEmptySubsequences: true) {
                appendToken(String(part))
            }
        } else {
            appendToken(arg)
        }
        return tokens
    }

    /// 读取 `KERN_PROCARGS2` 得到 argv 列表（不含环境变量）。
    nonisolated private static func processArguments(pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            var sz = size
            return sysctl(&mib, u_int(mib.count), raw.baseAddress, &sz, nil, 0) == 0
        }
        guard ok else { return [] }

        let argc = buffer.withUnsafeBytes { ptr -> Int in
            Int(ptr.load(as: Int32.self))
        }
        guard argc > 0, argc < 4096 else { return [] }

        var offset = MemoryLayout<Int32>.size
        // 跳过 exec_path（NUL 结尾）
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
        offset += 1
        // 跳过对齐用的多余 NUL
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }

        var args: [String] = []
        args.reserveCapacity(argc)
        for _ in 0..<argc {
            guard offset < buffer.count else { break }
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
            if start < offset,
               let s = String(bytes: buffer[start..<offset], encoding: .utf8),
               !s.isEmpty
            {
                args.append(s)
            }
            offset += 1
        }
        return args
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
