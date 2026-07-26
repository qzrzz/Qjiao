//
//  ProjectScriptEngine.swift
//  kero
//
//  多语言工程脚本执行引擎（支持 NPM, Gradle, uv, PDM, Rust alias, Makefile 等）
//

import Foundation
import GhosttyTerminal
import SwiftUI

// MARK: - 脚本分类枚举

/// 项目可执行脚本/任务来源分类
public enum ProjectScriptCategory: String, Codable, CaseIterable, Identifiable {
    case npm = "npm"
    case gradle = "Gradle"
    case uv = "uv"
    case pdm = "PDM"
    case rust = "Cargo"
    case makefile = "Makefile"

    public var id: String { rawValue }

    /// 分类图标
    public var iconName: String {
        switch self {
        case .npm: return "shippingbox"
        case .gradle: return "hammer"
        case .uv: return "terminal"
        case .pdm: return "cube"
        case .rust: return "gearshape.2"
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
            let hasWrapper = FileManager.default.fileExists(atPath: "./gradlew")
            let gradleCmd = hasWrapper ? "./gradlew" : "gradle"
            return "\(gradleCmd) \(shellQuote(scriptName))"
        case .uv:
            return "uv run \(shellQuote(scriptName))"
        case .pdm:
            return "pdm run \(shellQuote(scriptName))"
        case .rust:
            return "cargo \(shellQuote(scriptName))"
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

    public init(name: String, command: String, category: ProjectScriptCategory = .npm, directory: String) {
        self.id = "\(category.rawValue):\(name)@\(directory)"
        self.name = name
        self.command = command
        self.category = category
        self.directory = directory
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

// MARK: - 预留扩展 Providers (Gradle, uv, PDM, Cargo, Makefile)

public struct GradleScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .gradle }
    public init() {}
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        // 预留: 解析 gradlew / build.gradle / build.gradle.kts 任务列表
        return []
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

public struct CargoAliasProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .rust }
    public init() {}
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        // 预留: 解析 .cargo/config.toml [alias]
        return []
    }
}

public struct MakefileScriptProvider: ProjectScriptProvider {
    public var category: ProjectScriptCategory { .makefile }
    public init() {}
    public func detectScripts(in directory: String) async -> [UniversalProjectScript] {
        // 预留: 解析 Makefile target 目标
        return []
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
