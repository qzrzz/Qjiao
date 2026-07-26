//
//  RightSidebarView.swift
//  kero
//

import AppKit
import Combine
import QuickLook
import QuickLookUI
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
/// button or ⇧⌘B. 上半区 Start / Project / Info / Files / CWD / Git；
/// 下半区 System / Note；中间可拖分割。
struct RightSidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var fileTree = FileTreeModel()
    @StateObject private var git = GitStatusModel()
    /// 项目根路径 + npm scripts（Project tab）。
    @StateObject private var projectInfo = ProjectPanelModel()
    /// 当前终端 cwd / 进程 / 端口（Info tab）。
    @StateObject private var sessionInfo = SessionInfoModel()
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
    private static let bottomBarHeight: CGFloat = 34
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
                    .clipped()
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
        case .start, .project:
            if let project = manager.selectedProject {
                ProjectPanel(
                    model: projectInfo,
                    project: project,
                    manager: manager,
                    runPackageScript: { name, mode in
                        manager.runPackageScript(
                            name, mode: mode, directory: projectInfo.rootPath
                        )
                    },
                    openPackageJSON: {
                        let root = projectInfo.rootPath
                        guard !root.isEmpty else { return }
                        manager.openFile(
                            (root as NSString).appendingPathComponent("package.json")
                        )
                    },
                    runLaunchCommand: { manager.runLaunchCommand($0) },
                    runAllLaunchCommands: { manager.runAllLaunchCommands() }
                )
            }
        case .info:
            SessionInfoPanel(
                model: sessionInfo,
                manager: manager,
                runPackageScript: { name, mode in
                    manager.runPackageScript(
                        name, mode: mode, directory: sessionInfo.cwdPath
                    )
                },
                openPackageJSON: {
                    let root = sessionInfo.cwdPath
                    guard !root.isEmpty else { return }
                    manager.openFile(
                        (root as NSString).appendingPathComponent("package.json")
                    )
                }
            )
        case .files:
            FileTreePanel(
                manager: manager,
                model: fileTree,
                session: manager.selectedSession,
                currentFilePath: openFilePath,
                openFile: { manager.openFile($0) },
                openToSide: { manager.openFileToSide($0) },
                onRename: { manager.fileRenamed(from: $0, to: $1) }
            )
        case .cwd:
            FileTreePanel(
                manager: manager,
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

    /// 下半区比例是否处于拖拽贴底吸附的极小高度 (>= 0.90)
    private var isTopFractionAtBottomLimit: Bool {
        topFraction >= 0.90
    }

    private var bottomTabBar: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(RightBottomPanel.allCases) { tab in
                bottomTabButton(tab)
            }
            Spacer(minLength: 0)
            bottomCollapseButton
        }
        .padding(.horizontal, 8)
        .offset(y: -1.5)
        .frame(height: Self.bottomBarHeight)
        .background { WindowDragArea() }
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
                .frame(width: 24, height: 24)
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
                isActive: isActive,
                availableWidth: width
            )
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isActive ? "Selected" : "Not selected")
    }

    /// 底部 Tabs 展开/收起切换逻辑：
    /// - 若处于收起状态 (`bottomCollapsed == true`)：展开下半区；若记录的比例处于拖拽贴底吸附值，则自动恢复为默认高度 (70%)，否则保留用户自定义记录高度。
    /// - 若处于展开状态 (`bottomCollapsed == false`)：收起下半区 (`bottomCollapsed = true`)。
    private func toggleBottomCollapsed() {
        if bottomCollapsed {
            bottomCollapsed = false
            if isTopFractionAtBottomLimit {
                topFraction = Self.defaultTopFraction
            }
        } else {
            bottomCollapsed = true
        }
    }

    private var tabBar: some View {
        GeometryReader { geo in
            let availableW = geo.size.width
            ZStack(alignment: .leading) {
                // 右侧顶栏未被面板切换按钮占用的区域可拖动窗口。
                WindowDragArea()

                HStack(spacing: availableW < 250 ? 2 : 4) {
                    tabButton(.project, systemImage: "shippingbox", title: "Project", help: "Project", availableWidth: availableW)
                    tabButton(.info, systemImage: "info.circle", title: "Info", help: "Info (⇧⌘I)", availableWidth: availableW)
                    tabButton(.files, systemImage: "folder", title: "Files", help: "Files (⇧⌘E)", availableWidth: availableW)
                    if showsCWD {
                        tabButton(.cwd, systemImage: "terminal", title: "CWD", help: "CWD", availableWidth: availableW)
                    }
                    tabButton(.git, systemImage: "arrow.triangle.branch", title: "Git", help: "Git (⇧⌘G)", availableWidth: availableW)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
        }
        .frame(height: 41)
    }

    private func tabButton(
        _ panel: RightPanel,
        systemImage: String,
        title: String,
        help: String,
        availableWidth: CGFloat
    ) -> some View {
        let isActive = manager.panelTab == panel
        return Button {
            manager.panelTab = panel
        } label: {
            sidebarTabLabel(
                systemImage: systemImage,
                title: title,
                isActive: isActive,
                availableWidth: availableWidth
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Selected" : "Not selected")
    }

    /// 上/下半区共用的 tab 样式：根据可用宽度响应式展缩文本；字重始终 medium，
    /// 选中只改颜色和背景，避免 regular↔medium 宽度变化导致抖动。
    private func sidebarTabLabel(
        systemImage: String,
        title: String,
        isActive: Bool,
        availableWidth: CGFloat = 340
    ) -> some View {
        // 宽屏 (>=340): 全部显示 Icon + Title;
        // 中屏 (250~340): 仅选中项显示 Icon + Title，未选中项仅显示 Icon;
        // 窄屏 (<250): 全部仅显示 Icon (选中项带高亮框)。
        let showTitle: Bool = {
            if availableWidth >= 340 {
                return true
            } else if availableWidth >= 250 {
                return isActive
            } else {
                return false
            }
        }()

        return HStack(alignment: .center, spacing: 4) {
            Image(systemName: systemImage)
                .font(SidebarTypography.caption(.medium))
                .frame(width: 14, height: 14)
            if showTitle {
                Text(title)
                    .font(SidebarTypography.secondary(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(.horizontal, showTitle ? 7 : 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.09) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func syncModels() {
        manager.checkPackageScriptStatus()
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
        case .project:
            // 项目根 + 全 session shell 的进程/端口并集。
            let root = projectRoot(for: project, fallback: session)
            let shellPids = project.sessions.compactMap(\.shellPid)
            projectInfo.sync(root: root, shellPids: shellPids)
            manager.updatePackageScriptPorts(with: projectInfo.ports)
        case .info:
            // 当前终端 cwd 的 scripts + 本 session 进程/端口。
            sessionInfo.sync(
                cwd: session.currentDirectoryPath,
                shellName: session.shellName,
                shellPid: session.shellPid
            )
        case .files: fileTree.sync(root: projectRoot(for: project, fallback: session))
        case .cwd: fileTree.sync(root: session.currentDirectoryPath)
        case .git: git.sync(root: session.currentDirectoryPath)
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
    var titleFont: Font = SidebarTypography.title()
    var subtitleTruncationMode: Text.TruncationMode = .head

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(titleFont)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SidebarTypography.caption())
                    // PID 作为辅助信息显示，但在浅色模式下保持足够对比度。
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(subtitleTruncationMode)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quick Look Manager

/// 系统原生 Quick Look (快速预览) 管理类，支持 QLPreviewPanel 弹窗与数据源绑定。
@MainActor
final class QuickLookManager: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
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

private struct FileTreePanel: View {
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

            if isFilterActive {
                filterBarView
            }

            ScrollViewReader { proxy in
                ScrollView {
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
                }
                .focused($isTreeFocused)
                .focusable(true)
                .focusEffectDisabled()
                .onAppear {
                    scrollProxy = proxy
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
                session?.sendCommand("cd " + shellQuote(only.path) + "\n")
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
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.repoRoot)])
            } label: {
                Label("Reveal Repository in Finder", systemImage: "finder")
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
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
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
                    // 数量紧跟标题，不再右对齐到行尾。
                    if count > 0 {
                        Text("\(count)")
                            .font(SidebarTypography.micro())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            Spacer(minLength: 0)

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
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
        } label: {
            Label("Reveal in Finder", systemImage: "finder")
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

// MARK: - Project / Info 共用

/// 展开分组内容相对标题的左边距。
private enum SidebarPanelMetrics {
    static let expandedContentLeading: CGFloat = 12
}

/// 空 → 收起；0→有内容 → 展开；其余保持用户选择。
private func sidebarAutoCollapse(
    oldCount: Int, newCount: Int, isCollapsed: Binding<Bool>
) {
    if newCount == 0 {
        isCollapsed.wrappedValue = true
    } else if oldCount == 0 {
        isCollapsed.wrappedValue = false
    }
}

private func sidebarEmptyRow(_ text: String) -> some View {
    Text(text)
        .font(SidebarTypography.secondary())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
}

/// 路径区：展示绝对路径 + Finder / 代码编辑器 / Copy。
private struct PathDirectorySection: View {
    let path: String
    @Binding var isCollapsed: Bool
    /// 分组标题，如 "PROJECT" / "CWD"。
    var sectionTitle: String = "DIRECTORY"

    /// 订阅编辑器与 AI 工具注册表，首选变更时自动刷新按钮。
    @ObservedObject private var registry = CodeEditorRegistry.shared
    @ObservedObject private var aiRegistry = AIToolRegistry.shared

    var body: some View {
        GitSectionHeader(
            title: sectionTitle, count: 0, isCollapsed: $isCollapsed, actions: []
        )
        if !isCollapsed {
            VStack(alignment: .leading, spacing: 8) {
                Text(path.isEmpty ? "—" : path)
                    .font(SidebarTypography.secondary(design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(path)
                    .contextMenu {
                        Button("Copy Path") { copyPath() }
                            .disabled(path.isEmpty)
                    }

                HStack(spacing: 4) {
                    pathActionButton("Finder", systemImage: "finder") {
                        guard !path.isEmpty else { return }
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    }
                    .disabled(path.isEmpty)
                    // 若检测到已安装的代码编辑器则显示打开按钮。
                    if let preferred = registry.preferredEditor {
                        // 编辑器按钮：使用应用真实图标。
                        Button {
                            registry.open(path: path)
                        } label: {
                            HStack(spacing: 3) {
                                CodeEditorIcon(editor: preferred)
                                Text(preferred.displayName)
                                    .font(SidebarTypography.caption(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(path.isEmpty)
                        .help("Open in \(preferred.displayName)")
                        // 多个编辑器时右键菜单切换默认。
                        .contextMenu {
                            if registry.installedEditors.count > 1 {
                                ForEach(registry.installedEditors) { editor in
                                    Button {
                                        registry.preferredBundleId = editor.bundleId
                                        registry.open(path: path, with: editor)
                                    } label: {
                                        if let icon = editor.iconImage(size: 16) {
                                            Label {
                                                Text(editor.displayName)
                                            } icon: {
                                                Image(nsImage: icon)
                                            }
                                        } else {
                                            Label(editor.displayName, systemImage: editor.symbolName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // 若检测到已安装的 AI 工具则显示打开按钮。
                    if let preferredAI = aiRegistry.preferredTool {
                        Button {
                            aiRegistry.open(path: path, with: preferredAI)
                        } label: {
                            HStack(spacing: 3) {
                                AIToolIcon(tool: preferredAI, size: 12)
                                Text(preferredAI.displayName)
                                    .font(SidebarTypography.caption(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(path.isEmpty)
                        .help("Open in \(preferredAI.displayName)")
                        .contextMenu {
                            if aiRegistry.installedTools.count > 1 {
                                ForEach(aiRegistry.installedTools) { tool in
                                    Button {
                                        aiRegistry.preferredToolId = tool.id
                                        aiRegistry.open(path: path, with: tool)
                                    } label: {
                                        if let icon = tool.iconImage(size: 16) {
                                            Label {
                                                Text(tool.displayName)
                                            } icon: {
                                                Image(nsImage: icon)
                                            }
                                        } else {
                                            Label(tool.displayName, systemImage: tool.symbolName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    pathActionButton("Copy", systemImage: "doc.on.doc") {
                        copyPath()
                    }
                    .disabled(path.isEmpty)
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
            .padding(.trailing, 6)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    private func copyPath() {
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func pathActionButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(SidebarTypography.micro())
                Text(title)
                    .font(SidebarTypography.caption(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title == "Copy" ? "Copy Path" : "Open in \(title)")
    }
}

// MARK: - Package scripts / processes 共用区块

private func formatScriptDuration(_ duration: TimeInterval) -> String {
    if duration < 1.0 {
        let ms = duration * 1000.0
        let formatted = String(format: "%.1fms", ms)
        return formatted.replacingOccurrences(of: ".0ms", with: "ms")
    } else if duration < 60.0 {
        let formatted = String(format: "%.1fs", duration)
        return formatted.replacingOccurrences(of: ".0s", with: "s")
    } else {
        let min = Int(duration) / 60
        let sec = duration.truncatingRemainder(dividingBy: 60)
        let formattedSec = String(format: "%.1fs", sec)
        let cleanSec = formattedSec.replacingOccurrences(of: ".0s", with: "s")
        return "\(min)m\(cleanSec)"
    }
}

/// npm scripts 列表；scriptsRoot 仅用于空状态文案区分。
private struct PackageScriptsSection: View {
    let scripts: [SidebarProbe.PackageScript]
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runPackageScript: (String, TerminalManager.PackageScriptRunMode) -> Void
    let stopPackageScript: (String) -> Void
    let restartPackageScript: (String, TerminalManager.PackageScriptRunMode) -> Void
    let openPackageJSON: () -> Void

    @State private var selectedScriptName: String? = nil

    var body: some View {
        GitSectionHeader(
            title: "NPM SCRIPTS",
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if scripts.isEmpty {
                    sidebarEmptyRow("No package scripts in package.json")
                } else {
                    ForEach(scripts) { script in
                        PackageScriptRow(
                            script: script,
                            record: records[script.name],
                            isSelected: selectedScriptName == script.name,
                            onSelect: {
                                selectedScriptName = script.name
                            },
                            onDoubleClick: {
                                selectedScriptName = script.name
                                runPackageScript(script.name, .normal)
                            },
                            run: { mode in
                                selectedScriptName = script.name
                                runPackageScript(script.name, mode)
                            },
                            stop: {
                                stopPackageScript(script.name)
                            },
                            restart: { mode in
                                selectedScriptName = script.name
                                restartPackageScript(script.name, mode)
                            },
                            editPackageJSON: openPackageJSON
                        )
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

/// npm script 行：支持运行/停止/重新运行状态追踪，展示上一次运行耗时与明显 Hover 控制。
private struct PackageScriptRow: View {
    let script: SidebarProbe.PackageScript
    let record: TerminalManager.PackageScriptExecutionRecord?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let run: (TerminalManager.PackageScriptRunMode) -> Void
    let stop: () -> Void
    let restart: (TerminalManager.PackageScriptRunMode) -> Void
    let editPackageJSON: () -> Void

    @State private var isHoveringRow = false
    @State private var isHoveringActionBtn = false
    @State private var isHoveringRestartBtn = false
    @State private var isHoveringBrowserBtn = false

    private var status: TerminalManager.PackageScriptStatus {
        record?.status ?? .idle
    }

    private var boundPort: Int? {
        record?.boundPort
    }

    var body: some View {
        HStack(spacing: 6) {
            actionButton

            Text(script.name)
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(isSelected ? .primary : (isHoveringRow ? .primary : .secondary))
                .lineLimit(1)

            Spacer(minLength: 0)

            rightContent
        }
        .frame(height: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isSelected
                    ? Color.primary.opacity(0.09)
                    : (isHoveringRow ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { isHoveringRow = $0 }
        .onTapGesture(count: 2) {
            guard status == .idle else { return }
            onDoubleClick()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .help(script.command)
        .contextMenu {
            if let port = boundPort {
                Button("Open http://localhost:\(port) in Browser") {
                    if let url = URL(string: "http://localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
            }
            if status == .running {
                Button("Stop") { stop() }
                Button("Restart") { restart(.normal) }
            } else {
                Button("Run") { run(.normal) }
            }
            Button("Edit package.json") { editPackageJSON() }
            Divider()
            Button("Run with time") { run(.withTime) }
            Button("Run with --inspect") { run(.withInspect) }
            Button("Run with --prof") { run(.withProf) }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .idle:
            Button {
                run(.normal)
            } label: {
                Image(systemName: "play.fill")
                    .font(SidebarTypography.micro(.semibold))
                    .foregroundStyle(isHoveringActionBtn ? Color.white : Color(nsColor: Theme.cursor))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHoveringActionBtn ? Color(nsColor: Theme.cursor) : (isHoveringRow ? Color.primary.opacity(0.08) : Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringActionBtn = $0 }

        case .running:
            Button {
                stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(SidebarTypography.micro(.semibold))
                    .foregroundStyle(isHoveringActionBtn ? Color.white : Color.red)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHoveringActionBtn ? Color.red : Color.red.opacity(0.12))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringActionBtn = $0 }

        case .stopping:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        HStack(spacing: 4) {
            if let port = boundPort {
                Button {
                    if let url = URL(string: "http://localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "globe")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(isHoveringBrowserBtn ? Color.white : Color(nsColor: Theme.cursor))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isHoveringBrowserBtn ? Color(nsColor: Theme.cursor) : Color(nsColor: Theme.cursor).opacity(0.12))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringBrowserBtn = $0 }
                .help("Open http://localhost:\(port) in browser")
            }

            switch status {
            case .idle:
                if let duration = record?.lastDuration {
                    Text(formatScriptDuration(duration))
                        .font(SidebarTypography.micro(.medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 2)
                }

            case .running:
                Button {
                    restart(.normal)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(isHoveringRestartBtn ? Color.white : Color.secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isHoveringRestartBtn ? Color.primary.opacity(0.8) : (isHoveringRow ? Color.primary.opacity(0.08) : Color.clear))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringRestartBtn = $0 }

            case .stopping:
                Text("Stopping...")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct GradleTasksSection: View {
    let scripts: [UniversalProjectScript]
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void
    let stopScript: (String) -> Void
    let restartScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void

    @State private var selectedScriptName: String? = nil

    var body: some View {
        GitSectionHeader(
            title: "GRADLE TASKS",
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if scripts.isEmpty {
                    sidebarEmptyRow("No Gradle tasks found")
                } else {
                    ForEach(scripts) { script in
                        UniversalScriptRow(
                            script: script,
                            record: records[script.name],
                            isSelected: selectedScriptName == script.name,
                            onSelect: {
                                selectedScriptName = script.name
                            },
                            onDoubleClick: {
                                selectedScriptName = script.name
                                runScript(script, .normal)
                            },
                            run: { mode in
                                selectedScriptName = script.name
                                runScript(script, mode)
                            },
                            stop: {
                                stopScript(script.name)
                            },
                            restart: { mode in
                                selectedScriptName = script.name
                                restartScript(script, mode)
                            }
                        )
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

private struct JustTasksSection: View {
    let scripts: [UniversalProjectScript]
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void
    let stopScript: (String) -> Void
    let restartScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void

    @State private var selectedScriptName: String? = nil

    private var isJustInstalled: Bool {
        JustToolChecker.isJustInstalled
    }

    var body: some View {
        GitSectionHeader(
            title: "JUSTFILE",
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if !isJustInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(SidebarTypography.micro())
                            .foregroundStyle(.orange)
                        Text("Install just to run tasks")
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                if scripts.isEmpty {
                    sidebarEmptyRow("No tasks in Justfile")
                } else {
                    ForEach(scripts) { script in
                        UniversalScriptRow(
                            script: script,
                            record: records[script.name],
                            isSelected: selectedScriptName == script.name,
                            onSelect: {
                                selectedScriptName = script.name
                            },
                            onDoubleClick: {
                                selectedScriptName = script.name
                                runScript(script, .normal)
                            },
                            run: { mode in
                                selectedScriptName = script.name
                                runScript(script, mode)
                            },
                            stop: {
                                stopScript(script.name)
                            },
                            restart: { mode in
                                selectedScriptName = script.name
                                restartScript(script, mode)
                            }
                        )
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

private struct CargoTasksSection: View {
    let scripts: [UniversalProjectScript]
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void
    let stopScript: (String) -> Void
    let restartScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void

    @State private var selectedScriptName: String? = nil

    private var isCargoInstalled: Bool {
        CargoToolChecker.isCargoInstalled
    }

    var body: some View {
        GitSectionHeader(
            title: "CARGO",
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if !isCargoInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(SidebarTypography.micro())
                            .foregroundStyle(.orange)
                        Text("Install Rust/Cargo to run tasks")
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                if scripts.isEmpty {
                    sidebarEmptyRow("No Cargo tasks")
                } else {
                    ForEach(scripts) { script in
                        UniversalScriptRow(
                            script: script,
                            record: records[script.name],
                            isSelected: selectedScriptName == script.name,
                            onSelect: {
                                selectedScriptName = script.name
                            },
                            onDoubleClick: {
                                selectedScriptName = script.name
                                runScript(script, .normal)
                            },
                            run: { mode in
                                selectedScriptName = script.name
                                runScript(script, mode)
                            },
                            stop: {
                                stopScript(script.name)
                            },
                            restart: { mode in
                                selectedScriptName = script.name
                                restartScript(script, mode)
                            }
                        )
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

private struct CMakeTasksSection: View {
    let scripts: [UniversalProjectScript]
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void
    let stopScript: (String) -> Void
    let restartScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void

    @State private var selectedScriptName: String? = nil

    private var isCMakeInstalled: Bool {
        CMakeToolChecker.isCMakeInstalled
    }

    var body: some View {
        GitSectionHeader(
            title: "CMAKE TASKS",
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if !isCMakeInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(SidebarTypography.micro())
                            .foregroundStyle(.orange)
                        Text("Install CMake to run tasks")
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                if scripts.isEmpty {
                    sidebarEmptyRow("No CMake tasks")
                } else {
                    ForEach(scripts) { script in
                        UniversalScriptRow(
                            script: script,
                            record: records[script.name],
                            isSelected: selectedScriptName == script.name,
                            onSelect: {
                                selectedScriptName = script.name
                            },
                            onDoubleClick: {
                                selectedScriptName = script.name
                                runScript(script, .normal)
                            },
                            run: { mode in
                                selectedScriptName = script.name
                                runScript(script, mode)
                            },
                            stop: {
                                stopScript(script.name)
                            },
                            restart: { mode in
                                selectedScriptName = script.name
                                restartScript(script, mode)
                            }
                        )
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

private struct MakefileTasksSection: View {
    let scripts: [UniversalProjectScript]
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void
    let stopScript: (String) -> Void
    let restartScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void

    @State private var selectedScriptName: String? = nil

    private var isMakeInstalled: Bool {
        MakeToolChecker.isMakeInstalled
    }

    var body: some View {
        GitSectionHeader(
            title: "MAKEFILE",
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if !isMakeInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(SidebarTypography.micro())
                            .foregroundStyle(.orange)
                        Text("Install make to run tasks")
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                if scripts.isEmpty {
                    sidebarEmptyRow("No Makefile tasks")
                } else {
                    ForEach(scripts) { script in
                        UniversalScriptRow(
                            script: script,
                            record: records[script.name],
                            isSelected: selectedScriptName == script.name,
                            onSelect: {
                                selectedScriptName = script.name
                            },
                            onDoubleClick: {
                                selectedScriptName = script.name
                                runScript(script, .normal)
                            },
                            run: { mode in
                                selectedScriptName = script.name
                                runScript(script, mode)
                            },
                            stop: {
                                stopScript(script.name)
                            },
                            restart: { mode in
                                selectedScriptName = script.name
                                restartScript(script, mode)
                            }
                        )
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

/// 通用 Project Script 行展示组件 (支持 Gradle, Cargo, uv, Just 等)
private struct UniversalScriptRow: View {
    let script: UniversalProjectScript
    let record: TerminalManager.PackageScriptExecutionRecord?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let run: (UniversalScriptRunMode) -> Void
    let stop: () -> Void
    let restart: (UniversalScriptRunMode) -> Void

    @State private var isHoveringRow = false
    @State private var isHoveringActionBtn = false
    @State private var isHoveringRestartBtn = false
    @State private var isHoveringBrowserBtn = false

    private var status: TerminalManager.PackageScriptStatus {
        record?.status ?? .idle
    }

    private var boundPort: Int? {
        record?.boundPort
    }

    var body: some View {
        HStack(spacing: 6) {
            actionButton

            VStack(alignment: .leading, spacing: 1) {
                Text(script.name)
                    .font(SidebarTypography.secondary(.medium))
                    .foregroundStyle(isSelected ? .primary : (isHoveringRow ? .primary : .secondary))
                    .lineLimit(1)

                if !script.depends.isEmpty {
                    Text(" └─ depends on \(script.depends.joined(separator: ", "))")
                        .font(SidebarTypography.micro(.regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let desc = script.scriptDescription, !desc.isEmpty, desc != script.name && desc != "cargo \(script.name)" {
                    Text(" └─ \(desc)")
                        .font(SidebarTypography.micro(.regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            rightContent
        }
        .frame(height: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isSelected
                    ? Color.primary.opacity(0.09)
                    : (isHoveringRow ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { isHoveringRow = $0 }
        .onTapGesture(count: 2) {
            guard status == .idle else { return }
            onDoubleClick()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .help(script.category.buildExecutionCommand(scriptName: script.name, rawCommand: script.command))
        .contextMenu {
            if let port = boundPort {
                Button("Open http://localhost:\(port) in Browser") {
                    if let url = URL(string: "http://localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
            }
            if status == .running {
                Button("Stop") { stop() }
                Button("Restart") { restart(.normal) }
            } else {
                Button("Run") { run(.normal) }
            }
            Divider()
            Button("Run with time") { run(.withTime) }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .idle:
            Button {
                run(.normal)
            } label: {
                Image(systemName: "play.fill")
                    .font(SidebarTypography.micro(.semibold))
                    .foregroundStyle(isHoveringActionBtn ? Color.white : Color(nsColor: Theme.cursor))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHoveringActionBtn ? Color(nsColor: Theme.cursor) : (isHoveringRow ? Color.primary.opacity(0.08) : Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringActionBtn = $0 }

        case .running:
            Button {
                stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(SidebarTypography.micro(.semibold))
                    .foregroundStyle(isHoveringActionBtn ? Color.white : Color.red)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHoveringActionBtn ? Color.red : Color.red.opacity(0.12))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringActionBtn = $0 }

        case .stopping:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        HStack(spacing: 4) {
            if let port = boundPort {
                Button {
                    if let url = URL(string: "http://localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "globe")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(isHoveringBrowserBtn ? Color.white : Color(nsColor: Theme.cursor))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isHoveringBrowserBtn ? Color(nsColor: Theme.cursor) : Color(nsColor: Theme.cursor).opacity(0.12))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringBrowserBtn = $0 }
                .help("Open http://localhost:\(port) in browser")
            }

            switch status {
            case .idle:
                if let duration = record?.lastDuration {
                    Text(formatScriptDuration(duration))
                        .font(SidebarTypography.micro(.medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 2)
                }

            case .running:
                Button {
                    restart(.normal)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(isHoveringRestartBtn ? Color.white : Color.secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isHoveringRestartBtn ? Color.primary.opacity(0.8) : (isHoveringRow ? Color.primary.opacity(0.08) : Color.clear))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringRestartBtn = $0 }

            case .stopping:
                Text("Stopping...")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ProcessesSection: View {
    let processes: [SidebarProbe.ProcessItem]
    @Binding var isCollapsed: Bool
    let kill: (_ pid: pid_t, _ force: Bool) -> Void

    var body: some View {
        GitSectionHeader(
            title: "PROCESSES",
            count: processes.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if processes.isEmpty {
                    sidebarEmptyRow("No running processes")
                } else {
                    ForEach(processes) { process in
                        InfoProcessRow(process: process) { force in
                            kill(process.pid, force)
                        }
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

private struct PortsSection: View {
    let ports: [SidebarProbe.PortItem]
    @Binding var isCollapsed: Bool
    let kill: (_ pid: pid_t, _ force: Bool) -> Void

    var body: some View {
        GitSectionHeader(
            title: "PORTS",
            count: ports.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if ports.isEmpty {
                    sidebarEmptyRow("No listening ports")
                } else {
                    ForEach(ports) { port in
                        InfoPortRow(port: port) { force in
                            kill(port.pid, force)
                        }
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

// MARK: - Project panel

/// Project launchers 区块：在 ProjectPanel 中作为 LAUNCHERS 分组展示
private struct LaunchersSection: View {
    @ObservedObject var project: Project
    @Binding var isCollapsed: Bool
    let runCommand: (ProjectLaunchCommand) -> Void
    let runAllCommands: () -> Void

    @State private var expandedCommandID: UUID?
    @State private var draggedCommandID: UUID?
    @State private var dropTargetCommandID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            GitSectionHeader(
                title: "LAUNCHERS",
                count: project.launchCommands.count,
                isCollapsed: $isCollapsed,
                actions: [
                    GitSectionHeader.Action(
                        systemImage: "play.fill",
                        help: "Run all launchers in order",
                        perform: runAllCommands
                    ),
                    GitSectionHeader.Action(
                        systemImage: "plus",
                        help: "Add Launcher",
                        perform: addCommand
                    )
                ],
                actionsDisabled: project.launchCommands.isEmpty
            )

            if !isCollapsed {
                if project.launchCommands.isEmpty {
                    emptyView
                } else {
                    commandList
                }
            }
        }
        .onChange(of: project.launchCommands.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $isCollapsed
            )
        }
    }

    private var emptyView: some View {
        HStack(spacing: 6) {
            Text("No launchers")
                .font(SidebarTypography.caption())
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Add Launcher") {
                addCommand()
            }
            .buttonStyle(.plain)
            .font(SidebarTypography.caption(.medium))
            .foregroundStyle(Color(nsColor: Theme.cursor))
        }
        .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }

    private var commandList: some View {
        VStack(spacing: 1) {
            ForEach(Array(project.launchCommands.enumerated()), id: \.element.id) { index, command in
                VStack(spacing: 0) {
                    StartCommandRow(
                        command: command,
                        isExpanded: expandedCommandID == command.id,
                        isDropTarget: dropTargetCommandID == command.id,
                        run: { runCommand(command) },
                        toggleExpanded: { toggleExpanded(command.id) },
                        startDrag: {
                            draggedCommandID = command.id
                            return NSItemProvider(object: command.id.uuidString as NSString)
                        }
                    )
                    .onDrop(
                        of: [.plainText],
                        delegate: StartCommandDropDelegate(
                            targetID: command.id,
                            project: project,
                            draggedCommandID: $draggedCommandID,
                            dropTargetCommandID: $dropTargetCommandID
                        )
                    )

                    if expandedCommandID == command.id {
                        StartCommandInlineEditor(
                            command: binding(for: command.id),
                            delete: { delete(command.id) }
                        )
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                    }
                }
            }
        }
        .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        .padding(.trailing, 4)
    }

    private func addCommand() {
        if isCollapsed { isCollapsed = false }
        let command = ProjectLaunchCommand()
        project.addLaunchCommand(command)
        expandedCommandID = command.id
    }

    private func toggleExpanded(_ id: UUID) {
        expandedCommandID = expandedCommandID == id ? nil : id
    }

    private func delete(_ id: UUID) {
        guard let index = project.launchCommands.firstIndex(where: { $0.id == id }) else { return }
        if expandedCommandID == id { expandedCommandID = nil }
        project.removeLaunchCommands(at: IndexSet(integer: index))
    }

    private func binding(for id: UUID) -> Binding<ProjectLaunchCommand> {
        Binding {
            project.launchCommands.first(where: { $0.id == id }) ?? ProjectLaunchCommand(id: id)
        } set: { updated in
            project.updateLaunchCommand(updated)
        }
    }
}

/// 项目根路径 + 根 package.json scripts + 全 session 进程/端口并集。
private struct ProjectPanel: View {
    @ObservedObject var model: ProjectPanelModel
    @ObservedObject var project: Project
    @ObservedObject var manager: TerminalManager
    let runPackageScript: (String, TerminalManager.PackageScriptRunMode) -> Void
    let openPackageJSON: () -> Void
    let runLaunchCommand: (ProjectLaunchCommand) -> Void
    let runAllLaunchCommands: () -> Void

    @State private var launchersCollapsed = false
    @State private var packageScriptsCollapsed = false
    @State private var gradleTasksCollapsed = false
    @State private var justTasksCollapsed = false
    @State private var cargoTasksCollapsed = false
    @State private var cmakeTasksCollapsed = false
    @State private var makefileTasksCollapsed = false
    @State private var processesCollapsed = false
    @State private var portsCollapsed = false

    private var projectTitle: String {
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        guard !model.rootPath.isEmpty else { return "Project" }
        return (model.rootPath as NSString).lastPathComponent
    }

    private var headerSubtitle: String? {
        if let desc = project.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc
        }
        let n = model.sessionShellCount
        guard n > 0 else { return nil }
        return n == 1 ? "1 session" : "\(n) sessions"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    TopToolsOpenSection(path: model.rootPath, manager: manager)
                    LaunchersSection(
                        project: project,
                        isCollapsed: $launchersCollapsed,
                        runCommand: runLaunchCommand,
                        runAllCommands: runAllLaunchCommands
                    )
                    PackageScriptsSection(
                        scripts: model.packageScripts,
                        records: manager.packageScriptRecords,
                        isCollapsed: $packageScriptsCollapsed,
                        runPackageScript: runPackageScript,
                        stopPackageScript: { manager.stopPackageScript($0) },
                        restartPackageScript: { manager.restartPackageScript($0, mode: $1) },
                        openPackageJSON: openPackageJSON
                    )
                    if !model.gradleScripts.isEmpty || GradleScriptProvider.isGradleProject(at: model.rootPath) {
                        GradleTasksSection(
                            scripts: model.gradleScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $gradleTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    if !model.justScripts.isEmpty || JustScriptProvider.isJustProject(at: model.rootPath) {
                        JustTasksSection(
                            scripts: model.justScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $justTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    if !model.cargoScripts.isEmpty || CargoScriptProvider.isCargoProject(at: model.rootPath) {
                        CargoTasksSection(
                            scripts: model.cargoScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $cargoTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    if !model.cmakeScripts.isEmpty || CMakeScriptProvider.isCMakeProject(at: model.rootPath) {
                        CMakeTasksSection(
                            scripts: model.cmakeScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $cmakeTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    if !model.makefileScripts.isEmpty || MakefileScriptProvider.isMakefileProject(at: model.rootPath) {
                        MakefileTasksSection(
                            scripts: model.makefileScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $makefileTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    ProcessesSection(
                        processes: model.processes,
                        isCollapsed: $processesCollapsed,
                        kill: { model.kill($0, force: $1) }
                    )
                    PortsSection(
                        ports: model.ports,
                        isCollapsed: $portsCollapsed,
                        kill: { model.kill($0, force: $1) }
                    )
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .onChange(of: model.packageScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $packageScriptsCollapsed
            )
        }
        .onChange(of: model.gradleScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $gradleTasksCollapsed
            )
        }
        .onChange(of: model.justScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $justTasksCollapsed
            )
        }
        .onChange(of: model.cargoScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $cargoTasksCollapsed
            )
        }
        .onChange(of: model.cmakeScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $cmakeTasksCollapsed
            )
        }
        .onChange(of: model.makefileScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $makefileTasksCollapsed
            )
        }
        .onChange(of: model.processes.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $processesCollapsed
            )
        }
        .onChange(of: model.ports.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $portsCollapsed
            )
        }
        .onAppear {
            if model.packageScripts.isEmpty { packageScriptsCollapsed = true }
            if model.gradleScripts.isEmpty && !GradleScriptProvider.isGradleProject(at: model.rootPath) {
                gradleTasksCollapsed = true
            }
            if model.justScripts.isEmpty && !JustScriptProvider.isJustProject(at: model.rootPath) {
                justTasksCollapsed = true
            }
            if model.cargoScripts.isEmpty && !CargoScriptProvider.isCargoProject(at: model.rootPath) {
                cargoTasksCollapsed = true
            }
            if model.cmakeScripts.isEmpty && !CMakeScriptProvider.isCMakeProject(at: model.rootPath) {
                cmakeTasksCollapsed = true
            }
            if model.makefileScripts.isEmpty && !MakefileScriptProvider.isMakefileProject(at: model.rootPath) {
                makefileTasksCollapsed = true
            }
            if model.processes.isEmpty { processesCollapsed = true }
            if model.ports.isEmpty { portsCollapsed = true }
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        switch project.icon {
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(SidebarTypography.listIcon())
                .foregroundStyle(Color(nsColor: Theme.cursor))
                .frame(width: 24, height: 24)
        case .emoji(let emoji):
            Text(emoji)
                .font(SidebarTypography.listEmoji())
                .lineLimit(1)
                .fixedSize()
                .frame(width: 24, height: 24)
        case nil:
            Image(systemName: "shippingbox")
                .font(SidebarTypography.listIcon())
                .foregroundStyle(Color(nsColor: Theme.cursor))
                .frame(width: 24, height: 24)
        }
    }

    private var pathRow: some View {
        HStack(spacing: 6) {
            TextField("", text: .constant(model.rootPath.isEmpty ? "—" : model.rootPath))
                .textFieldStyle(.plain)
                .font(SidebarTypography.caption(design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.rootPath)

            HStack(spacing: 4) {
                Button {
                    guard !model.rootPath.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
                } label: {
                    Image(systemName: "finder")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Open in Finder")
                .disabled(model.rootPath.isEmpty)

                Button {
                    guard !model.rootPath.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.rootPath, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Copy Path")
                .disabled(model.rootPath.isEmpty)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                headerIcon
                PanelHeader(
                    title: projectTitle,
                    subtitle: headerSubtitle,
                    titleFont: SidebarTypography.body(.semibold),
                    subtitleTruncationMode: (project.description != nil && !(project.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) ? .tail : .head
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
            pathRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

/// 显示代码编辑器图标的辅助视图：优先展示应用真实图标，不可用时回退到 SF Symbol。
///
/// 固定以 32×32 物理像素取图（`appIcon()`），再以 `frame(16, 16)` 显示，
/// Retina 2× 屏下正好 1:1 物理像素对应，渲染清晰锐利。
private struct CodeEditorIcon: View {
    let editor: CodeEditor
    var size: CGFloat = 16

    var body: some View {
        if let icon = editor.iconImage(size: size) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            // 应用未安装或图标读取失败时回退到 SF Symbol。
            Image(systemName: editor.symbolName)
                .frame(width: size, height: size)
        }
    }
}

/// 用代码编辑器打开路径的按钮区域。
/// 左半区点击使用默认编辑器打开；右侧下拉箭头展开菜单可切换默认编辑器。
/// 若系统未检测到任何已知编辑器则隐藏整个区域。
private struct CodeEditorOpenButton: View {
    let path: String

    /// 订阅注册表，编辑器列表或首选变化时自动刷新 UI。
    @ObservedObject private var registry = CodeEditorRegistry.shared

    var body: some View {
        // 无任何已安装编辑器时整体隐藏。
        if let preferred = registry.preferredEditor {
            HStack(spacing: 0) {
                // ── 左半：主按钮（用默认编辑器打开）
                Button {
                    registry.open(path: path)
                } label: {
                    HStack(spacing: 6) {
                        CodeEditorIcon(editor: preferred, size: 16)
                        Text(preferred.displayName)
                            .font(SidebarTypography.caption(.medium))
                            .lineLimit(1)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(path.isEmpty)
                .help("在 \(preferred.displayName) 中打开")

                // ── 右侧：下拉切换编辑器（仅在已安装多个时才显示）
                if registry.installedEditors.count > 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 1, height: 14)

                    EditorDropdownNSButton(
                        editors: registry.installedEditors,
                        preferredBundleId: registry.preferredBundleId
                    ) { selected in
                        registry.preferredBundleId = selected.bundleId
                        registry.open(path: path, with: selected)
                    }
                    .frame(width: 22, height: 28)
                    .help("选择代码编辑器")
                } else {
                    Image(systemName: "arrow.up.forward")
                        .font(SidebarTypography.micro())
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 28)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

/// 显示 AI 工具图标的辅助视图：优先展示工具/应用真实图标，不可用时回退到 SF Symbol。
private struct AIToolIcon: View {
    let tool: AITool
    var size: CGFloat = 16

    var body: some View {
        if let icon = tool.iconImage(size: size) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: tool.symbolName)
                .frame(width: size, height: size)
        }
    }
}

/// 用 AI 工具打开路径的按钮区域。
/// 左半区点击使用默认 AI 工具打开；右侧下拉箭头展开菜单可切换首选 AI 工具。
/// 若系统未检测到任何可用 AI 工具则隐藏。
private struct AIToolOpenButton: View {
    let path: String
    var manager: TerminalManager? = nil

    @ObservedObject private var registry = AIToolRegistry.shared

    var body: some View {
        if let preferred = registry.preferredTool {
            HStack(spacing: 0) {
                // 左半：主按钮（用默认 AI 工具打开）
                Button {
                    registry.open(path: path, with: preferred, terminalManager: manager)
                } label: {
                    HStack(spacing: 6) {
                        AIToolIcon(tool: preferred, size: 16)
                        Text(preferred.displayName)
                            .font(SidebarTypography.caption(.medium))
                            .lineLimit(1)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(path.isEmpty)
                .help("在 \(preferred.displayName) 中打开")

                // 右侧：下拉切换 AI 工具（仅在已检测到多个时才显示）
                if registry.installedTools.count > 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 1, height: 14)

                    AIDropdownNSButton(
                        tools: registry.installedTools,
                        preferredToolId: registry.preferredToolId
                    ) { selected in
                        registry.preferredToolId = selected.id
                        registry.open(path: path, with: selected, terminalManager: manager)
                    }
                    .frame(width: 22, height: 28)
                    .help("选择 AI 工具")
                } else {
                    Image(systemName: "arrow.up.forward")
                        .font(SidebarTypography.micro())
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 28)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

/// 原生 NSButton + NSMenu 包装的 AI 工具下拉选择按钮。
private struct AIDropdownNSButton: NSViewRepresentable {
    let tools: [AITool]
    let preferredToolId: String
    let onSelect: (AITool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            button.image = chevron.withSymbolConfiguration(cfg)
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.update(
            tools: tools,
            preferredToolId: preferredToolId,
            onSelect: onSelect
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        private let menu = NSMenu()
        private var tools: [AITool] = []
        private var preferredToolId: String = ""
        private var onSelect: ((AITool) -> Void)?

        override init() {
            super.init()
            menu.autoenablesItems = false
        }

        func update(tools: [AITool], preferredToolId: String, onSelect: @escaping (AITool) -> Void) {
            self.tools = tools
            self.preferredToolId = preferredToolId
            self.onSelect = onSelect
            rebuildMenu()
        }

        private func rebuildMenu() {
            menu.removeAllItems()
            for tool in tools {
                let item = NSMenuItem(
                    title: tool.displayName,
                    action: #selector(selectTool(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.isEnabled = true
                item.representedObject = tool.id
                item.image = tool.iconImage(size: 16)
                item.state = (tool.id == preferredToolId) ? .on : .off
                menu.addItem(item)
            }
        }

        @objc func showMenu(_ sender: NSButton) {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }

        @objc func selectTool(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String,
                  let tool = tools.first(where: { $0.id == id })
            else { return }
            onSelect?(tool)
        }
    }
}

/// 顶部工具打开区域：平铺 Code 编辑器打开按钮与 AI 工具打开按钮。
private struct TopToolsOpenSection: View {
    let path: String
    var manager: TerminalManager? = nil

    @ObservedObject private var editorRegistry = CodeEditorRegistry.shared
    @ObservedObject private var aiRegistry = AIToolRegistry.shared

    var body: some View {
        if editorRegistry.preferredEditor != nil || aiRegistry.preferredTool != nil {
            HStack(spacing: 8) {
                CodeEditorOpenButton(path: path)
                AIToolOpenButton(path: path, manager: manager)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }
}

/// 原生 NSButton + NSMenu 包装的编辑器下拉选择按钮。
///
/// 使用 100% AppKit 原生 NSMenuItem：
/// - 系统原生处理鼠标 hover 高亮与离开，彻底消除自定义 View 的 hover 背景残留 Bug
/// - 原生菜单项不参与 Focus 焦点，消除 Tab 键聚焦框
/// - 配合像素化 NSImage，完美渲染 App 图标与勾选标记
private struct EditorDropdownNSButton: NSViewRepresentable {
    /// 可用编辑器列表。
    let editors: [CodeEditor]
    /// 当前选中编辑器的 Bundle ID。
    let preferredBundleId: String
    /// 用户选择编辑器后的回调。
    let onSelect: (CodeEditor) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        // SF Symbol chevron 作为下拉图标。
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            button.image = chevron.withSymbolConfiguration(cfg)
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        // 每次数据变化时更新 Coordinator 状态并重建菜单。
        context.coordinator.update(
            editors: editors,
            preferredBundleId: preferredBundleId,
            onSelect: onSelect
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // ⚠️ 不标 @MainActor：@objc target-action 由 AppKit 在主线程调用。
    final class Coordinator: NSObject {
        private let menu = NSMenu()
        private var editors: [CodeEditor] = []
        private var preferredBundleId: String = ""
        private var onSelect: ((CodeEditor) -> Void)?

        override init() {
            super.init()
            menu.autoenablesItems = false
        }

        /// 接收来自 SwiftUI 的最新数据并重建菜单。
        func update(editors: [CodeEditor], preferredBundleId: String, onSelect: @escaping (CodeEditor) -> Void) {
            self.editors = editors
            self.preferredBundleId = preferredBundleId
            self.onSelect = onSelect
            rebuildMenu()
        }

        /// 使用 100% AppKit 原生 NSMenuItem 重建菜单项。
        private func rebuildMenu() {
            menu.removeAllItems()
            for editor in editors {
                let item = NSMenuItem(
                    title: editor.displayName,
                    action: #selector(selectEditor(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.isEnabled = true
                item.representedObject = editor.bundleId
                item.image = editor.iconImage(size: 16)
                item.state = (editor.bundleId == preferredBundleId) ? .on : .off
                menu.addItem(item)
            }
        }

        /// 点击 chevron 时在按钮正下方弹出菜单。
        @objc func showMenu(_ sender: NSButton) {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }

        /// 菜单项被点击时调用。
        @objc func selectEditor(_ sender: NSMenuItem) {
            guard let bundleId = sender.representedObject as? String,
                  let editor = editors.first(where: { $0.bundleId == bundleId })
            else { return }
            onSelect?(editor)
        }
    }
}




// MARK: - Info panel（当前终端会话）

/// 当前终端 cwd + cwd 下 scripts / Gradle / Just / Cargo / CMake / Makefile Tasks + 本 session 进程/端口。
private struct SessionInfoPanel: View {
    @ObservedObject var model: SessionInfoModel
    @ObservedObject var manager: TerminalManager
    let runPackageScript: (String, TerminalManager.PackageScriptRunMode) -> Void
    let openPackageJSON: () -> Void

    @State private var packageScriptsCollapsed = false
    @State private var gradleTasksCollapsed = false
    @State private var justTasksCollapsed = false
    @State private var cargoTasksCollapsed = false
    @State private var cmakeTasksCollapsed = false
    @State private var makefileTasksCollapsed = false
    @State private var processesCollapsed = false
    @State private var portsCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    TopToolsOpenSection(path: model.cwdPath, manager: manager)
                    PackageScriptsSection(
                        scripts: model.packageScripts,
                        records: manager.packageScriptRecords,
                        isCollapsed: $packageScriptsCollapsed,
                        runPackageScript: runPackageScript,
                        stopPackageScript: { manager.stopPackageScript($0) },
                        restartPackageScript: { manager.restartPackageScript($0, mode: $1) },
                        openPackageJSON: openPackageJSON
                    )
                    if !model.gradleScripts.isEmpty || GradleScriptProvider.isGradleProject(at: model.cwdPath) {
                        GradleTasksSection(
                            scripts: model.gradleScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $gradleTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    if !model.justScripts.isEmpty || JustScriptProvider.isJustProject(at: model.cwdPath) {
                        JustTasksSection(
                            scripts: model.justScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $justTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    if !model.cargoScripts.isEmpty || CargoScriptProvider.isCargoProject(at: model.cwdPath) {
                        CargoTasksSection(
                            scripts: model.cargoScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $cargoTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    if !model.cmakeScripts.isEmpty || CMakeScriptProvider.isCMakeProject(at: model.cwdPath) {
                        CMakeTasksSection(
                            scripts: model.cmakeScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $cmakeTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    if !model.makefileScripts.isEmpty || MakefileScriptProvider.isMakefileProject(at: model.cwdPath) {
                        MakefileTasksSection(
                            scripts: model.makefileScripts,
                            records: manager.packageScriptRecords,
                            isCollapsed: $makefileTasksCollapsed,
                            runScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            },
                            stopScript: { scriptName in
                                manager.stopPackageScript(scriptName)
                            },
                            restartScript: { script, mode in
                                manager.runProjectScript(script, mode: mode)
                            }
                        )
                    }
                    ProcessesSection(
                        processes: model.processes,
                        isCollapsed: $processesCollapsed,
                        kill: { model.kill($0, force: $1) }
                    )
                    PortsSection(
                        ports: model.ports,
                        isCollapsed: $portsCollapsed,
                        kill: { model.kill($0, force: $1) }
                    )
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .onChange(of: model.packageScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $packageScriptsCollapsed
            )
        }
        .onChange(of: model.gradleScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $gradleTasksCollapsed
            )
        }
        .onChange(of: model.justScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $justTasksCollapsed
            )
        }
        .onChange(of: model.cargoScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $cargoTasksCollapsed
            )
        }
        .onChange(of: model.cmakeScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $cmakeTasksCollapsed
            )
        }
        .onChange(of: model.makefileScripts.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $makefileTasksCollapsed
            )
        }
        .onChange(of: model.processes.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $processesCollapsed
            )
        }
        .onChange(of: model.ports.count) { oldCount, newCount in
            sidebarAutoCollapse(
                oldCount: oldCount, newCount: newCount, isCollapsed: $portsCollapsed
            )
        }
        .onAppear {
            if model.packageScripts.isEmpty { packageScriptsCollapsed = true }
            if model.gradleScripts.isEmpty && !GradleScriptProvider.isGradleProject(at: model.cwdPath) {
                gradleTasksCollapsed = true
            }
            if model.justScripts.isEmpty && !JustScriptProvider.isJustProject(at: model.cwdPath) {
                justTasksCollapsed = true
            }
            if model.cargoScripts.isEmpty && !CargoScriptProvider.isCargoProject(at: model.cwdPath) {
                cargoTasksCollapsed = true
            }
            if model.cmakeScripts.isEmpty && !CMakeScriptProvider.isCMakeProject(at: model.cwdPath) {
                cmakeTasksCollapsed = true
            }
            if model.makefileScripts.isEmpty && !MakefileScriptProvider.isMakefileProject(at: model.cwdPath) {
                makefileTasksCollapsed = true
            }
            if model.processes.isEmpty { processesCollapsed = true }
            if model.ports.isEmpty { portsCollapsed = true }
        }
    }

    private var infoTitle: String {
        model.shellName.isEmpty ? "Session" : model.shellName
    }

    private var infoSubtitle: String? {
        model.shellPid > 0 ? "pid \(String(model.shellPid))" : nil
    }

    private var pathRow: some View {
        HStack(spacing: 6) {
            TextField("", text: .constant(model.cwdPath.isEmpty ? "—" : model.cwdPath))
                .textFieldStyle(.plain)
                .font(SidebarTypography.caption(design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.cwdPath)

            HStack(spacing: 4) {
                Button {
                    guard !model.cwdPath.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.cwdPath)])
                } label: {
                    Image(systemName: "finder")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Open in Finder")
                .disabled(model.cwdPath.isEmpty)

                Button {
                    guard !model.cwdPath.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.cwdPath, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Copy Path")
                .disabled(model.cwdPath.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let session = manager.selectedProject?.selectedSession {
            TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                if let appIcon = session.foregroundAppIcon {
                    TerminalAppIconView(source: appIcon, size: 16, isSelected: true)
                        .frame(width: 24, height: 24)
                } else if session.isForegroundCommandRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color(nsColor: Theme.cursor))
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "terminal")
                        .font(SidebarTypography.listIcon())
                        .foregroundStyle(Color(nsColor: Theme.cursor))
                        .frame(width: 24, height: 24)
                }
            }
        } else if case .file(let file)? = manager.selectedProject?.selectedTab?.focusedContent {
            MaterialFileIconView(fileName: file.name, isDirectory: false, size: 16)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "terminal")
                .font(SidebarTypography.listIcon())
                .foregroundStyle(Color(nsColor: Theme.cursor))
                .frame(width: 24, height: 24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                headerIcon
                PanelHeader(
                    title: infoTitle,
                    subtitle: infoSubtitle,
                    titleFont: SidebarTypography.body(.semibold)
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
            pathRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

private struct InfoProcessRow: View {
    let process: SidebarProbe.ProcessItem
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
                .font(SidebarTypography.caption(design: .monospaced).monospacedDigit())
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
                    .font(SidebarTypography.caption().monospacedDigit())
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
    let port: SidebarProbe.PortItem
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
                    .font(SidebarTypography.body(.medium, design: .monospaced).monospacedDigit())
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
