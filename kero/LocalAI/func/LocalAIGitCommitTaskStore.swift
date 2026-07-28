//
//  LocalAIGitCommitTaskStore.swift
//  kero
//
//  跟踪「AI Git Commit Message」后台任务：Git 面板按钮可显示进度并支持取消。
//  按仓库根路径（canonical）管理，与图标任务按 Project.id 区分。
//

import Combine
import Foundation
import SwiftUI

/// 单个仓库的 AI Commit Message 任务状态。
struct LocalAIGitCommitTaskState: Equatable, Sendable {
    /// 是否正在跑 headless CLI。
    var isRunning: Bool = false
    /// 最近一次失败信息（成功或取消后清空）。
    var lastError: String?
    /// 使用的 provider 展示名（进行中时用于副文案）。
    var providerLabel: String?
    /// 最近一次成功生成的 message（UI 写入输入框后可清）。
    var lastMessage: String?
}

/// 全局 AI Commit Message 任务表：按仓库根路径管理。
@MainActor
final class LocalAIGitCommitTaskStore: ObservableObject {
    static let shared = LocalAIGitCommitTaskStore()

    /// repoRoot → 状态。
    @Published private(set) var states: [String: LocalAIGitCommitTaskState] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    /// 某仓库是否正在生成。
    func isRunning(_ repoRoot: String) -> Bool {
        states[normalize(repoRoot)]?.isRunning == true
    }

    /// 读取状态（无记录时返回默认空闲）。
    func state(for repoRoot: String) -> LocalAIGitCommitTaskState {
        states[normalize(repoRoot)] ?? LocalAIGitCommitTaskState()
    }

    /// 启动（或重启）指定仓库的 AI Commit Message 生成。
    ///
    /// - Parameters:
    ///   - repoRoot: 仓库根目录。
    ///   - language: 已解析的写作语言。
    ///   - useEmoji: 是否 Gitmoji。
    func start(repoRoot: String, language: AIWritingLanguage, useEmoji: Bool) {
        let key = normalize(repoRoot)
        guard !key.isEmpty else {
            var s = states[key] ?? LocalAIGitCommitTaskState()
            s.isRunning = false
            s.lastError = L10n.t("No Git repository available.")
            s.providerLabel = nil
            s.lastMessage = nil
            states[key] = s
            return
        }

        guard LocalAI.isEnabled else {
            var s = states[key] ?? LocalAIGitCommitTaskState()
            s.isRunning = false
            s.lastError =
                "Local AI is disabled. Choose an AI headless provider in Settings → General."
            s.providerLabel = nil
            s.lastMessage = nil
            states[key] = s
            return
        }

        cancel(key, clearError: true)

        let providerLabel = LocalAI.selectedProvider.displayName
        states[key] = LocalAIGitCommitTaskState(
            isRunning: true,
            lastError: nil,
            providerLabel: providerLabel,
            lastMessage: nil
        )

        // 在非隔离 Task 中跑 CLI；仅更新状态时回主线程，保证结束后一定关转圈
        let task = Task { [weak self] in
            guard let self else { return }

            var nextMessage: String?
            var nextError: String?
            var cancelled = false

            do {
                try Task.checkCancellation()
                let suggestion = try await LocalAIGitCommitSuggest.suggest(
                    repoRoot: key,
                    language: language,
                    useEmoji: useEmoji
                )
                nextMessage = suggestion.message
            } catch is CancellationError {
                cancelled = true
            } catch {
                if Task.isCancelled {
                    cancelled = true
                } else {
                    nextError = error.localizedDescription
                }
            }

            await MainActor.run {
                // 若期间已启动新任务，勿覆盖新状态
                guard self.tasks[key] != nil else { return }
                self.tasks[key] = nil
                var done = self.states[key] ?? LocalAIGitCommitTaskState()
                done.isRunning = false
                done.providerLabel = nil
                if cancelled {
                    done.lastError = nil
                    done.lastMessage = nil
                } else if let nextMessage {
                    done.lastError = nil
                    done.lastMessage = nextMessage
                } else {
                    done.lastError = nextError
                    done.lastMessage = nil
                }
                self.states[key] = done
            }
        }
        tasks[key] = task
    }

    /// 取消进行中的任务。
    func cancel(_ repoRoot: String, clearError: Bool = false) {
        let key = normalize(repoRoot)
        tasks[key]?.cancel()
        tasks[key] = nil
        var s = states[key] ?? LocalAIGitCommitTaskState()
        s.isRunning = false
        s.providerLabel = nil
        if clearError {
            s.lastError = nil
        }
        // 取消时丢弃未消费的 message
        s.lastMessage = nil
        states[key] = s
    }

    /// 清除错误条。
    func clearError(_ repoRoot: String) {
        let key = normalize(repoRoot)
        guard var s = states[key] else { return }
        s.lastError = nil
        states[key] = s
    }

    /// 消费并清除 `lastMessage`（UI 已写入输入框后调用）。
    func consumeMessage(_ repoRoot: String) -> String? {
        let key = normalize(repoRoot)
        guard var s = states[key], let msg = s.lastMessage else { return nil }
        s.lastMessage = nil
        states[key] = s
        return msg
    }

    private func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
