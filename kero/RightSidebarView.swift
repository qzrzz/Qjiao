//
//  RightSidebarView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 右侧下半区底栏 tab（框架阶段仅切换空壳）。
private enum RightBottomPanel: String, CaseIterable, Identifiable {
    case system
    case note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .note: return "Note"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "cpu"
        case .note: return "note.text"
        }
    }
}

/// Right sidebar: hidden by default, toggled from the terminal's corner
/// button or ⇧⌘B. 上半区沿用 Start/Files/Git 等顶栏面板；下半区为
/// System / Note；中间可拖分割。
struct RightSidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var fileTree = FileTreeModel()
    @StateObject private var git = GitStatusModel()
    @StateObject private var info = SessionInfoModel()
    @StateObject private var systemInfo = SystemInfoModel()
    @StateObject private var noteModel = NoteModel()
    @AppStorage("rightSidebarWidth") private var width: Double = 240
    /// 上半区占「可分割内容高度」的比例；默认 70%。收起下半区时仍保留，便于展开还原。
    @AppStorage("rightSidebarTopFraction") private var topFraction: Double = 0.70
    /// 下半区是否收起为仅显示 System/Note tabs（内容高度为 0）。
    @AppStorage("rightSidebarBottomCollapsed") private var bottomCollapsed = false
    /// 下半区底栏选中项：system / note。
    @AppStorage("rightSidebarBottomTab") private var bottomTabRaw: String = RightBottomPanel.system.rawValue
    @State private var wasCWDVisible = false

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// 上沿放宽到接近贴底：下半最小可为仅 tabs。
    private static let topFractionRange: ClosedRange<Double> = 0.25...0.98
    private static let defaultTopFraction: Double = 0.70
    private static let splitHandleHeight: CGFloat = 7
    private static let bottomBarHeight: CGFloat = 38
    private static let minTopContentHeight: CGFloat = 80
    /// 展开时下半区内容区的建议最小高度（收起时可为 0，仅留 tabs）。
    private static let minBottomContentHeight: CGFloat = 60

    private var bottomTab: RightBottomPanel {
        RightBottomPanel(rawValue: bottomTabRaw) ?? .system
    }

    /// Path of the file in the focused pane, so the tree can highlight it.
    /// Reactive: focus/selection is published up through the project to `manager`.
    private var openFilePath: String? {
        if case .file(let file)? = manager.selectedProject?.focusedContent {
            return file.path
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if manager.isPanelVisible {
                // The divider remains translucent, but must composite over
                // an opaque sidebar-colored base instead of the terminal
                // surface below this sibling view.
                Rectangle()
                    .fill(Color(nsColor: Theme.sidebar.withAlphaComponent(1)))
                    .frame(width: 1)
                    .overlay {
                        Rectangle()
                            .fill(Color(nsColor: Theme.divider))
                    }

                splitBody
                    .frame(width: width)
                    .background {
                        // Keep the sidebar visually consistent with the main
                        // window: reduced window opacity uses native blur beneath
                        // the themed sidebar tint, rather than a sharp desktop.
                        if settings.windowBackgroundOpacity < 1 || settings.visualEffectAlpha < 1 {
                            VisualEffectView()
                        }
                        Color(nsColor: Theme.sidebar.withAlphaComponent(settings.windowBackgroundOpacity))
                        // 面板内容的空白区域可拖动窗口，前景控件仍优先接收点击和滚动。
                        WindowDragArea()
                    }
            }
        }
        .overlay(alignment: .leading) {
            if manager.isPanelVisible {
                SidebarResizeHandle(
                    edge: .leading,
                    width: $width,
                    range: 180...500,
                    defaultWidth: 240
                )
            }
        }
        .onAppear {
            syncModels()
            syncSystemPolling()
            syncNoteBinding()
        }
        .onReceive(refreshTimer) { _ in syncModels() }
        .onChange(of: manager.isPanelVisible) {
            syncModels()
            syncSystemPolling()
            // 隐藏右侧栏时先落盘，避免防抖未到就丢改动。
            if !manager.isPanelVisible {
                noteModel.flush()
            } else {
                syncNoteBinding()
            }
        }
        .onChange(of: manager.panelTab) { syncModels() }
        .onChange(of: manager.selectedSession?.id) { syncModels() }
        // A `cd` in the terminal publishes the new cwd immediately (OSC 7 →
        // session.workingDirectory); resync at once instead of waiting for the
        // next refreshTimer tick, which is what made the panel lag the change.
        .onChange(of: manager.selectedSession?.workingDirectory) { syncModels() }
        .onChange(of: manager.selectedProject?.id) { syncNoteBinding() }
        .onChange(of: bottomTabRaw) {
            syncSystemPolling()
            // 离开 Note tab 时立即写盘。
            if bottomTab != .note {
                noteModel.flush()
            } else {
                syncNoteBinding()
            }
        }
        .onChange(of: bottomCollapsed) {
            syncSystemPolling()
            if bottomCollapsed {
                noteModel.flush()
            }
        }
    }

    /// 笔记绑定当前选中项目；无项目时清空绑定。
    private func syncNoteBinding() {
        noteModel.bind(to: manager.selectedProject?.id)
    }

    /// 仅在右侧栏可见、下半区展开且选中 System 时轮询 CLI 指标。
    private func syncSystemPolling() {
        let active = manager.isPanelVisible
            && !bottomCollapsed
            && bottomTab == .system
        systemInfo.setActive(active)
    }

    /// 上下分区主体：上半现有面板、可拖分割；下半区顶部是 System/Note tabs，
    /// 其下为内容（可收起到 0，仅留 tabs）。
    private var splitBody: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.height - Self.splitHandleHeight)
            let minBottom = Self.bottomBarHeight
            let (topHeight, bottomHeight) = sectionHeights(available: available, minBottom: minBottom)

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    tabBar
                    topPanelContent
                }
                .frame(height: topHeight, alignment: .top)
                .clipped()

                VerticalSplitHandle(
                    fraction: $topFraction,
                    range: Self.topFractionRange,
                    defaultFraction: Self.defaultTopFraction,
                    availableHeight: available,
                    isCollapsed: $bottomCollapsed,
                    collapsedBottomHeight: Self.bottomBarHeight
                )

                // Tabs 在下半区顶部；收起时 bottomHeight == tabs 栏，内容不占高。
                VStack(spacing: 0) {
                    bottomTabBar
                    if !bottomCollapsed, bottomHeight > Self.bottomBarHeight {
                        bottomPanelContent
                    }
                }
                .frame(height: bottomHeight, alignment: .top)
                .clipped()
            }
        }
    }

    /// 按收起状态与 topFraction 分配上下高度；下半最小仅为 tabs 栏。
    private func sectionHeights(available: CGFloat, minBottom: CGFloat) -> (CGFloat, CGFloat) {
        if bottomCollapsed {
            let bottom = min(minBottom, available)
            let top = max(0, available - bottom)
            return (top, bottom)
        }
        let clampedFraction = min(
            max(topFraction, Self.topFractionRange.lowerBound),
            Self.topFractionRange.upperBound
        )
        let top = max(
            Self.minTopContentHeight,
            min(available - minBottom, available * clampedFraction)
        )
        let bottom = max(minBottom, available - top)
        return (top, bottom)
    }

    @ViewBuilder
    private var topPanelContent: some View {
        switch manager.panelTab {
        case .start:
            if let project = manager.selectedProject {
                StartPanel(
                    project: project,
                    runCommand: { manager.runLaunchCommand($0) },
                    runAllCommands: { manager.runAllLaunchCommands() }
                )
            }
        case .files:
            FileTreePanel(
                model: fileTree,
                session: manager.selectedSession,
                currentFilePath: openFilePath,
                openFile: { manager.openFile($0) },
                openToSide: { manager.openFileToSide($0) },
                onRename: { manager.fileRenamed(from: $0, to: $1) }
            )
        case .cwd:
            FileTreePanel(
                model: fileTree,
                session: manager.selectedSession,
                currentFilePath: openFilePath,
                openFile: { manager.openFile($0) },
                openToSide: { manager.openFileToSide($0) },
                onRename: { manager.fileRenamed(from: $0, to: $1) }
            )
        case .git:
            GitPanel(
                model: git,
                session: manager.selectedSession,
                openFile: { manager.openFile($0) },
                openToSide: { manager.openFileToSide($0) },
                openDiff: { entry, staged in
                    manager.openDiff(
                        repoRoot: git.repoRoot,
                        path: entry.path,
                        staged: staged,
                        untracked: entry.isUntracked,
                        origPath: entry.origPath
                    )
                }
            )
        case .info:
            InfoPanel(
                model: info,
                session: manager.selectedSession,
                runPackageScript: { manager.runPackageScript($0) }
            )
        }
    }

    /// 下半区内容：System 为 CLI 指标；Note 为按项目的纯文本草稿。
    @ViewBuilder
    private var bottomPanelContent: some View {
        switch bottomTab {
        case .system:
            SystemPanel(model: systemInfo)
        case .note:
            NotePanel(
                model: noteModel,
                hasProject: manager.selectedProject != nil
            )
        }
    }

    private var bottomTabBar: some View {
        ZStack(alignment: .leading) {
            // 标签未占满的区域仍可拖动窗口。
            WindowDragArea()
            HStack(spacing: 4) {
                ForEach(RightBottomPanel.allCases) { tab in
                    bottomTabButton(tab)
                }
                Spacer(minLength: 0)
                bottomCollapseButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: Self.bottomBarHeight)
        .contentShape(Rectangle())
        // 与 tab 按钮并存：双击底栏任意处（含标签）切换收起/展开。
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                toggleBottomCollapsed()
            }
        )
        .help(bottomCollapsed ? "Double-click to expand" : "Double-click to collapse")
        .accessibilityHint(bottomCollapsed ? "Double-click to expand panel" : "Double-click to collapse panel")
    }

    /// 底栏右侧收起/展开，行为与双击 tabs 一致。
    private var bottomCollapseButton: some View {
        let title = bottomCollapsed ? "Expand" : "Collapse"
        return Button {
            toggleBottomCollapsed()
        } label: {
            Image(systemName: bottomCollapsed ? "chevron.up" : "chevron.down")
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func bottomTabButton(_ tab: RightBottomPanel) -> some View {
        let isActive = bottomTab == tab
        return Button {
            bottomTabRaw = tab.rawValue
        } label: {
            sidebarTabLabel(
                systemImage: tab.systemImage,
                title: tab.title,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isActive ? "Selected" : "Not selected")
    }

    /// 收起时仅保留 tabs；展开时恢复上次 topFraction（若无效则用默认 70%）。
    private func toggleBottomCollapsed() {
        if bottomCollapsed {
            bottomCollapsed = false
            if topFraction >= Self.topFractionRange.upperBound - 0.01 {
                topFraction = Self.defaultTopFraction
            }
        } else {
            bottomCollapsed = true
        }
    }

    private var tabBar: some View {
        ZStack(alignment: .leading) {
            // 右侧顶栏未被面板切换按钮占用的区域可拖动窗口。
            WindowDragArea()

            HStack(spacing: 4) {
                tabButton(.start, systemImage: "play.circle", title: "Start", help: "Start")
                tabButton(.info, systemImage: "info.circle", title: "Info", help: "Info (⇧⌘I)")
                tabButton(.files, systemImage: "folder", title: "Files", help: "Files (⇧⌘E)")
                if showsCWD {
                    tabButton(.cwd, systemImage: "terminal", title: "CWD", help: "CWD")
                }
                tabButton(.git, systemImage: "arrow.triangle.branch", title: "Git", help: "Git (⇧⌘G)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
        .frame(height: 41)
    }

    private func tabButton(_ panel: RightPanel, systemImage: String, title: String, help: String) -> some View {
        let isActive = manager.panelTab == panel
        return Button {
            manager.panelTab = panel
        } label: {
            sidebarTabLabel(systemImage: systemImage, title: title, isActive: isActive)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Selected" : "Not selected")
    }

    /// 上/下半区共用的 tab 样式：内容宽度（最小 75）、左对齐；字重始终 medium，
    /// 选中只改颜色和背景，避免 regular↔medium 宽度变化导致抖动。
    private func sidebarTabLabel(systemImage: String, title: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(SidebarTypography.caption(.medium))
            Text(title)
                .font(SidebarTypography.secondary(.medium))
        }
        // 未选中使用次级文字色，避免在浅色模式下过于发白。
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 75)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.09) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func syncModels() {
        guard let project = manager.selectedProject, manager.isPanelVisible else { return }
        guard manager.panelTab != .start else { return }
        guard let session = manager.selectedSession else { return }
        let cwdVisible = showsCWD
        if manager.panelTab == .files, cwdVisible, !wasCWDVisible {
            manager.panelTab = .cwd
        }
        wasCWDVisible = cwdVisible

        if manager.panelTab == .cwd, !cwdVisible {
            manager.panelTab = .files
            return
        }
        switch manager.panelTab {
        case .start:
            break
        case .files: fileTree.sync(root: projectRoot(for: project, fallback: session))
        case .cwd: fileTree.sync(root: session.currentDirectoryPath)
        case .git: git.sync(root: session.currentDirectoryPath)
        case .info:
            info.sync(
                root: projectRoot(for: project, fallback: session),
                shellName: session.shellName,
                shellPid: session.shellPid
            )
        }
    }

    /// 项目配置尚未写入目录时，使用当前终端目录作为一次性回退值。
    private func projectRoot(for project: Project, fallback session: TerminalSession) -> String {
        project.projectDirectory.isEmpty ? session.currentDirectoryPath : project.projectDirectory
    }

    /// 只有项目目录与当前终端目录不同时才显示 CWD 面板。
    private var showsCWD: Bool {
        guard let project = manager.selectedProject,
              let session = manager.selectedSession
        else { return false }
        return normalizedPath(projectRoot(for: project, fallback: session))
            != normalizedPath(session.currentDirectoryPath)
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

// MARK: - Shared panel chrome

private struct PanelHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(SidebarTypography.title())
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SidebarTypography.caption())
                    // PID 作为辅助信息显示，但在浅色模式下保持足够对比度。
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - File tree

private struct FileTreePanel: View {
    @ObservedObject var model: FileTreeModel
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PanelHeader(title: model.rootName, subtitle: model.rootPath)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(SidebarTypography.secondary())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.items) { item in
                        FileTreeRow(
                            model: model, item: item, session: session,
                            currentFilePath: currentFilePath,
                            openFile: openFile, openToSide: openToSide, onRename: onRename
                        )
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
            .focusable(true)
            .focusEffectDisabled()
            // ⌘A 全选当前可见项（需面板先获得焦点）。
            .onKeyPress(keys: [.init("a")], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAllVisible()
                return .handled
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

    private static func formatByteCount(_ size: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: size))
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
        Button("Reveal in Finder") {
            selectForContextAction()
            let urls = menuActionTargets.map { URL(fileURLWithPath: $0.path) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        Button(targets.count == 1 ? "Copy Path" : "Copy Paths") {
            selectForContextAction()
            let text = menuActionTargets.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        if let only = onlyItem, only.isDirectory {
            Button("cd Here") {
                selectForContextAction()
                session?.sendCommand("cd " + shellQuote(only.path) + "\n")
            }
            Divider()
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
                .font(FileTreeFont.caption)
                .foregroundStyle(sizeForeground)
                .monospacedDigit()
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
                let sizeText = Text(folderSizeLabel)
                    .font(FileTreeFont.caption)
                    .foregroundStyle(sizeForeground)
                    .monospacedDigit()
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
                        .font(FileTreeFont.caption.weight(.medium))
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

// MARK: - Git panel

private struct GitPanel: View {
    private struct FileFingerprint: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?
    }

    private struct PendingDiscard {
        let entry: GitStatusModel.Entry
        let fingerprints: [String: FileFingerprint]
        let branch: String?
        let headOID: String?
    }

    @ObservedObject var model: GitStatusModel
    let session: TerminalSession?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let openDiff: (_ entry: GitStatusModel.Entry, _ staged: Bool) -> Void

    @State private var commitMessage = ""
    @State private var pendingDiscard: PendingDiscard?
    @State private var pendingDiscardAll: [PendingDiscard] = []
    @State private var confirmDiscardAll = false
    @State private var mergeCollapsed = false
    @State private var stagedCollapsed = false
    @State private var changesCollapsed = false
    @State private var historyCollapsed = true
    @State private var filterText = ""
    @State private var showFilter = false
    @State private var showBranchCreator = false
    @State private var newBranchName = ""
    @State private var operationExpanded = false
    @FocusState private var branchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            operationBanner

            if let statusError = model.statusError {
                statusFailure(statusError)
            } else if !model.isRepo {
                if model.isResolvingInitialStatus {
                    placeholder(icon: "arrow.clockwise", text: "Finding repository…")
                } else if model.isBusy {
                    placeholder(icon: "hourglass", text: "Finishing Git operation…")
                } else {
                    notRepository
                }
            } else {
                trackingBar
                repositoryOperationBanner
                branchCreator
                commitBox
                filterBar
                changeList
            }
        }
        .confirmationDialog(
            discardTitle(for: pendingDiscard?.entry),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(discardActionTitle(for: pendingDiscard?.entry),
                   role: .destructive) {
                if let pendingDiscard {
                    if discardSnapshotIsCurrent(pendingDiscard) {
                        model.discard(pendingDiscard.entry)
                    } else {
                        model.cancelStaleDiscard()
                    }
                }
                pendingDiscard = nil
            }
            .disabled(model.isBusy)
        }
        .confirmationDialog(
            "Discard the \(pendingDiscardAll.count) reviewed changes? Untracked and moved files go to the Trash.",
            isPresented: Binding(
                get: { confirmDiscardAll },
                set: {
                    confirmDiscardAll = $0
                    if !$0 { pendingDiscardAll = [] }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard All Changes", role: .destructive) {
                let snapshot = pendingDiscardAll
                if !snapshot.isEmpty && snapshot.allSatisfy(discardSnapshotIsCurrent) {
                    model.discardChanges(snapshot.map(\.entry))
                } else {
                    model.cancelStaleDiscard()
                }
                pendingDiscardAll = []
                confirmDiscardAll = false
            }
            .disabled(model.isBusy)
        }
        .onChange(of: model.rootPath) {
            // A dialog must never carry a destructive file target across cwd.
            pendingDiscard = nil
            pendingDiscardAll = []
            confirmDiscardAll = false
            showBranchCreator = false
            newBranchName = ""
        }
        .onChange(of: model.repositoryIdentity) {
            resetRepositoryDrafts()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if model.isRepo {
                branchMenu
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(SidebarTypography.secondary(.medium))
                    .foregroundStyle(Color(nsColor: Theme.cursor))
                PanelHeader(title: "Git", subtitle: model.rootPath)
            }
            // Only surface progress for user operations and the initial
            // repository discovery. Routine two-second background polls resolve
            // in milliseconds; showing a spinner for them just makes the header
            // flicker.
            if model.isBusy || model.isResolvingInitialStatus {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(model.isBusy ? "Git operation in progress" : "Refreshing Git status")
            }
            if model.isRepo {
                headerButton("line.3.horizontal.decrease", help: "Filter Changed Files", disabled: false) {
                    showFilter.toggle()
                    if !showFilter { filterText = "" }
                }
                headerButton(
                    "arrow.clockwise",
                    help: "Refresh Git Status",
                    disabled: model.isBusy || model.isResolvingInitialStatus
                ) {
                    model.refresh()
                }
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var branchMenu: some View {
        Menu {
            if !model.branches.isEmpty {
                ForEach(model.branches, id: \.self) { branch in
                    Button {
                        model.switchBranch(to: branch)
                    } label: {
                        if branch == model.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == model.branch || model.isBusy)
                }
                Divider()
            }
            Button("Create New Branch…") {
                newBranchName = ""
                showBranchCreator = true
                DispatchQueue.main.async { branchFieldFocused = true }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(SidebarTypography.secondary(.medium))
                    .foregroundStyle(Color(nsColor: Theme.cursor))
                PanelHeader(title: model.branch ?? "Detached HEAD", subtitle: model.rootPath)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Switch or Create Branch")
        .accessibilityLabel("Current branch, \(model.branch ?? "detached HEAD")")
    }

    private var moreMenu: some View {
        Menu {
            Button("Fetch") { model.fetch() }
                .disabled(model.isBusy || model.remotes.isEmpty)
            Button("Pull (Fast-forward Only)") { model.pull() }
                .disabled(model.isBusy || !model.hasUpstream)
            if model.hasUpstream {
                Button("Push") { model.push() }
                    .disabled(model.isBusy)
            } else if model.remotes.count > 1 {
                Menu("Publish Branch to") {
                    ForEach(model.remotes, id: \.self) { remote in
                        Button(remote) { model.publish(to: remote) }
                    }
                }
                .disabled(model.isBusy || model.branch == "detached HEAD")
            } else {
                Button("Publish Branch") { model.push() }
                    .disabled(model.isBusy || model.remotes.isEmpty || model.branch == "detached HEAD")
            }
            Button("Sync Changes") { model.syncChanges() }
                .disabled(
                    model.isBusy || model.remotes.isEmpty
                        || (!model.hasUpstream && model.remotes.count != 1)
                        || model.branch == "detached HEAD"
                )
            Divider()
            Button("Stash All Changes") { model.stash(includeUntracked: true) }
                .disabled(model.isBusy || model.totalChangeCount == 0)
            Button(model.stashCount == 1 ? "Pop Stash" : "Pop Stash (\(model.stashCount))") {
                model.stashPop()
            }
            .disabled(model.isBusy || model.stashCount == 0)
            Divider()
            Button("Copy Changed Paths") { copyChangedPaths() }
                .disabled(model.totalChangeCount == 0)
            Button("Copy Repository Path") { copyToPasteboard(model.repoRoot) }
            Button("Reveal Repository in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.repoRoot)])
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Actions…")
        .accessibilityLabel("More Git Actions")
    }

    private func headerButton(
        _ systemImage: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var trackingBar: some View {
        if let branch = model.branch {
            HStack(spacing: 5) {
                Image(systemName: model.hasUpstream ? "arrow.triangle.2.circlepath" : "icloud.slash")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
                Text(model.upstream ?? (branch == "detached HEAD" ? "Detached HEAD" : "Unpublished branch"))
                    .font(SidebarTypography.section())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if model.behind > 0 {
                    badge("↓\(model.behind)", label: "\(model.behind) incoming commits")
                }
                if model.ahead > 0 {
                    badge("↑\(model.ahead)", label: "\(model.ahead) outgoing commits")
                }
            }
            .frame(height: SidebarTypography.rowMinHeight)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Repository and operation state

    @ViewBuilder
    private var repositoryOperationBanner: some View {
        if let current = model.repositoryOperation {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge")
                    .font(SidebarTypography.caption(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(current)
                        .font(SidebarTypography.caption(.medium))
                    Text(model.mergeEntries.isEmpty
                         ? "Finish or abort from the terminal"
                         : "Resolve and stage \(model.mergeEntries.count) conflicted \(model.mergeEntries.count == 1 ? "file" : "files")")
                        .font(SidebarTypography.section())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(red: 0.74, green: 0.55, blue: 1.0))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.74, green: 0.55, blue: 1.0).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var operationBanner: some View {
        if let operation = model.operation {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    operationIcon(operation)
                    Text(operation.statusLabel)
                        .font(SidebarTypography.caption(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !operation.output.isEmpty {
                        Button {
                            operationExpanded.toggle()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(SidebarTypography.compact())
                                .rotationEffect(.degrees(operationExpanded ? 90 : 0))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(operationExpanded ? "Hide Git Output" : "Show Git Output")
                        .accessibilityLabel(operationExpanded ? "Hide Git Output" : "Show Git Output")
                    }
                    if !operation.isRunning {
                        Button {
                            operationExpanded = false
                            model.dismissOperation()
                        } label: {
                            Image(systemName: "xmark")
                                .font(SidebarTypography.compact())
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss Git Result")
                    }
                }
                if operationExpanded, !operation.output.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(operation.output)
                            .font(SidebarTypography.micro(.regular, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 96)
                    .accessibilityLabel("Git Output")
                }
            }
            .foregroundStyle(operationColor(operation))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(operationColor(operation).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
    }

    @ViewBuilder
    private func operationIcon(_ operation: GitStatusModel.Operation) -> some View {
        switch operation.state {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 11, height: 11)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").font(SidebarTypography.caption())
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(SidebarTypography.caption())
        }
    }

    private func operationColor(_ operation: GitStatusModel.Operation) -> Color {
        switch operation.state {
        case .running: return Color(nsColor: Theme.cursor)
        case .succeeded: return Color(red: 0.25, green: 0.68, blue: 0.33)
        case .failed: return Color(red: 0.88, green: 0.42, blue: 0.36)
        }
    }

    @ViewBuilder
    private var branchCreator: some View {
        if showBranchCreator {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.secondary)
                TextField("New branch name", text: $newBranchName)
                    .textFieldStyle(.plain)
                    .font(SidebarTypography.secondary())
                    .focused($branchFieldFocused)
                    .onSubmit(createBranch)
                    .onKeyPress(.escape) {
                        showBranchCreator = false
                        return .handled
                    }
                Button("Create", action: createBranch)
                    .buttonStyle(.borderless)
                    .font(SidebarTypography.caption(.medium))
                    .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                Button {
                    showBranchCreator = false
                } label: {
                    Image(systemName: "xmark").font(SidebarTypography.compact())
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .accessibilityLabel("Cancel Branch Creation")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: Theme.cursor).opacity(0.45))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func createBranch() {
        let name = newBranchName
        model.createBranch(named: name) { success in
            guard success else { return }
            newBranchName = ""
            showBranchCreator = false
        }
    }

    // MARK: Commit box

    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField(commitFieldPlaceholder, text: $commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(SidebarTypography.body())
                .lineLimit(1...4)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    performPrimaryAction()
                    return .handled
                }

            HStack(spacing: 4) {
                actionButton(
                    icon: "checkmark",
                    title: commitButtonTitle,
                    enabled: canCommit(includeAll: false),
                    help: "Commit staged changes (⌘Return)",
                    action: performPrimaryAction
                )
                commitMenu
            }

            if showSyncButton {
                actionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncButtonTitle,
                    enabled: !model.isBusy,
                    help: "Pull remote commits, then push local ones",
                    action: model.syncChanges
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var commitMenu: some View {
        Menu {
            Button("Commit Staged") { performCommit(includeAll: false) }
                .disabled(!canCommit(includeAll: false))
            Button("Stage All & Commit") { performCommit(includeAll: true) }
                .disabled(!canCommit(includeAll: true))
            Divider()
            Button("Amend Last Commit") { performCommit(includeAll: false, amend: true) }
                .disabled(!canAmend(includeAll: false))
            Button("Stage All & Amend") { performCommit(includeAll: true, amend: true) }
                .disabled(!canAmend(includeAll: true))
        } label: {
            Image(systemName: "chevron.down")
                .font(SidebarTypography.compact())
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Commit Options")
        .accessibilityLabel("Commit Options")
    }

    private func actionButton(
        icon: String, title: String, enabled: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(SidebarTypography.caption(.semibold))
                Text(title)
                    .font(SidebarTypography.secondary(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: Theme.cursor).opacity(enabled ? 0.85 : 0.3))
            )
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(title)
    }

    private var commitFieldPlaceholder: String {
        if model.stagedEntries.isEmpty {
            return model.recentCommits.isEmpty
                ? "Message (stage changes to use ⌘⏎)"
                : "Message (stage changes to use ⌘⏎, or choose Amend)"
        }
        if let branch = model.branch {
            return "Message (⌘⏎ to commit on \"\(branch)\")"
        }
        return "Message (⌘⏎ to commit)"
    }

    private var showSyncButton: Bool {
        model.totalChangeCount == 0 && (model.ahead > 0 || model.behind > 0)
    }

    private var syncButtonTitle: String {
        var title = "Sync Changes"
        if model.behind > 0 { title += " \(model.behind)↓" }
        if model.ahead > 0 { title += " \(model.ahead)↑" }
        return title
    }

    private var commitButtonTitle: String {
        if model.stagedEntries.count == 1 { return "Commit 1 Staged File" }
        if model.stagedEntries.count > 1 { return "Commit \(model.stagedEntries.count) Staged Files" }
        return "Commit Staged"
    }

    private func canCommit(includeAll: Bool) -> Bool {
        let hasEligibleChanges = includeAll
            ? (!model.changedEntries.isEmpty || !model.stagedEntries.isEmpty)
            : !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func canAmend(includeAll: Bool) -> Bool {
        let hasCommit = !model.recentCommits.isEmpty
        let hasEligibleChanges = !includeAll
            || !model.changedEntries.isEmpty
            || !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommit
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func performPrimaryAction() {
        performCommit(includeAll: false)
    }

    private func performCommit(includeAll: Bool, amend: Bool = false) {
        guard amend ? canAmend(includeAll: includeAll) : canCommit(includeAll: includeAll) else { return }
        let submittedMessage = commitMessage
        model.commit(message: submittedMessage, includeAll: includeAll, amend: amend) { success in
            if success, commitMessage == submittedMessage { commitMessage = "" }
        }
    }

    // MARK: Filter

    @ViewBuilder
    private var filterBar: some View {
        if showFilter {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.tertiary)
                TextField("Filter changed files", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(SidebarTypography.secondary())
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Filter")
                    .accessibilityLabel("Clear Git Filter")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.045))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: Change list

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if model.totalChangeCount == 0 {
                    cleanState
                } else if visibleChangeCount == 0 {
                    inlinePlaceholder(icon: "line.3.horizontal.decrease", text: "No changed files match “\(filterText)”")
                }
                if !filteredMergeEntries.isEmpty {
                    GitSectionHeader(
                        title: "MERGE CHANGES",
                        count: filteredMergeEntries.count,
                        isCollapsed: $mergeCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                    if !mergeCollapsed {
                        ForEach(filteredMergeEntries, id: \.mergeRowID) { entry in
                            row(entry, status: "U", kind: .merge)
                        }
                    }
                }
                if !filteredStagedEntries.isEmpty {
                    GitSectionHeader(
                        title: "STAGED CHANGES",
                        count: filteredStagedEntries.count,
                        isCollapsed: $stagedCollapsed,
                        actions: filterText.isEmpty ? [
                            .init(systemImage: "minus", help: "Unstage All Changes") {
                                model.unstageAll()
                            }
                        ] : [],
                        actionsDisabled: model.isBusy
                    )
                    if !stagedCollapsed {
                        ForEach(filteredStagedEntries, id: \.stagedRowID) { entry in
                            row(entry, status: entry.staged, kind: .staged)
                        }
                    }
                }
                if !filteredChangedEntries.isEmpty {
                    GitSectionHeader(
                        title: "CHANGES",
                        count: filteredChangedEntries.count,
                        isCollapsed: $changesCollapsed,
                        actions: filterText.isEmpty ? [
                            .init(systemImage: "arrow.uturn.backward", help: "Discard All Changes") {
                                requestDiscardAll()
                            },
                            .init(systemImage: "plus", help: "Stage All Changes") {
                                model.stageAll()
                            },
                        ] : [],
                        actionsDisabled: model.isBusy
                    )
                    if !changesCollapsed {
                        ForEach(filteredChangedEntries, id: \.changedRowID) { entry in
                            row(entry, status: entry.unstaged, kind: .unstaged)
                        }
                    }
                }
                if filterText.isEmpty, !model.recentCommits.isEmpty {
                    GitSectionHeader(
                        title: "RECENT COMMITS",
                        count: model.recentCommits.count,
                        isCollapsed: $historyCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                    if !historyCollapsed {
                        ForEach(model.recentCommits) { commit in
                            GitCommitRow(commit: commit)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private var filteredMergeEntries: [GitStatusModel.Entry] {
        model.mergeEntries.filter(matchesFilter)
    }

    private var filteredStagedEntries: [GitStatusModel.Entry] {
        model.stagedEntries.filter(matchesFilter)
    }

    private var filteredChangedEntries: [GitStatusModel.Entry] {
        model.changedEntries.filter(matchesFilter)
    }

    private var visibleChangeCount: Int {
        filteredMergeEntries.count + filteredStagedEntries.count + filteredChangedEntries.count
    }

    private func matchesFilter(_ entry: GitStatusModel.Entry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)
    }

    private var cleanState: some View {
        inlinePlaceholder(
            icon: model.ahead > 0 || model.behind > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle",
            text: model.ahead > 0 || model.behind > 0 ? "Working tree clean, sync is pending" : "Working tree clean"
        )
    }

    private func row(
        _ entry: GitStatusModel.Entry, status: Character, kind: GitEntryRow.Kind
    ) -> some View {
        GitEntryRow(
            entry: entry,
            status: status,
            kind: kind,
            disabled: model.isBusy,
            openDiff: {
                guard model.isCurrent(entry) else { return }
                var diffEntry = entry
                if kind == .unstaged && (entry.staged == "R" || entry.staged == "C") {
                    // A staged rename/copy's unstaged side compares the
                    // destination in the index with that same worktree path.
                    diffEntry.origPath = nil
                }
                openDiff(diffEntry, kind == .staged)
            },
            openFile: { openIfPossible(entry) },
            openToSide: { openIfPossible(entry, toSide: true) },
            stage: { model.stage(entry) },
            unstage: { model.unstage(entry) },
            discard: { pendingDiscard = makePendingDiscard(entry) },
            absolutePath: model.absolutePath(for: entry),
            copyRelativePath: { copyToPasteboard(entry.path) },
            insertInTerminal: session.map { session in
                { session.sendCommand(shellQuoted(model.absolutePath(for: entry)) + " ") }
            }
        )
    }

    private func openIfPossible(_ entry: GitStatusModel.Entry, toSide: Bool = false) {
        guard model.isCurrent(entry) else { return }
        let path = model.absolutePath(for: entry)
        guard FileManager.default.fileExists(atPath: path) else { return }
        if toSide {
            openToSide(path)
        } else {
            openFile(path)
        }
    }

    private func discardTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return "" }
        if entry.isUntracked {
            return "Delete \(entry.fileName)? Its contents will move to the Trash."
        }
        if entry.isWorktreeRename, let original = entry.origPath {
            return "Undo this rename? \(entry.fileName) will move to the Trash and \((original as NSString).lastPathComponent) will be restored."
        }
        if entry.isWorktreeCopy {
            return "Discard this copy? \(entry.fileName) will move to the Trash."
        }
        return "Discard changes in \(entry.fileName)?"
    }

    private func discardActionTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return "Discard Changes" }
        if entry.isUntracked || entry.isWorktreeCopy { return "Move to Trash" }
        if entry.isWorktreeRename { return "Undo Rename" }
        return "Discard Changes"
    }

    private func makePendingDiscard(_ entry: GitStatusModel.Entry) -> PendingDiscard {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath {
            paths.append(original)
        }
        return PendingDiscard(
            entry: entry,
            fingerprints: Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, fileFingerprint(at: absolutePath(path, for: entry)))
            }),
            branch: model.branch,
            headOID: model.headOID
        )
    }

    private func discardSnapshotIsCurrent(_ pending: PendingDiscard) -> Bool {
        model.isCurrent(pending.entry)
            && model.branch == pending.branch
            && model.headOID == pending.headOID
            && model.changedEntries.contains(pending.entry)
            && pending.fingerprints.allSatisfy { path, fingerprint in
                fileFingerprint(at: absolutePath(path, for: pending.entry)) == fingerprint
            }
    }

    private func absolutePath(_ path: String, for entry: GitStatusModel.Entry) -> String {
        let root = entry.repositoryRoot.isEmpty ? model.repoRoot : entry.repositoryRoot
        return (root as NSString).appendingPathComponent(path)
    }

    private func fileFingerprint(at path: String) -> FileFingerprint {
        let fm = FileManager.default
        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: path)
        guard linkDestination != nil || fm.fileExists(atPath: path) else {
            return FileFingerprint(
                exists: false, size: 0, modificationDate: nil,
                fileNumber: nil, symbolicLinkDestination: nil
            )
        }
        let attributes = try? fm.attributesOfItem(atPath: path)
        return FileFingerprint(
            exists: true,
            size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            symbolicLinkDestination: linkDestination
        )
    }

    private func requestDiscardAll() {
        pendingDiscardAll = model.changedEntries.map(makePendingDiscard)
        confirmDiscardAll = !pendingDiscardAll.isEmpty
    }

    // MARK: Bits

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(.quaternary)
            Text(text)
                .font(SidebarTypography.secondary())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func inlinePlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(SidebarTypography.emptyInlineIcon())
                .foregroundStyle(.quaternary)
            Text(text)
                .font(SidebarTypography.caption())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }

    private var notRepository: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(.quaternary)
            VStack(spacing: 2) {
                Text("No Git Repository")
                    .font(SidebarTypography.body(.medium))
                Text("Initialize the terminal’s current directory to start tracking changes.")
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Button("Initialize Repository") {
                model.initializeRepository()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color(nsColor: Theme.cursor))
            .disabled(model.rootPath.isEmpty || model.isBusy)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func statusFailure(_ message: String) -> some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
            VStack(spacing: 3) {
                Text("Git Status Unavailable")
                    .font(SidebarTypography.body(.medium))
                Text(message)
                    .font(SidebarTypography.caption(design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            Button("Retry") { model.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy || model.isResolvingInitialStatus)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String, label: String) -> some View {
        Text(text)
            .font(SidebarTypography.caption(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .accessibilityLabel(label)
    }

    private func copyChangedPaths() {
        let paths = Set(
            (model.mergeEntries + model.stagedEntries + model.changedEntries).map(\.path)
        ).sorted()
        copyToPasteboard(paths.joined(separator: "\n"))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resetRepositoryDrafts() {
        commitMessage = ""
        filterText = ""
        showFilter = false
        newBranchName = ""
        showBranchCreator = false
        operationExpanded = false
        pendingDiscard = nil
        pendingDiscardAll = []
        confirmDiscardAll = false
        mergeCollapsed = false
        stagedCollapsed = false
        changesCollapsed = false
        historyCollapsed = true
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct GitSectionHeader: View {
    struct Action: Identifiable {
        let id = UUID()
        let systemImage: String
        let help: String
        let perform: () -> Void
    }

    let title: String
    let count: Int
    @Binding var isCollapsed: Bool
    let actions: [Action]
    var actionsDisabled = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(SidebarTypography.chevron())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(title)
                        .font(SidebarTypography.section(.semibold))
                        // 分组标题使用次级文字色，提升浅色模式下的可读性。
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            ForEach(actions) { action in
                Button(action: action.perform) {
                    Image(systemName: action.systemImage)
                        .font(SidebarTypography.micro())
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .disabled(actionsDisabled)
                .opacity(actionsDisabled ? 0.3 : (isHovering ? 1 : 0.55))
                .help(action.help)
                .accessibilityLabel(action.help)
            }

            Spacer(minLength: 0)

            if count > 0 {
                Text("\(count)")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        // Fixed height so the taller hover buttons don't grow the header.
        .frame(height: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(actions) { action in
                Button(action.help, action: action.perform)
                    .disabled(actionsDisabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}

private struct GitCommitRow: View {
    let commit: GitStatusModel.RecentCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .font(SidebarTypography.body())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(commit.shortHash)
                    .font(SidebarTypography.section(design: .monospaced))
                    .foregroundStyle(Color(nsColor: Theme.cursor).opacity(0.85))
                Text("·")
                Text(commit.author)
                Text("·")
                Text(commit.relativeDate)
            }
            .font(SidebarTypography.section())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Commit Hash") { copy(commit.hash) }
            Button("Copy Commit Message") { copy(commit.subject) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(commit.subject), \(commit.shortHash), by \(commit.author), \(commit.relativeDate)")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct GitEntryRow: View {
    enum Kind {
        case merge, staged, unstaged
    }

    let entry: GitStatusModel.Entry
    let status: Character
    let kind: Kind
    let disabled: Bool
    let openDiff: () -> Void
    let openFile: () -> Void
    let openToSide: () -> Void
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void
    let absolutePath: String
    let copyRelativePath: () -> Void
    let insertInTerminal: (() -> Void)?

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button(action: openDiff) {
                HStack(spacing: 7) {
                    Text(String(status))
                        .font(SidebarTypography.caption(.bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .frame(width: 12)
                    // Git 变更行：按文件名匹配 Material 图标（目录变更极少，按文件处理）。
                    MaterialFileIconView(
                        fileName: entry.fileName,
                        isDirectory: false,
                        size: 14
                    )
                    Text(entry.fileName)
                        .font(SidebarTypography.body())
                        .foregroundStyle(.secondary)
                        .strikethrough(status == "D")
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !isHovering && !isFocused {
                        Text(entry.directory)
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: SidebarTypography.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .accessibilityLabel("\(entry.fileName), \(statusName)")
            .accessibilityHint(kind == .merge ? "Opens conflict changes" : "Opens changes")

            if !disabled {
                hoverActions
                    .opacity(isHovering || isFocused ? 1 : 0.55)
            }
        }
        // Fixed height so action buttons do not grow the dense file row.
        .frame(minHeight: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering || isFocused ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu { menu }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            switch kind {
            case .merge:
                rowButton("plus", help: "Mark Resolved (Stage)", action: stage)
            case .staged:
                rowButton("minus", help: "Unstage Changes", action: unstage)
            case .unstaged:
                rowButton("arrow.uturn.backward", help: "Discard Changes", action: discard)
                rowButton("plus", help: "Stage Changes", action: stage)
            }
        }
    }

    private func rowButton(
        _ systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var menu: some View {
        if kind == .merge {
            Button("Open Changes") { openDiff() }
            Button("Open Conflicted File") { openFile() }
        } else {
            Button("Open Changes") { openDiff() }
            Button("Open File") { openFile() }
        }
        Button("Open File to the Side") { openToSide() }
        Divider()
        switch kind {
        case .merge:
            Button("Mark Resolved (Stage)") { stage() }
                .disabled(disabled)
        case .staged:
            Button("Unstage Changes") { unstage() }
                .disabled(disabled)
        case .unstaged:
            Button("Stage Changes") { stage() }
                .disabled(disabled)
            Button(destructiveMenuTitle) { discard() }
                .disabled(disabled)
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(absolutePath, forType: .string)
        }
        Button("Copy Relative Path") { copyRelativePath() }
        if let insertInTerminal {
            Button("Insert Absolute Path in Terminal") { insertInTerminal() }
        }
    }

    private var statusName: String {
        switch status {
        case "M": return "Modified"
        case "A": return "Added"
        case "?": return "Untracked"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "U": return "Conflict"
        default: return "Changed"
        }
    }

    private var destructiveMenuTitle: String {
        if entry.isUntracked || entry.isWorktreeCopy { return "Move to Trash…" }
        if entry.isWorktreeRename { return "Undo Rename…" }
        return "Discard Changes…"
    }

    private var statusColor: Color {
        switch status {
        case "M": return Color(red: 0.82, green: 0.60, blue: 0.13)
        case "A", "?": return Color(red: 0.25, green: 0.73, blue: 0.31)
        case "D": return Color(red: 1.0, green: 0.48, blue: 0.45)
        case "R", "C": return Color(red: 0.35, green: 0.65, blue: 1.0)
        case "U": return Color(red: 0.74, green: 0.55, blue: 1.0)
        default: return .secondary
        }
    }
}

// MARK: - Info panel

/// Session dashboard: working directory (with reveal/open/copy actions),
/// processes running under the shell, and ports they are listening on.
private struct InfoPanel: View {
    @ObservedObject var model: SessionInfoModel
    let session: TerminalSession?
    let runPackageScript: (String) -> Void

    @State private var directoryCollapsed = false
    @State private var packageScriptsCollapsed = false
    @State private var processesCollapsed = false
    @State private var portsCollapsed = false

    private static let vsCodeURL = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    directorySection
                    packageScriptsSection
                    processesSection
                    portsSection
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(Color(nsColor: Theme.cursor))
            PanelHeader(
                title: model.shellName.isEmpty ? "Session" : model.shellName,
                subtitle: model.shellPid > 0 ? "pid \(String(model.shellPid))" : nil
            )
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(SidebarTypography.caption(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Directory

    @ViewBuilder
    private var directorySection: some View {
        GitSectionHeader(
            title: "DIRECTORY", count: 0, isCollapsed: $directoryCollapsed, actions: []
        )
        if !directoryCollapsed {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.rootPath)
                    .font(SidebarTypography.secondary(design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.rootPath)
                    .contextMenu {
                        Button("Copy Path") { copyPath() }
                    }

                HStack(spacing: 4) {
                    actionButton("Finder", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: model.rootPath)]
                        )
                    }
                    if let vsCode = Self.vsCodeURL {
                        actionButton("VS Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                            NSWorkspace.shared.open(
                                [URL(fileURLWithPath: model.rootPath)],
                                withApplicationAt: vsCode,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                        }
                    }
                    actionButton("Copy", systemImage: "doc.on.doc") {
                        copyPath()
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.rootPath, forType: .string)
    }

    private func actionButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(SidebarTypography.micro())
                Text(title)
                    .font(SidebarTypography.caption(.medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title == "Copy" ? "Copy Path" : "Open in \(title)")
    }

    // MARK: Processes

    @ViewBuilder
    private var packageScriptsSection: some View {
        GitSectionHeader(
            title: "NPM SCRIPTS",
            count: model.packageScripts.count,
            isCollapsed: $packageScriptsCollapsed,
            actions: []
        )
        if !packageScriptsCollapsed {
            if model.packageScripts.isEmpty {
                emptyRow("No package scripts in package.json")
            } else {
                ForEach(model.packageScripts) { script in
                    Button {
                        runPackageScript(script.name)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill")
                                .font(SidebarTypography.micro())
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 12)
                            Text(script.name)
                                .font(SidebarTypography.body(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help(script.command)
                }
            }
        }
    }

    // MARK: Processes

    @ViewBuilder
    private var processesSection: some View {
        GitSectionHeader(
            title: "PROCESSES",
            count: model.processes.count,
            isCollapsed: $processesCollapsed,
            actions: []
        )
        if !processesCollapsed {
            if model.processes.isEmpty {
                emptyRow("No running processes")
            } else {
                ForEach(model.processes) { process in
                    InfoProcessRow(process: process) { force in
                        model.kill(process.pid, force: force)
                    }
                }
            }
        }
    }

    // MARK: Ports

    @ViewBuilder
    private var portsSection: some View {
        GitSectionHeader(
            title: "PORTS",
            count: model.ports.count,
            isCollapsed: $portsCollapsed,
            actions: []
        )
        if !portsCollapsed {
            if model.ports.isEmpty {
                emptyRow("No listening ports")
            } else {
                ForEach(model.ports) { port in
                    InfoPortRow(port: port) { force in
                        model.kill(port.pid, force: force)
                    }
                }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(SidebarTypography.secondary())
            // 空状态提示不再使用过浅的三级文字色。
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct InfoProcessRow: View {
    let process: SessionInfoModel.ProcessItem
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                .frame(width: 5, height: 5)
            Text(process.name)
                .font(SidebarTypography.body())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .help(process.executable)
            Text(String(process.pid))
                .font(SidebarTypography.caption(design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    kill(false)
                } label: {
                    Image(systemName: "xmark")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Terminate Process")
            } else {
                Text(String(format: "%.0f%% · %@", process.cpu, process.memoryLabel))
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        // Fixed height so the taller hover button doesn't grow the row.
        .frame(height: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Terminate") { kill(false) }
            Button("Force Kill") { kill(true) }
            Divider()
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(process.pid)", forType: .string)
            }
            Button("Copy Executable Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.executable, forType: .string)
            }
        }
    }
}

private struct InfoPortRow: View {
    let port: SessionInfoModel.PortItem
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    private var urlString: String { "http://localhost:\(port.port)" }

    var body: some View {
        Button {
            if let url = port.url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "network")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .frame(width: 12)
                Text(String(port.port))
                    .font(SidebarTypography.body(.medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Text(port.processName)
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovering {
                    Image(systemName: "arrow.up.forward")
                        .font(SidebarTypography.micro())
                        .foregroundStyle(.tertiary)
                }
            }
            // Fixed height to match the other sidebar rows.
            .frame(height: SidebarTypography.rowMinHeight)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Open \(urlString)")
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Browser") {
                if let url = port.url {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }
            Divider()
            Button("Kill Process (\(port.processName))") { kill(false) }
        }
    }
}

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
