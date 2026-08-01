//
//  AgentStatus.swift
//  kero
//
//  Agent 运行状态模型（对齐 herdr：blocked / working / idle→done）。
//

import Foundation

/// Agent 语义状态。对外用 `done` 表示 herdr 的 `idle`（一轮结束、等待输入）。
enum AgentStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    /// 当前终端前台不是已知 Agent。
    case none
    /// Agent 正在思考 / 调用工具 / 输出。
    case working
    /// 需要人类确认（权限、问答、选择等）。
    case blocked
    /// Agent 空闲（提示符可见，等待下一条指令）。
    case done

    /// Info 面板与调试展示用文案（英文 key，走 L10n）。
    var displayKey: String {
        switch self {
        case .none: return "None"
        case .working: return "Working"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }
}

/// 单次检测结果。
struct AgentSnapshot: Equatable, Sendable {
    var sessionID: UUID
    /// 识别到的 Agent；`status == .none` 时为 nil。
    var kind: AgentKind?
    var status: AgentStatus
    /// 命中的规则 id，便于调试。
    var matchedRuleID: String?
    var updatedAt: Date

    static func none(sessionID: UUID, at date: Date = .now) -> AgentSnapshot {
        AgentSnapshot(
            sessionID: sessionID,
            kind: nil,
            status: .none,
            matchedRuleID: nil,
            updatedAt: date
        )
    }
}

/// 规则引擎内部状态（含 herdr 的 unknown + skip）。
enum AgentRuleState: String, Sendable, Equatable {
    case working
    case blocked
    /// herdr idle → 对外 done。
    case idle
    case unknown

    var publishedStatus: AgentStatus? {
        switch self {
        case .working: return .working
        case .blocked: return .blocked
        case .idle: return .done
        case .unknown: return nil
        }
    }

    static func parse(_ raw: String) -> AgentRuleState? {
        switch raw.lowercased() {
        case "working": return .working
        case "blocked": return .blocked
        case "idle", "done": return .idle
        case "unknown": return .unknown
        default: return nil
        }
    }
}
