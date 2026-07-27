//
//  LocalAIProjectMetaTaskStore.swift
//  kero
//
//  跟踪「AI Name & Desc & Icon」后台任务：项目行可显示进度，并支持取消。
//

import Combine
import Foundation
import SwiftUI

/// 单个项目的 AI 元数据任务状态。
struct LocalAIProjectMetaTaskState: Equatable, Sendable {
    /// 是否正在跑 headless CLI。
    var isRunning: Bool = false
    /// 最近一次失败信息。
    var lastError: String?
    /// 使用的 provider 展示名。
    var providerLabel: String?
}

/// 全局 AI 项目元数据任务表：按 `Project.id` 管理。
@MainActor
final class LocalAIProjectMetaTaskStore: ObservableObject {
    static let shared = LocalAIProjectMetaTaskStore()

    @Published private(set) var states: [UUID: LocalAIProjectMetaTaskState] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func isRunning(_ projectID: UUID) -> Bool {
        states[projectID]?.isRunning == true
    }

    func state(for projectID: UUID) -> LocalAIProjectMetaTaskState {
        states[projectID] ?? LocalAIProjectMetaTaskState()
    }

    /// 启动（或重启）AI 生成名称 / 描述 / 图标。
    ///
    /// 会取消同项目的「AI Select Icon」任务，避免双写 icon。
    func start(for project: Project) {
        guard LocalAI.isEnabled else {
            var s = states[project.id] ?? LocalAIProjectMetaTaskState()
            s.isRunning = false
            s.lastError =
                "Local AI is disabled. Choose an AI headless provider in Settings → General."
            s.providerLabel = nil
            states[project.id] = s
            return
        }

        // 与纯选图标互斥
        LocalAIIconTaskStore.shared.cancel(project.id, clearError: true)
        cancel(project.id, clearError: true)

        let providerLabel = LocalAI.selectedProvider.displayName
        states[project.id] = LocalAIProjectMetaTaskState(
            isRunning: true,
            lastError: nil,
            providerLabel: providerLabel
        )

        let projectID = project.id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tasks[projectID] = nil
                var done = self.states[projectID] ?? LocalAIProjectMetaTaskState()
                done.isRunning = false
                done.providerLabel = nil
                self.states[projectID] = done
            }

            do {
                try Task.checkCancellation()
                _ = try await LocalAIProjectMetaSuggest.apply(to: project)
                var ok = self.states[projectID] ?? LocalAIProjectMetaTaskState()
                ok.lastError = nil
                self.states[projectID] = ok
            } catch is CancellationError {
                var cancelled = self.states[projectID] ?? LocalAIProjectMetaTaskState()
                cancelled.lastError = nil
                self.states[projectID] = cancelled
            } catch {
                if Task.isCancelled { return }
                var failed = self.states[projectID] ?? LocalAIProjectMetaTaskState()
                failed.lastError = error.localizedDescription
                self.states[projectID] = failed
            }
        }
        tasks[projectID] = task
    }

    func cancel(_ projectID: UUID, clearError: Bool = false) {
        tasks[projectID]?.cancel()
        tasks[projectID] = nil
        var s = states[projectID] ?? LocalAIProjectMetaTaskState()
        s.isRunning = false
        s.providerLabel = nil
        if clearError {
            s.lastError = nil
        }
        states[projectID] = s
    }

    func clearError(_ projectID: UUID) {
        guard var s = states[projectID] else { return }
        s.lastError = nil
        states[projectID] = s
    }
}
