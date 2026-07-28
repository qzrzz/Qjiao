//
//  L10n.swift
//  kero/L10n
//
//  Runtime UI localization. English is the source language and default.
//  Per-language tables live alongside this file (e.g. zh-Hans.swift).
//  To add a language: AppLanguage case + table file + switch in `t(_:)`.
//

import Combine
import Foundation
import SwiftUI

/// Supported UI languages. Default is English (`en`).
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    /// Name shown in the language picker (always in the language itself).
    var nativeDisplayName: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

/// App-wide localization store. Views observe `shared` so they refresh when
/// the user switches language; call `L10n.t("English text")` for UI strings.
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    /// Published mirror for SwiftUI observation.
    @Published private(set) var language: AppLanguage = .english

    /// Snapshot readable from any isolation (menus, models, theme titles).
    nonisolated(unsafe) private static var currentLanguage: AppLanguage = .english

    private init() {}

    /// Apply a language without writing settings (used from `AppSettings` load/save).
    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        Self.currentLanguage = language
    }

    /// Translate an English source string. Missing keys fall back to English.
    /// Safe to call from any isolation / non-UI code.
    nonisolated static func t(_ key: String) -> String {
        switch currentLanguage {
        case .english:
            return key
        case .chineseSimplified:
            return zhHans[key] ?? key
        }
    }

    /// Translate then apply `String(format:)` placeholders (`%@`, `%d`, …).
    nonisolated static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = t(key)
        return String(format: template, locale: currentLanguage.locale, arguments: args)
    }

    /// Instance helper for views that already hold `@ObservedObject var l10n`.
    func t(_ key: String) -> String {
        Self.t(key)
    }
}

// MARK: - SwiftUI helpers

extension View {
    /// Observe language changes so localized strings in this view refresh.
    func observeLocalization() -> some View {
        modifier(L10nObserveModifier())
    }
}

private struct L10nObserveModifier: ViewModifier {
    @ObservedObject private var l10n = L10n.shared

    func body(content: Content) -> some View {
        // Reading `language` creates a dependency so the view tree re-renders.
        content.environment(\.l10nLanguage, l10n.language)
    }
}

private struct L10nLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .english
}

extension EnvironmentValues {
    /// Current UI language; set by `observeLocalization()`.
    var l10nLanguage: AppLanguage {
        get { self[L10nLanguageKey.self] }
        set { self[L10nLanguageKey.self] = newValue }
    }
}
