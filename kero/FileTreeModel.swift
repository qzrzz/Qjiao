//
//  FileTreeModel.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// Flattened, lazily-expanded view of a directory tree.
///
/// 选择语义对齐 Finder / VS Code Explorer：
/// - 单击选择；⌘ 切换；⇧ 按可见列表范围多选
/// - 双击打开文件 / 展开或折叠目录
///
/// 目录体积不在树刷新时计算（昂贵）；由用户 hover 点 Size 后按需异步统计。
@MainActor
final class FileTreeModel: nonisolated ObservableObject {
    /// 静态状态记录：标记当前是否正在从右侧边栏文件目录树中拖拽文件/文件夹
    static var isDraggingFromTree: Bool = false
    static var activeTreeDragPasteboardChangeCount: Int? = nil
    private static var dragEndMonitorInstalled = false

    /// 全局鼠标抬起时清掉树拖拽标记。只装一次，避免 ContentView.onAppear 重复叠加 monitor。
    static func installDragEndMonitor() {
        guard !dragEndMonitorInstalled else { return }
        dragEndMonitorInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { event in
            assumeMainActor { isDraggingFromTree = false }
            return event
        }
    }

    /// 文件排序依据
    enum FileSortCriteria: String, CaseIterable, Identifiable {
        case name
        case date
        case size

        var id: String { rawValue }
    }

    struct Item: Identifiable, Equatable {
        var id: String { path }
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
        /// 普通文件的字节大小；目录与草稿行不计算，保持列表刷新廉价。
        let fileSize: UInt64?
        /// 修改时间。
        let modificationDate: Date?
        /// True for the transient inline "new file/folder" input row, which
        /// has no backing file yet.
        var isDraft = false
        /// True for the transient "loading directory contents" placeholder row,
        /// shown while a folder's scan runs off the main thread. Not selectable.
        var isLoading = false

        /// 缓存中的目录子项以占位 `depth = 0` 存储，展平时按实际层级复制出新 Item。
        func withDepth(_ depth: Int) -> Item {
            guard depth != self.depth else { return self }
            return Item(
                name: name, path: path, isDirectory: isDirectory,
                depth: depth, fileSize: fileSize, modificationDate: modificationDate,
                isDraft: isDraft, isLoading: isLoading
            )
        }
    }

    /// A pending inline "new file/folder": an input row shown inside
    /// `parentDir` until the user names it (Enter) or cancels (Escape/blur).
    struct Draft: Equatable {
        let parentDir: String
        let isDirectory: Bool
    }

    /// 目录按需统计状态（仅用户触发；不自动扫盘）。
    enum FolderSizeState: Equatable {
        case idle
        case calculating
        case ready(UInt64)
        case failed
    }

    /// 目录内容指纹：用于缓存失效校验。
    /// 只取目录自身的 contentModificationDate——直接子项增删/改名都会更新它；
    /// 已有文件内容/大小变化不改目录 mtime（该缺口由后续文件监听方案覆盖）。
    private struct DirectoryFingerprint: Equatable {
        let contentModificationDate: Date
    }

    /// 单个目录的扫描结果缓存。`fingerprint == nil` 表示目录不存在/不可读：
    /// 稳定显示为空且不重复入队扫描（目录重新出现由父目录重扫驱动，不会漏）。
    private struct DirectoryCacheEntry {
        let items: [Item]
        let fingerprint: DirectoryFingerprint?
    }

    /// 一棵已访问过的树：展开集 + 目录缓存。
    private struct RootSnapshot {
        var expanded: Set<String>
        var cache: [String: DirectoryCacheEntry]
    }

    /// 手动刷新写入的哨兵指纹：与任何真实目录 mtime 都不等，触发后台重扫但保留旧子项。
    private static let forcedStaleFingerprint = DirectoryFingerprint(
        contentModificationDate: .distantPast
    )

    @Published private(set) var rootPath = ""
    @Published private(set) var items: [Item] = []
    /// 当前选中的路径集合（不含草稿行）。
    @Published private(set) var selectedPaths: Set<String> = []
    /// 已触发过的目录体积（path → 状态）；与 `items` 独立缓存。
    @Published private(set) var folderSizeStates: [String: FolderSizeState] = [:]
    /// Path of the row currently being renamed inline, if any.
    @Published private(set) var renamingPath: String?
    /// The pending new-file/folder input row, if any.
    @Published private(set) var draft: Draft?
    /// 排序依据（默认按文件名）。
    @Published private(set) var sortCriteria: FileSortCriteria = {
        if let raw = UserDefaults.standard.string(forKey: "fileTreeSortCriteria"),
           let criteria = FileSortCriteria(rawValue: raw) {
            return criteria
        }
        return .name
    }()
    /// 排序方向（默认升序）。
    @Published private(set) var sortAscending: Bool = {
        if UserDefaults.standard.object(forKey: "fileTreeSortAscending") != nil {
            return UserDefaults.standard.bool(forKey: "fileTreeSortAscending")
        }
        return true
    }()
    private var expanded: Set<String> = []
    /// 按 root 记住展开项与目录缓存；切回已访问过的树时直接恢复。
    private var snapshots: [String: RootSnapshot] = [:]
    /// 最近访问的 root，超出上限时丢掉最旧的快照。
    private var snapshotMRU: [String] = []
    private let maxSnapshots = 8
    /// 各 root 的纵向滚动位置（与快照共用 MRU 淘汰）。
    private var scrollOffsetByRoot: [String: CGFloat] = [:]
    /// 目录内容缓存（path → 已扫描的直接子项，未排序）。
    /// 排序在展平时于主线程进行，因此排序切换无需失效缓存。
    /// 切到未访问过的 root 时清空；切回已访问 root 时从 snapshots 恢复。
    private var directoryCache: [String: DirectoryCacheEntry] = [:]
    /// 正在后台扫描的目录 → 发起时的 scanGeneration。
    /// 完成时只清掉仍属于该 generation 的标记，避免 forceReload 后旧任务打穿新一代去重。
    private var inFlightScans: [String: UInt64] = [:]
    /// root 切换等结构性变化时递增；后台扫描完成回主线程时校验，丢弃过期结果。
    private var scanGeneration: UInt64 = 0
    /// ⇧ 范围选择的锚点：最近一次普通单击或 ⌘ 点击的目标。
    private var selectionAnchorPath: String?
    /// ⇧ 范围选择的游标端点：指示当前移动/扩展方向的目标。
    private var selectionHeadPath: String?
    /// path → 进行中的统计任务，便于取消与去重。
    private var folderSizeTasks: [String: Task<Void, Never>] = [:]
    /// 每次 request 递增；完成后校验，避免已取消任务写回过期结果。
    private var folderSizeGeneration: [String: UInt64] = [:]
    /// 等待开跑的目录（FIFO）；与进行中任务分离，便于限流。
    private var folderSizePending: [String] = []
    /// 同时扫盘的上限，多选时避免几十路 enumerator 抢 IO。
    private let maxConcurrentFolderSizeJobs = 2

    var rootName: String {
        (rootPath as NSString).lastPathComponent
    }

    /// 当前选中且仍在可见列表中的项（按树顺序）。
    var selectedItems: [Item] {
        let set = selectedPaths
        return items.filter { !$0.isDraft && !$0.isLoading && set.contains($0.path) }
    }

    func isExpanded(_ item: Item) -> Bool {
        expanded.contains(item.path)
    }

    func isSelected(_ path: String) -> Bool {
        selectedPaths.contains(path)
    }

    func folderSizeState(for path: String) -> FolderSizeState {
        folderSizeStates[path] ?? .idle
    }

    /// Points the tree at `root` and re-reads visible directories.
    /// Same root just rebuilds. A previously visited root restores expanded
    /// folders and cache; an unseen root starts collapsed.
    func sync(root: String) {
        if root != rootPath {
            storeCurrentSnapshot()
            if let saved = snapshots[root] {
                expanded = saved.expanded
                directoryCache = saved.cache
            } else {
                expanded = []
                directoryCache.removeAll()
            }
            touchMRU(root)

            rootPath = root
            // Any in-progress inline edit belonged to the old tree.
            renamingPath = nil
            draft = nil
            clearSelection()
            clearAllFolderSizes()
            // 旧 root 的在飞扫描结果按 generation 丢弃。
            scanGeneration &+= 1
        }
        rebuild()
    }

    /// 当前 root 的已记滚动位置。
    func scrollOffset(for root: String) -> CGFloat? {
        scrollOffsetByRoot[root]
    }

    /// 记住某棵树的纵向滚动；与快照共用淘汰。
    func rememberScrollOffset(_ offset: CGFloat, for root: String) {
        guard !root.isEmpty else { return }
        scrollOffsetByRoot[root] = offset
        touchMRU(root)
        evictOldSnapshots()
    }

    /// 手动完全刷新：把已缓存目录标成过期并后台重扫。
    /// 不清空缓存、不折叠已展开项——重扫完成前继续展示旧子项，避免滚动条回顶。
    /// 不清 in-flight：旧任务完成时只摘自己的 generation，不会挡新一轮扫描。
    func forceReload() {
        guard !rootPath.isEmpty else { return }
        scanGeneration &+= 1
        for (dir, entry) in directoryCache {
            directoryCache[dir] = DirectoryCacheEntry(
                items: entry.items,
                fingerprint: Self.forcedStaleFingerprint
            )
        }
        rebuild()
    }

    private func storeCurrentSnapshot() {
        guard !rootPath.isEmpty else { return }
        snapshots[rootPath] = RootSnapshot(expanded: expanded, cache: directoryCache)
        touchMRU(rootPath)
        evictOldSnapshots()
    }

    private func touchMRU(_ root: String) {
        guard !root.isEmpty else { return }
        snapshotMRU.removeAll { $0 == root }
        snapshotMRU.append(root)
    }

    private func evictOldSnapshots() {
        while snapshotMRU.count > maxSnapshots {
            let evict = snapshotMRU.removeFirst()
            if evict == rootPath {
                snapshotMRU.append(evict)
                continue
            }
            snapshots.removeValue(forKey: evict)
            scrollOffsetByRoot.removeValue(forKey: evict)
        }
    }

    func toggle(_ item: Item) {
        guard item.isDirectory else { return }
        if !expanded.insert(item.path).inserted {
            expanded.remove(item.path)
        }
        rebuild()
    }

    // MARK: - Sorting

    func setSortCriteria(_ criteria: FileSortCriteria) {
        guard sortCriteria != criteria else { return }
        sortCriteria = criteria
        UserDefaults.standard.set(criteria.rawValue, forKey: "fileTreeSortCriteria")
        rebuild()
    }

    func setSortAscending(_ ascending: Bool) {
        guard sortAscending != ascending else { return }
        sortAscending = ascending
        UserDefaults.standard.set(ascending, forKey: "fileTreeSortAscending")
        rebuild()
    }

    func toggleSortAscending() {
        setSortAscending(!sortAscending)
    }

    // MARK: - Selection

    /// 处理单击：支持普通 / ⌘ / ⇧ 多选。草稿行忽略。
    func selectClick(_ item: Item, modifiers: NSEvent.ModifierFlags, visibleItems: [Item]? = nil) {
        guard !item.isDraft, !item.isLoading else { return }
        if modifiers.contains(.shift) {
            shiftSelect(to: item, visibleItems: visibleItems)
        } else if modifiers.contains(.command) {
            commandToggle(item)
        } else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
            selectionHeadPath = item.path
        }
    }

    /// 右键菜单：若点在已选中项上则保留多选，否则改为单选该项。
    func prepareContextSelection(for item: Item) {
        guard !item.isDraft, !item.isLoading else { return }
        if !selectedPaths.contains(item.path) {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
            selectionHeadPath = item.path
        }
    }

    func clearSelection() {
        selectedPaths = []
        selectionAnchorPath = nil
        selectionHeadPath = nil
    }

    /// 全选当前可见的非草稿行。
    func selectAllVisible(visibleItems: [Item]? = nil) {
        let visible = visibleItems ?? items.filter { !$0.isDraft && !$0.isLoading }
        let paths = visible.map(\.path)
        selectedPaths = Set(paths)
        selectionAnchorPath = paths.first
        selectionHeadPath = paths.last
    }

    private func commandToggle(_ item: Item) {
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
        // ⌘ 点击更新锚点与游标，便于接着 ⇧ 扩展。
        selectionAnchorPath = item.path
        selectionHeadPath = item.path
    }

    /// 从锚点到目标之间、当前可见列表上的连续范围（含两端）。
    func shiftSelect(to item: Item, visibleItems: [Item]? = nil) {
        let visible = visibleItems ?? items.filter { !$0.isDraft && !$0.isLoading }
        guard let endIndex = visible.firstIndex(where: { $0.path == item.path }) else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
            selectionHeadPath = item.path
            return
        }
        let anchor = selectionAnchorPath
            .flatMap { path in visible.firstIndex(where: { $0.path == path }) }
            ?? endIndex
        let lo = min(anchor, endIndex)
        let hi = max(anchor, endIndex)
        selectedPaths = Set(visible[lo...hi].map(\.path))
        // ⇧ 不移动锚点，移动游标（与 Finder / VS Code 一致）。
        if selectionAnchorPath == nil {
            selectionAnchorPath = item.path
        }
        selectionHeadPath = item.path
    }

    /// 方向键方向
    enum ArrowDirection {
        case up
        case down
        case left
        case right
    }

    /// 方向键移动选择及展开/折叠。
    /// - Parameters:
    ///   - direction: 方向（上、下、左、右）
    ///   - shift: 是否按住 Shift 键进行多选扩展
    ///   - visibleItems: 当前可见节点列表（由 Panel 传入，包含 Filter 过滤后的节点）
    /// - Returns: 新选中的目标 Item（供界面平滑滚动），若无变化返回 nil。
    @discardableResult
    func moveSelection(direction: ArrowDirection, shift: Bool, visibleItems: [Item]) -> Item? {
        let visible = visibleItems.filter { !$0.isDraft && !$0.isLoading }
        guard !visible.isEmpty else { return nil }

        switch direction {
        case .down:
            let currentIndex: Int
            if shift {
                if let head = selectionHeadPath, let idx = visible.firstIndex(where: { $0.path == head }) {
                    currentIndex = idx
                } else if let anchor = selectionAnchorPath, let idx = visible.firstIndex(where: { $0.path == anchor }) {
                    currentIndex = idx
                } else if let maxIdx = selectedItemsIn(visible).map({ $0.0 }).max() {
                    currentIndex = maxIdx
                } else {
                    currentIndex = -1
                }
            } else {
                if let head = selectionHeadPath, let idx = visible.firstIndex(where: { $0.path == head }) {
                    currentIndex = idx
                } else if let maxIdx = selectedItemsIn(visible).map({ $0.0 }).max() {
                    currentIndex = maxIdx
                } else {
                    currentIndex = -1
                }
            }

            let targetIndex = min(max(currentIndex + 1, 0), visible.count - 1)
            let targetItem = visible[targetIndex]

            if shift {
                shiftSelect(to: targetItem, visibleItems: visible)
            } else {
                selectedPaths = [targetItem.path]
                selectionAnchorPath = targetItem.path
                selectionHeadPath = targetItem.path
            }
            return targetItem

        case .up:
            let currentIndex: Int
            if shift {
                if let head = selectionHeadPath, let idx = visible.firstIndex(where: { $0.path == head }) {
                    currentIndex = idx
                } else if let anchor = selectionAnchorPath, let idx = visible.firstIndex(where: { $0.path == anchor }) {
                    currentIndex = idx
                } else if let minIdx = selectedItemsIn(visible).map({ $0.0 }).min() {
                    currentIndex = minIdx
                } else {
                    currentIndex = visible.count
                }
            } else {
                if let head = selectionHeadPath, let idx = visible.firstIndex(where: { $0.path == head }) {
                    currentIndex = idx
                } else if let minIdx = selectedItemsIn(visible).map({ $0.0 }).min() {
                    currentIndex = minIdx
                } else {
                    currentIndex = visible.count
                }
            }

            let targetIndex = max(min(currentIndex - 1, visible.count - 1), 0)
            let targetItem = visible[targetIndex]

            if shift {
                shiftSelect(to: targetItem, visibleItems: visible)
            } else {
                selectedPaths = [targetItem.path]
                selectionAnchorPath = targetItem.path
                selectionHeadPath = targetItem.path
            }
            return targetItem

        case .right:
            let currentItem = focusItem(in: visible)
            guard let item = currentItem else { return nil }

            if item.isDirectory {
                if !isExpanded(item) {
                    toggle(item)
                    return item
                } else {
                    // 已展开：导航到第一个子节点
                    if let idx = visible.firstIndex(where: { $0.path == item.path }),
                       idx + 1 < visible.count {
                        let nextItem = visible[idx + 1]
                        if nextItem.path.hasPrefix(item.path + "/") {
                            selectedPaths = [nextItem.path]
                            selectionAnchorPath = nextItem.path
                            selectionHeadPath = nextItem.path
                            return nextItem
                        }
                    }
                }
            }
            return item

        case .left:
            let currentItem = focusItem(in: visible)
            guard let item = currentItem else { return nil }

            if item.isDirectory && isExpanded(item) {
                toggle(item)
                return item
            } else {
                // 文件或已折叠文件夹：导航到其父目录节点
                let parentPath = (item.path as NSString).deletingLastPathComponent
                if let parentItem = visible.first(where: { $0.path == parentPath }) {
                    selectedPaths = [parentItem.path]
                    selectionAnchorPath = parentItem.path
                    selectionHeadPath = parentItem.path
                    return parentItem
                }
            }
            return item
        }
    }

    private func focusItem(in visible: [Item]) -> Item? {
        if let head = selectionHeadPath, let item = visible.first(where: { $0.path == head }) {
            return item
        }
        if let anchor = selectionAnchorPath, let item = visible.first(where: { $0.path == anchor }) {
            return item
        }
        return selectedItemsIn(visible).first?.1 ?? visible.first
    }

    private func selectedItemsIn(_ visible: [Item]) -> [(Int, Item)] {
        var res: [(Int, Item)] = []
        for (index, item) in visible.enumerated() {
            if selectedPaths.contains(item.path) {
                res.append((index, item))
            }
        }
        return res
    }

    /// 重建后剔除已消失路径，避免选中幽灵项。
    private func pruneSelection() {
        let valid = Set(items.lazy.filter { !$0.isDraft }.map(\.path))
        let next = selectedPaths.intersection(valid)
        if next != selectedPaths {
            selectedPaths = next
        }
        if let anchor = selectionAnchorPath, !valid.contains(anchor) {
            selectionAnchorPath = next.sorted().first
        }
        if let head = selectionHeadPath, !valid.contains(head) {
            selectionHeadPath = selectionAnchorPath
        }
    }

    // MARK: - Folder size (on demand)

    /// 批量按需统计（多选 Size / 右键菜单）。已在 calculating 的跳过；
    /// `recalculate == false` 时跳过已有 ready，避免多选误触重扫。
    func requestFolderSizes(for paths: [String], recalculate: Bool = false) {
        // 去重并保持调用顺序，便于队列 FIFO 可预期。
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(paths.count)
        for path in paths where !path.isEmpty {
            if seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        for path in ordered {
            if !recalculate, case .ready = folderSizeStates[path] {
                continue
            }
            requestFolderSize(for: path)
        }
    }

    /// 用户点击 Size：排队后在 utility 优先级后台递归统计该目录逻辑体积。
    /// 已在统计中则忽略；ready 时再次调用会重算（先取消旧任务）。
    func requestFolderSize(for path: String) {
        guard !path.isEmpty else { return }
        // 已在跑或已在队列中：不重复入队。
        if case .calculating = folderSizeStates[path] { return }
        if folderSizePending.contains(path) { return }

        folderSizeTasks[path]?.cancel()
        let generation = (folderSizeGeneration[path] ?? 0) + 1
        folderSizeGeneration[path] = generation
        // 立刻标 calculating，多选时每行都能马上看到进度，而不是等排到才转圈。
        folderSizeStates[path] = .calculating
        folderSizePending.append(path)
        pumpFolderSizeQueue()
    }

    /// 在并发上限内从队列取任务启动。
    private func pumpFolderSizeQueue() {
        while folderSizeTasks.count < maxConcurrentFolderSizeJobs, !folderSizePending.isEmpty {
            let path = folderSizePending.removeFirst()
            // 入队后可能已被 drop/clear 作废（generation 已变且 state 清空）。
            guard case .calculating = folderSizeStates[path] else { continue }
            startFolderSizeJob(path: path, generation: folderSizeGeneration[path] ?? 0)
        }
    }

    private func startFolderSizeJob(path: String, generation: UInt64) {
        // detached：不占用 MainActor；cancel 时 `Task.isCancelled` 可在枚举循环中读到。
        let task = Task.detached(priority: .utility) { [weak self] in
            let measured = FileTreeModel.measureDirectoryByteSize(at: path) {
                Task.isCancelled
            }
            await MainActor.run {
                guard let self else { return }
                // 过期 generation：已被新一次 request / clear 取代。
                guard self.folderSizeGeneration[path] == generation else {
                    self.pumpFolderSizeQueue()
                    return
                }
                self.folderSizeTasks[path] = nil
                // 路径已不在当前 root 下时丢弃（切换项目 / 移走）。
                if !self.rootPath.isEmpty,
                   path != self.rootPath,
                   !path.hasPrefix(self.rootPath + "/")
                {
                    self.folderSizeStates[path] = nil
                    self.pumpFolderSizeQueue()
                    return
                }
                if Task.isCancelled {
                    if case .calculating = self.folderSizeStates[path] {
                        self.folderSizeStates[path] = nil
                    }
                    self.pumpFolderSizeQueue()
                    return
                }
                if let measured {
                    self.folderSizeStates[path] = .ready(measured)
                } else {
                    self.folderSizeStates[path] = .failed
                }
                self.pumpFolderSizeQueue()
            }
        }
        folderSizeTasks[path] = task
    }

    /// 切换项目根时清空缓存并取消所有进行中的统计。
    private func clearAllFolderSizes() {
        for task in folderSizeTasks.values {
            task.cancel()
        }
        folderSizeTasks.removeAll()
        folderSizePending.removeAll()
        folderSizeGeneration.removeAll()
        if !folderSizeStates.isEmpty {
            folderSizeStates = [:]
        }
    }

    /// 删除或移走路径后清掉自身与子孙的体积缓存。
    private func dropFolderSizes(under paths: Set<String>) {
        guard !paths.isEmpty else { return }
        guard !folderSizeStates.isEmpty || !folderSizeTasks.isEmpty || !folderSizePending.isEmpty
        else { return }

        func matches(_ key: String) -> Bool {
            paths.contains { key == $0 || key.hasPrefix($0 + "/") }
        }

        folderSizePending.removeAll { matches($0) }

        let taskKeys = folderSizeTasks.keys.filter(matches)
        for key in taskKeys {
            folderSizeTasks[key]?.cancel()
            folderSizeTasks[key] = nil
            folderSizeGeneration[key] = (folderSizeGeneration[key] ?? 0) + 1
        }
        let stateKeys = folderSizeStates.keys.filter(matches)
        for key in stateKeys {
            folderSizeStates[key] = nil
            folderSizeGeneration[key] = nil
        }
        pumpFolderSizeQueue()
    }

    private func remapFolderSizes(from oldPath: String, to newPath: String) {
        // 进行中的任务目标路径变了，取消后需用户重新点 Size。
        func matches(_ key: String) -> Bool {
            key == oldPath || key.hasPrefix(oldPath + "/")
        }

        folderSizePending = folderSizePending.compactMap { key in
            guard matches(key) else { return key }
            // calculating 队列项丢弃（对应 state 也不会迁移）。
            return nil
        }

        let taskKeys = folderSizeTasks.keys.filter(matches)
        for key in taskKeys {
            folderSizeTasks[key]?.cancel()
            folderSizeTasks[key] = nil
            folderSizeGeneration[key] = (folderSizeGeneration[key] ?? 0) + 1
        }

        var remapped: [String: FolderSizeState] = [:]
        var removeKeys: [String] = []
        for (key, state) in folderSizeStates where matches(key) {
            let next: String
            if key == oldPath {
                next = newPath
            } else {
                next = newPath + String(key.dropFirst(oldPath.count))
            }
            // calculating 不迁移（任务已取消 / 已出队）。
            if case .calculating = state {
                removeKeys.append(key)
                continue
            }
            remapped[next] = state
            removeKeys.append(key)
        }
        for key in removeKeys {
            folderSizeStates[key] = nil
            folderSizeGeneration[key] = nil
        }
        for (key, state) in remapped {
            folderSizeStates[key] = state
        }
        pumpFolderSizeQueue()
    }

    /// 后台深度优先枚举：只累加普通文件 `fileSize`，不跟随符号链接，避免环与跨卷。
    /// `isCancelled` 每处理一批条目查询一次，便于及时停扫大目录。
    nonisolated private static func measureDirectoryByteSize(
        at path: String,
        isCancelled: () -> Bool
    ) -> UInt64? {
        if isCancelled() { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }

        // 预取属性，减少每个条目的额外 stat。
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return nil }

        var total: UInt64 = 0
        var visited = 0
        let resourceKeys = Set(keys)
        while let fileURL = enumerator.nextObject() as? URL {
            visited += 1
            // 约每 512 项检查取消，避免大树长时间占满 utility 队列且无法响应。
            if visited & 0x1FF == 0, isCancelled() {
                return nil
            }
            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                // 符号链接：不计入目标体积，也不进入链接目录（防环 / 重复计）。
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isRegularFile == true {
                    if let size = values.fileSize, size > 0 {
                        total += UInt64(size)
                    }
                }
            } catch {
                // 无权限或瞬时消失：跳过该节点继续，尽量给出可用总量。
                continue
            }
        }
        if isCancelled() { return nil }
        return total
    }

    // MARK: - Trash

    /// Moves `item` to the Trash, then rebuilds so it drops out of the tree.
    func moveToTrash(_ item: Item) {
        moveToTrash(paths: [item.path])
    }

    /// 将多条路径移入废纸篓；部分失败时弹出首个错误。
    func moveToTrash(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        var firstError: (name: String, message: String)?
        var removed: Set<String> = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path), resultingItemURL: nil
                )
                expanded.remove(path)
                // 已展开的子路径前缀一并清理。
                expanded = expanded.filter { !$0.hasPrefix(path + "/") }
                removed.insert(path)
            } catch {
                if firstError == nil {
                    firstError = (name, error.localizedDescription)
                }
            }
        }
        selectedPaths.subtract(paths)
        if let anchor = selectionAnchorPath, paths.contains(anchor) {
            selectionAnchorPath = selectedPaths.sorted().first
        }
        dropFolderSizes(under: removed)
        if let firstError {
            presentError(
                "Couldn’t move “\(firstError.name)” to the Trash.",
                firstError.message
            )
        }
        rebuild()
    }

    // MARK: - Move Items

    /// 将多条文件/目录路径移动到目标目录 `targetDir`。
    /// - Parameters:
    ///   - paths: 待移动的源路径数组
    ///   - targetDir: 目标目录绝对路径
    ///   - overwrite: 若为 true，目标位置已存在同名项时先删除再移动
    ///   - onRename: 文件路径变更回调（用于同步更新打开的主编辑器标签页）
    func moveItems(paths: [String], into targetDir: String, overwrite: Bool = false, onRename: ((_ oldPath: String, _ newPath: String) -> Void)? = nil) {
        let normalizedDestDir = (targetDir as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDestDir, isDirectory: &isDir),
              isDir.boolValue
        else {
            presentError(
                L10n.t("Couldn’t move item."),
                L10n.t("The destination folder is missing or is not a directory.")
            )
            return
        }

        var firstError: String?
        var movedPaths: [(oldPath: String, newPath: String)] = []

        for srcPath in paths {
            let normalizedSource = (srcPath as NSString).standardizingPath
            let itemName = (normalizedSource as NSString).lastPathComponent
            let destPath = (normalizedDestDir as NSString).appendingPathComponent(itemName)

            if normalizedSource == destPath { continue }

            let fm = FileManager.default
            if fm.fileExists(atPath: destPath) {
                if overwrite {
                    // 覆盖模式：先删除目标，再移动
                    do {
                        try fm.removeItem(atPath: destPath)
                    } catch {
                        if firstError == nil {
                            firstError = L10n.format("Couldn’t replace “%@”: %@", itemName, error.localizedDescription)
                        }
                        continue
                    }
                    // 清理已被删除路径的缓存
                    dropFolderSizes(under: [destPath])
                } else {
                    if firstError == nil {
                        firstError = L10n.format("An item named “%@” already exists in this location.", itemName)
                    }
                    continue
                }
            }

            do {
                try fm.moveItem(atPath: normalizedSource, toPath: destPath)
                remapExpanded(from: normalizedSource, to: destPath)
                remapSelection(from: normalizedSource, to: destPath)
                remapFolderSizes(from: normalizedSource, to: destPath)
                movedPaths.append((normalizedSource, destPath))
            } catch {
                if firstError == nil {
                    firstError = L10n.format("Couldn’t move “%@”: %@", itemName, error.localizedDescription)
                }
            }
        }

        if !movedPaths.isEmpty {
            expanded.insert(normalizedDestDir)
            let newSelected = Set(movedPaths.map(\.newPath))
            selectedPaths = newSelected
            selectionAnchorPath = movedPaths.first?.newPath

            for (oldP, newP) in movedPaths {
                onRename?(oldP, newP)
            }
        }

        rebuild()
        FileTreeModel.isDraggingFromTree = false

        if let firstError {
            presentError(L10n.t("Couldn’t move completely."), firstError)
        }
    }

    // MARK: - Copy / Paste

    /// 同名冲突时用户选择：覆盖、使用新文件名、取消后续粘贴。
    private enum PasteConflictChoice {
        case overwrite
        case newName
        case cancel
    }

    /// 剪贴板是否含可粘贴的文件/目录 URL（含从 Finder 复制的项）。
    static var canPasteFromPasteboard: Bool {
        !readFileURLsFromPasteboard().isEmpty
    }

    /// 将选中路径写入系统剪贴板（`fileURL`，与 Finder 互通）。
    func copyToPasteboard(paths: [String]) {
        let unique = orderedUniquePaths(paths)
        guard !unique.isEmpty else { return }
        let urls = unique.map { URL(fileURLWithPath: $0) as NSURL }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
    }

    /// 复制当前选中项；无选中时 no-op。
    func copySelectionToPasteboard() {
        copyToPasteboard(paths: selectedItems.map(\.path))
    }

    /// 解析粘贴目标目录：单选文件夹 → 其内；单选文件 → 父目录；
    /// 多选 → 锚点所在目录（文件夹则其内）；否则项目根。
    func pasteDestinationDirectory() -> String {
        guard !rootPath.isEmpty else { return "" }
        let selected = selectedItems
        if selected.count == 1 {
            let item = selected[0]
            return item.isDirectory
                ? item.path
                : (item.path as NSString).deletingLastPathComponent
        }
        if let anchor = selectionAnchorPath {
            if let item = items.first(where: { $0.path == anchor }) {
                return item.isDirectory
                    ? item.path
                    : (item.path as NSString).deletingLastPathComponent
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: anchor, isDirectory: &isDir) {
                return isDir.boolValue
                    ? anchor
                    : (anchor as NSString).deletingLastPathComponent
            }
        }
        return rootPath
    }

    /// 右键行上的粘贴目标：目录 → 其内；文件 → 父目录。
    func pasteDestinationDirectory(for item: Item) -> String {
        item.isDirectory
            ? item.path
            : (item.path as NSString).deletingLastPathComponent
    }

    /// 从剪贴板粘贴到 `directory`；同名时弹窗选覆盖或新文件名。
    func pasteFromPasteboard(into directory: String) {
        let destDir = directory.isEmpty ? rootPath : directory
        guard !destDir.isEmpty else { return }
        let sources = Self.readFileURLsFromPasteboard()
        guard !sources.isEmpty else { return }

        // 异步拷贝大目录；冲突对话框仍在主线程。
        Task { @MainActor [weak self] in
            await self?.performPaste(sources: sources, into: destDir)
        }
    }

    /// 粘贴到当前推断的目标目录（快捷键 ⌘V）。
    func pasteFromPasteboard() {
        pasteFromPasteboard(into: pasteDestinationDirectory())
    }

    /// 粘贴前已解析好的单条拷贝任务。
    private struct PasteJob {
        let source: String
        let dest: String
        let overwrite: Bool
    }

    private func performPaste(sources: [URL], into destDir: String) async {
        let normalizedDestDir = (destDir as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDestDir, isDirectory: &isDir),
              isDir.boolValue
        else {
            presentError(
                "Couldn’t paste here.",
                "The destination folder is missing or is not a directory."
            )
            return
        }

        // 第一遍：校验并分类，不直接替用户决定同名策略。
        var firstError: String?
        /// 目标已存在且不是「粘贴自身」→ 需用户批量决策。
        var conflictItems: [(source: String, name: String)] = []
        /// 无冲突或粘贴自身（仅能新文件名）→ 可直接规划。
        var directJobs: [PasteJob] = []
        /// 规划新文件名时占用的名字，避免同批多文件撞到同一个 `copy` 名。
        var reservedNames = Set<String>()

        for sourceURL in sources {
            let normalizedSource = (sourceURL.path as NSString).standardizingPath
            let itemName = (normalizedSource as NSString).lastPathComponent

            // 禁止把文件夹粘进自己或其子目录。
            if normalizedDestDir == normalizedSource
                || normalizedDestDir.hasPrefix(normalizedSource + "/")
            {
                if firstError == nil {
                    firstError = "“\(itemName)” can’t be pasted into itself or one of its subfolders."
                }
                continue
            }

            guard FileManager.default.fileExists(atPath: normalizedSource) else {
                if firstError == nil {
                    firstError = "“\(itemName)” no longer exists."
                }
                continue
            }

            let preferredDest = (normalizedDestDir as NSString).appendingPathComponent(itemName)
            let preferredExists = FileManager.default.fileExists(atPath: preferredDest)

            if preferredExists {
                // 目标已有同名（含「粘贴到自身所在目录」）：一律进冲突列表，
                // 由用户整批选择覆盖 / 新文件名，绝不默认加 copy。
                conflictItems.append((normalizedSource, itemName))
            } else {
                reservedNames.insert(itemName)
                directJobs.append(
                    PasteJob(source: normalizedSource, dest: preferredDest, overwrite: false)
                )
            }
        }

        // 有同名冲突：整批只问一次，选项应用于本批全部冲突项。
        var conflictJobs: [PasteJob] = []
        if !conflictItems.isEmpty {
            let conflictNames = conflictItems.map(\.name)
            switch presentPasteConflictBatch(conflictNames: conflictNames) {
            case .cancel:
                // 用户取消：整批不粘贴（含无冲突项），避免半批结果难预期。
                return
            case .overwrite:
                for item in conflictItems {
                    let dest = (normalizedDestDir as NSString).appendingPathComponent(item.name)
                    // 源与目标是同一路径时覆盖会先删后拷导致丢文件，直接跳过（已在目标位置）。
                    if (dest as NSString).standardizingPath
                        == (item.source as NSString).standardizingPath
                    {
                        continue
                    }
                    conflictJobs.append(
                        PasteJob(source: item.source, dest: dest, overwrite: true)
                    )
                }
            case .newName:
                for item in conflictItems {
                    let newName = Self.uniqueCopyName(
                        for: item.name, in: normalizedDestDir, reserved: &reservedNames
                    )
                    conflictJobs.append(
                        PasteJob(
                            source: item.source,
                            dest: (normalizedDestDir as NSString).appendingPathComponent(newName),
                            overwrite: false
                        )
                    )
                }
            }
        }

        let jobs = directJobs + conflictJobs
        guard !jobs.isEmpty else {
            if let firstError {
                presentError("Couldn’t paste.", firstError)
            }
            return
        }

        var createdPaths: [String] = []
        for job in jobs {
            let copyError: String? = await Task.detached(priority: .userInitiated) {
                Self.copyItem(from: job.source, to: job.dest, overwrite: job.overwrite)
            }.value

            if let copyError {
                if firstError == nil {
                    firstError = copyError
                }
            } else {
                createdPaths.append(job.dest)
                if job.overwrite {
                    dropFolderSizes(under: [job.dest])
                }
            }
        }

        finishPaste(createdPaths: createdPaths, destDir: normalizedDestDir, firstError: firstError)
    }

    private func finishPaste(createdPaths: [String], destDir: String, firstError: String?) {
        if !createdPaths.isEmpty {
            expanded.insert(destDir)
            selectedPaths = Set(createdPaths)
            selectionAnchorPath = createdPaths.first
        }
        rebuild()
        if let firstError {
            presentError("Couldn’t paste completely.", firstError)
        }
    }

    /// 同名冲突整批询问一次：覆盖 / 新文件名 / 取消（取消则本批全部不粘贴）。
    private func presentPasteConflictBatch(conflictNames: [String]) -> PasteConflictChoice {
        let alert = NSAlert()
        let count = conflictNames.count
        if count == 1 {
            alert.messageText = L10n.format(
                "An item named “%@” already exists in this location.",
                conflictNames[0]
            )
            alert.informativeText = L10n.t(
                "Choose Overwrite or New Name for this paste. The choice applies to all name conflicts in this batch."
            )
        } else {
            alert.messageText = L10n.format("%d items already exist in this location.", count)
            let preview = conflictNames.prefix(8).joined(separator: "\n")
            let more = count > 8 ? "\n…" : ""
            alert.informativeText =
                "\(preview)\(more)\n\n"
                + L10n.format(
                    "Choose one action for all %d conflicting items in this paste.",
                    count
                )
        }
        alert.alertStyle = .warning
        // 默认偏安全：新文件名；其次覆盖；取消整批。
        alert.addButton(withTitle: L10n.t("New Name"))
        alert.addButton(withTitle: L10n.t("Overwrite"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .newName
        case .alertSecondButtonReturn:
            return .overwrite
        default:
            return .cancel
        }
    }

    /// Finder 风格副本名：`a.txt` → `a copy.txt` → `a copy 2.txt` …
    /// `reserved`：同批已占用的文件名，避免多个冲突项生成同一个 `copy` 名。
    nonisolated private static func uniqueCopyName(
        for originalName: String,
        in directory: String,
        reserved: inout Set<String>
    ) -> String {
        let ns = originalName as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let stemBase = ext.isEmpty ? originalName : base
        let fm = FileManager.default

        func makeName(copyIndex: Int) -> String {
            let stem: String
            if copyIndex <= 1 {
                stem = "\(stemBase) copy"
            } else {
                stem = "\(stemBase) copy \(copyIndex)"
            }
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }

        var index = 1
        while index < 10_000 {
            let candidate = makeName(copyIndex: index)
            let path = (directory as NSString).appendingPathComponent(candidate)
            if !reserved.contains(candidate), !fm.fileExists(atPath: path) {
                reserved.insert(candidate)
                return candidate
            }
            index += 1
        }
        // 极端情况下退回 UUID，保证可粘贴。
        let fallback = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        reserved.insert(fallback)
        return fallback
    }

    /// 后台拷贝；`overwrite` 时先删目标再复制。返回错误文案，成功为 nil。
    nonisolated private static func copyItem(from source: String, to dest: String, overwrite: Bool) -> String? {
        let fm = FileManager.default
        let name = (source as NSString).lastPathComponent
        do {
            if overwrite, fm.fileExists(atPath: dest) {
                try fm.removeItem(atPath: dest)
            }
            try fm.copyItem(atPath: source, toPath: dest)
            return nil
        } catch {
            return "“\(name)”: \(error.localizedDescription)"
        }
    }

    nonisolated private static func readFileURLsFromPasteboard() -> [URL] {
        let pb = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let objects = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else { return [] }
        // 去重并标准化路径。
        var seen = Set<String>()
        var result: [URL] = []
        for url in objects {
            let path = (url.path as NSString).standardizingPath
            if seen.insert(path).inserted {
                result.append(URL(fileURLWithPath: path))
            }
        }
        return result
    }

    private func orderedUniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where !path.isEmpty {
            let normalized = (path as NSString).standardizingPath
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    // MARK: - Rename

    func beginRename(_ item: Item) {
        // 重命名仅针对单行，顺带收敛选择。
        selectedPaths = [item.path]
        selectionAnchorPath = item.path
        renamingPath = item.path
    }

    func cancelRename() {
        renamingPath = nil
    }

    /// Renames `item` in place. No-ops on an empty or unchanged name; shows an
    /// alert if the name collides or the filesystem move fails. Returns the new
    /// absolute path when the file actually moved, so callers can follow it
    /// (e.g. re-point open tabs).
    @discardableResult
    func rename(_ item: Item, to newName: String) -> String? {
        renamingPath = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError("Couldn’t rename to “\(trimmed)”.", "A name can’t contain “/” or be “.” or “..”.")
            return nil
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        // A case-only rename ("foo"→"Foo") maps to the same file on a
        // case-insensitive volume, so don't treat that as a collision.
        let caseOnlyChange = trimmed.lowercased() == item.name.lowercased()
        guard caseOnlyChange || !fm.fileExists(atPath: dest) else {
            presentError("Couldn’t rename to “\(trimmed)”.", "An item named “\(trimmed)” already exists here.")
            return nil
        }
        do {
            try fm.moveItem(atPath: item.path, toPath: dest)
            remapExpanded(from: item.path, to: dest)
            remapSelection(from: item.path, to: dest)
            remapFolderSizes(from: item.path, to: dest)
        } catch {
            presentError("Couldn’t rename to “\(trimmed)”.", error.localizedDescription)
            return nil
        }
        rebuild()
        return dest
    }

    /// Keeps expansion state after a directory rename by rewriting the old
    /// path prefix (for the folder itself and any expanded descendants).
    private func remapExpanded(from oldPath: String, to newPath: String) {
        guard expanded.contains(where: { $0 == oldPath || $0.hasPrefix(oldPath + "/") })
        else { return }
        expanded = Set(expanded.map { path in
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") {
                return newPath + String(path.dropFirst(oldPath.count))
            }
            return path
        })
    }

    private func remapSelection(from oldPath: String, to newPath: String) {
        if selectedPaths.remove(oldPath) != nil {
            selectedPaths.insert(newPath)
        }
        // 子路径选择在目录改名后也要跟着走。
        let nested = selectedPaths.filter { $0.hasPrefix(oldPath + "/") }
        for path in nested {
            selectedPaths.remove(path)
            selectedPaths.insert(newPath + String(path.dropFirst(oldPath.count)))
        }
        if selectionAnchorPath == oldPath {
            selectionAnchorPath = newPath
        } else if let anchor = selectionAnchorPath, anchor.hasPrefix(oldPath + "/") {
            selectionAnchorPath = newPath + String(anchor.dropFirst(oldPath.count))
        }
    }

    // MARK: - Create (inline draft)

    /// Opens an inline input row for a new file inside `directory`.
    func beginNewFile(in directory: String) {
        startDraft(in: directory, isDirectory: false)
    }

    /// Opens an inline input row for a new folder inside `directory`.
    func beginNewFolder(in directory: String) {
        startDraft(in: directory, isDirectory: true)
    }

    private func startDraft(in directory: String, isDirectory: Bool) {
        renamingPath = nil
        draft = Draft(parentDir: directory, isDirectory: isDirectory)
        // Reveal the folder's contents so the input row is visible.
        expanded.insert(directory)
        rebuild()
    }

    func cancelDraft() {
        guard draft != nil else { return }
        draft = nil
        rebuild()
    }

    /// Commits the pending draft, creating the file or folder. An empty name
    /// cancels (matching VS Code). Returns the new file's path — for files
    /// only — so the caller can open it.
    @discardableResult
    func commitDraft(name: String) -> String? {
        guard let draft else { return nil }
        self.draft = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { rebuild(); return nil }
        let noun = draft.isDirectory ? "folder" : "file"
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError("Couldn’t create “\(trimmed)”.", "A name can’t contain “/” or be “.” or “..”.")
            rebuild()
            return nil
        }
        let dest = (draft.parentDir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest) else {
            presentError("Couldn’t create “\(trimmed)”.", "An item named “\(trimmed)” already exists here.")
            rebuild()
            return nil
        }
        var createdFile: String?
        if draft.isDirectory {
            do {
                try fm.createDirectory(atPath: dest, withIntermediateDirectories: false)
            } catch {
                presentError("Couldn’t create the \(noun).", error.localizedDescription)
            }
        } else if fm.createFile(atPath: dest, contents: nil) {
            createdFile = dest
        } else {
            presentError("Couldn’t create the \(noun).", "It could not be written to disk.")
        }
        if let createdFile {
            selectedPaths = [createdFile]
            selectionAnchorPath = createdFile
        } else if fm.fileExists(atPath: dest) {
            selectedPaths = [dest]
            selectionAnchorPath = dest
        }
        rebuild()
        return createdFile
    }

    private func presentError(_ messageText: String, _ informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func rebuild() {
        guard !rootPath.isEmpty else { return }
        var out: [Item] = []
        var stale: [String] = []
        appendCachedChildren(of: rootPath, depth: 0, into: &out, stale: &stale)
        if !stale.isEmpty {
            scheduleScan(of: stale)
        }
        if out != items {
            items = out
        }
        pruneSelection()
    }

    /// 展平已展开目录树：全部来自 `directoryCache`（内存），不做任何磁盘 I/O。
    /// 缓存缺失的目录收集进 `stale`，由 `scheduleScan` 在后台补扫，并显示 loading。
    /// 指纹过期时同样入队重扫，但继续展示旧子项，避免刷新折叠树、滚动条回顶。
    private func appendCachedChildren(of dir: String, depth: Int, into out: inout [Item], stale: inout [String]) {
        // Guard against runaway recursion through symlink cycles.
        guard depth < 32 else { return }
        // Show the inline new-file/folder input at the top of its folder.
        if let draft, draft.parentDir == dir {
            out.append(
                Item(
                    name: "", path: dir + "/\u{1}draft",
                    isDirectory: draft.isDirectory, depth: depth,
                    fileSize: nil, modificationDate: nil, isDraft: true
                )
            )
        }
        let needsPlaceholder = dir == rootPath || expanded.contains(dir)
        guard let entry = directoryCache[dir] else {
            if needsPlaceholder {
                out.append(loadingItem(in: dir, depth: depth))
            }
            stale.append(dir)
            return
        }
        // 指纹有效则校验：目录内容变化（直接子项增删/改名）时后台重扫。
        // 重扫完成前继续展示旧子项，避免刷新时折叠树、丢失滚动位置。
        // fingerprint == nil 的目录（不存在/不可读）稳定显示为空，不重复入队。
        if let cachedFingerprint = entry.fingerprint,
           fingerprint(of: dir) != cachedFingerprint {
            stale.append(dir)
        }
        // 排序在主线程展平时进行：size 排序需要 folderSizeStates，且排序切换
        // 无需失效缓存。
        let children = entry.items.sorted { compareItems($0, $1) }
        for child in children {
            out.append(child.withDepth(depth))
            if child.isDirectory, expanded.contains(child.path) {
                appendCachedChildren(of: child.path, depth: depth + 1, into: &out, stale: &stale)
            }
        }
    }

    /// 目录内容扫描中的 loading 占位行（不参与选择/右键/拖拽，由视图按 isLoading 分支渲染）。
    private func loadingItem(in dir: String, depth: Int) -> Item {
        Item(
            name: "", path: dir + "/\u{1}loading", isDirectory: true,
            depth: depth, fileSize: nil, modificationDate: nil, isLoading: true
        )
    }

    /// 把失效目录的扫描任务批量调度到后台（utility 优先级）。全部完成后回主线程
    /// 写缓存并再次 `rebuild()`（此时应全部命中，除非扫描期间目录又变化）。
    /// 同一目录同时只允许一个在飞任务，避免并发读盘。
    private func scheduleScan(of dirs: [String]) {
        let generation = scanGeneration
        let toScan = dirs.filter { inFlightScans[$0] != generation }
        guard !toScan.isEmpty else { return }
        for dir in toScan {
            inFlightScans[dir] = generation
        }
        Task.detached(priority: .utility) { [weak self] in
            var results: [String: DirectoryCacheEntry] = [:]
            results.reserveCapacity(toScan.count)
            for dir in toScan {
                results[dir] = Self.scanDirectoryContents(at: dir)
            }
            await MainActor.run {
                guard let self else { return }
                for dir in toScan {
                    if self.inFlightScans[dir] == generation {
                        self.inFlightScans.removeValue(forKey: dir)
                    }
                }
                guard self.scanGeneration == generation else { return }
                for (dir, result) in results {
                    self.directoryCache[dir] = result
                }
                self.rebuild()
            }
        }
    }

    /// 主线程校验目录指纹：对每个已展开目录做一次轻量 stat（比全量重扫便宜几个数量级）。
    private func fingerprint(of dir: String) -> DirectoryFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dir),
              let mtime = attrs[FileAttributeKey.modificationDate] as? Date
        else { return nil }
        return DirectoryFingerprint(contentModificationDate: mtime)
    }

    /// 后台扫描单个目录：一次 readdir（预取属性）批量取元数据，替代旧的
    /// 「每文件 fileExists + attributesOfItem 两次 stat」。纯函数，不碰主线程状态。
    /// 目录不存在/不可读时返回指纹为 nil 的条目，避免反复入队扫描造成死循环。
    nonisolated private static func scanDirectoryContents(at dir: String) -> DirectoryCacheEntry {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: dir),
              let mtime = attrs[FileAttributeKey.modificationDate] as? Date
        else {
            return DirectoryCacheEntry(items: [], fingerprint: nil)
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .isSymbolicLinkKey,
        ]
        guard let urls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        else {
            return DirectoryCacheEntry(items: [], fingerprint: nil)
        }
        let keySet = Set(keys)
        var items: [Item] = []
        items.reserveCapacity(urls.count)
        for child in urls {
            let name = child.lastPathComponent
            guard name != ".git" else { continue }
            guard let values = try? child.resourceValues(forKeys: keySet) else { continue }
            // 路径必须用字符串拼接而非 child.path：contentsOfDirectory 返回的
            // URL.path 是 realpath 后的形式（如 /var → /private/var），而 rootPath
            // 与旧代码的 appendingPathComponent 都是字符串拼接，混用会导致
            // expanded / hasPrefix 等路径匹配全部失效。属性值仍从 URL 批量取。
            let path = (dir as NSString).appendingPathComponent(name)
            // 符号链接按目标类型显示（与旧的 fileExists 语义一致）；
            // 仅 symlink 需要多一次 stat，普通文件/目录保持一次 resourceValues。
            let isSymlink = values.isSymbolicLink == true
            let isDirectory: Bool
            if isSymlink {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                isDirectory = isDir.boolValue
            } else {
                isDirectory = values.isDirectory == true
            }
            // values.fileSize 为 Int?，Item.fileSize 为 UInt64?：显式转换避免编译器歧义。
            let fileSize: UInt64? = isDirectory ? nil : values.fileSize.map(UInt64.init)
            items.append(
                Item(
                    name: name, path: path, isDirectory: isDirectory,
                    depth: 0, // 占位深度，展平时由 withDepth 重设
                    fileSize: fileSize,
                    modificationDate: values.contentModificationDate
                )
            )
        }
        return DirectoryCacheEntry(
            items: items,
            fingerprint: DirectoryFingerprint(contentModificationDate: mtime)
        )
    }

    /// 比较两个树项排序顺序（同级节点）。
    private func compareItems(_ a: Item, _ b: Item) -> Bool {
        // 1. 目录优先保持在最前
        if a.isDirectory != b.isDirectory {
            return a.isDirectory
        }

        // 2. 根据 sortCriteria 比较
        let isAsc = sortAscending
        switch sortCriteria {
        case .name:
            let cmp = a.name.localizedStandardCompare(b.name)
            if cmp != .orderedSame {
                return isAsc ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            }

        case .date:
            let aDate = a.modificationDate ?? Date.distantPast
            let bDate = b.modificationDate ?? Date.distantPast
            if aDate != bDate {
                return isAsc ? (aDate < bDate) : (aDate > bDate)
            }

        case .size:
            let aSize = itemEffectiveSize(a)
            let bSize = itemEffectiveSize(b)
            if aSize != bSize {
                return isAsc ? (aSize < bSize) : (aSize > bSize)
            }
        }

        // 3. 次要排序：若主属性相同，退回按文件名升序排列（确保稳定排序）
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// 获取 Item 用于排序的有效大小：普通文件为 fileSize，目录若已就绪为 ready size，否则为 0。
    private func itemEffectiveSize(_ item: Item) -> UInt64 {
        if item.isDirectory {
            if case .ready(let size) = folderSizeState(for: item.path) {
                return size
            }
            return 0
        }
        return item.fileSize ?? 0
    }
}
