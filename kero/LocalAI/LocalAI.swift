//
//  LocalAI.swift
//  kero
//
//  AI 统一门面：应用通过此接口调用本地 CLI 或云端 AI API。
//
//  支持：grok（--single）、codex（exec）、claude（-p）、agy（--print）、opencode（run）、pi（-p）。
//  全局设置：Settings → AI。
//

import Foundation

/// 应用内 AI 功能统一入口。
///
/// 保留 `LocalAI` 名称兼容既有调用点，实际后端由设置中的 CLI / API 选择决定。
enum LocalAI {
    /// 当前所选后端是否已完成必要配置。
    @MainActor
    static var isEnabled: Bool {
        switch AppSettings.shared.aiBackend {
        case .cli: return LocalAIRegistry.shared.isEnabled
        case .api: return AIAPIRegistry.shared.isEnabled
        }
    }

    /// 当前选中的统一 Provider 身份。
    @MainActor
    static var selectedProvider: AIProviderIdentity {
        switch AppSettings.shared.aiBackend {
        case .cli: return .cli(LocalAIRegistry.shared.selectedProvider)
        case .api: return .api(AppSettings.shared.aiAPIProvider)
        }
    }

    /// 全部 Provider 安装状态（含 disabled 与未安装项）。
    @MainActor
    static var providerStatuses: [LocalAIProviderStatus] {
        LocalAIRegistry.shared.statuses
    }

    /// 重新探测本机 CLI。
    @MainActor
    static func refreshInstallationStatus() {
        LocalAIRegistry.shared.refresh()
    }

    /// 执行单轮提示（使用全局设置中的后端；CLI override 存在时强制走 CLI）。
    ///
    /// - Parameter request: 提示词与可选工作目录、模型、超时等。
    /// - Returns: 解析后的文本与原始 stdout/stderr。
    static func prompt(_ request: LocalAIRequest) async throws -> LocalAIResponse {
        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAIError.emptyPrompt
        }

        var normalized = request
        normalized.prompt = trimmed

        let backend = resolveBackend(override: request.providerOverride)
        if backend == .api {
            let configuration = try await MainActor.run {
                try AIAPIRegistry.shared.configuration()
            }
            return try await AIAPIClient.prompt(normalized, configuration: configuration)
        }

        let provider = resolveCLIProvider(override: request.providerOverride)
        guard provider.isAIProvider else {
            throw LocalAIError.disabled
        }

        let executable = resolveExecutable(for: provider)
        guard let executable else {
            throw LocalAIError.notInstalled(provider)
        }

        let command = try LocalAICommandBuilder.build(
            provider: provider,
            executable: executable,
            request: normalized
        )

        try Task.checkCancellation()

        let processResult: LocalAIProcessResult
        do {
            processResult = try await LocalAIProcessRunner.run(command, timeout: request.timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalAIError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LocalAIError.launchFailed(error.localizedDescription)
        }

        try Task.checkCancellation()

        let text = LocalAICommandBuilder.extractText(
            provider: provider,
            processResult: processResult
        )

        if processResult.exitCode != 0, text.isEmpty {
            throw LocalAIError.commandFailed(
                provider: provider,
                exitCode: processResult.exitCode,
                stderr: processResult.stderr
            )
        }

        return LocalAIResponse(
            text: text,
            exitCode: processResult.exitCode,
            provider: .cli(provider),
            rawStdout: processResult.stdout,
            rawStderr: processResult.stderr,
            executablePath: executable
        )
    }

    /// 便捷方法：仅传提示词与可选工作目录。
    static func prompt(
        _ text: String,
        workingDirectory: String? = nil,
        model: String? = nil,
        timeout: Duration = .seconds(600),
        autoApprove: Bool = false
    ) async throws -> LocalAIResponse {
        try await prompt(
            LocalAIRequest(
                prompt: text,
                workingDirectory: workingDirectory,
                model: model,
                timeout: timeout,
                autoApprove: autoApprove
            )
        )
    }

    // MARK: - Private

    @MainActor
    private static func resolveBackend(override: LocalAIProviderID?) -> AIBackend {
        if override != nil { return .cli }
        return AppSettings.shared.aiBackend
    }

    @MainActor
    private static func resolveCLIProvider(override: LocalAIProviderID?) -> LocalAIProviderID {
        if let override { return override }
        return LocalAIRegistry.shared.selectedProvider
    }

    @MainActor
    private static func resolveExecutable(for provider: LocalAIProviderID) -> String? {
        // 优先用 Registry 缓存；未命中再即时探测
        if let path = LocalAIRegistry.shared.executablePath(for: provider) {
            return path
        }
        return LocalAIExecutableLocator.path(for: provider)
    }
}
