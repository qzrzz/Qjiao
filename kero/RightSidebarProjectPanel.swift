//
//  RightSidebarProjectPanel.swift
//  kero
//

import AppKit
import SwiftUI

// MARK: - Project panel

/// Project launchers 区块：在 ProjectPanel 中作为 LAUNCHERS 分组展示
private struct LaunchersSection: View {
    @ObservedObject var project: Project
    @Binding var isCollapsed: Bool
    let runCommand: (ProjectLaunchCommand) -> Void
    let runAllCommands: () -> Void

    @State private var expandedCommandID: UUID?
    @State private var draggedCommandID: UUID?
    @State private var commandFrames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarSectionHeader(
                title: "LAUNCHERS",
                count: project.launchCommands.count,
                isCollapsed: $isCollapsed,
                actions: [
                    SidebarSectionHeader.Action(
                        systemImage: "play.fill",
                        help: "Run all launchers in order",
                        perform: runAllCommands
                    ),
                    SidebarSectionHeader.Action(
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

    /// 空状态视图：无 launcher 时显示提示文案与添加按钮，包含内容左边距
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
        .padding(.leading, SidebarPanelMetrics.expandedContentLeading + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }

    private var commandList: some View {
        VStack(spacing: 0) {
            ForEach(project.launchCommands) { command in
                LauncherItemWrapper(
                    command: command,
                    commandBinding: binding(for: command.id),
                    isExpanded: expandedCommandID == command.id,
                    isDragged: draggedCommandID == command.id,
                    run: { runCommand(command) },
                    toggleExpanded: { toggleExpanded(command.id) },
                    delete: { delete(command.id) },
                    onDrag: { location in
                        updateCommandDrag(source: command.id, location: location)
                    },
                    onDragEnded: {
                        endCommandDrag()
                    }
                )
                .background(LauncherFrameReader(commandID: command.id))
            }
        }
        .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        .padding(.trailing, 4)
        .onPreferenceChange(LauncherFramePreferenceKey.self) { frames in
            commandFrames = frames
        }
    }

    private func updateCommandDrag(source: UUID, location: CGPoint) {
        draggedCommandID = source
        NSCursor.closedHand.set()
        guard let targetID = commandFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.snappy(duration: 0.2, extraBounce: 0.05)) {
            project.moveLaunchCommand(id: source, before: targetID)
        }
    }

    private func endCommandDrag() {
        withAnimation(.snappy(duration: 0.2)) {
            draggedCommandID = nil
        }
        NSCursor.arrow.set()
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
struct ProjectPanel: View {
    @ObservedObject var model: ProjectPanelModel
    @ObservedObject var project: Project
    @ObservedObject var manager: TerminalManager
    let runPackageScript: (String, TerminalManager.PackageScriptRunMode) -> Void
    let openPackageJSON: () -> Void
    let runLaunchCommand: (ProjectLaunchCommand) -> Void
    let runAllLaunchCommands: () -> Void

    @State private var packageInfoCollapsed = false
    @State private var launchersCollapsed = false
    @State private var packageScriptsCollapsed = false
    @State private var gradleTasksCollapsed = false
    @State private var justTasksCollapsed = false
    @State private var cargoTasksCollapsed = false
    @State private var cmakeTasksCollapsed = false
    @State private var makefileTasksCollapsed = false
    @State private var processesCollapsed = false
    @State private var portsCollapsed = false

    @State private var isIconHovered = false
    @State private var isIconPickerPresented = false

    @FocusState private var isNameFocused: Bool
    @State private var nameDraft = ""

    @FocusState private var isDescFocused: Bool
    @State private var descDraft = ""

    @State private var isNameHovered = false
    @State private var isDescHovered = false

    private func syncDrafts() {
        if !isNameFocused {
            nameDraft = project.name
        }
        if !isDescFocused {
            descDraft = project.description ?? ""
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            project.customName = nil
            nameDraft = project.name
        } else {
            project.customName = trimmed
        }
    }

    private func commitDescription() {
        let trimmed = descDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        project.description = trimmed.isEmpty ? nil : trimmed
    }

    private var descriptionPlaceholder: String {
        if isDescFocused { return "Description" }
        if let desc = project.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc
        }
        let n = model.sessionShellCount
        if n > 0 {
            return n == 1 ? "1 session" : "\(n) sessions"
        }
        return "Add description..."
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            TopToolsOpenSection(path: model.rootPath, manager: manager)
                            if let packageInfo = model.packageInfo {
                                PackageInfoSection(
                                    info: packageInfo,
                                    rootPath: model.rootPath,
                                    manager: manager,
                                    isCollapsed: $packageInfoCollapsed,
                                    openPackageJSON: openPackageJSON,
                                    onVersionUpdated: {
                                        model.refresh()
                                    }
                                )
                            }
                            LaunchersSection(
                                project: project,
                                isCollapsed: $launchersCollapsed,
                                runCommand: runLaunchCommand,
                                runAllCommands: runAllLaunchCommands
                            )
                            PackageScriptsSection(
                                projectID: project.id,
                                directory: model.rootPath,
                                scripts: model.packageScripts,
                                records: manager.packageScriptRecords,
                                isCollapsed: $packageScriptsCollapsed,
                                runPackageScript: runPackageScript,
                                stopPackageScript: { manager.stopPackageScript($0) },
                                restartPackageScript: {
                                    manager.restartPackageScript(
                                        $0,
                                        mode: $1,
                                        directory: model.rootPath
                                    )
                                },
                                openPackageJSON: openPackageJSON
                            )
                            if !model.gradleScripts.isEmpty || GradleScriptProvider.isGradleProject(at: model.rootPath) {
                                UniversalTasksSection(
                                    configuration: .gradle,
                                    projectID: project.id,
                                    defaultDirectory: model.rootPath,
                                    scripts: model.gradleScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $gradleTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.rootPath
                                        )
                                    },
                                    restartScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    }
                                )
                            }
                            if !model.justScripts.isEmpty || JustScriptProvider.isJustProject(at: model.rootPath) {
                                UniversalTasksSection(
                                    configuration: .just,
                                    projectID: project.id,
                                    defaultDirectory: model.rootPath,
                                    scripts: model.justScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $justTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.rootPath
                                        )
                                    },
                                    restartScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    }
                                )
                            }
                            if !model.cargoScripts.isEmpty || CargoScriptProvider.isCargoProject(at: model.rootPath) {
                                UniversalTasksSection(
                                    configuration: .cargo,
                                    projectID: project.id,
                                    defaultDirectory: model.rootPath,
                                    scripts: model.cargoScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $cargoTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.rootPath
                                        )
                                    },
                                    restartScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    }
                                )
                            }
                            if !model.cmakeScripts.isEmpty || CMakeScriptProvider.isCMakeProject(at: model.rootPath) {
                                UniversalTasksSection(
                                    configuration: .cmake,
                                    projectID: project.id,
                                    defaultDirectory: model.rootPath,
                                    scripts: model.cmakeScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $cmakeTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.rootPath
                                        )
                                    },
                                    restartScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    }
                                )
                            }
                            if !model.makefileScripts.isEmpty || MakefileScriptProvider.isMakefileProject(at: model.rootPath) {
                                UniversalTasksSection(
                                    configuration: .makefile,
                                    projectID: project.id,
                                    defaultDirectory: model.rootPath,
                                    scripts: model.makefileScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $makefileTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.rootPath
                                        )
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

                        // 填满 Project 面板底部剩余空白区域，允许拖拽移动窗口
                        WindowDragArea()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: 20)
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
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
        // Project 面板空白区域允许拖拽移动窗口
        .background { WindowDragArea() }
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
        case .preset(let preset):
            ProjectPresetIconImage(preset: preset, size: 22, isSelected: true)
                .frame(width: 24, height: 24)
        case .file(let path):
            ProjectFileIconImage(path: path, size: 22)
                .frame(width: 24, height: 24)
        case nil:
            Image(systemName: "shippingbox")
                .font(SidebarTypography.listIcon())
                .foregroundStyle(Color(nsColor: Theme.cursor))
                .frame(width: 24, height: 24)
        }
    }

    private var iconButton: some View {
        Button {
            isIconPickerPresented = true
        } label: {
            headerIcon
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isIconHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isIconHovered = hovering
        }
        .help("Set Project Icon")
        .popover(isPresented: $isIconPickerPresented, arrowEdge: .bottom) {
            ProjectIconPicker(project: project)
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
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

            HStack(spacing: 4) {
                SidebarIconButton(
                    systemImage: "terminal",
                    help: "Open Terminal",
                    disabled: model.rootPath.isEmpty
                ) {
                    guard !model.rootPath.isEmpty else { return }
                    project.newSession(directory: model.rootPath)
                }

                SidebarIconButton(
                    systemImage: "finder",
                    help: "Open in Finder",
                    disabled: model.rootPath.isEmpty
                ) {
                    guard !model.rootPath.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
                }

                SidebarIconButton(
                    systemImage: "doc.on.doc",
                    help: "Copy Path",
                    disabled: model.rootPath.isEmpty
                ) {
                    guard !model.rootPath.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.rootPath, forType: .string)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                iconButton

                VStack(alignment: .leading, spacing: 1) {
                    ZStack(alignment: .leading) {
                        // 隐藏的 Text 元素，根据当前展示文本/占位符计算自适应宽度
                        Text(nameDraft.isEmpty ? "Project Name" : nameDraft)
                            .font(SidebarTypography.body(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .opacity(0)
                            .accessibilityHidden(true)

                        TextField("Project Name", text: $nameDraft)
                            .textFieldStyle(.plain)
                            .font(SidebarTypography.body(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .focused($isNameFocused)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .onSubmit {
                                commitName()
                            }
                            .onChange(of: isNameFocused) {
                                if !isNameFocused {
                                    commitName()
                                }
                            }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isNameFocused ? Color.primary.opacity(0.06) : (isNameHovered ? Color.primary.opacity(0.04) : Color.clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isNameFocused ? Color(nsColor: Theme.cursor).opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                    .onHover { hovering in
                        isNameHovered = hovering
                    }

                    ZStack(alignment: .leading) {
                        // 隐藏的 Text 元素，根据当前展示文本/占位符计算自适应宽度
                        Text(descDraft.isEmpty ? descriptionPlaceholder : descDraft)
                            .font(SidebarTypography.caption())
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .opacity(0)
                            .accessibilityHidden(true)

                        TextField(descriptionPlaceholder, text: $descDraft)
                            .textFieldStyle(.plain)
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .focused($isDescFocused)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .onSubmit {
                                commitDescription()
                            }
                            .onChange(of: isDescFocused) {
                                if !isDescFocused {
                                    commitDescription()
                                }
                            }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isDescFocused ? Color.primary.opacity(0.06) : (isDescHovered ? Color.primary.opacity(0.04) : Color.clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isDescFocused ? Color(nsColor: Theme.cursor).opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                    .onHover { hovering in
                        isDescHovered = hovering
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SidebarRefreshButton(isRefreshing: model.isRefreshing) {
                    // 先结束输入框编辑，让版本等失焦提交完成后再读取磁盘。
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    DispatchQueue.main.async {
                        model.refresh()
                    }
                }
            }
            pathRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onAppear {
            syncDrafts()
        }
        .onChange(of: project.name) {
            if !isNameFocused {
                nameDraft = project.name
            }
        }
        .onChange(of: project.description) {
            if !isDescFocused {
                descDraft = project.description ?? ""
            }
        }
        // Project 面板 Header 空白区域允许拖拽移动窗口
        .background { WindowDragArea() }
    }
}

/// 显示代码编辑器图标的辅助视图：优先展示应用真实图标，不可用时回退到 SF Symbol。
///
/// 固定以 32×32 物理像素取图（`appIcon()`），再以 `frame(16, 16)` 显示，
/// Retina 2× 屏下正好 1:1 物理像素对应，渲染清晰锐利。
struct CodeEditorIcon: View {
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
struct CodeEditorOpenButton: View {
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
                    HStack(spacing: 4) {
                        CodeEditorIcon(editor: preferred, size: 16)
                        Text(preferred.displayName)
                            .font(SidebarTypography.caption(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .padding(.trailing, 2)
                    .padding(.vertical, 5)
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
                    .frame(width: 18, height: 26)
                    .help("选择代码编辑器")
                } else {
                    Image(systemName: "arrow.up.forward")
                        .font(SidebarTypography.micro())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 26)
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
struct AIToolIcon: View {
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
struct AIToolOpenButton: View {
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
                    HStack(spacing: 4) {
                        AIToolIcon(tool: preferred, size: 16)
                        Text(preferred.displayName)
                            .font(SidebarTypography.caption(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .padding(.trailing, 2)
                    .padding(.vertical, 5)
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
                    .frame(width: 18, height: 26)
                    .help("选择 AI 工具")
                } else {
                    Image(systemName: "arrow.up.forward")
                        .font(SidebarTypography.micro())
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 26)
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
struct AIDropdownNSButton: NSViewRepresentable {
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

            let desktopTools = tools.filter { $0.kind == .desktop }
            let cliTools = tools.filter { $0.kind == .cli }

            // 1. 添加 GUI 桌面应用
            for tool in desktopTools {
                addMenuItem(for: tool)
            }

            // 2. 若同时存在桌面应用与 CLI 工具，插入 CLI 分组标题 Header
            if !desktopTools.isEmpty && !cliTools.isEmpty {
                if #available(macOS 14.0, *) {
                    menu.addItem(NSMenuItem.sectionHeader(title: "CLI"))
                } else {
                    menu.addItem(NSMenuItem.separator())
                    let headerItem = NSMenuItem(title: "CLI", action: nil, keyEquivalent: "")
                    headerItem.isEnabled = false
                    menu.addItem(headerItem)
                }
            }

            // 3. 添加 CLI 命令行工具
            for tool in cliTools {
                addMenuItem(for: tool)
            }
        }

        private func addMenuItem(for tool: AITool) {
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
struct TopToolsOpenSection: View {
    let path: String
    var manager: TerminalManager? = nil

    @ObservedObject private var editorRegistry = CodeEditorRegistry.shared
    @ObservedObject private var aiRegistry = AIToolRegistry.shared

    var body: some View {
        if editorRegistry.preferredEditor != nil || aiRegistry.preferredTool != nil {
            HStack(spacing: 6) {
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
struct EditorDropdownNSButton: NSViewRepresentable {
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
