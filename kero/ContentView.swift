//
//  ContentView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers


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
                        if let tab = activeTab {
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
            // Tab Agent 角标依赖全局轮询；Info 面板也会 activate，幂等。
            AgentWatcher.shared.activate(manager: manager)
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

    /// 当前内容区选中的 PaneTab。优先匹配 selectedTab / chromeSelectedTabID；
    /// 只要项目内存有 Tab 就绝不返回 nil，防止新建/切换终端时因 ID 异步刷新误落入 emptyState。
    private var activeTab: PaneTab? {
        guard let project = manager.selectedProject, !project.tabs.isEmpty else { return nil }
        if let selected = project.selectedTab {
            return selected
        }
        if let chromeID = project.chromeSelectedTabID,
           let tab = project.tabs.first(where: { $0.id == chromeID }) {
            return tab
        }
        return project.tabs.first
    }

    /// The pane layer paints an opaque background to hide unselected diffs in
    /// its gaps — but a diff tab's own pane must stay clear so its web view
    /// (mounted in the stack behind) shows through.
    private var paneLayerIsOpaque: Bool {
        guard let tab = activeTab else { return true }
        return tab.diffs.isEmpty
    }

    @ViewBuilder
    private var emptyState: some View {
        if manager.selectedProject == nil {
            EmptyStatePromptView(
                manager: manager,
                title: L10n.t("No open projects")
            )
        } else {
            // A project whose tabs were all closed stays open; offer to reopen
            // a session rather than showing the no-projects prompt.
            EmptyStatePromptView(
                manager: manager,
                title: L10n.t("No open sessions")
            )
        }
    }
}

/// 无会话 / 无项目时的中心空白状态视图：包含精致大图标、支持拖入文件夹打开项目、加大「新建会话」主按钮及增设「新建项目」次要按钮。
private struct EmptyStatePromptView: View {
    @ObservedObject var manager: TerminalManager
    let title: String
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            // 背景拖窗热区：在未命中按钮时点按空白处仍可拖动窗口
            WindowDragArea()

            VStack(spacing: 20) {
                // 图标高亮卡片
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            isDropTargeted
                                ? Color(nsColor: Theme.cursor).opacity(0.15)
                                : Color(nsColor: Theme.secondaryForeground).opacity(0.08)
                        )
                        .frame(width: 84, height: 84)

                    Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "terminal")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(
                            isDropTargeted
                                ? Color(nsColor: Theme.cursor)
                                : Theme.secondaryColor
                        )
                        .scaleEffect(isDropTargeted ? 1.15 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isDropTargeted)
                }

                VStack(spacing: 6) {
                    Text(isDropTargeted ? L10n.t("Drop folder here to open project") : title)
                        .font(SidebarTypography.body(.semibold))
                        .foregroundStyle(Theme.primaryColor)

                    Text(L10n.t("Drag a folder here or click below to start"))
                        .font(SidebarTypography.compact())
                        .foregroundStyle(Theme.secondaryColor.opacity(0.75))
                }

                // 按钮组：新建会话（加大主按钮）与新建项目（次要按钮）
                HStack(spacing: 12) {
                    // 主按钮：新建会话 ⌘T（若已有所选项目优先 newSession，无项目时新建项目）
                    Button(action: {
                        if manager.selectedProject != nil {
                            manager.newSession()
                        } else {
                            manager.newProject()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.square")
                                .font(.system(size: 13, weight: .semibold))
                            Text(L10n.t("New Session"))
                                .font(SidebarTypography.body(.semibold))
                            Text("⌘T")
                                .font(SidebarTypography.micro(.medium))
                                .opacity(0.75)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: Theme.cursor).opacity(0.88))
                        }
                        .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)

                    // 次要按钮：新建项目 ⌘N
                    Button(action: { manager.newProject() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 13, weight: .medium))
                            Text(L10n.t("New Project"))
                                .font(SidebarTypography.body(.medium))
                            Text("⌘N")
                                .font(SidebarTypography.micro(.medium))
                                .opacity(0.75)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.secondaryColor.opacity(0.12))
                        }
                        .foregroundStyle(Theme.primaryColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: Theme.background).opacity(0.65))
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(
                                    Color(nsColor: Theme.cursor),
                                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                                )
                        }
                    }
            }
            .animation(.easeInOut(duration: 0.16), value: isDropTargeted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isDropTargeted,
            perform: handleFolderDrop
        )
    }

    /// 拖入文件夹到中心区域：解析 URL 并在当前应用打开/新建项目
    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        let dragPb = NSPasteboard(name: .drag)
        let isInternalFileTreeDrag = FileTreeModel.isDraggingFromTree
            || (dragPb.types?.contains(NSPasteboard.PasteboardType("com.qjiao.filetree-item")) ?? false)
            || (FileTreeModel.activeTreeDragPasteboardChangeCount == dragPb.changeCount)
        if isInternalFileTreeDrag {
            FileTreeModel.isDraggingFromTree = false
            return false
        }

        let externalProviders = providers.filter { provider in
            !provider.registeredTypeIdentifiers.contains("com.qjiao.filetree-item")
                && !provider.hasItemConformingToTypeIdentifier("com.qjiao.filetree-item")
        }
        guard !externalProviders.isEmpty else { return false }

        var accepted = false
        for provider in externalProviders {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }
            accepted = true
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                let url: URL? = if let url = item as? URL {
                    url
                } else if let data = item as? Data {
                    URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    nil
                }
                guard let url else { return }
                var isDirectory: ObjCBool = false
                let targetURL: URL
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    targetURL = url
                } else {
                    targetURL = url.deletingLastPathComponent()
                }
                Task { @MainActor in
                    _ = manager.addProject(at: targetURL)
                }
            }
        }
        return accepted
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
                            if !project.tabs.isEmpty {
                                SessionTabsView(
                                    manager: manager,
                                    project: project,
                                    maxStripWidth: stripMaxWidth
                                )
                            }
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
                isSelected: tab.id == (project.chromeSelectedTabID ?? project.selectedTabID),
                showsCommandSpinner: showsCommandSpinner(for: tab),
                terminalDetails: details(for: tab),
                currentTime: currentTime
            ) {
                project.selectTab(tab.id)
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

/// 单个主 Tab 在弹性布局下的分配结果。
private struct ElasticTabSlot: Equatable {
    var width: CGFloat
    var iconOnly: Bool
}

/// 主内容 Tabs 宽度常量与弹性分配算法。
private enum TabStripMetrics {
    static let interTabSpacing: CGFloat = 3
    /// 标签条未满时的单 Tab 最小宽度。
    static let relaxedTabMinWidth: CGFloat = 150
    /// 标签条已满（滚动模式）时的单 Tab 最小宽度。
    static let compressedTabMinWidth: CGFloat = 130
    /// 标签条未满时的单 Tab 最大宽度。
    static let relaxedTabMaxWidth: CGFloat = 220
    /// 标签条已满（滚动模式）时的单 Tab 最大宽度。
    static let compressedTabMaxWidth: CGFloat = 140
    /// 仅图标态固定宽度：图标 + 左右内边距。
    static let iconOnlyWidth: CGFloat = 32
    /// 分配宽度低于此值时切换为仅图标（无标题、无关闭）。
    static let iconOnlyThreshold: CGFloat = 72

    /// 图标 + 关闭占位 + 分栏提示等固定配件宽（与 `TabItemChrome` 布局一致）。
    /// leading 9 + icon 16 + HStack 间距×2 + close 14 + trailing 5 = 54；多分栏再加徽章约 24。
    static func accessoryWidth(paneCount: Int) -> CGFloat {
        paneCount > 1 ? 83 : 54
    }

    /// 标题理想像素宽（向上取整，避免与 SwiftUI 布局差 1pt 误判）。
    static func idealTitleWidth(_ title: String) -> CGFloat {
        ceil(
            (title as NSString).size(
                withAttributes: [.font: SidebarTypography.bodyNSFont]
            ).width
        )
    }

    static func naturalWidth(title: String, paneCount: Int) -> CGFloat {
        let titleWidth = idealTitleWidth(title)
        let floor = min(relaxedTabMinWidth, relaxedTabMaxWidth)
        return min(
            max(titleWidth + accessoryWidth(paneCount: paneCount), floor),
            relaxedTabMaxWidth
        )
    }

    /// 弹性模式：激活 Tab 保持自然全宽（受 max 限制）；先从最左侧非激活 Tab 连续压缩到仅图标，
    /// 仍不够再从最右侧非激活 Tab 压缩。激活 Tab 不参与压缩。
    static func resolveElastic(
        titles: [String],
        paneCounts: [Int],
        activeIndex: Int,
        availableWidth: CGFloat
    ) -> [ElasticTabSlot] {
        let count = titles.count
        guard count > 0 else { return [] }
        let safeActive = min(max(activeIndex, 0), count - 1)
        var widths: [CGFloat] = (0..<count).map { index in
            naturalWidth(title: titles[index], paneCount: paneCounts[index])
        }

        func totalWidth() -> CGFloat {
            widths.reduce(0, +) + interTabSpacing * CGFloat(max(count - 1, 0))
        }

        var deficit = totalWidth() - availableWidth
        if deficit > 0.5, availableWidth > 0 {
            // 左侧：从最左（远离激活）向激活方向压缩。
            if safeActive > 0 {
                for index in 0..<safeActive where deficit > 0.5 {
                    let reducible = widths[index] - iconOnlyWidth
                    guard reducible > 0 else { continue }
                    let take = min(reducible, deficit)
                    widths[index] -= take
                    deficit -= take
                }
            }
            // 右侧：从最右（远离激活）向激活方向压缩。
            if deficit > 0.5, safeActive < count - 1 {
                for index in stride(from: count - 1, through: safeActive + 1, by: -1)
                where deficit > 0.5 {
                    let reducible = widths[index] - iconOnlyWidth
                    guard reducible > 0 else { continue }
                    let take = min(reducible, deficit)
                    widths[index] -= take
                    deficit -= take
                }
            }
        }

        return widths.enumerated().map { index, width in
            let iconOnly = index != safeActive && width <= iconOnlyThreshold + 0.5
            let resolved = iconOnly ? iconOnlyWidth : width
            return ElasticTabSlot(width: resolved, iconOnly: iconOnly)
        }
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
    /// 标签条已挤满时压低单 Tab 最小/最大宽度，腾出可见数量（仅滚动模式）。
    @State private var stripIsFull = false
    @State private var draggedTabID: UUID?
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var tabSizes: [UUID: CGSize] = [:]
    @State private var renamingTabID: UUID?
    /// 弹性布局分配结果；随标题 / 选中 / 宽度变化重算。
    @State private var elasticSlots: [UUID: ElasticTabSlot] = [:]
    /// 标题驱动的弹性重算防抖：新建 Tab 后 shell 初始化会让标题短时间多次变化，
    /// 每次都重算会让激活 Tab 宽度来回跳动、条带反复滚动；等标题稳定后再重算一次。
    @State private var elasticRecomputeTask: Task<Void, Never>?
    /// 点击时本地抢先的选中态：只刷新顶栏，不经过 Project→Manager 整树广播。
    @State private var localChromeTabID: UUID?

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

    private var isElastic: Bool {
        settings.tabsLayoutMode == .elastic
    }

    /// 顶栏即时选中（可领先内容区一拍）：本地点击 > Project chrome > 内容选中。
    private var chromeSelectedID: UUID? {
        localChromeTabID ?? project.chromeSelectedTabID ?? project.selectedTabID
    }

    private var tabMinWidth: CGFloat {
        stripIsFull ? TabStripMetrics.compressedTabMinWidth : TabStripMetrics.relaxedTabMinWidth
    }

    private var tabMaxWidth: CGFloat {
        stripIsFull ? TabStripMetrics.compressedTabMaxWidth : TabStripMetrics.relaxedTabMaxWidth
    }

    /// 条带显示宽度：内容与上限取小；硬宽度，避免 ScrollView 把右侧工具顶走。
    private var stripWidth: CGFloat {
        guard maxStripWidth > 0 else { return 0 }
        guard contentWidth > 0 else { return maxStripWidth }
        return min(contentWidth, maxStripWidth)
    }

    var body: some View {
        // 弹性模式用轻量时钟跟踪终端动态标题，以便重算宽度分配。
        TimelineView(.periodic(from: .now, by: isElastic ? 0.45 : 3600)) { _ in
            tabStrip
        }
        .onChange(of: settings.tabsLayoutMode) { _, _ in
            recomputeElasticSlots()
        }
        .onChange(of: maxStripWidth) { _, _ in
            recomputeElasticSlots()
        }
        // 跟 chrome：点击时先压布局，不必等内容区 selectedTabID。
        .onChange(of: project.chromeSelectedTabID) { _, _ in
            recomputeElasticSlots()
        }
        .onChange(of: project.selectedTabID) { _, _ in
            recomputeElasticSlots()
        }
        .onChange(of: project.tabs.map(\.id)) { _, _ in
            recomputeElasticSlots()
        }
        .onAppear { recomputeElasticSlots() }
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TabStripMetrics.interTabSpacing) {
                    ForEach(project.tabs) { tab in
                        let slot = elasticSlots[tab.id]
                        PaneTabItem(
                            manager: manager,
                            tab: tab,
                            isSelected: tab.id == chromeSelectedID,
                            minWidth: isElastic ? (slot?.width ?? tabMinWidth) : tabMinWidth,
                            maxWidth: isElastic ? (slot?.width ?? tabMaxWidth) : tabMaxWidth,
                            iconOnly: isElastic && (slot?.iconOnly ?? false),
                            select: { selectTabChromeFirst(tab.id) },
                            close: { project.close(tab) },
                            renamingTabID: $renamingTabID
                        )
                        .id(tab.id)
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
                if !isElastic {
                    updateStripFullness(
                        contentWidth: new.contentWidth,
                        containerWidth: new.containerWidth
                    )
                }
            }
            .onChange(of: project.tabs.count) { _, _ in
                // 关 Tab 后可能立刻腾出空间，用条带上限估一次是否可恢复宽松宽度。
                if !isElastic {
                    reevaluateStripFullnessAfterTabCountChange()
                }
                recomputeElasticSlots()
            }
            // Keep the active tab visible: scrolls the minimum distance to
            // reveal it (anchor: nil is a no-op when it's already fully in view).
            // 跟 chrome 即时滚入，不必等内容切换。
            // 不包 withAnimation：与新开 Tab 同帧时会把插入/宽度布局做成左→右插值。
            .onChange(of: project.chromeSelectedTabID) { _, id in
                guard let id else { return }
                scrollToSelectedTab(using: proxy)
            }
            .onChange(of: project.selectedTabID) { _, id in
                // 内容已跟上：清掉本地抢先态，避免与 source of truth 分叉。
                if localChromeTabID == id {
                    localChromeTabID = nil
                } else if localChromeTabID != nil, id != localChromeTabID {
                    // 外部切换（快捷键等）覆盖本地意图。
                    localChromeTabID = nil
                }
                guard let id else { return }
                scrollToSelectedTab(using: proxy)
            }
            .onChange(of: localChromeTabID) { _, id in
                guard id != nil else { return }
                recomputeElasticSlots()
                scrollToSelectedTab(using: proxy)
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
            .onChange(of: elasticSlots) { _, _ in
                if isElastic {
                    scrollToSelectedTab(using: proxy)
                }
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
                    // 动画只作用于渐隐条本身。不能挂在 ScrollView 上：
                    // 溢出翻转（新建 Tab 恰好撑满条带时）会把新 Tab 插入、
                    // 弹性宽度重排和滚入视口一起包进 0.15s 插值，
                    // 表现为创建 Tab 时整条 Tabs 的异常尺寸变化动画。
                    .animation(.easeInOut(duration: 0.15), value: overflow.left)
                    Color.black
                    LinearGradient(
                        colors: [.black, overflow.right ? .clear : .black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 20)
                    .animation(.easeInOut(duration: 0.15), value: overflow.right)
                }
            }
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
        .onChange(of: titleFingerprint) { _, _ in
            // 标题在 shell 启动 / 命令执行期间可能连续变化（如新 Tab 的目录名→
            // 提示符→稳定标题），直接重算会让激活 Tab 宽度跟随标题来回跳动。
            // 防抖：等标题稳定后再重算一次，避免创建 Tab 时的尺寸/位置异常动画。
            elasticRecomputeTask?.cancel()
            elasticRecomputeTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                recomputeElasticSlots()
            }
        }
        .onDisappear {
            elasticRecomputeTask?.cancel()
        }
    }

    /// 标题指纹：弹性模式随终端/文件标题变化触发重算。
    private var titleFingerprint: String {
        project.tabs.map { tab in
            "\(tab.id.uuidString):\(tab.displayTitle ?? "")"
        }
        .joined(separator: "|")
    }

    /// 顶栏点击：本地立刻高亮，内容切换推迟到下一拍且不先广播 Project chrome。
    private func selectTabChromeFirst(_ id: UUID) {
        guard project.tabs.contains(where: { $0.id == id }) else { return }
        if localChromeTabID != id {
            localChromeTabID = id
        }
        project.selectTab(id, paintChrome: false)
    }

    private func recomputeElasticSlots() {
        guard isElastic else {
            if !elasticSlots.isEmpty { elasticSlots = [:] }
            return
        }
        let tabs = project.tabs
        guard !tabs.isEmpty, maxStripWidth > 0 else {
            elasticSlots = [:]
            return
        }
        let titles = tabs.map { $0.displayTitle ?? "" }
        let paneCounts = tabs.map(\.allPanes.count)
        let activeIndex = tabs.firstIndex(where: { $0.id == chromeSelectedID }) ?? 0
        let resolved = TabStripMetrics.resolveElastic(
            titles: titles,
            paneCounts: paneCounts,
            activeIndex: activeIndex,
            availableWidth: maxStripWidth
        )
        var next: [UUID: ElasticTabSlot] = [:]
        for (index, tab) in tabs.enumerated() where index < resolved.count {
            next[tab.id] = resolved[index]
        }
        // 不带动画写入：新开 Tab / 重算宽度时若 withAnimation，整条会从左到右插值，观感很怪。
        if next != elasticSlots {
            elasticSlots = next
        }
    }

    /// 仅滚动到足以完整显示当前 Tab 的位置；已在视口内时保持现有偏移。
    private func scrollToSelectedTab(using proxy: ScrollViewProxy) {
        guard let id = chromeSelectedID,
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
        let spacing = CGFloat(max(tabCount - 1, 0)) * TabStripMetrics.interTabSpacing
        let maxRelaxedTotal =
            CGFloat(tabCount) * TabStripMetrics.relaxedTabMaxWidth + spacing
        if maxRelaxedTotal <= maxStripWidth + 0.5 {
            stripIsFull = false
        }
    }

    private func reevaluateStripFullnessAfterTabCountChange() {
        guard stripIsFull else { return }
        let tabCount = max(project.tabs.count, 1)
        let spacing = CGFloat(max(tabCount - 1, 0)) * TabStripMetrics.interTabSpacing
        let maxRelaxedTotal =
            CGFloat(tabCount) * TabStripMetrics.relaxedTabMaxWidth + spacing
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
    /// 由标签条是否挤满决定：宽松 150 / 压缩 130；弹性模式为分配宽。
    var minWidth: CGFloat = 150
    /// 由标签条是否挤满决定：宽松 220 / 压缩 140；弹性模式为分配宽。
    var maxWidth: CGFloat = 220
    /// 弹性模式仅图标：无标题、无关闭，保留状态指示器。
    var iconOnly = false
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
                    tabSessions: tab.sessions,
                    showsCommandSpinner: manager.isRightSidebarCommandRunning(
                        sessionID: session.id
                    ),
                    customTitle: tab.customName,
                    paneCount: paneCount,
                    isSelected: isSelected,
                    minWidth: minWidth,
                    maxWidth: maxWidth,
                    iconOnly: iconOnly,
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
                    iconOnly: iconOnly,
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
                    iconOnly: iconOnly,
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
                    iconOnly: iconOnly,
                    select: select,
                    close: close
                )
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
    @ObservedObject private var agentWatcher = AgentWatcher.shared
    /// 同 Tab 内所有 session（分屏）；未读按 Tab 聚合。
    var tabSessions: [TerminalSession] = []
    let showsCommandSpinner: Bool
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    var minWidth: CGFloat = 150
    var maxWidth: CGFloat = 220
    var iconOnly = false
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        // Ghostty does not publish foreground-process changes as SwiftUI
        // state. A lightweight timeline refreshes just the visible tab icon.
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            let appIcon = session.foregroundAppIcon
            let isAgentWorking = agentWatcher.snapshot(for: session.id)?.status == .working
            let sessionsForUnread = tabSessions.isEmpty ? [session] : tabSessions
            let isAgentBlocked = sessionsForUnread.contains {
                agentWatcher.snapshot(for: $0.id)?.status == .blocked
            }
            let isAgentUnread = sessionsForUnread.contains {
                agentWatcher.isUnread(sessionID: $0.id)
            }
            TabItemChrome(
                systemImage: "terminal",
                title: customTitle ?? session.title,
                manualTitle: customTitle,
                paneCount: paneCount,
                isSelected: isSelected,
                isTaskTab: session.isTaskRunning,
                taskHasError: session.taskHasError,
                isTerminalRunning: showsCommandSpinner,
                isAgentWorking: isAgentWorking,
                isAgentBlocked: isAgentBlocked,
                isAgentUnread: isAgentUnread,
                terminalAppIcon: appIcon,
                minWidth: minWidth,
                maxWidth: maxWidth,
                iconOnly: iconOnly,
                select: {
                    // 点开即视为已读。
                    for s in sessionsForUnread {
                        agentWatcher.markRead(sessionID: s.id)
                    }
                    select()
                },
                close: close
            )
        }
        .onChange(of: isSelected) { _, selected in
            guard selected else { return }
            let sessionsForUnread = tabSessions.isEmpty ? [session] : tabSessions
            for s in sessionsForUnread {
                agentWatcher.markRead(sessionID: s.id)
            }
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
    var iconOnly = false
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
            iconOnly: iconOnly,
            select: select,
            close: close
        )
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
    var iconOnly = false
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
            iconOnly: iconOnly,
            select: select,
            close: close
        )
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
                .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.cursor)) : AnyShapeStyle(Theme.secondaryColor))
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
                    .scaleEffect(0.95)
                    .frame(width: 13, height: 13)
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

/// Agent 工作中：图标右下角呼吸闪烁的小绿点；结束时渐隐而非瞬间消失。
///
/// 需由父视图在 `isActive` 变为 false 后仍短暂保留本视图（始终 overlay 即可），
/// 否则 SwiftUI 会直接卸载子树，渐隐无法完成。
struct AgentWorkingStatusDot: View {
    var isActive: Bool = true
    var dotOffset: CGPoint = CGPoint(x: 2, y: 2)
    var size: CGFloat = 5

    private static let green = Color(red: 0.25, green: 0.73, blue: 0.31)
    private static let pulseDuration: Double = 1.1
    private static let fadeInDuration: Double = 0.22
    private static let fadeOutDuration: Double = 0.55

    /// 整体显现强度 0…1；结束时缓出到 0。
    @State private var presence: Double = 0
    /// 呼吸相位：true 为更暗/更小的一端。
    @State private var pulseDimmed = false

    private var drawnOpacity: Double {
        let pulse = pulseDimmed ? 0.28 : 1.0
        return presence * pulse
    }

    private var drawnScale: Double {
        let pulse = pulseDimmed ? 0.78 : 1.0
        // 渐隐时略微收一点，避免「还在原地突然没了」的感觉。
        return pulse * (0.88 + 0.12 * presence)
    }

    var body: some View {
        Circle()
            .fill(Self.green)
            .frame(width: size, height: size)
            .opacity(drawnOpacity)
            .scaleEffect(drawnScale)
            .offset(x: dotOffset.x, y: dotOffset.y)
            .allowsHitTesting(false)
            .accessibilityLabel(L10n.t("Working"))
            .accessibilityHidden(presence < 0.08)
            .onAppear {
                apply(active: isActive, animated: presence > 0.01)
            }
            .onChange(of: isActive) { _, active in
                apply(active: active, animated: true)
            }
    }

    private func apply(active: Bool, animated: Bool) {
        if active {
            if animated {
                withAnimation(.easeOut(duration: Self.fadeInDuration)) {
                    presence = 1
                }
            } else {
                presence = 1
            }
            // 呼吸循环（仅在 active 时驱动）。
            withAnimation(
                .easeInOut(duration: Self.pulseDuration)
                    .repeatForever(autoreverses: true)
            ) {
                pulseDimmed = true
            }
        } else {
            // 用非循环动画覆盖 forever，并把 presence 缓出到 0。
            withAnimation(.easeOut(duration: Self.fadeOutDuration)) {
                pulseDimmed = false
                presence = 0
            }
        }
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
    /// Agent 正在工作：图标右下角呼吸绿点（优先于 Task 状态角标）。
    var isAgentWorking = false
    /// Agent 阻塞/等待介入：橙色小点（优先于未读小蓝点）。
    var isAgentBlocked = false
    /// Agent 完成但未读：小蓝点（working 绿点优先；否则显示未读）。
    var isAgentUnread = false
    /// 终端前台进程匹配到的应用图标；有值时优先于转圈动画。
    var terminalAppIcon: TerminalAppIconSource? = nil
    /// 由标签条挤满状态决定：默认 150，挤满时 130；弹性模式为分配宽。
    var minWidth: CGFloat = 150
    /// 由标签条挤满状态决定：默认 220，挤满时 140；弹性模式为分配宽。
    var maxWidth: CGFloat = 220
    /// 弹性仅图标：无标题、无关闭；保留 Task / dirty 状态指示。
    var iconOnly = false
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false
    /// 当前显示宽度会立即扩张，但会延迟收缩，给标题的短暂变化留出缓冲。
    @State private var retainedWidth = defaultMinWidth
    @State private var shrinkTask: Task<Void, Never>?
    /// 标题 Text 实际分到的槽位宽度（用于判断是否截断）。
    @State private var titleSlotWidth: CGFloat = 0
    /// 新建 Tab 的标题稳定窗口：shell 启动期间标题会多次变化（目录名→提示符→
    /// 稳定标题），窗口内的标题变化直接落到目标宽，不做宽度过渡，
    /// 避免创建瞬间出现尺寸变化动画。
    @State private var appearTime = Date.distantPast

    /// 弹性模式 min==max 时使用固定分配宽；滚动模式走 retainedWidth。
    private var isFixedWidth: Bool {
        abs(minWidth - maxWidth) < 0.5
    }

    private var displayWidth: CGFloat {
        if iconOnly { return min(minWidth, maxWidth) }
        if isFixedWidth { return minWidth }
        return retainedWidth
    }

    private var idealTitleWidth: CGFloat {
        TabStripMetrics.idealTitleWidth(title)
    }

    /// 标题未完整露出（仅图标，或标题槽位不够放全文）时才显示完整标题 tooltip。
    private var needsTitleTooltip: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if iconOnly { return true }
        // 优先用布局测得的标题槽位；尚未布局时回退到 frame 估算。
        if titleSlotWidth > 0.5 {
            return idealTitleWidth > titleSlotWidth + 1
        }
        let accessory = TabStripMetrics.accessoryWidth(paneCount: paneCount)
        return idealTitleWidth + accessory > displayWidth + 0.5
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: iconOnly ? 0 : 5) {
                tabIcon

                if !iconOnly {
                    Text(title)
                        .font(SidebarTypography.body())
                        .foregroundStyle(isSelected ? Theme.primaryColor : Theme.secondaryColor)
                        .lineLimit(1)
                        // 标题独占可伸缩空间，右侧的分栏提示、修改提示和关闭按钮始终右对齐。
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TabTitleSlotWidthKey.self,
                                    value: geo.size.width
                                )
                            }
                        }
                    if paneCount > 1 {
                        HStack(spacing: 2) {
                            Image(systemName: "square.split.2x1")
                                .font(SidebarTypography.chevron())
                            Text("\(paneCount)")
                                .font(SidebarTypography.micro(.semibold))
                                .monospacedDigit()
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
                    } else if isAgentUnread && !isAgentWorking {
                        // Agent 未读：小蓝点（与 dirty 同位置）。
                        Circle()
                            .fill(Color(nsColor: .systemBlue))
                            .frame(width: 5, height: 5)
                            .frame(width: 14, height: 14)
                            .accessibilityLabel(L10n.t("Unread"))
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
            }
            .padding(.leading, iconOnly ? 7 : 9)
            .padding(.trailing, iconOnly ? 7 : 5)
            // 内容页 Tabs 相对原先各边 +1pt，整体高度 +2pt。
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: iconOnly ? .center : .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(width: displayWidth, alignment: .leading)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.primaryColor.opacity(0.09) : (isHovering ? Theme.primaryColor.opacity(0.04) : .clear))
        )
        // 未完整显示时在 Tab 上方展示完整标题；完整显示则不挂 tooltip。
        .modifier(TabTruncatedTitleTooltip(title: title, enabled: needsTitleTooltip))
        .onPreferenceChange(TabTitleSlotWidthKey.self) { titleSlotWidth = $0 }
        .onHover { isHovering = $0 }
        // 首帧 / 布局参数变化直接落到目标宽，避免新 Tab 从 defaultMin 扩到自然宽的左→右动画。
        .onAppear {
            appearTime = Date()
            updateRetainedWidth(immediate: true, animated: false)
        }
        .onChange(of: title) {
            // 标题稳定窗口（shell 初始化）内不带动画；之后才走平滑过渡。
            updateRetainedWidth(
                immediate: isFixedWidth || iconOnly,
                animated: Date().timeIntervalSince(appearTime) > 0.8
            )
        }
        .onChange(of: manualTitle) { applyManualTitleWidth() }
        .onChange(of: paneCount) { updateRetainedWidth(immediate: isFixedWidth || iconOnly) }
        .onChange(of: minWidth) { updateRetainedWidth(immediate: true, animated: false) }
        .onChange(of: maxWidth) { updateRetainedWidth(immediate: true, animated: false) }
        .onChange(of: iconOnly) { updateRetainedWidth(immediate: true, animated: false) }
        .onDisappear { shrinkTask?.cancel() }
    }

    @ViewBuilder
    private var tabIcon: some View {
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

        // Agent 绿点始终挂在 overlay 上，靠 isActive 渐显/渐隐，避免状态结束时瞬间卸载。
        iconBase
            .overlay(alignment: .bottomTrailing) {
                AgentWorkingStatusDot(isActive: isAgentWorking)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAgentWorking {
                    if isAgentBlocked {
                        // Agent Blocked（等待介入/确认）：图标右下角橙色点
                        Circle()
                            .fill(Color(red: 0.96, green: 0.62, blue: 0.14))
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: 2)
                            .accessibilityLabel(L10n.t("Blocked"))
                    } else if isAgentUnread && iconOnly {
                        // 仅图标模式：未读蓝点挂在图标右下（无右侧标题区）。
                        Circle()
                            .fill(Color(nsColor: .systemBlue))
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: 2)
                            .accessibilityLabel(L10n.t("Unread"))
                    } else if !isAgentUnread && isTaskTab {
                        TaskStatusOverlayView(
                            isExecuting: isTerminalRunning,
                            hasError: taskHasError,
                            tint: isSelected ? Color(nsColor: Theme.cursor) : Theme.secondaryColor
                        )
                    } else if iconOnly && isDirty {
                        // 仅图标时仍提示未保存：右下小圆点。
                        Circle()
                            .fill(Theme.secondaryColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: 2)
                    }
                }
            }
    }

    /// 根据 AppKit 测得的标题自然宽度更新显示宽度：扩张即时生效，收缩等待一段时间后再执行。
    /// `immediate` 用于最小/最大宽度随标签条挤满/放宽变化时立刻应用，避免仍卡在旧的 retainedWidth。
    /// `animated == false` 用于首帧与条带布局重算，避免新开 Tab 出现左→右展开动画。
    private func updateRetainedWidth(immediate: Bool = false, animated: Bool = true) {
        func applyWidth(_ width: CGFloat, useAnimation: Bool) {
            guard width != retainedWidth else { return }
            if useAnimation {
                withAnimation(.easeInOut(duration: 0.16)) {
                    retainedWidth = width
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    retainedWidth = width
                }
            }
        }

        // 弹性固定宽：直接采用分配值，不做标题防抖。
        if isFixedWidth || iconOnly {
            shrinkTask?.cancel()
            shrinkTask = nil
            applyWidth(min(minWidth, maxWidth), useAnimation: animated)
            return
        }

        // 图标、关闭/修改状态、左右内边距和元素间距占用的固定宽度。
        let accessoryWidth = TabStripMetrics.accessoryWidth(paneCount: paneCount)
        // 与 Tab 标题 SwiftUI 字号保持一致，避免测宽偏小导致文字被裁切。
        let titleWidth = TabStripMetrics.idealTitleWidth(title)
        // 下限不超过上限（挤满时 min 130 / max 140）；始终夹在 [floor, max] 内。
        let floorWidth = min(minWidth, maxWidth)
        let desiredWidth = min(
            max(titleWidth + accessoryWidth, floorWidth),
            maxWidth
        )

        if immediate {
            shrinkTask?.cancel()
            shrinkTask = nil
            applyWidth(desiredWidth, useAnimation: animated)
            return
        }

        guard desiredWidth < retainedWidth else {
            shrinkTask?.cancel()
            shrinkTask = nil
            guard desiredWidth != retainedWidth else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    retainedWidth = desiredWidth
                }
            } else {
                applyWidth(desiredWidth, useAnimation: false)
            }
            return
        }

        shrinkTask?.cancel()
        let widthBeforeDelay = retainedWidth
        shrinkTask = Task { @MainActor in
            try? await Task.sleep(for: Self.shrinkDelay)
            guard !Task.isCancelled, retainedWidth == widthBeforeDelay else { return }
            if animated {
                withAnimation(.easeInOut(duration: 0.2)) {
                    retainedWidth = desiredWidth
                }
            } else {
                applyWidth(desiredWidth, useAnimation: false)
            }
        }
    }

    /// 用户完成手动改名后不等待自动标题的防抖时间，立即更新为新标题所需宽度。
    private func applyManualTitleWidth() {
        updateRetainedWidth(immediate: true)
    }
}

/// 标题 Text 实际槽位宽度（由 `TabItemChrome` 上报）。
private struct TabTitleSlotWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 标题被截断 / 仅图标时，在 Tab 上方显示完整标题。
/// 使用独立 NSPanel 的 macTooltip，避免贴窗顶/窗边被裁切。
private struct TabTruncatedTitleTooltip: ViewModifier {
    let title: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.macTooltip(title, position: .top)
        } else {
            content
        }
    }
}

/// Terminal: 前台已知应用 → TerminalAppIcon；Agent 工作中 → 呼吸绿点；Task 标志 → 右下角 indicator；其他情况 → SF Symbol。
/// Open files / diffs use Material icons (same as the Files tree).
struct TabContentIcon: View {
    let content: PaneContent?
    var showsCommandSpinner = false
    let tint: Color
    @ObservedObject private var agentWatcher = AgentWatcher.shared
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
            let isAgentWorking = agentWatcher.snapshot(for: session.id)?.status == .working
            let isAgentUnread = agentWatcher.isUnread(sessionID: session.id)
            iconBase
                .overlay(alignment: .bottomTrailing) {
                    AgentWorkingStatusDot(isActive: isAgentWorking)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isAgentWorking {
                        if isAgentUnread {
                            Circle()
                                .fill(Color(nsColor: .systemBlue))
                                .frame(width: 5, height: 5)
                                .offset(x: 2, y: 2)
                                .accessibilityLabel(L10n.t("Unread"))
                        } else if session.isTaskRunning {
                            TaskStatusOverlayView(
                                isExecuting: showsCommandSpinner,
                                hasError: session.taskHasError,
                                tint: tint
                            )
                        }
                    }
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
