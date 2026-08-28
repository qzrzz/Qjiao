//
//  SidebarView.swift
//  kero
//

import AppKit
import GhosttyTheme
import SwiftUI
import UniformTypeIdentifiers

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var groupStore = ProjectGroupStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @AppStorage("leftSidebarWidth") private var width: Double = 220
    @State private var draggedProjectID: UUID?
    @State private var projectFrames: [UUID: CGRect] = [:]
    @State private var groupTabFrames: [String: CGRect] = [:]
    @State private var dropTargetGroupID: String?
    @State private var groupSearchText: String = ""
    /// 侧栏点击抢先选中；内容区 `selectedProjectID` 跟上后清掉。
    @State private var localChromeProjectID: UUID?
    /// 当前窗口是否置顶（`NSWindow.level == .floating`）。
    @State private var isWindowAlwaysOnTop = false
    /// Finder 等外部文件夹拖入侧栏时的高亮反馈。
    @State private var isFolderDropTargeted = false

    var body: some View {
        let _ = l10n.language
        VStack(alignment: .leading, spacing: 0) {
            // Header-height strip: traffic lights on the left; pin + collapse
            // on the right (outer margin matches the main header's right-sidebar
            // button so both edges read as the same inset).
            ZStack(alignment: .trailing) {
                WindowDragArea()
                HStack(spacing: HeaderTabActionMetrics.spacing) {
                    HeaderIconButton(
                        systemImage: isWindowAlwaysOnTop ? "pin.fill" : "pin",
                        isActive: isWindowAlwaysOnTop,
                        help: isWindowAlwaysOnTop
                            ? L10n.t("Stop Keeping on Top")
                            : L10n.t("Keep Window on Top"),
                        helpAlignment: .trailing,
                        action: toggleWindowAlwaysOnTop
                    )
                    HeaderIconButton(
                        systemImage: "sidebar.left",
                        isActive: true,
                        help: L10n.t("Toggle Left Sidebar (⌘B)"),
                        helpAlignment: .trailing,
                        action: { manager.toggleLeftSidebar() }
                    )
                }
                .padding(.trailing, HeaderTabActionMetrics.edgePadding)
            }
            .frame(height: 38)
            .background(WindowLevelReader(isAlwaysOnTop: $isWindowAlwaysOnTop))

            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 3) {
                        if showsGroupSearch {
                            SidebarGroupSearchField(text: $groupSearchText)
                        }

                        let visible = filteredVisibleProjects
                        if visible.isEmpty {
                            Text(emptyGroupText)
                                .font(SidebarTypography.caption(.regular))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, project in
                                SidebarProjectRow(
                                    manager: manager,
                                    project: project,
                                    index: index,
                                    isSelected: project.id == displayedSelectedProjectID,
                                    select: { selectProject(project) },
                                    close: { manager.close(project) },
                                    isDragging: draggedProjectID == project.id,
                                    onDrag: { updateProjectDrag(source: project.id, location: $0) },
                                    onDragEnded: endProjectDrag
                                )
                                .background(ProjectFrameReader(projectID: project.id))
                            }
                        }
                        // 动态填满最后一个项目行与底部栏之间的空白区域。
                        let dragAreaHeight = listDragAreaHeight(
                            in: viewport.frame(in: .global)
                        )
                        WindowDragArea()
                            .frame(maxWidth: .infinity)
                            .frame(height: dragAreaHeight)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }
                .scrollIndicators(.never)
            }

            SidebarProjectGroupBar(
                manager: manager,
                groupStore: groupStore,
                dropTargetGroupID: dropTargetGroupID
            )

            ZStack {
                // 底部按钮之间的空白区域可用于拖动窗口，按钮本身仍保持可点击。
                WindowDragArea()

                HStack(spacing: 2) {
                    SidebarFooterButton(
                        systemImage: "plus",
                        tooltip: L10n.t("New Project (⌘N)")
                    ) { manager.newProject() }
                    SidebarMoreMenu(manager: manager)
                    Spacer()
                    SidebarThemeButton(settings: settings)
                    SidebarFooterButton(
                        systemImage: "gearshape",
                        tooltip: L10n.t("Settings (⌘,)"),
                        tooltipAlignment: .trailing
                    ) { openWindow(id: "settings") }
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(height: 1)
            }
        }
        .frame(width: width)
        .background {
            Group {
                if Theme.isDefault(dark: colorScheme == .dark) {
                    VisualEffectView()
                    Color(nsColor: Theme.sidebar).opacity(0.5)
                } 
                else {
                    VisualEffectView()
                    Color(nsColor: Theme.sidebar).opacity(0.7)
                }
            }
        }
        .overlay {
            // 外部文件夹拖入侧栏时的边框提示。
            if isFolderDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            SidebarResizeHandle(
                edge: .trailing,
                width: $width,
                range: 160...400,
                defaultWidth: 220
            )
        }
        // 仅左侧边栏接收「以文件夹创建/激活项目」的 drop，不与终端路径 drop 抢手势。
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isFolderDropTargeted,
            perform: handleFolderDrop
        )
        .onPreferenceChange(ProjectFramePreferenceKey.self) { projectFrames = $0 }
        .onPreferenceChange(GroupTabFramePreferenceKey.self) { groupTabFrames = $0 }
        .onChange(of: groupStore.selectedID) { _, _ in
            groupSearchText = ""
        }
        .onChange(of: manager.selectedProjectID) { _, id in
            if localChromeProjectID == id {
                localChromeProjectID = nil
            } else if localChromeProjectID != nil, id != localChromeProjectID {
                localChromeProjectID = nil
            }
        }
        .onChange(of: manager.chromeSelectedProjectID) { _, id in
            if localChromeProjectID != nil, id != localChromeProjectID {
                localChromeProjectID = nil
            }
        }
    }

    /// 侧栏即时选中：本地点击 > manager chrome > 内容选中。
    private var displayedSelectedProjectID: UUID? {
        localChromeProjectID ?? manager.chromeSelectedProjectID ?? manager.selectedProjectID
    }

    private func selectProject(_ project: Project) {
        localChromeProjectID = project.id
        manager.selectProject(id: project.id, paintChrome: false)
    }

    private var showsGroupSearch: Bool {
        groupStore.selectedID == ProjectGroup.archivedID
            && !manager.archivedProjects.isEmpty
    }

    private var filteredVisibleProjects: [Project] {
        let projects = manager.visibleProjects
        let query = groupSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(query)
                || (project.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var emptyGroupText: String {
        let query = groupSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return L10n.t("No matching projects")
        }
        switch groupStore.selectedID {
        case ProjectGroup.archivedID:
            return L10n.t("No archived projects")
        case ProjectGroup.currentID:
            return L10n.t("No open projects")
        default:
            return L10n.t("No projects in this group")
        }
    }

    /// 从 Finder 拖入文件夹到左侧边栏：已有同路径项目则激活，否则新建。
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
                Task { @MainActor in
                    _ = manager.addProject(at: url)
                }
            }
        }
        return accepted
    }

    private func updateProjectDrag(source: UUID, location: CGPoint) {
        draggedProjectID = source
        NSCursor.closedHand.set()
        if let tabID = groupTabFrames.first(where: { $0.value.contains(location) })?.key {
            dropTargetGroupID = tabID
            return
        }
        dropTargetGroupID = nil
        guard let target = projectFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            manager.moveProject(source, to: target)
        }
    }

    private func endProjectDrag() {
        if let source = draggedProjectID,
           let tabID = dropTargetGroupID,
           let project = manager.projects.first(where: { $0.id == source }) {
            withAnimation(.easeInOut(duration: 0.15)) {
                manager.assign(project, toGroupID: tabID)
            }
        }
        draggedProjectID = nil
        dropTargetGroupID = nil
        NSCursor.arrow.set()
    }

    /// 计算列表最后一行到视口底部的距离，确保整段空白都能拖动窗口。
    private func listDragAreaHeight(in viewport: CGRect) -> CGFloat {
        guard let lastRowBottom = projectFrames.values.map(\.maxY).max() else {
            return max(0, viewport.height - 8)
        }
        // 预留 VStack 行间距，避免拖拽区把 ScrollView 内容撑出滚动范围。
        return max(0, viewport.maxY - lastRowBottom - 3)
    }

    /// 切换侧栏所在窗口的置顶状态。
    private func toggleWindowAlwaysOnTop() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        window.isAlwaysOnTop.toggle()
        isWindowAlwaysOnTop = window.isAlwaysOnTop
    }
}

/// 读取并同步宿主 `NSWindow` 的置顶状态，供侧栏 pin 按钮展示激活态。
private struct WindowLevelReader: NSViewRepresentable {
    @Binding var isAlwaysOnTop: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isAlwaysOnTop: _isAlwaysOnTop)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.sync(from: view)
    }

    final class Coordinator {
        var isAlwaysOnTop: Binding<Bool>
        private var observer: NSObjectProtocol?

        init(isAlwaysOnTop: Binding<Bool>) {
            self.isAlwaysOnTop = isAlwaysOnTop
        }

        func attach(_ view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let view = view else { return }
                self?.sync(from: view)
            }
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: .windowAlwaysOnTopDidChange,
                    object: nil,
                    queue: .main
                ) { [weak self, weak view] _ in
                    guard let view = view else { return }
                    self?.sync(from: view)
                }
            }
        }

        func sync(from view: NSView) {
            guard let window = view.window else { return }
            let pinned = window.isAlwaysOnTop
            if isAlwaysOnTop.wrappedValue != pinned {
                isAlwaysOnTop.wrappedValue = pinned
            }
        }

        deinit {
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

private struct SidebarFooterButton: View {
    let systemImage: String
    let tooltip: String
    /// Buttons near the sidebar's right edge anchor `.trailing` so the label
    /// grows inward instead of off-panel.
    var tooltipAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(isHovering ? Theme.primaryColor : Theme.secondaryColor)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, alignment: tooltipAlignment)
    }
}

/// 侧边栏底部的主题切换按钮：
/// - 左键点击：在亮色/暗色主题之间立即切换（若当前为 System，则根据系统实际外观反转设置）
/// - 右键点击：弹出包含 Theme 选项的上下文菜单
private struct SidebarThemeButton: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    var body: some View {
        Button(action: toggleTheme) {
            Image(systemName: appearanceIcon)
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(isHovering ? Theme.primaryColor : Theme.secondaryColor)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(L10n.format("Theme: %@", settings.theme.title), alignment: .trailing)
        .contextMenu {
            ForEach(AppTheme.allCases) { theme in
                Toggle(isOn: Binding(
                    get: { settings.theme == theme },
                    set: { if $0 { settings.theme = theme } }
                )) {
                    Text(theme.title)
                }
            }
            Divider()
            Button(L10n.t("Appearance Settings")) {
                openWindow(id: "settings")
            }
        }
    }

    /// 点击切换主题
    /// - 如果当前是 Light，变为 Dark
    /// - 如果当前是 Dark，变为 Light
    /// - 如果当前是 System，获取实际主题是 Light 还是 Dark，反转设置为 Light 或 Dark
    private func toggleTheme() {
        switch settings.theme {
        case .light:
            settings.theme = .dark
        case .dark:
            settings.theme = .light
        case .system:
            let isEffectiveDark = (colorScheme == .dark)
            settings.theme = isEffectiveDark ? .light : .dark
        }
    }

    /// 获取主题对应的图标
    private var appearanceIcon: String {
        switch settings.theme {
        case .dark:
            return "moon.fill"
        case .light:
            return "sun.max.fill"
        case .system:
            return colorScheme == .dark ? "moon.fill" : "sun.max.fill"
        }
    }
}

private struct ProjectFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct GroupTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct GroupTabFrameReader: View {
    let groupID: String

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(
                key: GroupTabFramePreferenceKey.self,
                value: [groupID: frame]
            )
        }
    }
}

private struct ProjectFrameReader: View {
    let projectID: UUID

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(
                key: ProjectFramePreferenceKey.self,
                value: [projectID: frame]
            )
        }
    }
}

private struct SidebarProjectRow: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var project: Project
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var isIconPickerPresented = false
    @State private var isEditingDescription = false
    @State private var isCloseConfirmationPresented = false
    @State private var isAISelectIconErrorPresented = false
    @State private var aiSelectIconError: String?
    @State private var isAIProjectMetaErrorPresented = false
    @State private var aiProjectMetaError: String?
    @State private var renameDraft = ""
    @State private var descriptionDraft = ""
    @FocusState private var renameFocused: Bool
    @FocusState private var descriptionFocused: Bool
    /// 共享后台任务状态：菜单关闭后项目行仍可显示进度。
    @ObservedObject private var aiIconTasks = LocalAIIconTaskStore.shared
    @ObservedObject private var aiMetaTasks = LocalAIProjectMetaTaskStore.shared
    @ObservedObject private var agentWatcher = AgentWatcher.shared

    /// 项目侧栏状态枚举（按优先级降序：运行中 > Agent 阻塞待确认 > Agent 工作中 > Agent 未读 > 无状态）。
    private enum ProjectSidebarStatus: Equatable {
        /// 运行中状态（Tab 图标下转圈状态）
        case running
        /// Agent 阻塞待确认状态（橙色圆点）
        case agentBlocked
        /// Agent 工作中状态（呼吸绿点）
        case agentWorking
        /// Agent 未读状态（蓝色数字角标）
        case agentUnread(count: Int)
        /// 无状态（显示快捷键或空）
        case none
    }

    /// 项目是否有 Tab 处于运行中状态。
    private var isProjectRunning: Bool {
        project.tabs.contains { tab in
            tab.isTaskRunning || tab.sessions.contains { s in
                s.isTaskRunning || manager.isRightSidebarCommandRunning(sessionID: s.id)
            }
        }
    }

    /// 项目是否有 Agent 处于阻塞待确认状态。
    private var isProjectAgentBlocked: Bool {
        project.sessions.contains { session in
            agentWatcher.snapshot(for: session.id)?.status == .blocked
        }
    }

    /// 项目是否有 Agent 处于工作中状态。
    private var isProjectAgentWorking: Bool {
        project.sessions.contains { session in
            agentWatcher.snapshot(for: session.id)?.status == .working
        }
    }

    /// 该项目下 Agent 未读 session 数。
    private var agentUnreadCount: Int {
        agentWatcher.unreadCount(for: project)
    }

    /// 计算当前项目的侧栏状态（遵从优先级：运行中 > Agent 阻塞待确认 > Agent 工作中 > Agent 未读 > 无状态）。
    private var projectSidebarStatus: ProjectSidebarStatus {
        if isProjectRunning {
            return .running
        }
        if isProjectAgentBlocked {
            return .agentBlocked
        }
        if isProjectAgentWorking {
            return .agentWorking
        }
        let unread = agentUnreadCount
        if unread > 0 {
            return .agentUnread(count: unread)
        }
        return .none
    }

    /// 项目状态指示图标/角标视图。
    @ViewBuilder
    private func projectStatusIndicator(for status: ProjectSidebarStatus) -> some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(Color(nsColor: Theme.cursor))
                .frame(width: 16, height: 16)
        case .agentBlocked:
            Circle()
                .fill(Color(red: 0.96, green: 0.62, blue: 0.14))
                .frame(width: 6, height: 6)
                .frame(width: 16, height: 16)
                .accessibilityLabel(L10n.t("Blocked"))
        case .agentWorking:
            AgentWorkingStatusDot(isActive: true, dotOffset: .zero, size: 6)
                .frame(width: 16, height: 16)
        case .agentUnread(let count):
            projectAgentUnreadBadge(count: count)
        case .none:
            EmptyView()
        }
    }

    var body: some View {
        Group {
            if isRenaming || isEditingDescription {
                rowContent
            } else {
                Button(action: select) {
                    rowContent
                }
                .buttonStyle(.plain)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { onDrag($0.location) }
                        .onEnded { _ in onDragEnded() }
                )
            }
        }
        .opacity(isDragging ? 0.65 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.primaryColor.opacity(0.09) : (isHovering ? Theme.primaryColor.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
        .contextMenu { projectContextMenu }
        .sheet(isPresented: $isIconPickerPresented) {
            ProjectIconPicker(project: project)
        }
        .alert(L10n.t("Close Project?"), isPresented: $isCloseConfirmationPresented) {
            Button(L10n.t("Delete Project"), role: .destructive, action: close)
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("This will close the project and its terminal sessions."))
        }
        .alert(L10n.t("AI Select Icon"), isPresented: $isAISelectIconErrorPresented) {
            Button(L10n.t("OK"), role: .cancel) {
                aiIconTasks.clearError(project.id)
            }
        } message: {
            Text(aiSelectIconError ?? L10n.t("Failed to select icon."))
        }
        .alert(L10n.t("AI Name & Desc & Icon"), isPresented: $isAIProjectMetaErrorPresented) {
            Button(L10n.t("OK"), role: .cancel) {
                aiMetaTasks.clearError(project.id)
            }
        } message: {
            Text(aiProjectMetaError ?? L10n.t("Failed to generate project metadata."))
        }
        .onChange(of: aiIconTasks.states[project.id]?.lastError) { _, newError in
            // 后台任务失败时弹一次 alert（进行中不打扰）
            guard let newError, !newError.isEmpty,
                  aiIconTasks.states[project.id]?.isRunning != true
            else { return }
            aiSelectIconError = newError
            isAISelectIconErrorPresented = true
        }
        .onChange(of: aiMetaTasks.states[project.id]?.lastError) { _, newError in
            guard let newError, !newError.isEmpty,
                  aiMetaTasks.states[project.id]?.isRunning != true
            else { return }
            aiProjectMetaError = newError
            isAIProjectMetaErrorPresented = true
        }
    }

    @ViewBuilder
    private var projectContextMenu: some View {
        Button {
            openProjectDirectory()
        } label: {
            Label(L10n.t("Open in Finder"), systemImage: "finder")
        }
        Button {
            manager.selectedProjectID = project.id
            let dir = project.selectedSession?.currentDirectoryPath
            manager.newSession(directory: dir)
        } label: {
            Label(L10n.t("Open in Terminal"), systemImage: "terminal")
        }
        Button {
            openConfigFolder()
        } label: {
            Label(L10n.t("Open Config Folder"), systemImage: "finder")
        }
        
        Divider()
        Button(L10n.t("Rename…")) {
            beginRename()
        }

        Button(L10n.t("Edit Description…")) {
            beginDescriptionEdit()
        }
        Button(L10n.t("Change Icon…")) {
            isIconPickerPresented = true
        }
        Toggle(L10n.t("Use Automatic Title"), isOn: $project.useAutoTitle)
        Divider()
        // ── AI：名称 + 描述 + 图标
        if aiMetaTasks.isRunning(project.id) {
            Button {
                aiMetaTasks.cancel(project.id)
            } label: {
                Label(L10n.t("Cancel AI Name & Desc & Icon"), systemImage: "xmark.circle")
            }
        } else {
            Button {
                startAIProjectMeta()
            } label: {
                Label(L10n.t("AI Name & Desc & Icon"), systemImage: "wand.and.stars")
            }
            .disabled(!LocalAI.isEnabled || aiIconTasks.isRunning(project.id))
        }
        // ── AI：仅图标
        if aiIconTasks.isRunning(project.id) {
            Button {
                aiIconTasks.cancel(project.id)
            } label: {
                Label(L10n.t("Cancel AI Select Icon"), systemImage: "xmark.circle")
            }
        } else {
            Button {
                startAISelectIcon()
            } label: {
                Label(L10n.t("AI Select Icon"), systemImage: "sparkles")
            }
            .disabled(!LocalAI.isEnabled || aiMetaTasks.isRunning(project.id))
        }

        Divider()
        Menu(L10n.t("Theme")) {
            Toggle(isOn: Binding(
                get: { project.theme.followsGlobal },
                set: { if $0 { project.theme = .global } }
            )) {
                Label {
                    Text(L10n.t("Follow Global Settings"))
                } icon: {
                    Image(nsImage: ThemePreviewImageRenderer.image(for: [
                        Theme.globalDefinition(dark: false),
                        Theme.globalDefinition(dark: true)
                    ]))
                }
                .labelStyle(.titleAndIcon)
            }
            Divider()
            projectAppearanceThemeMenu(dark: false)
            projectAppearanceThemeMenu(dark: true)
        }

        Divider()
        Menu(L10n.t("Move to Group")) {
            ForEach(ProjectGroupStore.shared.userGroups) { group in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.assign(project, toGroupID: group.id)
                    }
                } label: {
                    if (project.groupID ?? ProjectGroup.personalID) == group.id, !project.isArchived {
                        Label(group.displayName, systemImage: "checkmark")
                    } else {
                        Text(group.displayName)
                    }
                }
            }
            if (project.groupID ?? ProjectGroup.personalID) != ProjectGroup.personalID {
                Divider()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.ungroupProject(project)
                    }
                } label: {
                    Label(L10n.t("Ungroup"), systemImage: "minus.circle")
                }
            }
        }
        if project.isArchived {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    manager.unarchiveProject(project)
                }
            } label: {
                Label(L10n.t("Unarchive Project"), systemImage: "tray.and.arrow.up")
            }
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    manager.archiveProject(project)
                }
            } label: {
                Label(L10n.t("Archive Project"), systemImage: "archivebox")
            }
        }
        Divider()
        Button(L10n.t("Close Project")) {
            close()
        }
    }

    /// 任一 AI 任务进行中（行内转圈共用）。
    private var isAnyAITaskRunning: Bool {
        aiIconTasks.isRunning(project.id) || aiMetaTasks.isRunning(project.id)
    }

    /// 右键菜单：提交后台 AI 选图标（不阻塞 UI）。
    private func startAISelectIcon() {
        guard LocalAI.isEnabled else {
            aiSelectIconError =
                L10n.t("AI is disabled. Configure a provider in Settings → AI.")
            isAISelectIconErrorPresented = true
            return
        }
        aiIconTasks.start(for: project)
    }

    /// 右键菜单：后台生成名称、描述与图标。
    private func startAIProjectMeta() {
        guard LocalAI.isEnabled else {
            aiProjectMetaError =
                L10n.t("AI is disabled. Configure a provider in Settings → AI.")
            isAIProjectMetaErrorPresented = true
            return
        }
        aiMetaTasks.start(for: project)
    }

    /// 项目图标位：AI 任务进行中显示转圈，菜单关掉后仍可见。
    private var projectIconSlot: some View {
        let size: CGFloat = project.isArchived ? 16 : 24
        let running = isAnyAITaskRunning
        let helpText: String = {
            if aiMetaTasks.isRunning(project.id) {
                return aiMetaTasks.state(for: project.id).providerLabel.map {
                    "AI generating name, description & icon via \($0)…"
                } ?? "AI generating name, description & icon…"
            }
            if aiIconTasks.isRunning(project.id) {
                return aiIconTasks.state(for: project.id).providerLabel.map {
                    "AI selecting icon via \($0)…"
                } ?? "AI selecting icon…"
            }
            return ""
        }()
        return ZStack {
            ProjectIconView(
                icon: project.icon,
                isSelected: isSelected,
                size: size
            )
            .opacity(running ? 0.25 : 1)

            if running {
                ProgressView()
                    .controlSize(project.isArchived ? .mini : .small)
                    .help(helpText)
            }
        }
        .frame(width: size, height: size)
    }

    private var hasSubtitle: Bool {
        if isEditingDescription { return true }
        if let description = project.description,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            projectIconSlot

            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(SidebarTypography.body(.medium))
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: renameFocused) {
                        if !renameFocused, isRenaming {
                            commitRename()
                        }
                    }
            } else if project.isArchived || !hasSubtitle {
                // 已归档项目或无描述项目：单行精简展示项目名称，隐藏第二行副标题
                Text(project.name)
                    .font(project.isArchived ? SidebarTypography.secondary() : SidebarTypography.body())
                    .foregroundStyle(isSelected ? Theme.primaryColor : Theme.secondaryColor)
                    .lineLimit(1)
            } else {
                // 未归档且有描述（或正在编辑描述）：双行呈现（项目名 + 描述）
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(SidebarTypography.body())
                        .foregroundStyle(isSelected ? Theme.primaryColor : Theme.secondaryColor)
                        .lineLimit(1)
                    subtitle
                }
            }

            Spacer(minLength: 0)

            ZStack(alignment: .trailing) {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let status = projectSidebarStatus
                    let hasStatus = status != .none

                    if project.isArchived {
                        // 已归档项目：操作按钮 hover 显隐；状态指示器（运行中/Agent工作中/未读角标）有状态时显示。
                        HStack(spacing: 4) {
                            if hasStatus {
                                projectStatusIndicator(for: status)
                            }
                            HStack(spacing: 4) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        manager.unarchiveProject(project)
                                    }
                                } label: {
                                    Image(systemName: "tray.and.arrow.up")
                                        .font(SidebarTypography.micro(.bold))
                                        .foregroundStyle(Theme.secondaryColor)
                                        .frame(width: 16, height: 16)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(L10n.t("Unarchive Project"))

                                Button(action: requestClose) {
                                    Image(systemName: "xmark")
                                        .font(SidebarTypography.micro(.bold))
                                        .foregroundStyle(Theme.secondaryColor)
                                        .frame(width: 16, height: 16)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .opacity(isHovering && !isRenaming && !isEditingDescription ? 1 : 0)
                        }
                        .opacity(
                            (isHovering && !isRenaming && !isEditingDescription) || hasStatus
                                ? 1 : 0
                        )
                    } else if !isRenaming, !isEditingDescription {
                        HStack(spacing: 5) {
                            // 项目状态区 (按优先级: 运行中 > Agent 工作中 > Agent 未读)
                            projectStatusIndicator(for: status)

                            if isHovering {
                                Button(action: requestClose) {
                                    Image(systemName: "xmark")
                                        .font(SidebarTypography.micro(.bold))
                                        .foregroundStyle(Theme.secondaryColor)
                                        .frame(width: 16, height: 16)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            } else if !hasStatus, index < 9 {
                                // 无状态时显示快捷键 ⌘1~9
                                Text("⌘\(index + 1)")
                                    .font(SidebarTypography.section().monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, project.isArchived ? 3 : 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 项目列表 Agent 未读指示器（蓝色圆点，不带数字）。
    private func projectAgentUnreadBadge(count: Int) -> some View {
        Circle()
            .fill(Color(nsColor: .systemBlue))
            .frame(width: 6, height: 6)
            .frame(width: 16, height: 16)
            .accessibilityLabel(L10n.format("%lld unread", Int64(count)))
    }

    private func beginRename() {
        renameDraft = project.name
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            project.customName = trimmed
            project.useAutoTitle = false
        } else {
            project.customName = nil
        }
        isRenaming = false
    }

    /// 项目某一侧（Light 或 Dark）的配色子菜单；只覆盖该侧，不改亮暗外观。
    @ViewBuilder
    private func projectAppearanceThemeMenu(dark: Bool) -> some View {
        let currentName = dark ? project.theme.dark : project.theme.light
        let preview = Theme.definition(named: currentName ?? "")
            ?? Theme.globalDefinition(dark: dark)
        Menu {
            // 该侧跟随全局
            Toggle(isOn: Binding(
                get: { currentName == nil },
                set: { if $0 {
                    project.theme = dark
                        ? project.theme.withDark(nil)
                        : project.theme.withLight(nil)
                } }
            )) {
                Label {
                    Text(L10n.t("Follow Global Settings"))
                } icon: {
                    Image(nsImage: ThemePreviewImageRenderer.image(for: [
                        Theme.globalDefinition(dark: dark)
                    ]))
                }
                .labelStyle(.titleAndIcon)
            }
            Divider()
            customThemeMenuSection(dark: dark, selection: currentName) { name in
                project.theme = dark
                    ? project.theme.withDark(name)
                    : project.theme.withLight(name)
            }
            ForEach(ThemeMenuCatalog.primary(dark: dark), id: \.self) { name in
                namedProjectSideThemeItem(name: name, dark: dark)
            }
            Section(L10n.t("Cool")) {
                ForEach(ThemeMenuCatalog.cool(dark: dark), id: \.self) { name in
                    namedProjectSideThemeItem(name: name, dark: dark)
                }
            }
            Section(L10n.t("Warm")) {
                ForEach(ThemeMenuCatalog.warm(dark: dark), id: \.self) { name in
                    namedProjectSideThemeItem(name: name, dark: dark)
                }
            }
            Divider()
            Menu {
                ForEach(ThemeMenuCatalog.allIncludingCustom(dark: dark), id: \.self) { name in
                    namedProjectSideThemeItem(name: name, dark: dark)
                }
            } label: {
                themeMenuLabel(
                    dark ? L10n.t("All Dark Themes") : L10n.t("All Light Themes"),
                    definition: Theme.globalDefinition(dark: dark)
                )
            }
        } label: {
            themeMenuLabel(
                dark ? L10n.t("Dark colors") : L10n.t("Light colors"),
                definition: preview
            )
        }
    }

    /// 选中某一侧的具体 Ghostty 主题名（另一侧保持不动）。
    private func namedProjectSideThemeItem(name: String, dark: Bool) -> some View {
        let selected = (dark ? project.theme.dark : project.theme.light) == name
        let definition = Theme.definition(named: name)
            ?? Theme.globalDefinition(dark: dark)
        return Toggle(isOn: Binding(
            get: { selected },
            set: { if $0 {
                project.theme = dark
                    ? project.theme.withDark(name)
                    : project.theme.withLight(name)
            } }
        )) {
            Label {
                Text(name)
            } icon: {
                Image(nsImage: ThemePreviewImageRenderer.image(for: [definition]))
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func themeMenuLabel(_ title: String, definition: GhosttyThemeDefinition) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: ThemePreviewImageRenderer.image(for: [definition]))
        }
        .labelStyle(.titleAndIcon)
    }

    /// 普通点击要求确认；按住 Command 点击时直接关闭项目。
    private func requestClose() {
        if NSEvent.modifierFlags.contains(.command) {
            close()
        } else {
            isCloseConfirmationPresented = true
        }
    }

    /// 在 Finder 中打开项目当前终端所在的目录。
    private func openProjectDirectory() {
        guard let path = project.selectedSession?.currentDirectoryPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 创建并打开当前项目的独立配置目录：`…/projects/{projectId}/`。
    private func openConfigFolder() {
        let directory = ProjectConfigStore.projectDirectoryURL(for: project.id)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            NSLog("qjiao: failed to open config folder \(directory.path): \(error)")
        }
    }

    /// 开始项目描述的行内编辑，并使用当前值作为初始内容。
    private func beginDescriptionEdit() {
        descriptionDraft = project.description ?? ""
        isEditingDescription = true
        DispatchQueue.main.async {
            descriptionFocused = true
        }
    }

    /// 保存描述；空白描述按未设置处理，从而继续显示默认的项目辅助信息。
    private func saveDescription() {
        let trimmed = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        project.description = trimmed.isEmpty ? nil : trimmed
        isEditingDescription = false
    }

    /// 放弃本次描述编辑，不改变已经保存的项目描述。
    private func cancelDescriptionEdit() {
        isEditingDescription = false
    }

    @ViewBuilder
    private var subtitle: some View {
        if isEditingDescription {
            TextField("Description", text: $descriptionDraft)
                .textFieldStyle(.plain)
                .font(SidebarTypography.section())
                .foregroundStyle(Theme.secondaryColor)
                .focused($descriptionFocused)
                .onSubmit(saveDescription)
                .onExitCommand(perform: cancelDescriptionEdit)
                .onChange(of: descriptionFocused) {
                    if !descriptionFocused, isEditingDescription {
                        saveDescription()
                    }
                }
        } else if let description = project.description,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(description)
                .font(SidebarTypography.section())
                .foregroundStyle(Theme.secondaryColor)
                .lineLimit(1)
        }
    }
}

/// 已归档 tab 顶部的搜索框。
private struct SidebarGroupSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(SidebarTypography.micro(.regular))
                .foregroundStyle(.tertiary)

            TextField(L10n.t("Search archived projects..."), text: $text)
                .textFieldStyle(.plain)
                .font(SidebarTypography.secondary(.regular))
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(SidebarTypography.micro(.regular))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.primaryColor.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isFocused
                                ? Color(nsColor: Theme.cursor).opacity(0.5)
                                : Theme.primaryColor.opacity(0.12),
                            lineWidth: 1
                        )
                )
        )
        .padding(.bottom, 2)
        .onAppear { isFocused = true }
    }
}

/// 左侧边栏底部的项目分组 tabs：个人 / 工作 / 当前 / 已归档，以及用户自建分组。
private struct SidebarProjectGroupBar: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var groupStore: ProjectGroupStore
    let dropTargetGroupID: String?

    @ObservedObject private var l10n = L10n.shared
    @State private var renamingGroupID: String?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    @State private var isDeleteGroupPresented = false
    @State private var pendingDeleteGroupID: String?

    private static let barHeight: CGFloat = 34

    var body: some View {
        let _ = l10n.language
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider).opacity(0.6))
                .frame(height: 1)

            GeometryReader { geo in
                let tabs = groupStore.tabs
                let activeIndex = tabs.firstIndex { $0.id == groupStore.selectedID } ?? 0
                let trailingReserve =
                    SidebarTabLayout.collapseButtonSide + SidebarTabLayout.interTabSpacingWide
                let layout = SidebarTabLayout.resolve(
                    items: tabs.enumerated().map { index, group in
                        SidebarTabLayout.MeasureItem(
                            title: group.displayName,
                            badgeCount: index == activeIndex
                                ? manager.projects(inGroupID: group.id).count
                                : 0
                        )
                    },
                    activeIndex: activeIndex,
                    availableWidth: geo.size.width,
                    trailingReserve: trailingReserve,
                    allTitlesExtraSlack: 56
                )
                HStack(alignment: .center, spacing: layout.spacing) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .center, spacing: layout.spacing) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, group in
                                groupTab(group, showTitle: layout.showsTitle(at: index))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    addGroupButton
                }
                .padding(.horizontal, SidebarTabLayout.barHorizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: Self.barHeight)
            .background { WindowDragArea() }
        }
        .alert(
            L10n.t("Delete Group?"),
            isPresented: $isDeleteGroupPresented
        ) {
            Button(L10n.t("Delete Group"), role: .destructive) {
                if let id = pendingDeleteGroupID {
                    manager.deleteProjectGroup(id: id)
                }
                pendingDeleteGroupID = nil
            }
            Button(L10n.t("Cancel"), role: .cancel) {
                pendingDeleteGroupID = nil
            }
        } message: {
            Text(L10n.t("Projects in this group will move to Current."))
        }
    }

    private var addGroupButton: some View {
        Button {
            let group = groupStore.addGroup()
            beginRename(group)
        } label: {
            Image(systemName: "plus")
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: SidebarTabLayout.collapseButtonSide,
                    height: SidebarTabLayout.collapseButtonSide
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(L10n.t("New Group"))
    }

    @ViewBuilder
    private func groupTab(_ group: ProjectGroup, showTitle: Bool) -> some View {
        let isSelected = groupStore.selectedID == group.id
        let isDropTarget = dropTargetGroupID == group.id
        let count = manager.projects(inGroupID: group.id).count
        let isRenaming = renamingGroupID == group.id
        let isActive = isSelected || isDropTarget

        Group {
            if isRenaming {
                renameChip(group: group)
            } else {
                Button {
                    groupStore.selectedID = group.id
                } label: {
                    SidebarTabChip(
                        systemImage: group.systemImage,
                        title: group.displayName,
                        isActive: isActive,
                        showTitle: showTitle,
                        badgeCount: isActive ? count : 0
                    )
                }
                .buttonStyle(.plain)
                .help(groupTabHelp(group))
                .accessibilityLabel(group.displayName)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }
        }
        .background(GroupTabFrameReader(groupID: group.id))
        .contextMenu { groupContextMenu(group) }
    }

    private func renameChip(group: ProjectGroup) -> some View {
        HStack(alignment: .center, spacing: SidebarTabLayout.iconTitleSpacing) {
            Image(systemName: group.systemImage)
                .font(SidebarTypography.caption(.medium))
                .frame(
                    width: SidebarTabLayout.iconSide,
                    height: SidebarTabLayout.iconSide
                )
            TextField("", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(SidebarTypography.secondary(.medium))
                .focused($renameFocused)
                .frame(minWidth: 36, maxWidth: 80)
                .onSubmit { commitRename(group) }
                .onExitCommand { cancelRename() }
                .onChange(of: renameFocused) { _, focused in
                    if !focused, renamingGroupID == group.id {
                        commitRename(group)
                    }
                }
        }
        .foregroundStyle(.primary)
        .padding(.leading, SidebarTabLayout.horizontalPaddingWithTitle)
        .padding(
            .trailing,
            SidebarTabLayout.horizontalPaddingWithTitle + SidebarTabLayout.trailingPaddingExtra
        )
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.09))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func groupTabHelp(_ group: ProjectGroup) -> String {
        switch group.kind {
        case .current:
            return L10n.t("Currently open projects")
        case .archived:
            return L10n.t("Archived projects")
        case .user:
            return group.displayName
        }
    }

    @ViewBuilder
    private func groupContextMenu(_ group: ProjectGroup) -> some View {
        if group.isRenamable {
            Button(L10n.t("Rename Group")) {
                beginRename(group)
            }
        }
        if group.isDeletable {
            Button(L10n.t("Delete Group"), role: .destructive) {
                pendingDeleteGroupID = group.id
                isDeleteGroupPresented = true
            }
        }
        if group.isRenamable || group.isDeletable {
            Divider()
        }
        Button(L10n.t("New Group")) {
            let created = groupStore.addGroup()
            beginRename(created)
        }
    }

    private func beginRename(_ group: ProjectGroup) {
        guard group.isRenamable else { return }
        renamingGroupID = group.id
        renameDraft = group.displayName
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename(_ group: ProjectGroup) {
        groupStore.renameGroup(id: group.id, to: renameDraft)
        renamingGroupID = nil
        renameFocused = false
    }

    private func cancelRename() {
        renamingGroupID = nil
        renameFocused = false
    }
}

/// 侧边栏底部更多按钮及弹出菜单：
/// - 打开文件夹…
/// - AI 整理全部
/// - 归档全部
/// - 清理空项目
private struct SidebarMoreMenu: View {
    @ObservedObject var manager: TerminalManager

    var body: some View {
        SidebarFooterButton(
            systemImage: "ellipsis",
            tooltip: L10n.t("More Options")
        ) {
            showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let itemOpen = NSMenuItem(
            title: L10n.t("Open Folder…"),
            action: #selector(SidebarMenuActionTarget.performAction),
            keyEquivalent: ""
        )
        if let img = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) {
            itemOpen.image = img
        }
        let tOpen = SidebarMenuActionTarget { openFolderPanel() }
        itemOpen.target = tOpen
        menu.addItem(itemOpen)

        menu.addItem(NSMenuItem.separator())

        let itemAI = NSMenuItem(
            title: L10n.t("AI Organize All"),
            action: #selector(SidebarMenuActionTarget.performAction),
            keyEquivalent: ""
        )
        if let img = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil) {
            itemAI.image = img
        }
        let tAI = SidebarMenuActionTarget { aiOrganizeAll() }
        itemAI.target = tAI
        if !LocalAI.isEnabled {
            itemAI.isEnabled = false
        }
        menu.addItem(itemAI)

        menu.addItem(NSMenuItem.separator())

        let itemArchive = NSMenuItem(
            title: L10n.t("Archive All"),
            action: #selector(SidebarMenuActionTarget.performAction),
            keyEquivalent: ""
        )
        if let img = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil) {
            itemArchive.image = img
        }
        let tArchive = SidebarMenuActionTarget { manager.archiveAllProjects() }
        itemArchive.target = tArchive
        menu.addItem(itemArchive)

        let itemClean = NSMenuItem(
            title: L10n.t("Clean Empty Projects"),
            action: #selector(SidebarMenuActionTarget.performAction),
            keyEquivalent: ""
        )
        if let img = NSImage(systemSymbolName: "trash", accessibilityDescription: nil) {
            itemClean.image = img
        }
        let tClean = SidebarMenuActionTarget { cleanEmptyProjects() }
        itemClean.target = tClean
        menu.addItem(itemClean)

        let targets = [tOpen, tAI, tArchive, tClean]
        objc_setAssociatedObject(menu, "targets", targets, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        if let event = NSApp.currentEvent, let window = event.window, let contentView = window.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                manager.addProject(at: url)
            }
        }
    }

    private func aiOrganizeAll() {
        for project in manager.activeProjects {
            LocalAIProjectMetaTaskStore.shared.start(for: project)
        }
    }

    private func cleanEmptyProjects() {
        let emptyProjects = manager.projects.filter { project in
            project.sessions.isEmpty && (project.customName == nil || project.customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
        }

        if emptyProjects.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.t("No Empty Projects Found")
            alert.informativeText = L10n.t("There are no projects without terminals and without custom names.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.t("OK"))
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.t("Clean Empty Projects?")
        alert.informativeText = L10n.format("Found %lld projects matching cleanup conditions, clean up?", emptyProjects.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("Clean Up"))
        alert.addButton(withTitle: L10n.t("Cancel"))

        if alert.runModal() == .alertFirstButtonReturn {
            let count = emptyProjects.count
            for project in emptyProjects {
                manager.close(project)
            }

            let resultAlert = NSAlert()
            resultAlert.messageText = L10n.t("Cleanup Complete")
            resultAlert.informativeText = L10n.format("Cleaned up %lld projects.", count)
            resultAlert.alertStyle = .informational
            resultAlert.addButton(withTitle: L10n.t("OK"))
            resultAlert.runModal()
        }
    }
}

@MainActor
private final class SidebarMenuActionTarget: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    @objc func performAction() {
        closure()
    }
}

