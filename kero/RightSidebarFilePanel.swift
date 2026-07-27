//
//  RightSidebarFilePanel.swift
//  kero
//

import AppKit
import QuickLook
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Quick Look Manager

/// 系统原生 Quick Look (快速预览) 管理类，支持 QLPreviewPanel 弹窗与数据源绑定。
@MainActor
private final class QuickLookManager: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookManager()
    private var currentURLs: [URL] = []

    /// 打开或更新当前 Quick Look 预览文件集合。
    func preview(urls: [URL]) {
        guard !urls.isEmpty else {
            close()
            return
        }
        self.currentURLs = urls
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            if !panel.isVisible {
                panel.makeKeyAndOrderFront(nil)
            }
        } else if let panel = QLPreviewPanel.shared() {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// 切换预览窗口开/关：已打开时关闭，未打开时开窗预览。
    func togglePreview(urls: [URL]) {
        if isVisible {
            close()
        } else {
            preview(urls: urls)
        }
    }

    /// 关闭 Quick Look 预览窗口。
    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        currentURLs = []
    }

    /// 当前 Quick Look 窗口是否可见。
    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    // MARK: - QLPreviewPanelDataSource

    @objc nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            currentURLs.count
        }
    }

    @objc nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard index >= 0 && index < currentURLs.count else { return nil }
            return currentURLs[index] as NSURL
        }
    }
}

// MARK: - File tree

struct FileTreePanel: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var model: FileTreeModel
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void

    @State private var isFilterActive = false
    @State private var filterQuery = ""
    @State private var isPanelHovered = false
    @State private var isPanelClicked = false
    @State private var eventMonitor: Any? = nil

    @FocusState private var isFilterFieldFocused: Bool
    @FocusState private var isTreeFocused: Bool

    /// 根据当前 Filter 过滤已在 Tree 中存在的节点，同时保留匹配节点的所有父路径。
    private var filteredItems: [FileTreeModel.Item] {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFilterActive, !trimmed.isEmpty else {
            return model.items
        }

        let directMatches = model.items.filter { !$0.isDraft && $0.name.localizedCaseInsensitiveContains(trimmed) }
        var keepPaths = Set<String>()

        for item in directMatches {
            keepPaths.insert(item.path)
            if item.isDirectory {
                // 若匹配项为文件夹，保留其所有直属/深层子节点
                for child in model.items where child.path.hasPrefix(item.path + "/") {
                    keepPaths.insert(child.path)
                }
            }
        }

        // 向上补齐父路径，保持树型层级关系
        let allItemPaths = Set(model.items.map(\.path))
        for path in keepPaths {
            var current = (path as NSString).deletingLastPathComponent
            while !current.isEmpty && current != "/" && current != model.rootPath {
                if allItemPaths.contains(current) {
                    keepPaths.insert(current)
                }
                current = (current as NSString).deletingLastPathComponent
            }
        }

        return model.items.filter { keepPaths.contains($0.path) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PanelHeader(title: model.rootName, subtitle: model.rootPath)
                Button {
                    isFilterActive.toggle()
                    if isFilterActive {
                        isFilterFieldFocused = true
                    } else {
                        dismissFilter()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(SidebarTypography.secondary())
                        .foregroundStyle(isFilterActive ? Color(nsColor: Theme.cursor) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Filter files (⌘F)")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
                } label: {
                    Image(systemName: "finder")
                        .font(SidebarTypography.secondary())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            // Files 面板 Header 空白区域允许拖拽移动窗口
            .background { WindowDragArea() }

            if isFilterActive {
                filterBarView
            }

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            let itemsToDisplay = filteredItems
                            if itemsToDisplay.isEmpty && isFilterActive && !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                VStack(spacing: 6) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.tertiary)
                                    Text("No matching files")
                                        .font(SidebarTypography.caption())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                            } else {
                                LazyVStack(spacing: 1) {
                                    ForEach(itemsToDisplay) { item in
                                        FileTreeRow(
                                            model: model, item: item, session: session,
                                            currentFilePath: currentFilePath,
                                            openFile: openFile, openToSide: openToSide, onRename: onRename
                                        )
                                        .id(item.id)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.bottom, 8)
                                // 点击列表空白处清空选择；行上的手势优先命中。
                                .frame(maxWidth: .infinity, alignment: .top)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.clearSelection()
                                }
                            }

                            // 填满 Files 面板底部剩余空白区域，允许拖拽移动窗口
                            WindowDragArea()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .frame(minHeight: 20)
                        }
                        .frame(minHeight: geo.size.height, alignment: .top)
                    }
                    .focused($isTreeFocused)
                    .focusable(true)
                    .focusEffectDisabled()
                    .onAppear {
                        scrollProxy = proxy
                    }
                }
            }
            // ⌘F 快捷键：仅在焦点位于 Files Tree 时激活 Filter，与终端/编辑器 ⌘F 隔离
            .onKeyPress(keys: [.init("f")], phases: .down) { press in
                guard press.modifiers.contains(.command),
                      !press.modifiers.contains(.shift),
                      !press.modifiers.contains(.option)
                else { return .ignored }
                isFilterActive = true
                isFilterFieldFocused = true
                return .handled
            }
            // 文件树快捷键：⌘A 全选、⌘C 复制、⌘V 粘贴（需面板焦点）。
            .onKeyPress(keys: [.init("a")], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAllVisible()
                return .handled
            }
            .onKeyPress(keys: [.init("c")], phases: .down) { press in
                guard press.modifiers.contains(.command),
                      !press.modifiers.contains(.shift),
                      !press.modifiers.contains(.option)
                else { return .ignored }
                guard !model.selectedItems.isEmpty else { return .ignored }
                model.copySelectionToPasteboard()
                return .handled
            }
            .onKeyPress(keys: [.init("v")], phases: .down) { press in
                guard press.modifiers.contains(.command),
                      !press.modifiers.contains(.shift),
                      !press.modifiers.contains(.option)
                else { return .ignored }
                guard FileTreeModel.canPasteFromPasteboard else { return .ignored }
                model.pasteFromPasteboard()
                return .handled
            }
        }
        .onAppear {
            setupKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onHover { isHovered in
            isPanelHovered = isHovered
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                isPanelClicked = true
            }
        )
        .onChange(of: model.selectedPaths) { _ in
            // 如果 Quick Look 预览窗口已打开，选中项改变时实时更新 Quick Look 预览
            if QuickLookManager.shared.isVisible {
                let fileURLs = model.selectedItems
                    .filter { !$0.isDirectory && !$0.isDraft }
                    .map { URL(fileURLWithPath: $0.path) }
                if !fileURLs.isEmpty {
                    QuickLookManager.shared.preview(urls: fileURLs)
                }
            }
        }
        .onChange(of: manager.selectedProject?.selectedTab?.focusedPaneID) { _ in
            // 当主编辑区/终端被点击或切换焦点时，标记侧边栏无独立点击响应
            isPanelClicked = false
        }
        .onChange(of: manager.panelTab) { _ in
            if manager.panelTab != .files && manager.panelTab != .cwd {
                dismissFilter()
                isPanelClicked = false
                QuickLookManager.shared.close()
            }
        }
    }

    @State private var scrollProxy: ScrollViewProxy? = nil

    /// 根据首字母定位并选中目标文件，连续触发时在相同首字母文件间循环切换。
    private func jumpToNextItem(startingWith char: Character) {
        let prefix = String(char).lowercased()
        let visible = filteredItems.filter { !$0.isDraft }
        let candidates = visible.filter { $0.name.lowercased().hasPrefix(prefix) }
        guard !candidates.isEmpty else { return }

        let targetItem: FileTreeModel.Item
        if let currentPath = model.selectedPaths.first,
           let selectedIndexInCandidates = candidates.firstIndex(where: { $0.path == currentPath }) {
            // 当前已选中该首字母的某个候选文件：循环切换到下一个
            let nextIndex = (selectedIndexInCandidates + 1) % candidates.count
            targetItem = candidates[nextIndex]
        } else {
            // 当前选中的项不在候选列表中：从目前选中项后方开始找到第一个候选，或者直接取首个候选
            if let currentPath = model.selectedPaths.first,
               let currentIndexInVisible = visible.firstIndex(where: { $0.path == currentPath }),
               let firstCandidateAfter = candidates.first(where: { candidate in
                   if let candidateIndex = visible.firstIndex(where: { $0.path == candidate.path }) {
                       return candidateIndex > currentIndexInVisible
                   }
                   return false
               }) {
                targetItem = firstCandidateAfter
            } else {
                targetItem = candidates[0]
            }
        }

        // 选中目标并平滑滚动到可见区域中央
        model.selectClick(targetItem, modifiers: [])
        if let proxy = scrollProxy {
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(targetItem.id, anchor: .center)
            }
        }
    }

    /// 注册 NSEvent 本地按键监听，处理 ⌘F、字母数字文件定位及空格键 Quick Look 预览。
    private func setupKeyboardMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // 1. ⌘F 快捷键：激活 Filter 输入栏
            if flags == .command, event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f" {
                if isFilesTreeActiveOrFocused() {
                    Task { @MainActor in
                        isFilterActive = true
                        isFilterFieldFocused = true
                    }
                    return nil // 拦截 ⌘F，不触发主菜单 Find 命令
                }
            }

            // 2. 字母数字按键文件定位 (a-z, 0-9)：在非 Filter 激活且非内联重命名/新建草稿状态下触发
            if (flags.isEmpty || flags == .shift),
               !isFilterActive,
               !isFilterFieldFocused,
               model.renamingPath == nil,
               model.draft == nil,
               isFilesTreeActiveOrFocused() {
                if let chars = event.charactersIgnoringModifiers, chars.count == 1,
                   let scalar = chars.unicodeScalars.first,
                   CharacterSet.alphanumerics.contains(scalar) {
                    let char = Character(chars.lowercased())
                    Task { @MainActor in
                        jumpToNextItem(startingWith: char)
                    }
                    return nil // 消费该按键，屏蔽系统提示音
                }
            }

            // 3. 空格键：触发/切换系统 Quick Look 文件快速预览
            if flags.isEmpty, event.keyCode == 49 || event.charactersIgnoringModifiers == " ",
               !isFilterActive,
               !isFilterFieldFocused,
               model.renamingPath == nil,
               model.draft == nil,
               isFilesTreeActiveOrFocused() {
                let fileURLs = model.selectedItems
                    .filter { !$0.isDirectory && !$0.isDraft }
                    .map { URL(fileURLWithPath: $0.path) }
                if !fileURLs.isEmpty {
                    Task { @MainActor in
                        QuickLookManager.shared.togglePreview(urls: fileURLs)
                    }
                    return nil // 消费空格键
                }
            }

            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// 判断当前 ⌘F 是否应该作用于 Files Tree。
    private func isFilesTreeActiveOrFocused() -> Bool {
        guard manager.isPanelVisible,
              (manager.panelTab == .files || manager.panelTab == .cwd)
        else { return false }

        if isFilterActive || isFilterFieldFocused || isTreeFocused || isPanelClicked {
            return true
        }

        if let window = NSApp.keyWindow, let responder = window.firstResponder as? NSView {
            let className = String(describing: type(of: responder))
            if className.contains("Ghostty") || className.contains("STTextView") || className.contains("SourceTextEditor") {
                return false
            }
            var current: NSView? = responder
            while let v = current {
                let name = String(describing: type(of: v))
                if name.contains("FileTree") || name.contains("RightSidebar") {
                    return true
                }
                current = v.superview
            }
        }

        return isPanelHovered
    }

    /// 顶部 Filter 输入栏。
    @ViewBuilder
    private var filterBarView: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Filter files…", text: $filterQuery)
                .textFieldStyle(.plain)
                .font(SidebarTypography.body())
                .focused($isFilterFieldFocused)
                .onKeyPress(.escape) {
                    dismissFilter()
                    return .handled
                }

            if !filterQuery.isEmpty {
                Button {
                    filterQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }

            Button {
                dismissFilter()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close filter (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// 关闭与重置 Filter 状态，复位焦点至文件树列表。
    private func dismissFilter() {
        filterQuery = ""
        isFilterActive = false
        isFilterFieldFocused = false
        isTreeFocused = true
    }
}

private struct FileTreeRow: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject private var settings = AppSettings.shared
    let item: FileTreeModel.Item
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void

    @State private var isHovering = false
    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { model.renamingPath == item.path }

    /// 用户多选/单击选中的行。
    private var isSelected: Bool { model.isSelected(item.path) }

    /// 当前编辑器打开的文件（与选择态可并存，选择优先高亮）。
    private var isCurrent: Bool { !item.isDirectory && item.path == currentFilePath }

    /// 普通文件：设置开启时显示字节大小。
    private var fileSizeLabel: String? {
        guard settings.displayFileSize, !item.isDirectory, !item.isDraft,
              let size = item.fileSize
        else { return nil }
        return Self.formatByteCount(size)
    }

    /// 目录：按需统计完成后的可读体积（与文件共用格式）。
    private var folderSizeLabel: String? {
        guard item.isDirectory, !item.isDraft else { return nil }
        if case .ready(let size) = model.folderSizeState(for: item.path) {
            return Self.formatByteCount(size)
        }
        return nil
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    /// 格式化文件与目录体积，将 bytes/byte/字节 统一替换显示为 b。
    private static func formatByteCount(_ size: UInt64) -> String {
        if size < 1000 {
            return "\(size) b"
        }
        let str = byteFormatter.string(fromByteCount: Int64(clamping: size))
        return str
            .replacingOccurrences(of: " bytes", with: " b")
            .replacingOccurrences(of: " Bytes", with: " b")
            .replacingOccurrences(of: " byte", with: " b")
            .replacingOccurrences(of: " Byte", with: " b")
            .replacingOccurrences(of: " 字节", with: " b")
            .replacingOccurrences(of: "字节", with: "b")
            .replacingOccurrences(of: " B", with: " b")
    }

    private var rowBackground: Color {
        if isSelected {
            return Color(nsColor: Theme.cursor).opacity(0.22)
        }
        if isCurrent {
            return Color.primary.opacity(0.09)
        }
        if isHovering {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }

    /// 选中态背景偏 accent 半透明，次要层级字色会糊在一起；选中时抬到 primary。
    private var titleForeground: Color {
        if isSelected {
            return .primary
        }
        // 点文件保持更弱一层。
        return item.name.hasPrefix(".")
            ? Color.primary.opacity(0.45)
            : Color.secondary
    }

    private var sizeForeground: Color {
        isSelected ? Color.secondary : Color.primary.opacity(0.45)
    }

    var body: some View {
        if item.isDraft {
            // The transient new-file/folder input row: no hover/menu, no
            // backing file to act on.
            draftRow
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(rowBackground)
                )
                .onHover { isHovering = $0 }
                .contextMenu { rowMenu }
        }
    }

    /// 右键菜单作用目标（只读，禁止在 body / menu 构建期改选择态）。
    /// 点在已多选的项上 → 整组；否则仅当前行（与 Finder 在动作瞬间解析目标一致）。
    private var menuActionTargets: [FileTreeModel.Item] {
        if model.isSelected(item.path), model.selectedPaths.count > 1 {
            return model.selectedItems
        }
        return [item]
    }

    @ViewBuilder
    private var rowMenu: some View {
        // 注意：SwiftUI 会在刷新 body 时求值 contextMenu 内容；
        // 此处绝不能写 selectedPaths，否则会触发无限重绘（CPU 打满、界面一直转圈）。
        let targets = menuActionTargets
        let fileTargets = targets.filter { !$0.isDirectory }
        let onlyItem = targets.count == 1 ? targets[0] : nil

        if !fileTargets.isEmpty {
            Button(fileTargets.count == 1 ? "Open" : "Open \(fileTargets.count) Files") {
                selectForContextAction()
                for file in fileTargets { openFile(file.path) }
            }
            if let only = onlyItem, !only.isDirectory {
                Button("Open to the Side") {
                    selectForContextAction()
                    openToSide(only.path)
                }
            }
        }

        Button("Open in Default App") {
            selectForContextAction()
            for target in menuActionTargets {
                NSWorkspace.shared.open(URL(fileURLWithPath: target.path))
            }
        }
        Button {
            selectForContextAction()
            let urls = menuActionTargets.map { URL(fileURLWithPath: $0.path) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } label: {
            Label("Reveal in Finder", systemImage: "finder")
        }
        Button(targets.count == 1 ? "Copy Path" : "Copy Paths") {
            selectForContextAction()
            let text = menuActionTargets.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        Divider()
        // 复制文件本身（fileURL，可粘贴到本树或 Finder）。
        Button(targets.count == 1 ? "Copy" : "Copy \(targets.count) Items") {
            selectForContextAction()
            model.copyToPasteboard(paths: menuActionTargets.map(\.path))
        }
        // 粘贴到右键目标：文件夹内，或文件的父目录。
        // 注意：不在菜单构建期写 selectedPaths；canPaste 只读剪贴板。
        if FileTreeModel.canPasteFromPasteboard {
            Button("Paste") {
                selectForContextAction()
                let dest = model.pasteDestinationDirectory(for: item)
                model.pasteFromPasteboard(into: dest)
            }
        }

        if let only = onlyItem, only.isDirectory {
            Divider()
            Button("cd Here") {
                selectForContextAction()
                session?.sendCommand("cd " + rightSidebarShellQuote(only.path) + "\n")
            }
            Button("New File…") {
                selectForContextAction()
                model.beginNewFile(in: only.path)
            }
            Button("New Folder…") {
                selectForContextAction()
                model.beginNewFolder(in: only.path)
            }
        }

        // 多选/单选目录：右键也可触发体积统计（与 hover Size 同一套队列）。
        let directoryTargets = targets.filter(\.isDirectory)
        if !directoryTargets.isEmpty {
            let n = directoryTargets.count
            Button(n == 1 ? "Calculate Size" : "Calculate Size (\(n))") {
                selectForContextAction()
                model.requestFolderSizes(
                    for: directoryTargets.map(\.path),
                    recalculate: true
                )
            }
        }

        Divider()
        if let only = onlyItem {
            Button("Rename") {
                model.beginRename(only)
            }
        }
        Button(
            targets.count == 1 ? "Move to Trash" : "Move \(targets.count) Items to Trash",
            role: .destructive
        ) {
            selectForContextAction()
            model.moveToTrash(paths: Set(menuActionTargets.map(\.path)))
        }
    }

    /// 用户点了菜单项后再收敛选择（允许改状态；不会在 body 构建期触发）。
    private func selectForContextAction() {
        model.prepareContextSelection(for: item)
    }

    /// Commits an inline rename and, when the file actually moved, tells the
    /// app to follow it in any open tabs. Guarded by `isRenaming` so the
    /// commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commitRename() {
        guard isRenaming else { return }
        let oldPath = item.path
        if let newPath = model.rename(item, to: editingName) {
            onRename(oldPath, newPath)
        }
    }

    /// Commits the inline new-file/folder input, opening a newly created file.
    /// Guarded so the commit-on-blur after Enter/Escape is a no-op.
    private func commitDraft() {
        guard item.isDraft, model.draft != nil else { return }
        if let created = model.commitDraft(name: editingName) {
            openFile(created)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isRenaming {
            renameRow
        } else {
            selectableRow
        }
    }

    /// 单击选择（含 ⌘ / ⇧），双击打开文件或展开目录；chevron 单独切换展开。
    private var selectableRow: some View {
        HStack(spacing: 5) {
            expandControl
            MaterialFileIconView(
                fileName: item.name,
                isDirectory: item.isDirectory,
                isExpanded: item.isDirectory && model.isExpanded(item),
                isRoot: item.path == model.rootPath,
                size: FileTreeFont.iconSize
            )
            .frame(width: FileTreeFont.iconSize, alignment: .center)
            Text(item.name)
                .foregroundStyle(titleForeground)
                // 文件名中的数字等宽，便于 `file01` / `file10` 等纵向对齐。
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            trailingSizeControl
        }
        .font(FileTreeFont.body)
        .frame(minHeight: FileTreeFont.rowMinHeight, alignment: .leading)
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        // simultaneous：单击立即选择（无双击延迟）；双击再打开/展开。
        .onTapGesture {
            model.selectClick(item, modifiers: NSEvent.modifierFlags)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                activateItem()
            }
        )
        // Drag a row out as a file URL: onto the terminal (which inserts its
        // path) or into Finder and other apps. 拖的是当前选择组（若本行在选中内）。
        .onDrag {
            dragProvider()
        }
    }

    /// 行尾体积区：文件直接显示；目录 hover 出 Size，统计中转圈，完成后显示数字。
    @ViewBuilder
    private var trailingSizeControl: some View {
        if item.isDirectory {
            folderSizeControl
        } else if let fileSizeLabel {
            Text(fileSizeLabel)
                .font(FileTreeFont.caption.monospacedDigit())
                .foregroundStyle(sizeForeground)
                .lineLimit(1)
                .layoutPriority(0)
        }
    }

    /// Size 按钮作用目录：本行在多选内 → 全部选中目录；否则仅本行。
    private var sizeActionDirectoryPaths: [String] {
        if isSelected, model.selectedPaths.count > 1 {
            return model.selectedItems.filter(\.isDirectory).map(\.path)
        }
        return item.isDirectory ? [item.path] : []
    }

    @ViewBuilder
    private var folderSizeControl: some View {
        switch model.folderSizeState(for: item.path) {
        case .calculating:
            // 离开 hover 仍保留指示，避免大目录扫盘时「按钮消失却不知进度」。
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.75)
                .frame(width: 14, height: 14)
                .help("Calculating folder size…")
        case .ready:
            if let folderSizeLabel {
                // Font.monospacedDigit：表格数字宽度固定，列表右侧体积列更稳。
                let sizeText = Text(folderSizeLabel)
                    .font(FileTreeFont.caption.monospacedDigit())
                    .foregroundStyle(sizeForeground)
                    .lineLimit(1)
                // hover 时点击数字可重算；多选时重算整组选中目录。
                if isHovering {
                    let paths = sizeActionDirectoryPaths
                    let n = paths.count
                    Button {
                        model.requestFolderSizes(for: paths, recalculate: true)
                    } label: {
                        sizeText
                    }
                    .buttonStyle(.plain)
                    .help(
                        n > 1
                            ? "Recalculate size for \(n) folders"
                            : "Recalculate folder size"
                    )
                    .layoutPriority(0)
                } else {
                    sizeText.layoutPriority(0)
                }
            }
        case .idle, .failed:
            if isHovering {
                let paths = sizeActionDirectoryPaths
                let n = paths.count
                let isFailed = model.folderSizeState(for: item.path) == .failed
                let title: String = {
                    if n > 1 { return "Size \(n)" }
                    return isFailed ? "Retry" : "Size"
                }()
                Button {
                    // 多选：跳过已 ready 的，只补算 idle/failed；单行 failed 走 Retry 同路径。
                    model.requestFolderSizes(for: paths, recalculate: false)
                } label: {
                    Text(title)
                        .font(FileTreeFont.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(Color(nsColor: Theme.cursor))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: Theme.cursor).opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
                .help(
                    n > 1
                        ? "Calculate size for \(n) selected folders"
                        : (isFailed ? "Retry calculating folder size" : "Calculate folder size")
                )
            }
        }
    }

    /// 目录折叠箭头：只切换展开，不打开文件。
    @ViewBuilder
    private var expandControl: some View {
        if item.isDirectory {
            Button {
                model.toggle(item)
            } label: {
                Image(systemName: "chevron.right")
                    .font(FileTreeFont.compact)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(model.isExpanded(item) ? 90 : 0))
                    .frame(width: 12, height: FileTreeFont.rowMinHeight, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Spacer().frame(width: 12)
        }
    }

    /// 双击：文件 → 打开；目录 → 展开/折叠。同时保证该项被选中。
    private func activateItem() {
        model.selectClick(item, modifiers: [])
        if item.isDirectory {
            model.toggle(item)
        } else {
            openFile(item.path)
        }
    }

    private func dragProvider() -> NSItemProvider {
        let paths: [String]
        if isSelected, model.selectedPaths.count > 1 {
            paths = model.selectedItems.map(\.path)
        } else {
            // 拖未选中项时先单选该项，与 Finder 一致。
            if !isSelected {
                model.selectClick(item, modifiers: [])
            }
            paths = [item.path]
        }
        // NSItemProvider 以主文件 URL 为代表；多文件时写入 pasteboard 文件列表。
        if paths.count == 1 {
            return NSItemProvider(object: URL(fileURLWithPath: paths[0]) as NSURL)
        }
        let provider = NSItemProvider()
        let urls = paths.map { URL(fileURLWithPath: $0) }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            // 注册第一个 URL 的 data；多文件拖拽由系统在部分场景下降级为单文件。
            if let data = urls.first?.dataRepresentation {
                completion(data, nil)
            } else {
                completion(nil, nil)
            }
            return nil
        }
        // 额外把全部路径写成 public.file-url 列表，供支持多文件的目标读取。
        provider.registerObject(
            urls.map(\.absoluteString).joined(separator: "\n") as NSString,
            visibility: .all
        )
        return provider
    }

    private var renameRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField("Name")
                .onSubmit { commitRename() }
                .onKeyPress(.escape) { model.cancelRename(); return .handled }
                .onChange(of: fieldFocused) {
                    // Commit on blur (Finder-style); unchanged names no-op.
                    if !fieldFocused { commitRename() }
                }
        }
        .font(FileTreeFont.body)
        .frame(minHeight: FileTreeFont.rowMinHeight, alignment: .leading)
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = item.name
            focusField()
        }
    }

    private var draftRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField(item.isDirectory ? "Folder name" : "File name")
                .onSubmit { commitDraft() }
                .onKeyPress(.escape) { model.cancelDraft(); return .handled }
                .onChange(of: fieldFocused) {
                    // Blur commits a typed name, cancels an empty one (VS Code).
                    if !fieldFocused { commitDraft() }
                }
        }
        .font(FileTreeFont.body)
        .frame(minHeight: FileTreeFont.rowMinHeight, alignment: .leading)
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = ""
            focusField()
        }
    }

    private func nameField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $editingName)
            .textFieldStyle(.plain)
            .font(FileTreeFont.body)
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: Theme.cursor).opacity(0.7), lineWidth: 1)
            )
    }

    /// Grab focus on the next runloop tick — a context menu is still
    /// dismissing when the input row appears, and a synchronous focus can be
    /// stolen back as it tears down.
    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    /// 重命名/草稿行仍用静态 leading（无独立 chevron 按钮）。
    private var leadingGlyphs: some View {
        let iconSize = FileTreeFont.iconSize
        return Group {
            if item.isDirectory && !item.isDraft {
                Image(systemName: "chevron.right")
                    .font(FileTreeFont.compact)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(model.isExpanded(item) ? 90 : 0))
                    .frame(width: 12, alignment: .center)
            } else {
                Spacer().frame(width: 12)
            }
            MaterialFileIconView(
                fileName: item.name,
                isDirectory: item.isDirectory,
                isExpanded: item.isDirectory && model.isExpanded(item),
                isRoot: item.path == model.rootPath,
                size: iconSize
            )
            .frame(width: iconSize, alignment: .center)
        }
    }
}
