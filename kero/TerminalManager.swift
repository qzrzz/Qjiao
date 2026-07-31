//
//  TerminalManager.swift
//  kero
//

import AppKit
import Combine
import Foundation
import GhosttyTerminal
import SwiftUI
import WebKit

/// Files 面板的模式（文件树 / 全局搜寻）
enum FilePanelMode: String, Codable {
    case tree
    case search
}

/// 右侧栏上半区面板。rawValue 会写入会话快照，新增 case 勿改已有值。
enum RightPanel: String, Codable {
    case start
    /// 项目根路径与 package.json scripts（与当前终端 cwd 无关）。
    case project
    /// 当前终端会话：cwd、shell pid、子进程与监听端口。
    case info
    case files
    case cwd
    case git
}

/// One Find menu command, routed from the menu bar to whichever find
/// implementation the focused pane owns: Ghostty's own search in a terminal,
/// `NSTextFinder`'s find bar in a file editor.
enum FindAction {
    case show
    case replace
    case hide
    case next
    case previous
    case useSelection
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension Notification.Name {
    static let qjiaoProjectListDidChange = Notification.Name("qjiaoProjectListDidChange")
}

/// Owns the list of projects and the current selection. Each project holds
/// its own terminal sessions; the "selected session" is the selected
/// project's selected session.
@MainActor
final class TerminalManager: nonisolated ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedProjectID: UUID? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            reloadActiveProjectTheme()
        }
    }
    @Published var isPanelVisible = false
    @Published var panelTab: RightPanel = .files
    @Published var filePanelMode: FilePanelMode = .tree
    /// Visibility of the left project sidebar (⌘B). `isPanelVisible` above is
    /// the separate right panel.
    @Published var isLeftSidebarVisible = true
    @Published private(set) var isCommandPaletteVisible = false

    /// Projects publish their own changes (session list, session selection);
    /// re-publish them so views observing the manager stay current.
    private var projectObservations: [UUID: AnyCancellable] = [:]
    private var projectThemeObservations: [UUID: AnyCancellable] = [:]
    private var projectCounter = 0
    private var settingsObservation: AnyCancellable?
    private var zshIdleTitleObservation: AnyCancellable?
    private var autosaveObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    private var projectListChangeObservation: AnyCancellable?
    private static var isSynchronizingProjectList = false
    /// The stable terminal/editor responder displaced by the command palette's
    /// search field. AppKit field editors are deliberately excluded because a
    /// SwiftUI TextField can reuse the same responder for the palette itself.
    private weak var commandPalettePreviousResponder: NSResponder?
    private weak var commandPaletteWindow: NSWindow?
    /// Window hosting this manager, once SwiftUI has attached its content.
    /// Finder service requests use it to target the active Qjiao window.
    private weak var window: NSWindow?
    /// The untouched project created before the first window appears. A Finder
    /// request arriving during launch replaces it instead of leaving an extra
    /// home-directory project beside the requested folder.
    private var startupProjectID: UUID?

    /// Live managers in window-creation order; the persisted snapshot is
    /// one entry per registered manager.
    private(set) static var registry: [TerminalManager] = []
    /// Folder requests can arrive while macOS is still launching Qjiao, before
    /// a WindowGroup has produced a manager/window to receive them.
    private static var pendingDirectories: [String] = []
    /// Captured from SwiftUI's openWindow environment so a Finder request can
    /// reopen Qjiao after the user has closed its last window.
    private static var windowOpener: (() -> Void)?
    /// Window snapshots loaded from disk that no window has claimed yet.
    /// Each new manager claims the next; extras beyond the saved count
    /// start fresh.
    private static var pendingRestores: [SessionSnapshot] = []
    /// Terminal scrollback loaded from the sidecar store, keyed by the
    /// `historyKey` each restoring session pane carries. Shared across windows
    /// (keys are unique per pane), so restores read from it without consuming.
    private static var pendingHistories: [String: String] = [:]
    private static var hasLoadedStore = false
    /// Set on app termination so window teardown can't re-save a partial
    /// snapshot over the final full one.
    private static var isQuitting = false
    private static var didReopenWindows = false

    init() {
        if !Self.hasLoadedStore {
            Self.hasLoadedStore = true
            Self.pendingRestores = SessionStore.load()
            Self.pendingHistories = TerminalHistoryStore.load()

            // 统计恢复时加载的项目总数与终端 Session 总数
            let sessionCount = Self.pendingRestores.reduce(0) { winSum, win in
                winSum + win.projects.reduce(0) { projSum, proj in
                    projSum + proj.tabs.reduce(0) { tabSum, tab in
                        tabSum + tab.columns.reduce(0) { colSum, col in
                            colSum + col.panes.filter { if case .session = $0.content { return true }; return false }.count
                        }
                    }
                }
            }
            let projectCount = Self.pendingRestores.flatMap(\.projects).count
            NSLog("🚀 [Qjiao Startup] 恢复窗口数: %d, 恢复项目数: %d, 恢复终端 Session 总数: %d", Self.pendingRestores.count, projectCount, sessionCount)
        }
        let previousManagers = Self.registry
        Self.registry.append(self)
        var restored = false
        if !Self.pendingRestores.isEmpty {
            restored = restore(from: Self.pendingRestores.removeFirst())
        } else {
            // 当会话快照为空时，以 config/projects 目录为来源扫描并恢复已有项目
            restored = restore(from: SessionSnapshot(projects: [], selectedProjectIndex: 0))
        }
        // Only a window still claiming a snapshot reads the scrollback blobs,
        // so once the last one is claimed they are dead weight — several
        // hundred lines per restored session, held for the life of the process.
        if Self.pendingRestores.isEmpty, !Self.pendingHistories.isEmpty {
            Self.pendingHistories = [:]
        }
        let queuedDirectories = Self.takePendingDirectories()
        if !restored, queuedDirectories.isEmpty {
            // 若为新开窗口，且此前已有其他活跃窗口，则继承已有窗口的项目列表
            if let existing = previousManagers.first(where: { !$0.projects.isEmpty }) {
                synchronizeProjectList(with: existing.projects.map(\.id))
            } else {
                startupProjectID = newProject().id
            }
        } else if !restored {
            if let existing = previousManagers.first(where: { !$0.projects.isEmpty }) {
                synchronizeProjectList(with: existing.projects.map(\.id))
            }
        }
        for directory in queuedDirectories {
            newProject(directory: directory)
        }
        projectListChangeObservation = NotificationCenter.default
            .publisher(for: .qjiaoProjectListDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if (notification.object as AnyObject) === self { return }
                guard let newIDs = notification.userInfo?["projectIDs"] as? [UUID] else { return }
                self.synchronizeProjectList(with: newIDs)
            }
        // Re-theme live sessions when font, appearance, or terminal theme settings change.
        // Delivery is scheduled onto the main queue because @Published emits in
        // willSet — by then `didSet` has pushed the theme onto NSApp, so
        // `refreshAppearance` reads the new effective appearance.
        settingsObservation = Publishers.CombineLatest3(
            Publishers.CombineLatest(
                Publishers.CombineLatest4(
                    AppSettings.shared.$fontFamily.removeDuplicates(),
                    AppSettings.shared.$fontSize.removeDuplicates(),
                    AppSettings.shared.$useBundledChineseTerminalFont.removeDuplicates(),
                    AppSettings.shared.$fontThicken.removeDuplicates()
                ),
                Publishers.CombineLatest(
                    AppSettings.shared.$terminalBackgroundOpacity.removeDuplicates(),
                    AppSettings.shared.$macosOptionAsAlt.removeDuplicates()
                )
            ),
            AppSettings.shared.$directClickMovesCursor.removeDuplicates(),
            Publishers.CombineLatest3(
                AppSettings.shared.$theme.removeDuplicates(),
                AppSettings.shared.$themeLight.removeDuplicates(),
                AppSettings.shared.$themeDark.removeDuplicates()
            )
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAppearance()
            }
        zshIdleTitleObservation = AppSettings.shared.$zshIdleTitleStyle
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStyle in
                self?.applyZshIdleTitleStyleChange(newStyle)
            }
        // Every project/tab/selection change re-publishes through the manager,
        // so a debounced sink snapshots layout after mutations settle without
        // reading live terminal contents.
        autosaveObservation = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { _ in
                TerminalManager.saveAll(captureTerminalHistory: false)
            }
        // The debounce can swallow changes made just before quitting;
        // capture a final snapshot while the shells are still alive.
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in
                guard !TerminalManager.isQuitting else { return }
                TerminalManager.isQuitting = true
                TerminalManager.saveAll(captureTerminalHistory: true)
            }
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: TerminalSession? {
        selectedProject?.selectedSession
    }

    /// 当 AppSettings 的 zshIdleTitleStyle 发生变化时，即时刷新全部打开终端 Session 的 UI 标签标题。
    func applyZshIdleTitleStyleChange(_ style: ZshIdleTitleStyle) {
        for project in projects {
            for tab in project.tabs {
                for session in tab.sessions {
                    session.updateIdleTitleStyle(style)
                }
            }
        }
        objectWillChange.send()
    }

    // MARK: - Projects

    @discardableResult
    func newProject() -> Project {
        let project = makeProject()
        project.saveConfig()
        insert(project)
        return project
    }

    /// Creates a project rooted at `directory`, with its first terminal
    /// launched there. Used by Qjiao's Finder service.
    private func newProject(directory: String) {
        let project = makeProject(createInitialSession: false)
        project.customName = URL(
            fileURLWithPath: directory,
            isDirectory: true
        ).lastPathComponent
        project.projectDirectory = directory
        project.newSession(directory: directory)
        project.saveConfig()
        insert(project)
    }

    /// Routes folders from the Finder service into the active Qjiao window.
    /// If no window exists yet, the next WindowGroup manager claims them.
    static func openDirectories(_ directories: [String]) {
        guard !directories.isEmpty else { return }
        let manager = registry.first { $0.window === NSApp.keyWindow }
            ?? registry.first { $0.window === NSApp.mainWindow }
            ?? registry.last { $0.window != nil }
        guard let manager else {
            pendingDirectories.append(contentsOf: directories)
            if registry.isEmpty {
                windowOpener?()
            }
            return
        }

        for directory in directories {
            manager.newProject(directory: directory)
        }
        manager.window?.makeKeyAndOrderFront(nil)
    }

    /// Called as soon as SwiftUI gives this manager an AppKit window. A
    /// launch-time Finder request may have been queued before that happened.
    func attach(to window: NSWindow) {
        self.window = window
        let directories = Self.takePendingDirectories()
        if !directories.isEmpty, let startupProjectID,
           let startupProject = projects.first(where: { $0.id == startupProjectID }) {
            startupProject.terminateAll()
            remove(startupProject)
        }
        startupProjectID = nil
        for directory in directories {
            newProject(directory: directory)
        }
        if !directories.isEmpty {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func takePendingDirectories() -> [String] {
        let directories = pendingDirectories
        pendingDirectories = []
        return directories
    }

    /// 打开文件夹为项目：若已有同目录项目则激活（归档中则先解除），否则新建并启动终端。
    @discardableResult
    func addProject(at directoryURL: URL) -> Bool {
        let directoryURL = directoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path, isDirectory: &isDirectory
        ), isDirectory.boolValue
        else { return false }

        let path = directoryURL.path
        if let existing = projects.first(where: { Self.projectDirectoryMatches($0, path: path) }) {
            if existing.isArchived {
                unarchiveProject(existing)
            } else {
                selectedProjectID = existing.id
            }
            return true
        }

        let project = makeProject(createInitialSession: false)
        project.customName = directoryURL.lastPathComponent
        project.projectDirectory = path
        project.newSession(directory: path)
        project.saveConfig()
        insert(project)
        return true
    }

    /// 规范化后比较项目目录是否与给定路径相同。
    private static func projectDirectoryMatches(_ project: Project, path: String) -> Bool {
        guard !project.projectDirectory.isEmpty else { return false }
        let projectPath = URL(fileURLWithPath: project.projectDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return projectPath == path
    }

    /// 将项目插入当前项目之后，并把它设为当前项目。
    private func insert(_ project: Project) {
        // Open the new project next to the current one rather than at the end.
        // Falls back to appending when nothing is selected yet.
        if let selectedProjectID,
           let index = projects.firstIndex(where: { $0.id == selectedProjectID }) {
            projects.insert(project, at: index + 1)
        } else {
            projects.append(project)
        }
        selectedProjectID = project.id
        broadcastProjectListChange()
    }

    private func broadcastProjectListChange() {
        guard !Self.isSynchronizingProjectList else { return }
        let projectIDs = projects.map(\.id)
        NotificationCenter.default.post(
            name: .qjiaoProjectListDidChange,
            object: self,
            userInfo: ["projectIDs": projectIDs]
        )
    }

    /// 跨窗口同步项目列表（包含添加未有项目、清理已被删除项目、重新排序）
    private func synchronizeProjectList(with newIDs: [UUID]) {
        Self.isSynchronizingProjectList = true
        defer { Self.isSynchronizingProjectList = false }

        let newIDSet = Set(newIDs)

        // 1. 移除已不在全局列表中的项目
        let projectsToRemove = projects.filter { !newIDSet.contains($0.id) }
        for project in projectsToRemove {
            removeLocally(project)
        }

        // 2. 补全新增的项目
        for id in newIDs {
            if !projects.contains(where: { $0.id == id }) {
                let project = makeProject(id: id, createInitialSession: false)
                if let config = ProjectConfigStore.load(for: id) {
                    project.customName = config.customName
                    project.useAutoTitle = config.useAutoTitle ?? false
                    project.description = config.description
                    project.icon = config.icon
                    project.theme = config.theme ?? .global
                    project.projectDirectory = config.projectDirectory ?? ""
                    project.isArchived = config.isArchived ?? false
                    project.launchCommands = config.launchCommands ?? []
                    if let aiLangStr = config.aiWritingLanguage {
                        project.aiWritingLanguage = AIWritingLanguage(rawValue: aiLangStr)
                    }
                }
                projects.append(project)
            }
        }

        // 3. 按 newIDs 重新排序当前窗口的 projects 数组
        let projectMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        projects = newIDs.compactMap { projectMap[$0] }

        // 4. 校正选中的项目
        if let selectedID = selectedProjectID, !projects.contains(where: { $0.id == selectedID }) {
            selectedProjectID = activeProjects.first?.id ?? projects.first?.id
        }
    }

    /// 仅在当前窗口本地移除项目（响应其他窗口的项目删除广播）
    private func removeLocally(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        projectObservations[project.id] = nil
        projectThemeObservations[project.id] = nil
        if selectedProjectID == project.id {
            let neighbor = min(index, projects.count - 1)
            selectedProjectID = neighbor >= 0 ? projects[neighbor].id : nil
        }
        if projects.isEmpty {
            isPanelVisible = false
        }
    }

    private func makeProject(id: UUID? = nil, createInitialSession: Bool = true) -> Project {
        projectCounter += 1
        let project = Project(
            id: id ?? UUID(),
            fallbackName: "Project \(projectCounter)",
            createInitialSession: createInitialSession
        )
        // 文件夹创建项目仅接受左侧边栏 drop；终端 drop 改为插入路径，不再走此回调。
        project.onOpenProjectDirectory = nil
        projectObservations[project.id] = project.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        projectThemeObservations[project.id] = project.$theme.sink { [weak self] _ in
            guard let self, self.selectedProjectID == project.id else { return }
            self.reloadActiveProjectTheme()
        }
        return project
    }

    func close(_ project: Project) {
        project.terminateAll()
        let projectID = project.id
        remove(project)
        // 延后删除配置目录：先让 Note 面板在切换选中项时 flush，
        // 避免防抖写回在删目录之后又重建空文件夹。
        DispatchQueue.main.async {
            ProjectConfigStore.removeAllData(for: projectID)
        }
    }

    private func remove(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        projectObservations[project.id] = nil
        projectThemeObservations[project.id] = nil
        if selectedProjectID == project.id {
            let neighbor = min(index, projects.count - 1)
            selectedProjectID = neighbor >= 0 ? projects[neighbor].id : nil
        }
        // Nothing left to inspect once the last project is gone, so collapse
        // the right sidebar — its panels all track the selected session.
        if projects.isEmpty {
            isPanelVisible = false
        }
        broadcastProjectListChange()
    }

    /// Moves a dragged project across `targetID`: after it when moving down,
    /// or before it when moving up. Selection continues to follow its project ID.
    func moveProject(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = projects.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = projects.firstIndex(where: { $0.id == targetID })
        else { return }

        var reorderedProjects = projects
        let draggedProject = reorderedProjects.remove(at: draggedIndex)
        reorderedProjects.insert(draggedProject, at: targetIndex)
        projects = reorderedProjects
        broadcastProjectListChange()
    }

    /// 当前所有未归档的正常项目列表。
    var activeProjects: [Project] {
        projects.filter { !$0.isArchived }
    }

    /// 当前所有已归档的项目列表。
    var archivedProjects: [Project] {
        projects.filter { $0.isArchived }
    }

    /// 将指定项目归档。
    /// - Parameter project: 需要归档的项目
    func archiveProject(_ project: Project) {
        guard !project.isArchived else { return }
        project.isArchived = true
        // 若归档的项目正好是当前选中项目，则切到下一个未归档项目
        if selectedProjectID == project.id {
            if let next = activeProjects.first {
                selectedProjectID = next.id
            }
        }
        objectWillChange.send()
        broadcastProjectListChange()
    }

    /// 将指定项目解除归档，并将其设为当前选中项目。
    /// - Parameter project: 需要解除归档的项目
    func unarchiveProject(_ project: Project) {
        guard project.isArchived else { return }
        project.isArchived = false
        selectedProjectID = project.id
        objectWillChange.send()
        broadcastProjectListChange()
    }

    /// 将所有未归档的项目归档。
    func archiveAllProjects() {
        let toArchive = activeProjects
        guard !toArchive.isEmpty else { return }
        for project in toArchive {
            project.isArchived = true
            project.saveConfig()
        }
        if let next = activeProjects.first {
            selectedProjectID = next.id
        }
        objectWillChange.send()
        broadcastProjectListChange()
    }


    /// 按索引选中未归档项目（对应快捷键 ⌘1 ~ ⌘9）。
    /// - Parameter index: 未归档项目列表中的索引
    func selectProject(index: Int) {
        let active = activeProjects
        guard active.indices.contains(index) else { return }
        selectedProjectID = active[index].id
    }

    /// 循环切换上一个/下一个未归档项目。
    func selectNextProject() {
        shiftProjectSelection(by: 1)
    }

    /// 循环切换上一个/下一个未归档项目。
    func selectPreviousProject() {
        shiftProjectSelection(by: -1)
    }

    private func shiftProjectSelection(by offset: Int) {
        let active = activeProjects
        guard !active.isEmpty,
              let current = active.firstIndex(where: { $0.id == selectedProjectID })
        else { return }
        let next = (current + offset + active.count) % active.count
        selectedProjectID = active[next].id
    }

    // MARK: - Sessions

    /// 在当前项目中新建终端会话（若项目不存在则创建新项目）；可指定初始工作目录。
    /// - Parameter directory: 终端会话初始工作目录路径，传 nil 时默认使用项目目录或当前会话目录。
    func newSession(directory: String? = nil) {
        guard let project = selectedProject else {
            newProject()
            selectedProject?.newSession(directory: directory)
            return
        }
        project.newSession(directory: directory)
    }

    /// 在当前项目中新建浏览器 Tab；无项目时先建立正常项目上下文。
    func newBrowserTab(initialURL: String? = nil) {
        let project = selectedProject ?? newProject()
        project.newBrowserTab(
            initialURL: initialURL,
            initialFocus: initialURL == nil ? .addressBar : .webContent
        )
    }

    /// 在聚焦 Pane 旁创建浏览器 Pane。
    func newBrowserPane(
        toward edge: PaneDropEdge = .right,
        initialURL: String? = nil
    ) {
        selectedProject?.newBrowserPane(
            toward: edge,
            initialURL: initialURL,
            initialFocus: initialURL == nil ? .addressBar : .webContent
        )
    }

    typealias PackageScriptStatus = UniversalScriptStatus
    typealias PackageScriptExecutionRecord = UniversalScriptExecutionRecord
    typealias PackageScriptRunMode = UniversalScriptRunMode

    /// 记录各项目脚本的执行句柄与耗时信息（KEY: scriptName 或 script.id）
    @Published var packageScriptRecords: [String: UniversalScriptExecutionRecord] = [:]
    /// 从右侧栏发起的终端命令。Tab 仅为这些 Session 显示通用转圈，
    /// 手动在终端输入的未知命令仍保留普通终端图标。
    @Published private var rightSidebarCommandStartedAt: [UUID: Date] = [:]

    private var scriptCheckTimer: Timer?

    private func startScriptCheckTimerIfNeeded() {
        guard scriptCheckTimer == nil else { return }
        scriptCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPackageScriptStatus()
            }
        }
    }

    private func stopScriptCheckTimerIfEmpty() {
        let hasRunning = packageScriptRecords.values.contains { $0.status == .running || $0.status == .stopping }
        if !hasRunning && rightSidebarCommandStartedAt.isEmpty {
            scriptCheckTimer?.invalidate()
            scriptCheckTimer = nil
        }
    }

    /// 当前 Session 是否正在执行由右侧栏发起的命令。
    func isRightSidebarCommandRunning(sessionID: UUID) -> Bool {
        rightSidebarCommandStartedAt[sessionID] != nil
    }

    /// 检查并更新所有脚本的运行/空闲状态（如果 shell 前台命令已执行完，标记为完成/停止并统计耗时）
    func checkPackageScriptStatus() {
        let now = Date()
        for (executionKey, record) in packageScriptRecords where record.status == .running {
            guard let project = project(containingSessionID: record.sessionID),
                  let session = project.sessions.first(where: { $0.id == record.sessionID })
            else {
                markScriptAsIdle(executionKey, endedAt: now)
                continue
            }

            if let tab = project.tabs.first(where: { $0.sessions.contains(where: { $0.id == session.id }) }) {
                tab.taskHasError = session.taskHasError
            }

            if session.hasExited {
                markScriptAsIdle(executionKey, endedAt: now)
            } else if now.timeIntervalSince(record.startedAt) > 0.5 && !session.isForegroundCommandRunning {
                // 运行超过 0.5 秒且前台命令已被 shell 释放（命令运行结束），判定为完成/停止
                markScriptAsIdle(executionKey, endedAt: now)
            }
        }
        for (sessionID, startedAt) in Array(rightSidebarCommandStartedAt) {
            guard let project = project(containingSessionID: sessionID),
                  let session = project.sessions.first(where: { $0.id == sessionID })
            else {
                rightSidebarCommandStartedAt.removeValue(forKey: sessionID)
                continue
            }

            if let tab = project.tabs.first(where: { $0.sessions.contains(where: { $0.id == session.id }) }) {
                tab.taskHasError = session.taskHasError
            }

            if session.hasExited {
                rightSidebarCommandStartedAt.removeValue(forKey: sessionID)
            } else if now.timeIntervalSince(startedAt) > 0.5,
                      session.isInitialized,
                      !session.isForegroundCommandRunning
            {
                rightSidebarCommandStartedAt.removeValue(forKey: sessionID)
            }
        }
        stopScriptCheckTimerIfEmpty()
    }

    /// 用指定 Shell 集合的最新监听端口更新脚本绑定；端口消失时同步清空旧值。
    func updatePackageScriptPorts(
        with ports: [SidebarProbe.PortItem],
        shellPids: [pid_t]
    ) {
        guard !packageScriptRecords.isEmpty else { return }
        let refreshedShellPids = Set(shellPids.filter { $0 > 0 })
        for (executionKey, record) in packageScriptRecords where record.status == .running {
            guard let project = project(containingSessionID: record.sessionID),
                  let session = project.sessions.first(where: { $0.id == record.sessionID }),
                  let shellPid = session.shellPid,
                  refreshedShellPids.contains(shellPid)
            else { continue }

            // 检查监听端口 PID 是否属于此 session shellPid
            let foregroundPid = session.isInitialized ? session.terminalView.foregroundPid : nil
            let matchedPort = ports.first(where: {
                $0.rootShellPid == shellPid
                    || $0.pid == shellPid
                    || $0.pid == foregroundPid
            })?.port
            if packageScriptRecords[executionKey]?.boundPort != matchedPort {
                packageScriptRecords[executionKey]?.boundPort = matchedPort
            }
        }
    }

    private func markScriptAsIdle(_ scriptKey: String, endedAt: Date) {
        guard let record = packageScriptRecords[scriptKey], record.status == .running || record.status == .stopping else { return }
        let elapsed = max(0.1, endedAt.timeIntervalSince(record.startedAt))
        var updated = record
        updated.status = .idle
        updated.lastDuration = elapsed
        updated.boundPort = nil
        packageScriptRecords[scriptKey] = updated
        rightSidebarCommandStartedAt.removeValue(forKey: record.sessionID)
    }

    /// 注册右侧栏命令对应的 Session，记录 Task 运行标志，并在终端退出时及时清理状态。
    private func trackRightSidebarCommand(in session: TerminalSession) {
        session.isTaskRunning = true
        session.taskHasError = false
        if let proj = project(containingSessionID: session.id) {
            if let tab = proj.tabs.first(where: { $0.sessions.contains(where: { $0.id == session.id }) }) {
                tab.isTaskRunning = true
                tab.taskHasError = false
            } else {
                proj.selectedTab?.isTaskRunning = true
                proj.selectedTab?.taskHasError = false
            }
        }
        rightSidebarCommandStartedAt[session.id] = Date()
        startScriptCheckTimerIfNeeded()

        let originalOnExited = session.onExited
        session.onExited = { [weak self] exitedSession in
            originalOnExited?(exitedSession)
            Task { @MainActor in
                self?.rightSidebarCommandStartedAt.removeValue(forKey: exitedSession.id)
                self?.stopScriptCheckTimerIfEmpty()
            }
        }
    }

    /// 关闭该任务之前启动过的所有终端窗口/Session（无论当前是在运行中还是已运行结束）
    func closeExistingPackageScriptTerminal(executionKey: String) {
        guard let record = packageScriptRecords[executionKey] else { return }
        if let project = project(containingSessionID: record.sessionID),
           let session = project.sessions.first(where: { $0.id == record.sessionID }) {
            project.closeContent(.session(session), terminate: true)
        }
        if record.status == .running || record.status == .stopping {
            markScriptAsIdle(executionKey, endedAt: Date())
        }
    }

    /// 通用项目脚本运行接口（支持 NPM, Gradle, uv, PDM, Rust alias, Makefile 等）
    func runProjectScript(
        _ script: UniversalProjectScript,
        mode: UniversalScriptRunMode = .normal
    ) {
        guard let project = selectedProject, !script.name.isEmpty else { return }
        let resolvedDirectory = !script.directory.isEmpty ? script.directory : (project.projectDirectory.isEmpty ? (selectedSession?.currentDirectoryPath ?? "") : project.projectDirectory)
        guard !resolvedDirectory.isEmpty else { return }

        let trackedScript = UniversalProjectScript(
            name: script.name,
            command: script.command,
            category: script.category,
            directory: resolvedDirectory,
            depends: script.depends,
            scriptDescription: script.scriptDescription
        )
        let scriptKey = trackedScript.executionKey(projectID: project.id)
        // 如果该任务之前启动过终端窗口（无论运行中还是已运行结束），再次运行时都关闭原来的窗口
        closeExistingPackageScriptTerminal(executionKey: scriptKey)

        let session = project.newSession(directory: resolvedDirectory)
        let tabTitle = script.category.buildTabTitle(scriptName: script.name, directory: script.directory)
        project.selectedTab?.customName = tabTitle
        session.title = tabTitle

        let oldLastDuration = packageScriptRecords[scriptKey]?.lastDuration
        let record = UniversalScriptExecutionRecord(
            script: trackedScript,
            sessionID: session.id,
            startedAt: Date(),
            status: .running,
            lastDuration: oldLastDuration
        )
        packageScriptRecords[scriptKey] = record
        trackRightSidebarCommand(in: session)

        // 监听该终端 Session 的退出/销毁
        let originalOnExited = session.onExited
        session.onExited = { [weak self] s in
            originalOnExited?(s)
            Task { @MainActor in
                self?.markScriptAsIdle(scriptKey, endedAt: Date())
            }
        }

        let baseCmd = script.category.buildExecutionCommand(scriptName: script.name, rawCommand: script.command, directory: script.directory)
        let command: String
        switch mode {
        case .normal:
            command = baseCmd
        case .withTime:
            let timePrefix = FileManager.default.isExecutableFile(atPath: "/usr/bin/time") ? "/usr/bin/time" : "time"
            command = "\(timePrefix) \(baseCmd)"
        case .withInspect:
            command = "NODE_OPTIONS=\"--inspect\" \(baseCmd)"
        case .withProf:
            command = "NODE_OPTIONS=\"--prof\" \(baseCmd)"
        case .custom(let prefix):
            command = "\(prefix) \(baseCmd)"
        }
        session.sendCommandWhenReady(command + "\n")
    }

    /// 运行指定的 npm script
    func runPackageScript(
        _ scriptName: String,
        mode: PackageScriptRunMode = .normal,
        directory: String? = nil
    ) {
        let dir = directory ?? selectedProject?.projectDirectory ?? selectedSession?.currentDirectoryPath ?? ""
        let script = UniversalProjectScript(name: scriptName, command: "", category: .npm, directory: dir)
        runProjectScript(script, mode: mode)
    }

    /// 在指定项目/目录下新开终端 Session 并执行任意 shell 命令
    /// - Parameters:
    ///   - command: 准备执行的 shell 命令字符串（如 "bun install"）
    ///   - title: 终端 Tab 显示的名字
    ///   - directory: 可选工作目录；若未传则优先使用 selectedProject 根路径
    func runRawCommand(_ command: String, title: String, directory: String? = nil) {
        guard let project = selectedProject else { return }
        let dir = directory ?? (!project.projectDirectory.isEmpty ? project.projectDirectory : (selectedSession?.currentDirectoryPath ?? ""))
        guard !dir.isEmpty else { return }

        let session = project.newSession(directory: dir)
        project.selectedTab?.customName = title
        session.title = title
        trackRightSidebarCommand(in: session)
        session.sendCommandWhenReady(command + "\n")
    }

    /// 按唯一执行键停止脚本，避免同名任务跨项目互相影响。
    func stopPackageScript(_ executionKey: String) {
        guard let record = packageScriptRecords[executionKey], record.status == .running else {
            return
        }
        packageScriptRecords[executionKey]?.status = .stopping

        guard let project = project(containingSessionID: record.sessionID) else { return }
        if let session = project.sessions.first(where: { $0.id == record.sessionID }) {
            project.closeContent(.session(session), terminate: true)
        }

        markScriptAsIdle(executionKey, endedAt: Date())
    }

    /// 停止当前项目中的通用任务。
    func stopProjectScript(
        _ script: UniversalProjectScript,
        fallbackDirectory: String = ""
    ) {
        guard let project = selectedProject else { return }
        stopPackageScript(
            script.executionKey(
                projectID: project.id,
                fallbackDirectory: fallbackDirectory
            )
        )
    }

    /// 重新运行指定的 package script（先停止，再启动）
    func restartPackageScript(
        _ scriptName: String,
        mode: PackageScriptRunMode = .normal,
        directory: String? = nil
    ) {
        guard let project = selectedProject else { return }
        let resolvedDirectory = directory
            ?? (!project.projectDirectory.isEmpty
                ? project.projectDirectory
                : (selectedSession?.currentDirectoryPath ?? ""))
        let executionKey = UniversalProjectScript.executionKey(
            projectID: project.id,
            category: .npm,
            name: scriptName,
            directory: resolvedDirectory
        )
        stopPackageScript(executionKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.runPackageScript(
                scriptName,
                mode: mode,
                directory: resolvedDirectory
            )
        }
    }

    /// 查找脚本 Session 所属项目；脚本运行状态不能依赖当前选中的项目。
    private func project(containingSessionID sessionID: UUID) -> Project? {
        projects.first { project in
            project.sessions.contains { $0.id == sessionID }
        }
    }

    /// Runs one saved project launcher from the Start sidebar panel.
    func runLaunchCommand(_ command: ProjectLaunchCommand) {
        guard let project = selectedProject else { return }
        switch command.type {
        case .terminal:
            runTerminalLaunch(command, in: project)

        case .application:
            let path = command.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            let argument = command.content.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.arguments = argument.isEmpty ? [] : [argument]
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: configuration
            ) { _, error in
                if let error { NSLog("qjiao: failed to open application: \(error)") }
            }

        case .finderFolder:
            let folderURL = ProjectLaunchCommand.resolveFolderURL(command.content, projectDirectory: project.projectDirectory)
            NSWorkspace.shared.open(folderURL)

        case .web:
            let rawURL = command.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: rawURL.contains("://") ? rawURL : "https://\(rawURL)")
            if let url { NSWorkspace.shared.open(url) }
        }
    }

    /// Starts the project's configured launchers in list order. The first
    /// terminal always establishes a new tab; later terminal commands with a
    /// Split direction join that tab as panes.
    func runAllLaunchCommands() {
        guard let project = selectedProject else { return }
        var hasStartedTerminal = false
        for command in project.launchCommands {
            guard command.type == .terminal else {
                runLaunchCommand(command)
                continue
            }
            runTerminalLaunch(command, in: project, forceNewTab: !hasStartedTerminal)
            hasStartedTerminal = true
        }
    }

    private func runTerminalLaunch(
        _ command: ProjectLaunchCommand,
        in project: Project,
        forceNewTab: Bool = false
    ) {
        let text = command.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let directory = project.projectDirectory.isEmpty
            ? selectedSession?.currentDirectoryPath
            : project.projectDirectory
        let previousTabID = project.selectedTabID
        let session: TerminalSession
        if !forceNewTab, let edge = command.split.edge,
           let splitSession = project.newSplitSession(directory: directory, toward: edge) {
            session = splitSession
        } else {
            session = project.newSession(directory: directory)
        }
        // Start titles and manual tab renames share PaneTab.customName. A
        // split command keeps the existing tab name by design.
        if project.selectedTabID != previousTabID {
            let title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
            project.selectedTab?.customName = title.isEmpty ? nil : title
        }
        trackRightSidebarCommand(in: session)
        session.sendCommandWhenReady(text + "\n")
    }

    /// Brings `session` to the foreground: selects its project and tab, then
    /// focuses its pane. Backs the command palette's session switcher; a no-op
    /// if the session is no longer open anywhere.
    func revealSession(_ session: TerminalSession) {
        for project in projects {
            for tab in project.tabs {
                guard let paneID = tab.paneID(forContent: session.id) else { continue }
                selectedProjectID = project.id
                project.selectedTabID = tab.id
                tab.focusedPaneID = paneID
                return
            }
        }
    }

    /// Clears the terminal in the focused pane. No-op while a file or diff pane
    /// is focused, so ⌘K never wipes an off-screen terminal.
    func clearActiveTerminal() {
        if case .session(let session)? = selectedProject?.focusedContent {
            session.clear()
        }
    }

    /// Whether ⌘K has a terminal on screen to act on right now.
    var canClearActiveTerminal: Bool {
        if case .session? = selectedProject?.focusedContent { return true }
        return false
    }

    /// Routes a Find menu command to the focused pane. Driven off the focused
    /// pane rather than the first responder, so ⌘F and ⌘G keep working while
    /// the find bar's own field holds keyboard focus.
    func performFindAction(_ action: FindAction) {
        switch selectedProject?.focusedContent {
        case .session(let session): session.find.perform(action)
        case .file(let file): file.performFindAction(action)
        case .browser, .diff, .none: break
        }
    }

    /// Whether the Find menu has something searchable on screen right now.
    /// Diffs render their own views rather than a searchable text view.
    var canFind: Bool {
        switch selectedProject?.focusedContent {
        case .session, .file: return true
        case .browser, .diff, .none: return false
        }
    }

    /// Whether Find and Replace has an editable pane to act on: terminal
    /// output and diffs are read-only, so replace is only offered for a file.
    var canReplace: Bool {
        if case .file? = selectedProject?.focusedContent { return true }
        return false
    }

    /// Closes the focused pane (⌘W). When it's the last pane in its tab the
    /// tab closes too — matching the old single-content-tab behavior. Once the
    /// project has no tabs left, ⌘W closes the project itself.
    func closeSelectedTab() {
        guard let project = selectedProject else { return }
        if project.tabs.isEmpty {
            close(project)
        } else {
            project.closeFocusedPane()
        }
    }

    /// Closes the pane that initiated a terminal context-menu action.
    func closePane(_ content: PaneContent) {
        selectedProject?.closeContent(content)
    }

    // MARK: - Panes

    func splitRight() { selectedProject?.splitRight() }
    func splitLeft() { selectedProject?.splitLeft() }
    func splitDown() { selectedProject?.splitDown() }
    func splitUp() { selectedProject?.splitUp() }
    func split(toward edge: PaneDropEdge) { selectedProject?.split(toward: edge) }
    func focusPaneLeft() { selectedProject?.focusLeft() }
    func focusPaneRight() { selectedProject?.focusRight() }
    func focusPaneUp() { selectedProject?.focusUp() }
    func focusPaneDown() { selectedProject?.focusDown() }
    func focusNextPane() { selectedProject?.focusNextPane() }
    func focusPreviousPane() { selectedProject?.focusPreviousPane() }

    func togglePaneZoom() { selectedProject?.togglePaneZoom() }
    func equalizePanes() { selectedProject?.equalizePanes() }
    func resizePaneUp() { selectedProject?.resizePaneUp() }
    func resizePaneDown() { selectedProject?.resizePaneDown() }
    func resizePaneLeft() { selectedProject?.resizePaneLeft() }
    func resizePaneRight() { selectedProject?.resizePaneRight() }

    /// Whether the focused pane can be split right now (false for diffs / no
    /// project).
    var canSplit: Bool { selectedProject?.canSplit ?? false }

    /// Whether the selected tab holds more than one pane — gates the zoom,
    /// resize and equalize commands.
    var hasSplitPanes: Bool { selectedProject?.hasSplitPanes ?? false }

    /// Whether the selected tab is showing a zoomed pane — drives the header's
    /// exit-zoom indicator.
    var isPaneZoomed: Bool { selectedProject?.isPaneZoomed ?? false }

    // MARK: - Browser

    private var selectedBrowser: BrowserTab? {
        if case .browser(let browser)? = selectedProject?.focusedContent {
            return browser
        }
        return nil
    }

    var hasSelectedBrowser: Bool { selectedBrowser != nil }

    func focusBrowserAddressBar() {
        selectedBrowser?.requestAddressFocus()
    }

    func reloadSelectedBrowser() {
        selectedBrowser?.reload()
    }

    func stopSelectedBrowser() {
        selectedBrowser?.stopLoading()
    }

    func openSelectedPageInDefaultBrowser() {
        selectedBrowser?.openInDefaultBrowser()
    }

    func copySelectedBrowserAddress() {
        selectedBrowser?.copyAddress()
    }

    func selectNextTab() {
        selectedProject?.selectNext()
    }

    func selectPreviousTab() {
        selectedProject?.selectPrevious()
    }

    func selectTab(index: Int) {
        selectedProject?.select(index: index)
    }

    // MARK: - Files

    /// Opens `path` as a file tab in the current project.
    func openFile(_ path: String) {
        selectedProject?.openFile(path)
    }

    /// Opens `path` as a file tab and moves cursor to specified line and column.
    func openFile(_ path: String, line: Int, column: Int = 0) {
        selectedProject?.openFile(path, line: line, column: column)
    }

    /// Open right sidebar, select Files tab, and switch to Search mode.
    func openSearchInFiles() {
        if !isPanelVisible {
            isPanelVisible = true
        }
        panelTab = .files
        filePanelMode = .search
    }

    /// Opens `path` as a pane beside the focused one in the current tab.
    func openFileToSide(_ path: String) {
        selectedProject?.openFileToSide(path)
    }

    /// Opens a git diff tab in the current project.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        selectedProject?.openDiff(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
    }

    /// Saves the focused pane if it holds a file.
    func saveSelectedFile() {
        if case .file(let file)? = selectedProject?.focusedContent {
            file.save()
        }
    }

    /// Propagates a file-tree rename to every open file tab across all
    /// projects, so tabs for the moved file (or files under a moved
    /// directory) keep pointing at the right place.
    func fileRenamed(from oldPath: String, to newPath: String) {
        for project in projects {
            project.updateFilePaths(from: oldPath, to: newPath)
        }
    }

    // MARK: - Panels & appearance

    func toggleSidebar() {
        isPanelVisible.toggle()
    }

    func toggleLeftSidebar() {
        isLeftSidebarVisible.toggle()
    }

    func toggleCommandPalette() {
        if isCommandPaletteVisible {
            dismissCommandPalette()
        } else {
            commandPaletteWindow = NSApp.keyWindow
            if let responder = commandPaletteWindow?.firstResponder,
               let stableResponder = stableWorkspaceResponder(from: responder) {
                commandPalettePreviousResponder = stableResponder
            } else {
                commandPalettePreviousResponder = nil
            }
            isCommandPaletteVisible = true
        }
    }

    func dismissCommandPalette() {
        guard isCommandPaletteVisible else { return }
        isCommandPaletteVisible = false
    }

    /// Called by the palette after SwiftUI has actually removed its focused
    /// search field from the window.
    func restoreFocusAfterCommandPalette() {
        let window = commandPaletteWindow
        let responder = commandPalettePreviousResponder
        commandPaletteWindow = nil
        commandPalettePreviousResponder = nil

        // Let the removal transaction finish before restoring the displaced
        // AppKit responder.
        DispatchQueue.main.async {
            guard let window, let responder else { return }
            // A palette command may already have focused a new terminal or
            // editor. Never let restoration race that newer focus and win.
            if let current = window.firstResponder,
               current !== responder,
               self.stableWorkspaceResponder(from: current) != nil {
                return
            }
            window.makeFirstResponder(responder)
        }
    }

    /// 返回可跨命令面板稳定恢复的宿主 responder；排除会被 SwiftUI 输入框复用的普通 field editor。
    private func stableWorkspaceResponder(
        from responder: NSResponder
    ) -> NSResponder? {
        if responder is KeroTerminalView || responder is FocusReportingTextView {
            return responder
        }
        if let addressField = responder as? BrowserAddressTextField {
            return addressField
        }
        if let fieldEditor = responder as? NSTextView,
           let addressField = fieldEditor.delegate as? BrowserAddressTextField {
            return addressField
        }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return responder }
            view = current.superview
        }
        return nil
    }

    /// Shows the sidebar on `panel`, or hides it if already showing that panel.
    func togglePanel(_ panel: RightPanel) {
        if isPanelVisible && panelTab == panel {
            isPanelVisible = false
        } else {
            panelTab = panel
            isPanelVisible = true
        }
    }

    /// Re-themes every session after a light/dark appearance change.
    func refreshAppearance() {
        for project in projects {
            for session in project.sessions {
                session.applyTheme()
            }
        }
    }

    /// 套用当前选中项目的 Light/Dark 配色覆盖后重绘终端与原生色。
    /// `followsGlobal` 的项目会清空覆盖，回到全局 theme-light / theme-dark。
    func reloadActiveProjectTheme() {
        let project = selectedProject
        Theme.reloadProjectSelection(project?.theme, projectName: project?.name)
        refreshAppearance()
    }

    /// 自定义主题重命名 / 删除时，同步所有窗口内项目的 light/dark 覆盖。
    /// `to == nil` 表示清除该侧覆盖（跟随全局）。
    static func remapProjectThemeName(from old: String, to new: String?) {
        for manager in registry {
            for project in manager.projects {
                var theme = project.theme
                var changed = false
                if theme.dark == old {
                    theme = theme.withDark(new)
                    changed = true
                }
                if theme.light == old {
                    theme = theme.withLight(new)
                    changed = true
                }
                if changed {
                    project.theme = theme
                }
            }
            manager.reloadActiveProjectTheme()
        }
    }

    /// 自定义主题配色变更后重绘全部窗口的终端（选择名未变时 settings 观察者不会触发）。
    static func refreshAllAppearances() {
        for manager in registry {
            manager.reloadActiveProjectTheme()
        }
    }

    /// After the first window appears, reopen one window per unclaimed
    /// saved snapshot; each new window's manager claims the next one.
    /// Deferred a runloop tick so windows the system itself restores can
    /// claim theirs first.
    static func openRestoredWindows(_ open: @escaping () -> Void) {
        windowOpener = open
        guard !didReopenWindows else { return }
        didReopenWindows = true
        DispatchQueue.main.async {
            for _ in 0..<pendingRestores.count {
                open()
            }
        }
    }

    /// Called when this manager's window closes: drop it from the
    /// persisted set — except for the last window, whose snapshot is kept
    /// saved and queued so reopening (or relaunching) restores it — and
    /// kill its shells.
    func windowClosed() {
        guard !Self.isQuitting else { return }
        Self.registry.removeAll { $0 === self }
        if Self.registry.isEmpty {
            // These shells are about to be destroyed, so this is their final
            // capture even though the macOS app may remain open with no window.
            let window = makeWindowSnapshot(captureTerminalHistory: true)
            // Last window: keep its snapshot and scrollback saved and queued so
            // reopening (or relaunching) restores them.
            SessionStore.save([window.snapshot])
            TerminalHistoryStore.save(window.histories)
            Self.pendingRestores = [window.snapshot]
            Self.pendingHistories = window.histories
        } else {
            Self.saveAll(captureTerminalHistory: false)
        }
        for project in projects {
            project.terminateAll()
        }
    }

    // MARK: - Persistence

    private static func saveAll(captureTerminalHistory: Bool) {
        guard !registry.isEmpty else { return }
        var snapshots: [SessionSnapshot] = []
        var histories: [String: String] = [:]
        for manager in registry {
            let window = manager.makeWindowSnapshot(
                captureTerminalHistory: captureTerminalHistory
            )
            snapshots.append(window.snapshot)
            histories.merge(window.histories) { _, new in new }
        }
        SessionStore.save(snapshots)
        TerminalHistoryStore.save(histories)
    }

    /// Builds this window's layout snapshot and, alongside it, the scrollback
    /// to persist for its sessions. Each captured session gets a fresh
    /// `historyKey` stored on both sides so restore can pair them; sessions
    /// with no history (feature off, empty, or unserializable) get no key.
    private func makeWindowSnapshot(
        captureTerminalHistory: Bool
    ) -> (snapshot: SessionSnapshot, histories: [String: String]) {
        typealias ProjectSnapshot = SessionSnapshot.ProjectSnapshot
        var histories: [String: String] = [:]
        let snapshot = SessionSnapshot(
            projects: projects.map { project in
                let tabs = project.tabs.map { tab -> ProjectSnapshot.TabSnapshot in
                    let columns = tab.columns.map { column in
                        ProjectSnapshot.ColumnSnapshot(
                            panes: column.panes.map { pane in
                                var historyKey: String?
                                if case .session(let session) = pane.content,
                                   let history = session.serializedHistory(
                                       captureLive: captureTerminalHistory
                                   ), !history.isEmpty {
                                    let key = UUID().uuidString
                                    histories[key] = history
                                    historyKey = key
                                }
                                return ProjectSnapshot.PaneSnapshot(
                                    content: Self.contentSnapshot(pane.content),
                                    weight: Double(pane.weight),
                                    historyKey: historyKey
                                )
                            },
                            weight: Double(column.weight)
                        )
                    }
                    let (col, row) = tab.focusedLocation() ?? (0, 0)
                    return ProjectSnapshot.TabSnapshot(
                        columns: columns, focusedColumn: col, focusedRow: row,
                        customName: tab.customName
                    )
                }
                ProjectConfigStore.save(
                    ProjectConfig(
                        customName: project.customName,
                        useAutoTitle: project.useAutoTitle,
                        description: project.description,
                        icon: project.icon,
                        theme: project.theme,
                        projectDirectory: project.projectDirectory,
                        launchCommands: project.launchCommands,
                        isArchived: project.isArchived,
                        aiWritingLanguage: project.aiWritingLanguage?.rawValue
                    ),
                    for: project.id
                )
                return ProjectSnapshot(
                    id: project.id,
                    customName: nil,
                    useAutoTitle: nil,
                    description: nil,
                    icon: nil,
                    theme: project.theme,
                    projectDirectory: nil,
                    isArchived: project.isArchived,
                    tabs: tabs,
                    selectedTabIndex: project.tabs.firstIndex { $0.id == project.selectedTabID }
                )
            },
            selectedProjectIndex: projects.firstIndex { $0.id == selectedProjectID },
            isLeftSidebarVisible: isLeftSidebarVisible,
            isRightPanelVisible: isPanelVisible,
            rightPanelTab: panelTab
        )
        return (snapshot, histories)
    }

    private static func contentSnapshot(
        _ content: PaneContent
    ) -> SessionSnapshot.ProjectSnapshot.PaneContentSnapshot {
        switch content {
        case .session(let session):
            return .session(workingDirectory: session.currentDirectoryPath)
        case .file(let file):
            return .file(path: file.path, editorState: file.editorState)
        case .browser(let browser):
            return .browser(url: browser.snapshotURL)
        case .diff(let diff):
            return .diff(
                repoRoot: diff.repoRoot, path: diff.path, staged: diff.staged,
                untracked: diff.untracked, origPath: diff.origPath
            )
        }
    }

    /// 从磁盘 `config/projects` 存储与会话快照重新构建项目和标签页列表。
    ///
    /// `config/projects` 目录作为项目列表的权威来源 (Source of truth)，扫描磁盘上所有项目配置文件；
    /// 快照 `session.json` 则提供各个项目内部 Tab/Pane 的会话布局恢复与渲染顺位。
    private func restore(from snapshot: SessionSnapshot) -> Bool {
        if let visible = snapshot.isLeftSidebarVisible {
            isLeftSidebarVisible = visible
        }
        if let visible = snapshot.isRightPanelVisible {
            isPanelVisible = visible
        }
        if let tab = snapshot.rightPanelTab {
            panelTab = tab
        }

        // 1. 获取磁盘 config/projects 目录下保存的所有有效项目 ID 集合
        let diskProjectIDs = ProjectConfigStore.allProjectIDs()
        let diskIDSet = Set(diskProjectIDs)

        var loadedProjectIDs = Set<UUID>()
        let targetProjectIndex = snapshot.selectedProjectIndex ?? 0

        // 2. 优先按快照中的顺序恢复存活在 config/projects 中的项目及其 Tab/Pane 布局
        for (projectIndex, saved) in snapshot.projects.enumerated() {
            guard let savedID = saved.id, diskIDSet.contains(savedID) else {
                // 若快照记录的项目已被从 config/projects 中彻底删除，则跳过
                continue
            }
            loadedProjectIDs.insert(savedID)

            let project = makeProject(id: savedID, createInitialSession: false)
            let config = ProjectConfigStore.load(for: project.id)
            project.customName = config?.customName ?? saved.customName
            project.useAutoTitle = config?.useAutoTitle ?? saved.useAutoTitle ?? false
            project.description = config?.description ?? saved.description
            project.icon = config?.icon ?? saved.icon
            project.theme = config?.theme ?? saved.theme ?? .global
            project.projectDirectory = config?.projectDirectory ?? saved.projectDirectory ?? ""
            project.launchCommands = config?.launchCommands ?? []
            project.isArchived = config?.isArchived ?? saved.isArchived ?? false
            project.aiWritingLanguage = config?.aiWritingLanguage
                .flatMap(AIWritingLanguage.init(rawValue:))
            let targetTabIndex = saved.selectedTabIndex ?? 0
            for (tabIndex, tab) in saved.tabs.enumerated() {
                let isSelectedActiveTab = (projectIndex == targetProjectIndex && tabIndex == targetTabIndex)
                project.restoreTab(
                    from: tab,
                    histories: Self.pendingHistories,
                    sessionDirectory: project.projectDirectory.isEmpty
                        ? nil
                        : project.projectDirectory,
                    isLazy: !isSelectedActiveTab
                )
            }
            if project.projectDirectory.isEmpty {
                project.projectDirectory = project.sessions.first?.currentDirectoryPath ?? ""
            }
            // 确保项目配置在磁盘上最新
            project.saveConfig()

            if let index = saved.selectedTabIndex, project.tabs.indices.contains(index) {
                project.selectedTabID = project.tabs[index].id
            }
            project.resetRecency()
            projects.append(project)
        }

        // 3. 读取并补全 config/projects 下存在但未在快照中列出的项目（以 config/projects 为主要来源）
        for diskID in diskProjectIDs {
            guard !loadedProjectIDs.contains(diskID) else { continue }
            guard let config = ProjectConfigStore.load(for: diskID) else { continue }

            let project = makeProject(id: diskID, createInitialSession: false)
            project.customName = config.customName
            project.useAutoTitle = config.useAutoTitle ?? false
            project.description = config.description
            project.icon = config.icon
            project.theme = config.theme ?? .global
            project.projectDirectory = config.projectDirectory ?? ""
            project.launchCommands = config.launchCommands ?? []
            project.isArchived = config.isArchived ?? false
            project.aiWritingLanguage = config.aiWritingLanguage
                .flatMap(AIWritingLanguage.init(rawValue:))

            // 为补全的项目分配默认终端会话
            project.newSession(directory: project.projectDirectory.isEmpty ? nil : project.projectDirectory)
            project.resetRecency()
            projects.append(project)
        }

        guard !projects.isEmpty else { return false }
        if let index = snapshot.selectedProjectIndex, projects.indices.contains(index) {
            selectedProjectID = projects[index].id
        } else {
            selectedProjectID = projects.first?.id
        }
        return true
    }
}
