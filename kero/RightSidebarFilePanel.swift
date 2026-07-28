//
//  RightSidebarFilePanel.swift
//  kero
//

import AppKit
import QuickLook
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Selected Row Position Preference Key

private struct SelectedRowYKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

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
    @ObservedObject var findModel: FilesFindModel
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    /// 打开 ImageBuild（多→多 / 1→多）；参数为选中的图片路径。
    var onImageBuild: (([String]) -> Void)? = nil

    @State private var isFilterActive = false
    @State private var filterQuery = ""
    @State private var isPanelHovered = false
    @State private var isPanelClicked = false
    /// Search 模式主输入框是否拥有焦点；Replace / Include / Exclude 不算。
    @State private var isFilesSearchFieldFocused = false
    /// Search 模式任一输入框是否拥有焦点，用于阻止快捷键漏到终端菜单。
    @State private var isFilesSearchInputFocused = false
    @State private var isCloseFilterHovering = false
    @State private var isContainerDropTargeted = false
    @State private var eventMonitor: Any? = nil

    @State private var selectedRowY: CGFloat? = nil
    @State private var quickPreviewPath: String? = nil
    @State private var quickPreviewImage: NSImage? = nil
    @State private var quickPreviewIsVideo = false
    @State private var quickPreviewLoading = false
    @State private var quickPreviewDimensions: String? = nil

    @State private var activeAnchorView: NSView? = nil
    @State private var activeAnchorPath: String? = nil

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
            HStack(spacing: 6) {
                PanelHeader(title: model.rootName, subtitle: model.rootPath, isSubtitlePath: true)

                SidebarIconButton(
                    systemImage: "magnifyingglass",
                    help: manager.filePanelMode == .search ? "Switch to File Tree (⇧⌘F)" : "Search in Files (⇧⌘F)",
                    active: manager.filePanelMode == .search
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.filePanelMode = manager.filePanelMode == .search ? .tree : .search
                    }
                }

                SidebarIconButton(
                    systemImage: "line.3.horizontal.decrease",
                    help: L10n.t("Filter files (⌘F)"),
                    active: isFilterActive
                ) {
                    isFilterActive.toggle()
                    if isFilterActive {
                        isFilterFieldFocused = true
                    } else {
                        dismissFilter()
                    }
                }

                SidebarMenuIconButton(
                    systemImage: "arrow.up.arrow.down",
                    help: L10n.t("Sort files"),
                    active: model.sortCriteria != .name || !model.sortAscending
                ) {
                    Picker(L10n.t("Sort By"), selection: Binding(
                        get: { model.sortCriteria },
                        set: { model.setSortCriteria($0) }
                    )) {
                        Text(L10n.t("File Name")).tag(FileTreeModel.FileSortCriteria.name)
                        Text(L10n.t("Modification Date")).tag(FileTreeModel.FileSortCriteria.date)
                        Text(L10n.t("Size")).tag(FileTreeModel.FileSortCriteria.size)
                    }
                    .pickerStyle(.inline)

                    Divider()

                    Picker(L10n.t("Order"), selection: Binding(
                        get: { model.sortAscending },
                        set: { model.setSortAscending($0) }
                    )) {
                        Text(L10n.t("Ascending")).tag(true)
                        Text(L10n.t("Descending")).tag(false)
                    }
                    .pickerStyle(.inline)
                }

                SidebarIconButton(
                    systemImage: "finder",
                    help: L10n.t("Reveal in Finder")
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            // Files 面板 Header 空白区域允许拖拽移动窗口
            mainContentView
            // 文件树快捷键：⌘A 全选、⌘C 复制、⌘V 粘贴（需面板焦点）。
            .onKeyPress(keys: [.init("a")], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAllVisible(visibleItems: filteredItems)
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
            if !isHovered {
                FilePreviewPopoverManager.shared.close()
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                isPanelClicked = true
                isTreeFocused = true
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        )
        .onChange(of: model.selectedPaths) { _ in
            updateQuickPreviewState()
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
                FilePreviewPopoverManager.shared.close()
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
        model.selectClick(targetItem, modifiers: [], visibleItems: filteredItems)
        if let proxy = scrollProxy {
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(targetItem.id, anchor: .center)
            }
        }
    }

    /// 注册 NSEvent 本地按键监听，处理 ⌘F、方向键移动选择/Shift 多选、字母数字文件定位及空格键 Quick Look 预览。
    private func setupKeyboardMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Sheet / 模态对话框（如 Image Build）打开时绝不拦截。
            if Self.isSheetOrModalPresented(event) {
                return event
            }

            // 只过滤用户显式按下的 Command, Shift, Option, Control 键，排除 macOS 为方向键自动附加的 .numericPad 与 .function
            let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // 1. Files 内部 ⌘F 三态：
            // 文件树 → Filter；Filter 输入框 → Search；Search 主输入框 → 文件树。
            if relevantFlags == .command,
               (event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f") {
                if manager.isPanelVisible, manager.panelTab == .files {
                    if manager.filePanelMode == .tree, isFilterFieldFocused {
                        Task { @MainActor in
                            dismissFilter()
                            manager.filePanelMode = .search
                        }
                        return nil
                    }
                    if manager.filePanelMode == .search, isFilesSearchFieldFocused {
                        Task { @MainActor in
                            isFilesSearchFieldFocused = false
                            isFilesSearchInputFocused = false
                            manager.filePanelMode = .tree
                        }
                        return nil
                    }
                    if manager.filePanelMode == .search, isFilesSearchInputFocused {
                        return nil
                    }
                    if isFilesTreeActiveOrFocused() {
                        Task { @MainActor in
                            isFilterActive = true
                            isFilterFieldFocused = true
                        }
                        return nil // 拦截 ⌘F，不触发主菜单 Find 命令
                    }
                }
            }

            // 2. 方向键移动选择与 Shift 多选 (keyCode: 123 左, 124 右, 125 下, 126 上)
            if (relevantFlags.isEmpty || relevantFlags == .shift),
               model.renamingPath == nil,
               model.draft == nil,
               (123...126).contains(event.keyCode) {
                let isFilterFocusMove = isFilterFieldFocused && event.keyCode == 125
                if isFilesTreeActiveOrFocused() || isFilterFocusMove {
                    let direction: FileTreeModel.ArrowDirection
                    switch event.keyCode {
                    case 123: direction = .left
                    case 124: direction = .right
                    case 125: direction = .down
                    case 126: direction = .up
                    default: return event
                    }
                    let isShift = relevantFlags.contains(.shift)
                    Task { @MainActor in
                        if isFilterFieldFocused {
                            isFilterFieldFocused = false
                        }
                        isPanelClicked = true
                        isTreeFocused = true
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        let visible = filteredItems
                        if let targetItem = model.moveSelection(direction: direction, shift: isShift, visibleItems: visible),
                           let proxy = scrollProxy {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(targetItem.id, anchor: nil)
                            }
                        }
                    }
                    return nil // 消费该按键，屏蔽系统提示音
                }
            }

            // 3. 字母数字按键文件定位 (a-z, 0-9)：在非 Filter 激活且非内联重命名/新建草稿状态下触发
            if (relevantFlags.isEmpty || relevantFlags == .shift),
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

            // 4. 空格键：触发/切换系统 Quick Look 文件快速预览
            if relevantFlags.isEmpty, event.keyCode == 49 || event.charactersIgnoringModifiers == " ",
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

    @ViewBuilder
    private var mainContentView: some View {
        if manager.filePanelMode == .search {
            FilesFindView(
                model: findModel,
                rootPath: model.rootPath,
                onOpenMatch: { path, line, col in
                    manager.openFile(path, line: line, column: col)
                },
                onInputFocusChanged: { searchFocused, anyInputFocused in
                    isFilesSearchFieldFocused = searchFocused
                    isFilesSearchInputFocused = anyInputFocused
                }
            )
        } else {
            VStack(spacing: 0) {
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
                                        Text(L10n.t("No matching files"))
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
                                                openFile: openFile, openToSide: openToSide, onRename: onRename,
                                                onImageBuild: onImageBuild,
                                                onRowClick: {
                                                    isPanelClicked = true
                                                    isTreeFocused = true
                                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                                },
                                                onRowAnchor: { path, view in
                                                    activeAnchorPath = path
                                                    activeAnchorView = view
                                                    updateQuickPreviewState(anchorView: view)
                                                }
                                            )
                                            .id(item.id)
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.bottom, 8)
                                    .frame(maxWidth: .infinity, alignment: .top)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        isPanelClicked = true
                                        isTreeFocused = true
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                        model.clearSelection()
                                    }
                                }

                                WindowDragArea()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .frame(minHeight: 20)
                            }
                            .frame(minHeight: geo.size.height, alignment: .top)
                        }
                        .coordinateSpace(name: "FileTreePanelContainer")
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isContainerDropTargeted ? Color(nsColor: Theme.cursor) : Color.clear, lineWidth: 2)
                                .padding(2)
                        )
                        .onDrop(of: [.fileURL], isTargeted: $isContainerDropTargeted) { providers in
                            let targetDir = model.rootPath
                            guard !targetDir.isEmpty else { return false }
                            let sources: [String]
                            if FileTreeModel.isDraggingFromTree {
                                sources = model.selectedItems.map(\.path)
                            } else {
                                sources = []
                            }

                            if !sources.isEmpty {
                                confirmAndPerformMove(sources: sources, targetDir: targetDir, model: model, onRename: onRename)
                            } else {
                                extractURLs(from: providers) { urls in
                                    confirmAndPerformMove(sources: urls.map(\.path), targetDir: targetDir, model: model, onRename: onRename)
                                }
                            }
                            return true
                        }
                        .onPreferenceChange(SelectedRowYKey.self) { y in
                            selectedRowY = y
                        }
                        .focused($isTreeFocused)
                        .focusable(true)
                        .focusEffectDisabled()
                        .onAppear {
                            scrollProxy = proxy
                        }
                    }
                }
            }
        }
    }

    /// 当前按键是否应完整交给 Sheet / 模态窗口。
    private static func isSheetOrModalPresented(_ event: NSEvent) -> Bool {
        // 事件落在 sheet 窗口上
        if event.window?.isSheet == true { return true }
        // 任意可见 sheet（SwiftUI sheet 有时 keyWindow 仍是宿主）
        if NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) {
            return true
        }
        if NSApp.modalWindow != nil { return true }
        return false
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// 判断当前按键事件是否应该作用于 Files Tree。
    private func isFilesTreeActiveOrFocused() -> Bool {
        guard manager.isPanelVisible,
              (manager.panelTab == .files || manager.panelTab == .cwd),
              manager.filePanelMode == .tree
        else { return false }

        // Sheet / 模态对话框打开时，Files 树不抢按键
        if NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) {
            return false
        }
        if NSApp.modalWindow != nil { return false }
        if let win = NSApp.keyWindow, win.isSheet { return false }

        // 内联重命名或新建草稿输入框激活时，不抢按键
        if model.renamingPath != nil || model.draft != nil {
            return false
        }

        // firstResponder 是当前事件最可靠的焦点来源，必须优先于
        // isPanelClicked 等 SwiftUI 状态判断。否则 Files 曾被点击后，
        // 再点击本来就已选中的终端 pane 不会改变 focusedPaneID，
        // 残留的 isPanelClicked 会继续截走终端的 ⌘F / 方向键等按键。
        if let window = NSApp.keyWindow, let responder = window.firstResponder as? NSView {
            let className = String(describing: type(of: responder))
            if responder is NSTextView || responder is NSTextField
                || responder is KeroTerminalView || responder is FocusReportingTextView
                || className.contains("TextField") || className.contains("FieldEditor")
                || className.contains("Ghostty") || className.contains("STTextView")
                || className.contains("SourceTextEditor") {
                return false
            }
        }

        // Files 树的 SwiftUI focus 是首选；isPanelClicked 仅用于树的
        // 空白区/行点击后 AppKit 没有可作为 firstResponder 的原生视图。
        if isFilterFieldFocused || isTreeFocused || isPanelClicked {
            return true
        }

        // SwiftUI 的 focus bridge 可能把 firstResponder 放在私有宿主视图，
        // 此时只沿视图层级确认它是否真的属于 Files / RightSidebar。
        if let window = NSApp.keyWindow, let responder = window.firstResponder as? NSView {
            var current: NSView? = responder
            while let v = current {
                let name = String(describing: type(of: v))
                if name.contains("FileTree") || name.contains("RightSidebar") {
                    return true
                }
                current = v.superview
            }
        }

        // hover 只决定预览展示，不代表键盘焦点；指针停在 Files 上时，
        // 仍应让当前 firstResponder（例如终端）独占快捷键。
        return false
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
                .help(L10n.t("Clear filter"))
            }

            Button {
                dismissFilter()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isCloseFilterHovering ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCloseFilterHovering ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseFilterHovering = $0 }
            .help(L10n.t("Close filter (Esc)"))
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

    // MARK: - Floating Quick Preview Helper

    private func isPreviewableFile(_ path: String) -> Bool {
        isImageFile(path) || isVideoFile(path)
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
            "tiff", "bmp", "svg", "ico", "icns", "avif", "psd"
        ]
        return imageExts.contains(ext)
    }

    private func isVideoFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let videoExts: Set<String> = [
            "mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "wmv"
        ]
        return videoExts.contains(ext)
    }

    private var currentSelectedFileSizeLabel: String? {
        guard let selectedItem = model.selectedItems.first,
              selectedItem.path == quickPreviewPath,
              let size = selectedItem.fileSize
        else { return nil }
        return FileTreeRow.formatByteCount(size)
    }

    private func updateQuickPreviewState(anchorView: NSView? = nil) {
        guard isPanelHovered else {
            FilePreviewPopoverManager.shared.close()
            return
        }

        let selected = model.selectedItems
        guard selected.count == 1,
              let item = selected.first,
              !item.isDirectory,
              !item.isDraft,
              isPreviewableFile(item.path)
        else {
            quickPreviewPath = nil
            quickPreviewImage = nil
            quickPreviewLoading = false
            quickPreviewDimensions = nil
            FilePreviewPopoverManager.shared.close()
            return
        }

        let targetPath = item.path
        let isVideo = isVideoFile(targetPath)
        quickPreviewPath = targetPath
        quickPreviewIsVideo = isVideo

        if let view = anchorView ?? activeAnchorView, activeAnchorPath == targetPath {
            if quickPreviewImage == nil {
                quickPreviewLoading = true
                FilePreviewPopoverManager.shared.show(
                    for: targetPath,
                    targetView: view,
                    image: nil,
                    isVideo: isVideo,
                    isLoading: true
                )
            }
        }

        let url = URL(fileURLWithPath: targetPath)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetPixelDim: CGFloat = 260 * scale
        let size = CGSize(width: targetPixelDim, height: targetPixelDim)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            DispatchQueue.main.async {
                guard self.quickPreviewPath == targetPath else { return }
                self.quickPreviewLoading = false
                var dimensionsStr: String? = nil
                var loadedImg: NSImage? = nil

                if let image = rep?.nsImage {
                    loadedImg = image
                    dimensionsStr = "\(Int(image.size.width)) × \(Int(image.size.height))"
                } else if self.isImageFile(targetPath), let fallback = NSImage(contentsOfFile: targetPath) {
                    loadedImg = fallback
                    dimensionsStr = "\(Int(fallback.size.width)) × \(Int(fallback.size.height))"
                }

                self.quickPreviewImage = loadedImg
                self.quickPreviewDimensions = dimensionsStr

                if let view = anchorView ?? self.activeAnchorView, self.activeAnchorPath == targetPath {
                    FilePreviewPopoverManager.shared.show(
                        for: targetPath,
                        targetView: view,
                        image: loadedImg,
                        isVideo: isVideo,
                        isLoading: false
                    )
                } else {
                    FilePreviewPopoverManager.shared.updateContent(
                        for: targetPath,
                        image: loadedImg,
                        isVideo: isVideo,
                        isLoading: false
                    )
                }
            }
        }
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
    var onImageBuild: (([String]) -> Void)? = nil
    var onRowClick: (() -> Void)? = nil
    var onRowAnchor: ((_ path: String, _ view: NSView) -> Void)? = nil

    @State private var isHovering = false
    @State private var isDropTargeted = false
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
    fileprivate static func formatByteCount(_ size: UInt64) -> String {
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
        if isDropTargeted {
            return Color(nsColor: Theme.cursor).opacity(0.35)
        }
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
                Button(L10n.t("Open to the Side")) {
                    selectForContextAction()
                    openToSide(only.path)
                }
            }
        }

        Button(L10n.t("Open in Default App")) {
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
            Label(L10n.t("Reveal in Finder"), systemImage: "finder")
        }

        // 选中的图片 → ImageBuild（单张为 1→多，多张为多→多）
        let imagePaths = targets
            .filter { !$0.isDirectory }
            .map(\.path)
            .filter { ImageBuild.supportsImageExtension(($0 as NSString).pathExtension) }
        if let onImageBuild, !imagePaths.isEmpty {
            Divider()
            Button {
                selectForContextAction()
                onImageBuild(imagePaths)
            } label: {
                Label {
                    Text(
                        imagePaths.count == 1
                            ? "Image Build…"
                            : "Image Build (\(imagePaths.count))…"
                    )
                } icon: {
                    Image("ImageBuild")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                }
            }
        }

        Divider()
        // 复制地址
        Button(targets.count == 1 ? "Copy Path" : "Copy Paths") {
            selectForContextAction()
            let text = menuActionTargets.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        // 复制文件本身（fileURL，可粘贴到本树或 Finder）。
        Button(targets.count == 1 ? "Copy" : "Copy \(targets.count) Items") {
            selectForContextAction()
            model.copyToPasteboard(paths: menuActionTargets.map(\.path))
        }
        // 粘贴到右键目标：文件夹内，或文件的父目录。
        // 注意：不在菜单构建期写 selectedPaths；canPaste 只读剪贴板。
        if FileTreeModel.canPasteFromPasteboard {
            Button(L10n.t("Paste")) {
                selectForContextAction()
                let dest = model.pasteDestinationDirectory(for: item)
                model.pasteFromPasteboard(into: dest)
            }
        }

        if let only = onlyItem, only.isDirectory {
            Divider()
            Button(L10n.t("cd Here")) {
                selectForContextAction()
                session?.sendCommand("cd " + rightSidebarShellQuote(only.path) + "\n")
            }
            Divider()
            Button(L10n.t("New File…")) {
                selectForContextAction()
                model.beginNewFile(in: only.path)
            }
            Button(L10n.t("New Folder…")) {
                selectForContextAction()
                model.beginNewFolder(in: only.path)
            }
        }

        // 多选/单选目录：右键也可触发体积统计（与 hover Size 同一套队列）。
        let directoryTargets = targets.filter(\.isDirectory)
        if !directoryTargets.isEmpty {
            let n = directoryTargets.count
            Button(
                n == 1
                    ? L10n.t("Calculate Size")
                    : L10n.format("Calculate Size (%d)", n)
            ) {
                selectForContextAction()
                model.requestFolderSizes(
                    for: directoryTargets.map(\.path),
                    recalculate: true
                )
            }
        }

        Divider()
        if let only = onlyItem {
            Button(L10n.t("Rename")) {
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
        .background(
            FileRowAnchorRepresentable(
                item: item,
                isSelected: isSelected && model.selectedPaths.count == 1,
                isPreviewable: item.name.contains(".") && !item.isDirectory
            ) { view in
                onRowAnchor?(item.path, view)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isDropTargeted ? Color(nsColor: Theme.cursor) : Color.clear, lineWidth: 1.5)
        )
        // simultaneous：单击立即选择（无双击延迟）；双击再打开/展开。
        .onTapGesture {
            onRowClick?()
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let targetDir = item.isDirectory ? item.path : (item.path as NSString).deletingLastPathComponent
            let sources: [String]
            if FileTreeModel.isDraggingFromTree {
                sources = isSelected && model.selectedPaths.count > 1
                    ? model.selectedItems.map(\.path)
                    : [item.path]
            } else {
                sources = []
            }

            if !sources.isEmpty {
                confirmAndPerformMove(sources: sources, targetDir: targetDir, model: model, onRename: onRename)
            } else {
                extractURLs(from: providers) { urls in
                    confirmAndPerformMove(sources: urls.map(\.path), targetDir: targetDir, model: model, onRename: onRename)
                }
            }
            return true
        }
    }

    /// 行尾操作与体积区：文件显示大小；目录 hover 出 Size 与新建文件夹（+）按钮。
    @ViewBuilder
    private var trailingSizeControl: some View {
        if item.isDirectory {
            HStack(spacing: 4) {
                folderSizeControl
                if isHovering {
                    Button {
                        model.beginNewFolder(in: item.path)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(nsColor: Theme.cursor))
                            .frame(width: 16, height: 16)
                            .background(
                                Circle()
                                    .fill(Color(nsColor: Theme.cursor).opacity(0.14))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("New Folder…"))
                    .layoutPriority(0)
                }
            }
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
                .help(L10n.t("Calculating folder size…"))
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
                onRowClick?()
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

    /// 生成拖拽 ItemProvider，包含文件 URL 与内部文件树标记。
    /// - Returns: NSItemProvider，若包含多选则写多文件列表，并附带 com.qjiao.filetree-item 标识
    private func dragProvider() -> NSItemProvider {
        FileTreeModel.isDraggingFromTree = true
        let pb = NSPasteboard(name: .drag)
        pb.addTypes([NSPasteboard.PasteboardType("com.qjiao.filetree-item")], owner: nil)
        pb.setString("true", forType: NSPasteboard.PasteboardType("com.qjiao.filetree-item"))
        FileTreeModel.activeTreeDragPasteboardChangeCount = pb.changeCount

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
        let provider: NSItemProvider
        if paths.count == 1 {
            provider = NSItemProvider(object: URL(fileURLWithPath: paths[0]) as NSURL)
        } else {
            provider = NSItemProvider()
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
        }
        // 标识属于软件内部文件目录树，避免触发全局「拖入文件夹打开项目」功能
        provider.registerDataRepresentation(
            forTypeIdentifier: "com.qjiao.filetree-item",
            visibility: .ownProcess
        ) { completion in
            completion("filetree".data(using: .utf8), nil)
            return nil
        }
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

// MARK: - File Preview Panel Manager (Borderless Floating NSPanel)

@MainActor
final class FilePreviewPopoverManager: NSObject {
    static let shared = FilePreviewPopoverManager()

    private var panel: NSPanel?
    private(set) var currentPath: String?
    private weak var currentView: NSView?
    private weak var currentClipView: NSClipView?
    private var scrollObserver: Any? = nil

    private func getOrCreatePanel() -> NSPanel {
        if let panel = self.panel {
            return panel
        }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .normal // 不使用 .floating，与主窗口平级
        p.hidesOnDeactivate = true // 切换至其他 App 时自动隐藏
        p.ignoresMouseEvents = true
        p.isMovableByWindowBackground = false
        self.panel = p
        return p
    }

    func show(
        for path: String,
        targetView: NSView,
        image: NSImage?,
        isVideo: Bool,
        isLoading: Bool
    ) {
        guard let window = targetView.window else {
            close()
            return
        }

        // 检查 targetView 是否在 ScrollView 可见区域内并设置 60/120fps 实时滚动监听
        if let clipView = targetView.enclosingScrollView?.contentView {
            let viewRectInClip = targetView.convert(targetView.bounds, to: clipView)
            if !clipView.bounds.intersects(viewRectInClip) {
                close()
                return
            }
            observeScrollView(clipView)
        }

        let panel = getOrCreatePanel()

        let contentView = FileQuickPreviewPopoverContentView(
            image: image,
            isVideo: isVideo,
            isLoading: isLoading
        )

        let displaySize = contentView.displaySize

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: displaySize)
        panel.contentView = hostingView

        currentPath = path
        currentView = targetView

        // 附加为主窗口子窗口：在 App 内位于最上层，但被其他应用遮盖时自动跟随主窗口下沉
        if panel.parent != window {
            if let oldParent = panel.parent {
                oldParent.removeChildWindow(panel)
            }
            window.addChildWindow(panel, ordered: .above)
        }

        updatePosition(targetView: targetView, panelSize: displaySize)

        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    func updateContent(
        for path: String,
        image: NSImage?,
        isVideo: Bool,
        isLoading: Bool
    ) {
        guard currentPath == path, let targetView = currentView else { return }
        show(for: path, targetView: targetView, image: image, isVideo: isVideo, isLoading: isLoading)
    }

    private func observeScrollView(_ clipView: NSClipView) {
        clipView.postsBoundsChangedNotifications = true
        if currentClipView !== clipView {
            removeScrollObserver()
            currentClipView = clipView
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.repositionCurrentPanel()
                }
            }
        }
    }

    private func removeScrollObserver() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
        currentClipView = nil
    }

    private func repositionCurrentPanel() {
        guard let targetView = currentView, let panel = panel, panel.isVisible else { return }

        if let clipView = targetView.enclosingScrollView?.contentView {
            let viewRectInClip = targetView.convert(targetView.bounds, to: clipView)
            if !clipView.bounds.intersects(viewRectInClip) {
                close()
                return
            }
        }

        if let hostingView = panel.contentView as? NSHostingView<FileQuickPreviewPopoverContentView> {
            let displaySize = hostingView.rootView.displaySize
            updatePosition(targetView: targetView, panelSize: displaySize)
        }
    }

    private func updatePosition(targetView: NSView, panelSize: CGSize) {
        guard let window = targetView.window, let panel = panel else { return }

        let rectInWindow = targetView.convert(targetView.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)

        // 紧贴文件目录树左边缘（右边缘与 sidebar 左界留 6pt 间隙），垂直中心对齐选中行
        let panelX = rectOnScreen.minX - panelSize.width - 6
        let panelY = rectOnScreen.midY - (panelSize.height / 2)

        panel.setFrame(NSRect(x: panelX, y: panelY, width: panelSize.width, height: panelSize.height), display: true, animate: false)
    }

    func close() {
        removeScrollObserver()
        if let parent = panel?.parent {
            parent.removeChildWindow(panel!)
        }
        panel?.orderOut(nil)
        currentPath = nil
        currentView = nil
    }
}

// MARK: - File Quick Preview Popover Content View

private extension NSImage {
    /// 获取 NSImage 的真实物理像素尺寸 (Physical Pixel Size)
    var pixelSize: CGSize {
        if let rep = representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        if let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return size
    }
}

private struct FileQuickPreviewPopoverContentView: View {
    let image: NSImage?
    let isVideo: Bool
    let isLoading: Bool

    /// 根据图片真实物理像素与高清屏缩放比（Retina @2x/@3x）计算 1:1 像素清晰对齐的紧凑浮窗尺寸
    var displaySize: CGSize {
        guard let image = image else {
            return CGSize(width: 160, height: 110)
        }
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pix = image.pixelSize
        guard pix.width > 0, pix.height > 0 else {
            return CGSize(width: 160, height: 110)
        }

        // 高清屏点阵尺寸（Physical Pixels / backingScaleFactor）
        let ptW = pix.width / screenScale
        let ptH = pix.height / screenScale

        let maxW: CGFloat = 260
        let maxH: CGFloat = 260
        let scale = min(1.0, min(maxW / ptW, maxH / ptH))
        let finalW = max(32, ptW * scale)
        let finalH = max(32, ptH * scale)
        return CGSize(width: finalW, height: finalH)
    }

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 160, height: 110)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displaySize.width, height: displaySize.height)

                if isVideo {
                    // 视频播放缩略图轻量标记
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(Color.black.opacity(0.65)))
                                .padding(6)
                        }
                    }
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text(L10n.t("No Preview Available"))
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 160, height: 100)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .background(
            ZStack {
                VisualEffectView()
                Color(nsColor: Theme.sidebar).opacity(0.4)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Anchor NSView Representable

private struct FileRowAnchorRepresentable: NSViewRepresentable {
    let item: FileTreeModel.Item
    let isSelected: Bool
    let isPreviewable: Bool
    let onAnchor: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { nsView in
            if isSelected && isPreviewable {
                onAnchor(nsView)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isSelected && isPreviewable {
            DispatchQueue.main.async {
                onAnchor(nsView)
            }
        }
    }
}

private final class AnchorNSView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: ((NSView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onLayout?(self)
        }
    }

    override func layout() {
        super.layout()
        if window != nil {
            onLayout?(self)
        }
    }
}

// MARK: - Drag and Drop Move Helpers

/// 校验并弹出确认移动对话框（NSAlert），用户确认后执行移动操作。
@MainActor
fileprivate func confirmAndPerformMove(
    sources: [String],
    targetDir: String,
    model: FileTreeModel,
    onRename: ((_ oldPath: String, _ newPath: String) -> Void)?
) {
    let normalizedTarget = (targetDir as NSString).standardizingPath
    let validSources = sources.filter { srcPath in
        let normalizedSource = (srcPath as NSString).standardizingPath
        let srcDir = (normalizedSource as NSString).deletingLastPathComponent

        // 1. 同目录内无需移动
        guard srcDir != normalizedTarget else { return false }
        // 2. 目标就是自身：无效
        guard normalizedSource != normalizedTarget else { return false }
        // 3. 不能将文件/文件夹移入自身或其子目录下
        guard !normalizedTarget.hasPrefix(normalizedSource + "/") else { return false }
        // 4. 源路径必须存在
        return FileManager.default.fileExists(atPath: normalizedSource)
    }

    guard !validSources.isEmpty else {
        FileTreeModel.isDraggingFromTree = false
        return
    }

    let targetDirName = (normalizedTarget as NSString).lastPathComponent

    let alert = NSAlert()
    if validSources.count == 1 {
        let srcName = (validSources[0] as NSString).lastPathComponent
        alert.messageText = L10n.format(
            "Are you sure you want to move “%@” into “%@”?",
            srcName,
            targetDirName
        )
        alert.informativeText = L10n.t(
            "This operation will move the selected item to the new location."
        )
    } else {
        alert.messageText = L10n.format(
            "Are you sure you want to move %d items into “%@”?",
            validSources.count,
            targetDirName
        )
        alert.informativeText = L10n.t(
            "This operation will move the selected items to the new location."
        )
    }
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.t("Move"))
    alert.addButton(withTitle: L10n.t("Cancel"))

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        model.moveItems(paths: validSources, into: normalizedTarget, onRename: onRename)
    }
    FileTreeModel.isDraggingFromTree = false
}

/// 从 NSItemProvider 数组异步提取 fileURL。
fileprivate func extractURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()

    for provider in providers {
        if provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                if let url = object {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
    }

    group.notify(queue: .main) {
        completion(urls)
    }
}
