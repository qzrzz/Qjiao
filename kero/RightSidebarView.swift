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
        case .system: return L10n.t("System")
        case .note: return L10n.t("Note")
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "cpu"
        case .note: return "note.text"
        }
    }
}

/// 右侧顶栏单个 tab 的展示元数据。
private struct TopTabItem {
    let panel: RightPanel
    let systemImage: String
    let title: String
    let help: String
    let badgeCount: Int

    init(panel: RightPanel, systemImage: String, title: String, help: String, badgeCount: Int = 0) {
        self.panel = panel
        self.systemImage = systemImage
        self.title = title
        self.help = help
        self.badgeCount = badgeCount
    }
}

/// 右侧 Tabs 按内容测宽的自适应布局：能完整展示标题时全部展示，
/// 否则优先保留选中项标题，再退回仅图标。
private enum SidebarTabLayout {
    enum TitleMode {
        /// 全部 tab 显示图标 + 完整标题。
        case all
        /// 仅选中项显示标题，其余仅图标。
        case activeOnly
        /// 全部仅图标。
        case iconsOnly
    }

    struct Result {
        let mode: TitleMode
        let spacing: CGFloat
        let activeIndex: Int

        func showsTitle(at index: Int) -> Bool {
            switch mode {
            case .all: return true
            case .activeOnly: return index == activeIndex
            case .iconsOnly: return false
            }
        }
    }

    static let iconSide: CGFloat = 14
    static let iconTitleSpacing: CGFloat = 4
    static let horizontalPaddingWithTitle: CGFloat = 7
    static let horizontalPaddingIconOnly: CGFloat = 6
    /// tab chip 右侧相对左侧多出的内边距，避免标题贴边。
    static let trailingPaddingExtra: CGFloat = 2
    static let interTabSpacingWide: CGFloat = 4
    static let interTabSpacingNarrow: CGFloat = 2
    static let barHorizontalPadding: CGFloat = 8
    /// 底栏收起/展开按钮热区边长。
    static let collapseButtonSide: CGFloat = 24
    /// 测宽相对渲染的余量，避免字体度量与 SwiftUI 布局的细微偏差裁切尾字。
    private static let measureSlack: CGFloat = 2

    /// 根据实际文案宽度决定展缩模式与 tab 间距。
    static func resolve(
        items: [TopTabItem],
        activeIndex: Int,
        availableWidth: CGFloat,
        trailingReserve: CGFloat = 0
    ) -> Result {
        let count = items.count
        guard count > 0, availableWidth > 0 else {
            return Result(mode: .iconsOnly, spacing: interTabSpacingNarrow, activeIndex: 0)
        }
        let safeActive = min(max(activeIndex, 0), count - 1)
        let barInsets = barHorizontalPadding * 2 + trailingReserve

        func totalWidth(mode: TitleMode, spacing: CGFloat) -> CGFloat {
            var sum: CGFloat = 0
            for (index, item) in items.enumerated() {
                let showTitle = mode == .all || (mode == .activeOnly && index == safeActive)
                sum += chipWidth(title: showTitle ? item.title : nil, badgeCount: item.badgeCount)
            }
            sum += spacing * CGFloat(max(0, count - 1))
            return sum + barInsets + measureSlack
        }

        // 优先全标题 + 宽间距；空间稍紧时缩间距仍尽量全标题。
        if totalWidth(mode: .all, spacing: interTabSpacingWide) <= availableWidth {
            return Result(mode: .all, spacing: interTabSpacingWide, activeIndex: safeActive)
        }
        if totalWidth(mode: .all, spacing: interTabSpacingNarrow) <= availableWidth {
            return Result(mode: .all, spacing: interTabSpacingNarrow, activeIndex: safeActive)
        }
        if totalWidth(mode: .activeOnly, spacing: interTabSpacingWide) <= availableWidth {
            return Result(mode: .activeOnly, spacing: interTabSpacingWide, activeIndex: safeActive)
        }
        if totalWidth(mode: .activeOnly, spacing: interTabSpacingNarrow) <= availableWidth {
            return Result(mode: .activeOnly, spacing: interTabSpacingNarrow, activeIndex: safeActive)
        }
        return Result(mode: .iconsOnly, spacing: interTabSpacingNarrow, activeIndex: safeActive)
    }

    /// 根据实际文案宽度决定展缩模式与 tab 间距（底栏字符串回退版本）。
    static func resolve(
        titles: [String],
        activeIndex: Int,
        availableWidth: CGFloat,
        trailingReserve: CGFloat = 0
    ) -> Result {
        let items = titles.map { TopTabItem(panel: .project, systemImage: "", title: $0, help: "", badgeCount: 0) }
        return resolve(items: items, activeIndex: activeIndex, availableWidth: availableWidth, trailingReserve: trailingReserve)
    }

    /// 单个 chip 宽度：图标固定 14，有标题时再加字距与文案测宽；若有角标则加上角标宽度。
    private static func chipWidth(title: String?, badgeCount: Int = 0) -> CGFloat {
        var base: CGFloat = 0
        if let title {
            base = horizontalPaddingWithTitle * 2
                + trailingPaddingExtra
                + iconSide
                + iconTitleSpacing
                + titleWidth(title)
        } else {
            base = horizontalPaddingIconOnly * 2 + trailingPaddingExtra + iconSide
        }
        if badgeCount > 0 {
            base += iconTitleSpacing + badgeWidth(count: badgeCount)
        }
        return base
    }

    private static func badgeWidth(count: Int) -> CGFloat {
        let text = count > 99 ? "99+" : "\(count)"
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: 10,
            weight: .semibold
        )
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return max(16, textWidth + 8)
    }

    private static func titleWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: SidebarTypography.secondarySize,
            weight: .medium
        )
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Right sidebar: hidden by default, toggled from the terminal's corner
/// button or ⇧⌘B. 上半区 Start / Project / Info / Files / CWD / Git；
/// 下半区 System / Note；中间可拖分割。
struct RightSidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var l10n = L10n.shared
    @StateObject private var fileTree = FileTreeModel()
    @StateObject private var filesFind = FilesFindModel()
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
    /// 任一项目终端完成命令都会改变对应序号；字典保留连续相同退出结果的事件。
    private var commandCompletionSequences: [UUID: UInt64] {
        Dictionary(uniqueKeysWithValues:
            manager.selectedProject?.sessions.map {
                ($0.id, $0.commandCompletionSequence)
            } ?? []
        )
    }
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
        let _ = l10n.language
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
        // 进程、端口与文件信息继续按需轮询；Git 在侧栏打开时持续保持状态更新以精确显示角标。
        .onReceive(refreshTimer) { _ in syncModels(refreshGit: true) }
        // 回到前台：恢复 System 轮询（面板可见时）并刷新 Git 角标。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            syncSystemPolling()
            refreshGitForExternalEvent()
        }
        // 退到后台：立即停止 System 轮询，消除 top 时代的后台空转（原生采集同样无需后台运行）。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        )) { _ in
            systemInfo.setActive(false)
        }
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
        .onChange(of: commandCompletionSequences) { refreshGitForExternalEvent() }
        .onChange(of: manager.selectedProjectID) {
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
        .onReceive(NotificationCenter.default.publisher(for: .qjiaoSidebarPortsDidProbe)) { _ in
            switch manager.panelTab {
            case .start, .project:
                manager.updatePackageScriptPorts(
                    with: projectInfo.ports,
                    shellPids: manager.selectedProject?.sessions.compactMap(\.shellPid) ?? []
                )
            case .info:
                if let session = manager.selectedSession {
                    manager.updatePackageScriptPorts(
                        with: sessionInfo.ports,
                        shellPids: [session.shellPid].compactMap { $0 }
                    )
                }
            default:
                break
            }
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

    /// Git 事件处理从庞大的 SwiftUI modifier 表达式中拆出，降低 Swift 6 类型推断负担。
    private func refreshGitForExternalEvent() {
        guard manager.isPanelVisible else { return }
        syncModels()
    }

    /// 仅在右侧栏可见、下半区展开、选中 System 且 App 处于前台时轮询 CLI 指标。
    private func syncSystemPolling() {
        let active = NSApplication.shared.isActive
            && manager.isPanelVisible
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
                findModel: filesFind,
                git: git,
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
                findModel: filesFind,
                git: git,
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
                project: manager.selectedProject,
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
        GeometryReader { geo in
            let titles = RightBottomPanel.allCases.map(\.title)
            let activeIndex = RightBottomPanel.allCases.firstIndex(of: bottomTab) ?? 0
            // 右侧收起按钮占位，避免标题把 chevron 挤出可视区。
            let trailingReserve =
                SidebarTabLayout.collapseButtonSide + SidebarTabLayout.interTabSpacingWide
            let layout = SidebarTabLayout.resolve(
                titles: titles,
                activeIndex: activeIndex,
                availableWidth: geo.size.width,
                trailingReserve: trailingReserve
            )
            HStack(alignment: .center, spacing: layout.spacing) {
                ForEach(Array(RightBottomPanel.allCases.enumerated()), id: \.element.id) { index, tab in
                    bottomTabButton(tab, showTitle: layout.showsTitle(at: index))
                }
                Spacer(minLength: 0)
                bottomCollapseButton
            }
            .padding(.horizontal, SidebarTabLayout.barHorizontalPadding)
            .offset(y: -1.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
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
        let title = bottomCollapsed ? L10n.t("Expand") : L10n.t("Collapse")
        return Button {
            toggleBottomCollapsed()
        } label: {
            Image(systemName: bottomCollapsed ? "chevron.up" : "chevron.down")
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: SidebarTabLayout.collapseButtonSide,
                    height: SidebarTabLayout.collapseButtonSide
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func bottomTabButton(_ tab: RightBottomPanel, showTitle: Bool) -> some View {
        let isActive = bottomTab == tab
        return Button {
            bottomTabRaw = tab.rawValue
        } label: {
            sidebarTabLabel(
                systemImage: tab.systemImage,
                title: tab.title,
                isActive: isActive,
                showTitle: showTitle
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
            let items = topTabItems
            let activeIndex = items.firstIndex { $0.panel == manager.panelTab } ?? 0
            let layout = SidebarTabLayout.resolve(
                items: items,
                activeIndex: activeIndex,
                availableWidth: geo.size.width
            )
            ZStack(alignment: .leading) {
                // 右侧顶栏未被面板切换按钮占用的区域可拖动窗口。
                WindowDragArea()

                HStack(spacing: layout.spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.panel) { index, item in
                        tabButton(
                            item.panel,
                            systemImage: item.systemImage,
                            title: item.title,
                            help: item.help,
                            showTitle: layout.showsTitle(at: index),
                            badgeCount: item.badgeCount
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SidebarTabLayout.barHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
        }
        .frame(height: 41)
        // 右侧 Tabs 顶栏空白区域允许拖拽移动窗口
        .background { WindowDragArea() }
    }

    /// 顶栏可见 tabs（CWD 仅在与项目目录不同时出现）。
    private var topTabItems: [TopTabItem] {
        var items: [TopTabItem] = [
            TopTabItem(
                panel: .project,
                systemImage: "shippingbox",
                title: L10n.t("Project"),
                help: L10n.t("Project")
            ),
            TopTabItem(
                panel: .info,
                systemImage: "info.circle",
                title: L10n.t("Info"),
                help: L10n.t("Info (⇧⌘I)")
            ),
            TopTabItem(
                panel: .files,
                systemImage: "folder",
                title: L10n.t("Files"),
                help: L10n.t("Files (⇧⌘E)")
            ),
        ]
        if showsCWD {
            items.append(
                TopTabItem(
                    panel: .cwd,
                    systemImage: "terminal",
                    title: L10n.t("CWD"),
                    help: L10n.t("CWD")
                )
            )
        }
        items.append(
            TopTabItem(
                panel: .git,
                systemImage: "arrow.triangle.branch",
                title: L10n.t("Git"),
                help: L10n.t("Git (⇧⌘G)"),
                badgeCount: git.isRepo ? git.totalChangeCount : 0
            )
        )
        return items
    }

    private func tabButton(
        _ panel: RightPanel,
        systemImage: String,
        title: String,
        help: String,
        showTitle: Bool,
        badgeCount: Int = 0
    ) -> some View {
        let isActive = manager.panelTab == panel
        return Button {
            manager.panelTab = panel
        } label: {
            sidebarTabLabel(
                systemImage: systemImage,
                title: title,
                isActive: isActive,
                showTitle: showTitle,
                badgeCount: badgeCount
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Selected" : "Not selected")
    }

    /// 上/下半区共用的 tab 样式：由栏级布局决定是否显示标题；字重始终 medium，
    /// 选中只改颜色和背景，避免 regular↔medium 宽度变化导致抖动。
    private func sidebarTabLabel(
        systemImage: String,
        title: String,
        isActive: Bool,
        showTitle: Bool,
        badgeCount: Int = 0
    ) -> some View {
        HStack(alignment: .center, spacing: SidebarTabLayout.iconTitleSpacing) {
            Image(systemName: systemImage)
                .font(SidebarTypography.caption(.medium))
                .frame(
                    width: SidebarTabLayout.iconSide,
                    height: SidebarTabLayout.iconSide
                )
            if showTitle {
                Text(title)
                    .font(SidebarTypography.secondary(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if badgeCount > 0 {
                let badgeText = badgeCount > 99 ? "99+" : "\(badgeCount)"
                Text(badgeText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.85))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 15)
                    .background(
                        Capsule()
                            .fill(isActive ? Color.primary.opacity(0.14) : Color.primary.opacity(0.09))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: badgeCount)
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(
            .leading,
            showTitle
                ? SidebarTabLayout.horizontalPaddingWithTitle
                : SidebarTabLayout.horizontalPaddingIconOnly
        )
        .padding(
            .trailing,
            (showTitle
                ? SidebarTabLayout.horizontalPaddingWithTitle
                : SidebarTabLayout.horizontalPaddingIconOnly)
                + SidebarTabLayout.trailingPaddingExtra
        )
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.09) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func syncModels(
        reloadActivePanel: Bool = false,
        refreshGit: Bool = true
    ) {
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

        // 无论当前 panelTab 是什么，只要侧边栏可见且 refreshGit 为 true，都更新 git 状态以实时保持 Git 角标数量精准。
        // 优先使用当前 terminal session 的 cwd，若无 session 或 cwd 为空则回退到项目根目录，确保切换项目时即时同步 Git 状态。
        if refreshGit {
            let root = session?.currentDirectoryPath.isEmpty == false
                ? session!.currentDirectoryPath
                : projectRoot(for: project, fallback: session)
            if !root.isEmpty {
                git.sync(root: root)
            }
        }

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
            break
        }
    }

    private func projectRoot(
        for project: Project,
        fallback session: TerminalSession?
    ) -> String {
        guard let session else {
            return project.projectDirectory
        }
        return project.panelRoot(
            followingSessionAt: session.currentDirectoryPath,
            foregroundAt: session.foregroundDirectoryPath
        ).root
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
