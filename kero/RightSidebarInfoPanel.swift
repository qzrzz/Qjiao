//
//  RightSidebarInfoPanel.swift
//  kero
//

import AppKit
import SwiftUI

// MARK: - Info panel（当前终端会话）

/// 当前终端 cwd + cwd 下 scripts / Gradle / Just / Cargo / CMake / Makefile Tasks + 本 session 进程/端口。
struct SessionInfoPanel: View {
    @ObservedObject var model: SessionInfoModel
    @ObservedObject var manager: TerminalManager
    let projectID: UUID
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
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            TopToolsOpenSection(path: model.cwdPath, manager: manager)
                            PackageScriptsSection(
                                projectID: projectID,
                                directory: model.cwdPath,
                                scripts: model.packageScripts,
                                records: manager.packageScriptRecords,
                                isCollapsed: $packageScriptsCollapsed,
                                runPackageScript: runPackageScript,
                                stopPackageScript: { manager.stopPackageScript($0) },
                                restartPackageScript: {
                                    manager.restartPackageScript(
                                        $0,
                                        mode: $1,
                                        directory: model.cwdPath
                                    )
                                },
                                openPackageJSON: openPackageJSON
                            )
                            if !model.gradleScripts.isEmpty || GradleScriptProvider.isGradleProject(at: model.cwdPath) {
                                UniversalTasksSection(
                                    configuration: .gradle,
                                    projectID: projectID,
                                    defaultDirectory: model.cwdPath,
                                    scripts: model.gradleScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $gradleTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.cwdPath
                                        )
                                    },
                                    restartScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    }
                                )
                            }
                            if !model.justScripts.isEmpty || JustScriptProvider.isJustProject(at: model.cwdPath) {
                                UniversalTasksSection(
                                    configuration: .just,
                                    projectID: projectID,
                                    defaultDirectory: model.cwdPath,
                                    scripts: model.justScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $justTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.cwdPath
                                        )
                                    },
                                    restartScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    }
                                )
                            }
                            if !model.cargoScripts.isEmpty || CargoScriptProvider.isCargoProject(at: model.cwdPath) {
                                UniversalTasksSection(
                                    configuration: .cargo,
                                    projectID: projectID,
                                    defaultDirectory: model.cwdPath,
                                    scripts: model.cargoScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $cargoTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.cwdPath
                                        )
                                    },
                                    restartScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    }
                                )
                            }
                            if !model.cmakeScripts.isEmpty || CMakeScriptProvider.isCMakeProject(at: model.cwdPath) {
                                UniversalTasksSection(
                                    configuration: .cmake,
                                    projectID: projectID,
                                    defaultDirectory: model.cwdPath,
                                    scripts: model.cmakeScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $cmakeTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.cwdPath
                                        )
                                    },
                                    restartScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    }
                                )
                            }
                            if !model.makefileScripts.isEmpty || MakefileScriptProvider.isMakefileProject(at: model.cwdPath) {
                                UniversalTasksSection(
                                    configuration: .makefile,
                                    projectID: projectID,
                                    defaultDirectory: model.cwdPath,
                                    scripts: model.makefileScripts,
                                    records: manager.packageScriptRecords,
                                    isCollapsed: $makefileTasksCollapsed,
                                    runScript: { script, mode in
                                        manager.runProjectScript(script, mode: mode)
                                    },
                                    stopScript: { script in
                                        manager.stopProjectScript(
                                            script,
                                            fallbackDirectory: model.cwdPath
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

                        // 填满 SessionInfo 面板底部剩余空白区域，允许拖拽移动窗口
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
        // Session Info 面板 Header 空白区域允许拖拽移动窗口
        .background { WindowDragArea() }
    }
}

struct InfoProcessRow: View {
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

struct InfoPortRow: View {
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
