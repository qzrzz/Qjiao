//
//  RightSidebarProjectComponents.swift
//  kero
//

import AppKit
import SwiftUI

// MARK: - Project / Info 共用

/// 展开分组内容相对标题的左边距。
enum SidebarPanelMetrics {
    static let expandedContentLeading: CGFloat = 12
}

/// 空 → 收起；0→有内容 → 展开；其余保持用户选择。
func sidebarAutoCollapse(
    oldCount: Int, newCount: Int, isCollapsed: Binding<Bool>
) {
    if newCount == 0 {
        isCollapsed.wrappedValue = true
    } else if oldCount == 0 {
        isCollapsed.wrappedValue = false
    }
}

func sidebarEmptyRow(_ text: String) -> some View {
    Text(L10n.t(text))
        .font(SidebarTypography.secondary())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
}

/// 路径区：展示绝对路径 + Finder / 代码编辑器 / Copy。
struct PathDirectorySection: View {
    let path: String
    @Binding var isCollapsed: Bool
    /// 分组标题，如 "PROJECT" / "CWD"。
    var sectionTitle: String = "DIRECTORY"

    /// 订阅编辑器与 AI 工具注册表，首选变更时自动刷新按钮。
    @ObservedObject private var registry = CodeEditorRegistry.shared
    @ObservedObject private var aiRegistry = AIToolRegistry.shared

    @ObservedObject private var settings = AppSettings.shared

    private var formattedPath: String {
        guard !path.isEmpty else { return "—" }
        if settings.displayShortDirPath {
            return (path as NSString).abbreviatingWithTildeInPath
        }
        return path
    }

    var body: some View {
        SidebarSectionHeader(
            title: sectionTitle, count: 0, isCollapsed: $isCollapsed, actions: []
        )
        if !isCollapsed {
            VStack(alignment: .leading, spacing: 8) {
                Text(formattedPath)
                    .font(SidebarTypography.secondary())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(path)
                    .contextMenu {
                        Button(L10n.t("Copy Path")) { copyPath() }
                            .disabled(path.isEmpty)
                    }

                HStack(spacing: 4) {
                    pathActionButton("Finder", systemImage: "finder") {
                        guard !path.isEmpty else { return }
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    }
                    .disabled(path.isEmpty)
                    // 若检测到已安装的代码编辑器则显示打开按钮。
                    if let preferred = registry.preferredEditor {
                        // 编辑器按钮：使用应用真实图标。
                        Button {
                            registry.open(path: path)
                        } label: {
                            HStack(spacing: 3) {
                                CodeEditorIcon(editor: preferred)
                                Text(preferred.displayName)
                                    .font(SidebarTypography.caption(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(path.isEmpty)
                        .help("Open in \(preferred.displayName)")
                        // 多个编辑器时右键菜单切换默认。
                        .contextMenu {
                            if registry.installedEditors.count > 1 {
                                ForEach(registry.installedEditors) { editor in
                                    Button {
                                        registry.preferredBundleId = editor.bundleId
                                        registry.open(path: path, with: editor)
                                    } label: {
                                        if let icon = editor.iconImage(size: 16) {
                                            Label {
                                                Text(editor.displayName)
                                            } icon: {
                                                Image(nsImage: icon)
                                            }
                                        } else {
                                            Label(editor.displayName, systemImage: editor.symbolName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // 若检测到已安装的 AI 工具则显示打开按钮。
                    if let preferredAI = aiRegistry.preferredTool {
                        Button {
                            aiRegistry.open(path: path, with: preferredAI)
                        } label: {
                            HStack(spacing: 3) {
                                AIToolIcon(tool: preferredAI, size: 12)
                                Text(preferredAI.displayName)
                                    .font(SidebarTypography.caption(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(path.isEmpty)
                        .help("Open in \(preferredAI.displayName)")
                        .contextMenu {
                            if aiRegistry.installedTools.count > 1 {
                                let desktopTools = aiRegistry.installedTools.filter { $0.kind == .desktop }
                                let cliTools = aiRegistry.installedTools.filter { $0.kind == .cli }

                                ForEach(desktopTools) { tool in
                                    Button {
                                        aiRegistry.preferredToolId = tool.id
                                        aiRegistry.open(path: path, with: tool)
                                    } label: {
                                        if let icon = tool.iconImage(size: 16) {
                                            Label {
                                                Text(tool.displayName)
                                            } icon: {
                                                Image(nsImage: icon)
                                            }
                                        } else {
                                            Label(tool.displayName, systemImage: tool.symbolName)
                                        }
                                    }
                                }

                                if !desktopTools.isEmpty && !cliTools.isEmpty {
                                    Divider()
                                }

                                ForEach(cliTools) { tool in
                                    Button {
                                        aiRegistry.preferredToolId = tool.id
                                        aiRegistry.open(path: path, with: tool)
                                    } label: {
                                        if let icon = tool.iconImage(size: 16) {
                                            Label {
                                                Text(tool.displayName)
                                            } icon: {
                                                Image(nsImage: icon)
                                            }
                                        } else {
                                            Label(tool.displayName, systemImage: tool.symbolName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    pathActionButton("Copy", systemImage: "doc.on.doc") {
                        copyPath()
                    }
                    .disabled(path.isEmpty)
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
            .padding(.trailing, 6)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    private func copyPath() {
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func pathActionButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(SidebarTypography.micro())
                Text(title)
                    .font(SidebarTypography.caption(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title == "Copy" ? "Copy Path" : "Open in \(title)")
    }
}

// MARK: - Package scripts / processes 共用区块

func formatScriptDuration(_ duration: TimeInterval) -> String {
    if duration < 1.0 {
        let ms = duration * 1000.0
        let formatted = String(format: "%.1fms", ms)
        return formatted.replacingOccurrences(of: ".0ms", with: "ms")
    } else if duration < 60.0 {
        let formatted = String(format: "%.1fs", duration)
        return formatted.replacingOccurrences(of: ".0s", with: "s")
    } else {
        let min = Int(duration) / 60
        let sec = duration.truncatingRemainder(dividingBy: 60)
        let formattedSec = String(format: "%.1fs", sec)
        let cleanSec = formattedSec.replacingOccurrences(of: ".0s", with: "s")
        return "\(min)m\(cleanSec)"
    }
}

@MainActor
private final class MenuActionTarget: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    @objc func performAction() {
        closure()
    }
}

/// package.json 信息展示分组（包含 name、version、repository 链接与 SemVer 快速递增/Git Tag）
struct PackageInfoSection: View {
    let info: SidebarProbe.PackageInfo
    let rootPath: String
    @ObservedObject var manager: TerminalManager
    @Binding var isCollapsed: Bool
    let openPackageJSON: () -> Void
    let onVersionUpdated: () -> Void

    @State private var isHoveringCopyName = false
    @State private var isHoveringRepo = false
    @State private var isHoveringPlus = false
    @State private var isHoveringMinus = false
    @State private var isHoveringMenu = false
    @State private var isHoveringVersionBox = false

    @FocusState private var isVersionFocused: Bool
    @State private var versionDraft: String = ""
    @State private var versionBaseline: String = ""
    @State private var isVersionDirty: Bool = false
    @State private var isUpdatingVersion: Bool = false

    private var currentDisplayVersion: String {
        if !versionDraft.isEmpty {
            return versionDraft
        }
        let ver = info.version ?? ""
        return (ver.hasPrefix("v") || ver.hasPrefix("V")) ? String(ver.dropFirst()) : ver
    }

    private var pmInfo: SidebarProbe.PackageManagerInfo {
        SidebarProbe.detectPackageManager(
            directory: rootPath,
            globalSetting: AppSettings.shared.packageManagerCommand.rawValue
        )
    }

    private func syncDraftFromInfo(force: Bool = false) {
        guard !isUpdatingVersion, force || !isVersionFocused else { return }
        let ver = info.version ?? ""
        let clean = (ver.hasPrefix("v") || ver.hasPrefix("V")) ? String(ver.dropFirst()) : ver
        versionDraft = clean
        versionBaseline = clean
        isVersionDirty = false
    }

    private func applyVersion(_ newVersion: String) {
        let cleanNew = (newVersion.hasPrefix("v") || newVersion.hasPrefix("V")) ? String(newVersion.dropFirst()) : newVersion
        isUpdatingVersion = true
        versionDraft = cleanNew
        if SidebarProbe.updatePackageVersion(directory: rootPath, newVersion: cleanNew) {
            versionBaseline = cleanNew
            isVersionDirty = false
            onVersionUpdated()
        } else {
            // 写入失败时立即恢复磁盘值，避免后续刷新永远被 updating 状态拦截。
            isUpdatingVersion = false
            syncDraftFromInfo(force: true)
        }
    }

    private func handleInfoVersionChanged() {
        let ver = info.version ?? ""
        let clean = (ver.hasPrefix("v") || ver.hasPrefix("V")) ? String(ver.dropFirst()) : ver
        if isUpdatingVersion {
            if clean == versionDraft {
                isUpdatingVersion = false
            } else {
                // 磁盘结果是最终事实；写入被其他进程覆盖时不保留过期草稿。
                isUpdatingVersion = false
                syncDraftFromInfo()
            }
        } else {
            syncDraftFromInfo()
        }
    }

    private func commitVersionChange() {
        guard isVersionDirty else {
            syncDraftFromInfo(force: true)
            return
        }
        let trimmed = versionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            syncDraftFromInfo(force: true)
            return
        }
        applyVersion(trimmed)
    }

    private var headerMoreMenu: AnyView {
        AnyView(
            Button {
                let menu = NSMenu()

                let itemOpen = NSMenuItem(title: L10n.t("Open package.json"), action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                let tOpen = MenuActionTarget { openPackageJSON() }
                itemOpen.target = tOpen
                menu.addItem(itemOpen)

                menu.addItem(NSMenuItem.separator())

                let itemInstall = NSMenuItem(title: pmInfo.installCommand, action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                let tInstall = MenuActionTarget { manager.runRawCommand(pmInfo.installCommand, title: pmInfo.installCommand, directory: rootPath) }
                itemInstall.target = tInstall
                menu.addItem(itemInstall)

                let itemPublish = NSMenuItem(title: pmInfo.publishCommand, action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                let tPublish = MenuActionTarget { manager.runRawCommand(pmInfo.publishCommand, title: pmInfo.publishCommand, directory: rootPath) }
                itemPublish.target = tPublish
                menu.addItem(itemPublish)

                let itemUpdate = NSMenuItem(title: pmInfo.updateCommand, action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                let tUpdate = MenuActionTarget { manager.runRawCommand(pmInfo.updateCommand, title: pmInfo.updateCommand, directory: rootPath) }
                itemUpdate.target = tUpdate
                menu.addItem(itemUpdate)

                menu.addItem(NSMenuItem.separator())

                let itemTaze = NSMenuItem(title: L10n.t("Update  Deps (npx taze)"), action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                let tTaze = MenuActionTarget { manager.runRawCommand("npx taze", title: L10n.t("npx taze"), directory: rootPath) }
                itemTaze.target = tTaze
                menu.addItem(itemTaze)

                objc_setAssociatedObject(menu, "targets", [tOpen, tInstall, tPublish, tUpdate, tTaze], .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

                if let event = NSApp.currentEvent, let window = event.window, let contentView = window.contentView {
                    NSMenu.popUpContextMenu(menu, with: event, for: contentView)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(L10n.t("More Package Options"))
        )
    }

    var body: some View {
        SidebarSectionHeader(
            title: L10n.t("PACKAGE"),
            count: 0,
            isCollapsed: $isCollapsed,
            actions: [],
            trailingView: headerMoreMenu
        )
        if !isCollapsed {
            VStack(alignment: .leading, spacing: 5) {
                // 第一行：[npm图标] [包名] [复制图标] ------------------ [仓库跳转链接，仅图标]
                HStack(spacing: 4) {
                    ProjectPresetIconImage(preset: .bundled("bxl-npm.svg"), size: 14)

                    if let name = info.name, !name.isEmpty {
                        Text(name)
                            .font(SidebarTypography.secondary(.regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(name, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                                .foregroundStyle(isHoveringCopyName ? Color.primary : Color.secondary)
                                .frame(width: 16, height: 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(isHoveringCopyName ? Color.primary.opacity(0.08) : Color.clear)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringCopyName = $0 }
                        .help("Copy package name (\(name))")
                    } else {
                        Text(L10n.t("package.json"))
                            .font(SidebarTypography.secondary(.regular))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if let repoUrl = info.repositoryUrl, !repoUrl.isEmpty, let url = URL(string: repoUrl) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "link")
                                .font(.system(size: 11))
                                .foregroundStyle(isHoveringRepo ? Color.primary : Color.secondary)
                                .frame(width: 20, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(isHoveringRepo ? Color.primary.opacity(0.08) : Color.clear)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringRepo = $0 }
                        .help("Open Repository: \(repoUrl)")
                    }
                }
                .frame(height: 20)

                // 第二行：自适应宽度的版本输入框 [ v | 1.0.0 ] [ + | - | ⌵ ]
                if info.version != nil {
                    HStack(spacing: 6) {
                        HStack(spacing: 0) {
                            Text("v")
                                .font(SidebarTypography.caption(design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 5)

                            ZStack(alignment: .leading) {
                                let currentText = currentDisplayVersion
                                Text(currentText.isEmpty ? "0.0.0" : currentText)
                                    .font(SidebarTypography.caption(design: .monospaced))
                                    .opacity(0)
                                    .padding(.trailing, 5)
                                    .padding(.leading, 1)

                                TextField("0.0.0", text: $versionDraft)
                                    .font(SidebarTypography.caption(design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textFieldStyle(.plain)
                                    .focused($isVersionFocused)
                                    .padding(.trailing, 5)
                                    .padding(.leading, 1)
                                    .onSubmit {
                                        commitVersionChange()
                                        isVersionFocused = false
                                    }
                                    .onChange(of: isVersionFocused) {
                                        if !isVersionFocused {
                                            // 内容确实修改过才在失焦时写盘；未修改则允许刷新读取外部版本。
                                            commitVersionChange()
                                        }
                                    }
                                    .onChange(of: versionDraft) {
                                        guard !isUpdatingVersion else { return }
                                        isVersionDirty = versionDraft != versionBaseline
                                    }
                                    .onAppear {
                                        syncDraftFromInfo()
                                    }
                                    .onChange(of: info.version) {
                                        handleInfoVersionChanged()
                                    }
                                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                                        syncDraftFromInfo()
                                    }
                            }
                        }
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isHoveringVersionBox || isVersionFocused ? Color.primary.opacity(0.1) : Color.primary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isVersionFocused ? Color.primary.opacity(0.25) : Color.clear, lineWidth: 1)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                        .onHover { isHoveringVersionBox = $0 }

                        let targetVer = currentDisplayVersion
                        let nextBumpVer = SidebarProbe.bumpVersion(targetVer)
                        let nextDecVer = SidebarProbe.decrementVersion(targetVer)
                        let parsed = SidebarProbe.parseSemVer(targetVer)

                        // 连贯一体式的 Segmented Split Control (+ / - / ⌵)
                        HStack(spacing: 0) {
                            // [增加按钮 +]
                            Button {
                                applyVersion(nextBumpVer)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(isHoveringPlus ? Color.primary : Color.secondary)
                                    .frame(width: 18, height: 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(isHoveringPlus ? Color.primary.opacity(0.08) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { isHoveringPlus = $0 }
                            .help("Bump version to \(nextBumpVer)")

                            Divider()
                                .frame(height: 10)
                                .opacity(0.3)

                            // [减少按钮 -]
                            Button {
                                applyVersion(nextDecVer)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(isHoveringMinus ? Color.primary : Color.secondary)
                                    .frame(width: 18, height: 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(isHoveringMinus ? Color.primary.opacity(0.08) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { isHoveringMinus = $0 }
                            .help("Decrement version to \(nextDecVer)")

                            Divider()
                                .frame(height: 10)
                                .opacity(0.3)

                                // [下拉菜单 ⌵] Button 点击弹出 NSMenu
                                Button {
                                    let tagVersion = targetVer.lowercased().hasPrefix("v") ? targetVer : "v\(targetVer)"
                                    let menu = NSMenu()

                                    let itemMajor = NSMenuItem(title: "+ MAJOR ( \(parsed.major) )", action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                                    let tMajor = MenuActionTarget {
                                        applyVersion(parsed.major)
                                    }
                                    itemMajor.target = tMajor
                                    menu.addItem(itemMajor)

                                    let itemMinor = NSMenuItem(title: "+ MINOR ( \(parsed.minor) )", action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                                    let tMinor = MenuActionTarget {
                                        applyVersion(parsed.minor)
                                    }
                                    itemMinor.target = tMinor
                                    menu.addItem(itemMinor)

                                    let itemPatch = NSMenuItem(title: "+ PATCH ( \(parsed.patch) )", action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                                    let tPatch = MenuActionTarget {
                                        applyVersion(parsed.patch)
                                    }
                                    itemPatch.target = tPatch
                                    menu.addItem(itemPatch)

                                    menu.addItem(NSMenuItem.separator())

                                    let itemTag = NSMenuItem(title: "Git tag \(tagVersion)", action: #selector(MenuActionTarget.performAction), keyEquivalent: "")
                                    let tTag = MenuActionTarget {
                                        SidebarProbe.createGitTag(directory: rootPath, tagName: tagVersion)
                                    }
                                    itemTag.target = tTag
                                    menu.addItem(itemTag)

                                    objc_setAssociatedObject(menu, "targets", [tMajor, tMinor, tPatch, tTag], .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

                                    if let event = NSApp.currentEvent, let window = event.window, let contentView = window.contentView {
                                        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(isHoveringMenu ? Color.primary : Color.secondary)
                                        .frame(width: 18, height: 16)
                                        .background(
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(isHoveringMenu ? Color.primary.opacity(0.08) : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { isHoveringMenu = $0 }
                                .help(L10n.t("Version Options"))
                            }
                            .padding(1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )

                        Spacer(minLength: 0)
                    }
                    .frame(height: 20)
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading + 10  )
            .padding(.trailing, )
            .padding(.vertical, 3)
        }
    }
}

/// npm scripts 列表；scriptsRoot 仅用于空状态文案区分。
struct PackageScriptsSection: View {
    let projectID: UUID
    let directory: String
    let scripts: [SidebarProbe.PackageScript]
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runPackageScript: (String, TerminalManager.PackageScriptRunMode) -> Void
    let stopPackageScript: (String) -> Void
    let restartPackageScript: (String, TerminalManager.PackageScriptRunMode) -> Void
    let openPackageJSON: () -> Void

    @State private var selectedScriptName: String? = nil

    var body: some View {
        SidebarSectionHeader(
            title: L10n.t("NPM SCRIPTS"),
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if scripts.isEmpty {
                    sidebarEmptyRow("No package scripts in package.json")
                } else {
                    ForEach(scripts) { script in
                        let executionKey = UniversalProjectScript.executionKey(
                            projectID: projectID,
                            category: .npm,
                            name: script.name,
                            directory: directory
                        )
                        PackageScriptRow(
                            script: script,
                            record: records[executionKey],
                            isSelected: selectedScriptName == script.name,
                            onSelect: {
                                selectedScriptName = script.name
                            },
                            onDoubleClick: {
                                selectedScriptName = script.name
                                runPackageScript(script.name, .normal)
                            },
                            run: { mode in
                                selectedScriptName = script.name
                                runPackageScript(script.name, mode)
                            },
                            stop: {
                                stopPackageScript(executionKey)
                            },
                            restart: { mode in
                                selectedScriptName = script.name
                                restartPackageScript(script.name, mode)
                            },
                            editPackageJSON: openPackageJSON
                        )
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

/// npm script 行：支持运行/停止/重新运行状态追踪，展示上一次运行耗时与明显 Hover 控制。
private struct PackageScriptRow: View {
    let script: SidebarProbe.PackageScript
    let record: TerminalManager.PackageScriptExecutionRecord?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let run: (TerminalManager.PackageScriptRunMode) -> Void
    let stop: () -> Void
    let restart: (TerminalManager.PackageScriptRunMode) -> Void
    let editPackageJSON: () -> Void

    @State private var isHoveringRow = false
    @State private var isHoveringActionBtn = false
    @State private var isHoveringRestartBtn = false
    @State private var isHoveringBrowserBtn = false

    private var status: TerminalManager.PackageScriptStatus {
        record?.status ?? .idle
    }

    private var boundPort: Int? {
        record?.boundPort
    }

    var body: some View {
        HStack(spacing: 6) {
            actionButton

            Text(script.name)
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(isSelected ? .primary : (isHoveringRow ? .primary : .secondary))
                .lineLimit(1)

            Spacer(minLength: 0)

            rightContent
        }
        .frame(height: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isSelected
                    ? Color.primary.opacity(0.09)
                    : (isHoveringRow ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { isHoveringRow = $0 }
        .onTapGesture(count: 2) {
            guard status == .idle else { return }
            onDoubleClick()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .macTooltip(script.command.isEmpty ? nil : script.command, position: .bottom, delay: 0.8)
        .contextMenu {
            if let port = boundPort {
                Button("Open http://localhost:\(port) in Browser") {
                    if let url = URL(string: "http://localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
            }
            if status == .running {
                Button(L10n.t("Stop")) { stop() }
                Button(L10n.t("Restart")) { restart(.normal) }
            } else {
                Button(L10n.t("Run")) { run(.normal) }
            }
            Button(L10n.t("Edit package.json")) { editPackageJSON() }
            Divider()
            Button(L10n.t("Run with time")) { run(.withTime) }
            Button(L10n.t("Run with --inspect")) { run(.withInspect) }
            Button(L10n.t("Run with --prof")) { run(.withProf) }
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
                            .fill(isHoveringActionBtn ? Color(nsColor: Theme.cursor) : (isHoveringRow ? Color.primary.opacity(0.08) : Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringActionBtn = $0 }

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

        case .stopping:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        HStack(spacing: 4) {
            if let port = boundPort {
                Button {
                    if let url = URL(string: "http://localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "globe")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(isHoveringBrowserBtn ? Color.white : Color(nsColor: Theme.cursor))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isHoveringBrowserBtn ? Color(nsColor: Theme.cursor) : Color(nsColor: Theme.cursor).opacity(0.12))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringBrowserBtn = $0 }
                .help("Open http://localhost:\(port) in browser")
            }

            switch status {
            case .idle:
                if let duration = record?.lastDuration {
                    Text(formatScriptDuration(duration))
                        .font(SidebarTypography.micro(.medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 2)
                }

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
                                .fill(isHoveringRestartBtn ? Color(nsColor: Theme.cursor) : (isHoveringRow ? Color.primary.opacity(0.08) : Color.clear))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringRestartBtn = $0 }

            case .stopping:
                Text(L10n.t("Stopping..."))
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/** 通用项目任务分组的展示差异。 */
struct UniversalTasksSectionConfiguration {
    let title: String
    let emptyText: String
    let missingToolText: String?
    let isToolInstalled: Bool

    /** Gradle 任务由项目 wrapper 驱动，不额外检查全局命令。 */
    static var gradle: Self {
        Self(
            title: L10n.t("GRADLE TASKS"),
            emptyText: "No Gradle tasks found",
            missingToolText: nil,
            isToolInstalled: true
        )
    }

    /** Justfile 任务展示配置。 */
    static var just: Self {
        Self(
            title: L10n.t("JUSTFILE"),
            emptyText: "No tasks in Justfile",
            missingToolText: "Install just to run tasks",
            isToolInstalled: JustToolChecker.isJustInstalled
        )
    }

    /** Cargo 任务展示配置。 */
    static var cargo: Self {
        Self(
            title: L10n.t("CARGO"),
            emptyText: "No Cargo tasks",
            missingToolText: "Install Rust/Cargo to run tasks",
            isToolInstalled: CargoToolChecker.isCargoInstalled
        )
    }

    /** CMake 任务展示配置。 */
    static var cmake: Self {
        Self(
            title: L10n.t("CMAKE TASKS"),
            emptyText: "No CMake tasks",
            missingToolText: "Install CMake to run tasks",
            isToolInstalled: CMakeToolChecker.isCMakeInstalled
        )
    }

    /** Makefile 任务展示配置。 */
    static var makefile: Self {
        Self(
            title: L10n.t("MAKEFILE"),
            emptyText: "No Makefile tasks",
            missingToolText: "Install make to run tasks",
            isToolInstalled: MakeToolChecker.isMakeInstalled
        )
    }
}

/** Gradle、Just、Cargo、CMake 与 Makefile 共用的任务分组。 */
struct UniversalTasksSection: View {
    let configuration: UniversalTasksSectionConfiguration
    let projectID: UUID
    let defaultDirectory: String
    let scripts: [UniversalProjectScript]
    let records: [String: TerminalManager.PackageScriptExecutionRecord]
    @Binding var isCollapsed: Bool
    let runScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void
    let stopScript: (UniversalProjectScript) -> Void
    let restartScript: (UniversalProjectScript, UniversalScriptRunMode) -> Void

    @State private var selectedScriptName: String? = nil

    var body: some View {
        SidebarSectionHeader(
            title: configuration.title,
            count: scripts.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if !configuration.isToolInstalled,
                   let missingToolText = configuration.missingToolText {
                    missingToolWarning(missingToolText)
                }

                if scripts.isEmpty {
                    sidebarEmptyRow(configuration.emptyText)
                } else {
                    ForEach(scripts) { script in
                        scriptRow(script)
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }

    /** 统一构建任务行的选择、运行、停止和重启回调。 */
    private func scriptRow(_ script: UniversalProjectScript) -> some View {
        let executionKey = script.executionKey(
            projectID: projectID,
            fallbackDirectory: defaultDirectory
        )
        return UniversalScriptRow(
            script: script,
            record: records[executionKey],
            isSelected: selectedScriptName == script.name,
            onSelect: {
                selectedScriptName = script.name
            },
            onDoubleClick: {
                selectedScriptName = script.name
                runScript(script, .normal)
            },
            run: { mode in
                selectedScriptName = script.name
                runScript(script, mode)
            },
            stop: {
                stopScript(script)
            },
            restart: { mode in
                selectedScriptName = script.name
                restartScript(script, mode)
            }
        )
    }

    /** 缺少对应 CLI 时共用的轻量警告行。 */
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

/// 通用 Project Script 行展示组件 (支持 Gradle, Cargo, uv, Just 等)
private struct UniversalScriptRow: View {
    let script: UniversalProjectScript
    let record: TerminalManager.PackageScriptExecutionRecord?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let run: (UniversalScriptRunMode) -> Void
    let stop: () -> Void
    let restart: (UniversalScriptRunMode) -> Void

    @State private var isHoveringRow = false
    @State private var isHoveringActionBtn = false
    @State private var isHoveringRestartBtn = false
    @State private var isHoveringBrowserBtn = false

    private var status: TerminalManager.PackageScriptStatus {
        record?.status ?? .idle
    }

    private var boundPort: Int? {
        record?.boundPort
    }

    var body: some View {
        HStack(spacing: 6) {
            actionButton

            VStack(alignment: .leading, spacing: 1) {
                Text(script.name)
                    .font(SidebarTypography.secondary(.medium))
                    .foregroundStyle(isSelected ? .primary : (isHoveringRow ? .primary : .secondary))
                    .lineLimit(1)

                if !script.depends.isEmpty {
                    Text(" └─ depends on \(script.depends.joined(separator: ", "))")
                        .font(SidebarTypography.micro(.regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let desc = script.scriptDescription, !desc.isEmpty, desc != script.name && desc != "cargo \(script.name)" {
                    Text(" └─ \(desc)")
                        .font(SidebarTypography.micro(.regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            rightContent
        }
        .frame(height: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isSelected
                    ? Color.primary.opacity(0.09)
                    : (isHoveringRow ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { isHoveringRow = $0 }
        .onTapGesture(count: 2) {
            guard status == .idle else { return }
            onDoubleClick()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .macTooltip(
            script.category == .npm
                ? (script.command.isEmpty ? script.category.buildExecutionCommand(scriptName: script.name, rawCommand: script.command, directory: script.directory) : script.command)
                : script.category.buildExecutionCommand(scriptName: script.name, rawCommand: script.command, directory: script.directory),
            position: .bottom,
            delay: 0.8
        )
        .contextMenu {
            if let port = boundPort {
                Button("Open http://localhost:\(port) in Browser") {
                    if let url = URL(string: "http://localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
            }
            if status == .running {
                Button(L10n.t("Stop")) { stop() }
                Button(L10n.t("Restart")) { restart(.normal) }
            } else {
                Button(L10n.t("Run")) { run(.normal) }
            }
            Divider()
            Button(L10n.t("Run with time")) { run(.withTime) }
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
                            .fill(isHoveringActionBtn ? Color(nsColor: Theme.cursor) : (isHoveringRow ? Color.primary.opacity(0.08) : Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringActionBtn = $0 }

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

        case .stopping:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        HStack(spacing: 4) {
            if let port = boundPort {
                Button {
                    if let url = URL(string: "http://localhost:\(port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "globe")
                        .font(SidebarTypography.micro(.semibold))
                        .foregroundStyle(isHoveringBrowserBtn ? Color.white : Color(nsColor: Theme.cursor))
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isHoveringBrowserBtn ? Color(nsColor: Theme.cursor) : Color(nsColor: Theme.cursor).opacity(0.12))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringBrowserBtn = $0 }
                .help("Open http://localhost:\(port) in browser")
            }

            switch status {
            case .idle:
                if let duration = record?.lastDuration {
                    Text(formatScriptDuration(duration))
                        .font(SidebarTypography.micro(.medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 2)
                }

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
                                .fill(isHoveringRestartBtn ? Color(nsColor: Theme.cursor) : (isHoveringRow ? Color.primary.opacity(0.08) : Color.clear))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringRestartBtn = $0 }

            case .stopping:
                Text(L10n.t("Stopping..."))
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ProcessesSection: View {
    let processes: [SidebarProbe.ProcessItem]
    @Binding var isCollapsed: Bool
    let kill: (_ pid: pid_t, _ force: Bool) -> Void

    var body: some View {
        SidebarSectionHeader(
            title: L10n.t("PROCESSES"),
            count: processes.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if processes.isEmpty {
                    sidebarEmptyRow("No running processes")
                } else {
                    ForEach(processes) { process in
                        InfoProcessRow(process: process) { force in
                            kill(process.pid, force)
                        }
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}

struct PortsSection: View {
    let ports: [SidebarProbe.PortItem]
    @Binding var isCollapsed: Bool
    let kill: (_ pid: pid_t, _ force: Bool) -> Void

    var body: some View {
        SidebarSectionHeader(
            title: L10n.t("PORTS"),
            count: ports.count,
            isCollapsed: $isCollapsed,
            actions: []
        )
        if !isCollapsed {
            Group {
                if ports.isEmpty {
                    sidebarEmptyRow("No listening ports")
                } else {
                    ForEach(ports) { port in
                        InfoPortRow(port: port) { force in
                            kill(port.pid, force)
                        }
                    }
                }
            }
            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
        }
    }
}
