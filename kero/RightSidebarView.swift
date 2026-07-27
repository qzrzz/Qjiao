//
//  RightSidebarView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

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
    /// 从 Files 树打开的 ImageBuild 会话
    @State private var imageBuildSession: ImageBuildSession?

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
            syncModels(reloadActivePanel: true)
            syncSystemPolling()
            syncNoteBinding()
        }
        .onReceive(refreshTimer) { _ in syncModels() }
        .onChange(of: manager.isPanelVisible) {
            syncModels(reloadActivePanel: manager.isPanelVisible)
            syncSystemPolling()
            // 隐藏右侧栏时先落盘，避免防抖未到就丢改动。
            if !manager.isPanelVisible {
                noteModel.flush()
            } else {
                syncNoteBinding()
            }
        }
        .onChange(of: manager.panelTab) {
            syncModels(reloadActivePanel: true)
        }
        .onChange(of: manager.selectedSession?.id) { syncModels() }
        // A `cd` in the terminal publishes the new cwd immediately (OSC 7 →
        // session.workingDirectory); resync at once instead of waiting for the
        // next refreshTimer tick, which is what made the panel lag the change.
        .onChange(of: manager.selectedSession?.workingDirectory) { syncModels() }
        .onChange(of: manager.selectedProject?.id) {
            syncModels()
            syncNoteBinding()
        }
        // 后台 ps/lsof 完成后立即把端口绑定到脚本行，不再等待下一轮 2s Timer。
        .onChange(of: projectInfo.ports) {
            manager.updatePackageScriptPorts(
                with: projectInfo.ports,
                shellPids: manager.selectedProject?.sessions.compactMap(\.shellPid) ?? []
            )
        }
        .onChange(of: sessionInfo.ports) {
            manager.updatePackageScriptPorts(
                with: sessionInfo.ports,
                shellPids: [manager.selectedSession?.shellPid].compactMap { $0 }
            )
        }
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
        .sheet(item: $imageBuildSession) { session in
            ImageBuildView(
                session: session,
                onDismiss: { outputPath in
                    imageBuildSession = nil
                    if let outputPath {
                        NSWorkspace.shared.selectFile(outputPath, inFileViewerRootedAtPath: "")
                    }
                }
            )
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
            if let project = manager.selectedProject {
                SessionInfoPanel(
                    model: sessionInfo,
                    manager: manager,
                    projectID: project.id,
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
            }
        case .files:
            FileTreePanel(
                manager: manager,
                model: fileTree,
                session: manager.selectedSession,
                currentFilePath: openFilePath,
                openFile: { manager.openFile($0) },
                openToSide: { manager.openFileToSide($0) },
                onRename: { manager.fileRenamed(from: $0, to: $1) },
                onImageBuild: { paths in
                    imageBuildSession = .fromFileTree(paths: paths)
                }
            )
        case .cwd:
            FileTreePanel(
                manager: manager,
                model: fileTree,
                session: manager.selectedSession,
                currentFilePath: openFilePath,
                openFile: { manager.openFile($0) },
                openToSide: { manager.openFileToSide($0) },
                onRename: { manager.fileRenamed(from: $0, to: $1) },
                onImageBuild: { paths in
                    imageBuildSession = .fromFileTree(paths: paths)
                }
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
        // 右侧 Tabs 顶栏空白区域允许拖拽移动窗口
        .background { WindowDragArea() }
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

    private func syncModels(reloadActivePanel: Bool = false) {
        let projectPanelActive = manager.isPanelVisible
            && (manager.panelTab == .start || manager.panelTab == .project)
            && manager.selectedProject != nil
        let infoPanelActive = manager.isPanelVisible
            && manager.panelTab == .info
            && manager.selectedSession != nil
        projectInfo.setFileMonitoringActive(projectPanelActive)
        sessionInfo.setFileMonitoringActive(infoPanelActive)

        guard let project = manager.selectedProject, manager.isPanelVisible else { return }
        let session = manager.selectedSession
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
        case .start, .project:
            // 项目根 + 全 session shell 的进程/端口并集。
            let root = projectRoot(for: project, fallback: session)
            let shellPids = project.sessions.compactMap(\.shellPid)
            projectInfo.sync(
                root: root,
                shellPids: shellPids,
                reloadScripts: reloadActivePanel
            )
        case .info:
            // 当前终端 cwd 的 scripts + 本 session 进程/端口。
            guard let session else { return }
            sessionInfo.sync(
                cwd: session.currentDirectoryPath,
                shellName: session.shellName,
                shellPid: session.shellPid,
                reloadScripts: reloadActivePanel
            )
        case .files:
            fileTree.sync(root: projectRoot(for: project, fallback: session))
        case .cwd:
            guard let session else { return }
            fileTree.sync(root: session.currentDirectoryPath)
        case .git:
            guard let session else { return }
            git.sync(root: session.currentDirectoryPath)
        }
    }

    /// 项目配置尚未写入目录时，使用当前终端目录作为一次性回退值。
    private func projectRoot(
        for project: Project,
        fallback session: TerminalSession?
    ) -> String {
        project.projectDirectory.isEmpty
            ? (session?.currentDirectoryPath ?? "")
            : project.projectDirectory
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
