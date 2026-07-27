//
//  LocalAIRegistry.swift
//  kero
//
//  探测本机 AI CLI 安装状态，并与 AppSettings 中的 headless provider 选择同步。
//

import Combine
import Foundation

/// 本地 AI headless 提供器注册表：安装探测 + 当前选择。
///
/// 在主线程使用，可作为 `@ObservedObject` 驱动设置面板。
@MainActor
final class LocalAIRegistry: nonisolated ObservableObject {
    /// 与 `AppSettings.shared` 同生命周期的全局单例。
    static let shared = LocalAIRegistry()

    /// 全部 Provider 的安装状态（含 disabled）。
    @Published private(set) var statuses: [LocalAIProviderStatus] = []

    /// 当前选中的 headless provider（写回 `AppSettings`）。
    @Published var selectedProvider: LocalAIProviderID {
        didSet {
            guard oldValue != selectedProvider else { return }
            // 未安装的 CLI 不允许选中
            if selectedProvider.isAIProvider,
               !isInstalled(selectedProvider) {
                selectedProvider = .disabled
                return
            }
            if AppSettings.shared.localAIHeadlessProvider != selectedProvider {
                AppSettings.shared.localAIHeadlessProvider = selectedProvider
            }
        }
    }

    /// 当前是否启用了本地 AI（非 disabled 且已安装）。
    var isEnabled: Bool {
        selectedProvider.isAIProvider && isInstalled(selectedProvider)
    }

    /// 当前选中项的状态。
    var selectedStatus: LocalAIProviderStatus? {
        statuses.first { $0.provider == selectedProvider }
    }

    private init() {
        selectedProvider = AppSettings.shared.localAIHeadlessProvider
        refresh()
        // 若配置里记了未安装的 CLI，回落到 disabled
        if selectedProvider.isAIProvider, !isInstalled(selectedProvider) {
            selectedProvider = .disabled
        }
    }

    /// 重新探测 PATH / 常见安装目录。
    func refresh() {
        statuses = LocalAIExecutableLocator.probeAll()
        syncFromSettings()
    }

    /// 从 `AppSettings` 拉回选择（Reset Defaults / 外部改配置后调用）。
    func syncFromSettings() {
        let fromSettings = AppSettings.shared.localAIHeadlessProvider
        if fromSettings.isAIProvider, !isInstalled(fromSettings) {
            // 配置里的 CLI 已不存在 → 降级并写回
            if selectedProvider != .disabled {
                selectedProvider = .disabled
            } else if AppSettings.shared.localAIHeadlessProvider != .disabled {
                AppSettings.shared.localAIHeadlessProvider = .disabled
            }
            return
        }
        if selectedProvider != fromSettings {
            selectedProvider = fromSettings
        }
    }

    /// 指定 Provider 是否已安装。
    func isInstalled(_ provider: LocalAIProviderID) -> Bool {
        if provider == .disabled { return true }
        return statuses.first(where: { $0.provider == provider })?.isAvailable == true
    }

    /// 可执行路径；未安装返回 nil。
    func executablePath(for provider: LocalAIProviderID) -> String? {
        statuses.first(where: { $0.provider == provider })?.executablePath
    }

    /// 设置面板用：全部选项（未安装也列出，由 UI 禁用选择）。
    var allStatusesForPicker: [LocalAIProviderStatus] {
        statuses
    }
}
