//
//  TasksPanel.swift
//  kero
//

import AppKit
import SwiftUI

/// 右侧下半区 Tasks tab：项目根目录下的 npm scripts 与各语言工程任务。
struct TasksPanel: View {
    @ObservedObject var model: ProjectPanelModel
    @ObservedObject var project: Project
    @ObservedObject var manager: TerminalManager
    let runPackageScript: (String, TerminalManager.PackageScriptRunMode) -> Void
    let openPackageJSON: () -> Void

    @ObservedObject private var l10n = L10n.shared

    @State private var packageScriptsCollapsed = false
    @State private var gradleTasksCollapsed = false
    @State private var justTasksCollapsed = false
    @State private var cargoTasksCollapsed = false
    @State private var cmakeTasksCollapsed = false
    @State private var makefileTasksCollapsed = false

    private var hasAnyTaskSection: Bool {
        !model.packageScripts.isEmpty
            || !model.gradleScripts.isEmpty
            || !model.justScripts.isEmpty
            || JustScriptProvider.isJustProject(at: model.rootPath)
            || !model.cargoScripts.isEmpty
            || CargoScriptProvider.isCargoProject(at: model.rootPath)
            || !model.cmakeScripts.isEmpty
            || CMakeScriptProvider.isCMakeProject(at: model.rootPath)
            || !model.makefileScripts.isEmpty
            || MakefileScriptProvider.isMakefileProject(at: model.rootPath)
    }

    var body: some View {
        let _ = l10n.language
        Group {
            if hasAnyTaskSection {
                taskList
            } else {
                emptyTasks
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .onAppear {
            if model.packageScripts.isEmpty { packageScriptsCollapsed = true }
            if model.gradleScripts.isEmpty { gradleTasksCollapsed = true }
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
        }
        .background { WindowDragArea() }
    }

    private var taskList: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        if !model.packageScripts.isEmpty {
                            TasksGridSection(
                                title: L10n.t("NPM SCRIPTS"),
                                emptyText: "No package scripts in package.json",
                                missingToolText: nil,
                                isToolInstalled: true,
                                scripts: npmScripts,
                                projectID: project.id,
                                records: manager.packageScriptRecords,
                                isCollapsed: $packageScriptsCollapsed,
                                runScript: { script, mode in
                                    runPackageScript(script.name, mode)
                                },
                                stopScript: { script in
                                    manager.stopProjectScript(
                                        script,
                                        fallbackDirectory: model.rootPath
                                    )
                                },
                                restartScript: { script, mode in
                                    manager.restartPackageScript(
                                        script.name,
                                        mode: mode,
                                        directory: model.rootPath
                                    )
                                },
                                openPackageJSON: openPackageJSON
                            )
                        }
                        if !model.gradleScripts.isEmpty {
                            gridSection(
                                configuration: .gradle,
                                scripts: model.gradleScripts,
                                isCollapsed: $gradleTasksCollapsed
                            )
                        }
                        if !model.justScripts.isEmpty || JustScriptProvider.isJustProject(at: model.rootPath) {
                            gridSection(
                                configuration: .just,
                                scripts: model.justScripts,
                                isCollapsed: $justTasksCollapsed
                            )
                        }
                        if !model.cargoScripts.isEmpty || CargoScriptProvider.isCargoProject(at: model.rootPath) {
                            gridSection(
                                configuration: .cargo,
                                scripts: model.cargoScripts,
                                isCollapsed: $cargoTasksCollapsed
                            )
                        }
                        if !model.cmakeScripts.isEmpty || CMakeScriptProvider.isCMakeProject(at: model.rootPath) {
                            gridSection(
                                configuration: .cmake,
                                scripts: model.cmakeScripts,
                                isCollapsed: $cmakeTasksCollapsed
                            )
                        }
                        if !model.makefileScripts.isEmpty || MakefileScriptProvider.isMakefileProject(at: model.rootPath) {
                            gridSection(
                                configuration: .makefile,
                                scripts: model.makefileScripts,
                                isCollapsed: $makefileTasksCollapsed
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)

                    WindowDragArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 20)
                }
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    private var npmScripts: [UniversalProjectScript] {
        model.packageScripts.map {
            UniversalProjectScript(
                name: $0.name,
                command: $0.command,
                category: .npm,
                directory: model.rootPath
            )
        }
    }

    private var emptyTasks: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.square")
                .font(SidebarTypography.emptyInlineIcon())
                .foregroundStyle(.tertiary)
            Text(L10n.t("No scripts or tasks"))
                .font(SidebarTypography.body(.medium))
                .foregroundStyle(.secondary)
            Text(L10n.t("Add npm scripts, Justfile, Makefile, or other task files"))
                .font(SidebarTypography.section())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("No scripts or tasks"))
    }

    private func gridSection(
        configuration: UniversalTasksSectionConfiguration,
        scripts: [UniversalProjectScript],
        isCollapsed: Binding<Bool>
    ) -> some View {
        TasksGridSection(
            title: configuration.title,
            emptyText: configuration.emptyText,
            missingToolText: configuration.missingToolText,
            isToolInstalled: configuration.isToolInstalled,
            scripts: scripts,
            projectID: project.id,
            records: manager.packageScriptRecords,
            isCollapsed: isCollapsed,
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
            },
            openPackageJSON: nil
        )
    }
}

/// 未选中项目时的 Tasks 空状态。
struct TasksPanelNoProject: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.square")
                .font(SidebarTypography.emptyInlineIcon())
                .foregroundStyle(.tertiary)
            Text(L10n.t("No project selected"))
                .font(SidebarTypography.body(.medium))
                .foregroundStyle(.secondary)
            Text(L10n.t("Open a project to run tasks"))
                .font(SidebarTypography.section())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .background { WindowDragArea() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("No project selected for tasks"))
    }
}

// MARK: - Two-column grid

private struct TasksGridSection: View {
    let title: String
    let emptyText: String
    let missingToolText: String?
    let isToolInstalled: Bool
    let scripts: [UniversalProjectScript]
    let projectID: UUID
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void
    let stopScript: (UniversalProjectScript) -> Void
    let restartScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void
    let openPackageJSON: (() -> Void)?

    private static let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        SidebarSectionHeader(
            title: title,
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            VStack(alignment: .leading, spacing: 4) {
                if !isToolInstalled, let missingToolText {
                    missingToolWarning(missingToolText)
                }

                if scripts.isEmpty {
                    sidebarEmptyRow(emptyText)
                } else {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                        ForEach(scripts) { script in
                            TaskGridCell(
                                script: script,
                                record: records[script.executionKey(projectID: projectID)],
                                run: { runScript(script, $0) },
                                stop: { stopScript(script) },
                                restart: { restartScript(script, $0) },
                                openPackageJSON: openPackageJSON
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func missingToolWarning(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(SidebarTypography.micro())
                .foregroundStyle(.orange)
            Text(L10n.t(text))
                .font(SidebarTypography.caption())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// 两列网格中的单个任务按钮：操作与 Project 任务行一致（运行/停止、重新运行、打开网页）。
private struct TaskGridCell: View {
    let script: UniversalProjectScript
    let record: TerminalManager.PackageScriptExecutionRecord?
    let run: (UniversalScriptRunMode) -> Void
    let stop: () -> Void
    let restart: (UniversalScriptRunMode) -> Void
    let openPackageJSON: (() -> Void)?

    @State private var isHovering = false
    @State private var isHoveringActionBtn = false
    @State private var isHoveringRestartBtn = false
    @State private var isHoveringBrowser = false

    private var status: TerminalManager.PackageScriptStatus {
        record?.status ?? .idle
    }

    private var boundPort: Int? {
        record?.boundPort
    }

    private var tooltip: String {
        if script.category == .npm, !script.command.isEmpty {
            return script.command
        }
        return script.category.buildExecutionCommand(
            scriptName: script.name,
            rawCommand: script.command,
            directory: script.directory
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            actionButton

            Text(script.name)
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(isHovering || status == .running ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            rightContent
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: SidebarTypography.rowMinHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(cellFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(count: 2) {
            guard status == .idle else { return }
            run(.normal)
        }
        .onHover { isHovering = $0 }
        .macTooltip(tooltip, position: .bottom, delay: 0.8)
        .contextMenu {
            if let port = boundPort {
                Button("Open http://localhost:\(port) in Browser") {
                    openLocalhost(port)
                }
                Divider()
            }
            if status == .running {
                Button(L10n.t("Stop")) { stop() }
                Button(L10n.t("Restart")) { restart(.normal) }
            } else {
                Button(L10n.t("Run")) { run(.normal) }
            }
            if let openPackageJSON {
                Button(L10n.t("Edit package.json")) { openPackageJSON() }
            }
            Divider()
            Button(L10n.t("Run with time")) { run(.withTime) }
            if script.category == .npm {
                Button(L10n.t("Run with --inspect")) { run(.withInspect) }
                Button(L10n.t("Run with --prof")) { run(.withProf) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(script.name)
    }

    private var cellFill: Color {
        switch status {
        case .running:
            return Color(nsColor: Theme.cursor).opacity(isHovering ? 0.16 : 0.10)
        case .stopping:
            return Color.red.opacity(0.08)
        case .idle:
            return isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.045)
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
                            .fill(
                                isHoveringActionBtn
                                    ? Color(nsColor: Theme.cursor)
                                    : (isHovering ? Color.primary.opacity(0.08) : Color.clear)
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringActionBtn = $0 }
            .help(L10n.t("Run"))
            .accessibilityLabel(L10n.t("Run"))

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
            .help(L10n.t("Stop"))
            .accessibilityLabel(L10n.t("Stop"))

        case .stopping:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        HStack(spacing: 2) {
            if let port = boundPort {
                Button {
                    openLocalhost(port)
                } label: {
                    Image(systemName: "globe")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(isHoveringBrowser ? Color.white : Color(nsColor: Theme.cursor))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(
                                    isHoveringBrowser
                                        ? Color(nsColor: Theme.cursor)
                                        : Color(nsColor: Theme.cursor).opacity(0.12)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringBrowser = $0 }
                .help("Open http://localhost:\(port) in browser")
                .accessibilityLabel("Open http://localhost:\(port) in browser")
            }

            switch status {
            case .idle:
                EmptyView()

            case .running:
                Button {
                    restart(.normal)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(isHoveringRestartBtn ? Color.white : Color(nsColor: Theme.cursor))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(
                                    isHoveringRestartBtn
                                        ? Color(nsColor: Theme.cursor)
                                        : (isHovering ? Color.primary.opacity(0.08) : Color.clear)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringRestartBtn = $0 }
                .help(L10n.t("Restart"))
                .accessibilityLabel(L10n.t("Restart"))

            case .stopping:
                EmptyView()
            }
        }
    }

    private func openLocalhost(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") {
            NSWorkspace.shared.open(url)
        }
    }
}
