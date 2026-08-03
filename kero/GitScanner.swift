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
    /// 原始 porcelain 条目（已写入 repositoryRoot 规范根）。
    var entries: [GitStatusModel.Entry] = []
    var ignoredPaths: Set<String> = []
    var branches: [String] = []
    var remotes: [String] = []
    var recentCommits: [GitStatusModel.RecentCommit] = []
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
        recovery: Bool = false
    ) -> StatusLoadResult {
        let inCooldown = Date() < bypassFsmonitorUntil
        let bypass = recovery || inCooldown
        let result = loadStatusOnce(
            in: root,
            includeIgnoredPaths: includeIgnoredPaths,
            bypassFsmonitor: bypass
        )
        // 撞上 Bad file descriptor / 失效 IPC：heal + 进入 cooldown + bypass 再扫。
        // cooldown 内的常规轮询只 bypass、不再每次 stop/start daemon；
        // 仅当本次结果仍是 EBADF 时才 heal（已 bypass 的成功扫描不进这里）。
        if case .failed(let message) = result,
           Self.looksLikeStaleFileDescriptor(message) {
            Self.recoverFilesystemMonitor(in: root)
            bypassFsmonitorUntil = Date().addingTimeInterval(Self.fsmonitorBypassCooldown)
            return loadStatusOnce(
                in: root,
                includeIgnoredPaths: includeIgnoredPaths,
                bypassFsmonitor: true
            )
        }
        return result
    }

    /// 单次扫描（无自愈递归）。`bypassFsmonitor` 时对所有 git 子进程注入
    /// `-c core.fsmonitor=false`，避免再碰残留 IPC。
    private func loadStatusOnce(
        in root: String,
        includeIgnoredPaths: Bool,
        bypassFsmonitor: Bool
    ) -> StatusLoadResult {
        let config: [String: String] = bypassFsmonitor ? ["core.fsmonitor": "false"] : [:]
        let top = Self.runGit(["rev-parse", "--show-toplevel"], in: root, config: config)
        guard top.status == 0 else {
            let failure = Self.gitFailureMessage(top, fallback: "Unable to locate the Git repository.")
            if top.status == 128,
               failure.localizedCaseInsensitiveContains("not a git repository"),
               !Self.containsGitMetadata(atOrAbove: root) {
                return .notRepository
            }
            return .failed(failure)
        }
        let rawRoot = Self.strippingTrailingLineEnding(top.stdout)
        guard !rawRoot.isEmpty else {
            return .failed("Git returned an empty repository path.")
        }
        let resolvedRoot = URL(fileURLWithPath: rawRoot).resolvingSymlinksInPath().path
        let status = Self.runGit(
            [
                "status", "--porcelain=v2", "--branch", "-z",
                // VS Code `git.untrackedFiles: mixed` 语义：完全未跟踪目录折叠为
                // 单个目录条目（`? dir/`），已跟踪目录内的未跟踪文件仍逐文件显示。
                // 相比 `all`，未跟踪目录不再递归展开，条目数与扫描量级大幅下降。
                "--untracked-files=normal",
                includeIgnoredPaths ? "--ignored=matching" : "--ignored=no",
            ],
            in: resolvedRoot,
            config: config
        )
        guard status.status == 0 else {
            return .failed(Self.gitFailureMessage(status, fallback: "Unable to read Git status."))
        }
        var result = Self.parseStatus(status.stdout)
        result.topLevel = resolvedRoot

        result.loadedDetails = true
        let repoRoot = resolvedRoot

        let refs = Self.runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            in: repoRoot,
            config: config
        )
        if refs.status == 0 {
            result.branches = refs.stdout.split(separator: "\n").map(String.init).sorted()
        }

        let remoteRun = Self.runGit(["remote"], in: repoRoot, config: config)
        if remoteRun.status == 0 {
            result.remotes = remoteRun.stdout.split(separator: "\n").map(String.init).sorted()
        }

        let log = Self.runGit(
            ["log", "-n", "8", "--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1e"],
            in: repoRoot,
            config: config
        )
        if log.status == 0 { result.recentCommits = Self.parseRecentCommits(log.stdout) }

        let stash = Self.runGit(
            ["rev-list", "--walk-reflogs", "--count", "refs/stash"],
            in: repoRoot,
            config: config
        )
        if stash.status == 0 {
            result.stashCount = Int(stash.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        let gitDir = Self.runGit(
            ["rev-parse", "--absolute-git-dir"],
            in: repoRoot,
            config: config
        )
        if gitDir.status == 0 {
            let path = Self.strippingTrailingLineEnding(gitDir.stdout)
            result.repositoryOperation = Self.detectRepositoryOperation(gitDirectory: path)
        }
        return .repository(Self.preprocess(result))
    }

    // MARK: Preprocess

    /// 把原始条目切分为 merge / staged / changed 三组，并构建文件级与
    /// 目录级装饰字典。所有 O(n) 计算都发生在 actor 执行器上，主线程
    /// 的 `applyRepository` 只做 `@Published` 赋值。
    private static func preprocess(_ result: StatusResult) -> StatusResult {
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

    private static func fileDecoration(for entry: GitStatusModel.Entry) -> GitStatusModel.FileDecoration {
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
    /// stop / start 失败均忽略。
    nonisolated static func recoverFilesystemMonitor(in root: String) {
        _ = runGit(["fsmonitor--daemon", "stop"], in: root)

        var gitDirectory: String?
        let gitDir = runGit(["rev-parse", "--absolute-git-dir"], in: root)
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
        }

        let config = runGit(["config", "--get", "core.fsmonitor"], in: root)
        let usesBuiltinDaemon = config.status == 0
            && strippingTrailingLineEnding(config.stdout) == "true"
        if usesBuiltinDaemon {
            _ = runGit(["fsmonitor--daemon", "start"], in: root)
        }
    }

    /// Cocoa / POSIX 风格的失效 fd 文案（Process 启动失败或 git 读写坏 socket）。
    nonisolated static func looksLikeStaleFileDescriptor(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("bad file descriptor")
            || lower.contains("ebadf")
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
    nonisolated static func runGit(
        _ args: [String],
        in dir: String,
        config: [String: String] = [:]
    ) -> (status: Int32, stdout: String, stderr: String) {
        var fullArgs: [String] = []
        for (key, value) in config {
            fullArgs.append(contentsOf: ["-c", "\(key)=\(value)"])
        }
        fullArgs.append(contentsOf: args)

        // 启动失败且像 EBADF 时重试一次（换新 pipe /dev/null），避免共享
        // FileHandle.nullDevice 被其它 Process 关闭后整段 Git 面板永久失效。
        let first = launchGit(fullArgs, in: dir)
        if first.launched {
            return first.result
        }
        if looksLikeStaleFileDescriptor(first.result.stderr) {
            let second = launchGit(fullArgs, in: dir)
            return second.result
        }
        return first.result
    }

    /// 实际拉起 git 子进程；`launched == false` 表示 `Process.run()` 抛错。
    private nonisolated static func launchGit(
        _ args: [String], in dir: String
    ) -> (launched: Bool, result: (status: Int32, stdout: String, stderr: String)) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Fail rather than hanging on a credential prompt behind the app.
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Git diagnostics are parsed only to distinguish an ordinary folder
        // from a broken repository. Pinning the locale makes that safe and
        // also keeps relative dates stable in the compact history list.
        env["LC_ALL"] = "C"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // 每次打开独立 /dev/null，避免复用 FileHandle.nullDevice：
        // Process 退出时会 close 传入的 handle，共享 nullDevice 被关掉后
        // 后续 Process.run 会稳定抛出 Bad file descriptor。
        if let devNull = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = devNull
        } else {
            let nullPipe = Pipe()
            try? nullPipe.fileHandleForWriting.close()
            process.standardInput = nullPipe
        }

        do {
            try process.run()
        } catch {
            return (false, (-1, "", error.localizedDescription))
        }
        let outData = PipeData()
        let errData = PipeData()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outData.value = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errData.value = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        return (
            true,
            (
                process.terminationStatus,
                String(data: outData.value, encoding: .utf8) ?? "",
                String(data: errData.value, encoding: .utf8) ?? ""
            )
        )
    }

    private nonisolated final class PipeData: @unchecked Sendable {
        var value = Data()
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

    private nonisolated static func gitFailureMessage(
        _ run: (status: Int32, stdout: String, stderr: String), fallback: String
    ) -> String {
        let message = [run.stderr, run.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return message ?? fallback
    }

    /// Parses NUL-delimited porcelain v2. Unlike Git's default quoted output,
    /// this preserves spaces, quotes, tabs, and newlines in file names.
    nonisolated static func parseStatus(_ output: String) -> StatusResult {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result = StatusResult()
        var index = 0
        while index < records.count {
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
            let clean = record.trimmingCharacters(in: .newlines)
            let fields = clean.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 5 else { return nil }
            return GitStatusModel.RecentCommit(
                hash: String(fields[0]), shortHash: String(fields[1]),
                subject: String(fields[2]), author: String(fields[3]),
                relativeDate: String(fields[4])
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
