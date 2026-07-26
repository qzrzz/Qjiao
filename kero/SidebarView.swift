//
//  SidebarView.swift
//  kero
//

import AppKit
import GhosttyTheme
import SwiftUI

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @AppStorage("leftSidebarWidth") private var width: Double = 220
    @State private var draggedProjectID: UUID?
    @State private var projectFrames: [UUID: CGRect] = [:]
    /// 当前窗口是否置顶（`NSWindow.level == .floating`）。
    @State private var isWindowAlwaysOnTop = false

    var body: some View {
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
                            ? "Stop Keeping on Top"
                            : "Keep Window on Top",
                        helpAlignment: .trailing,
                        action: toggleWindowAlwaysOnTop
                    )
                    HeaderIconButton(
                        systemImage: "sidebar.left",
                        isActive: true,
                        help: "Toggle Left Sidebar (⌘B)",
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
                        ForEach(Array(manager.projects.enumerated()), id: \.element.id) { index, project in
                            SidebarProjectRow(
                                project: project,
                                index: index,
                                isSelected: project.id == manager.selectedProjectID,
                                select: { manager.selectedProjectID = project.id },
                                close: { manager.close(project) },
                                isDragging: draggedProjectID == project.id,
                                onDrag: { updateProjectDrag(source: project.id, location: $0) },
                                onDragEnded: endProjectDrag
                            )
                            .background(ProjectFrameReader(projectID: project.id))
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
            }

            ZStack {
                // 底部按钮之间的空白区域可用于拖动窗口，按钮本身仍保持可点击。
                WindowDragArea()

                HStack(spacing: 2) {
                    SidebarFooterButton(
                        systemImage: "plus",
                        tooltip: "New Project (⌘N)"
                    ) { manager.newProject() }
                    Spacer()
                    SidebarThemeButton(settings: settings)
                    SidebarFooterButton(
                        systemImage: "gearshape",
                        tooltip: "Settings (⌘,)",
                        tooltipAlignment: .trailing
                    ) { openSettings() }
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
        .overlay(alignment: .trailing) {
            if !Theme.isDefault(dark: colorScheme == .dark) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(width: 1)
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
        .onPreferenceChange(ProjectFramePreferenceKey.self) { projectFrames = $0 }
    }

    private func updateProjectDrag(source: UUID, location: CGPoint) {
        draggedProjectID = source
        NSCursor.closedHand.set()
        guard let target = projectFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            manager.moveProject(source, to: target)
        }
    }

    private func endProjectDrag() {
        draggedProjectID = nil
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

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            sync(from: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            sync(from: view)
        }
    }

    private func sync(from view: NSView) {
        guard let window = view.window else { return }
        let pinned = window.isAlwaysOnTop
        if isAlwaysOnTop != pinned {
            isAlwaysOnTop = pinned
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
                .foregroundStyle(isHovering ? .primary : .secondary)
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
    @Environment(\.openSettings) private var openSettings
    @State private var isHovering = false

    var body: some View {
        Button(action: toggleTheme) {
            Image(systemName: appearanceIcon)
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip("Theme: \(settings.theme.title)", alignment: .trailing)
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
            Button("Appearance Settings") {
                openSettings()
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
    @State private var renameDraft = ""
    @State private var descriptionDraft = ""
    @FocusState private var renameFocused: Bool
    @FocusState private var descriptionFocused: Bool

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
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…") {
                beginRename()
            }
            if project.customName != nil {
                Button("Use Automatic Title") {
                    project.customName = nil
                }
            }
            Button("Edit Description…") {
                beginDescriptionEdit()
            }
            Menu("Theme") {
                projectThemeItem(.global)
                curatedThemeMenu(dark: false)
                Divider()
                curatedThemeMenu(dark: true)
            }
            Divider()
            Button {
                openProjectDirectory()
            } label: {
                Label("Open in Finder", systemImage: "finder")
            }
            Button {
                openConfigFolder()
            } label: {
                Label("Open Config Folder", systemImage: "finder")
            }
            Divider()
            Button("Change Icon…") {
                isIconPickerPresented = true
            }
            if project.icon != nil {
                Button("Clear Icon") {
                    project.icon = nil
                }
            }
            Divider()
            Button("Close Project") {
                close()
            }
        }
        .sheet(isPresented: $isIconPickerPresented) {
            ProjectIconPicker(project: project)
        }
        .alert("Close Project?", isPresented: $isCloseConfirmationPresented) {
            Button("Delete Project", role: .destructive, action: close)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will close the project and its terminal sessions.")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            ProjectIconView(icon: project.icon, isSelected: isSelected)

            VStack(alignment: .leading, spacing: 1) {
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
                } else {
                    Text(project.name)
                        .font(SidebarTypography.body())
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
                subtitle
            }

            Spacer(minLength: 0)

            if isHovering, !isRenaming, !isEditingDescription {
                Button(action: requestClose) {
                    Image(systemName: "xmark")
                        .font(SidebarTypography.micro(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if index < 9, !isRenaming, !isEditingDescription {
                Text("⌘\(index + 1)")
                    .font(SidebarTypography.section())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
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
        project.customName = trimmed.isEmpty ? nil : trimmed
        isRenaming = false
    }

    @ViewBuilder
    private func projectThemeItem(_ theme: ProjectTheme) -> some View {
        Toggle(isOn: Binding(
            get: { project.theme == theme },
            set: { if $0 { project.theme = theme } }
        )) {
            Label {
                Text("Follow Global Settings")
            } icon: {
                Image(nsImage: ThemePreviewImageRenderer.image(for: [
                    Theme.globalDefinition(dark: false),
                    Theme.globalDefinition(dark: true)
                ]))
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func namedProjectThemeItem(name: String, dark: Bool) -> some View {
        let theme: ProjectTheme = if dark {
            .dark(name: name)
        } else {
            .light(name: name)
        }
        let definition = Theme.definition(named: name)
            ?? Theme.globalDefinition(dark: dark)
        return Toggle(isOn: Binding(
            get: { project.theme == theme },
            set: { if $0 { project.theme = theme } }
        )) {
            Label {
                Text(name)
            } icon: {
                Image(nsImage: ThemePreviewImageRenderer.image(for: [definition]))
            }
            .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private func curatedThemeMenu(dark: Bool) -> some View {
        Menu {
            ForEach(ThemeMenuCatalog.primary(dark: dark), id: \.self) { name in
                namedProjectThemeItem(name: name, dark: dark)
            }
            Section("Cool") {
                ForEach(ThemeMenuCatalog.cool(dark: dark), id: \.self) { name in
                    namedProjectThemeItem(name: name, dark: dark)
                }
            }
            Section("Warm") {
                ForEach(ThemeMenuCatalog.warm(dark: dark), id: \.self) { name in
                    namedProjectThemeItem(name: name, dark: dark)
                }
            }
            Divider()
            allThemeMenu(dark: dark, title: "全部 \(dark ? "Dark" : "Light") 主题")
        } label: {
            themeMenuLabel(dark ? "Dark" : "Light", dark: dark)
        }
    }

    @ViewBuilder
    private func allThemeMenu(dark: Bool, title: String) -> some View {
        Menu {
            ForEach(ThemeMenuCatalog.all(dark: dark), id: \.self) { name in
                namedProjectThemeItem(name: name, dark: dark)
            }
        } label: {
            themeMenuLabel(title, dark: dark)
        }
    }

    private func themeMenuLabel(_ title: String, dark: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: ThemePreviewImageRenderer.image(
                for: [Theme.globalDefinition(dark: dark)]
            ))
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

    /// 创建并打开当前项目配置所在的 Qjiao 配置目录。
    private func openConfigFolder() {
        let directory = AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("projects", isDirectory: true)
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
                .foregroundStyle(.secondary)
                .focused($descriptionFocused)
                .onSubmit(saveDescription)
                .onExitCommand(perform: cancelDescriptionEdit)
                .onChange(of: descriptionFocused) {
                    if !descriptionFocused, isEditingDescription {
                        saveDescription()
                    }
                }
        } else if let description = project.description, !description.isEmpty {
            Text(description)
                .font(SidebarTypography.section())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if project.sessions.count > 1 {
            Text("\(project.sessions.count) sessions")
                .font(SidebarTypography.section())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let session = project.selectedSession {
            SessionDirectoryLabel(session: session)
        }
    }
}

/// Small subtitle showing a session's current directory; separate view so
/// it observes the session's own published working directory.
private struct SessionDirectoryLabel: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let dir = session.directoryLabel {
            Text(dir)
                .font(SidebarTypography.section())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
