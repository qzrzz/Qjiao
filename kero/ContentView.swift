//
//  ContentView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var tabSwitcher = TabSwitcherController()

    var body: some View {
        let _ = l10n.language
        HStack(spacing: 0) {
            if manager.isLeftSidebarVisible {
                SidebarView(manager: manager)
            }

            VStack(spacing: 0) {
                // Above the pane stack so header tooltips, which hang down
                // into the terminal area, aren't covered by it.
                MainHeaderView(manager: manager)
                    .zIndex(1)

                ZStack {
                    // Diff 面板在未选中时保持挂载：避免其 NSHostingView 从窗口移除
                    // 导致内部 WKWebView 被销毁和重新创建（丢失已渲染的 diff 和滚动位置）。
                    // 未选中的 Diff 需要将透明度设为 0，防止终端开启透明背景时透出显示。
                    if let project = manager.selectedProject {
                        ForEach(project.diffPlacements, id: \.diff.id) { placement in
                            let isSelected = project.selectedTabID == placement.tabID
                            DiffViewerView(
                                diff: placement.diff,
                                isSelected: isSelected
                            )
                            .background(Color(nsColor: Theme.background.withAlphaComponent(settings.terminalBackgroundOpacity)))
                            .opacity(isSelected ? 1 : 0)
                            .allowsHitTesting(isSelected)
                            .zIndex(isSelected ? 1 : 0)
                        }
                    }
                    Group {
                        if let tab = manager.selectedProject?.selectedTab {
                            PaneLayoutView(
                                tab: tab,
                                onSplit: { manager.split(toward: $0) },
                                onClosePane: { manager.closePane($0) },
                                onNewBrowserTab: {
                                    manager.newBrowserTab(initialURL: $0)
                                },
                                onNewBrowserPane: {
                                    manager.newBrowserPane(initialURL: $0)
                                }
                            )
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Opaque so the pane gaps hide unselected diffs behind.
                    // A diff tab's own pane stays clear so its web view,
                    // mounted in the stack below, remains visible.
                    .background(paneLayerIsOpaque ? AnyShapeStyle(Color(nsColor: Theme.background)) : AnyShapeStyle(Color.clear))
                    .zIndex(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background {
                // A semi-transparent theme color alone exposes the desktop
                // sharply. Put the native material behind it so the window
                // opacity setting reads as frosted glass instead.
                if settings.windowBackgroundOpacity < 1 || settings.visualEffectAlpha < 1 {
                    VisualEffectView()
                }
                Color(nsColor: Theme.background.withAlphaComponent(settings.windowBackgroundOpacity))
            }

            RightSidebarView(manager: manager)
        }
        // 全局 tooltip 宿主：浮在侧栏顶栏 / ScrollView 之上，避免被裁剪遮挡。
        .tooltipHost()
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            TerminalParkingView(sessions: parkedTerminalSessions)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            if manager.isCommandPaletteVisible {
                CommandPaletteView(manager: manager)
            }
        }
        .overlay {
            if tabSwitcher.isPresented, let project = manager.selectedProject {
                TabSwitcherOverlay(
                    manager: manager,
                    project: project,
                    controller: tabSwitcher
                )
                    .zIndex(20)
            }
        }
        .background {
            TabSwitcherEventMonitor(manager: manager, controller: tabSwitcher)
                .frame(width: 0, height: 0)
        }
        .background(WindowChromeAccessor { manager.attach(to: $0) })
        // 文件夹创建项目改由左侧边栏 onDrop 处理，避免整窗拦截导致终端无法接收路径 drop。
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
        .onChange(of: manager.selectedProject?.theme) {
            // 项目 light/dark 配色覆盖变更：先写入 Theme.projectSelection 再刷终端。
            manager.reloadActiveProjectTheme()
        }
        .onAppear {
            manager.reloadActiveProjectTheme()
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { event in
                FileTreeModel.isDraggingFromTree = false
                return event
            }
        }
    }

    /// Sessions in the visible tab are owned by `TerminalHostView`; every
    /// other session stays window-attached in the invisible parking host.
    private var parkedTerminalSessions: [TerminalSession] {
        let visibleIDs = Set(
            manager.selectedProject?.selectedTab?.sessions.map(\.id) ?? []
        )
        return manager.projects
            .flatMap(\.sessions)
            .filter { $0.isInitialized && !visibleIDs.contains($0.id) }
    }

    /// The pane layer paints an opaque background to hide unselected diffs in
    /// its gaps — but a diff tab's own pane must stay clear so its web view
    /// (mounted in the stack behind) shows through.
    private var paneLayerIsOpaque: Bool {
        guard let tab = manager.selectedProject?.selectedTab else { return true }
        return tab.diffs.isEmpty
    }

    @ViewBuilder
    private var emptyState: some View {
        if manager.selectedProject == nil {
            emptyStatePrompt(
                title: L10n.t("No open projects"),
                buttonTitle: L10n.t("New Project  ⌘N"),
                action: { manager.newProject() }
            )
        } else {
            // A project whose tabs were all closed stays open; offer to reopen
            // a session rather than showing the no-projects prompt.
            emptyStatePrompt(
                title: L10n.t("No open sessions"),
                buttonTitle: L10n.t("New Session  ⌘T"),
                action: { manager.newSession() }
            )
        }
    }

    private func emptyStatePrompt(
        title: String, buttonTitle: String, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(Theme.secondaryColor)
            Button(buttonTitle, action: action)
        }
    }
}
/// Slim bar above the terminal: the selected project's sessions as
/// horizontal tabs on the left, right-sidebar toggle on the right.
///
/// Window drag lives only on blank surfaces: 8pt strips above/below the tab
/// row, plus leading/trailing empty space. Tabs themselves never sit under a
/// `WindowDragArea`, so reorder gestures keep the mouse stream.
/// Left-sidebar toggle lives in `SidebarView` while open, and only appears
/// here when the left sidebar is closed.
private struct MainHeaderView: View {
    @ObservedObject var manager: TerminalManager

    /// 左侧栏收起时，为红绿灯预留的宽度（不含开关左边距）。
    private static let trafficLightInset: CGFloat = 68
    /// 收起时 Tabs 栏上左边栏开关的左边距（红绿灯之后）。
    private static let leftToggleLeadingPadding: CGFloat = 16
    /// 收起时 Tabs 栏上左边栏开关的右边距（与标签条之间）。
    private static let leftToggleTrailingPadding: CGFloat = 12
    /// 「+」与右侧工具、以及工具彼此之间的间距（满栏时与按钮间距一致）。
    private static var actionSpacing: CGFloat { HeaderTabActionMetrics.spacing }
    /// 标签条与「+」间距。
    private static let tabNewSpacing: CGFloat = 4
    /// Tabs 行上下各一条拖窗热区高度。
    private static let tabEdgeDragHeight: CGFloat = 8
    /// 顶栏总高：上下拖窗带 + 中间标签行。
    private static let headerHeight: CGFloat = 42

    /// 左侧栏开关占用宽度（按钮 + 右侧间距）；仅在 Tabs 栏展示时计入。
    private static var leftToggleWidth: CGFloat {
        HeaderTabActionMetrics.size + leftToggleTrailingPadding
    }

    /// With the left sidebar hidden the header slides under the window's
    /// traffic-light buttons, so inset its content to clear them. When the
    /// left toggle is shown it gets a larger leading pad than the open-state
    /// tabs inset.
    private var leadingInset: CGFloat {
        if manager.isLeftSidebarVisible {
            return HeaderTabActionMetrics.edgePadding
        }
        return Self.trafficLightInset + Self.leftToggleLeadingPadding
    }

    /// 右侧固定工具簇固有宽度（zoom 可选 + 下拉 + 侧栏）。
    private static func trailingClusterWidth(isPaneZoomed: Bool, hasProject: Bool) -> CGFloat {
        guard hasProject else { return 0 }
        var width =
            HeaderTabActionMetrics.size
            + HeaderTabActionMetrics.spacing
            + HeaderTabActionMetrics.size
        if isPaneZoomed {
            width += HeaderTabActionMetrics.size + HeaderTabActionMetrics.spacing
        }
        return width
    }

    var body: some View {
        GeometryReader { geo in
            let hasProject = manager.selectedProject != nil
            let showLeftToggle = !manager.isLeftSidebarVisible
            let trailingCluster = Self.trailingClusterWidth(
                isPaneZoomed: manager.isPaneZoomed,
                hasProject: hasProject
            )
            // 标签/新建不得进入的右侧预留：工具簇 + 与「+」同宽的间距 + 外边距。
            let trailingReserve =
                trailingCluster
                + (trailingCluster > 0 ? Self.actionSpacing : 0)
                + HeaderTabActionMetrics.edgePadding
            let leftToggleOccupied = showLeftToggle ? Self.leftToggleWidth : 0
            let leftBudget = max(
                0,
                geo.size.width - leadingInset - leftToggleOccupied - trailingReserve
            )
            let stripMaxWidth = max(
                0,
                leftBudget - Self.tabNewSpacing - HeaderTabActionMetrics.size
            )

            VStack(spacing: 0) {
                // Tabs 上方 8pt：整行可拖窗口（不压在 Tab 上）。
                HeaderWindowDragBand(height: Self.tabEdgeDragHeight)

                HStack(spacing: 0) {
                    HeaderWindowDragBand(width: leadingInset)

                    if showLeftToggle {
                        HeaderIconButton(
                            systemImage: "sidebar.left",
                            isActive: false,
                            help: L10n.t("Toggle Left Sidebar (⌘B)"),
                            action: { manager.toggleLeftSidebar() }
                        )
                        .padding(.trailing, Self.leftToggleTrailingPadding)
                    }

                    if let project = manager.selectedProject {
                        HStack(spacing: Self.tabNewSpacing) {
                            SessionTabsView(
                                manager: manager,
                                project: project,
                                maxStripWidth: stripMaxWidth
                            )
                            NewTabButton(project: project)
                        }
                    }

                    // 标签与右侧工具之间的空白：拖窗口。
                    HeaderWindowDragBand()

                    if let project = manager.selectedProject {
                        HStack(spacing: Self.actionSpacing) {
                            if manager.isPaneZoomed {
                                HeaderIconButton(
                                    systemImage: "arrow.down.forward.and.arrow.up.backward",
                                    isActive: true,
                                    help: L10n.t("Exit Pane Zoom (⇧⌘↩)"),
                                    helpAlignment: .trailing,
                                    action: { manager.togglePaneZoom() }
                                )
                            }
                            TabListButton(manager: manager, project: project)
                            HeaderIconButton(
                                systemImage: "sidebar.right",
                                isActive: manager.isPanelVisible,
                                help: L10n.t("Toggle Right Sidebar (⇧⌘B)"),
                                helpAlignment: .trailing,
                                action: { manager.toggleSidebar() }
                            )
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.trailing, HeaderTabActionMetrics.edgePadding)
                    } else {
                        HeaderWindowDragBand(width: HeaderTabActionMetrics.edgePadding)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Tabs 下方 8pt：整行可拖窗口。
                HeaderWindowDragBand(height: Self.tabEdgeDragHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(height: Self.headerHeight)
        .clipped()
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }
}

/// 顶栏拖窗热区：由 SwiftUI 固定尺寸，`WindowDragArea` 叠在上面填满。
/// 避免纯 NSViewRepresentable 在 GeometryReader 里偶发 bounds 为空/撑破。
private struct HeaderWindowDragBand: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil

    var body: some View {
        ZStack {
            // 尺寸锚点：SwiftUI 先占位，NSView 才能稳定拿到非零 frame。
            Color.clear
            WindowDragArea()
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .clipped()
        .contentShape(Rectangle())
    }
}

/// 顶栏图标按钮尺寸与 hover 样式（左侧栏 / 新建 / 下拉 / 右侧栏 / Zoom 共用）。
enum HeaderTabActionMetrics {
    /// 点击热区边长；图标仍用 caption，不随热区放大。
    static let size: CGFloat = 26
    static let spacing: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    /// 顶栏左右工具按钮外侧边距：左边栏开关左边距 = 右边栏开关右边距。
    static let edgePadding: CGFloat = 10
    /// 仅 hover 浅底；按下 / 激活无底色。
    static let hoverFill = Theme.primaryColor.opacity(0.06)
}

/// 顶栏统一图标按钮：较大 hit 区、固定 caption 图标；hover 浅底，按下无底色。
struct HeaderIconButton: View {
    let systemImage: String
    var isActive = false
    let help: String
    var helpAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    @State private var isHovering = false

    private var iconColor: Color {
        if isActive { return Color(nsColor: Theme.cursor) }
        return isHovering ? Theme.primaryColor : Theme.secondaryColor
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(iconColor)
                .frame(width: HeaderTabActionMetrics.size, height: HeaderTabActionMetrics.size)
                .contentShape(
                    RoundedRectangle(cornerRadius: HeaderTabActionMetrics.cornerRadius, style: .continuous)
                )
        }
        .buttonStyle(HeaderIconButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isActive)
        .tooltip(help, edge: .below, alignment: helpAlignment)
    }
}

/// 仅 hover 时铺浅底；`isPressed` 时去掉底色，且不做系统默认压暗。
struct HeaderIconButtonStyle: ButtonStyle {
    var isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let showHoverFill = isHovering && !configuration.isPressed
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: HeaderTabActionMetrics.cornerRadius, style: .continuous)
                    .fill(showHoverFill ? HeaderTabActionMetrics.hoverFill : .clear)
            )
            .animation(.easeInOut(duration: 0.12), value: showHoverFill)
    }
}

/// 标签条右侧：新建标签。
private struct NewTabButton: View {
    @ObservedObject var project: Project

    var body: some View {
        HeaderIconButton(
            systemImage: "plus",
            help: L10n.t("New Session (⌘T)"),
            action: { project.newSession() }
        )
    }
}

/// 顶栏标签总览入口，固定在右侧侧栏按钮旁。
private struct TabListButton: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var project: Project
    @State private var isPresented = false

    var body: some View {
        HeaderIconButton(
            systemImage: "chevron.down",
            isActive: isPresented,
            help: L10n.t("Show Tab List"),
            helpAlignment: .trailing,
            action: { isPresented.toggle() }
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TabListPopover(
                manager: manager,
                project: project,
                isPresented: $isPresented
            )
        }
    }
}

/// 可滚动的项目 Tab 下拉面板，标题刻意允许换行以完整显示终端标题。
private struct TabListPopover: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var project: Project
    @Binding var isPresented: Bool
    @StateObject private var terminalDetails = TerminalTabDetailsLoader()
    @State private var currentTime = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Tabs"))
                .font(SidebarTypography.body(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)

            Divider()

            if project.tabs.count <= 6 {
                // 内容放得下时不使用 ScrollView，避免系统压缩首尾列表项。
                VStack(spacing: 3) {
                    tabRows
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 3) {
                        tabRows
                    }
                    // 与弹出面板的大圆角保持安全距离，选中背景不会贴边。
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 440)
        // 少量 Tab 由内容的实际尺寸决定 Popover 高度，避免手算行高留白。
        .fixedSize(horizontal: false, vertical: project.tabs.count <= 6)
        // 弹层先完成显示，再异步抓取每个终端的系统信息。
        .onAppear { terminalDetails.load(sessions: project.sessions) }
        .onDisappear { terminalDetails.cancel() }
        // 使用一个共享计时器刷新所有行，避免每一行的 TimelineView 影响布局高度。
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) {
            currentTime = $0
        }
    }

    private func details(for tab: PaneTab) -> TerminalSession.TabListDetails? {
        guard case .session(let session)? = tab.focusedContent else { return nil }
        return terminalDetails.detailsBySessionID[session.id]
    }

    private func showsCommandSpinner(for tab: PaneTab) -> Bool {
        guard case .session(let session)? = tab.focusedContent else { return false }
        return manager.isRightSidebarCommandRunning(sessionID: session.id)
    }

    @ViewBuilder
    private var tabRows: some View {
        ForEach(project.tabs) { tab in
            TabListRow(
                tab: tab,
                isSelected: tab.id == project.selectedTabID,
                showsCommandSpinner: showsCommandSpinner(for: tab),
                terminalDetails: details(for: tab),
                currentTime: currentTime
            ) {
                project.selectedTabID = tab.id
                isPresented = false
            }
        }
    }
}

/// Tab 列表中的一项。标题没有行数上限，避免终端标题被裁剪。
private struct TabListRow: View {
    @ObservedObject var tab: PaneTab
    let isSelected: Bool
    let showsCommandSpinner: Bool
    let terminalDetails: TerminalSession.TabListDetails?
    let currentTime: Date
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                TabContentIcon(
                    content: tab.focusedContent,
                    showsCommandSpinner: showsCommandSpinner,
                    tint: isSelected ? Color(nsColor: Theme.cursor) : Theme.secondaryColor
                )
                .frame(width: 16, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.displayTitle ?? "Untitled Tab")
                        .font(SidebarTypography.body())
                        .foregroundStyle(isSelected ? Theme.primaryColor : Theme.secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if case .session(let session)? = tab.focusedContent {
                        TerminalTabDetails(
                            session: session,
                            details: terminalDetails,
                            currentTime: currentTime
                        )
                    }

                    if tab.allPanes.count > 1 {
                        Label(L10n.format("%d panes", tab.allPanes.count), systemImage: "square.split.2x1")
                            .font(SidebarTypography.section())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // 弹出面板首次打开时，macOS 会给第一个 Button 加蓝色键盘焦点环；
        // 列表已有自己的选中背景，因此不显示这层额外描边。
        .focusable(false)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Theme.primaryColor.opacity(0.09) : .clear)
        )
    }
}

/// 终端 Tab 的次要信息：工作目录、常驻内存和已运行时间。
private struct TerminalTabDetails: View {
    let session: TerminalSession
    let details: TerminalSession.TabListDetails?
    let currentTime: Date

    var body: some View {
        if let details {
            detailsView(details)
        } else {
            Label(L10n.t("Loading terminal details…"), systemImage: "hourglass")
                .font(SidebarTypography.section())
                .foregroundStyle(.tertiary)
        }
    }

    private func detailsView(
        _ details: TerminalSession.TabListDetails
    ) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Label(details.directory, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    Label(details.memoryLabel, systemImage: "memorychip")
                    Label(session.runningDurationLabel(at: currentTime), systemImage: "clock")
                }
            }
            .font(SidebarTypography.section())
            .foregroundStyle(.tertiary)
    }
}

/// 并发加载 Tab 总览详情；结果逐项发布，因此慢终端不会阻塞整个面板。
@MainActor
private final class TerminalTabDetailsLoader: ObservableObject {
    @Published private(set) var detailsBySessionID: [UUID: TerminalSession.TabListDetails] = [:]
    private var tasks: [Task<Void, Never>] = []

    func load(sessions: [TerminalSession]) {
        cancel()
        detailsBySessionID = [:]

        let requests = sessions.map { session in
            Request(
                id: session.id,
                shellPid: session.shellPid,
                fallbackDirectory: session.tabListFallbackDirectory
            )
        }
        for request in requests {
            let task = Task.detached(priority: .utility) { [weak self] in
                let details = TerminalSession.loadTabListDetails(
                    shellPid: request.shellPid,
                    fallbackDirectory: request.fallbackDirectory
                )
                guard !Task.isCancelled else { return }
                await self?.store(details, for: request.id)
            }
            tasks.append(task)
        }
    }

    func cancel() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    private func store(_ details: TerminalSession.TabListDetails, for id: UUID) {
        detailsBySessionID[id] = details
    }

    private struct Request: Sendable {
        let id: UUID
        let shellPid: pid_t?
        let fallbackDirectory: String
    }
}

/// Horizontal tabs for one project — terminal sessions and open files.
/// 新建在条带右侧（`NewTabButton`）；总览下拉固定在侧栏旁（`TabListButton`）。
private struct SessionTabsView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var project: Project
    @ObservedObject private var settings = AppSettings.shared
    let maxStripWidth: CGFloat
    @State private var overflow = StripOverflow()
    /// 标签内容固有宽度（未裁切），用于条带收窄到内容。
    @State private var contentWidth: CGFloat = 0
    /// 标签条已挤满时压低单 Tab 最小/最大宽度，腾出可见数量。
    @State private var stripIsFull = false
    @State private var draggedTabID: UUID?
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var tabSizes: [UUID: CGSize] = [:]
    @State private var renamingTabID: UUID?

    /// Which edges have off-screen tabs, i.e. where to show a fade hint.
    private struct StripOverflow: Equatable {
        var left = false
        var right = false
    }

    /// Scroll 几何快照：边缘淡入 + 是否挤满（用于压缩 Tab 宽限）。
    private struct StripGeometry: Equatable {
        var overflow = StripOverflow()
        var contentWidth: CGFloat = 0
        var containerWidth: CGFloat = 0
    }

    /// 标签条未满时的单 Tab 最小宽度。
    private static let relaxedTabMinWidth: CGFloat = 150
    /// 标签条已满（需要滚动）时的单 Tab 最小宽度。
    private static let compressedTabMinWidth: CGFloat = 130
    /// 标签条未满时的单 Tab 最大宽度。
    private static let relaxedTabMaxWidth: CGFloat = 220
    /// 标签条已满（需要滚动）时的单 Tab 最大宽度。
    private static let compressedTabMaxWidth: CGFloat = 140

    private var tabMinWidth: CGFloat {
        stripIsFull ? Self.compressedTabMinWidth : Self.relaxedTabMinWidth
    }

    private var tabMaxWidth: CGFloat {
        stripIsFull ? Self.compressedTabMaxWidth : Self.relaxedTabMaxWidth
    }

    /// 条带显示宽度：内容与上限取小；硬宽度，避免 ScrollView 把右侧工具顶走。
    private var stripWidth: CGFloat {
        guard maxStripWidth > 0 else { return 0 }
        guard contentWidth > 0 else { return maxStripWidth }
        return min(contentWidth, maxStripWidth)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(project.tabs) { tab in
                        PaneTabItem(
                            manager: manager,
                            tab: tab,
                            isSelected: tab.id == project.selectedTabID,
                            minWidth: tabMinWidth,
                            maxWidth: tabMaxWidth,
                            select: { project.selectedTabID = tab.id },
                            close: { project.close(tab) },
                            renamingTabID: $renamingTabID
                        )
                        .contextMenu { tabContextMenu(for: tab) }
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TabFramePreferenceKey.self,
                                    value: [tab.id: geo.frame(in: .global)]
                                )
                            }
                        }
                        .opacity(draggedTabID == tab.id ? 0.65 : 1)
                        // 占满 Tab 热区，避免透明间隙把事件漏给其它拖动手势。
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                .onChanged { value in
                                    updateTabDrag(source: tab.id, location: value.location)
                                }
                                .onEnded { _ in endTabDrag() },
                            including: renamingTabID == tab.id ? .subviews : .all
                        )
                    }
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TabStripContentWidthKey.self,
                            value: geo.size.width
                        )
                    }
                }
            }
            .onPreferenceChange(TabStripContentWidthKey.self) { contentWidth = $0 }
            .onScrollGeometryChange(for: StripGeometry.self) { geo in
                StripGeometry(
                    overflow: StripOverflow(
                        left: geo.contentOffset.x > 0.5,
                        right: geo.contentOffset.x + geo.containerSize.width < geo.contentSize.width - 0.5
                    ),
                    contentWidth: geo.contentSize.width,
                    containerWidth: geo.containerSize.width
                )
            } action: { _, new in
                overflow = new.overflow
                // contentSize 亦同步内容宽，避免仅依赖 preference 时的首帧空档。
                if new.contentWidth > 0 {
                    contentWidth = new.contentWidth
                }
                updateStripFullness(
                    contentWidth: new.contentWidth,
                    containerWidth: new.containerWidth
                )
            }
            .onChange(of: project.tabs.count) { _, _ in
                // 关 Tab 后可能立刻腾出空间，用条带上限估一次是否可恢复宽松宽度。
                reevaluateStripFullnessAfterTabCountChange()
            }
            // Keep the active tab visible: scrolls the minimum distance to
            // reveal it (anchor: nil is a no-op when it's already fully in view).
            .onChange(of: project.selectedTabID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollToSelectedTab(using: proxy)
                }
            }
            // 侧栏/窗口改变可视宽度、Tab 增删/排序或动态标题改变前序宽度时，
            // 选中项都可能在未切换选择的情况下被挤出视口。
            .onChange(of: maxStripWidth) { _, _ in
                scrollToSelectedTab(using: proxy)
            }
            .onChange(of: project.tabs.map(\.id)) { _, _ in
                scrollToSelectedTab(using: proxy)
            }
            .onChange(of: tabSizes) { _, _ in
                scrollToSelectedTab(using: proxy)
            }
            .onAppear {
                // Restored sessions may open with an off-screen active tab.
                DispatchQueue.main.async {
                    scrollToSelectedTab(using: proxy)
                }
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [overflow.left ? .clear : .black, .black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 20)
                    Color.black
                    LinearGradient(
                        colors: [.black, overflow.right ? .clear : .black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 20)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: overflow)
            // 硬宽度 = min(内容, 上限)，不参与 HStack 弹性争夺。
            .frame(width: stripWidth, alignment: .leading)
            .clipped()
            .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                tabFrames = frames
                let sizes = frames.mapValues(\.size)
                if sizes != tabSizes {
                    tabSizes = sizes
                }
            }
        }
        .frame(width: stripWidth, alignment: .leading)
    }

    /// 仅滚动到足以完整显示当前 Tab 的位置；已在视口内时保持现有偏移。
    private func scrollToSelectedTab(using proxy: ScrollViewProxy) {
        guard let id = project.selectedTabID,
              project.tabs.contains(where: { $0.id == id })
        else { return }
        proxy.scrollTo(id)
    }

    /// 内容超出可视宽度 → 压缩；仅当按宽松最大宽度也一定放得下时才恢复，避免 140/220 来回抖。
    private func updateStripFullness(contentWidth: CGFloat, containerWidth: CGFloat) {
        let overflowing = contentWidth > containerWidth + 0.5
        if overflowing {
            if !stripIsFull { stripIsFull = true }
            return
        }
        guard stripIsFull else { return }
        // 当前已是压缩态且不再溢出；若全部扩到 relaxed 仍不超过条带，才解除压缩。
        let tabCount = max(project.tabs.count, 1)
        let spacing = CGFloat(max(tabCount - 1, 0)) * 3
        let maxRelaxedTotal =
            CGFloat(tabCount) * Self.relaxedTabMaxWidth + spacing
        if maxRelaxedTotal <= maxStripWidth + 0.5 {
            stripIsFull = false
        }
    }

    private func reevaluateStripFullnessAfterTabCountChange() {
        guard stripIsFull else { return }
        let tabCount = max(project.tabs.count, 1)
        let spacing = CGFloat(max(tabCount - 1, 0)) * 3
        let maxRelaxedTotal =
            CGFloat(tabCount) * Self.relaxedTabMaxWidth + spacing
        if maxRelaxedTotal <= maxStripWidth + 0.5 {
            stripIsFull = false
        }
    }

    /// Reorders immediately as the pointer crosses another tab. This direct
    /// gesture deliberately avoids a pasteboard drag session, which the
    /// hidden title bar can otherwise claim as a window move first.
    private func updateTabDrag(source: UUID, location: CGPoint) {
        draggedTabID = source
        NSCursor.closedHand.set()
        guard let target = tabFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            project.moveTab(source, to: target)
        }
    }

    private func endTabDrag() {
        draggedTabID = nil
        NSCursor.arrow.set()
    }

    @ViewBuilder
    private func tabContextMenu(for tab: PaneTab) -> some View {
        Button(L10n.t("Rename…")) { renamingTabID = tab.id }
        if tab.customName != nil {
            Button(L10n.t("Use Automatic Title")) { tab.customName = nil }
        }
        Menu(L10n.t("Zsh Idle title")) {
            ForEach(ZshIdleTitleStyle.allCases) { style in
                Toggle(isOn: Binding(
                    get: { settings.zshIdleTitleStyle == style },
                    set: { if $0 { settings.zshIdleTitleStyle = style } }
                )) {
                    Text(style.displayName)
                }
            }
        }
        Divider()
        if case .file(let file) = tab.focusedContent {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                Label(L10n.t("Reveal in Finder"), systemImage: "finder")
            }
            Button(L10n.t("Copy Absolute Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Button(L10n.t("Copy Relative Path")) {
                let root = project.projectDirectory
                let rootPrefix = root.hasSuffix("/") ? root : root + "/"
                let relative: String
                if file.path == root {
                    relative = "."
                } else if file.path.hasPrefix(rootPrefix) {
                    relative = String(file.path.dropFirst(rootPrefix.count))
                } else {
                    relative = file.path
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(relative, forType: .string)
            }
            Divider()
        }
        if case .browser(let browser) = tab.focusedContent,
           !browser.urlString.isEmpty {
            Button(L10n.t("Open in Default Browser")) {
                browser.openInDefaultBrowser()
            }
            .disabled(browser.shareURL == nil)
            Button(L10n.t("Copy Address")) {
                browser.copyAddress()
            }
            Divider()
        }
        Button(L10n.t("Close")) { project.close(tab) }
        Button(L10n.t("Close Others")) { project.closeOthers(tab) }
            .disabled(project.tabs.count <= 1)
        Button(L10n.t("Close Tabs to the Right")) { project.closeToRight(of: tab) }
            .disabled(project.tabs.last?.id == tab.id)
        Divider()
        Button(L10n.t("Close All")) { project.closeAll() }
    }
}

/// Collects each tab's global frame so a direct drag gesture can hit-test the
/// pointer even while the horizontal strip is moving under it.
private struct TabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 标签条内容固有宽度（全部 Tab 排开后的总宽）。
private struct TabStripContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A tab in the strip. Shows the focused pane's title/icon, with a small
/// counter when the tab holds more than one pane. Observes the tab so focus
/// and layout changes refresh it; the focused content is observed by the
/// per-kind label below so its live title/dirty state shows.
private struct PaneTabItem: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var tab: PaneTab
    let isSelected: Bool
    /// 由标签条是否挤满决定：宽松 150 / 压缩 130。
    var minWidth: CGFloat = 150
    /// 由标签条是否挤满决定：宽松 220 / 压缩 140。
    var maxWidth: CGFloat = 220
    let select: () -> Void
    let close: () -> Void
    @Binding var renamingTabID: UUID?

    var body: some View {
        let paneCount = tab.allPanes.count
        if renamingTabID == tab.id {
            TabRenameChrome(
                systemImage: tab.focusedContent?.systemImage ?? "terminal",
                materialFileName: tab.focusedContent?.materialFileName,
                browserIcon: focusedBrowser,
                initialValue: tab.displayTitle ?? "",
                commit: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    tab.customName = trimmed.isEmpty ? nil : trimmed
                },
                end: { renamingTabID = nil }
            )
        } else {
            switch tab.focusedContent {
            case .session(let session):
                SessionTabLabel(
                    session: session,
                    showsCommandSpinner: manager.isRightSidebarCommandRunning(
                        sessionID: session.id
                    ),
                    customTitle: tab.customName,
                    paneCount: paneCount,
                    isSelected: isSelected,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    select: select,
                    close: close
                )
            case .file(let file):
                FileTabLabel(
                    file: file,
                    customTitle: tab.customName,
                    paneCount: paneCount,
                    isSelected: isSelected,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    select: select,
                    close: close
                )
            case .browser(let browser):
                BrowserTabLabel(
                    browser: browser,
                    customTitle: tab.customName,
                    paneCount: paneCount,
                    isSelected: isSelected,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    select: select,
                    close: close
                )
            case .diff(let diff):
                TabItemChrome(
                    systemImage: "plus.forwardslash.minus",
                    materialFileName: diff.name,
                    title: tab.customName ?? diff.title,
                    manualTitle: tab.customName,
                    paneCount: paneCount,
                    isSelected: isSelected,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    select: select,
                    close: close
                )
                .help(diff.path)
            case nil:
                EmptyView()
            }
        }
    }

    private var focusedBrowser: BrowserTab? {
        if case .browser(let browser) = tab.focusedContent {
            return browser
        }
        return nil
    }
}

/// Inline editor for a tab title; Enter/focus loss commits and Escape cancels.
private struct TabRenameChrome: View {
    let systemImage: String
    /// 打开文件 / Diff 时用 Material 图标，与文件树一致。
    var materialFileName: String? = nil
    var browserIcon: BrowserTab?
    let initialValue: String
    let commit: (String) -> Void
    let end: () -> Void
    @State private var draft: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        systemImage: String,
        materialFileName: String? = nil,
        browserIcon: BrowserTab? = nil,
        initialValue: String,
        commit: @escaping (String) -> Void,
        end: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.materialFileName = materialFileName
        self.browserIcon = browserIcon
        self.initialValue = initialValue
        self.commit = commit
        self.end = end
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        HStack(spacing: 5) {
            if let browserIcon {
                BrowserFaviconView(browser: browserIcon, size: 13)
            } else {
                TabStripIconView(
                    systemImage: systemImage,
                    materialFileName: materialFileName,
                    isSelected: true
                )
            }
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(SidebarTypography.body())
                .frame(width: 110)
                .focused($focused)
                .onSubmit { finish(apply: true) }
                .onExitCommand { finish(apply: false) }
                .onChange(of: focused) { if !focused { finish(apply: true) } }
        }
        .padding(.horizontal, 8)
        // 与 TabItemChrome 一致：上下各 +1pt，整体高度 +2pt。
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.primaryColor.opacity(0.09)))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func finish(apply: Bool) {
        guard !finished else { return }
        finished = true
        if apply { commit(draft) }
        end()
    }
}

private struct SessionTabLabel: View {
    @ObservedObject var session: TerminalSession
    let showsCommandSpinner: Bool
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    var minWidth: CGFloat = 150
    var maxWidth: CGFloat = 220
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        // Ghostty does not publish foreground-process changes as SwiftUI
        // state. A lightweight timeline refreshes just the visible tab icon.
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            let appIcon = session.foregroundAppIcon
            TabItemChrome(
                systemImage: "terminal",
                title: customTitle ?? session.title,
                manualTitle: customTitle,
                paneCount: paneCount,
                isSelected: isSelected,
                isTaskTab: session.isTaskRunning,
                taskHasError: session.taskHasError,
                isTerminalRunning: showsCommandSpinner,
                terminalAppIcon: appIcon,
                minWidth: minWidth,
                maxWidth: maxWidth,
                select: select,
                close: close
            )
        }
    }
}

private struct FileTabLabel: View {
    @ObservedObject var file: FileTab
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    var minWidth: CGFloat = 150
    var maxWidth: CGFloat = 220
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "doc.text",
            materialFileName: file.name,
            title: customTitle ?? file.name,
            manualTitle: customTitle,
            paneCount: paneCount,
            isSelected: isSelected,
            isDirty: file.isDirty,
            minWidth: minWidth,
            maxWidth: maxWidth,
            select: select,
            close: close
        )
        .help(file.path)
    }
}

/// 浏览器标签标题和 favicon 会随页面导航实时更新。
private struct BrowserTabLabel: View {
    @ObservedObject var browser: BrowserTab
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    var minWidth: CGFloat = 150
    var maxWidth: CGFloat = 220
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "globe",
            browserIcon: browser,
            title: customTitle ?? browser.title,
            manualTitle: customTitle,
            paneCount: paneCount,
            isSelected: isSelected,
            minWidth: minWidth,
            maxWidth: maxWidth,
            select: select,
            close: close
        )
        .help(browser.urlString)
    }
}

/// 顶栏 Tab / 重命名条上的图标：打开文件用 Material Icon，终端等仍用 SF Symbol。
private struct TabStripIconView: View {
    let systemImage: String
    var materialFileName: String? = nil
    var isSelected = false
    /// 顶栏 Tab 条文件图标尺寸。
    private static let materialSize: CGFloat = 16

    var body: some View {
        if let materialFileName {
            MaterialFileIconView(
                fileName: materialFileName,
                isDirectory: false,
                size: Self.materialSize
            )
            .opacity(isSelected ? 1 : 0.72)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.cursor)) : AnyShapeStyle(.tertiary))
        }
    }
}

/// 终端 Task 状态的右下角指示器（运行中为转圈动画，正常结束为蓝圈带勾，错误结束为红圈带感叹号）
struct TaskStatusOverlayView: View {
    let isExecuting: Bool
    var hasError: Bool = false
    var tint: Color = Color(nsColor: Theme.cursor)

    var body: some View {
        ZStack {
            if isExecuting {
                ProgressView()
                    .controlSize(.mini)
                    .tint(tint)
                    .scaleEffect(0.7)
                    .frame(width: 11, height: 11)
            } else if hasError {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: NSColor.systemRed))
                        .frame(width: 11, height: 11)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: NSColor.systemBlue))
                        .frame(width: 11, height: 11)
                    Image(systemName: "checkmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .offset(x: 3.5, y: 3.5)
    }
}

private struct TabItemChrome: View {
    /// 默认最小宽度（标签条未满）；实际下限由 `minWidth` 传入。
    private static let defaultMinWidth: CGFloat = 150
    /// 标题缩短后保留当前宽度的时长，避免命令状态频繁变化造成标签抖动。
    private static let shrinkDelay: Duration = .seconds(2)

    let systemImage: String
    /// 非空时优先显示 Material 文件图标（打开的文件 / Diff）。
    var materialFileName: String? = nil
    /// 浏览器优先显示站点 favicon。
    var browserIcon: BrowserTab? = nil
    let title: String
    /// 非空时表示用户手动指定的标签名，应立即采用其对应宽度。
    var manualTitle: String?
    var paneCount: Int = 1
    let isSelected: Bool
    var isDirty = false
    var isTaskTab = false
    var taskHasError = false
    var isTerminalRunning = false
    /// 终端前台进程匹配到的应用图标；有值时优先于转圈动画。
    var terminalAppIcon: TerminalAppIconSource? = nil
    /// 由标签条挤满状态决定：默认 150，挤满时 130。
    var minWidth: CGFloat = 150
    /// 由标签条挤满状态决定：默认 220，挤满时 140。
    var maxWidth: CGFloat = 220
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false
    /// 当前显示宽度会立即扩张，但会延迟收缩，给标题的短暂变化留出缓冲。
    @State private var retainedWidth = defaultMinWidth
    @State private var shrinkTask: Task<Void, Never>?

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                let iconBase = Group {
                    if let browserIcon {
                        BrowserFaviconView(browser: browserIcon, size: 16)
                            .opacity(isSelected ? 1 : 0.78)
                    } else if let terminalAppIcon {
                        TerminalAppIconView(
                            source: terminalAppIcon,
                            size: 16,
                            isSelected: isSelected
                        )
                        .accessibilityLabel(L10n.t("Running application"))
                    } else {
                        TabStripIconView(
                            systemImage: systemImage,
                            materialFileName: materialFileName,
                            isSelected: isSelected
                        )
                    }
                }

                if isTaskTab {
                    iconBase.overlay(
                        TaskStatusOverlayView(
                            isExecuting: isTerminalRunning,
                            hasError: taskHasError,
                            tint: isSelected ? Color(nsColor: Theme.cursor) : Theme.secondaryColor
                        ),
                        alignment: .bottomTrailing
                    )
                } else {
                    iconBase
                }

                Text(title)
                    .font(SidebarTypography.body())
                    .foregroundStyle(isSelected ? Theme.primaryColor : Theme.secondaryColor)
                    .lineLimit(1)
                    // 标题独占可伸缩空间，右侧的分栏提示、修改提示和关闭按钮始终右对齐。
                    .frame(maxWidth: .infinity, alignment: .leading)
                if paneCount > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "square.split.2x1")
                            .font(SidebarTypography.chevron())
                        Text("\(paneCount)")
                            .font(SidebarTypography.micro(.semibold))
                    }
                    .foregroundStyle(.tertiary)
                }
                if isHovering {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(SidebarTypography.compact(.bold))
                            .foregroundStyle(Theme.secondaryColor)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if isDirty {
                    Circle()
                        .fill(Theme.secondaryColor)
                        .frame(width: 5, height: 5)
                        .frame(width: 14, height: 14)
                } else {
                    Spacer()
                        .frame(width: 14)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            // 内容页 Tabs 相对原先各边 +1pt，整体高度 +2pt。
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(width: retainedWidth, alignment: .leading)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.primaryColor.opacity(0.09) : (isHovering ? Theme.primaryColor.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
        .onAppear { updateRetainedWidth() }
        .onChange(of: title) { updateRetainedWidth() }
        .onChange(of: manualTitle) { applyManualTitleWidth() }
        .onChange(of: paneCount) { updateRetainedWidth() }
        .onChange(of: minWidth) { updateRetainedWidth(immediate: true) }
        .onChange(of: maxWidth) { updateRetainedWidth(immediate: true) }
        .onDisappear { shrinkTask?.cancel() }
    }

    /// 根据 AppKit 测得的标题自然宽度更新显示宽度：扩张即时生效，收缩等待一段时间后再执行。
    /// `immediate` 用于最小/最大宽度随标签条挤满/放宽变化时立刻应用，避免仍卡在旧的 retainedWidth。
    private func updateRetainedWidth(immediate: Bool = false) {
        // 图标、关闭/修改状态、左右内边距和元素间距占用的固定宽度。
        let accessoryWidth: CGFloat = paneCount > 1 ? 73 : 44
        // 与 Tab 标题 SwiftUI 字号保持一致，避免测宽偏小导致文字被裁切。
        let titleWidth = (title as NSString).size(
            withAttributes: [.font: SidebarTypography.bodyNSFont]
        ).width
        // 下限不超过上限（挤满时 min 130 / max 140）；始终夹在 [floor, max] 内。
        let floorWidth = min(minWidth, maxWidth)
        let desiredWidth = min(
            max(titleWidth + accessoryWidth, floorWidth),
            maxWidth
        )

        if immediate {
            shrinkTask?.cancel()
            shrinkTask = nil
            guard desiredWidth != retainedWidth else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                retainedWidth = desiredWidth
            }
            return
        }

        guard desiredWidth < retainedWidth else {
            shrinkTask?.cancel()
            shrinkTask = nil
            guard desiredWidth != retainedWidth else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                retainedWidth = desiredWidth
            }
            return
        }

        shrinkTask?.cancel()
        let widthBeforeDelay = retainedWidth
        shrinkTask = Task { @MainActor in
            try? await Task.sleep(for: Self.shrinkDelay)
            guard !Task.isCancelled, retainedWidth == widthBeforeDelay else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                retainedWidth = desiredWidth
            }
        }
    }

    /// 用户完成手动改名后不等待自动标题的防抖时间，立即更新为新标题所需宽度。
    private func applyManualTitleWidth() {
        updateRetainedWidth(immediate: true)
    }
}

/// Terminal: 前台已知应用 → TerminalAppIcon；Task 标志 → 右下角 indicator；其他情况 → SF Symbol。
/// Open files / diffs use Material icons (same as the Files tree).
struct TabContentIcon: View {
    let content: PaneContent?
    var showsCommandSpinner = false
    let tint: Color
    private static let materialSize: CGFloat = 14

    var body: some View {
        if case .browser(let browser)? = content {
            BrowserFaviconView(browser: browser, size: Self.materialSize)
                .foregroundStyle(tint)
        } else if case .session(let session)? = content {
            let iconBase = Group {
                if let appIcon = session.foregroundAppIcon {
                    TerminalAppIconView(
                        source: appIcon,
                        size: Self.materialSize,
                        isSelected: true
                    )
                } else {
                    Image(systemName: "terminal")
                        .font(SidebarTypography.secondary(.medium))
                        .foregroundStyle(tint)
                }
            }
            if session.isTaskRunning {
                iconBase.overlay(
                    TaskStatusOverlayView(
                        isExecuting: showsCommandSpinner,
                        hasError: session.taskHasError,
                        tint: tint
                    ),
                    alignment: .bottomTrailing
                )
            } else {
                iconBase
            }
        } else if let fileName = content?.materialFileName {
            MaterialFileIconView(
                fileName: fileName,
                isDirectory: false,
                size: Self.materialSize
            )
        } else {
            Image(systemName: content?.systemImage ?? "terminal")
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(tint)
        }
    }
}
