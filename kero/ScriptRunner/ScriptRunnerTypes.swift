//
//  ScriptRunnerTypes.swift
//  kero/ScriptRunner
//
//  Script Runner 核心类型与模型定义
//

import Foundation

/// 受支持的脚本编程语言分类
public enum ScriptLanguage: String, CaseIterable, Identifiable, Sendable {
    case javaScript = "JavaScript"
    case typeScript = "TypeScript"
    case python = "Python"
    case go = "Go"
    case rust = "Rust"

    public var id: String { rawValue }

    /// 显示名称
    public var displayName: String { rawValue }

    /// 根据文件扩展名识别语言
    /// - Parameter ext: 文件扩展名（不带点号，如 "js"、"ts"）
    /// - Returns: 对应的 ScriptLanguage 实例；若不支持则返回 nil
    public static func from(fileExtension ext: String) -> ScriptLanguage? {
        let normalized = ext.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "js", "mjs":
            return .javaScript
        case "ts", "tsx":
            return .typeScript
        case "py":
            return .python
        case "go":
            return .go
        case "rs":
            return .rust
        default:
            return nil
        }
    }
}

/// 可用的 Runtime 执行引擎类型
public enum ScriptRuntime: String, CaseIterable, Identifiable, Codable, Sendable {
    case bun = "bun"
    case node = "node"
    case tsx = "tsx"
    case uv = "uv"
    case python3 = "python3"
    case python = "python"
    case go = "go"
    case cargo = "cargo"

    public var id: String { rawValue }

    /// Runtime 可执行名称
    public var executableName: String { rawValue }
}

/// Script Runner 配置: JavaScript / TypeScript
public enum ScriptRunnerJSSetting: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case bun = "bun"
    case node = "node"
    case tsx = "tsx"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return L10n.t("Auto")
        case .bun: return "Bun"
        case .node: return "Node.js"
        case .tsx: return "TSX"
        }
    }
}

/// Script Runner 配置: Python
public enum ScriptRunnerPythonSetting: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case uv = "uv"
    case python = "python"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return L10n.t("Auto")
        case .uv: return "uv"
        case .python: return "Python"
        }
    }
}

/// Script Runner 配置: Go
public enum ScriptRunnerGoSetting: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case go = "go"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return L10n.t("Auto")
        case .go: return "Go"
        }
    }
}

/// Script Runner 配置: Rust
public enum ScriptRunnerRustSetting: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case cargo = "cargo"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return L10n.t("Auto")
        case .cargo: return "Cargo"
        }
    }
}

/// 脚本运行修饰符（运行模式）
public enum ScriptRunModifier: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "none"
    case time = "time"
    case inspect = "inspect"
    case inspectBrk = "inspect-brk"
    case prof = "prof"

    public var id: String { rawValue }

    /// 对应的本地化菜单名称
    public var displayName: String {
        switch self {
        case .none:
            return L10n.t("Run")
        case .time:
            return L10n.t("Run with time")
        case .inspect:
            return L10n.t("Run with --inspect")
        case .inspectBrk:
            return L10n.t("Run with --inspect-brk")
        case .prof:
            return L10n.t("Run with --prof")
        }
    }

    /// 判断修饰符是否受指定的语言和 Runtime 支持
    /// - Parameters:
    ///   - language: 脚本语言
    ///   - runtime: 选定的 Runtime
    /// - Returns: 布尔值，标识修饰符是否兼容
    public func isCompatible(language: ScriptLanguage, runtime: ScriptRuntime) -> Bool {
        switch self {
        case .none, .time:
            return true
        case .inspect, .inspectBrk:
            // inspect / inspect-brk 仅支持 JS/TS Runtime (node, bun, tsx)
            return language == .javaScript || language == .typeScript
        case .prof:
            // --prof 仅对 Node.js 兼容 Runtime (node, tsx) 开放
            return (language == .javaScript || language == .typeScript) && (runtime == .node || runtime == .tsx)
        }
    }
}

/// 结构化 Run 命令模型
public struct ScriptRunCommand: Equatable, Sendable {
    /// 目标可执行程序（如 "node", "python3", "cargo"）
    public let executable: String
    /// 命令行参数列表（如 ["--inspect", "app.js"]）
    public let args: [String]
    /// 包装层命令（如 ["time"]）
    public let wrapper: [String]?
    /// 执行命令的工作目录
    public let workingDirectory: String

    public init(
        executable: String,
        args: [String],
        wrapper: [String]? = nil,
        workingDirectory: String
    ) {
        self.executable = executable
        self.args = args
        self.wrapper = wrapper
        self.workingDirectory = workingDirectory
    }

    /// 安全转义并拼接生成终端可调用的 Shell 命令文本
    public var shellString: String {
        var parts: [String] = []
        if let wrapper = wrapper, !wrapper.isEmpty {
            parts.append(contentsOf: wrapper.map { ScriptCommandBuilder.shellQuote($0) })
        }
        parts.append(ScriptCommandBuilder.shellQuote(executable))
        for arg in args {
            parts.append(ScriptCommandBuilder.shellQuote(arg))
        }
        return parts.joined(separator: " ")
    }
}

/// Runtime 探测结构化结果
public struct ScriptRuntimeDetectionResult: Equatable, Sendable {
    /// 目标文件语言
    public let language: ScriptLanguage
    /// 生效的 Runtime
    public let runtime: ScriptRuntime
    /// 目标文件在工作目录下的相对路径（或完整文件名）
    public let targetFilePath: String
    /// 命令运行的工作目录
    public let workingDirectory: String
    /// 最近的项目根目录（若找到）
    public let projectRoot: String?
    /// 是否为 Bun 项目
    public let isBunProject: Bool

    public init(
        language: ScriptLanguage,
        runtime: ScriptRuntime,
        targetFilePath: String,
        workingDirectory: String,
        projectRoot: String? = nil,
        isBunProject: Bool = false
    ) {
        self.language = language
        self.runtime = runtime
        self.targetFilePath = targetFilePath
        self.workingDirectory = workingDirectory
        self.projectRoot = projectRoot
        self.isBunProject = isBunProject
    }
}

/// Script Runner 错误定义
public enum ScriptRunnerError: Error, LocalizedError, Equatable {
    case fileNotFound(String)
    case isDirectory(String)
    case unsupportedFileType(String)
    case runtimeNotFound(String)
    case incompatibleRuntime(runtime: String, fileType: String)
    case singleRustFileNotSupported
    case incompatibleModifier(modifier: ScriptRunModifier, runtime: ScriptRuntime)
    case commandBuildFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return L10n.format("File not found: %@", (path as NSString).lastPathComponent)
        case .isDirectory:
            return L10n.t("Cannot execute directory.")
        case .unsupportedFileType:
            return L10n.t("Unsupported file type")
        case .runtimeNotFound(let name):
            return L10n.format("Runtime not found: %@", name)
        case .incompatibleRuntime(let runtime, let fileType):
            return L10n.format("Runtime %@ is not compatible with %@ file.", runtime, fileType)
        case .singleRustFileNotSupported:
            return L10n.t("Running a single Rust file is currently not supported.")
        case .incompatibleModifier(let modifier, let runtime):
            return L10n.format("Modifier %@ is not supported for %@.", modifier.displayName, runtime.rawValue)
        case .commandBuildFailed(let reason):
            return L10n.format("Failed to build command: %@", reason)
        case .launchFailed(let reason):
            return L10n.format("Failed to launch command: %@", reason)
        }
    }
}
