//
//  AIAPIRegistry.swift
//  kero
//
//  缓存当前 API 配置是否完整，供设置页与现有 AI 功能即时刷新启用状态。
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

    private init() {
        refreshKeyState()
    }

    /// API Key、供应商切换或设置页出现后刷新缓存。
    func refreshKeyState() {
        do {
            hasAPIKey = try !AIAPIKeyStore.load(for: AppSettings.shared.aiAPIProvider).isEmpty
            keychainError = nil
        } catch {
            hasAPIKey = false
            keychainError = error.localizedDescription
        }
    }

    /// 当前 API 配置是否足以发起请求。
    var isEnabled: Bool {
        let settings = AppSettings.shared
        return hasAPIKey
            && !settings.aiAPIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.aiAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 从 AppSettings 与 Keychain 生成一次调用使用的不可变配置。
    func configuration() throws -> AIAPIConfiguration {
        let settings = AppSettings.shared
        let provider = settings.aiAPIProvider
        let apiKey = try AIAPIKeyStore.load(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
