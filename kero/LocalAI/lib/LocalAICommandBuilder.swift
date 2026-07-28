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
            "--output-format", "plain",
        ]
        if request.disableTools {
            // 纯文本生成：禁用工具 / 联网 / 子代理，避免卡在权限确认
            args += [
                "--tools", "",
                "--disable-web-search",
                "--no-subagents",
                "--permission-mode", "dontAsk",
            ]
        }
        // 长提示词走文件，避免超大 argv
        if let file = writePromptTempFile(prompt, prefix: "qjiao-localai-grok") {
            args += ["--prompt-file", file]
        } else {
            args += ["--single", prompt]
        }
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
        var args: [String] = ["exec", "--skip-git-repo-check", "--ephemeral"]
        if let cwd = request.workingDirectory, !cwd.isEmpty {
            args += ["--cd", cwd]
        }
        // 默认 gpt-5.6-luna；请求可覆盖。使用 -m 与 CLI 文档一致。
        let model = (request.model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? LocalAIProviderID.codexDefaultModel
        args += ["-m", model]
        if request.disableTools {
            // 只读沙箱，减少写盘/跑 shell；仍可能尝试工具，配合超时兜底
            args += ["--sandbox", "read-only"]
        }
        if request.autoApprove {
            // 仅在调用方明确要求时启用；极度危险，用于可信自动化环境。
            args.append("--dangerously-bypass-approvals-and-sandbox")
        }
        // 长 prompt 走 stdin，避免 ARG_MAX / 挂起
        if prompt.utf8.count > 6_000 {
            args.append("-")
            return LocalAICommand(
                executable: executable,
                arguments: args,
                workingDirectory: request.workingDirectory,
                stdinText: prompt
            )
        }
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
        if request.disableTools {
            // 空 tools = 禁用全部内置工具，避免 Bash/Read 卡住
            args += ["--tools", ""]
            args += ["--permission-mode", "dontAsk"]
        }
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

    /// `agy [flags] --print <prompt>` 单轮非交互。
    ///
    /// **参数顺序很重要**：`--print` / `-p` 会把**紧随其后的下一个参数**当作 prompt。
    /// 若写成 `--print --output-format text …`，模型会把 `--output-format` 当成用户问题。
    /// 正确顺序：其它 flag 在前，最后 `--print` + prompt。
    ///
    /// headless 无法弹出 tool 权限确认：若 agent 调了 `command` 等工具会被 auto-deny，
    /// 并出现 `no output produced`。因此一律带 `--dangerously-skip-permissions`。
    /// 纯文本场景仍靠 prompt 约束「不要执行额外操作」；不要加 `--sandbox`。
    private static func buildAgy(
        executable: String,
        request: LocalAIRequest,
        prompt: String
    ) -> LocalAICommand {
        let seconds = max(15, Int(request.timeout.components.seconds))
        var args: [String] = [
            "--output-format", "text",
            "--dangerously-skip-permissions",
            // 与 LocalAI 超时大致对齐，避免默认 5m 拖死 UI 转圈
            "--print-timeout", "\(seconds)s",
        ]
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        // 必须放在最后：--print 的下一个 argv 才是真正的用户提示词
        args += ["--print", prompt]
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

    /// 将长提示词写入临时文件（调用方不负责删除；系统临时目录会清理）。
    private static func writePromptTempFile(_ prompt: String, prefix: String) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).txt")
        do {
            try prompt.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
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
