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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
                                onClosePane: { manager.closePane($0) }
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
        .background(
            WindowChromeAccessor(
                projectTheme: manager.selectedProject?.theme ?? .global,
                onAppearanceChanged: manager.reloadActiveProjectTheme
            )
        )
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: addDroppedProjects)
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
        .onChange(of: manager.selectedProject?.theme) {
            manager.refreshAppearance()
        }
        .onAppear {
            // The window appearance may be applied by WindowChromeAccessor
            // during the first mount; refresh once after that override exists.
            manager.reloadActiveProjectTheme()
        }
    }

    /// 接收从 Finder 拖入窗口的文件夹；每个有效文件夹都会创建一个项目。
    private func addDroppedProjects(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
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
                Task { @MainActor in
                    _ = manager.addProject(at: url)
                }
            }
        }
        return true
    }

    /// Sessions in the visible tab are owned by `TerminalHostView`; every
    /// other session stays window-attached in the invisible parking host.
    private var parkedTerminalSessions: [TerminalSession] {
        let visibleIDs = Set(
            manager.selectedProject?.selectedTab?.sessions.map(\.id) ?? []
        )
        return manager.projects
            .flatMap(\.sessions)
            .filter { !visibleIDs.contains($0.id) }
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
                title: "No open projects",
                buttonTitle: "New Project  ⌘N",
                action: { manager.newProject() }
            )
        } else {
            // A project whose tabs were all closed stays open; offer to reopen
            // a session rather than showing the no-projects prompt.
            emptyStatePrompt(
                title: "No open sessions",
                buttonTitle: "New Session  ⌘T",
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
                .foregroundStyle(.secondary)
            Button(buttonTitle, action: action)
        }
    }
}
/// Slim bar above the terminal: the selected project's sessions as
/// horizontal tabs on the left, sidebar toggle on the right. Doubles as
/// window-drag space.
private struct MainHeaderView: View {
    @ObservedObject var manager: TerminalManager

    /// With the left sidebar hidden the header slides under the window's
    /// traffic-light buttons, so inset its content to clear them.
    private var leadingInset: CGFloat {
        manager.isLeftSidebarVisible ? 8 : 78
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 顶栏未被标签和按钮占用的区域始终可拖动窗口。
                WindowDragArea()

                HStack(spacing: 8) {
                    if let project = manager.selectedProject {
                        // Everything in the header that isn't the scrollable tab
                        // strip: leading inset + trailing padding (8), HStack
                        // spacings (24), tab-list + sidebar toggles (56), "+" and spacing (26),
                        // and the exit-zoom button (24 + 8 spacing) while shown.
                        SessionTabsView(
                            project: project,
                            maxStripWidth: max(0, geo.size.width - leadingInset - 106 - (manager.isPaneZoomed ? 32 : 0))
                        )
                    }
                    Spacer(minLength: 0)
                    // Zoom indicator: only visible while the selected tab has a
                    // zoomed pane. Styled like the sidebar toggle next to it, with
                    // the accent tint marking the active state. Click restores the
                    // layout.
                    if manager.isPaneZoomed {
                        Button {
                            manager.togglePaneZoom()
                        } label: {
                            Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                                .font(SidebarTypography.secondary(.medium))
                                .foregroundStyle(Color(nsColor: Theme.cursor))
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .tooltip("Exit Pane Zoom (⇧⌘↩)", edge: .below, alignment: .trailing)
                    }
                    // No project means the sidebar has nothing to show, so drop
                    // its toggle too — matching the panel collapsing itself.
                    if let project = manager.selectedProject {
                        TabListButton(project: project)
                        Button {
                            manager.toggleSidebar()
                        } label: {
                            Image(systemName: "sidebar.right")
                                .font(SidebarTypography.secondary(.medium))
                                .foregroundStyle(manager.isPanelVisible ? Color(nsColor: Theme.cursor) : .secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .tooltip("Toggle Right Sidebar (⇧⌘B)", edge: .below, alignment: .trailing)
                    }
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, 8)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }
}

/// 顶栏右侧的 Tab 总览入口。用于在标题很长或标签很多时快速切换。
private struct TabListButton: View {
    @ObservedObject var project: Project
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(isPresented ? Color(nsColor: Theme.cursor) : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .tooltip("Show Tab List", edge: .below, alignment: .trailing)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TabListPopover(project: project, isPresented: $isPresented)
        }
    }
}

/// 可滚动的项目 Tab 下拉面板，标题刻意允许换行以完整显示终端标题。
private struct TabListPopover: View {
    @ObservedObject var project: Project
    @Binding var isPresented: Bool
    @StateObject private var terminalDetails = TerminalTabDetailsLoader()
    @State private var currentTime = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tabs")
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

    @ViewBuilder
    private var tabRows: some View {
        ForEach(project.tabs) { tab in
            TabListRow(
                tab: tab,
                isSelected: tab.id == project.selectedTabID,
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
    let terminalDetails: TerminalSession.TabListDetails?
    let currentTime: Date
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                TabContentIcon(
                    content: tab.focusedContent,
                    tint: isSelected ? Color(nsColor: Theme.cursor) : .secondary
                )
                .frame(width: 16, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.displayTitle ?? "Untitled Tab")
                        .font(SidebarTypography.body())
                        .foregroundStyle(isSelected ? .primary : .secondary)
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
                        Label("\(tab.allPanes.count) panes", systemImage: "square.split.2x1")
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
                .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
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
            Label("Loading terminal details…", systemImage: "hourglass")
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

/// Horizontal tabs for one project — terminal sessions and open files —
/// plus a "+" button.
private struct SessionTabsView: View {
    @ObservedObject var project: Project
    @ObservedObject private var settings = AppSettings.shared
    let maxStripWidth: CGFloat
    @State private var overflow = StripOverflow()
    /// 标签条已挤满时把单 Tab 最大宽度从 220 压到 140，腾出可见数量。
    @State private var stripIsFull = false
    @State private var draggedTabID: UUID?
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var renamingTabID: UUID?

    /// Which edges have off-screen tabs, i.e. where to show a fade hint.
    private struct StripOverflow: Equatable {
        var left = false
        var right = false
    }

    /// Scroll 几何快照：边缘淡入 + 是否挤满（用于压缩 Tab 最大宽度）。
    private struct StripGeometry: Equatable {
        var overflow = StripOverflow()
        var contentWidth: CGFloat = 0
        var containerWidth: CGFloat = 0
    }

    /// 标签条未满时的单 Tab 最大宽度。
    private static let relaxedTabMaxWidth: CGFloat = 220
    /// 标签条已满（需要滚动）时的单 Tab 最大宽度。
    private static let compressedTabMaxWidth: CGFloat = 140

    private var tabMaxWidth: CGFloat {
        stripIsFull ? Self.compressedTabMaxWidth : Self.relaxedTabMaxWidth
    }

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(project.tabs) { tab in
                        PaneTabItem(
                            tab: tab,
                            isSelected: tab.id == project.selectedTabID,
                            maxWidth: tabMaxWidth,
                            select: { project.selectedTabID = tab.id },
                            close: { project.close(tab) },
                            renamingTabID: $renamingTabID
                        )
                        .contextMenu { tabContextMenu(for: tab) }
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: TabFramePreferenceKey.self,
                                    value: [tab.id: proxy.frame(in: .global)]
                                )
                            }
                        }
                        .opacity(draggedTabID == tab.id ? 0.65 : 1)
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
            }
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
                    proxy.scrollTo(id)
                }
            }
            .onAppear {
                // Restored sessions may open with an off-screen active tab.
                guard let id = project.selectedTabID else { return }
                DispatchQueue.main.async { proxy.scrollTo(id) }
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
            .frame(maxWidth: maxStripWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            }

            Button {
                project.newSession()
            } label: {
                Image(systemName: "plus")
                    .font(SidebarTypography.compact())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .tooltip("New Session (⌘T)", edge: .below)
        }
        .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
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
        Button("Rename…") { renamingTabID = tab.id }
        if tab.customName != nil {
            Button("Use Automatic Title") { tab.customName = nil }
        }
        Toggle("Disable Zsh Auto Title", isOn: $settings.disableZshAutoTitle)
        Divider()
        if case .file(let file) = tab.focusedContent {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
            Button("Copy Absolute Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Divider()
        }
        Button("Close") { project.close(tab) }
        Button("Close Others") { project.closeOthers(tab) }
            .disabled(project.tabs.count <= 1)
        Button("Close Tabs to the Right") { project.closeToRight(of: tab) }
            .disabled(project.tabs.last?.id == tab.id)
        Divider()
        Button("Close All") { project.closeAll() }
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

/// A tab in the strip. Shows the focused pane's title/icon, with a small
/// counter when the tab holds more than one pane. Observes the tab so focus
/// and layout changes refresh it; the focused content is observed by the
/// per-kind label below so its live title/dirty state shows.
private struct PaneTabItem: View {
    @ObservedObject var tab: PaneTab
    let isSelected: Bool
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
                    customTitle: tab.customName,
                    paneCount: paneCount,
                    isSelected: isSelected,
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
}

/// Inline editor for a tab title; Enter/focus loss commits and Escape cancels.
private struct TabRenameChrome: View {
    let systemImage: String
    /// 打开文件 / Diff 时用 Material 图标，与文件树一致。
    var materialFileName: String? = nil
    let initialValue: String
    let commit: (String) -> Void
    let end: () -> Void
    @State private var draft: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        systemImage: String,
        materialFileName: String? = nil,
        initialValue: String,
        commit: @escaping (String) -> Void,
        end: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.materialFileName = materialFileName
        self.initialValue = initialValue
        self.commit = commit
        self.end = end
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        HStack(spacing: 5) {
            TabStripIconView(systemImage: systemImage, materialFileName: materialFileName, isSelected: true)
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
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.09)))
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
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
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
                isTerminalRunning: session.isForegroundCommandRunning,
                terminalAppIcon: appIcon,
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
            maxWidth: maxWidth,
            select: select,
            close: close
        )
        .help(file.path)
    }
}

/// 顶栏 Tab / 重命名条上的图标：打开文件用 Material Icon，终端等仍用 SF Symbol。
private struct TabStripIconView: View {
    let systemImage: String
    var materialFileName: String? = nil
    var isSelected = false
    /// 顶栏 Tab 条文件图标尺寸。
    private static let materialSize: CGFloat = 13

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
                .font(SidebarTypography.micro())
                .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.cursor)) : AnyShapeStyle(.tertiary))
        }
    }
}

private struct TabItemChrome: View {
    /// 常规 Tab 的最小宽度，避免短标题让标签过于紧凑。
    private static let minimumWidth: CGFloat = 136
    /// 标题缩短后保留当前宽度的时长，避免命令状态频繁变化造成标签抖动。
    private static let shrinkDelay: Duration = .seconds(2)

    let systemImage: String
    /// 非空时优先显示 Material 文件图标（打开的文件 / Diff）。
    var materialFileName: String? = nil
    let title: String
    /// 非空时表示用户手动指定的标签名，应立即采用其对应宽度。
    var manualTitle: String?
    var paneCount: Int = 1
    let isSelected: Bool
    var isDirty = false
    var isTerminalRunning = false
    /// 终端前台进程匹配到的应用图标；有值时优先于转圈动画。
    var terminalAppIcon: TerminalAppIconSource? = nil
    /// 由标签条挤满状态决定：默认 220，挤满时 140。
    var maxWidth: CGFloat = 220
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false
    /// 当前显示宽度会立即扩张，但会延迟收缩，给标题的短暂变化留出缓冲。
    @State private var retainedWidth = minimumWidth
    @State private var shrinkTask: Task<Void, Never>?

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                if let terminalAppIcon {
                    // 识别到 agy / codex 等应用时显示其图标，替代通用转圈。
                    TerminalAppIconView(
                        source: terminalAppIcon,
                        size: 13,
                        isSelected: isSelected
                    )
                    .accessibilityLabel("Running application")
                } else if isTerminalRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(isSelected ? Color(nsColor: Theme.cursor) : .secondary)
                        .frame(width: 11, height: 11)
                        .accessibilityLabel("Command running")
                } else {
                    TabStripIconView(
                        systemImage: systemImage,
                        materialFileName: materialFileName,
                        isSelected: isSelected
                    )
                }
                Text(title)
                    .font(SidebarTypography.body())
                    .foregroundStyle(isSelected ? .primary : .secondary)
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
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if isDirty {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                        .frame(width: 14, height: 14)
                } else {
                    Spacer()
                        .frame(width: 14)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(width: retainedWidth, alignment: .leading)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
        .onAppear { updateRetainedWidth() }
        .onChange(of: title) { updateRetainedWidth() }
        .onChange(of: manualTitle) { applyManualTitleWidth() }
        .onChange(of: paneCount) { updateRetainedWidth() }
        .onChange(of: maxWidth) { updateRetainedWidth(immediate: true) }
        .onDisappear { shrinkTask?.cancel() }
    }

    /// 根据 AppKit 测得的标题自然宽度更新显示宽度：扩张即时生效，收缩等待一段时间后再执行。
    /// `immediate` 用于最大宽度上限被标签条挤满/放宽时立刻应用，避免仍卡在旧的 retainedWidth。
    private func updateRetainedWidth(immediate: Bool = false) {
        // 图标、关闭/修改状态、左右内边距和元素间距占用的固定宽度。
        let accessoryWidth: CGFloat = paneCount > 1 ? 73 : 44
        // 与 Tab 标题 SwiftUI 字号保持一致，避免测宽偏小导致文字被裁切。
        let titleWidth = (title as NSString).size(
            withAttributes: [.font: SidebarTypography.bodyNSFont]
        ).width
        // 挤满时 maxWidth 可能小于 minimumWidth（140 vs 136 仍 ≥）；始终保证不超过上限。
        let floorWidth = min(Self.minimumWidth, maxWidth)
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

/// Terminal: idle → SF Symbol；前台已知应用 → TerminalAppIcon；未知忙 → spinner。
/// Open files / diffs use Material icons (same as the Files tree).
private struct TabContentIcon: View {
    let content: PaneContent?
    let tint: Color
    private static let materialSize: CGFloat = 14

    var body: some View {
        if case .session(let session)? = content {
            if let appIcon = session.foregroundAppIcon {
                TerminalAppIconView(
                    source: appIcon,
                    size: Self.materialSize,
                    isSelected: true
                )
            } else if session.isForegroundCommandRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                    .accessibilityLabel("Command running")
            } else {
                Image(systemName: "terminal")
                    .font(SidebarTypography.secondary(.medium))
                    .foregroundStyle(tint)
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
