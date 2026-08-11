//
//  QjiaoAgentAutomation.swift
//  kero
//

import Foundation

/// Agent 生命周期。`blocked` 是受保护输入的关键状态：自动化请求不得越过
/// Agent 当前等待用户确认的界面。
enum QjiaoAgentPhase: String, Codable, CaseIterable, Sendable {
    case created
    case working
    case blocked
    case done
    case idle
    case unknown

    var publicPhase: Self {
        self == .idle ? .done : self
    }
}

enum QjiaoAgentAuthority: String, Codable, Sendable {
    case integration
    case screen
    case process
    case command
}

/// 由自动化启动或 AgentWatcher 识别出的 Agent 状态。
struct QjiaoAgentStatus: Sendable, Equatable {
    var alias: String?
    var kind: AgentKind
    var phase: QjiaoAgentPhase
    var authority: QjiaoAgentAuthority
    var reason: String
    var updatedAt: Date
    var processID: pid_t?
    var unseen: Bool
}

extension QjiaoAgentPhase {
    init(agentStatus: AgentStatus) {
        switch agentStatus {
        case .none: self = .unknown
        case .working: self = .working
        case .blocked: self = .blocked
        case .done: self = .done
        }
    }
}

enum QjiaoAutomationReadError: Error {
    case agentNotIdle
    case unavailable
}

@MainActor
extension TerminalSession {
    /// 统一读取自动化看到的 Agent 状态。显式声明的生命周期优先；没有
    /// 声明时复用现有 AgentWatcher，避免重复实现屏幕规则和轮询。
    func effectiveAutomationAgentStatus() -> QjiaoAgentStatus? {
        let watcher = AgentWatcher.shared
        let observed = watcher.snapshot(for: id)

        if var declared = automationAgent {
            if declared.authority != .integration,
               let observed,
               observed.kind == declared.kind,
               observed.status != .none {
                declared.phase = QjiaoAgentPhase(agentStatus: observed.status)
                declared.authority = .screen
                declared.reason = observed.matchedRuleID ?? "screen_observation"
                declared.updatedAt = observed.updatedAt
            }
            declared.unseen = watcher.isUnread(sessionID: id)
            declared.processID = agentProcessID(for: declared.kind)
            return declared
        }

        guard let observed, let kind = observed.kind, observed.status != .none else {
            return nil
        }
        return QjiaoAgentStatus(
            alias: nil,
            kind: kind,
            phase: QjiaoAgentPhase(agentStatus: observed.status),
            authority: observed.status == .working || observed.status == .blocked
                ? .screen : .process,
            reason: observed.matchedRuleID ?? "agent_watcher",
            updatedAt: observed.updatedAt,
            processID: agentProcessID(for: kind),
            unseen: watcher.isUnread(sessionID: id)
        )
    }

    var isShellAvailableForAutomation: Bool {
        isUsable && isInitialized && shellPid != nil && !isForegroundCommandRunning
    }

    func declareAutomationAgent(alias: String, kind: AgentKind) {
        automationAgent = QjiaoAgentStatus(
            alias: alias,
            kind: kind,
            phase: .created,
            authority: .command,
            reason: "declared",
            updatedAt: .now,
            processID: nil,
            unseen: false
        )
    }

    func isAutomationAgentRunning(kind: AgentKind) -> Bool {
        guard isUsable, isInitialized, isForegroundCommandRunning else { return false }
        return AgentKind.identify(processNames: foregroundJobExecutableNames) == kind
    }

    func markAutomationAgentPrompted() {
        guard var status = automationAgent else { return }
        status.phase = .working
        status.authority = .command
        status.reason = "prompt_sent"
        status.updatedAt = .now
        automationAgent = status
    }

    @discardableResult
    func reportAutomationAgent(
        phase: QjiaoAgentPhase,
        reason: String?
    ) -> Bool {
        guard var status = automationAgent else { return false }
        guard phase != .created else { return false }
        status.phase = phase
        status.authority = .integration
        status.reason = reason ?? "reported"
        status.updatedAt = .now
        automationAgent = status
        return true
    }

    func markAutomationAgentSeen() {
        guard var status = automationAgent else { return }
        status.unseen = false
        automationAgent = status
        AgentWatcher.shared.markRead(sessionID: id)
    }

    func automationReadText(
        maxLines: Int,
        maxColumns: Int,
        requireIdleAgentForHistory: Bool
    ) throws -> String {
        if requireIdleAgentForHistory,
           let status = effectiveAutomationAgentStatus(),
           status.phase == .working || status.phase == .blocked {
            throw QjiaoAutomationReadError.agentNotIdle
        }
        guard isUsable, isInitialized,
              let text = TerminalHistorySerializer.previewText(
                from: terminalView,
                maxLines: maxLines,
                maxColumns: maxColumns
              )
        else { throw QjiaoAutomationReadError.unavailable }
        return text
    }

    private func agentProcessID(for kind: AgentKind) -> pid_t? {
        guard let snapshot = foregroundJobDebugSnapshot() else { return nil }
        return snapshot.processes.first { process in
            let candidates = ([process.execBase].compactMap { $0 } + process.argv).map {
                ($0 as NSString).lastPathComponent
            }
            return AgentKind.identify(processNames: candidates) == kind
        }?.pid
    }
}
