//
//  GitFileWatcher.swift
//  kero
//
//  Git 面板事件驱动的文件变化监听（替代高频定时轮询）：
//  - .git 元数据：DispatchSource 监听 index / HEAD / refs / packed-refs，
//    覆盖 stage / commit / checkout / branch 等 git 操作（含终端内手动 git）；
//  - 工作区递归变化：FSEventStream（FileEvents + latency 聚合），覆盖外部
//    编辑器与终端对工作区文件的增删改，让 `git status` 由事件触发而不是空转轮询。
//
//  事件统一防抖合并后回调 onChange（主线程）。GitStatusModel 仍保留低频
//  兜底心跳，防止 watcher 漏事件（网络盘 / 外部进程替换文件等）导致状态长期陈旧。
//
//  已知盲区（靠心跳兜底）：worktree 的 `gitdir` 文件、`sequencer/`、
//  `COMMIT_EDITMSG` 等未单独监听；DispatchSource 在路径短暂消失时 open 失败
//  会在下次防抖重建时重试。
//

import CoreServices
import Darwin
import Foundation

/// 监听 Git 仓库的元数据与工作区变化。所有方法在主线程调用；
/// 回调统一在主线程派发（与 SidebarProjectFileWatcher 相同的并发模式）。
@MainActor
final class GitFileWatcher {
    /// 防抖窗口：合并同一次保存 / git 操作触发的多路事件（目录 + 文件 + FSEvents）。
    private static let debounceInterval: TimeInterval = 0.5
    /// FSEvents latency：洪峰聚合窗口（秒）。
    private static let eventLatency: TimeInterval = 1.0

    /// 文件变化回调（主线程派发）。参数 `affectsHistory`：HEAD / refs /
    /// packed-refs 等提交历史相关元数据变化为 true（需带详情重扫，刷新
    /// 提交历史 / 分支 / stash）；工作区文件与 index 变化为 false（快路径
    /// 刷新变更列表即可）。防抖窗口内任一事件要求详情则最终回调 true。
    var onChange: ((_ affectsHistory: Bool) -> Void)?
    private var repositoryRoot = ""
    private var gitDirectory = ""
    private var sources: [DispatchSourceFileSystemObject] = []
    private var eventStream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    /// 防抖窗口内是否收到过需要 reopen vnode 的事件（.rename / .delete）。
    private var pendingRebuildDispatchSources = false
    /// 防抖窗口内是否收到过提交历史相关元数据事件（HEAD / refs / packed-refs）。
    private var pendingAffectsHistory = false

    init() {}

    deinit {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
        sources.forEach { $0.cancel() }
    }

    /**
     开始监听仓库。gitDirectory 为空时仅监听工作区（非仓库目录场景：
     终端内 `git init` 后可立即被 FSEvents 捕获，无需等心跳轮询）。
     路径未变化时保留现有监听器。
     */
    func watch(repositoryRoot: String, gitDirectory: String?) {
        guard !repositoryRoot.isEmpty else {
            stop()
            return
        }
        let gitDir = gitDirectory ?? ""
        let hasWatchers = !sources.isEmpty || eventStream != nil
        guard repositoryRoot != self.repositoryRoot || gitDir != self.gitDirectory || !hasWatchers else {
            return
        }
        stop()
        self.repositoryRoot = repositoryRoot
        self.gitDirectory = gitDir
        rebuildSources()
    }

    /** 停止所有监听。 */
    func stop() {
        repositoryRoot = ""
        gitDirectory = ""
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingRebuildDispatchSources = false
        pendingAffectsHistory = false
        stopSources()
        stopEventStream()
    }

    // MARK: - 监听装配

    private func rebuildSources() {
        rebuildDispatchSources()
        startWorkingTreeStream()
    }

    /// 重建 `.git` 元数据 vnode 监听。`index` / `HEAD` 等常为 lockfile + rename
    /// 原子替换，旧 inode 的 DispatchSource 在 `.rename`/`.delete` 后失效，
    /// 必须 reopen 路径才能继续收到后续 git 元数据事件。
    private func rebuildDispatchSources() {
        stopSources()
        guard !gitDirectory.isEmpty else { return }
        // 注意：**不**监听 .git 目录本身——fsmonitor daemon 每次 `git status`
        // 都会写 `.git/fsmonitor--daemon/` cookie 文件，目录级 vnode 事件会
        // 捕获这些写入，导致「扫描 → 事件 → 再扫描」的无限自触发循环。
        // index / HEAD 文件监听覆盖 git add / commit / checkout；
        // refs 目录覆盖分支创建 / 删除；packed-refs 覆盖打包引用更新。
        // index 变化（git add / stage）不影响提交历史 → affectsHistory = false；
        // HEAD / refs / packed-refs（commit / amend / checkout / branch）→ true。
        watchPath((gitDirectory as NSString).appendingPathComponent("index"), affectsHistory: false)
        watchPath((gitDirectory as NSString).appendingPathComponent("HEAD"), affectsHistory: true)
        watchPath((gitDirectory as NSString).appendingPathComponent("refs"), affectsHistory: true)
        watchPath((gitDirectory as NSString).appendingPathComponent("packed-refs"), affectsHistory: true)
    }

    /// DispatchSource 监听单个文件 / 目录（vnode 事件）。
    private func watchPath(_ path: String, affectsHistory: Bool) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // 注意：**不**监听 `.attrib` / `.revoke`——git status 每次打开 index
            // 读取（fsmonitor stat 缓存检查）都会更新 atime 触发 NOTE_ATTRIB，
            // 会导致「扫描 → attrib 事件 → 再扫描」无限自触发循环。
            // 内容写入（git add / commit）由 .write / .extend 覆盖，
            // 原子替换（HEAD 切换）由 .rename / .delete 覆盖。
            eventMask: [.write, .delete, .rename, .extend, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // index/HEAD 原子替换会发 .rename / .delete 并换 inode，需 reopen；
            // 普通 .write/.extend 仍挂在同一 vnode 上，不必每次重建。
            let events = source.data
            let rebuild = events.contains(.delete) || events.contains(.rename)
            self.scheduleChange(
                rebuildDispatchSources: rebuild,
                affectsHistory: affectsHistory
            )
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sources.append(source)
        source.resume()
    }

    /// FSEventStream 递归监听整个工作区（FileEvents 提供文件级事件，
    /// latency 聚合洪峰，避免大仓库事件风暴逐条派发）。
    private func startWorkingTreeStream() {
        stopEventStream()
        guard !repositoryRoot.isEmpty else { return }

        let paths = [repositoryRoot] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<GitFileWatcher>.fromOpaque(info).takeUnretainedValue()
                // 注意：macOS 27 SDK 的 FSEventStreamCallback 参数顺序为
                // (streamRef, info, numEvents, eventPaths, eventFlags, eventIds)。
                let cfArray = Unmanaged<CFArray>
                    .fromOpaque(eventPaths)
                    .takeUnretainedValue()
                let paths = cfArray as? [String] ?? []
                // 回调在 main queue（FSEventStreamSetDispatchQueue），可 assumeIsolated。
                MainActor.assumeIsolated {
                    // 已有仓库：过滤 .git 下全部事件（fsmonitor cookie 会自触发循环），
                    // 元数据由 DispatchSource 负责。
                    // 非仓库（gitDirectory 空）：保留 `.git` 出现事件，使 `git init` 可即时发现。
                    let filterGit = !watcher.gitDirectory.isEmpty
                    let hasRelevantChange = paths.contains { path in
                        if filterGit {
                            return !path.contains("/.git/") && !path.hasSuffix("/.git")
                        }
                        return true
                    }
                    guard hasRelevantChange else { return }
                    // FSEventStream 按路径监听、不依赖 inode，无需重建 DispatchSource。
                    // 工作区文件变化不涉及提交历史 → affectsHistory = false（快路径）。
                    watcher.scheduleChange(
                        rebuildDispatchSources: false,
                        affectsHistory: false
                    )
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.eventLatency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else { return }
        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    // MARK: - 事件合并

    /// 合并式防抖：持续变化会推迟回调，但 GitStatusModel 的兜底心跳保证最终一致。
    /// - Parameter rebuildDispatchSources: index/HEAD 原子 rename 后需 reopen vnode；
    ///   对齐 SidebarProjectFileWatcher。普通写入与 FSEvents 不必重建。
    /// - Parameter affectsHistory: HEAD / refs / packed-refs 变化（commit / checkout
    ///   / branch 等）为 true；防抖窗口内任一事件为 true 则最终回调 true。
    private func scheduleChange(rebuildDispatchSources: Bool, affectsHistory: Bool) {
        // 防抖窗口内任一事件要求重建，则最终回调时重建一次即可。
        if rebuildDispatchSources {
            pendingRebuildDispatchSources = true
        }
        if affectsHistory {
            pendingAffectsHistory = true
        }
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.repositoryRoot.isEmpty else { return }
            if self.pendingRebuildDispatchSources {
                self.pendingRebuildDispatchSources = false
                self.rebuildDispatchSources()
            }
            let history = self.pendingAffectsHistory
            self.pendingAffectsHistory = false
            self.onChange?(history)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: workItem
        )
    }

    private func stopSources() {
        let currentSources = sources
        sources = []
        currentSources.forEach { $0.cancel() }
    }

    private func stopEventStream() {
        guard let eventStream else { return }
        FSEventStreamStop(eventStream)
        FSEventStreamInvalidate(eventStream)
        FSEventStreamRelease(eventStream)
        self.eventStream = nil
    }
}
