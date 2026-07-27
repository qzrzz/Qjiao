//
//  LocalAICommandBuilder.swift
//  kero
//
//  将统一 LocalAIRequest 映射为各 AI CLI 的 headless / exec 命令行。
//

import Foundation

/// 为每个 Provider 构建非交互调用 argv。
enum LocalAICommandBuilder {
    /// 根据 Provider 与请求生成可执行命令。
    ///
    /// - Parameters:
    ///   - provider: 目标 CLI（不得为 `.disabled`）。
    ///   - executable: 已解析的绝对路径。
    ///   - request: 统一请求。
    static func build(
        provider: LocalAIProviderID,
        executable: String,
        request: LocalAIRequest
    ) throws -> LocalAICommand {
        guard provider.isAIProvider else {
            throw LocalAIError.disabled
        }
        let prompt = request.prompt
        switch provider {
        case .disabled:
            throw LocalAIError.disabled
        case .grok:
            return buildGrok(executable: executable, request: request, prompt: prompt)
        case .codex:
            return buildCodex(executable: executable, request: request, prompt: prompt)
        case .claude:
            return buildClaude(executable: executable, request: request, prompt: prompt)
        case .agy:
            return buildAgy(executable: executable, request: request, prompt: prompt)
        case .opencode:
            return buildOpenCode(executable: executable, request: request, prompt: prompt)
        }
    }

    // MARK: - grok

    /// `grok --single <prompt>` headless 单轮；可附加 cwd / model / always-approve。
    private static func buildGrok(
        executable: String,
        request: LocalAIRequest,
        prompt: String
    ) -> LocalAICommand {
        var args: [String] = [
            "--single", prompt,
            "--output-format", "plain",
        ]
        if let cwd = request.workingDirectory, !cwd.isEmpty {
            args += ["--cwd", cwd]
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if request.autoApprove {
            args.append("--always-approve")
        }
        return LocalAICommand(
            executable: executable,
            arguments: args,
            workingDirectory: request.workingDirectory
        )
    }

    // MARK: - codex

    /// `codex exec [options] <prompt>` 非交互执行。
    private static func buildCodex(
        executable: String,
        request: LocalAIRequest,
        prompt: String
    ) -> LocalAICommand {
        var args: [String] = ["exec", "--skip-git-repo-check"]
        if let cwd = request.workingDirectory, !cwd.isEmpty {
            args += ["--cd", cwd]
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if request.autoApprove {
            // 仅在调用方明确要求时启用；极度危险，用于可信自动化环境。
            args.append("--dangerously-bypass-approvals-and-sandbox")
        }
        // prompt 作为位置参数；空时由 stdin 读，这里始终传参。
        args.append(prompt)
        return LocalAICommand(
            executable: executable,
            arguments: args,
            workingDirectory: request.workingDirectory
        )
    }

    // MARK: - claude

    /// `claude -p <prompt>`（--print）非交互输出。
    private static func buildClaude(
        executable: String,
        request: LocalAIRequest,
        prompt: String
    ) -> LocalAICommand {
        var args: [String] = [
            "--print",
            "--output-format", "text",
        ]
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if request.autoApprove {
            args.append("--dangerously-skip-permissions")
        }
        // prompt 作为尾部位置参数
        args.append(prompt)
        return LocalAICommand(
            executable: executable,
            arguments: args,
            workingDirectory: request.workingDirectory
        )
    }

    // MARK: - agy

    /// `agy --print <prompt>` 单轮非交互。
    private static func buildAgy(
        executable: String,
        request: LocalAIRequest,
        prompt: String
    ) -> LocalAICommand {
        var args: [String] = ["--print", prompt]
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if request.autoApprove {
            args.append("--dangerously-skip-permissions")
        }
        return LocalAICommand(
            executable: executable,
            arguments: args,
            workingDirectory: request.workingDirectory
        )
    }

    // MARK: - opencode

    /// `opencode run <message>` 非交互跑一轮。
    private static func buildOpenCode(
        executable: String,
        request: LocalAIRequest,
        prompt: String
    ) -> LocalAICommand {
        var args: [String] = ["run"]
        if let cwd = request.workingDirectory, !cwd.isEmpty {
            args += ["--dir", cwd]
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if request.autoApprove {
            args.append("--auto")
        }
        // message 为位置参数；长 prompt 拆成单个 argv 更稳妥
        args.append(prompt)
        return LocalAICommand(
            executable: executable,
            arguments: args,
            workingDirectory: request.workingDirectory
        )
    }

    // MARK: - 输出解析

    /// 从进程输出提取对用户有意义的文本。
    static func extractText(
        provider: LocalAIProviderID,
        processResult: LocalAIProcessResult
    ) -> String {
        let stdout = processResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }
        // 部分 CLI 把主输出写到 stderr（少见）；仅在 stdout 空时回退
        let stderr = processResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // 避免把纯日志当答案：仅当退出成功且 stderr 看起来像正文时
        if processResult.exitCode == 0, !stderr.isEmpty {
            return stderr
        }
        _ = provider
        return stdout
    }
}
