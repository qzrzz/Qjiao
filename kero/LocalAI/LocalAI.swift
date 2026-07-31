//
//  LocalAI.swift
//  kero
//
//  本地 AI 统一门面：应用通过此接口调用 headless / exec 模式的 AI CLI。
//
//  支持：grok（--single）、codex（exec）、claude（-p）、agy（--print）、opencode（run）、pi（-p）。
//  全局设置：Settings → General → AI headless provider。
//

import Foundation

/// 本地 AI 功能统一入口。
///
/// 使用前请在设置中选择已安装的 CLI；未选择或 disabled 时 `prompt` 会抛出 `LocalAIError.disabled`。
enum LocalAI {
    /// 当前是否启用且选中 CLI 已安装。
    @MainActor
    static var isEnabled: Bool {
        LocalAIRegistry.shared.isEnabled
    }

    /// 当前选中的 Provider。
    @MainActor
    static var selectedProvider: LocalAIProviderID {
        LocalAIRegistry.shared.selectedProvider
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

    /// 执行单轮提示（使用全局设置中的 headless provider，除非 request 覆盖）。
    ///
    /// - Parameter request: 提示词与可选工作目录、模型、超时等。
    /// - Returns: 解析后的文本与原始 stdout/stderr。
    static func prompt(_ request: LocalAIRequest) async throws -> LocalAIResponse {
        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAIError.emptyPrompt
        }

        let provider = await resolveProvider(override: request.providerOverride)
        guard provider.isAIProvider else {
            throw LocalAIError.disabled
        }

        let executable = await resolveExecutable(for: provider)
        guard let executable else {
            throw LocalAIError.notInstalled(provider)
        }

        var normalized = request
        normalized.prompt = trimmed

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
            provider: provider,
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
    private static func resolveProvider(override: LocalAIProviderID?) -> LocalAIProviderID {
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
