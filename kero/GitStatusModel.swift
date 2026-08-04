//
//  GitStatusModel.swift
//  kero
//

import Combine
import Dispatch
import Foundation

/// Loads repository state in response to explicit UI events and performs
/// source-control operations without blocking the UI.
@MainActor
final class GitStatusModel: nonisolated ObservableObject {
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        var id: String { path }
        /// Relative to the repository root, as porcelain v2 reports it.
        let path: String
        /// Index (staged) status letter, "." when clean, "?" for untracked.
        let staged: Character
        /// Worktree (unstaged) status letter.
        let unstaged: Character
        var isConflict = false
        /// Previous path for renames/copies (porcelain "2" entries).
        var origPath: String?
        /// Canonical repo that produced this snapshot. Mutations reject stale
        /// rows after the active terminal moves to another repository.
        var repositoryRoot = ""

        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }
        /// porcelain `normal`（VS Code mixed）模式下，完全未跟踪目录折叠为
        /// 单个条目且 path 带尾斜杠（`? dir/`）；其他记录不带尾斜杠。
        var isDirectoryEntry: Bool { path.hasSuffix("/") }
        /// Intent-to-add (`git add -N`) is represented as `.A`; restoring it
        /// from the empty index blob would truncate user content, so destructive
        /// handling treats it like an untracked file and uses the Trash.
        var isIntentToAdd: Bool { staged == "." && unstaged == "A" }
        var isUntracked: Bool { staged == "?" || isIntentToAdd }
        var isWorktreeRename: Bool { unstaged == "R" && origPath != nil }
        var isWorktreeCopy: Bool { unstaged == "C" && origPath != nil }

        // A file can sit in two sections at once (for example, "MM"). Rows in
        // the same lazy stack need distinct identities or SwiftUI drops one.
        var mergeRowID: String { "merge/" + path }
        var stagedRowID: String { "staged/" + path }
        var changedRowID: String { "changed/" + path }

        /// 乐观更新时生成状态字母变化后的副本（path / repositoryRoot 保留）。
        func withStatus(
            staged: Character,
            unstaged: Character,
            origPath: String? = nil
        ) -> Entry {
            var copy = Entry(
                path: path,
                staged: staged,
                unstaged: unstaged,
                isConflict: isConflict,
                origPath: origPath ?? self.origPath
            )
            copy.repositoryRoot = repositoryRoot
            return copy
        }
    }

    /// Compact Explorer-style decoration for a path in the active repository.
    /// The file tree maps these semantic states to both a color and a visible
    /// status badge, so color is never the only indication.
    nonisolated enum FileDecoration: Equatable, Sendable {
        case modified
        case added
        case untracked
        case deleted
        case renamed
        case copied
        case conflict
        case ignored

        /// When a directory contains several changed files, bubble up the
        /// state that most needs attention.
        var directoryPriority: Int {
            switch self {
            case .conflict: 8
            case .deleted: 7
            case .modified: 6
            case .added: 5
            case .untracked: 4
            case .renamed: 3
            case .copied: 2
            case .ignored: 1
            }
        }
    }

    nonisolated struct RecentCommit: Identifiable, Equatable, Sendable {
        var id: String { hash }
        let hash: String
        let shortHash: String
        let subject: String
        let author: String
        let relativeDate: String
    }

    /// stage / commit 前的列表快照；失败时回滚乐观更新。
    private struct ResourceSnapshot {
        var mergeEntries: [Entry]
        var stagedEntries: [Entry]
        var changedEntries: [Entry]
        var fileDecorations: [String: FileDecoration]
        var directoryDecorations: [String: FileDecoration]
        var ahead: Int
        var recentCommits: [RecentCommit]
    }

    nonisolated struct Operation: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case running
            case succeeded
            case failed(exitCode: Int32)
        }

        let id: UUID
        let label: String
        var state: State
        var output: String
        let startedAt: Date
        var finishedAt: Date?

        var isRunning: Bool { state == .running }
        var isSuccess: Bool { state == .succeeded }

        var statusLabel: String {
            switch state {
            case .running: return L10n.format("%@…", label)
            case .succeeded: return L10n.format("%@ completed", label)
            case .failed: return L10n.format("%@ failed", label)
            }
        }
    }

    @Published private(set) var rootPath = ""
    /// Stable canonical repository root, used by the UI to key drafts. It is
    /// preserved while a cwd change is being resolved inside the same repo.
    @Published private(set) var repositoryIdentity = ""
    @Published private(set) var isRepo = false
    @Published private(set) var fileDecorations: [String: FileDecoration] = [:]
    /// 目录的聚合装饰（子项最高优先级），由 `applyRepository` 一次性预计算，
    /// 文件树按目录查询时 O(1) 命中，避免每个目录行渲染时全量扫描 `fileDecorations`。
    @Published private(set) var directoryDecorations: [String: FileDecoration] = [:]
    /// Relative porcelain paths. Directory records retain their trailing slash
    /// so expanded descendants can inherit the ignored state.
    @Published private(set) var ignoredPaths: Set<String> = []
    @Published private(set) var branch: String?
    @Published private(set) var headOID: String?
    @Published private(set) var hasHead = true
    @Published private(set) var upstream: String?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var hasUpstream = false
    @Published private(set) var mergeEntries: [Entry] = []
    @Published private(set) var stagedEntries: [Entry] = []
    @Published private(set) var changedEntries: [Entry] = []
    @Published private(set) var branches: [String] = []
    @Published private(set) var remotes: [String] = []
    @Published private(set) var recentCommits: [RecentCommit] = []
    @Published private(set) var repositoryOperation: String?
    @Published private(set) var stashCount = 0
    @Published private(set) var isRefreshing = false
    /// True once a status load has completed for the current `rootPath`. The
    /// UI keeps showing resolved content during later event-driven refreshes
    /// instead of flashing a loading placeholder.
    @Published private(set) var hasResolvedStatus = false
    @Published private(set) var statusError: String?
    /// True while a user-initiated Git operation runs.
    @Published private(set) var isBusy = false
    /// 软切换（stale-while-revalidate）标记：root 已变化、新扫描进行中，
    /// UI 保留上一仓库内容但锁定交互，避免「Finding repository…」闪烁。
    @Published private(set) var isSwitchingRoot = false
    /// 变更条目数达到上限（超大仓库）：UI 提示「仅显示前 N 条」，
    /// 并降低自动刷新频率避免空转。
    @Published private(set) var statusLimitHit = false
    /// True while Retry recovery（fsmonitor 自愈 + 强制重扫）进行中。
    /// 与 `runningOperationID` 分开记账，避免 `clearRepositoryState` 仅按
    /// 操作 id 重算 `isBusy` 时把 recovery 的 busy 清掉。
    @Published private(set) var isRecovering = false
    @Published private(set) var operation: Operation?
    @Published var lastError: String?

    /// Absolute repository root. Porcelain paths are relative to this path,
    /// not necessarily to the terminal's current working directory.
    private var topLevel = ""
    /// Invalidates async refreshes and operations after the terminal changes cwd.
    private var contextGeneration: UInt = 0
    /// Invalidates an in-flight status refresh when a mutation begins, so its
    /// pre-operation snapshot cannot overwrite the post-operation state.
    private var statusRequestID: UInt = 0
    /// 合并刷新期间到达的新事件，避免取消轮询后丢事件导致状态长期陈旧。
    private var refreshPending = false
    /// Keeps a mutation globally exclusive even if the terminal changes cwd
    /// while its Git process is still running.
    private var runningOperationID: UUID?
    /// 当前 in-flight Retry recovery；完成后按 id 匹配再清 busy。
    private var recoveryID: UUID?
    /// 手动强制刷新时修复 fsmonitor daemon 的节流：频繁点击刷新按钮不反复
    /// stop/start daemon（每次重启都会重置 token，下一次 status 需全量扫描）。
    private var lastManualRepairAt = Date.distantPast
    private static let manualRepairInterval: TimeInterval = 60

    /// 事件驱动文件监听（.git 元数据 + 工作区递归），替代高频定时轮询。
    private let gitWatcher: GitFileWatcher
    /// 兜底心跳：watcher / 事件可能漏掉变化（网络盘、外部进程替换文件），
    /// 定期全量重扫保证最终一致；大仓库（条目达上限）时降频。
    private var autoRefreshInterval: TimeInterval { statusLimitHit ? 30 : 10 }
    private var autoRefreshTask: Task<Void, Never>?
    private var autoRefreshEnabled = false
    private var appActive = true
    /// 失焦 / 面板隐藏期间到达的文件变化，恢复后补一次刷新。
    private var pendingChangeWhileInactive = false
    /// VS Code 风格：文件事件防抖后再扫（GitFileWatcher 0.5s 之上再合一次）。
    private var autoRefreshDebounceTask: Task<Void, Never>?
    /// mutation 成功后的自动 status 冷却（对齐 VS Code updateWhenIdleAndWait 的节奏）。
    private var lastMutationRefreshAt = Date.distantPast
    private static let postMutationAutoRefreshCooldown: TimeInterval = 5

    init() {
        gitWatcher = GitFileWatcher()
        gitWatcher.onChange = { [weak self] in
            self?.handleFileChange()
        }
    }

    var totalChangeCount: Int {
        mergeEntries.count + stagedEntries.count + changedEntries.count
    }

    /// True while the first status load for the current directory is still in
    /// flight, so later event-driven refreshes do not replace resolved content
    /// with a loading state.
    var isResolvingInitialStatus: Bool {
        isRefreshing && !hasResolvedStatus
    }

    var repoRoot: String {
        topLevel.isEmpty ? rootPath : topLevel
    }

    /// UI 交互锁：真实 git 操作进行中，或仓库根切换中（旧内容保留展示、
    /// 新扫描未完成，避免对旧仓库条目执行 stage / discard 等操作）。
    var isInteractionLocked: Bool { isBusy || isSwitchingRoot }

    func absolutePath(for entry: Entry) -> String {
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (base as NSString).appendingPathComponent(entry.path)
    }

    func fileExistsOnDisk(for entry: Entry) -> Bool {
        let cleanPath = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        let fullPath = (base as NSString).appendingPathComponent(cleanPath)
        return FileManager.default.fileExists(atPath: fullPath)
    }

    func canStage(_ entry: Entry) -> Bool {
        if fileExistsOnDisk(for: entry) { return true }
        // 磁盘上已无此文件：
        // 只有当该文件属于 HEAD 中已追踪的历史文件（且处于工作区被删除状态 'D'），
        // 或者是已在暂存区中且非纯新增 ('A') 的变动时，Git 才能记录其删除。
        // 未追踪且磁盘不存在的文件、或尚在暂存区未提交到 HEAD 且磁盘已删除的文件，
        // 传入 git add -A 会触发 fatal: pathspec did not match any files。
        if entry.isUntracked { return false }
        if entry.staged == "A" && !fileExistsOnDisk(for: entry) { return false }
        return entry.unstaged == "D" || (entry.staged != "." && entry.staged != "?")
    }

    func isCurrent(_ entry: Entry) -> Bool {
        // 软切换期间保留 topLevel / 装饰用于展示，但禁止对旧仓库条目执行操作。
        if isSwitchingRoot { return false }
        return entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot
    }

    func sync(root: String) {
        if root != rootPath {
            contextGeneration &+= 1
            rootPath = root
            // 切换项目 / cwd 时立刻脱离旧 root 上的 commit/stage：后台进程可继续跑完，
            // 但 UI 与结果全部作废，避免 isBusy 挡住新 root 的刷新（表现为面板不切换）。
            abandonInFlightWorkForContextChange()
            if hasResolvedStatus {
                // stale-while-revalidate：保留已解析的 UI（仓库内容或非仓库视图），
                // 仅作废在飞扫描；新结果 apply 后整体替换，不再闪「Finding repository…」。
                // 保留 topLevel / fileDecorations，避免 Files 树 Git 角标在切换期间闪空；
                // isCurrent 在 isSwitchingRoot 时返回 false，配合 isInteractionLocked 锁交互。
                isSwitchingRoot = true
                invalidateStatusRefresh()
            } else {
                // 从未解析过（首次 / 恢复会话）：全清后显示首次解析占位。
                hasResolvedStatus = false
                clearRepositoryState(preserveIdentity: true)
            }
            // onAppear 常先 setAutoRefreshEnabled（此时 rootPath 仍空，心跳不会创建），
            // 再 sync 写入 root；此处必须重算，否则兜底心跳可能一直不跑。
            updateAutoRefreshTask()
            // 绕过 actor + 高优先级：切换后立刻扫新仓库，不排队等旧扫描。
            refreshForRootChange()
            return
        }
        updateAutoRefreshTask()
        refresh()
    }

    /// 根路径切换时作废旧 root 的操作 / recovery 记账，让面板能立刻跟新上下文。
    private func abandonInFlightWorkForContextChange() {
        runningOperationID = nil
        recoveryID = nil
        isRecovering = false
        isBusy = false
        autoRefreshDebounceTask?.cancel()
        autoRefreshDebounceTask = nil
        if let op = operation, op.isRunning {
            operation = nil
            lastError = nil
        }
    }

    /// 项目 / cwd 切换后的即时全量扫描：不经 actor 队列，带详情（分支列表等）。
    private func refreshForRootChange() {
        let root = rootPath
        let generation = contextGeneration
        guard !root.isEmpty else { return }
        invalidateStatusRefresh()
        let requestID = statusRequestID
        isRefreshing = true
        let includeIgnoredPaths = AppSettings.shared.filesGitDecorations
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                GitScanner.loadStatusNow(
                    in: root,
                    includeIgnoredPaths: includeIgnoredPaths,
                    includeDetails: true,
                    bypassFsmonitor: false
                )
            }.value
            guard let self else { return }
            guard self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else {
                if self.statusRequestID == requestID {
                    self.isRefreshing = false
                }
                return
            }
            self.isRefreshing = false
            self.hasResolvedStatus = true
            self.apply(result, ignoreBusy: true)
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    func refresh() {
        let root = rootPath
        let generation = contextGeneration
        guard !root.isEmpty else { return }
        guard !isRefreshing, !isBusy else {
            refreshPending = true
            return
        }
        refreshPending = false
        statusRequestID &+= 1
        let requestID = statusRequestID
        isRefreshing = true
        // 忽略路径数据只服务于 Files 面板的 Git 装饰（默认关闭）；
        // 关闭时跳过 --ignored=matching，避免大仓库每 2s 全量枚举被忽略文件。
        let includeIgnoredPaths = AppSettings.shared.filesGitDecorations

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await GitScanner.shared.loadStatus(in: root, includeIgnoredPaths: includeIgnoredPaths)
            }.value
            guard let self else { return }
            guard self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else {
                // 请求已作废时 isRefreshing 由 invalidate / 新 refresh 管理；
                // 仅当仍是当前 requestID（例如 root 已变）时清标志，防卡死。
                if self.statusRequestID == requestID {
                    self.isRefreshing = false
                }
                return
            }
            self.isRefreshing = false
            self.apply(result)
            self.hasResolvedStatus = true
            if self.refreshPending {
                self.refreshPending = false
                // 扫描进行中又收到文件事件 / 心跳时合并为 pending；完成后立即再扫
                // 会形成无间隙连续扫描，git 子进程持续占满 CPU / IO。
                // 延迟一小段再补扫，留出呼吸窗口（事件合并窗口的配套）。
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard let self, !self.isRefreshing, !self.isBusy,
                          self.rootPath == root else { return }
                    self.refresh()
                }
            }
        }
    }

    /// stage / unstage / commit / discard 等用户 mutation 完成后的即时刷新。
    ///
    /// 与普通 `refresh()` 的区别：
    /// - 先作废在飞扫描，避免吃到 mutation 前启动的陈旧结果；
    /// - **绕过** `GitScanner` actor 串行队列，以 `.userInitiated` 立刻重扫；
    /// - **跳过** branches / remotes / log / stash 详情（只更新变更列表 + branch 头），
    ///   避免 Commit 后还串行跑 4～5 个 git 子进程拖慢体感；详情由后续心跳补齐。
    private func refreshAfterMutation() {
        let root = rootPath
        let generation = contextGeneration
        guard !root.isEmpty else { return }
        // 作废在飞扫描（含仍占 actor 的旧结果）；ID 已在 invalidate 中递增。
        invalidateStatusRefresh()
        let requestID = statusRequestID
        isRefreshing = true
        let includeIgnoredPaths = AppSettings.shared.filesGitDecorations
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                GitScanner.loadStatusNow(
                    in: root,
                    includeIgnoredPaths: includeIgnoredPaths,
                    includeDetails: false,
                    bypassFsmonitor: false
                )
            }.value
            guard let self else { return }
            guard self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else {
                if self.statusRequestID == requestID {
                    self.isRefreshing = false
                }
                return
            }
            self.isRefreshing = false
            self.hasResolvedStatus = true
            self.lastMutationRefreshAt = Date()
            // ignoreBusy：mutation 的 completion 链可能立刻又置 busy，结果仍须落盘。
            self.apply(result, ignoreBusy: true)
            if self.refreshPending {
                self.refreshPending = false
                // 冷却后再补，避免与乐观更新刚落地的状态打架。
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard let self,
                          self.contextGeneration == generation,
                          self.rootPath == root,
                          !self.isBusy,
                          !self.isRefreshing else { return }
                    self.refresh()
                }
            } else {
                // 快路径不带 recent commits 等详情；对齐 VS Code 空闲后再补全量。
                Task { [weak self] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.postMutationAutoRefreshCooldown * 1_000_000_000)
                    )
                    guard let self,
                          self.contextGeneration == generation,
                          self.rootPath == root,
                          !self.isBusy,
                          !self.isRefreshing,
                          !self.isSwitchingRoot else { return }
                    self.refresh()
                }
            }
        }
    }

    /// 强制刷新（手动刷新按钮与 Retry 共用）：兜底解决各种「普通 refresh 无效」
    /// 的异常——坏 fsmonitor daemon / IPC socket 残留 / 卡在 actor 队列上的
    /// 挂死扫描 / 排队阻塞。
    ///
    /// 与普通 `refresh()` 的区别：
    /// - **不**因 `isRefreshing` / `isBusy` 静默 return：先作废进行中的扫描，并
    ///   **抢占**上一次未完成的强制刷新（换新 `recoveryID`），每次点击都推进；
    /// - （节流后）先修复失效的 Git fsmonitor daemon（stop → 删残留 IPC socket
    ///   → 按需 start），再以 `core.fsmonitor=false` 强制全量重扫；
    /// - 扫描走 **actor 外** 的 `loadStatusForRecovery`，不被卡在坏 IPC 上的
    ///   常规 `loadStatus` 堵住；全程 bypass fsmonitor，失败时再试 `git -C`；
    /// - 用户 Git 操作（`runningOperationID != nil`）时拒绝介入，避免与
    ///   stage/commit 交错；`recoveryID` + `isRecovering` 记账 busy，cwd 切换
    ///   时 `clearRepositoryState` 可安全作废。
    func forceRefresh() {
        let root = rootPath
        let generation = contextGeneration
        guard !root.isEmpty else { return }
        // 真实 git 操作进行中不要重叠；强制刷新进行中时允许再次点击抢占。
        if runningOperationID != nil { return }
        invalidateStatusRefresh()
        let id = UUID()
        recoveryID = id
        isRecovering = true
        isBusy = true
        // 立刻清掉旧错误，避免刷新中仍显示上一轮同一句 EBADF，看起来像「点了没反应」。
        statusError = nil
        let includeIgnoredPaths = AppSettings.shared.filesGitDecorations
        // daemon 修复 60s 节流：上一轮刚修复过则跳过（bypass 重扫仍执行）。
        let shouldRepair = Date().timeIntervalSince(lastManualRepairAt)
            >= Self.manualRepairInterval
        if shouldRepair {
            lastManualRepairAt = Date()
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                // 1) 停 daemon + 删 IPC（短超时，不经 actor）——兜底坏 daemon / socket 残留
                if shouldRepair {
                    GitScanner.recoverFilesystemMonitor(in: root)
                }
                // 2) 独立于 actor 串行队列的 bypass 扫描（含超时 / git -C 回退）
                let loaded = GitScanner.loadStatusForRecovery(
                    in: root,
                    includeIgnoredPaths: includeIgnoredPaths
                )
                return loaded
            }.value
            guard let self else { return }
            let stillOurs = self.recoveryID == id
            if stillOurs {
                self.recoveryID = nil
                self.isRecovering = false
                if self.runningOperationID == nil {
                    self.isBusy = false
                }
            }
            // cwd / root 已变，或 recovery 被更新的刷新 / clearRepositoryState 抢占：丢弃。
            guard stillOurs,
                  self.contextGeneration == generation,
                  self.rootPath == root else { return }
            self.isRefreshing = false
            self.hasResolvedStatus = true
            // 结果必须落盘：ignoreBusy 防止与其它 busy 竞态时静默丢弃。
            self.apply(result, ignoreBusy: true)
            // 成功或失败都拉长 fsmonitor bypass cooldown，避免后续轮询立刻再撞 daemon。
            Task { await GitScanner.shared.noteFilesystemMonitorBypassCooldown() }
            // 刷新期间 timer 可能堆积了 refreshPending；状态已是最新时清掉即可，
            // 若仍失败则再走一次普通 refresh（cooldown 内会自动 bypass）。
            if self.refreshPending {
                self.refreshPending = false
                if self.statusError != nil {
                    self.refresh()
                }
            }
        }
    }

    /// 侧边栏可见性变化时调用（可见才允许自动刷新）。恢复可见时若期间
    /// 有被抑制的文件变化，立即补刷一次。
    func setAutoRefreshEnabled(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        if enabled {
            let pending = pendingChangeWhileInactive
            pendingChangeWhileInactive = false
            if pending, !rootPath.isEmpty {
                refresh()
            }
        } else {
            pendingChangeWhileInactive = false
        }
        updateAutoRefreshTask()
    }

    /// 应用前台 / 后台切换时调用。失焦暂停心跳与 watcher 刷新（与 System 面板
    /// 同策略）；聚焦后若期间有变化立即补刷一次（面板隐藏时保留 pending，
    /// 等面板重新可见时由 `setAutoRefreshEnabled` 补刷）。
    func setAppActive(_ active: Bool) {
        appActive = active
        if active {
            if pendingChangeWhileInactive, autoRefreshEnabled, !rootPath.isEmpty {
                pendingChangeWhileInactive = false
                refresh()
            }
        }
        updateAutoRefreshTask()
    }

    /// 兜底心跳：低频全量重扫，保证 watcher 漏掉的变化最终一致。
    private func updateAutoRefreshTask() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard autoRefreshEnabled, appActive, !rootPath.isEmpty else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.autoRefreshInterval ?? 10
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard self.autoRefreshEnabled, self.appActive, !self.rootPath.isEmpty else { return }
                // VS Code：操作进行中不自动 status；忙完由 refreshPending / mutation 路径补。
                guard !self.isBusy, !self.isSwitchingRoot else { continue }
                // mutation 刚刷过则跳过本拍，避免 stage 后立刻再全量扫。
                if Date().timeIntervalSince(self.lastMutationRefreshAt)
                    < Self.postMutationAutoRefreshCooldown {
                    continue
                }
                self.refresh()
            }
        }
    }

    /// 文件 watcher 事件（主线程回调）：对齐 VS Code onFileChange——
    /// 失焦 / 操作中 / 大仓库自动跳过，其余防抖后刷新。
    private func handleFileChange() {
        guard autoRefreshEnabled, appActive else {
            pendingChangeWhileInactive = true
            return
        }
        // 操作进行中：只记 pending，不打断 commit/stage（VS Code operations.isIdle）。
        if isBusy || isSwitchingRoot {
            refreshPending = true
            return
        }
        // 大仓库命中条目上限：跳过事件驱动全量扫，仅靠降频心跳兜底。
        if statusLimitHit {
            return
        }
        // mutation 冷却内忽略噪声（git 自身写 index 触发的事件）。
        if Date().timeIntervalSince(lastMutationRefreshAt)
            < Self.postMutationAutoRefreshCooldown {
            return
        }
        scheduleDebouncedAutoRefresh()
    }

    /// VS Code `@debounce(1000)` + throttle 的轻量等价：合并洪峰后再 refresh。
    private func scheduleDebouncedAutoRefresh() {
        autoRefreshDebounceTask?.cancel()
        autoRefreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.autoRefreshEnabled, self.appActive else {
                self.pendingChangeWhileInactive = true
                return
            }
            guard !self.isBusy, !self.isSwitchingRoot, !self.statusLimitHit else {
                self.refreshPending = true
                return
            }
            self.refresh()
        }
    }

    func dismissOperation() {
        guard operation?.isRunning != true else { return }
        operation = nil
        lastError = nil
    }

    /// Returns a Git decoration only when `absolutePath` belongs to the
    /// currently resolved repository. Plain folders therefore keep the normal
    /// file-tree appearance, even when their names resemble ignored paths.
    func fileDecoration(for absolutePath: String, isDirectory: Bool) -> FileDecoration? {
        guard isRepo, !topLevel.isEmpty else { return nil }
        let repositoryPath = (topLevel as NSString).standardizingPath
        let itemPath = (absolutePath as NSString).standardizingPath
        let relativePath: String
        if itemPath == repositoryPath {
            relativePath = ""
        } else {
            let prefix = repositoryPath + "/"
            guard itemPath.hasPrefix(prefix) else { return nil }
            relativePath = String(itemPath.dropFirst(prefix.count))
        }

        if let decoration = fileDecorations[relativePath] {
            return decoration
        }
        if ignoredPaths.contains(where: { ignoredPath in
            if ignoredPath.hasSuffix("/") {
                let directory = String(ignoredPath.dropLast())
                return relativePath == directory || relativePath.hasPrefix(directory + "/")
            }
            return relativePath == ignoredPath
        }) {
            return .ignored
        }
        guard isDirectory, !relativePath.isEmpty else { return nil }
        return directoryDecorations[relativePath]
    }

    // MARK: - File operations

    func stage(_ entry: Entry) {
        guard validate(entry), canStage(entry) else { return }
        let original = entry.unstaged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        let pathSet = Set(paths)
        perform(
            label: L10n.format("Stage %@", entry.fileName),
            commands: [["--literal-pathspecs", "add", "-A", "--"] + paths],
            // stage 不依赖 HEAD 稳定；跳过 rev-parse 校验加快按钮响应（对齐 VS Code）。
            requiresStableHead: false,
            optimisticUpdate: { [weak self] in
                self?.optimisticallyStage(paths: pathSet)
            }
        )
    }

    func unstage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.staged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        let pathSet = Set(paths)
        let args = hasHead
            ? ["--literal-pathspecs", "restore", "--staged", "--"] + paths
            : ["--literal-pathspecs", "rm", "--cached", "-f", "--"] + paths
        perform(
            label: L10n.format("Unstage %@", entry.fileName),
            commands: [args],
            requiresStableHead: false,
            optimisticUpdate: { [weak self] in
                self?.optimisticallyUnstage(paths: pathSet)
            }
        )
    }

    /// 将工作区所有变更添加到暂存区 (`git add -A`)。
    /// - Parameter completion: 完成后的回调，传入操作是否成功。
    func stageAll(completion: (@MainActor (Bool) -> Void)? = nil) {
        perform(
            label: L10n.t("Stage all changes"),
            commands: [["add", "-A"]],
            requiresStableHead: false,
            completion: completion,
            optimisticUpdate: { [weak self] in
                self?.optimisticallyStageAll()
            }
        )
    }

    func unstageAll() {
        let args = hasHead
            ? ["restore", "--staged", "--", "."]
            : ["rm", "--cached", "-r", "-f", "--", "."]
        perform(
            label: L10n.t("Unstage all changes"),
            commands: [args],
            requiresStableHead: false,
            optimisticUpdate: { [weak self] in
                self?.optimisticallyUnstageAll()
            }
        )
    }

    /// Restores a tracked file from the index, or moves an untracked file to
    /// the Trash. The UI confirms before calling this.
    func discard(_ entry: Entry) {
        guard validate(entry) else { return }
        if entry.isIntentToAdd {
            perform(
                label: L10n.format("Remove intent-to-add for %@", entry.fileName),
                commands: [[
                    "--literal-pathspecs", "rm", "--cached", "-f", "--", entry.path,
                ]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: L10n.format("Move %@ to Trash", entry.fileName),
                    completedBefore: "Removed the intent-to-add index entry."
                )
            }
        } else if entry.isUntracked || entry.isWorktreeCopy {
            trash(paths: [entry.path], label: L10n.format("Move %@ to Trash", entry.fileName))
        } else if entry.isWorktreeRename, let original = entry.origPath {
            perform(
                label: L10n.format("Restore %@", (original as NSString).lastPathComponent),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", original]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: L10n.format("Move %@ to Trash", entry.fileName),
                    completedBefore: "Restored \((original as NSString).lastPathComponent)."
                )
            }
        } else {
            perform(
                label: L10n.format("Discard changes in %@", entry.fileName),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", entry.path]]
            )
        }
    }

    /// Discards every worktree change. Tracked files are restored and
    /// untracked files are moved to the Trash. The UI confirms first.
    func discardAllChanges() {
        discardChanges(changedEntries)
    }

    /// Discards only the confirmed snapshot. This prevents new files written
    /// by an agent while the dialog is open from joining a bulk destructive action.
    func discardChanges(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        guard entries.allSatisfy(isCurrent) else {
            cancelStaleDiscard()
            return
        }
        let intentToAdd = entries.filter(\.isIntentToAdd)
        let moved = entries.filter { $0.isWorktreeRename || $0.isWorktreeCopy }
        let untracked = entries.filter(\.isUntracked).map(\.path) + moved.map(\.path)
        let renamedOriginals = moved.filter(\.isWorktreeRename).compactMap(\.origPath)
        let tracked = entries.filter {
            !$0.isUntracked && !$0.isWorktreeRename && !$0.isWorktreeCopy
        }.map(\.path) + renamedOriginals
        var commands: [[String]] = []
        if !tracked.isEmpty {
            commands.append(["--literal-pathspecs", "restore", "--worktree", "--"] + tracked)
        }
        if !intentToAdd.isEmpty {
            commands.append(
                ["--literal-pathspecs", "rm", "--cached", "-f", "--"]
                    + intentToAdd.map(\.path)
            )
        }
        guard !commands.isEmpty || !untracked.isEmpty else { return }

        if commands.isEmpty {
            trash(paths: untracked, label: L10n.t("Move untracked files to Trash"))
        } else {
            var completedSteps: [String] = []
            if !tracked.isEmpty {
                completedSteps.append(
                    "Restored \(tracked.count) tracked path\(tracked.count == 1 ? "" : "s")."
                )
            }
            if !intentToAdd.isEmpty {
                completedSteps.append(
                    "Removed \(intentToAdd.count) intent-to-add index entr\(intentToAdd.count == 1 ? "y" : "ies")."
                )
            }
            perform(label: L10n.t("Discard all changes"), commands: commands) { [weak self] success in
                guard success, !untracked.isEmpty else { return }
                self?.trash(
                    paths: untracked,
                    label: L10n.t("Finish discarding all changes"),
                    completedBefore: completedSteps.joined(separator: "\n")
                )
            }
        }
    }

    func cancelStaleDiscard() {
        failImmediately(L10n.t("Files changed while the confirmation was open. Review them and try again."))
    }

    // MARK: - Commit and remote operations

    /// Commits only the index unless `includeAll` explicitly requests `git add -A`.
    func commit(
        message: String,
        includeAll: Bool,
        amend: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(L10n.t("Enter a commit message"), completion: completion)
            return
        }
        guard includeAll || !stagedEntries.isEmpty || amend else {
            failImmediately(L10n.t("Stage changes before committing"), completion: completion)
            return
        }

        var commands: [[String]] = []
        if includeAll { commands.append(["add", "-A"]) }
        var commitArgs = ["commit"]
        if amend { commitArgs.append("--amend") }
        commitArgs += ["-m", trimmed]
        commands.append(commitArgs)
        let label = amend ? L10n.t("Amend commit") : (includeAll ? L10n.t("Stage all and commit") : L10n.t("Commit staged changes"))
        // VS Code：commit 后立刻清空 staged（乐观），后台 status 纠偏。
        perform(
            label: label,
            commands: commands,
            completion: completion,
            optimisticUpdate: { [weak self] in
                self?.optimisticallyCommit(includeAll: includeAll, amend: amend, message: trimmed)
            }
        )
    }

    /// 简单模式提交：将 `checkedEntries` 阶段包含路径提交暂存，将 `uncheckedEntries` 移出暂存区，而后执行 commit。
    func commitSimple(
        message: String,
        checkedEntries: [Entry],
        uncheckedEntries: [Entry],
        amend: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(L10n.t("Enter a commit message"), completion: completion)
            return
        }
        guard !checkedEntries.isEmpty || amend else {
            failImmediately(L10n.t("Select changes before committing"), completion: completion)
            return
        }

        var commands: [[String]] = []

        // 1. 未勾选且当前处于暂存区的路径 -> 移出暂存区
        let pathsToUnstage = uncheckedEntries.filter { $0.staged != "." && $0.staged != "?" }
        if !pathsToUnstage.isEmpty {
            let unstagePaths = pathsToUnstage.flatMap { entry -> [String] in
                let orig = (entry.staged == "R" || entry.staged == "C") ? entry.origPath.map { [$0] } ?? [] : []
                return [entry.path] + orig
            }
            if !unstagePaths.isEmpty {
                let unstageArgs = hasHead
                    ? ["--literal-pathspecs", "restore", "--staged", "--"] + unstagePaths
                    : ["--literal-pathspecs", "rm", "--cached", "-f", "--"] + unstagePaths
                commands.append(unstageArgs)
            }
        }

        // 2. 已勾选的路径 -> 加入暂存区
        if !checkedEntries.isEmpty {
            let entriesToStage = checkedEntries.filter { entry in
                guard canStage(entry) else { return false }
                // 如果已经 staged 且 worktree 无额外变动，不需要再跑 git add
                if entry.staged != "." && entry.staged != "?" && (entry.unstaged == "." || entry.unstaged == "?") {
                    return false
                }
                return true
            }
            let stagePaths = entriesToStage.flatMap { entry -> [String] in
                let orig = (entry.unstaged == "R" || entry.unstaged == "C") ? entry.origPath.map { [$0] } ?? [] : []
                return [entry.path] + orig
            }
            if !stagePaths.isEmpty {
                commands.append(["--literal-pathspecs", "add", "-A", "--"] + stagePaths)
            }
        }

        // 3. Commit
        var commitArgs = ["commit"]
        if amend { commitArgs.append("--amend") }
        commitArgs += ["-m", trimmed]
        commands.append(commitArgs)

        let label = amend ? L10n.t("Amend commit") : L10n.t("Commit selected changes")
        perform(
            label: label,
            commands: commands,
            completion: completion
        )
    }

    /// Compatibility for older call sites. The behavior remains explicit in
    /// the new panel, which uses the overload above.
    func commit(message: String) {
        commit(message: message, includeAll: stagedEntries.isEmpty)
    }

    func fetch() {
        guard !remotes.isEmpty else {
            failImmediately(L10n.t("No Git remote is configured"))
            return
        }
        perform(
            label: L10n.t("Fetch"),
            commands: [["fetch", "--all", "--prune"]],
            requiresStableHead: false
        )
    }

    func pull() {
        guard hasUpstream else {
            failImmediately(L10n.t("This branch has no upstream to pull from"))
            return
        }
        perform(
            label: L10n.t("Pull"),
            commands: [["pull", "--ff-only"]],
            requiresStableUpstream: true
        )
    }

    func push() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(L10n.t("Create or switch to a branch before publishing detached HEAD"))
            return
        }
        if hasUpstream {
            perform(label: L10n.t("Push"), commands: [["push"]], requiresStableUpstream: true)
            return
        }
        guard let remote = unambiguousRemote else {
            failImmediately(remotes.isEmpty
                ? L10n.t("Add a Git remote before publishing this branch")
                : L10n.t("Choose which remote should receive this branch"))
            return
        }
        perform(label: L10n.t("Publish branch"), commands: [["push", "-u", remote, "HEAD"]])
    }

    func publish(to remote: String) {
        guard branch != "detached HEAD" else {
            failImmediately(L10n.t("Create or switch to a branch before publishing detached HEAD"))
            return
        }
        guard remotes.contains(remote) else {
            failImmediately(L10n.t("The selected Git remote is no longer available"))
            return
        }
        perform(
            label: L10n.format("Publish branch to %@", remote),
            commands: [["push", "-u", remote, "HEAD"]]
        )
    }

    func syncChanges() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(L10n.t("Create or switch to a branch before publishing detached HEAD"))
            return
        }
        if hasUpstream {
            perform(
                label: L10n.t("Sync changes"),
                commands: [["pull", "--ff-only"], ["push"]],
                requiresStableUpstream: true
            )
        } else {
            guard let remote = unambiguousRemote else {
                failImmediately(remotes.isEmpty
                    ? L10n.t("Add a Git remote before publishing this branch")
                    : L10n.t("Choose which remote should receive this branch"))
                return
            }
            perform(label: L10n.t("Publish branch"), commands: [["push", "-u", remote, "HEAD"]])
        }
    }

    // MARK: - Branches, stash, and repository setup

    func switchBranch(to name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !name.isEmpty, name != branch else {
            completion?(name == branch)
            return
        }
        perform(label: L10n.format("Switch to %@", name), commands: [["switch", name]], completion: completion)
    }

    func createBranch(named name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(L10n.t("Enter a branch name"), completion: completion)
            return
        }
        perform(
            label: L10n.format("Create branch %@", trimmed),
            commands: [["switch", "-c", trimmed]],
            completion: completion
        )
    }

    func stash(includeUntracked: Bool = true) {
        guard totalChangeCount > 0 else {
            failImmediately(L10n.t("There are no changes to stash"))
            return
        }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        perform(label: L10n.t("Stash changes"), commands: [args])
    }

    func stashPop() {
        guard stashCount > 0 else {
            failImmediately(L10n.t("There are no stashes to pop"))
            return
        }
        perform(label: L10n.t("Pop stash"), commands: [["stash", "pop"]])
    }

    func initializeRepository(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !rootPath.isEmpty else {
            failImmediately(L10n.t("Open a terminal directory first"), completion: completion)
            return
        }
        perform(
            label: L10n.t("Initialize repository"),
            commands: [["init"]],
            directory: rootPath,
            completion: completion
        )
    }

    // MARK: - Operation runner

    private var unambiguousRemote: String? {
        remotes.count == 1 ? remotes[0] : nil
    }

    private func validate(_ entry: Entry) -> Bool {
        guard isCurrent(entry) else {
            failImmediately("Repository changed; refresh and try the Git action again")
            return false
        }
        return true
    }

    private func perform(
        label: String,
        commands: [[String]],
        directory: String? = nil,
        requiresStableHead: Bool = true,
        requiresStableUpstream: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil,
        optimisticUpdate: (() -> Void)? = nil
    ) {
        if directory == nil && !isRepo {
            failImmediately(
                "Repository changed; review the current directory and try the Git action again.",
                completion: completion
            )
            return
        }
        let dir = directory ?? repoRoot
        let generation = contextGeneration
        let validationRoot = rootPath
        let expectedRepositoryRoot = directory == nil && isRepo ? repoRoot : nil
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let expectedUpstream = upstream
        guard !dir.isEmpty, !isBusy, !commands.isEmpty else { return }

        let operationID = UUID()
        invalidateStatusRefresh()
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(
            id: operationID,
            label: label,
            state: .running,
            output: "",
            startedAt: Date(),
            finishedAt: nil
        )

        // VS Code optimisticUpdate：git 子进程跑之前先改 UI 列表，失败再回滚。
        let resourceSnapshot: ResourceSnapshot? = optimisticUpdate != nil
            ? captureResourceSnapshot()
            : nil
        optimisticUpdate?()

        Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                var transcript: [String] = []
                var failureCode: Int32?
                var failureMessage: String?

                if let expectedRepositoryRoot {
                    guard GitScanner.resolveRepositoryRoot(in: validationRoot) == expectedRepositoryRoot else {
                        let message = "Repository changed before the Git action could run. Review the current changes and try again."
                        return CommandBatchResult(
                            output: message, failureCode: -1, failureMessage: message
                        )
                    }
                    if requiresStableHead {
                        // 轻量 rev-parse 快照（不做 worktree 全量 status）：大仓库上
                        // 原先 porcelain status 校验本身可比 commit 更慢。
                        let live = GitScanner.readBranchSnapshot(
                            in: expectedRepositoryRoot,
                            includeUpstream: requiresStableUpstream
                        )
                        guard let live,
                              live.headOID == expectedHeadOID,
                              live.branch == expectedBranch,
                              !requiresStableUpstream || live.upstream == expectedUpstream else {
                            let changedState = requiresStableUpstream
                                ? "Branch, HEAD, or upstream"
                                : "Branch or HEAD"
                            let message = "\(changedState) changed before the Git action could run. Review the current changes and try again."
                            return CommandBatchResult(
                                output: message, failureCode: -1, failureMessage: message
                            )
                        }
                    }
                }

                for args in commands {
                    transcript.append("$ git " + Self.displayCommand(args))
                    let run = GitScanner.runGit(args, in: dir)
                    let text = [run.stdout, run.stderr]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    if !text.isEmpty { transcript.append(text) }
                    if run.status != 0 {
                        let fallback = "git \(args.first ?? "command") failed"
                        failureCode = run.status
                        failureMessage = text.isEmpty ? fallback : text
                        break
                    }
                }
                return CommandBatchResult(
                    output: transcript.joined(separator: "\n"),
                    failureCode: failureCode,
                    failureMessage: failureMessage
                )
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation,
                  self.operation?.id == operationID else {
                // The command may have completed in the old repository, but
                // success-only follow-ups (for example moving a renamed file
                // to Trash) must never continue in the newly selected context.
                completion?(false)
                self.refreshAfterMutation()
                return
            }
            let finishedAt = Date()
            if let failureCode = batch.failureCode {
                // 乐观更新回滚，再后台纠偏。
                if let resourceSnapshot {
                    self.restoreResourceSnapshot(resourceSnapshot)
                }
                self.lastError = batch.failureMessage
                self.operation = Operation(
                    id: operationID,
                    label: label,
                    state: .failed(exitCode: failureCode),
                    output: batch.output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(false)
            } else {
                self.lastError = nil
                self.operation = Operation(
                    id: operationID,
                    label: label,
                    state: .succeeded,
                    output: batch.output.isEmpty ? L10n.t("Completed successfully.") : batch.output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(true)
            }
            // 成功时列表已是乐观结果，后台轻量 status 纠偏即可；失败时纠偏真实状态。
            self.refreshAfterMutation()
        }
    }

    // MARK: - Optimistic updates (VS Code 风格)

    private func captureResourceSnapshot() -> ResourceSnapshot {
        ResourceSnapshot(
            mergeEntries: mergeEntries,
            stagedEntries: stagedEntries,
            changedEntries: changedEntries,
            fileDecorations: fileDecorations,
            directoryDecorations: directoryDecorations,
            ahead: ahead,
            recentCommits: recentCommits
        )
    }

    private func restoreResourceSnapshot(_ snapshot: ResourceSnapshot) {
        mergeEntries = snapshot.mergeEntries
        stagedEntries = snapshot.stagedEntries
        changedEntries = snapshot.changedEntries
        fileDecorations = snapshot.fileDecorations
        directoryDecorations = snapshot.directoryDecorations
        ahead = snapshot.ahead
        recentCommits = snapshot.recentCommits
    }

    private func applyOptimisticLists(
        merge: [Entry],
        staged: [Entry],
        changed: [Entry]
    ) {
        mergeEntries = merge
        stagedEntries = staged
        changedEntries = changed
        recomputeDecorationsFromLists()
    }

    /// 从当前三组列表粗算装饰（不要求与 porcelain 完全一致；后台 status 会覆盖）。
    private func recomputeDecorationsFromLists() {
        var byPath: [String: Entry] = [:]
        for entry in mergeEntries + stagedEntries + changedEntries {
            if let existing = byPath[entry.path] {
                // 合并两侧字母：同 path 可同时出现在 staged + changed（MM）。
                let stagedLetter = entry.staged != "." ? entry.staged : existing.staged
                let unstagedLetter = entry.unstaged != "." ? entry.unstaged : existing.unstaged
                byPath[entry.path] = existing.withStatus(
                    staged: stagedLetter,
                    unstaged: unstagedLetter,
                    origPath: entry.origPath ?? existing.origPath
                )
            } else {
                byPath[entry.path] = entry
            }
        }
        var fileDec: [String: FileDecoration] = [:]
        var dirDec: [String: FileDecoration] = [:]
        for entry in byPath.values {
            let decoration = Self.optimisticDecoration(for: entry)
            let key = entry.isDirectoryEntry ? String(entry.path.dropLast()) : entry.path
            fileDec[key] = decoration
            var directory = (key as NSString).deletingLastPathComponent
            while !directory.isEmpty {
                if let current = dirDec[directory],
                   current.directoryPriority >= decoration.directoryPriority {
                    break
                }
                dirDec[directory] = decoration
                directory = (directory as NSString).deletingLastPathComponent
            }
            if entry.isDirectoryEntry {
                dirDec[key] = decoration
            }
        }
        // 保留 ignored 装饰（乐观路径不重扫 ignore）。
        for (path, decoration) in fileDecorations where decoration == .ignored {
            if fileDec[path] == nil { fileDec[path] = .ignored }
        }
        fileDecorations = fileDec
        directoryDecorations = dirDec
    }

    private nonisolated static func optimisticDecoration(for entry: Entry) -> FileDecoration {
        let statuses = [entry.staged, entry.unstaged]
        if entry.isConflict || statuses.contains("U") { return .conflict }
        if statuses.contains("?") { return .untracked }
        if entry.staged == "A" { return .added }
        if statuses.contains("D") { return .deleted }
        if statuses.contains("R") { return .renamed }
        if statuses.contains("C") { return .copied }
        return .modified
    }

    private func pathMatches(_ entry: Entry, paths: Set<String>) -> Bool {
        paths.contains(entry.path)
            || (entry.origPath.map { paths.contains($0) } ?? false)
    }

    /// 乐观 stage：把 changed 中匹配项移入 staged（字母按 git add 后的常见结果估算）。
    private func optimisticallyStage(paths: Set<String>) {
        var staged = stagedEntries
        var changed = changedEntries
        let moving = changed.filter { pathMatches($0, paths: paths) }
        changed.removeAll { pathMatches($0, paths: paths) }
        for entry in moving {
            let stagedLetter: Character
            if entry.isUntracked || entry.staged == "?" || entry.unstaged == "?" {
                stagedLetter = "A"
            } else if entry.unstaged != "." {
                stagedLetter = entry.unstaged
            } else {
                stagedLetter = entry.staged == "." ? "M" : entry.staged
            }
            staged.removeAll { $0.path == entry.path }
            staged.append(entry.withStatus(staged: stagedLetter, unstaged: "."))
        }
        // 已在 staged 且仍有 unstaged 侧（MM）：清 unstaged。
        staged = staged.map { entry in
            guard pathMatches(entry, paths: paths), entry.unstaged != "." else { return entry }
            let letter = entry.staged == "." ? "M" : entry.staged
            return entry.withStatus(staged: letter, unstaged: ".")
        }
        applyOptimisticLists(merge: mergeEntries, staged: staged, changed: changed)
    }

    private func optimisticallyUnstage(paths: Set<String>) {
        var staged = stagedEntries
        var changed = changedEntries
        let moving = staged.filter { pathMatches($0, paths: paths) }
        staged.removeAll { pathMatches($0, paths: paths) }
        for entry in moving {
            let letter = entry.staged == "." ? "M" : entry.staged
            // 新文件取消暂存 → 回到未跟踪。
            let restored: Entry
            if letter == "A" {
                restored = entry.withStatus(staged: "?", unstaged: "?", origPath: nil)
            } else {
                restored = entry.withStatus(staged: ".", unstaged: letter)
            }
            changed.removeAll { $0.path == entry.path }
            changed.append(restored)
        }
        applyOptimisticLists(merge: mergeEntries, staged: staged, changed: changed)
    }

    private func optimisticallyStageAll() {
        let paths = Set(changedEntries.map(\.path))
        guard !paths.isEmpty else { return }
        optimisticallyStage(paths: paths)
    }

    private func optimisticallyUnstageAll() {
        let paths = Set(stagedEntries.map(\.path))
        guard !paths.isEmpty else { return }
        optimisticallyUnstage(paths: paths)
    }

    private func optimisticallyCommit(includeAll: Bool, amend: Bool, message: String) {
        if includeAll {
            stagedEntries = []
            changedEntries = []
        } else {
            stagedEntries = []
        }
        if !amend {
            if hasUpstream { ahead += 1 }
            // 乐观插入一条 recent commit 头（后台 status 会换成真实 hash）。
            let placeholder = RecentCommit(
                hash: "optimistic",
                shortHash: "·······",
                subject: message,
                author: "",
                relativeDate: "just now"
            )
            recentCommits = [placeholder] + recentCommits.filter { $0.hash != "optimistic" }
            if recentCommits.count > 8 {
                recentCommits = Array(recentCommits.prefix(8))
            }
        }
        recomputeDecorationsFromLists()
    }

    private func failImmediately(
        _ message: String,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !isBusy else {
            completion?(false)
            return
        }
        lastError = message
        operation = Operation(
            id: UUID(),
            label: L10n.t("Git action"),
            state: .failed(exitCode: -1),
            output: message,
            startedAt: Date(),
            finishedAt: Date()
        )
        completion?(false)
    }

    private func trash(paths: [String], label: String, completedBefore: String? = nil) {
        guard !paths.isEmpty, !isBusy else { return }
        let base = URL(fileURLWithPath: repoRoot, isDirectory: true)
        let expectedRepositoryRoot = repoRoot
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let validationRoot = rootPath
        let generation = contextGeneration
        let operationID = UUID()
        invalidateStatusRefresh()
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(
            id: operationID, label: label, state: .running, output: "",
            startedAt: Date(), finishedAt: nil
        )

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                guard GitScanner.resolveRepositoryRoot(in: validationRoot) == expectedRepositoryRoot else {
                    return TrashResult(
                        moved: [],
                        failure: "Repository changed before the file action could run. Review the current changes and try again."
                    )
                }
                // 同 perform：轻量 rev-parse，避免 discard 前再跑全量 status。
                let live = GitScanner.readBranchSnapshot(
                    in: expectedRepositoryRoot,
                    includeUpstream: false
                )
                guard let live,
                      live.headOID == expectedHeadOID,
                      live.branch == expectedBranch else {
                    return TrashResult(
                        moved: [],
                        failure: "Branch or HEAD changed before the file action could run. Review the current changes and try again."
                    )
                }
                var moved: [String] = []
                var failure: String?
                for path in paths {
                    do {
                        try FileManager.default.trashItem(
                            at: base.appendingPathComponent(path), resultingItemURL: nil
                        )
                        moved.append(path)
                    } catch {
                        failure = error.localizedDescription
                        break
                    }
                }
                return TrashResult(moved: moved, failure: failure)
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation,
                  self.operation?.id == operationID else {
                self.refreshAfterMutation()
                return
            }
            let finishedAt = Date()
            if let failure = result.failure {
                let completedResult = completedBefore.map { $0 + "\n" } ?? ""
                let partialResult = result.moved.isEmpty
                    ? ""
                    : "\n\nMoved to Trash before the failure:\n" + result.moved.joined(separator: "\n")
                let output = completedResult + failure + partialResult
                self.lastError = result.moved.isEmpty
                    ? completedResult + failure
                    : completedResult + "\(failure) (\(result.moved.count) item\(result.moved.count == 1 ? " was" : "s were") already moved to Trash.)"
                self.operation = Operation(
                    id: operationID, label: label, state: .failed(exitCode: -1),
                    output: output, startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
            } else {
                let output = [
                    completedBefore,
                    "Moved to Trash:\n" + result.moved.joined(separator: "\n"),
                ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                self.operation = Operation(
                    id: operationID, label: label, state: .succeeded,
                    output: output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
            }
            self.refreshAfterMutation()
        }
    }

    private nonisolated struct CommandBatchResult: Sendable {
        let output: String
        let failureCode: Int32?
        let failureMessage: String?
    }

    private nonisolated struct TrashResult: Sendable {
        let moved: [String]
        let failure: String?
    }

    private func invalidateStatusRefresh() {
        statusRequestID &+= 1
        isRefreshing = false
        refreshPending = false
    }

    private nonisolated static func displayCommand(_ args: [String]) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_@%+=:,./-")
        )
        return args.map { arg in
            guard arg.isEmpty || arg.unicodeScalars.contains(where: { !safeCharacters.contains($0) }) else {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: - Status

    private func clearRepositoryState(
        preserveIdentity: Bool = false,
        preserveFailedOperation: Bool = false
    ) {
        let failedOperation = preserveFailedOperation ? operation : nil
        let failedError = preserveFailedOperation ? lastError : nil
        topLevel = ""
        isRepo = false
        isSwitchingRoot = false
        statusLimitHit = false
        gitWatcher.stop()
        branch = nil
        headOID = nil
        hasHead = true
        upstream = nil
        ahead = 0
        behind = 0
        hasUpstream = false
        mergeEntries = []
        stagedEntries = []
        changedEntries = []
        fileDecorations = [:]
        directoryDecorations = [:]
        ignoredPaths = []
        branches = []
        remotes = []
        recentCommits = []
        repositoryOperation = nil
        stashCount = 0
        isRefreshing = false
        // 作废 in-flight recovery 记账：async 任务仍会跑完，但 completion
        // 用 recoveryID 匹配失败后不再清/改 busy，避免与新 root 交错。
        recoveryID = nil
        isRecovering = false
        isBusy = runningOperationID != nil
        operation = failedOperation
        lastError = failedError
        statusError = nil
        statusRequestID &+= 1
        if !preserveIdentity { repositoryIdentity = "" }
    }

    /// - Parameter ignoreBusy: Retry recovery 完成时为 true，避免 `isBusy`
    ///   竞态导致失败/成功结果被静默丢弃（表现为 Retry 无效）。
    private func apply(_ loadResult: StatusLoadResult, ignoreBusy: Bool = false) {
        switch loadResult {
        case .notRepository:
            if isBusy && !ignoreBusy { return }
            isSwitchingRoot = false
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(preserveFailedOperation: preserveFailure)
            // 非仓库目录也挂工作区监听：终端内 `git init` 可立即被发现，
            // 无需等 10s 兜底心跳。
            gitWatcher.watch(repositoryRoot: rootPath, gitDirectory: nil)
            return
        case .failed(let message):
            if isBusy && !ignoreBusy { return }
            isSwitchingRoot = false
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(
                preserveIdentity: true,
                preserveFailedOperation: preserveFailure
            )
            // clearRepositoryState 会清 statusError；写回完整诊断文案。
            // recovery 路径（ignoreBusy）在调用方已清 isRecovering / recoveryID。
            statusError = message
            // clear 会 stop watcher；失败态仍挂工作区监听，可恢复错误能靠文件事件
            // / 心跳自动再扫，而不是只能等用户手动 forceRefresh。
            if !rootPath.isEmpty {
                gitWatcher.watch(repositoryRoot: rootPath, gitDirectory: nil)
            }
            return
        case .repository(let result):
            isSwitchingRoot = false
            statusError = nil
            applyRepository(result)
        }
    }

    /// 扫描 / 解析 / 预处理都已在 `GitScanner` actor 内完成，
    /// 这里只做 @Published 赋值（Swift 数组 COW，赋值 O(1)），
    /// 主线程不再承担任何 O(n) 计算。
    private func applyRepository(_ result: StatusResult) {
        isRepo = true
        branch = result.branch
        headOID = result.headOID
        hasHead = result.hasHead
        upstream = result.upstream
        ahead = result.ahead
        behind = result.behind
        hasUpstream = result.upstream != nil
        topLevel = result.topLevel
        repositoryIdentity = result.topLevel
        statusLimitHit = result.didHitLimit
        if result.loadedDetails {
            branches = result.branches
            remotes = result.remotes
            recentCommits = result.recentCommits
            repositoryOperation = result.repositoryOperation
            stashCount = result.stashCount
        }
        fileDecorations = result.fileDecorations
        directoryDecorations = result.directoryDecorations
        ignoredPaths = result.ignoredPaths
        mergeEntries = result.mergeEntries
        stagedEntries = result.stagedEntries
        changedEntries = result.changedEntries
        // 挂载 / 更新文件 watcher（路径未变时内部直接跳过，零开销）。
        gitWatcher.watch(repositoryRoot: result.topLevel, gitDirectory: result.gitDirectory)
    }

    /// 兼容旧调用点（命令面板 / Diff / LocalAI 的一次性同步查询）。
    /// 真实实现在 `GitScanner.runGit`。
    nonisolated static func runGit(
        _ args: [String], in dir: String
    ) -> (status: Int32, stdout: String, stderr: String) {
        GitScanner.runGit(args, in: dir)
    }
}
