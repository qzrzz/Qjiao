//
//  ProjectScriptEngine.swift
//  kero
//
//  多语言工程脚本执行引擎（支持 NPM, Gradle, uv, PDM, Rust alias, Makefile 等）
//

import CryptoKit
import Foundation
import GhosttyTerminal
import SwiftUI

// MARK: - 脚本分类枚举

/// 项目可执行脚本/任务来源分类
public enum ProjectScriptCategory: String, Codable, CaseIterable, Identifiable {
    case npm = "npm"
    case gradle = "Gradle"
    case just = "Just"
    case uv = "uv"
    case pdm = "PDM"
    case rust = "Cargo"
    case cmake = "CMake"
    case makefile = "Makefile"

    public var id: String { rawValue }

    /// 分类图标
    public var iconName: String {
        switch self {
        case .npm: return "shippingbox"
        case .gradle: return "hammer"
        case .just: return "play.square"
        case .uv: return "terminal"
        case .pdm: return "cube"
        case .rust: return "gearshape.2"
        case .cmake: return "wrench.and.screwdriver"
        case .makefile: return "doc.plaintext"
        }
    }

    /// 命令行默认运行命令格式化
    public func buildExecutionCommand(scriptName: String, rawCommand: String) -> String {
        switch self {
        case .npm:
            let pm = AppSettings.shared.packageManagerCommand.rawValue
            return "\(pm) \(shellQuote(scriptName))"
        case .gradle:
            return "./gradlew \(shellQuote(scriptName))"
        case .just:
            return "just \(shellQuote(scriptName))"
        case .uv:
            return "uv run \(shellQuote(scriptName))"
        case .pdm:
            return "pdm run \(shellQuote(scriptName))"
        case .rust:
            return "cargo \(shellQuote(scriptName))"
        case .cmake:
            return rawCommand.isEmpty ? "cmake --build build" : rawCommand
        case .makefile:
            return "make \(shellQuote(scriptName))"
        }
    }

    /// 生成终端 Tab 专属标题格式: "<scriptName> (<category/pm> run)"
    public func buildTabTitle(scriptName: String) -> String {
        switch self {
        case .npm:
            let pm = AppSettings.shared.packageManagerCommand.rawValue
            return "\(scriptName) (\(pm) run)"
        default:
            return "\(scriptName) (\(rawValue) run)"
        }
    }
}

// MARK: - 抽象脚本数据模型

/// 抽象脚本条目（通用 Task 模型）
public struct UniversalProjectScript: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let command: String
    public let category: ProjectScriptCategory
    public let directory: String
    public let depends: [String]
    public let scriptDescription: String?

    public init(
        name: String,
        command: String,
        category: ProjectScriptCategory = .npm,
        directory: String,
        depends: [String] = [],
        scriptDescription: String? = nil
    ) {
        self.id = "\(category.rawValue):\(name)@\(directory)"
        self.name = name
        self.command = command
        self.category = category
        self.directory = directory
        self.depends = depends
        self.scriptDescription = scriptDescription
    }
}

// MARK: - 运行模式与状态

public enum UniversalScriptRunMode: Equatable {
    case normal
    case withTime
    case withInspect
    case withProf
    case custom(prefix: String)
}

public enum UniversalScriptStatus: Equatable {
    case idle
    case running
    case stopping
}

/// 脚本执行过程追踪记录
public struct UniversalScriptExecutionRecord: Identifiable {
    public let id = UUID()
    public let script: UniversalProjectScript
    public let sessionID: UUID
    public let startedAt: Date
    public var status: UniversalScriptStatus
    public var lastDuration: TimeInterval?
    public var boundPort: Int?

    public init(
        script: UniversalProjectScript,
        sessionID: UUID,
        startedAt: Date = Date(),
        status: UniversalScriptStatus = .running,
        lastDuration: TimeInterval? = nil,
        boundPort: Int? = nil
    ) {
        self.script = script
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.status = status
        self.lastDuration = lastDuration
        self.boundPort = boundPort
    }
}

// MARK: - 脚本解析 Provider 协议

public protocol ProjectScriptProvider {
    var category: ProjectScriptCategory { get }
    func detectScripts(in directory: String) async -> [UniversalProjectScript]
}

// MARK: - NPM Script Provider 实现

public struct NPMScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .npm }

    public init() {}

    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        let probeScripts = SidebarProbe.loadPackageScripts(directory: directory)
        return probeScripts.map {
            UniversalProjectScript(name: $0.name, command: $0.command, category: .npm, directory: directory)
        }
    }
}

// MARK: - Gradle Task 快速匹配模型与缓存

/// Gradle Task 提取项模型
public struct GradleTaskItem: Codable, Equatable, Hashable {
    /// 任务名称（如 assembleDebug, test）
    public let name: String
    /// 来源文件路径（相对路径，如 build.gradle.kts）
    public let source: String

    public init(name: String, source: String) {
        self.name = name
        self.source = source
    }
}

/// Gradle 任务解析结果缓存管理
public final class GradleTaskCache: @unchecked Sendable {
    /// 单例实例
    public static let shared = GradleTaskCache()

    /// 缓存条目
    public struct CacheEntry: Codable {
        public let filePath: String
        public let modificationDate: Date
        public let hash: String
        public let tasks: [GradleTaskItem]
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    private init() {}

    /// 获取文件的解析缓存
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - modificationDate: 文件修改时间
    ///   - hash: 文件内容 Hash 值
    /// - Returns: 缓存的任务列表，若未命中或文件失效则返回 nil
    public func getCached(filePath: String, modificationDate: Date, hash: String) -> [GradleTaskItem]? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[filePath] else { return nil }
        if entry.modificationDate == modificationDate && entry.hash == hash {
            return entry.tasks
        }
        return nil
    }

    /// 设置文件的解析缓存
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - modificationDate: 文件修改时间
    ///   - hash: 文件内容 Hash 值
    ///   - tasks: 解析出的任务列表
    public func setCache(filePath: String, modificationDate: Date, hash: String, tasks: [GradleTaskItem]) {
        lock.lock()
        defer { lock.unlock() }

        cache[filePath] = CacheEntry(
            filePath: filePath,
            modificationDate: modificationDate,
            hash: hash,
            tasks: tasks
        )
    }

    /// 清空所有缓存
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}

// MARK: - Gradle Task 快速文本解析器

/// 基于正则表达式的 Gradle 任务快速文本解析器（毫秒级，不依赖 JVM / Gradle 执行）
public enum GradleTaskParser {
    /// 额外固定的 Android 任务列表
    public static let fixedAndroidTasks = [
        "assembleDebug",
        "assembleRelease",
        "installDebug",
        "installRelease",
        "lint",
        "test"
    ]

    /// Kotlin DSL 正则: tasks.register("xxx") / tasks.create("xxx")
    private static let kotlinDSLRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"tasks\.(?:register|create)\s*\(\s*["']([^"']+)["']"#, options: [])
    }()

    /// Groovy 正则: task xxx
    private static let groovyRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^\s*task\s+["']?([A-Za-z0-9_-]+)["']?"#, options: [.anchorsMatchLines])
    }()

    /// 解析单个 build.gradle / build.gradle.kts 文件中的任务
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - relativeSourcePath: 相对来源路径（用于 source 字段，如 build.gradle.kts）
    /// - Returns: 匹配到的 GradleTaskItem 数组
    public static func parseFile(atPath filePath: String, relativeSourcePath: String) -> [GradleTaskItem] {
        let fileURL = URL(fileURLWithPath: filePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let modDate = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        // 计算 SHA-256 Hash
        let hashData = SHA256.hash(data: data)
        let contentHash = hashData.compactMap { String(format: "%02x", $0) }.joined()

        // 优先尝试读取缓存
        if let cachedTasks = GradleTaskCache.shared.getCached(filePath: filePath, modificationDate: modDate, hash: contentHash) {
            return cachedTasks
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var taskNames: [String] = []
        var seenNames = Set<String>()

        func addTask(_ name: String) {
            if seenNames.insert(name).inserted {
                taskNames.append(name)
            }
        }

        let range = NSRange(location: 0, length: (content as NSString).length)

        // 1. Kotlin DSL 匹配: tasks.register("xxx") / tasks.create("xxx")
        if let regex = kotlinDSLRegex {
            let matches = regex.matches(in: content, options: [], range: range)
            for match in matches {
                if match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: content) {
                    let taskName = String(content[r])
                    addTask(taskName)
                }
            }
        }

        // 2. Groovy 匹配: task xxx
        if let regex = groovyRegex {
            let matches = regex.matches(in: content, options: [], range: range)
            for match in matches {
                if match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: content) {
                    let taskName = String(content[r])
                    addTask(taskName)
                }
            }
        }

        // 4. 判定 Android 插件并附加固定 Android Task
        if content.contains("com.android.application") || content.contains("com.android.library") {
            for androidTask in fixedAndroidTasks {
                addTask(androidTask)
            }
        }

        let resultItems = taskNames.map { GradleTaskItem(name: $0, source: relativeSourcePath) }
        GradleTaskCache.shared.setCache(filePath: filePath, modificationDate: modDate, hash: contentHash, tasks: resultItems)
        return resultItems
    }
}

// MARK: - 预留扩展 Providers (Gradle, uv, PDM, Cargo, Makefile)

/// Gradle 项目相关文件状态感知
public struct GradleFileState: Equatable {
    public let isGradleProject: Bool
    public let rootBuildGradleDate: Date?
    public let rootBuildKtsDate: Date?
    public let appBuildGradleDate: Date?
    public let appBuildKtsDate: Date?
}

public struct GradleScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .gradle }

    public init() {}

    /// 获取指定目录及常用构建文件的修改状态
    /// - Parameter directory: 工程绝对路径
    /// - Returns: GradleFileState 状态结构体
    public static func gradleFileState(directory: String) -> GradleFileState {
        guard !directory.isEmpty else {
            return GradleFileState(isGradleProject: false, rootBuildGradleDate: nil, rootBuildKtsDate: nil, appBuildGradleDate: nil, appBuildKtsDate: nil)
        }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        let isGradle = isGradleProject(at: directory)

        let rootBgDate = (try? fm.attributesOfItem(atPath: rootURL.appendingPathComponent("build.gradle").path))?[.modificationDate] as? Date
        let rootKtsDate = (try? fm.attributesOfItem(atPath: rootURL.appendingPathComponent("build.gradle.kts").path))?[.modificationDate] as? Date
        let appBgDate = (try? fm.attributesOfItem(atPath: rootURL.appendingPathComponent("app/build.gradle").path))?[.modificationDate] as? Date
        let appKtsDate = (try? fm.attributesOfItem(atPath: rootURL.appendingPathComponent("app/build.gradle.kts").path))?[.modificationDate] as? Date

        return GradleFileState(
            isGradleProject: isGradle,
            rootBuildGradleDate: rootBgDate,
            rootBuildKtsDate: rootKtsDate,
            appBuildGradleDate: appBgDate,
            appBuildKtsDate: appKtsDate
        )
    }

    /// 判断指定目录是否为 Gradle 项目
    /// - Parameter directory: 工程绝对路径
    /// - Returns: 是否为 Gradle 项目
    public static func isGradleProject(at directory: String) -> Bool {
        guard !directory.isEmpty else { return false }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        let indicatorFiles = [
            "build.gradle",
            "build.gradle.kts",
            "settings.gradle",
            "settings.gradle.kts",
            "gradlew",
            "gradlew.bat"
        ]
        for file in indicatorFiles {
            if fm.fileExists(atPath: rootURL.appendingPathComponent(file).path) {
                return true
            }
        }
        if fm.fileExists(atPath: rootURL.appendingPathComponent(".gradle").path) {
            return true
        }
        return false
    }

    /// 探测目录及近邻子模块下的 Gradle 任务
    /// - Parameter directory: 工程根目录绝对路径
    /// - Returns: 通用脚本模型 UniversalProjectScript 列表
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        // 先判断是否为 Gradle 项目，非 Gradle 项目直接返回空列表
        guard GradleScriptProvider.isGradleProject(at: directory) else {
            return []
        }

        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        var allTaskItems: [GradleTaskItem] = []
        var scannedPaths = Set<String>()

        let targetFileNames = ["build.gradle", "build.gradle.kts"]

        // 扫描根目录
        for fileName in targetFileNames {
            let fileURL = rootURL.appendingPathComponent(fileName)
            if fm.fileExists(atPath: fileURL.path) {
                scannedPaths.insert(fileURL.path)
                let items = GradleTaskParser.parseFile(atPath: fileURL.path, relativeSourcePath: fileName)
                allTaskItems.append(contentsOf: items)
            }
        }

        // 扫描浅层子目录（避开 build, .gradle, node_modules, .git 等）
        let ignoredDirs: Set<String> = ["build", ".gradle", ".git", "node_modules", "bin", "obj", "out", ".idea"]
        if let subdirs = try? fm.contentsOfDirectory(atPath: directory) {
            for sub in subdirs {
                guard !sub.hasPrefix("."), !ignoredDirs.contains(sub) else { continue }
                let subURL = rootURL.appendingPathComponent(sub)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: subURL.path, isDirectory: &isDir), isDir.boolValue {
                    for fileName in targetFileNames {
                        let targetURL = subURL.appendingPathComponent(fileName)
                        if fm.fileExists(atPath: targetURL.path), !scannedPaths.contains(targetURL.path) {
                            scannedPaths.insert(targetURL.path)
                            let relPath = "\(sub)/\(fileName)"
                            let items = GradleTaskParser.parseFile(atPath: targetURL.path, relativeSourcePath: relPath)
                            allTaskItems.append(contentsOf: items)
                        }
                    }
                }
            }
        }

        // 转换并去重
        var scripts: [UniversalProjectScript] = []
        var seenNames = Set<String>()
        for item in allTaskItems {
            if seenNames.insert(item.name).inserted {
                let script = UniversalProjectScript(
                    name: item.name,
                    command: item.name,
                    category: .gradle,
                    directory: directory
                )
                scripts.append(script)
            }
        }
        return scripts
    }
}

// MARK: - Just Task 提取模型与缓存

/// Justfile 任务提取项模型
public struct JustTaskItem: Codable, Equatable, Hashable {
    /// 任务名称（如 build, test）
    public let name: String
    /// 运行指令（如 just build）
    public let command: String
    /// 来源文件名（如 Justfile）
    public let source: String
    /// 依赖任务列表（如 ["test"]）
    public let depends: [String]

    public init(name: String, command: String, source: String, depends: [String] = []) {
        self.name = name
        self.command = command
        self.source = source
        self.depends = depends
    }
}

/// Just Task 解析结果缓存管理
public final class JustTaskCache: @unchecked Sendable {
    /// 单例实例
    public static let shared = JustTaskCache()

    /// 缓存条目
    public struct CacheEntry: Codable {
        public let filePath: String
        public let modificationDate: Date
        public let hash: String
        public let tasks: [JustTaskItem]
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    private init() {}

    /// 获取 Justfile 的解析缓存
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - modificationDate: 修改时间
    ///   - hash: 内容 Hash
    /// - Returns: 缓存的任务列表，未命中返回 nil
    public func getCached(filePath: String, modificationDate: Date, hash: String) -> [JustTaskItem]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[filePath] else { return nil }
        if entry.modificationDate == modificationDate && entry.hash == hash {
            return entry.tasks
        }
        return nil
    }

    /// 设置 Justfile 解析缓存
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - modificationDate: 修改时间
    ///   - hash: 内容 Hash
    ///   - tasks: 任务列表
    public func setCache(filePath: String, modificationDate: Date, hash: String, tasks: [JustTaskItem]) {
        lock.lock()
        defer { lock.unlock() }
        cache[filePath] = CacheEntry(filePath: filePath, modificationDate: modificationDate, hash: hash, tasks: tasks)
    }

    /// 清空缓存
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}

/// 检查系统 `just` CLI 是否已安装
public enum JustToolChecker {
    /// 检测系统中是否存在 executable 的 `just` 命令行工具
    public static var isJustInstalled: Bool {
        let fm = FileManager.default
        let commonPaths = [
            "/usr/local/bin/just",
            "/opt/homebrew/bin/just",
            "/usr/bin/just",
            "/bin/just",
            "~/.cargo/bin/just"
        ]
        for path in commonPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return true
            }
        }
        return false
    }
}

// MARK: - Justfile 快速解析器

/// 基于正则表达式的 Justfile 快速文本解析器
public enum JustTaskParser {
    /// 匹配任务声明与依赖的正则表达式: ^([A-Za-z_][A-Za-z0-9_-]*)\s*:
    private static let taskHeaderRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?!alias\b)(?!set\b)(?!export\b)([A-Za-z_][A-Za-z0-9_-]*)\s*(?:[^\n:=]*)\s*:(?!=)(.*)$"#,
            options: [.anchorsMatchLines]
        )
    }()

    /// 解析单个 Justfile 文件中的任务
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - relativeSourcePath: 相对来源路径（如 Justfile）
    /// - Returns: 提取到的 JustTaskItem 列表
    public static func parseFile(atPath filePath: String, relativeSourcePath: String) -> [JustTaskItem] {
        let fileURL = URL(fileURLWithPath: filePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let modDate = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        // SHA-256 Hash
        let hashData = SHA256.hash(data: data)
        let contentHash = hashData.compactMap { String(format: "%02x", $0) }.joined()

        if let cached = JustTaskCache.shared.getCached(filePath: filePath, modificationDate: modDate, hash: contentHash) {
            return cached
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var results: [JustTaskItem] = []
        var seenNames = Set<String>()

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 忽略注释、变量定义与命令行
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.contains(":=") || trimmed.hasPrefix("export ") || trimmed.hasPrefix("set ") {
                continue
            }

            let nsRange = NSRange(location: 0, length: (line as NSString).length)
            guard let regex = taskHeaderRegex,
                  let match = regex.firstMatch(in: line, options: [], range: nsRange),
                  match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: line) else {
                continue
            }

            let taskName = String(line[nameRange])

            // 忽略私有任务（以 _ 开头）
            if taskName.hasPrefix("_") {
                continue
            }

            // 解析依赖项 (冒号右侧)
            var depends: [String] = []
            if match.numberOfRanges >= 3, let depRange = Range(match.range(at: 2), in: line) {
                let depString = String(line[depRange])
                let tokens = depString.split(separator: " ")
                for token in tokens {
                    let cleaned = token.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()@+")))
                    if !cleaned.isEmpty && !cleaned.hasPrefix("#") && !cleaned.hasPrefix("_") {
                        depends.append(cleaned)
                    }
                }
            }

            if seenNames.insert(taskName).inserted {
                let item = JustTaskItem(
                    name: taskName,
                    command: "just \(taskName)",
                    source: relativeSourcePath,
                    depends: depends
                )
                results.append(item)
            }
        }

        JustTaskCache.shared.setCache(filePath: filePath, modificationDate: modDate, hash: contentHash, tasks: results)
        return results
    }
}

// MARK: - Just Provider

public struct JustFileState: Equatable {
    public let hasJustfile: Bool
    public let modificationDate: Date?
}

public struct JustScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .just }

    public init() {}

    /// 获取指定目录中 Justfile 的变动状态
    /// - Parameter directory: 工程路径
    /// - Returns: JustFileState
    public static func justFileState(directory: String) -> JustFileState {
        guard !directory.isEmpty else { return JustFileState(hasJustfile: false, modificationDate: nil) }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        for name in ["Justfile", "justfile"] {
            let path = rootURL.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                return JustFileState(hasJustfile: true, modificationDate: modDate)
            }
        }
        return JustFileState(hasJustfile: false, modificationDate: nil)
    }

    /// 判断指定目录是否包含 Justfile
    /// - Parameter directory: 工程路径
    /// - Returns: 是否为 Just 项目
    public static func isJustProject(at directory: String) -> Bool {
        justFileState(directory: directory).hasJustfile
    }

    /// 探测目录下的 Just 任务
    /// - Parameter directory: 工程路径
    /// - Returns: UniversalProjectScript 列表
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        guard JustScriptProvider.isJustProject(at: directory) else { return [] }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        var taskItems: [JustTaskItem] = []

        for name in ["Justfile", "justfile"] {
            let path = rootURL.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) {
                let items = JustTaskParser.parseFile(atPath: path, relativeSourcePath: name)
                taskItems.append(contentsOf: items)
                break
            }
        }

        return taskItems.map { item in
            UniversalProjectScript(
                name: item.name,
                command: item.command,
                category: .just,
                directory: directory,
                depends: item.depends
            )
        }
    }
}

public struct UvScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .uv }
    public init() {}
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        // 预留: 解析 pyproject.toml [tool.uv.scripts]
        return []
    }
}

public struct PDMScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .pdm }
    public init() {}
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        // 预留: 解析 pyproject.toml [tool.pdm.scripts]
        return []
    }
}

// MARK: - Cargo Task 提取模型与缓存

/// Cargo 任务提取项模型（包含预置 Task 与 Alias 别名）
public struct CargoTaskItem: Codable, Equatable, Hashable {
    /// 任务或别名名称（如 check, b, t）
    public let name: String
    /// 运行指令（如 cargo check, cargo b）
    public let command: String
    /// 详细展开说明（如 cargo build）
    public let description: String?
    /// 来源（如 Preset, .cargo/config.toml）
    public let source: String

    public init(name: String, command: String, description: String? = nil, source: String = "Cargo") {
        self.name = name
        self.command = command
        self.description = description
        self.source = source
    }
}

/// Cargo Alias 解析结果缓存管理器
public final class CargoTaskCache: @unchecked Sendable {
    /// 单例实例
    public static let shared = CargoTaskCache()

    /// 缓存条目结构
    public struct CacheEntry: Codable {
        public let filePath: String
        public let modificationDate: Date
        public let hash: String
        public let aliases: [CargoTaskItem]
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    private init() {}

    /// 获取 Cargo 配置文件解析缓存
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - modificationDate: 修改时间
    ///   - hash: 内容 Hash
    /// - Returns: 缓存的别名任务列表，未命中返回 nil
    public func getCached(filePath: String, modificationDate: Date, hash: String) -> [CargoTaskItem]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[filePath] else { return nil }
        if entry.modificationDate == modificationDate && entry.hash == hash {
            return entry.aliases
        }
        return nil
    }

    /// 设置 Cargo 配置文件解析缓存
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - modificationDate: 修改时间
    ///   - hash: 内容 Hash
    ///   - aliases: 别名任务列表
    public func setCache(filePath: String, modificationDate: Date, hash: String, aliases: [CargoTaskItem]) {
        lock.lock()
        defer { lock.unlock() }
        cache[filePath] = CacheEntry(filePath: filePath, modificationDate: modificationDate, hash: hash, aliases: aliases)
    }

    /// 清空缓存
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}

/// 检查系统 `cargo` CLI 是否已安装
public enum CargoToolChecker {
    /// 检测系统中是否存在 executable 的 `cargo` 命令行工具
    public static var isCargoInstalled: Bool {
        let fm = FileManager.default
        let commonPaths = [
            "~/.cargo/bin/cargo",
            "/usr/local/bin/cargo",
            "/opt/homebrew/bin/cargo",
            "/usr/bin/cargo",
            "/bin/cargo"
        ]
        for path in commonPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return true
            }
        }
        return false
    }
}

// MARK: - Cargo.toml / config 快捷别名解析器

/// 基于正则表达式的 Cargo [alias] 快捷别名解析器
public enum CargoConfigParser {
    /// 匹配 alias 赋值语句: ^\s*([a-zA-Z0-9_-]+)\s*=\s*["']([^"']+)["']
    private static let aliasRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^\s*([a-zA-Z0-9_-]+)\s*=\s*["']([^"']+)["']"#,
            options: [.anchorsMatchLines]
        )
    }()

    /// 解析指定配置文件中的 [alias] 节
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - relativeSourcePath: 相对来源路径（如 .cargo/config.toml）
    /// - Returns: CargoTaskItem 列表
    public static func parseFile(atPath filePath: String, relativeSourcePath: String) -> [CargoTaskItem] {
        let fileURL = URL(fileURLWithPath: filePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let modDate = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        // SHA-256 Hash
        let hashData = SHA256.hash(data: data)
        let contentHash = hashData.compactMap { String(format: "%02x", $0) }.joined()

        if let cached = CargoTaskCache.shared.getCached(filePath: filePath, modificationDate: modDate, hash: contentHash) {
            return cached
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var results: [CargoTaskItem] = []
        var inAliasSection = false

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let sectionName = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                inAliasSection = (sectionName == "alias")
                continue
            }

            if inAliasSection {
                let nsRange = NSRange(location: 0, length: (line as NSString).length)
                if let regex = aliasRegex,
                   let match = regex.firstMatch(in: line, options: [], range: nsRange),
                   match.numberOfRanges >= 3,
                   let keyRange = Range(match.range(at: 1), in: line),
                   let valRange = Range(match.range(at: 2), in: line) {
                    let key = String(line[keyRange])
                    let val = String(line[valRange])
                    let item = CargoTaskItem(
                        name: key,
                        command: "cargo \(key)",
                        description: "cargo \(val)",
                        source: relativeSourcePath
                    )
                    results.append(item)
                }
            }
        }

        CargoTaskCache.shared.setCache(filePath: filePath, modificationDate: modDate, hash: contentHash, aliases: results)
        return results
    }
}

// MARK: - Cargo Provider

public struct CargoFileState: Equatable {
    public let isCargoProject: Bool
    public let configModDate: Date?
}

public struct CargoScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .rust }

    public init() {}

    /// 预置的基础 Task: check, run, build, test, clean
    public static let presetTasks: [CargoTaskItem] = [
        CargoTaskItem(name: "check", command: "cargo check", description: "cargo check", source: "Preset"),
        CargoTaskItem(name: "run", command: "cargo run", description: "cargo run", source: "Preset"),
        CargoTaskItem(name: "build", command: "cargo build", description: "cargo build", source: "Preset"),
        CargoTaskItem(name: "test", command: "cargo test", description: "cargo test", source: "Preset"),
        CargoTaskItem(name: "clean", command: "cargo clean", description: "cargo clean", source: "Preset")
    ]

    /// 获取工程的 Cargo 配置文件修改状态
    /// - Parameter directory: 工程路径
    /// - Returns: CargoFileState
    public static func cargoFileState(directory: String) -> CargoFileState {
        guard !directory.isEmpty else { return CargoFileState(isCargoProject: false, configModDate: nil) }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)

        let hasCargoToml = fm.fileExists(atPath: rootURL.appendingPathComponent("Cargo.toml").path)
        var modDate: Date? = nil

        for name in [".cargo/config.toml", ".cargo/config"] {
            let path = rootURL.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mDate = attrs[.modificationDate] as? Date {
                modDate = mDate
                break
            }
        }

        let isCargo = hasCargoToml || modDate != nil
        return CargoFileState(isCargoProject: isCargo, configModDate: modDate)
    }

    /// 判断指定目录是否为 Cargo/Rust 项目
    /// - Parameter directory: 工程路径
    /// - Returns: 是否包含 Cargo.toml 或 .cargo/config(.toml)
    public static func isCargoProject(at directory: String) -> Bool {
        cargoFileState(directory: directory).isCargoProject
    }

    /// 探测并获取目录下的所有 Cargo Tasks (快捷别名 + 预置 Task)
    /// - Parameter directory: 工程路径
    /// - Returns: UniversalProjectScript 列表
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        guard CargoScriptProvider.isCargoProject(at: directory) else { return [] }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        var aliasItems: [CargoTaskItem] = []

        for name in [".cargo/config.toml", ".cargo/config"] {
            let path = rootURL.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) {
                let items = CargoConfigParser.parseFile(atPath: path, relativeSourcePath: name)
                aliasItems.append(contentsOf: items)
                break
            }
        }

        var finalTasks: [CargoTaskItem] = []
        var seenNames = Set<String>()

        // 优先加入自定义 Alias
        for item in aliasItems {
            if seenNames.insert(item.name).inserted {
                finalTasks.append(item)
            }
        }

        // 补全预置的任务 check, run, build, test, clean
        for preset in CargoScriptProvider.presetTasks {
            if seenNames.insert(preset.name).inserted {
                finalTasks.append(preset)
            }
        }

        return finalTasks.map { item in
            UniversalProjectScript(
                name: item.name,
                command: item.command,
                category: .rust,
                directory: directory,
                depends: [],
                scriptDescription: item.description
            )
        }
    }
}

// MARK: - CMake Provider

/// 检查系统 `cmake` CLI 是否已安装
public enum CMakeToolChecker {
    /// 检测系统中是否存在 executable 的 `cmake` 命令行工具
    public static var isCMakeInstalled: Bool {
        let fm = FileManager.default
        let commonPaths = [
            "/usr/local/bin/cmake",
            "/opt/homebrew/bin/cmake",
            "/usr/bin/cmake",
            "/bin/cmake"
        ]
        for path in commonPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return true
            }
        }
        return false
    }
}

public struct CMakeFileState: Equatable {
    public let isCMakeProject: Bool
    public let modificationDate: Date?
}

public struct CMakeScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .cmake }

    public init() {}

    /// 预置的 5 个基础 CMake 任务: Configure, Build, Test, Clean, Install
    public static let presetTasks: [UniversalProjectScript] = [
        UniversalProjectScript(
            name: "Configure",
            command: "cmake -S . -B build",
            category: .cmake,
            directory: ""
        ),
        UniversalProjectScript(
            name: "Build",
            command: "cmake --build build",
            category: .cmake,
            directory: ""
        ),
        UniversalProjectScript(
            name: "Test",
            command: "ctest --test-dir build",
            category: .cmake,
            directory: ""
        ),
        UniversalProjectScript(
            name: "Clean",
            command: "cmake --build build --target clean",
            category: .cmake,
            directory: ""
        ),
        UniversalProjectScript(
            name: "Install",
            command: "cmake --install build",
            category: .cmake,
            directory: ""
        )
    ]

    /// 获取指定目录的 CMakeLists.txt 状态
    /// - Parameter directory: 工程路径
    /// - Returns: CMakeFileState
    public static func cmakeFileState(directory: String) -> CMakeFileState {
        guard !directory.isEmpty else { return CMakeFileState(isCMakeProject: false, modificationDate: nil) }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        let path = rootURL.appendingPathComponent("CMakeLists.txt").path

        if let attrs = try? fm.attributesOfItem(atPath: path),
           let modDate = attrs[.modificationDate] as? Date {
            return CMakeFileState(isCMakeProject: true, modificationDate: modDate)
        }
        return CMakeFileState(isCMakeProject: false, modificationDate: nil)
    }

    /// 判断指定目录是否为 CMake 项目
    /// - Parameter directory: 工程路径
    /// - Returns: 是否包含 CMakeLists.txt
    public static func isCMakeProject(at directory: String) -> Bool {
        cmakeFileState(directory: directory).isCMakeProject
    }

    /// 探测目录下的 CMake 任务
    /// - Parameter directory: 工程路径
    /// - Returns: UniversalProjectScript 列表
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        guard CMakeScriptProvider.isCMakeProject(at: directory) else { return [] }
        return CMakeScriptProvider.presetTasks.map { preset in
            UniversalProjectScript(
                name: preset.name,
                command: preset.command,
                category: .cmake,
                directory: directory,
                depends: [],
                scriptDescription: nil
            )
        }
    }
}

public struct CargoAliasProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .rust }
    public init() {}
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        await CargoScriptProvider().detectScripts(in: directory)
    }
}

// MARK: - Makefile Task 提取模型与缓存

/// Makefile 任务提取项模型
public struct MakefileTaskItem: Codable, Equatable, Hashable {
    /// 任务名称（如 build, test）
    public let name: String
    /// 运行指令（如 make build）
    public let command: String
    /// 来源文件名（如 Makefile）
    public let source: String

    public init(name: String, command: String, source: String) {
        self.name = name
        self.command = command
        self.source = source
    }
}

/// Makefile Task 解析结果缓存管理
public final class MakefileTaskCache: @unchecked Sendable {
    /// 单例实例
    public static let shared = MakefileTaskCache()

    /// 缓存条目
    public struct CacheEntry: Codable {
        public let filePath: String
        public let modificationDate: Date
        public let hash: String
        public let tasks: [MakefileTaskItem]
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    private init() {}

    /// 获取 Makefile 的解析缓存
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - modificationDate: 修改时间
    ///   - hash: 内容 Hash
    /// - Returns: 缓存的任务列表，未命中返回 nil
    public func getCached(filePath: String, modificationDate: Date, hash: String) -> [MakefileTaskItem]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[filePath] else { return nil }
        if entry.modificationDate == modificationDate && entry.hash == hash {
            return entry.tasks
        }
        return nil
    }

    /// 设置 Makefile 解析缓存
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - modificationDate: 修改时间
    ///   - hash: 内容 Hash
    ///   - tasks: 任务列表
    public func setCache(filePath: String, modificationDate: Date, hash: String, tasks: [MakefileTaskItem]) {
        lock.lock()
        defer { lock.unlock() }
        cache[filePath] = CacheEntry(filePath: filePath, modificationDate: modificationDate, hash: hash, tasks: tasks)
    }

    /// 清空缓存
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}

/// 检查系统 `make` CLI 是否已安装
public enum MakeToolChecker {
    /// 检测系统中是否存在 executable 的 `make` 命令行工具
    public static var isMakeInstalled: Bool {
        let fm = FileManager.default
        let commonPaths = [
            "/usr/bin/make",
            "/usr/local/bin/make",
            "/opt/homebrew/bin/make",
            "/bin/make"
        ]
        for path in commonPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return true
            }
        }
        return false
    }
}

// MARK: - Makefile 快速解析器

/// 基于正则表达式的 Makefile 快速文本解析器
public enum MakefileParser {
    /// 匹配 Target 目标的正则表达式: ^([A-Za-z0-9_-]+)\s*:
    private static let targetRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^([A-Za-z0-9_-]+)\s*:"#,
            options: [.anchorsMatchLines]
        )
    }()

    /// 解析指定 Makefile 文件中的 Target
    /// - Parameters:
    ///   - filePath: 文件绝对路径
    ///   - relativeSourcePath: 相对来源路径（如 Makefile）
    /// - Returns: MakefileTaskItem 列表
    public static func parseFile(atPath filePath: String, relativeSourcePath: String) -> [MakefileTaskItem] {
        let fileURL = URL(fileURLWithPath: filePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let modDate = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        // SHA-256 Hash
        let hashData = SHA256.hash(data: data)
        let contentHash = hashData.compactMap { String(format: "%02x", $0) }.joined()

        if let cached = MakefileTaskCache.shared.getCached(filePath: filePath, modificationDate: modDate, hash: contentHash) {
            return cached
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var results: [MakefileTaskItem] = []
        var seenNames = Set<String>()

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 忽略注释与变量赋值语句 (如 VAR = val, VAR := val, VAR ?= val)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.contains("=") {
                continue
            }

            let nsRange = NSRange(location: 0, length: (line as NSString).length)
            guard let regex = targetRegex,
                  let match = regex.firstMatch(in: line, options: [], range: nsRange),
                  match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: line) else {
                continue
            }

            let targetName = String(line[nameRange])

            // 过滤以 "." 开头的特殊 target (如 .PHONY, .DEFAULT, .SILENT)
            if targetName.hasPrefix(".") {
                continue
            }

            if seenNames.insert(targetName).inserted {
                let item = MakefileTaskItem(
                    name: targetName,
                    command: "make \(targetName)",
                    source: relativeSourcePath
                )
                results.append(item)
            }
        }

        MakefileTaskCache.shared.setCache(filePath: filePath, modificationDate: modDate, hash: contentHash, tasks: results)
        return results
    }
}

// MARK: - Makefile Provider

public struct MakefileFileState: Equatable {
    public let hasMakefile: Bool
    public let modificationDate: Date?
}

public struct MakefileScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .makefile }

    public init() {}

    /// 获取指定目录中 Makefile 的变动状态
    /// - Parameter directory: 工程路径
    /// - Returns: MakefileFileState
    public static func makefileFileState(directory: String) -> MakefileFileState {
        guard !directory.isEmpty else { return MakefileFileState(hasMakefile: false, modificationDate: nil) }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        for name in ["Makefile", "makefile", "GNUmakefile"] {
            let path = rootURL.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                return MakefileFileState(hasMakefile: true, modificationDate: modDate)
            }
        }
        return MakefileFileState(hasMakefile: false, modificationDate: nil)
    }

    /// 判断指定目录是否包含 Makefile
    /// - Parameter directory: 工程路径
    /// - Returns: 是否为 Makefile 项目
    public static func isMakefileProject(at directory: String) -> Bool {
        makefileFileState(directory: directory).hasMakefile
    }

    /// 探测目录下的 Makefile 任务
    /// - Parameter directory: 工程路径
    /// - Returns: UniversalProjectScript 列表
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        guard MakefileScriptProvider.isMakefileProject(at: directory) else { return [] }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: directory)
        var taskItems: [MakefileTaskItem] = []

        for name in ["Makefile", "makefile", "GNUmakefile"] {
            let path = rootURL.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) {
                let items = MakefileParser.parseFile(atPath: path, relativeSourcePath: name)
                taskItems.append(contentsOf: items)
                break
            }
        }

        return taskItems.map { item in
            UniversalProjectScript(
                name: item.name,
                command: item.command,
                category: .makefile,
                directory: directory
            )
        }
    }
}

// MARK: - 工具函数

private func shellQuote(_ text: String) -> String {
    guard !text.isEmpty else { return "''" }
    if text.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@+".contains($0) }) {
        return text
    }
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
