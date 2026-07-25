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
    struct Item: Identifiable, Equatable {
        var id: String { path }
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
        /// 普通文件的字节大小；目录与草稿行不计算，保持列表刷新廉价。
        let fileSize: UInt64?
        /// True for the transient inline "new file/folder" input row, which
        /// has no backing file yet.
        var isDraft = false
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
    private var expanded: Set<String> = []
    /// ⇧ 范围选择的锚点：最近一次普通单击或 ⌘ 点击的目标。
    private var selectionAnchorPath: String?
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
        return items.filter { !$0.isDraft && set.contains($0.path) }
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

    /// Points the tree at `root` (collapsing everything if it moved) and
    /// re-reads visible directories. Cheap when nothing changed.
    func sync(root: String) {
        if root != rootPath {
            rootPath = root
            expanded = []
            // Any in-progress inline edit belonged to the old tree.
            renamingPath = nil
            draft = nil
            clearSelection()
            clearAllFolderSizes()
        }
        rebuild()
    }

    func toggle(_ item: Item) {
        guard item.isDirectory else { return }
        if !expanded.insert(item.path).inserted {
            expanded.remove(item.path)
        }
        rebuild()
    }

    // MARK: - Selection

    /// 处理单击：支持普通 / ⌘ / ⇧ 多选。草稿行忽略。
    func selectClick(_ item: Item, modifiers: NSEvent.ModifierFlags) {
        guard !item.isDraft else { return }
        if modifiers.contains(.shift) {
            shiftSelect(to: item)
        } else if modifiers.contains(.command) {
            commandToggle(item)
        } else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
        }
    }

    /// 右键菜单：若点在已选中项上则保留多选，否则改为单选该项。
    func prepareContextSelection(for item: Item) {
        guard !item.isDraft else { return }
        if !selectedPaths.contains(item.path) {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
        }
    }

    func clearSelection() {
        selectedPaths = []
        selectionAnchorPath = nil
    }

    /// 全选当前可见的非草稿行。
    func selectAllVisible() {
        let paths = items.filter { !$0.isDraft }.map(\.path)
        selectedPaths = Set(paths)
        selectionAnchorPath = paths.first
    }

    private func commandToggle(_ item: Item) {
        if selectedPaths.contains(item.path) {
            selectedPaths.remove(item.path)
        } else {
            selectedPaths.insert(item.path)
        }
        // ⌘ 点击更新锚点，便于接着 ⇧ 扩展。
        selectionAnchorPath = item.path
    }

    /// 从锚点到目标之间、当前可见列表上的连续范围（含两端）。
    private func shiftSelect(to item: Item) {
        let visible = items.filter { !$0.isDraft }
        guard let endIndex = visible.firstIndex(where: { $0.path == item.path }) else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
            return
        }
        let anchor = selectionAnchorPath
            .flatMap { path in visible.firstIndex(where: { $0.path == path }) }
            ?? endIndex
        let lo = min(anchor, endIndex)
        let hi = max(anchor, endIndex)
        selectedPaths = Set(visible[lo...hi].map(\.path))
        // ⇧ 不移动锚点（与 Finder / VS Code 一致）。
        if selectionAnchorPath == nil {
            selectionAnchorPath = item.path
        }
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
        appendChildren(of: rootPath, depth: 0, into: &out)
        if out != items {
            items = out
        }
        pruneSelection()
    }

    private func appendChildren(of dir: String, depth: Int, into out: inout [Item]) {
        // Guard against runaway recursion through symlink cycles.
        guard depth < 32 else { return }
        // Show the inline new-file/folder input at the top of its folder.
        if let draft, draft.parentDir == dir {
            out.append(
                Item(
                    name: "", path: dir + "/\u{1}draft",
                    isDirectory: draft.isDirectory, depth: depth,
                    fileSize: nil, isDraft: true
                )
            )
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }

        let children = names
            .filter { $0 != ".git" }
            .map { name -> Item in
                let path = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                let isDirectory = isDir.boolValue
                // 仅读文件属性；目录体积需递归，不在树刷新路径上计算。
                let fileSize: UInt64? = {
                    guard !isDirectory else { return nil }
                    let attrs = try? fm.attributesOfItem(atPath: path)
                    return (attrs?[.size] as? NSNumber)?.uint64Value
                }()
                return Item(
                    name: name, path: path, isDirectory: isDirectory,
                    depth: depth, fileSize: fileSize
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        for child in children {
            out.append(child)
            if child.isDirectory, expanded.contains(child.path) {
                appendChildren(of: child.path, depth: depth + 1, into: &out)
            }
        }
    }
}
