//
//  AIAPIKeyStore.swift
//  kero
//
//  使用 macOS Keychain 保存各 AI API 供应商的密钥，避免明文进入 config.toml。
//

import Foundation
import Security

/// AI API Key 的 Keychain 读写工具。
enum AIAPIKeyStore {
    /// 读取指定供应商的 API Key；尚未保存时返回空字符串。
    static func load(for provider: AIAPIProviderID) throws -> String {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw AIAPIKeyStoreError.keychain(status)
        }
        return value
    }

    /// 新增或覆盖指定供应商的 API Key；空值等同删除。
    static func save(_ apiKey: String, for provider: AIAPIProviderID) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            try delete(for: provider)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(for: provider)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AIAPIKeyStoreError.keychain(updateStatus)
        }

        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIAPIKeyStoreError.keychain(addStatus)
        }
    }

    /// 删除指定供应商保存的 API Key。
    static func delete(for provider: AIAPIProviderID) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIAPIKeyStoreError.keychain(status)
        }
    }

    /// Keychain Service 按应用隔离，Account 按供应商隔离。
    private static func baseQuery(for provider: AIAPIProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.qzrzz.qjiao.ai-api",
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

/// Keychain 操作失败。
enum AIAPIKeyStoreError: Error, LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return L10n.format("Could not access API Key in Keychain: %@", detail)
        }
    }
}
