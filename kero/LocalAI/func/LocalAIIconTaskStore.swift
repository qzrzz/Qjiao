//
//  LocalAIIconTaskStore.swift
//  kero
//
//  跟踪「AI Select Icon」后台任务：项目行可显示进度，并支持取消。
//

import Combine
import Foundation
import SwiftUI

/// 单个项目的 AI 选图标任务状态。
struct LocalAIIconTaskState: Equatable, Sendable {
    /// 是否正在跑 headless CLI。
    var isRunning: Bool = false
    /// 最近一次失败信息（成功或取消后清空）。
    var lastError: String?
    /// 使用的 provider 展示名（进行中时用于副文案）。
    var providerLabel: String?
}

/// 全局 AI 选图标任务表：按 `Project.id` 管理，菜单关掉后进度仍可见。
@MainActor
final class LocalAIIconTaskStore: ObservableObject {
    static let shared = LocalAIIconTaskStore()

    /// projectId → 状态；视图用 `state(for:)` 读取。
    @Published private(set) var states: [UUID: LocalAIIconTaskState] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// 某项目是否正在 AI 选图标。
    func isRunning(_ projectID: UUID) -> Bool {
        states[projectID]?.isRunning == true
    }

    /// 读取状态（无记录时返回默认空闲）。
    func state(for projectID: UUID) -> LocalAIIconTaskState {
        states[projectID] ?? LocalAIIconTaskState()
    }

    /// 启动（或重启）指定项目的 AI 选图标；立即返回，在后台完成。
    func start(for project: Project) {
        guard LocalAI.isEnabled else {
            var s = states[project.id] ?? LocalAIIconTaskState()
            s.isRunning = false
            s.lastError =
                "Local AI is disabled. Choose an AI headless provider in Settings → General."
            s.providerLabel = nil
            states[project.id] = s
            return
        }

        // 与「Name & Desc & Icon」互斥，避免双写 icon
        LocalAIProjectMetaTaskStore.shared.cancel(project.id, clearError: true)
        // 已有图标任务则先取消
        cancel(project.id, clearError: true)

        let providerLabel = LocalAI.selectedProvider.displayName
        states[project.id] = LocalAIIconTaskState(
            isRunning: true,
            lastError: nil,
            providerLabel: providerLabel
        )

        let projectID = project.id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tasks[projectID] = nil
                var done = self.states[projectID] ?? LocalAIIconTaskState()
                done.isRunning = false
                done.providerLabel = nil
                self.states[projectID] = done
            }

            do {
                try Task.checkCancellation()
                _ = try await LocalAIIconSuggest.apply(to: project)
                // 成功：清错误
                var ok = self.states[projectID] ?? LocalAIIconTaskState()
                ok.lastError = nil
                self.states[projectID] = ok
            } catch is CancellationError {
                // 用户取消：不弹错误
                var cancelled = self.states[projectID] ?? LocalAIIconTaskState()
                cancelled.lastError = nil
                self.states[projectID] = cancelled
            } catch {
                // 进程被 cancel 终止时，部分 CLI 以非 0 退出；若 Task 已取消则忽略
                if Task.isCancelled { return }
                var failed = self.states[projectID] ?? LocalAIIconTaskState()
                failed.lastError = error.localizedDescription
                self.states[projectID] = failed
            }
        }
        tasks[projectID] = task
    }

    /// 取消进行中的任务并尽量杀掉 CLI 子进程。
    func cancel(_ projectID: UUID, clearError: Bool = false) {
        tasks[projectID]?.cancel()
        tasks[projectID] = nil
        var s = states[projectID] ?? LocalAIIconTaskState()
        s.isRunning = false
        s.providerLabel = nil
        if clearError {
            s.lastError = nil
        }
        states[projectID] = s
    }

    /// 清除错误条（用户 dismiss 后）。
    func clearError(_ projectID: UUID) {
        guard var s = states[projectID] else { return }
        s.lastError = nil
        states[projectID] = s
    }
}
