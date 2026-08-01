//
//  AIAPIRegistry.swift
//  kero
//
//  按需缓存当前 API 密钥状态，避免应用启动时访问 macOS Keychain。
//

import Combine
import Foundation

/// 当前 AI API 配置状态。
@MainActor
final class AIAPIRegistry: nonisolated ObservableObject {
    static let shared = AIAPIRegistry()

    /// 当前供应商是否已在 Keychain 保存 API Key。
    @Published private(set) var hasAPIKey = false

    /// Keychain 读取失败时供设置页展示的错误。
    @Published private(set) var keychainError: String?

    /// 密钥缓存对应的提供方；nil 表示应用启动后尚未读取 Keychain。
    private var loadedProvider: AIAPIProviderID?

    private init() {}

    /// 设置页或实际请求读取密钥后，用已有结果更新缓存，不再次访问 Keychain。
    func recordKeyState(_ apiKey: String, for provider: AIAPIProviderID) {
        loadedProvider = provider
        hasAPIKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        keychainError = nil
    }

    /// 记录按需读取 Keychain 时的失败状态。
    func recordKeychainError(_ error: Error, for provider: AIAPIProviderID) {
        loadedProvider = provider
        hasAPIKey = false
        keychainError = error.localizedDescription
    }

    /// 当前 API 配置是否足以发起请求。
    var isEnabled: Bool {
        let settings = AppSettings.shared
        let hasValidFields = !settings.aiAPIModel
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.aiAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 尚未按需读取时不为了按钮状态提前查询 Keychain；实际请求会校验密钥。
        let keyIsUsable = loadedProvider == settings.aiAPIProvider ? hasAPIKey : true
        return hasValidFields && keyIsUsable
    }

    /// 从 AppSettings 与 Keychain 生成一次调用使用的不可变配置。
    func configuration() throws -> AIAPIConfiguration {
        let settings = AppSettings.shared
        let provider = settings.aiAPIProvider
        let apiKey: String
        do {
            apiKey = try AIAPIKeyStore.load(for: provider)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            recordKeyState(apiKey, for: provider)
        } catch {
            recordKeychainError(error, for: provider)
            throw error
        }
        let model = settings.aiAPIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = settings.aiAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw LocalAIError.invalidAPIConfiguration(L10n.t("Enter and save an API Key."))
        }
        guard !model.isEmpty else {
            throw LocalAIError.invalidAPIConfiguration(L10n.t("Enter an AI model ID."))
        }
        guard !baseURL.isEmpty else {
            throw LocalAIError.invalidAPIConfiguration(L10n.t("Enter an API base URL."))
        }
        return AIAPIConfiguration(
            provider: provider,
            apiKey: apiKey,
            model: model,
            baseURL: baseURL
        )
    }
}
