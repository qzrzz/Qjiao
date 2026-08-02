//
//  AgentWatcher.swift
//  kero
//
//  低频检测终端内 Coding Agent 状态（标题 + 屏幕尾部规则）。
//  性能策略：先廉价识别进程；仅对已识别 Agent 做读标题/读屏；读屏有最短间隔。
//  未读：working → done 且终端对用户不可见时标记；用户看见后清除。
//

import AppKit
import Combine
import Foundation
import GhosttyTerminal

/// 全局 Agent 状态观察者。主线程使用；对外只读 `states` / `snapshot(for:)` / `isUnread(sessionID:)`。
@MainActor
final class AgentWatcher: ObservableObject {
    static let shared = AgentWatcher()

    /// sessionID → 最新快照。
    @Published private(set) var states: [UUID: AgentSnapshot] = [:]
    /// working → done 且当时不可见的 session，Tab 显示未读蓝点。
    @Published private(set) var unreadSessionIDs: Set<UUID> = []

    /// 进程识别轮询间隔（廉价）。
    private static let processPollInterval: TimeInterval = 2.0
    /// 已识别 Agent 的读屏最短间隔（昂贵：write_screen_file）。
    private static let screenScanInterval: TimeInterval = 3.0
    /// 读屏行数上限（对齐 herdr 底部缓冲规模）。
    private static let screenMaxLines = 28
    private static let screenMaxColumns = 200

    private var processTask: Task<Void, Never>?
    private var isActive = false
    private weak var manager: TerminalManager?
    private var activationObservers: [NSObjectProtocol] = []

    /// 每个 session 上次完整检测时间（含读屏）。
    private var lastScreenScanAt: [UUID: Date] = [:]
    /// 已识别为 Agent 的 session；进程消失后清理。
    private var knownAgentSessions: Set<UUID> = []
    /// 跳过状态更新时保留的上一次语义状态。
    private var lastSemanticStatus: [UUID: AgentStatus] = [:]

    private init() {}

    // MARK: - Public API

    /// 绑定 TerminalManager 并启动后台轮询。
    func activate(manager: TerminalManager) {
        self.manager = manager
        guard !isActive else { return }
        isActive = true
        AgentManifestStore.warmUp(kinds: [
            .claude, .codex, .agy, .pi, .opencode, .grok,
        ])
        installActivationObservers()
        startProcessLoop()
    }

    /// 停止轮询（保留缓存状态与未读）。
    func deactivate() {
        isActive = false
        processTask?.cancel()
        processTask = nil
        removeActivationObservers()
    }

    /// 读取某 session 的最新快照。
    func snapshot(for sessionID: UUID) -> AgentSnapshot? {
        states[sessionID]
    }

    /// 是否有未读（Agent 在不可见时完成工作）。
    func isUnread(sessionID: UUID) -> Bool {
        unreadSessionIDs.contains(sessionID)
    }

    /// 项目下未读 Agent session 数量（侧栏角标用）。
    func unreadCount(for project: Project) -> Int {
        guard !unreadSessionIDs.isEmpty else { return 0 }
        var count = 0
        for session in project.sessions {
            if unreadSessionIDs.contains(session.id) {
                count += 1
            }
        }
        return count
    }

    /// 手动标记已读（选中对应 Tab / 看见终端时也会自动清除）。
    func markRead(sessionID: UUID) {
        guard unreadSessionIDs.contains(sessionID) else { return }
        var next = unreadSessionIDs
        next.remove(sessionID)
        unreadSessionIDs = next
    }

    /// 立即对指定 session 做一次检测（仍遵守读屏最短间隔，除非 `forceScreen`）。
    func refresh(session: TerminalSession, forceScreen: Bool = false) {
        _ = evaluate(session: session, forceScreen: forceScreen, now: .now)
    }

    // MARK: - Loop

    private func startProcessLoop() {
        processTask?.cancel()
        processTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { break }
                self.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.processPollInterval * 1_000_000_000))
            }
        }
    }

    private func tick() {
        guard let manager else { return }
        // 未读依赖「非当前项目」完成：扫描全部项目 session。
        // 进程识别廉价；读屏仍只对已识别 Agent 且有间隔。
        let targets = manager.projects.flatMap(\.sessions)
        let liveIDs = Set(targets.map(\.id))

        let now = Date()
        for session in targets {
            _ = evaluate(session: session, forceScreen: false, now: now)
        }

        // 用户已看见的终端：清除未读。
        clearUnreadForAttendedSessions(in: targets)

        // 清理已关闭 session
        let stale = states.keys.filter { !liveIDs.contains($0) }
        for id in stale {
            states.removeValue(forKey: id)
            lastScreenScanAt.removeValue(forKey: id)
            lastSemanticStatus.removeValue(forKey: id)
            knownAgentSessions.remove(id)
            markRead(sessionID: id)
        }
        // 未读集合中已不存在的 id
        if !unreadSessionIDs.isSubset(of: liveIDs) {
            unreadSessionIDs = unreadSessionIDs.intersection(liveIDs)
        }
    }

    // MARK: - Detect

    @discardableResult
    private func evaluate(
        session: TerminalSession,
        forceScreen: Bool,
        now: Date
    ) -> AgentSnapshot {
        let sessionID = session.id

        guard session.isUsable, session.isInitialized else {
            return publishNone(session: session, at: now)
        }

        // 1) 廉价：前台进程识别（含 ghost-complete 等 PTY 代理下的子孙扫描）
        guard session.isForegroundCommandRunning,
              session.shellPid != nil
        else {
            knownAgentSessions.remove(sessionID)
            return publishNone(session: session, at: now)
        }

        let names = session.foregroundJobExecutableNames
        guard let kind = AgentKind.identify(processNames: names) else {
            knownAgentSessions.remove(sessionID)
            return publishNone(session: session, at: now)
        }

        knownAgentSessions.insert(sessionID)

        // 无屏幕 manifest 的 Agent：仅根据「进程在前台」粗分为 working。
        guard kind.hasScreenManifest, let manifest = AgentManifestStore.manifest(for: kind) else {
            let snap = AgentSnapshot(
                sessionID: sessionID,
                kind: kind,
                status: .working,
                matchedRuleID: "process_present",
                updatedAt: now
            )
            publish(snap, session: session)
            return snap
        }

        // 2) 标题始终可读（免费）
        let title = session.title

        // 3) 读屏：仅 Agent 且达到间隔
        let shouldScanScreen: Bool = {
            if forceScreen { return true }
            guard let last = lastScreenScanAt[sessionID] else { return true }
            return now.timeIntervalSince(last) >= Self.screenScanInterval
        }()

        var screen = ""
        if shouldScanScreen {
            lastScreenScanAt[sessionID] = now
            screen = captureScreenTail(from: session) ?? ""
        } else if let previous = states[sessionID], previous.kind == kind {
            // 间隔内：仅用标题重评
            let titleOnly = AgentRuleEngine.detect(
                manifest: manifest,
                input: AgentDetectionInput(screen: "", oscTitle: title, oscProgress: "")
            )
            if !titleOnly.skipStateUpdate,
               let status = titleOnly.state.publishedStatus,
               status != .done || titleOnly.visibleIdle {
                if titleOnly.matchedRuleID != nil {
                    let snap = AgentSnapshot(
                        sessionID: sessionID,
                        kind: kind,
                        status: status,
                        matchedRuleID: titleOnly.matchedRuleID,
                        updatedAt: now
                    )
                    lastSemanticStatus[sessionID] = status
                    publish(snap, session: session)
                    return snap
                }
            }
            // 保持缓存（仍可能需要清未读）
            if isSessionAttended(session) {
                markRead(sessionID: sessionID)
            }
            if var cached = states[sessionID] {
                cached.updatedAt = now
                return cached
            }
        }

        let detection = AgentRuleEngine.detect(
            manifest: manifest,
            input: AgentDetectionInput(screen: screen, oscTitle: title, oscProgress: "")
        )

        if detection.skipStateUpdate {
            if let previous = states[sessionID], previous.kind == kind {
                var kept = previous
                kept.updatedAt = now
                kept.matchedRuleID = detection.matchedRuleID ?? previous.matchedRuleID
                publish(kept, session: session)
                return kept
            }
        }

        let status: AgentStatus
        if let published = detection.state.publishedStatus {
            status = published
        } else if let last = lastSemanticStatus[sessionID] {
            status = last
        } else {
            status = .done
        }

        lastSemanticStatus[sessionID] = status
        let snap = AgentSnapshot(
            sessionID: sessionID,
            kind: kind,
            status: status,
            matchedRuleID: detection.matchedRuleID ?? "default_known_agent_idle_fallback",
            updatedAt: now
        )
        publish(snap, session: session)
        return snap
    }

    private func captureScreenTail(from session: TerminalSession) -> String? {
        guard session.isInitialized, session.isUsable else { return nil }
        return TerminalHistorySerializer.previewText(
            from: session.terminalView,
            maxLines: Self.screenMaxLines,
            maxColumns: Self.screenMaxColumns
        )
    }

    private func publishNone(session: TerminalSession, at date: Date) -> AgentSnapshot {
        let snap = AgentSnapshot.none(sessionID: session.id, at: date)
        lastSemanticStatus.removeValue(forKey: session.id)
        publish(snap, session: session)
        return snap
    }

    private func publish(_ snap: AgentSnapshot, session: TerminalSession) {
        let previousStatus = states[snap.sessionID]?.status ?? lastSemanticStatus[snap.sessionID]

        // working → done 且用户看不见：标记未读；无论是否可见都播放完成音效。
        if previousStatus == .working,
           snap.status == .done {
            SoundEffects.shared.play(.agentCompleted)
            if !isSessionAttended(session) {
                markUnread(sessionID: snap.sessionID)
            }
        }

        // 转为 blocked（待处理）：无论是否可见都播放 Blocked 待处理音效；未看见则标记未读。
        if previousStatus != .blocked,
           snap.status == .blocked {
            SoundEffects.shared.play(.agentBlocked)
            if !isSessionAttended(session) {
                markUnread(sessionID: snap.sessionID)
            }
        }

        // 已看见：清除未读。
        if isSessionAttended(session) {
            markRead(sessionID: snap.sessionID)
        }

        if let existing = states[snap.sessionID],
           existing.kind == snap.kind,
           existing.status == snap.status,
           existing.matchedRuleID == snap.matchedRuleID {
            return
        }
        states[snap.sessionID] = snap
    }

    // MARK: - Unread / visibility

    private func markUnread(sessionID: UUID) {
        guard !unreadSessionIDs.contains(sessionID) else { return }
        var next = unreadSessionIDs
        next.insert(sessionID)
        unreadSessionIDs = next
    }

    /// 终端对用户「可见」：应用激活 + 当前项目 + 当前 Tab 内含该 session。
    private func isSessionAttended(_ session: TerminalSession) -> Bool {
        // 窗口 / 应用非激活
        guard NSApp.isActive else { return false }
        // 无 key window 时视为未聚焦（例如全部最小化）
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else {
            return false
        }
        _ = keyWindow

        guard let manager,
              let project = manager.selectedProject
        else { return false }

        // 非当前项目
        let inSelectedProject = project.tabs.contains { tab in
            tab.sessions.contains { $0.id == session.id }
        }
        guard inSelectedProject else { return false }

        // 非当前 Tab
        guard let tab = project.selectedTab,
              tab.sessions.contains(where: { $0.id == session.id })
        else { return false }

        return true
    }

    private func clearUnreadForAttendedSessions(in sessions: [TerminalSession]) {
        guard !unreadSessionIDs.isEmpty else { return }
        for session in sessions where unreadSessionIDs.contains(session.id) {
            if isSessionAttended(session) {
                markRead(sessionID: session.id)
            }
        }
    }

    private func installActivationObservers() {
        removeActivationObservers()
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.clearUnreadForCurrentlyVisible()
            }
        }
        activationObservers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main,
                using: handler
            ),
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main,
                using: handler
            ),
        ]
    }

    private func removeActivationObservers() {
        for token in activationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        activationObservers = []
    }

    private func clearUnreadForCurrentlyVisible() {
        guard let manager else { return }
        clearUnreadForAttendedSessions(in: manager.projects.flatMap(\.sessions))
    }
}
