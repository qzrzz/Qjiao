//
//  ScriptCommandBuilder.swift
//  kero/ScriptRunner
//
//  Script Runner 命令构建器
//

import Foundation

/// 负责根据 Runtime 检测结果和修饰符构造强类型的 ScriptRunCommand 命令，并进行安全 Shell 转义
public struct ScriptCommandBuilder: Sendable {

    /// 根据检测结果与修饰符生成结构化运行命令
    /// - Parameters:
    ///   - detectionResult: Runtime 检测结构化结果
    ///   - modifier: 运行修饰符
    /// - Returns: 结构化的 ScriptRunCommand 模型
    /// - Throws: ScriptRunnerError
    public static func build(
        detectionResult: ScriptRuntimeDetectionResult,
        modifier: ScriptRunModifier = .none
    ) throws -> ScriptRunCommand {

        // 1. 检查修饰符与当前语言和 Runtime 的兼容性
        guard modifier.isCompatible(language: detectionResult.language, runtime: detectionResult.runtime) else {
            throw ScriptRunnerError.incompatibleModifier(modifier: modifier, runtime: detectionResult.runtime)
        }

        var wrapper: [String]? = nil
        var executable = detectionResult.runtime.executableName
        var args: [String] = []

        // 处理 time 修饰符
        if modifier == .time {
            wrapper = ["time"]
        }

        switch detectionResult.language {
        case .javaScript, .typeScript:
            // JavaScript / TypeScript 命令参数组装
            var jsArgs: [String] = []
            switch modifier {
            case .inspect:
                jsArgs.append("--inspect")
            case .inspectBrk:
                jsArgs.append("--inspect-brk")
            case .prof:
                jsArgs.append("--prof")
            case .none, .time:
                break
            }
            jsArgs.append(detectionResult.targetFilePath)
            args = jsArgs

        case .python:
            if detectionResult.runtime == .uv {
                executable = "uv"
                args = ["run", "python", detectionResult.targetFilePath]
            } else {
                executable = detectionResult.runtime.executableName
                args = [detectionResult.targetFilePath]
            }

        case .go:
            executable = "go"
            args = ["run", detectionResult.targetFilePath]

        case .rust:
            executable = "cargo"
            args = ["run"]
        }

        return ScriptRunCommand(
            executable: executable,
            args: args,
            wrapper: wrapper,
            workingDirectory: detectionResult.workingDirectory
        )
    }

    /// 对 Shell 命令行参数或可执行文件进行安全转义处理
    /// - Parameter value: 参数文本
    /// - Returns: 转义后的 Shell 安全参数字符串
    public static func shellQuote(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }

        // 判断是否包含需要单引号包裹的 Shell 特殊字符或空格/Unicode
        let safeSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-")
        if value.unicodeScalars.allSatisfy({ safeSet.contains($0) }) {
            return value
        }

        // 用单引号包裹，并将内部单引号替换为 '\''
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
