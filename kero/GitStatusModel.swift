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
            case .running: return label + "…"
            case .succeeded: return label + " completed"
            case .failed: return label + " failed"
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

    func absolutePath(for entry: Entry) -> String {
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (base as NSString).appendingPathComponent(entry.path)
    }

    func isCurrent(_ entry: Entry) -> Bool {
        entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot
    }

    func sync(root: String) {
        if root != rootPath {
            contextGeneration &+= 1
            rootPath = root
            hasResolvedStatus = false
            clearRepositoryState(preserveIdentity: true)
        }
        refresh()
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
            guard let self, self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else { return }
            self.isRefreshing = false
            self.apply(result)
            self.hasResolvedStatus = true
            if self.refreshPending {
                self.refreshPending = false
                // 扫描耗时超过 2s 轮询间隔时，完成即再扫会形成无间隙连续轮询，
                // git 子进程持续占满 CPU / IO；延迟一小段再补扫以留出呼吸窗口。
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard let self, !self.isRefreshing, !self.isBusy,
                          self.rootPath == root else { return }
                    self.refresh()
                }
            }
        }
    }

    /// Retry 的「从头刷新」：先修复失效的 Git fsmonitor daemon（停止 →
    /// 清理残留 IPC socket → 重新拉起，见 `GitScanner.recoverFilesystemMonitor`），
    /// 再全量重扫仓库状态。用于「Bad file descriptor」这类 daemon / IPC
    /// 失效错误——仅重新扫描无法自愈。修复期间置 `isBusy` 禁用 UI，
    /// 完成后恢复并走正常 `refresh()` 流程。
    func retryRecovery() {
        let root = rootPath
        let generation = contextGeneration
        guard !root.isEmpty, !isRefreshing, !isBusy else { return }
        isBusy = true
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                GitScanner.recoverFilesystemMonitor(in: root)
            }.value
            guard let self else { return }
            self.isBusy = false
            guard self.contextGeneration == generation, self.rootPath == root else { return }
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
        guard validate(entry) else { return }
        let original = entry.unstaged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        perform(
            label: "Stage \(entry.fileName)",
            commands: [["--literal-pathspecs", "add", "--"] + paths]
        )
    }

    func unstage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.staged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        let args = hasHead
            ? ["--literal-pathspecs", "restore", "--staged", "--"] + paths
            : ["--literal-pathspecs", "rm", "--cached", "-f", "--"] + paths
        perform(label: "Unstage \(entry.fileName)", commands: [args])
    }

    /// 将工作区所有变更添加到暂存区 (`git add -A`)。
    /// - Parameter completion: 完成后的回调，传入操作是否成功。
    func stageAll(completion: (@MainActor (Bool) -> Void)? = nil) {
        perform(label: "Stage all changes", commands: [["add", "-A"]], completion: completion)
    }

    func unstageAll() {
        let args = hasHead
            ? ["restore", "--staged", "--", "."]
            : ["rm", "--cached", "-r", "-f", "--", "."]
        perform(label: "Unstage all changes", commands: [args])
    }

    /// Restores a tracked file from the index, or moves an untracked file to
    /// the Trash. The UI confirms before calling this.
    func discard(_ entry: Entry) {
        guard validate(entry) else { return }
        if entry.isIntentToAdd {
            perform(
                label: "Remove intent-to-add for \(entry.fileName)",
                commands: [[
                    "--literal-pathspecs", "rm", "--cached", "-f", "--", entry.path,
                ]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: "Move \(entry.fileName) to Trash",
                    completedBefore: "Removed the intent-to-add index entry."
                )
            }
        } else if entry.isUntracked || entry.isWorktreeCopy {
            trash(paths: [entry.path], label: "Move \(entry.fileName) to Trash")
        } else if entry.isWorktreeRename, let original = entry.origPath {
            perform(
                label: "Restore \((original as NSString).lastPathComponent)",
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", original]]
            ) { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: "Move \(entry.fileName) to Trash",
                    completedBefore: "Restored \((original as NSString).lastPathComponent)."
                )
            }
        } else {
            perform(
                label: "Discard changes in \(entry.fileName)",
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
            trash(paths: untracked, label: "Move untracked files to Trash")
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
            perform(label: "Discard all changes", commands: commands) { [weak self] success in
                guard success, !untracked.isEmpty else { return }
                self?.trash(
                    paths: untracked,
                    label: "Finish discarding all changes",
                    completedBefore: completedSteps.joined(separator: "\n")
                )
            }
        }
    }

    func cancelStaleDiscard() {
        failImmediately("Files changed while the confirmation was open. Review them and try again.")
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
            failImmediately("Enter a commit message", completion: completion)
            return
        }
        guard includeAll || !stagedEntries.isEmpty || amend else {
            failImmediately("Stage changes before committing", completion: completion)
            return
        }

        var commands: [[String]] = []
        if includeAll { commands.append(["add", "-A"]) }
        var commitArgs = ["commit"]
        if amend { commitArgs.append("--amend") }
        commitArgs += ["-m", trimmed]
        commands.append(commitArgs)
        let label = amend ? "Amend commit" : (includeAll ? "Stage all and commit" : "Commit staged changes")
        perform(label: label, commands: commands, completion: completion)
    }

    /// Compatibility for older call sites. The behavior remains explicit in
    /// the new panel, which uses the overload above.
    func commit(message: String) {
        commit(message: message, includeAll: stagedEntries.isEmpty)
    }

    func fetch() {
        guard !remotes.isEmpty else {
            failImmediately("No Git remote is configured")
            return
        }
        perform(
            label: "Fetch",
            commands: [["fetch", "--all", "--prune"]],
            requiresStableHead: false
        )
    }

    func pull() {
        guard hasUpstream else {
            failImmediately("This branch has no upstream to pull from")
            return
        }
        perform(
            label: "Pull",
            commands: [["pull", "--ff-only"]],
            requiresStableUpstream: true
        )
    }

    func push() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately("Create or switch to a branch before publishing detached HEAD")
            return
        }
        if hasUpstream {
            perform(label: "Push", commands: [["push"]], requiresStableUpstream: true)
            return
        }
        guard let remote = unambiguousRemote else {
            failImmediately(remotes.isEmpty
                ? "Add a Git remote before publishing this branch"
                : "Choose which remote should receive this branch")
            return
        }
        perform(label: "Publish branch", commands: [["push", "-u", remote, "HEAD"]])
    }

    func publish(to remote: String) {
        guard branch != "detached HEAD" else {
            failImmediately("Create or switch to a branch before publishing detached HEAD")
            return
        }
        guard remotes.contains(remote) else {
            failImmediately("The selected Git remote is no longer available")
            return
        }
        perform(
            label: "Publish branch to \(remote)",
            commands: [["push", "-u", remote, "HEAD"]]
        )
    }

    func syncChanges() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately("Create or switch to a branch before publishing detached HEAD")
            return
        }
        if hasUpstream {
            perform(
                label: "Sync changes",
                commands: [["pull", "--ff-only"], ["push"]],
                requiresStableUpstream: true
            )
        } else {
            guard let remote = unambiguousRemote else {
                failImmediately(remotes.isEmpty
                    ? "Add a Git remote before publishing this branch"
                    : "Choose which remote should receive this branch")
                return
            }
            perform(label: "Publish branch", commands: [["push", "-u", remote, "HEAD"]])
        }
    }

    // MARK: - Branches, stash, and repository setup

    func switchBranch(to name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !name.isEmpty, name != branch else {
            completion?(name == branch)
            return
        }
        perform(label: "Switch to \(name)", commands: [["switch", name]], completion: completion)
    }

    func createBranch(named name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately("Enter a branch name", completion: completion)
            return
        }
        perform(
            label: "Create branch \(trimmed)",
            commands: [["switch", "-c", trimmed]],
            completion: completion
        )
    }

    func stash(includeUntracked: Bool = true) {
        guard totalChangeCount > 0 else {
            failImmediately("There are no changes to stash")
            return
        }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        perform(label: "Stash changes", commands: [args])
    }

    func stashPop() {
        guard stashCount > 0 else {
            failImmediately("There are no stashes to pop")
            return
        }
        perform(label: "Pop stash", commands: [["stash", "pop"]])
    }

    func initializeRepository(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !rootPath.isEmpty else {
            failImmediately("Open a terminal directory first", completion: completion)
            return
        }
        perform(
            label: "Initialize repository",
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
        completion: (@MainActor (Bool) -> Void)? = nil
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
                        let liveStatus = GitScanner.runGit(
                            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                            in: expectedRepositoryRoot
                        )
                        let live = liveStatus.status == 0
                            ? GitScanner.parseStatus(liveStatus.stdout)
                            : nil
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
                self.refresh()
                return
            }
            let finishedAt = Date()
            if let failureCode = batch.failureCode {
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
                    output: batch.output.isEmpty ? "Completed successfully." : batch.output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(true)
            }
            self.refresh()
        }
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
            label: "Git action",
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
                let liveStatus = GitScanner.runGit(
                    ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                    in: expectedRepositoryRoot
                )
                let live = liveStatus.status == 0 ? GitScanner.parseStatus(liveStatus.stdout) : nil
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
                self.refresh()
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
            self.refresh()
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
        isBusy = runningOperationID != nil
        operation = failedOperation
        lastError = failedError
        statusError = nil
        statusRequestID &+= 1
        if !preserveIdentity { repositoryIdentity = "" }
    }

    private func apply(_ loadResult: StatusLoadResult) {
        switch loadResult {
        case .notRepository:
            // A refresh can finish after a user action starts. Do not let a
            // transient status failure erase the active operation/result.
            if isBusy { return }
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(preserveFailedOperation: preserveFailure)
            return
        case .failed(let message):
            if isBusy { return }
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
            statusError = message
            return
        case .repository(let result):
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
    }

    /// 兼容旧调用点（命令面板 / Diff / LocalAI 的一次性同步查询）。
    /// 真实实现在 `GitScanner.runGit`。
    nonisolated static func runGit(
        _ args: [String], in dir: String
    ) -> (status: Int32, stdout: String, stderr: String) {
        GitScanner.runGit(args, in: dir)
    }
}
