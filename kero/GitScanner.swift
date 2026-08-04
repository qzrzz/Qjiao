//
//  GitScanner.swift
//  kero
//
//  Git 子进程调用、porcelain v2 解析与结果预处理的唯一入口，隔离在独立
//  `GitScanner` actor 中：
//  - 扫描流水线串行执行（同一时刻至多一个 git status 流水线在跑），
//    避免并发 git 进程争抢 CPU / IO，也避免大仓库下的扫描风暴；
//  - 全部 O(n) 计算（切分 merge/staged/changed、构建装饰字典）都在
//    actor 的全局执行器上完成，主线程只做最终的 @Published 赋值；
//  - 由调用方以 `.utility` 优先级调度（`Task.detached(priority: .utility)`），
//    不抢占 UI 的 userInteractive 负载。
//
//  同步工具（`runGit` 等）保持 `nonisolated`：操作执行（stage / commit /
//  discard 等）与命令面板 / Diff 等一次性调用直接在各自线程上同步运行，
//  无需排队等待扫描，保证用户操作的即时响应。
//

import Dispatch
import Foundation

// MARK: - 状态结果类型（扫描侧产出，模型侧消费）

/// 解析 + 预处理后的完整仓库状态。`fileDecorations` / `directoryDecorations`
/// 与三组变更数组由 `GitScanner` 在 actor 内一次性构建，主线程拿到后只做赋值。
struct StatusResult: Equatable, Sendable {
    var branch: String?
    var headOID: String?
    var hasHead = true
    var upstream: String?
    var ahead = 0
    var behind = 0
    var topLevel = ""
    /// 绝对 git 目录（worktree 场景为真实 gitdir），供文件 watcher 监听元数据变化。
    var gitDirectory: String?
    /// 变更条目数达到上限（超大仓库），UI 提示并降低自动刷新频率。
    var didHitLimit = false
    /// 原始 porcelain 条目（已写入 repositoryRoot 规范根）。
    var entries: [GitStatusModel.Entry] = []
    var ignoredPaths: Set<String> = []
    var branches: [String] = []
    var remotes: [String] = []
    /// 仓库默认分支（clone 的 origin/HEAD 指向；非 clone 仓库用 main/master 惯例降级）。
    var defaultBranch: String?
    var recentCommits: [GitStatusModel.RecentCommit] = []
    /// 提交历史超过当前分页上限（多取一条探测）。
    var hasMoreRecentCommits = false
    var repositoryOperation: String?
    var stashCount = 0
    var loadedDetails = false

    // MARK: 预处理结果（actor 内完成）

    var mergeEntries: [GitStatusModel.Entry] = []
    var stagedEntries: [GitStatusModel.Entry] = []
    var changedEntries: [GitStatusModel.Entry] = []
    var fileDecorations: [String: GitStatusModel.FileDecoration] = [:]
    var directoryDecorations: [String: GitStatusModel.FileDecoration] = [:]
}

/// `GitScanner.loadStatus` 的返回结果。
enum StatusLoadResult: Equatable, Sendable {
    case repository(StatusResult)
    case notRepository
    case failed(String)
}

// MARK: - Actor

actor GitScanner {
    static let shared = GitScanner()

    /// EBADF 自愈后一段时间内默认 bypass fsmonitor，避免 2s 轮询反复
    /// fail → stop/start daemon → bypass 双倍扫描 thrash。
    private var bypassFsmonitorUntil = Date.distantPast
    private static let fsmonitorBypassCooldown: TimeInterval = 60

    /// 常规 git 子进程超时。fsmonitor 坏 socket 上 `git status` 可能永久阻塞；
    /// 无超时会把整个 actor 队列卡死，表现为 Retry 一直 Recovering / 无效。
    private static let gitCommandTimeout: TimeInterval = 45
    /// 单次扫描展示的变更条目上限（与 VS Code 的 10000 一致）。超过后停止解析并
    /// 标记 `didHitLimit`，UI 提示「仅显示前 N 条」并降低自动刷新频率。
    static let statusEntryLimit = 10_000
    /// Retry 恢复路径用更短超时，尽快失败并给出诊断信息。
    private static let gitRecoveryTimeout: TimeInterval = 20

    // MARK: Status pipeline

    /// 完整状态流水线：rev-parse → status → 详情命令 → 解析 → 预处理。
    /// actor 隔离保证串行；阻塞子进程等待发生在全局执行器线程上，
    /// 不占用主线程。返回的结果已切分好三组变更并构建完装饰字典。
    ///
    /// - Parameter recovery: 为 true 时全程 `-c core.fsmonitor=false`，绕过
    ///   失效的 fsmonitor daemon / IPC（Retry 与 EBADF 自愈路径使用）。
    func loadStatus(
        in root: String,
        includeIgnoredPaths: Bool,
        recovery: Bool = false,
        recentCommitLimit: Int = GitStatusModel.defaultRecentCommitPageSize
    ) -> StatusLoadResult {
        let inCooldown = Date() < bypassFsmonitorUntil
        let bypass = recovery || inCooldown
        let result = Self.loadStatusOnce(
            in: root,
            includeIgnoredPaths: includeIgnoredPaths,
            bypassFsmonitor: bypass,
            includeDetails: true,
            recentCommitLimit: recentCommitLimit,
            timeout: recovery ? Self.gitRecoveryTimeout : Self.gitCommandTimeout,
            diagnosticContext: recovery ? "recovery scan" : "status scan"
        )
        // 撞上 Bad file descriptor / 超时 / 失效 IPC：heal + cooldown + bypass 再扫。
        // cooldown 内的常规轮询只 bypass、不再每次 stop/start daemon。
        if case .failed(let message) = result,
           Self.looksLikeRecoverableGitFailure(message) {
            Self.recoverFilesystemMonitor(in: root)
            bypassFsmonitorUntil = Date().addingTimeInterval(Self.fsmonitorBypassCooldown)
            let retry = Self.loadStatusOnce(
                in: root,
                includeIgnoredPaths: includeIgnoredPaths,
                bypassFsmonitor: true,
                includeDetails: true,
                recentCommitLimit: recentCommitLimit,
                timeout: Self.gitRecoveryTimeout,
                diagnosticContext: "auto-heal scan (fsmonitor bypassed)"
            )
            return Self.annotateRecoveryFailure(retry, priorMessage: message, root: root)
        }
        return result
    }

    /// Retry 专用：不经过 actor 串行队列，避免被卡在坏 socket 上的常规扫描挡住。
    /// 调用方须先 `recoverFilesystemMonitor`，再以 bypass 全量重扫。
    nonisolated static func loadStatusForRecovery(
        in root: String,
        includeIgnoredPaths: Bool,
        recentCommitLimit: Int = GitStatusModel.defaultRecentCommitPageSize
    ) -> StatusLoadResult {
        let result = loadStatusOnce(
            in: root,
            includeIgnoredPaths: includeIgnoredPaths,
            bypassFsmonitor: true,
            includeDetails: true,
            recentCommitLimit: recentCommitLimit,
            timeout: gitRecoveryTimeout,
            diagnosticContext: "Retry recovery (fsmonitor bypassed, independent of scan queue)"
        )
        if case .failed(let message) = result {
            // 再试一次：不用 currentDirectoryURL，改 git -C，规避 cwd fd 类故障。
            let second = loadStatusOnce(
                in: root,
                includeIgnoredPaths: includeIgnoredPaths,
                bypassFsmonitor: true,
                includeDetails: true,
                recentCommitLimit: recentCommitLimit,
                timeout: gitRecoveryTimeout,
                diagnosticContext: "Retry recovery (git -C, no process cwd)",
                preferGitDashC: true
            )
            return annotateRecoveryFailure(second, priorMessage: message, root: root)
        }
        return result
    }

    /// 即时扫描：不经过 actor 串行队列。用于 stage / unstage / commit 等用户
    /// mutation 完成后的状态刷新——mutation 前已启动的 `loadStatus` 可能仍占着
    /// actor（大仓库或坏 fsmonitor 上可长达数十秒），若仍排队则 UI 长时间停在旧列表。
    ///
    /// - `includeDetails: false`（默认）：只跑 rev-parse + status + git-dir，
    ///   跳过 branches / remotes / log / stash，commit 后列表能立刻更新；
    ///   详情由后续普通 refresh / 心跳补齐（`loadedDetails == false` 时 UI 保留旧值）。
    /// - `bypassFsmonitor`：默认 false。mutation 已改 index，fsmonitor 通常仍可用；
    ///   强制 bypass 会让大仓库 `git status` 全量扫盘，Commit 后体感极慢。
    nonisolated static func loadStatusNow(
        in root: String,
        includeIgnoredPaths: Bool,
        includeDetails: Bool = false,
        bypassFsmonitor: Bool = false,
        recentCommitLimit: Int = GitStatusModel.defaultRecentCommitPageSize
    ) -> StatusLoadResult {
        loadStatusOnce(
            in: root,
            includeIgnoredPaths: includeIgnoredPaths,
            bypassFsmonitor: bypassFsmonitor,
            includeDetails: includeDetails,
            recentCommitLimit: recentCommitLimit,
            timeout: gitCommandTimeout,
            diagnosticContext: "post-mutation scan"
        )
    }

    /// 操作前 HEAD / branch / upstream 轻量快照（若干次 `rev-parse`，不做 worktree 扫描）。
    /// 替代原先整份 `git status --porcelain` 校验——大仓库上可省数秒甚至更久。
    nonisolated struct BranchSnapshot: Equatable, Sendable {
        var headOID: String?
        var branch: String?
        var upstream: String?
    }

    nonisolated static func readBranchSnapshot(
        in repoRoot: String,
        includeUpstream: Bool
    ) -> BranchSnapshot? {
        // 空仓库尚无 HEAD 时 rev-parse HEAD 非 0；仍视为有效快照（headOID = nil）。
        let head = runGit(
            ["rev-parse", "HEAD"],
            in: repoRoot,
            timeout: 10
        )
        let headOID: String?
        if head.status == 0 {
            let oid = strippingTrailingLineEnding(head.stdout)
            headOID = oid.isEmpty ? nil : oid
        } else {
            headOID = nil
        }

        let abr = runGit(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            in: repoRoot,
            timeout: 10
        )
        guard abr.status == 0 else { return nil }
        let abrName = strippingTrailingLineEnding(abr.stdout)
        let branch: String = abrName == "HEAD" || abrName.isEmpty
            ? "detached HEAD"
            : abrName

        var upstream: String?
        if includeUpstream {
            let up = runGit(
                ["rev-parse", "--abbrev-ref", "@{upstream}"],
                in: repoRoot,
                timeout: 10
            )
            if up.status == 0 {
                let name = strippingTrailingLineEnding(up.stdout)
                if !name.isEmpty { upstream = name }
            }
        }

        return BranchSnapshot(headOID: headOID, branch: branch, upstream: upstream)
    }

    /// 进入 fsmonitor bypass cooldown（Retry 成功/失败后都延长，避免 thrash）。
    func noteFilesystemMonitorBypassCooldown() {
        bypassFsmonitorUntil = Date().addingTimeInterval(Self.fsmonitorBypassCooldown)
    }

    /// 单次扫描（无自愈递归）。`bypassFsmonitor` 时对所有 git 子进程注入
    /// `-c core.fsmonitor=false`，避免再碰残留 IPC。
    ///
    /// `includeDetails`：为 false 时跳过 branches / remotes / log / stash
    ///（mutation 后快路径）；status --branch 已带 branch / ahead / behind。
    ///
    /// `nonisolated`：Retry 恢复路径可在 actor 外直接调用，不被卡住的扫描阻塞。
    nonisolated private static func loadStatusOnce(
        in root: String,
        includeIgnoredPaths: Bool,
        bypassFsmonitor: Bool,
        includeDetails: Bool,
        recentCommitLimit: Int,
        timeout: TimeInterval,
        diagnosticContext: String,
        preferGitDashC: Bool = false
    ) -> StatusLoadResult {
        let config: [String: String] = bypassFsmonitor ? ["core.fsmonitor": "false"] : [:]
        let top = runGit(
            ["rev-parse", "--show-toplevel"],
            in: root,
            config: config,
            timeout: timeout,
            preferGitDashC: preferGitDashC
        )
        guard top.status == 0 else {
            let failure = gitFailureMessage(
                top,
                command: "rev-parse --show-toplevel",
                directory: root,
                context: diagnosticContext,
                fallback: "Unable to locate the Git repository."
            )
            if top.status == 128,
               failure.localizedCaseInsensitiveContains("not a git repository"),
               !containsGitMetadata(atOrAbove: root) {
                return .notRepository
            }
            return .failed(failure)
        }
        let rawRoot = strippingTrailingLineEnding(top.stdout)
        guard !rawRoot.isEmpty else {
            return .failed(formatDiagnostic(
                summary: "Git returned an empty repository path.",
                command: "rev-parse --show-toplevel",
                directory: root,
                context: diagnosticContext,
                detail: top.stderr
            ))
        }
        let resolvedRoot = URL(fileURLWithPath: rawRoot).resolvingSymlinksInPath().path
        let status = runGit(
            [
                "status", "--porcelain=v2", "--branch", "-z",
                // VS Code `git.untrackedFiles: mixed` 语义：完全未跟踪目录折叠为
                // 单个目录条目（`? dir/`），已跟踪目录内的未跟踪文件仍逐文件显示。
                // 相比 `all`，未跟踪目录不再递归展开，条目数与扫描量级大幅下降。
                "--untracked-files=normal",
                includeIgnoredPaths ? "--ignored=matching" : "--ignored=no",
            ],
            in: resolvedRoot,
            config: config,
            timeout: timeout,
            preferGitDashC: preferGitDashC
        )
        guard status.status == 0 else {
            return .failed(gitFailureMessage(
                status,
                command: "status --porcelain=v2",
                directory: resolvedRoot,
                context: diagnosticContext,
                fallback: "Unable to read Git status."
            ))
        }
        var result = parseStatus(status.stdout, limit: Self.statusEntryLimit)
        result.topLevel = resolvedRoot
        let repoRoot = resolvedRoot

        // git-dir 供 watcher 挂载；与 details 解耦，mutation 快路径也需要。
        let gitDir = runGit(
            ["rev-parse", "--absolute-git-dir"],
            in: repoRoot,
            config: config,
            timeout: timeout,
            preferGitDashC: preferGitDashC
        )
        if gitDir.status == 0 {
            let path = strippingTrailingLineEnding(gitDir.stdout)
            result.repositoryOperation = detectRepositoryOperation(gitDirectory: path)
            result.gitDirectory = path
        }

        if includeDetails {
            result.loadedDetails = true
            // 详情命令互不依赖，并行跑以缩短全量扫描尾延迟。
            let detailQueue = DispatchQueue(
                label: "com.qzrzz.qjiao.git-status-details",
                attributes: .concurrent
            )
            let group = DispatchGroup()
            let lock = NSLock()
            var branches: [String] = []
            var remotes: [String] = []
            var recentCommits: [GitStatusModel.RecentCommit] = []
            var stashCount = 0
            var defaultBranch: String?
            var hasMoreRecentCommits = false

            group.enter()
            detailQueue.async {
                defer { group.leave() }
                let refs = runGit(
                    ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
                    in: repoRoot,
                    config: config,
                    timeout: timeout,
                    preferGitDashC: preferGitDashC
                )
                let parsed = refs.status == 0
                    ? refs.stdout.split(separator: "\n").map(String.init).sorted()
                    : []
                lock.lock()
                branches = parsed
                lock.unlock()
            }
            group.enter()
            detailQueue.async {
                defer { group.leave() }
                let remoteRun = runGit(
                    ["remote"],
                    in: repoRoot,
                    config: config,
                    timeout: timeout,
                    preferGitDashC: preferGitDashC
                )
                let parsed = remoteRun.status == 0
                    ? remoteRun.stdout.split(separator: "\n").map(String.init).sorted()
                    : []
                lock.lock()
                remotes = parsed
                lock.unlock()
            }
            group.enter()
            detailQueue.async {
                defer { group.leave() }
                // NUL-delimited name-status records preserve every valid path while
                // supplying the nested file rows used by the commit history rows.
                // 多取一条探测是否还有更多提交（分页）。
                let log = runGit([
                    "log", "-n", "\(recentCommitLimit + 1)", "--decorate=short",
                    "--pretty=format:%x1e%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1f%P%x1f%D",
                    "--name-status", "-z",
                ], in: repoRoot, config: config, timeout: timeout, preferGitDashC: preferGitDashC)
                let parsed = log.status == 0 ? parseRecentCommits(log.stdout) : []
                lock.lock()
                recentCommits = Array(parsed.prefix(recentCommitLimit))
                hasMoreRecentCommits = parsed.count > recentCommitLimit
                lock.unlock()
            }
            group.enter()
            detailQueue.async {
                defer { group.leave() }
                let stash = runGit(
                    ["rev-list", "--walk-reflogs", "--count", "refs/stash"],
                    in: repoRoot,
                    config: config,
                    timeout: timeout,
                    preferGitDashC: preferGitDashC
                )
                let count = stash.status == 0
                    ? (Int(stash.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
                    : 0
                lock.lock()
                stashCount = count
                lock.unlock()
            }
            group.enter()
            detailQueue.async {
                defer { group.leave() }
                // 一条命令列出所有 remote 的 symbolic HEAD（如 `origin/HEAD origin/main`）。
                // 普通 ref 的 symref 为空会被过滤；origin 优先，其余 remote 兜底，
                // 无需先知道 remotes 列表，且与其它详情并行不增加尾部延迟。
                let remoteHeads = runGit(
                    ["for-each-ref", "--format=%(refname:short) %(symref)", "refs/remotes"],
                    in: repoRoot,
                    config: config,
                    timeout: timeout,
                    preferGitDashC: preferGitDashC
                )
                var parsed: String?
                if remoteHeads.status == 0 {
                    for line in remoteHeads.stdout.split(separator: "\n") {
                        let parts = line.split(separator: " ", maxSplits: 1)
                        guard parts.count == 2 else { continue }
                        let refName = parts[0]
                        let symref = parts[1]
                        guard refName.hasSuffix("/HEAD") else { continue }
                        let prefix = String(refName.dropLast("/HEAD".count)) + "/"
                        guard symref.hasPrefix(prefix) else { continue }
                        let branch = String(symref.dropFirst(prefix.count))
                        if refName.hasPrefix("origin/") {
                            parsed = branch
                            break
                        }
                        if parsed == nil { parsed = branch }
                    }
                }
                lock.lock()
                defaultBranch = parsed
                lock.unlock()
            }
            group.wait()
            result.branches = branches
            result.remotes = remotes
            result.recentCommits = recentCommits
            result.stashCount = stashCount
            result.hasMoreRecentCommits = hasMoreRecentCommits
            // 非 clone 仓库（git remote add）没有 remote HEAD symbolic ref，
            // 按 main > master 惯例降级；两者都必须存在于本地分支列表。
            var resolvedDefaultBranch = defaultBranch
            if resolvedDefaultBranch == nil {
                if branches.contains("main") {
                    resolvedDefaultBranch = "main"
                } else if branches.contains("master") {
                    resolvedDefaultBranch = "master"
                }
            }
            if let db = resolvedDefaultBranch, !branches.contains(db) {
                resolvedDefaultBranch = nil
            }
            result.defaultBranch = resolvedDefaultBranch
        } else {
            result.loadedDetails = false
        }

        return .repository(preprocess(result))
    }

    // MARK: Preprocess

    /// 把原始条目切分为 merge / staged / changed 三组，并构建文件级与
    /// 目录级装饰字典。所有 O(n) 计算都发生在扫描线程上，主线程
    /// 的 `applyRepository` 只做 `@Published` 赋值。
    nonisolated private static func preprocess(_ result: StatusResult) -> StatusResult {
        var result = result
        let entries = result.entries.map { entry in
            var entry = entry
            entry.repositoryRoot = result.topLevel
            return entry
        }
        result.entries = entries

        // 文件级装饰 + 目录聚合装饰一次构建。未跟踪目录条目（`? dir/`，带尾斜杠）
        // 统一去尾斜杠作为 key：文件树查询与目录聚合使用的都是无斜杠路径。
        var fileDecorations: [String: GitStatusModel.FileDecoration] = [:]
        var directoryDecorations: [String: GitStatusModel.FileDecoration] = [:]
        for entry in entries {
            let decoration = fileDecoration(for: entry)
            let key = entry.isDirectoryEntry
                ? String(entry.path.dropLast())
                : entry.path
            fileDecorations[key] = decoration

            // 向上聚合祖先目录（子项最高优先级）：存在更高优先级时覆盖，
            // 渲染期按目录 O(1) 查询，替换原先的全量字典扫描。
            var directory = (key as NSString).deletingLastPathComponent
            while !directory.isEmpty {
                if let current = directoryDecorations[directory],
                   current.directoryPriority >= decoration.directoryPriority {
                    // 该目录已有同优先级或更高优先级的装饰，且其祖先目录必然也已
                    // 被同一条目传播到不低于当前值，可安全提前结束。
                    break
                }
                directoryDecorations[directory] = decoration
                directory = (directory as NSString).deletingLastPathComponent
            }
            // 目录条目自身也写入聚合表（文件树目录查询的兜底）。
            if entry.isDirectoryEntry {
                directoryDecorations[key] = decoration
            }
        }
        result.fileDecorations = fileDecorations
        result.directoryDecorations = directoryDecorations

        result.mergeEntries = entries.filter(\.isConflict)
        result.stagedEntries = entries.filter {
            !$0.isConflict && $0.staged != "." && $0.staged != "?"
        }
        result.changedEntries = entries.filter {
            !$0.isConflict && $0.unstaged != "."
        }
        return result
    }

    nonisolated private static func fileDecoration(for entry: GitStatusModel.Entry) -> GitStatusModel.FileDecoration {
        let statuses = [entry.staged, entry.unstaged]
        if entry.isConflict || statuses.contains("U") { return .conflict }
        if statuses.contains("?") { return .untracked }
        if entry.staged == "A" { return .added }
        if statuses.contains("D") { return .deleted }
        if statuses.contains("R") { return .renamed }
        if statuses.contains("C") { return .copied }
        return .modified
    }

    // MARK: Sync Git helpers

    /// Resolves the active repository and distinguishes a normal non-repo
    /// directory from an actual Git failure that the UI should surface.
    nonisolated static func resolveRepositoryRoot(in root: String) -> String? {
        let top = runGit(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else { return nil }
        let path = strippingTrailingLineEnding(top.stdout)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// 修复失效的 Git fsmonitor daemon：停止 → 删除残留 IPC socket →
    /// （若仓库启用了内建 fsmonitor）重新拉起。
    ///
    /// 「Bad file descriptor」类错误多由 daemon 崩溃、git 版本切换或
    /// Xcode / 命令行 Git 混用后残留的 socket 引起，仅重新扫描无法自愈。
    ///
    /// **始终**尝试 stop + 删除 IPC（即使 `core.fsmonitor` 不是 `true`），
    /// 避免残留 socket 继续污染后续 git 调用；仅在确认启用了内建 daemon
    /// 时才 `start`，避免给 hook 路径 / 未启用仓库多起无用进程。
    /// stop / start 失败均忽略。恢复路径用短超时，避免 stop 自身挂死。
    nonisolated static func recoverFilesystemMonitor(in root: String) {
        let timeout = gitRecoveryTimeout
        // 强制 bypass，避免 stop/rev-parse 再撞上坏 IPC。
        let bypass = ["core.fsmonitor": "false"]
        _ = runGit(
            ["fsmonitor--daemon", "stop"],
            in: root,
            config: bypass,
            timeout: timeout
        )

        var gitDirectory: String?
        let gitDir = runGit(
            ["rev-parse", "--absolute-git-dir"],
            in: root,
            config: bypass,
            timeout: timeout
        )
        if gitDir.status == 0 {
            gitDirectory = strippingTrailingLineEnding(gitDir.stdout)
        } else {
            // rev-parse 本身也可能因坏 socket 失败；回退到 .git 目录或
            // worktree 的 `gitdir:` 指针文件，再删残留 IPC。
            gitDirectory = resolveGitDirectoryFallback(in: root)
        }
        if let gitDirectory {
            let socketPath = (gitDirectory as NSString)
                .appendingPathComponent("fsmonitor--daemon.ipc")
            try? FileManager.default.removeItem(atPath: socketPath)
            // 个别 git 版本把 socket 放在 git common dir；再清一次 common 路径。
            let common = runGit(
                ["rev-parse", "--git-common-dir"],
                in: root,
                config: bypass,
                timeout: timeout
            )
            if common.status == 0 {
                let commonPath = strippingTrailingLineEnding(common.stdout)
                let resolvedCommon: String
                if (commonPath as NSString).isAbsolutePath {
                    resolvedCommon = commonPath
                } else {
                    resolvedCommon = (root as NSString).appendingPathComponent(commonPath)
                }
                let commonSocket = (resolvedCommon as NSString)
                    .appendingPathComponent("fsmonitor--daemon.ipc")
                if commonSocket != socketPath {
                    try? FileManager.default.removeItem(atPath: commonSocket)
                }
            }
        }

        let config = runGit(
            ["config", "--get", "core.fsmonitor"],
            in: root,
            config: bypass,
            timeout: timeout
        )
        let usesBuiltinDaemon = config.status == 0
            && strippingTrailingLineEnding(config.stdout) == "true"
        if usesBuiltinDaemon {
            // 恢复扫描不依赖 daemon；延后 start 失败也不影响 Retry。
            _ = runGit(
                ["fsmonitor--daemon", "start"],
                in: root,
                config: bypass,
                timeout: timeout
            )
        }
    }

    /// Cocoa / POSIX 风格的失效 fd 文案（Process 启动失败或 git 读写坏 socket）。
    nonisolated static func looksLikeStaleFileDescriptor(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("bad file descriptor")
            || lower.contains("ebadf")
    }

    /// 可通过 stop daemon + bypass 自愈的失败（含超时——常为坏 IPC 挂死）。
    nonisolated static func looksLikeRecoverableGitFailure(_ message: String) -> Bool {
        if looksLikeStaleFileDescriptor(message) { return true }
        let lower = message.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("fsmonitor")
            || lower.contains("broken pipe")
            || lower.contains("connection refused")
            || lower.contains("socket")
    }

    /// 恢复扫描仍失败时，把先前错误与已采取的恢复步骤附到诊断文案。
    nonisolated private static func annotateRecoveryFailure(
        _ result: StatusLoadResult,
        priorMessage: String,
        root: String
    ) -> StatusLoadResult {
        guard case .failed(let message) = result else { return result }
        if message.contains("Recovery steps:") { return result }
        let note = [
            message,
            "",
            "Recovery steps:",
            "• Stopped git fsmonitor--daemon (if running)",
            "• Removed .git/fsmonitor--daemon.ipc socket residue",
            "• Retried with core.fsmonitor=false",
            "Directory: \(root)",
            priorMessage == message
                ? nil
                : "Earlier error: \(priorMessage.split(separator: "\n").first.map(String.init) ?? priorMessage)",
        ].compactMap { $0 }.joined(separator: "\n")
        return .failed(note)
    }

    /// rev-parse 失败时解析 `root/.git`：目录仓库直接用；worktree 的
    /// `.git` 文件形如 `gitdir: /path/to/real/gitdir`。
    nonisolated private static func resolveGitDirectoryFallback(in root: String) -> String? {
        let candidate = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return candidate
        }
        guard let content = try? String(contentsOfFile: candidate, encoding: .utf8) else {
            return nil
        }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("gitdir:") else { continue }
            let raw = trimmed.dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            let url: URL
            if (raw as NSString).isAbsolutePath {
                url = URL(fileURLWithPath: raw)
            } else {
                url = URL(fileURLWithPath: candidate)
                    .deletingLastPathComponent()
                    .appendingPathComponent(raw)
            }
            return url.resolvingSymlinksInPath().path
        }
        return nil
    }

    /// Runs Git while draining stdout and stderr concurrently. Reading either
    /// pipe only after the process exits can deadlock when the other fills.
    ///
    /// - Parameter config: 注入 `git -c key=value` 临时配置（不写磁盘），
    ///   例如 recovery 路径的 `core.fsmonitor=false`。
    /// - Parameter timeout: 子进程最长等待秒数；超时 SIGTERM→SIGKILL。
    /// - Parameter preferGitDashC: 为 true 时用 `git -C dir` 而不设置
    ///   `Process.currentDirectoryURL`，规避 cwd 相关 fd 故障。
    nonisolated static func runGit(
        _ args: [String],
        in dir: String,
        config: [String: String] = [:],
        timeout: TimeInterval = gitCommandTimeout,
        preferGitDashC: Bool = false
    ) -> (status: Int32, stdout: String, stderr: String) {
        var fullArgs: [String] = []
        if preferGitDashC {
            fullArgs.append(contentsOf: ["-C", dir])
        }
        for (key, value) in config {
            fullArgs.append(contentsOf: ["-c", "\(key)=\(value)"])
        }
        fullArgs.append(contentsOf: args)

        // 启动失败（尤其 EBADF）时换新 pipe / stdin 再试；第二次改用 git -C。
        let first = launchGit(
            fullArgs,
            in: preferGitDashC ? nil : dir,
            timeout: timeout
        )
        if first.launched && first.result.status != -1 {
            return first.result
        }
        if first.launched && !looksLikeStaleFileDescriptor(first.result.stderr)
            && !first.result.stderr.localizedCaseInsensitiveContains("timed out") {
            return first.result
        }
        // 第二次：强制 git -C + 全新 IO，不设 process cwd。
        var retryArgs: [String] = []
        if !preferGitDashC {
            retryArgs.append(contentsOf: ["-C", dir])
        }
        // fullArgs 在 preferGitDashC 时已含 -C；否则补上。
        if preferGitDashC {
            retryArgs = fullArgs
        } else {
            for (key, value) in config {
                retryArgs.append(contentsOf: ["-c", "\(key)=\(value)"])
            }
            retryArgs.append(contentsOf: args)
        }
        let second = launchGit(retryArgs, in: nil, timeout: timeout)
        if second.launched {
            return second.result
        }
        // 两次都启动失败：合并诊断。
        let detail = [
            second.result.stderr,
            first.result.stderr != second.result.stderr ? "First attempt: \(first.result.stderr)" : nil,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return (-1, "", detail.isEmpty ? first.result.stderr : detail)
    }

    /// 实际拉起 git 子进程（统一走 SubprocessRunner，含进程树终止与读端兜底）。
    /// - `in` 为 nil 时不设置 `currentDirectoryURL`（配合 `git -C`）。
    /// - `launched == false` 表示 `Process.run()` 抛错。
    private nonisolated static func launchGit(
        _ args: [String],
        in dir: String?,
        timeout: TimeInterval
    ) -> (launched: Bool, result: (status: Int32, stdout: String, stderr: String)) {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Fail rather than hanging on a credential prompt behind the app.
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Git diagnostics are parsed only to distinguish an ordinary folder
        // from a broken repository. Pinning the locale makes that safe and
        // also keeps relative dates stable in the compact history list.
        env["LC_ALL"] = "C"

        let run = SubprocessRunner.run(
            SubprocessRunner.Config(
                executable: "/usr/bin/git",
                arguments: args,
                workingDirectory: dir,
                environment: env,
                timeout: timeout
            )
        )

        if !run.launched {
            return (
                false,
                (-1, "", formatLaunchError(run.launchError ?? "Unknown launch error", args: args, directory: dir))
            )
        }

        var stderrText = String(data: run.stderr, encoding: .utf8) ?? ""
        if run.timedOut {
            // 超时终止：坏 fsmonitor socket 上 git 可能永久阻塞，拖死 actor 队列。
            let timeoutNote = "git timed out after \(Int(timeout))s"
            stderrText = stderrText.isEmpty
                ? timeoutNote
                : timeoutNote + "\n" + stderrText
            return (
                true,
                (-1, String(data: run.stdout, encoding: .utf8) ?? "", stderrText)
            )
        }
        return (
            true,
            (
                run.exitCode,
                String(data: run.stdout, encoding: .utf8) ?? "",
                stderrText
            )
        )
    }

    /// 把启动失败诊断（来自 SubprocessRunner）拼上命令与目录信息。
    private nonisolated static func formatLaunchError(
        _ description: String,
        args: [String],
        directory: String?
    ) -> String {
        var lines: [String] = [description]
        let command = args.prefix(4).joined(separator: " ")
        if !command.isEmpty {
            lines.append("Command: git \(command)\(args.count > 4 ? " …" : "")")
        }
        if let directory, !directory.isEmpty {
            lines.append("Directory: \(directory)")
        }
        return lines.joined(separator: "\n")
    }

    /// A malformed `.git` directory/file can produce the same rev-parse text
    /// as a plain folder. Preserve that as an actionable status error instead
    /// of offering to initialize a nested repository on top of broken metadata.
    private nonisolated static func containsGitMetadata(atOrAbove root: String) -> Bool {
        let fm = FileManager.default
        var directory = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        while true {
            if fm.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return true
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return false }
            directory = parent
        }
    }

    private nonisolated static func strippingTrailingLineEnding(_ value: String) -> String {
        var value = value
        if value.hasSuffix("\n") { value.removeLast() }
        if value.hasSuffix("\r") { value.removeLast() }
        return value
    }

    /// 组合 git 失败诊断：摘要 + 命令 + 目录 + 上下文 + 原始输出。
    private nonisolated static func gitFailureMessage(
        _ run: (status: Int32, stdout: String, stderr: String),
        command: String,
        directory: String,
        context: String,
        fallback: String
    ) -> String {
        let body = [run.stderr, run.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return formatDiagnostic(
            summary: body ?? fallback,
            command: command,
            directory: directory,
            context: context,
            detail: body == nil ? nil : "exit \(run.status)",
            exitCode: run.status
        )
    }

    private nonisolated static func formatDiagnostic(
        summary: String,
        command: String,
        directory: String,
        context: String,
        detail: String? = nil,
        exitCode: Int32? = nil
    ) -> String {
        var lines: [String] = [summary]
        if let detail, !detail.isEmpty, !summary.contains(detail) {
            lines.append(detail)
        }
        lines.append("Command: git \(command)")
        if let exitCode {
            lines.append("Exit code: \(exitCode)")
        }
        if !directory.isEmpty {
            lines.append("Directory: \(directory)")
        }
        if !context.isEmpty {
            lines.append("Context: \(context)")
        }
        return lines.joined(separator: "\n")
    }

    /// Parses NUL-delimited porcelain v2. Unlike Git's default quoted output,
    /// this preserves spaces, quotes, tabs, and newlines in file names.
    ///
    /// - Parameter limit: 变更条目上限（超大仓库保护）。达到后停止解析并标记
    ///   `didHitLimit`；porcelain v2 的 header 记录（`# branch.*`）都在条目之前，
    ///   截断不影响分支 / 上下游信息。
    nonisolated static func parseStatus(_ output: String, limit: Int? = nil) -> StatusResult {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result = StatusResult()
        var index = 0
        while index < records.count {
            if let limit, limit > 0, result.entries.count >= limit {
                result.didHitLimit = true
                break
            }
            let record = records[index]
            if record.hasPrefix("# branch.oid ") {
                let oid = String(record.dropFirst("# branch.oid ".count))
                result.hasHead = oid != "(initial)"
                result.headOID = result.hasHead ? oid : nil
            } else if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                result.branch = name == "(detached)" ? "detached HEAD" : name
            } else if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { result.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { result.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8)
                if fields.count == 9, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    result.entries.append(
                        GitStatusModel.Entry(path: String(fields[8]), staged: xy[0], unstaged: xy[1])
                    )
                }
            } else if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9)
                if fields.count == 10, fields[1].count == 2, index + 1 < records.count {
                    let xy = Array(fields[1])
                    // With -z, the destination is in this record and the
                    // original path is the following NUL-delimited token.
                    result.entries.append(
                        GitStatusModel.Entry(
                            path: String(fields[9]), staged: xy[0], unstaged: xy[1],
                            origPath: records[index + 1]
                        )
                    )
                    index += 1
                }
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10)
                if fields.count == 11, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    result.entries.append(
                        GitStatusModel.Entry(
                            path: String(fields[10]), staged: xy[0], unstaged: xy[1],
                            isConflict: true
                        )
                    )
                }
            } else if record.hasPrefix("? ") {
                result.entries.append(
                    GitStatusModel.Entry(path: String(record.dropFirst(2)), staged: "?", unstaged: "?")
                )
            } else if record.hasPrefix("! ") {
                result.ignoredPaths.insert(String(record.dropFirst(2)))
            }
            index += 1
        }
        return result
    }

    nonisolated static func parseRecentCommits(_ output: String) -> [GitStatusModel.RecentCommit] {
        output.split(separator: "\u{1e}").compactMap { record in
            var chunks = record.split(separator: "\u{0}", omittingEmptySubsequences: false)
                .map(String.init)
            guard !chunks.isEmpty else { return nil }

            // With --name-status -z, the first status follows the pretty
            // header after a newline; subsequent statuses are their own NUL
            // fields. Rename/copy records carry both old and new paths.
            let headerAndStatus = chunks.removeFirst()
            let boundary = headerAndStatus.lastIndex(of: "\n")
            let header = boundary.map { String(headerAndStatus[..<$0]) } ?? headerAndStatus
            var statusToken = boundary.map {
                String(headerAndStatus[headerAndStatus.index(after: $0)...])
            } ?? ""
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 7 else { return nil }

            var files: [GitStatusModel.RecentCommit.FileChange] = []
            var index = 0
            while !statusToken.isEmpty, index < chunks.count {
                guard let status = statusToken.first else { break }
                if status == "R" || status == "C" {
                    guard index + 1 < chunks.count else { break }
                    files.append(.init(
                        status: status,
                        path: chunks[index + 1],
                        originalPath: chunks[index]
                    ))
                    index += 2
                } else {
                    files.append(.init(
                        status: status,
                        path: chunks[index],
                        originalPath: nil
                    ))
                    index += 1
                }
                guard index < chunks.count else { break }
                statusToken = chunks[index]
                index += 1
            }

            let parentHash = fields[5]
                .split(separator: " ")
                .first
                .map(String.init)
            let references = fields[6]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return GitStatusModel.RecentCommit(
                hash: String(fields[0]), shortHash: String(fields[1]),
                subject: String(fields[2]), author: String(fields[3]),
                relativeDate: String(fields[4]),
                parentHash: parentHash,
                references: references,
                files: files
            )
        }
    }

    nonisolated static func detectRepositoryOperation(gitDirectory: String) -> String? {
        let fm = FileManager.default
        let git = URL(fileURLWithPath: gitDirectory, isDirectory: true)
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: git.appendingPathComponent(name).path)
        }

        if exists("rebase-merge") || exists("rebase-apply") { return "Rebase in progress" }
        if exists("MERGE_HEAD") { return "Merge in progress" }
        if exists("CHERRY_PICK_HEAD") { return "Cherry-pick in progress" }
        if exists("REVERT_HEAD") { return "Revert in progress" }
        if exists("BISECT_LOG") { return "Bisect in progress" }
        return nil
    }
}
