//
//  Project.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// 应用内置预置图标（随 Bundle 打包的 Material / TerminalAppIcons 资源）。
enum ProjectPresetIcon: Codable, Equatable, Hashable {
    /// Material Icon Theme 逻辑名（如 `typescript`、`nodejs`）。
    case material(String)
    /// `TerminalAppIcons/icons` 下的文件名（如 `bxl-github.svg`、`antigravity-color.png`）。
    case bundled(String)
}

/// 项目列表中显示的自定义图标。
enum ProjectIcon: Codable, Equatable {
    case sfSymbol(String)
    case emoji(String)
    /// 本应用内置预置图标。
    case preset(ProjectPresetIcon)
    /// 用户选择的图片文件绝对路径（通常为配置目录下的托管副本）。
    case file(String)
}

/// A reusable project launch target shown in the Start panel.
enum ProjectLaunchCommandType: String, Codable, CaseIterable, Identifiable {
    case terminal
    case application
    case finderFolder
    case web
    case agentCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return L10n.t("Terminal")
        case .application: return L10n.t("Application")
        case .finderFolder: return L10n.t("Finder Folder")
        case .web: return L10n.t("Webpage")
        case .agentCLI: return L10n.t("Agent CLI")
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .application: return "app"
        case .finderFolder: return "folder"
        case .web: return "globe"
        case .agentCLI: return "sparkles"
        }
    }
}

/// How a terminal launcher is inserted into the current terminal tab.
enum ProjectLaunchSplit: String, Codable, CaseIterable, Identifiable {
    case none
    case left
    case right
    case top
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L10n.t("New Tab")
        case .left: return L10n.t("Split Left")
        case .right: return L10n.t("Split Right")
        case .top: return L10n.t("Split Above")
        case .bottom: return L10n.t("Split Below")
        }
    }

    var edge: PaneDropEdge? {
        switch self {
        case .none: return nil
        case .left: return .left
        case .right: return .right
        case .top: return .top
        case .bottom: return .bottom
        }
    }
}

/// One user-configured project launcher. `target` is used only by application
/// launchers; `content` is the terminal command, app argument, folder path,
/// or webpage URL for the corresponding type.
struct ProjectLaunchCommand: Codable, Identifiable, Equatable {
    var id: UUID
    var type: ProjectLaunchCommandType
    var title: String
    var target: String
    var content: String
    var split: ProjectLaunchSplit

    init(
        id: UUID = UUID(),
        type: ProjectLaunchCommandType = .terminal,
        title: String = "",
        target: String = "",
        content: String = "",
        split: ProjectLaunchSplit = .none
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.target = target
        self.content = content
        self.split = split
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, target, content, split
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decodeIfPresent(ProjectLaunchCommandType.self, forKey: .type) ?? .terminal
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        split = try container.decodeIfPresent(ProjectLaunchSplit.self, forKey: .split) ?? .none
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .agentCLI {
            let cli = target.trimmingCharacters(in: .whitespacesAndNewlines)
            let cliName = cli.isEmpty ? "Agent CLI" : cli
            return content.isEmpty ? cliName : "\(cliName): \(content)"
        }
        return content.isEmpty ? type.title : content
    }

    /// 将 Launcher 配置的文件夹路径解析为实际的 Finder 绝对目录 URL。
    ///
    /// 支持相对路径（如 `./`、`.` 或相对子目录）、波浪号路径（`~/`）、绝对路径或空字符串。
    /// 相对路径将以 `projectDirectory`（项目根目录）为基准进行解析；若解析出的路径在磁盘上不存在，降级退回项目根目录。
    ///
    /// - Parameters:
    ///   - rawPath: 用户输入的路径字符串。
    ///   - projectDirectory: 当前项目的根目录绝对路径。
    /// - Returns: 解析后的绝对目录 URL。
    static func resolveFolderURL(_ rawPath: String, projectDirectory: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let projDirURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)

        if trimmed.isEmpty || trimmed == "." || trimmed == "./" {
            return projDirURL
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolvedPath: String
        if (expanded as NSString).isAbsolutePath {
            resolvedPath = expanded
        } else {
            resolvedPath = (projectDirectory as NSString).appendingPathComponent(expanded)
        }

        let targetURL = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL

        // 目标路径如果真实存在，使用 targetURL；否则降级退回项目根目录 URL
        if FileManager.default.fileExists(atPath: targetURL.path) {
            return targetURL
        } else if FileManager.default.fileExists(atPath: projDirURL.path) {
            return projDirURL
        } else {
            return targetURL
        }
    }
}

/// A project groups tabs and appears as one row in the left sidebar. Each tab
/// is a niri-style layout of panes (terminal sessions and open files); see
extension Notification.Name {
    static let qjiaoProjectConfigDidChange = Notification.Name("qjiaoProjectConfigDidChange")
}

/// A project groups tabs and appears as one row in the left sidebar. Each tab
/// is a niri-style layout of panes (terminal sessions and open files); see
/// `PaneTab`. It always starts with one session; closing the last tab leaves
/// the project open but empty — only the explicit "Close Project" action (see
/// `TerminalManager.close(_:)`) removes it from the manager.
@MainActor
final class Project: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id: UUID

    /// User-assigned name; when nil the project title follows the
    /// selected session's terminal title.
    @Published var customName: String? {
        didSet {
            saveConfig()
        }
    }
    /// 是否开启自动标题。为 true 时显示终端动态标题且保留 customName 设置；为 false 时优先显示 customName。
    @Published var useAutoTitle: Bool = false {
        didSet {
            saveConfig()
        }
    }
    /// 项目的可选描述，显示在项目列表名称下方。
    @Published var description: String?
    /// 项目根目录；与终端当前工作目录分开保存。
    @Published var projectDirectory = ""
    /// 项目列表的可选自定义图标；未设置时显示默认文件夹图标。
    @Published var icon: ProjectIcon? {
        didSet {
            ProjectIconThumbnailCache.clearCache()
            saveConfig()
        }
    }
    /// 项目级 Light/Dark 配色覆盖；默认两侧都跟随全局。
    @Published var theme: ProjectTheme = .global {
        didSet {
            saveConfig()
        }
    }
    /// 项目是否已归档，归档后会移至左侧边栏底部的归档栏中。
    @Published var isArchived: Bool = false {
        didSet {
            saveConfig()
        }
    }
    /// 项目级 AI 写作语言覆盖；nil 表示跟随全局 `AppSettings.aiWritingLanguage`。
    @Published var aiWritingLanguage: AIWritingLanguage? {
        didSet {
            saveConfig()
        }
    }
    /// 可选指定 Git 仓库路径（位于项目目录 `projectDirectory` 的子文件夹中或项目目录本身）。
    @Published var customGitPath: String? {
        didSet {
            saveConfig()
        }
    }
    /// User-configured actions displayed in the right sidebar's Start panel.
    @Published var launchCommands: [ProjectLaunchCommand] = []
    @Published var tabs: [PaneTab] = []
    /// 内容区实际选中的 Tab。用户点击切换时可能比顶栏 chrome 晚一拍，避免终端/侧栏重活卡住点击反馈。
    @Published var selectedTabID: UUID? {
        didSet {
            // 直接赋值（新建/关闭/恢复）时与 chrome 对齐。
            if chromeSelectedTabID != selectedTabID {
                chromeSelectedTabID = selectedTabID
            }
            guard selectedTabID != oldValue, let selectedTabID else { return }
            recentTabIDs.removeAll { $0 == selectedTabID }
            recentTabIDs.insert(selectedTabID, at: 0)
        }
    }

    /// 顶栏 / 列表的即时选中态；用户切换时先更新这里，内容区再跟进 `selectedTabID`。
    @Published private(set) var chromeSelectedTabID: UUID?

    /// 取消过期的延迟内容切换（快速连点时只应用最后一次）。
    private var selectTabGeneration = 0

    /// 按使用时间从新到旧记录的 Tab ID 列表。
    private var recentTabIDs: [UUID] = []

    /// 按最近使用顺序排序的标签页列表（最近使用的在最前面）。
    /// 未在本会话中选中的标签页保留物理顺序接在末尾。
    var tabsByRecency: [PaneTab] {
        var seen = Set<UUID>()
        var ordered: [PaneTab] = []
        func add(_ tab: PaneTab) {
            guard seen.insert(tab.id).inserted else { return }
            ordered.append(tab)
        }
        for id in recentTabIDs {
            if let tab = tabs.first(where: { $0.id == id }) {
                add(tab)
            }
        }
        for tab in tabs {
            add(tab)
        }
        return ordered
    }

    /// 重置 Recency 历史（在恢复会话 snapshot 后调用）
    func resetRecency() {
        recentTabIDs.removeAll()
        if let selectedTabID {
            recentTabIDs.append(selectedTabID)
        }
    }

    /// 描述 Files/Git 面板根目录产生的判决规则。
    enum PanelRootSource: Equatable {
        /// 用户在项目菜单中手动固定的目录。
        case pinned
        /// Shell 自身所在 Git 仓库或工作目录。
        case shell
        /// 终端前台作业 (如 Agent) 切换到的 Worktree / 仓库。
        case foreground(isWorktree: Bool)
    }

    struct PanelRootResult {
        let root: String
        let source: PanelRootSource
    }

    /// 校验指定的 Git 路径是否为合法且存在的目录。
    func isValidCustomGitPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let standardizedPath = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL.path
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: standardizedPath, isDirectory: &isDir) && isDir.boolValue
    }

    /// 计算 Files 与 Project 面板应锚定的根目录路径及其来源。
    func panelRoot(
        followingSessionAt cwd: String,
        foregroundAt foregroundCwd: String? = nil
    ) -> PanelRootResult {
        if !projectDirectory.isEmpty,
           FileManager.default.fileExists(atPath: projectDirectory) {
            return PanelRootResult(root: projectDirectory, source: .pinned)
        }

        let shellRepo = Self.closestGitRepository(for: cwd)
        if let foregroundCwd, !foregroundCwd.isEmpty {
            if let fgRepo = Self.closestGitRepository(for: foregroundCwd),
               fgRepo != shellRepo {
                let gitPath = (fgRepo as NSString).appendingPathComponent(".git")
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir)
                let isWorktree = exists && !isDir.boolValue
                return PanelRootResult(root: fgRepo, source: .foreground(isWorktree: isWorktree))
            }
        }

        if let shellRepo {
            return PanelRootResult(root: shellRepo, source: .shell)
        }

        return PanelRootResult(root: cwd, source: .shell)
    }

    /// 计算 Git 面板与状态扫描应锚定的仓库根目录。
    /// 若用户为项目指定了 customGitPath，且合法并存在，优先使用 customGitPath；
    /// 否则按 session cwd / shell repo / foreground repo / projectDirectory 自动判定。
    func gitRoot(
        followingSessionAt cwd: String = "",
        foregroundAt foregroundCwd: String? = nil
    ) -> String {
        if let customGitPath, isValidCustomGitPath(customGitPath) {
            return URL(fileURLWithPath: customGitPath).resolvingSymlinksInPath().path
        }
        if let foregroundCwd, !foregroundCwd.isEmpty,
           let fgRepo = Self.closestGitRepository(for: foregroundCwd) {
            return fgRepo
        }
        if !cwd.isEmpty, let shellRepo = Self.closestGitRepository(for: cwd) {
            return shellRepo
        }
        if !projectDirectory.isEmpty, FileManager.default.fileExists(atPath: projectDirectory) {
            return URL(fileURLWithPath: projectDirectory).resolvingSymlinksInPath().path
        }
        return cwd
    }

    /// 查找包含指定路径的最近 Git 仓库根目录（向上寻找包含 .git 的目录）。
    private static func closestGitRepository(for path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var currentURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        while currentURL.pathComponents.count > 1 {
            let gitPath = currentURL.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitPath) {
                return currentURL.path
            }
            let parent = currentURL.deletingLastPathComponent()
            if parent.path == currentURL.path { break }
            currentURL = parent
        }
        return nil
    }
    private var isUpdatingFromStorage = false
    private var configChangeObservation: AnyCancellable?

    /// 解析本项目实际使用的 AI 写作语言（项目覆盖优先，否则全局）。
    var resolvedAIWritingLanguage: AIWritingLanguage {
        aiWritingLanguage ?? AppSettings.shared.aiWritingLanguage
    }

    /// 将项目配置（名称、描述、图标、主题、导航路径等）立即持久化保存到磁盘配置文件。
    func saveConfig() {
        guard !isUpdatingFromStorage else { return }
        ProjectConfigStore.save(
            ProjectConfig(
                customName: customName,
                useAutoTitle: useAutoTitle,
                description: description,
                icon: icon,
                theme: theme,
                projectDirectory: projectDirectory,
                launchCommands: launchCommands,
                isArchived: isArchived,
                aiWritingLanguage: aiWritingLanguage?.rawValue,
                customGitPath: customGitPath
            ),
            for: id
        )
        NotificationCenter.default.post(
            name: .qjiaoProjectConfigDidChange,
            object: self,
            userInfo: ["id": id]
        )
    }

    /// 从磁盘配置文件中更新本项目的各项配置属性（用于多窗口改动同步）。
    func reloadConfig() {
        guard let config = ProjectConfigStore.load(for: id) else { return }
        isUpdatingFromStorage = true
        defer { isUpdatingFromStorage = false }

        if customName != config.customName { customName = config.customName }
        if useAutoTitle != (config.useAutoTitle ?? false) { useAutoTitle = config.useAutoTitle ?? false }
        if description != config.description { description = config.description }
        if let dir = config.projectDirectory, projectDirectory != dir { projectDirectory = dir }
        if icon != config.icon { icon = config.icon }
        if theme != (config.theme ?? .global) { theme = config.theme ?? .global }
        if isArchived != (config.isArchived ?? false) { isArchived = config.isArchived ?? false }
        if launchCommands != (config.launchCommands ?? []) { launchCommands = config.launchCommands ?? [] }
        let aiLang = config.aiWritingLanguage.flatMap(AIWritingLanguage.init(rawValue:))
        if aiWritingLanguage != aiLang { aiWritingLanguage = aiLang }
        if customGitPath != config.customGitPath { customGitPath = config.customGitPath }
    }

    /// 历史回调：曾用于「终端 drop 文件夹 → 创建项目」。
    /// 现已改为左侧边栏 drop；保留字段以免会话层配置代码失效，默认不接线。
    var onOpenProjectDirectory: ((URL) -> Bool)? {
        didSet {
            for session in sessions {
                configureProjectDirectoryDrop(for: session)
            }
        }
    }

    private let fallbackName: String
    /// Sessions publish their own changes (title, directory); re-publish them
    /// so the project name and views observing the project stay current.
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    /// Tabs publish layout changes (splits, focus, resize); re-publish them so
    /// the strip re-renders and autosave fires.
    private var tabObservations: [UUID: AnyCancellable] = [:]
    /// 浏览器导航会改变动态标题和快照 URL，因此同样向 Project 转发变化。
    private var browserObservations: [UUID: AnyCancellable] = [:]

    /// Pass `createInitialSession: false` when restoring a saved project;
    /// the caller then rebuilds the tabs itself.
    init(id: UUID = UUID(), fallbackName: String, createInitialSession: Bool = true) {
        self.id = id
        self.fallbackName = fallbackName
        if createInitialSession {
            newSession()
            projectDirectory = selectedSession?.currentDirectoryPath ?? ""
        }
        configChangeObservation = NotificationCenter.default
            .publisher(for: .qjiaoProjectConfigDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if (notification.object as AnyObject) === self { return }
                guard let targetID = notification.userInfo?["id"] as? UUID, targetID == self.id else { return }
                self.reloadConfig()
            }
    }

    var name: String {
        if useAutoTitle {
            return selectedSession?.title ?? fallbackName
        }
        if let customName, !customName.isEmpty {
            return customName
        }
        return selectedSession?.title ?? fallbackName
    }

    /// Every terminal session across every pane in every tab.
    var sessions: [TerminalSession] {
        tabs.flatMap(\.sessions)
    }

    var selectedTab: PaneTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Content of the focused pane in the selected tab.
    var focusedContent: PaneContent? {
        selectedTab?.focusedContent
    }

    /// Every diff shown anywhere, paired with the id of its containing tab so
    /// the content view can tell which one is currently on screen.
    var diffPlacements: [(diff: DiffTab, tabID: UUID)] {
        tabs.flatMap { tab in tab.diffs.map { (diff: $0, tabID: tab.id) } }
    }

    /// The focused terminal session; while a file, browser, or diff pane is focused it
    /// has no directory of its own, so panels that need a working directory
    /// (file tree, git, info) track a terminal that does: one sharing the
    /// file's tab (a split), else the session the file was opened from (the
    /// tab's `contextSession`), else the project's first session. The last two
    /// fallbacks are why opening a file from one tab kept showing another tab's
    /// directory when it landed on `sessions.first`.
    var selectedSession: TerminalSession? {
        if case .session(let session)? = focusedContent {
            return session
        }
        return selectedTab?.sessions.first
            ?? selectedTab?.contextSession
            ?? sessions.first
    }

    /// Whether the selected tab's focused pane can be split (false for diffs).
    var canSplit: Bool {
        selectedTab?.canSplit ?? false
    }

    // MARK: - Sessions

    /// When no directory is given, the new session starts in the current
    /// session's working directory (home if the project has none yet).
    @discardableResult
    func newSession(directory: String? = nil) -> TerminalSession {
        let session = makeSession(directory: directory)
        let tab = makeTab(content: .session(session))
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return session
    }

    /// Adds a fresh terminal next to the focused pane in the selected tab.
    /// Returns nil when there is no terminal-capable tab to split.
    func newSplitSession(
        directory: String? = nil, toward edge: PaneDropEdge
    ) -> TerminalSession? {
        guard let tab = selectedTab, tab.canSplit else { return nil }
        let session = makeSession(directory: directory)
        tab.split(Pane(content: .session(session)), toward: edge)
        return session
    }

    /// 在原 pane 位置用新终端会话替换旧会话，保留分屏布局、分隔比例与 pane id。
    /// 旧会话已不在任何 tab 的布局树中时返回 nil（调用方应回退到 `newSession`）。
    @discardableResult
    func replaceSession(
        id sessionID: UUID,
        directory: String? = nil
    ) -> TerminalSession? {
        for tab in tabs {
            guard let paneID = tab.paneID(forContent: sessionID) else { continue }
            // terminate 不会触发 onExited，因此 pane 不会被自动摘除，可安全原地替换。
            if let old = tab.sessions.first(where: { $0.id == sessionID }) {
                old.terminate()
                sessionObservations[sessionID] = nil
            }
            let session = makeSession(directory: directory)
            tab.replaceContent(in: paneID, with: .session(session))
            selectedTabID = tab.id
            return session
        }
        return nil
    }

    func addLaunchCommand(_ command: ProjectLaunchCommand) {
        launchCommands.append(command)
    }

    func updateLaunchCommand(_ command: ProjectLaunchCommand) {
        guard let index = launchCommands.firstIndex(where: { $0.id == command.id }) else { return }
        launchCommands[index] = command
    }

    func removeLaunchCommands(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            launchCommands.remove(at: index)
        }
    }

    func moveLaunchCommands(from offsets: IndexSet, to destination: Int) {
        let moved = offsets.map { launchCommands[$0] }
        for index in offsets.sorted(by: >) {
            launchCommands.remove(at: index)
        }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = destination - removedBeforeDestination
        launchCommands.insert(contentsOf: moved, at: insertionIndex)
    }

    func moveLaunchCommand(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = launchCommands.firstIndex(where: { $0.id == id }),
              let targetIndex = launchCommands.firstIndex(where: { $0.id == targetID })
        else { return }

        let command = launchCommands.remove(at: sourceIndex)
        launchCommands.insert(command, at: targetIndex)
    }

    /// Builds a session wired for exit + change observation, without placing
    /// it in a tab — shared by new tabs and splits. `restoredHistory` seeds the
    /// scrollback when reopening a saved session.
    private func makeSession(
        directory: String? = nil, restoredHistory: String? = nil, isLazy: Bool = false
    ) -> TerminalSession {
        let session = TerminalSession(
            initialDirectory: directory
                ?? selectedSession?.currentDirectoryPath
                ?? (projectDirectory.isEmpty ? nil : projectDirectory),
            restoredHistory: restoredHistory,
            isLazy: isLazy
        )
        configureProjectDirectoryDrop(for: session)
        session.onExited = { [weak self] session in
            // Already dead — just drop its pane, no second terminate.
            self?.closeContent(.session(session), terminate: false)
        }
        sessionObservations[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return session
    }

    /// 让每个终端会话使用项目统一的文件夹拖放处理器。
    private func configureProjectDirectoryDrop(for session: TerminalSession) {
        session.pendingOnOpenProjectDirectory = { [weak self] directoryURL in
            self?.onOpenProjectDirectory?(directoryURL) ?? false
        }
    }

    func terminateAll() {
        for session in sessions {
            session.terminate()
        }
    }

    /// 应用退出路径没有下一轮 runloop，必须同步停止所有终端进程组。
    func terminateAllImmediately() {
        for session in sessions {
            session.terminateImmediately()
        }
    }

    // MARK: - Splits

    func splitRight() { split(toward: .right) }
    func splitLeft() { split(toward: .left) }
    func splitDown() { split(toward: .bottom) }
    func splitUp() { split(toward: .top) }

    /// Splits the focused pane on `edge` with a fresh terminal. Left/right open
    /// a new column; top/bottom stack within the focused column. No-op while a
    /// diff is focused.
    func split(toward edge: PaneDropEdge) {
        guard let tab = selectedTab, tab.canSplit else { return }
        let session = makeSession()
        tab.split(Pane(content: .session(session)), toward: edge)
    }

    func focusLeft() { selectedTab?.focusLeft() }
    func focusRight() { selectedTab?.focusRight() }
    func focusUp() { selectedTab?.focusUp() }
    func focusDown() { selectedTab?.focusDown() }
    func focusNextPane() { selectedTab?.focusNext() }
    func focusPreviousPane() { selectedTab?.focusPrevious() }

    func togglePaneZoom() { selectedTab?.toggleZoom() }
    func equalizePanes() { selectedTab?.equalize() }
    func resizePaneUp() { selectedTab?.resizeUp() }
    func resizePaneDown() { selectedTab?.resizeDown() }
    func resizePaneLeft() { selectedTab?.resizeLeft() }
    func resizePaneRight() { selectedTab?.resizeRight() }

    /// Whether the selected tab is a split layout — gates zoom, resize and
    /// equalize.
    var hasSplitPanes: Bool { selectedTab?.hasMultiplePanes ?? false }

    /// Whether the selected tab is showing a zoomed pane.
    var isPaneZoomed: Bool { selectedTab?.isZoomed ?? false }

    // MARK: - Files

    /// Opens `path` as a new file tab, reusing an existing tab/pane for the
    /// same path. `editorState` seeds scroll/cursor state when restoring.
    func openFile(_ path: String, editorState: EditorState? = nil) {
        if let (tab, paneID) = findFilePane(path: path) {
            selectedTabID = tab.id
            tab.focusedPaneID = paneID
            if let pane = tab.allPanes.first(where: { $0.id == paneID }),
               case .file(let file) = pane.content,
               let editorState {
                file.editorState = editorState
                if let location = editorState.selectionLocation {
                    let range = NSRange(location: location, length: editorState.selectionLength ?? 0)
                    file.onJumpToSelection?(range)
                }
            }
            return
        }
        // Capture the current directory context *before* selection moves to the
        // new tab, so its panels track the tab the file was opened from.
        let context = selectedSession
        let file = FileTab(path: path)
        if let editorState {
            file.editorState = editorState
        }
        let tab = makeTab(content: .file(file))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    /// 打开文件并精确定位到指定行号与列号
    func openFile(_ path: String, line: Int, column: Int = 0) {
        var editorState: EditorState? = nil
        if let content = try? String(contentsOfFile: path) {
            let lines = content.components(separatedBy: .newlines)
            let targetLineIdx = max(0, min(line - 1, lines.count - 1))
            var offset = 0
            if !lines.isEmpty {
                for i in 0..<targetLineIdx {
                    offset += lines[i].count + 1
                }
                offset += max(0, min(column, lines[targetLineIdx].count))
            }
            editorState = EditorState(selectionLocation: offset, selectionLength: 0)
        }

        openFile(path, editorState: editorState)
    }

    /// Opens `path` as a new pane beside the focused one in the current tab
    /// ("Open to the Side"). Falls back to a fresh tab when the current tab
    /// can't take a split (e.g. it's a diff) or none is selected.
    func openFileToSide(_ path: String) {
        guard let tab = selectedTab, tab.canSplit else {
            openFile(path)
            return
        }
        if let existing = tab.allPanes.first(where: {
            if case .file(let file) = $0.content { return file.path == path }
            return false
        }) {
            tab.focusedPaneID = existing.id
            return
        }
        tab.split(Pane(content: .file(FileTab(path: path))), toward: .right)
    }

    private func findFilePane(path: String) -> (tab: PaneTab, paneID: UUID)? {
        for tab in tabs {
            if let pane = tab.allPanes.first(where: {
                if case .file(let file) = $0.content { return file.path == path }
                return false
            }) {
                return (tab, pane.id)
            }
        }
        return nil
    }

    /// 以十六进制编辑器模式打开 `path`。复用已有的十六进制标签页；
    /// 同路径若已以文本模式打开则另开新标签页，互不干扰。
    func openFileInHexEditor(_ path: String) {
        if let (tab, paneID) = findHexFilePane(path: path) {
            selectedTabID = tab.id
            tab.focusedPaneID = paneID
            return
        }
        let context = selectedSession
        let file = FileTab(path: path, hexEditor: true)
        let tab = makeTab(content: .file(file))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    private func findHexFilePane(path: String) -> (tab: PaneTab, paneID: UUID)? {
        for tab in tabs {
            if let pane = tab.allPanes.first(where: {
                if case .file(let file) = $0.content {
                    return file.path == path && file.isHexMode
                }
                return false
            }) {
                return (tab, pane.id)
            }
        }
        return nil
    }

    // MARK: - Browser

    /// 在当前标签旁创建原生浏览器 Tab。
    @discardableResult
    func newBrowserTab(
        initialURL: String? = nil,
        initialFocus: BrowserTab.InitialFocus = .addressBar
    ) -> BrowserTab {
        let context = selectedSession
        let browser = makeBrowser(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        let tab = makeTab(content: .browser(browser))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return browser
    }

    /// 在当前聚焦 Pane 的指定方向创建原生浏览器 Pane。
    @discardableResult
    func newBrowserPane(
        toward edge: PaneDropEdge = .right,
        initialURL: String? = nil,
        initialFocus: BrowserTab.InitialFocus = .addressBar
    ) -> BrowserTab? {
        guard let tab = selectedTab, tab.canSplit else { return nil }
        let browser = makeBrowser(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        tab.split(Pane(content: .browser(browser)), toward: edge)
        return browser
    }

    private func makeBrowser(
        initialURL: String?,
        initialFocus: BrowserTab.InitialFocus
    ) -> BrowserTab {
        let browser = BrowserTab(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        browserObservations[browser.id] = browser.objectWillChange.sink {
            [weak self] _ in
            self?.objectWillChange.send()
        }
        return browser
    }

    /// After a rename on disk, re-points any open file pane at its new path —
    /// the renamed file itself, or any file beneath a renamed directory.
    func updateFilePaths(from oldPath: String, to newPath: String) {
        for tab in tabs {
            for case .file(let file) in tab.allContents {
                if file.path == oldPath {
                    file.updatePath(newPath)
                } else if file.path.hasPrefix(oldPath + "/") {
                    file.updatePath(newPath + String(file.path.dropFirst(oldPath.count)))
                }
            }
        }
    }

    // MARK: - Diffs

    /// Opens a git diff as a new tab, reusing (and reloading) an existing tab
    /// for the same file and stage side.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        if let (tab, pane) = findDiffPane(repoRoot: repoRoot, path: path, staged: staged),
           case .diff(let diff) = pane.content {
            diff.untracked = untracked
            diff.origPath = origPath
            diff.reload()
            selectedTabID = tab.id
            tab.focusedPaneID = pane.id
            return
        }
        let context = selectedSession
        let diff = DiffTab(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
        let tab = makeTab(content: .diff(diff))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    private func findDiffPane(
        repoRoot: String, path: String, staged: Bool
    ) -> (tab: PaneTab, pane: Pane)? {
        for tab in tabs {
            if let pane = tab.allPanes.first(where: {
                if case .diff(let diff) = $0.content {
                    return diff.repoRoot == repoRoot && diff.path == path && diff.staged == staged
                }
                return false
            }) {
                return (tab, pane)
            }
        }
        return nil
    }

    // MARK: - Closing

    /// Closes one piece of content: terminates a session, prompts before
    /// discarding a dirty file, then removes its pane (dropping the tab when
    /// that was its last pane). `terminate` is false when a shell has already
    /// exited on its own.
    func closeContent(_ content: PaneContent, terminate: Bool = true) {
        switch content {
        case .session(let session):
            if terminate { session.terminate() }
            removePaneWithContent(content.id)
        case .file(let file):
            guard file.isDirty else {
                removePaneWithContent(content.id)
                return
            }
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            Task { @MainActor in
                _ = await confirmCloseUnsaved(file, in: window)
            }
        case .browser:
            removePaneWithContent(content.id)
        case .diff:
            removePaneWithContent(content.id)
        }
    }

    /// Closes the focused pane of the selected tab (⌘W).
    func closeFocusedPane() {
        guard let content = focusedContent else { return }
        closeContent(content)
    }

    func closeSelected() {
        closeFocusedPane()
    }

    /// Closes an entire tab — every pane it holds.
    func close(_ tab: PaneTab) {
        closeBatch(tab.allContents)
    }

    /// Closes every tab except `keep`.
    func closeOthers(_ keep: PaneTab) {
        selectedTabID = keep.id
        closeBatch(tabs.filter { $0.id != keep.id }.flatMap(\.allContents))
    }

    /// Closes every tab positioned to the right of `tab` in the strip.
    func closeToRight(of tab: PaneTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        closeBatch(Array(tabs[(index + 1)...]).flatMap(\.allContents))
    }

    /// Closes every tab, leaving the project open but empty.
    func closeAll() {
        closeBatch(tabs.flatMap(\.allContents))
    }

    /// Asks whether to save before discarding an edited file, matching the
    /// standard macOS Save / Don't Save / Cancel prompt. Presented as a sheet
    /// on `window` (app-modal only when there's no window) so it doesn't block
    /// the whole app. Returns `true` if the user backed out — Cancel, or a save
    /// that failed — so a batch close can stop before tearing down other panes.
    ///
    /// This is `async` on purpose: awaiting the sheet means each prompt in a
    /// batch is presented only after the previous one has fully dismissed.
    @discardableResult
    private func confirmCloseUnsaved(_ file: FileTab, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to \(file.name)?"
        alert.informativeText = L10n.t("Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: L10n.t("Save"))
        let dontSave = alert.addButton(withTitle: L10n.t("Don't Save"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: L10n.t("Cancel"))
        cancel.keyEquivalent = "\u{1b}"

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        switch response {
        case .alertFirstButtonReturn: // Save
            file.save()
            // Keep the pane open if the write failed; the error bar shows why.
            guard file.saveError == nil else { return true }
            removePaneWithContent(file.id)
            return false
        case .alertSecondButtonReturn: // Don't Save
            removePaneWithContent(file.id)
            return false
        default: // Cancel
            return true
        }
    }

    /// Closes several pieces of content at once. Any unsaved files are
    /// confirmed *first*, one prompt at a time; the remaining (clean) content
    /// is only torn down once every prompt has been answered — so cancelling
    /// out of a save prompt leaves the saved panes open too.
    private func closeBatch(_ targets: [PaneContent]) {
        let dirtyFiles = targets.compactMap { content -> FileTab? in
            if case .file(let file) = content, file.isDirty { return file }
            return nil
        }
        let cleanContents = targets.filter { content in
            if case .file(let file) = content { return !file.isDirty }
            return true
        }

        guard !dirtyFiles.isEmpty else {
            cleanContents.forEach { closeContent($0) }
            return
        }

        let window = NSApp.keyWindow ?? NSApp.mainWindow
        Task { @MainActor in
            for file in dirtyFiles where file.isDirty {
                // Bail the moment the user backs out — the clean panes, and any
                // files not yet prompted, stay open.
                if await confirmCloseUnsaved(file, in: window) { return }
            }
            cleanContents.forEach { closeContent($0) }
        }
    }

    // MARK: - Tab selection

    /// Moves a dragged tab across `targetID`: after it when moving right, or
    /// before it when moving left. Selection continues to follow its tab ID.
    func moveTab(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = tabs.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID })
        else { return }

        var reorderedTabs = tabs
        let draggedTab = reorderedTabs.remove(at: draggedIndex)
        reorderedTabs.insert(draggedTab, at: targetIndex)
        tabs = reorderedTabs
    }

    /// 将 `sourceID` 整个布局并入当前选中 Tab，落在 `targetPaneID` 的 `edge` 侧形成分屏。
    /// 源 Tab 被移除，但其中的终端 / 文件 / 浏览器会话保持挂载；不可并入自身。
    /// 源或目标含 diff 时拒绝（diff 独占单 pane Tab）。
    func mergeTab(_ sourceID: UUID, toward edge: PaneDropEdge, of targetPaneID: UUID) {
        guard sourceID != selectedTabID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == sourceID }),
              let targetTab = selectedTab,
              targetTab.canSplit,
              targetTab.layout.contains(targetPaneID)
        else { return }

        let sourceTab = tabs[sourceIndex]
        // diff 独占单 pane，不允许拖入其它 Tab 的分屏树
        guard sourceTab.diffs.isEmpty else { return }
        if let targetPane = targetTab.allPanes.first(where: { $0.id == targetPaneID }),
           case .diff = targetPane.content {
            return
        }

        let incomingLayout = sourceTab.layout
        let focusing = sourceTab.focusedPaneID

        // 只摘掉 Tab 条目与 tab 级观察；session / browser 观察继续由内容 id 持有。
        tabObservations[sourceID] = nil
        tabs.remove(at: sourceIndex)
        if chromeSelectedTabID == sourceID {
            chromeSelectedTabID = targetTab.id
        }

        targetTab.absorb(
            layout: incomingLayout,
            toward: edge,
            beside: targetPaneID,
            focusing: focusing
        )
    }

    /// 用户驱动的标签切换：先更新顶栏选中态，下一 runloop 再切换内容。
    /// 新建 / 关闭 / 恢复等路径请继续直接写 `selectedTabID`，以同步切换内容。
    /// - Parameter paintChrome: 为 false 时不写 `chromeSelectedTabID`（调用方已用本地 @State 抢先绘制，避免再触发整树刷新）。
    func selectTab(_ id: UUID, paintChrome: Bool = true) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if paintChrome, chromeSelectedTabID != id {
            chromeSelectedTabID = id
        }
        guard selectedTabID != id else { return }

        selectTabGeneration += 1
        let generation = selectTabGeneration
        // 等当前帧把 chrome 绘制出去，再动终端挂载、侧栏跟随等重活。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard generation == self.selectTabGeneration else { return }
            // paintChrome == false 时 chrome 可能仍是旧值，只校验 id 仍有效。
            if paintChrome {
                guard self.chromeSelectedTabID == id else { return }
            }
            guard self.tabs.contains(where: { $0.id == id }) else { return }
            guard self.selectedTabID != id else { return }
            self.selectedTabID = id
        }
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func selectNext() {
        shiftSelection(by: 1)
    }

    func selectPrevious() {
        shiftSelection(by: -1)
    }

    private func shiftSelection(by offset: Int) {
        guard !tabs.isEmpty else { return }
        // 连按下一标签时以 chrome 为准，避免内容尚未跟进时来回卡在旧选中项。
        let currentID = chromeSelectedTabID ?? selectedTabID
        guard let current = tabs.firstIndex(where: { $0.id == currentID })
        else { return }
        let next = (current + offset + tabs.count) % tabs.count
        selectTab(tabs[next].id)
    }

    // MARK: - Layout mutation plumbing

    private func makeTab(content: PaneContent) -> PaneTab {
        register(PaneTab(content: content))
    }

    /// Wires a tab's change observation and returns it — used for fresh tabs
    /// and for tabs rebuilt during restore.
    @discardableResult
    func register(_ tab: PaneTab) -> PaneTab {
        tabObservations[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return tab
    }

    /// Rebuilds a saved tab's pane layout — recreating its sessions (wired for
    /// exit + observation), files and diffs — then registers and appends it.
    /// Skips panes whose content can't be rebuilt; a tab with none is dropped.
    func restoreTab(
        from snap: SessionSnapshot.ProjectSnapshot.TabSnapshot,
        histories: [String: String] = [:],
        sessionDirectory: String? = nil,
        isLazy: Bool = false
    ) {
        let layout = restoreLayout(
            from: snap.layout, histories: histories,
            sessionDirectory: sessionDirectory, isLazy: isLazy
        )
        let panes = layout.allPanes
        guard !panes.isEmpty else { return }
        let focusedIndex = min(max(0, snap.focusedPaneIndex), panes.count - 1)
        let tab = PaneTab(layout: layout, focusedPaneID: panes[focusedIndex].id)
        tab.customName = snap.customName
        append(tab)
    }

    private func restoreLayout(
        from snap: SessionSnapshot.ProjectSnapshot.LayoutSnapshot,
        histories: [String: String],
        sessionDirectory: String?,
        isLazy: Bool
    ) -> PaneNode {
        switch snap {
        case .pane(let pane):
            let restoredHistory = pane.historyKey.flatMap { histories[$0] }
            return .pane(Pane(content: makeContent(
                from: pane.content,
                restoredHistory: restoredHistory,
                sessionDirectory: sessionDirectory,
                isLazy: isLazy
            )))
        case .split(let axis, let fraction, let first, let second):
            return .split(PaneSplit(
                axis: axis,
                fraction: CGFloat(fraction),
                first: restoreLayout(
                    from: first, histories: histories,
                    sessionDirectory: sessionDirectory, isLazy: isLazy
                ),
                second: restoreLayout(
                    from: second, histories: histories,
                    sessionDirectory: sessionDirectory, isLazy: isLazy
                )
            ))
        }
    }

    private func makeContent(
        from snap: SessionSnapshot.ProjectSnapshot.PaneContentSnapshot,
        restoredHistory: String? = nil,
        sessionDirectory: String? = nil,
        isLazy: Bool = false
    ) -> PaneContent {
        switch snap {
        case .session(let workingDirectory):
            return .session(
                makeSession(
                    directory: sessionDirectory ?? workingDirectory,
                    restoredHistory: restoredHistory,
                    isLazy: isLazy
                )
            )
        case .file(let path, let editorState):
            let file = FileTab(path: path)
            if let editorState { file.editorState = editorState }
            return .file(file)
        case .fileHex(let path, let editorState):
            let file = FileTab(path: path, hexEditor: true)
            if let editorState { file.editorState = editorState }
            return .file(file)
        case .browser(let url):
            return .browser(makeBrowser(initialURL: url, initialFocus: .none))
        case .diff(let repoRoot, let path, let staged, let untracked, let origPath):
            return .diff(DiffTab(
                repoRoot: repoRoot, path: path, staged: staged,
                untracked: untracked, origPath: origPath
            ))
        }
    }

    /// Inserts a newly created tab immediately after the current selection so
    /// new tabs open next to the current one instead of at the end of the
    /// strip. Appends when there's no selection — the first tab, or while
    /// restoring, where selection tracks the last tab added.
    private func insertNextToSelected(_ tab: PaneTab) {
        if let selectedTabID,
           let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    /// Appends a tab and selects it — used while restoring, which builds tabs
    /// in saved order.
    func append(_ tab: PaneTab) {
        register(tab)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Removes the pane holding `contentID` from whichever tab owns it, and
    /// drops the tab if that pane was its last.
    private func removePaneWithContent(_ contentID: UUID) {
        for tab in tabs {
            guard let paneID = tab.paneID(forContent: contentID) else { continue }
            // 两类观察表按内容 id 清理，其他内容类型为 no-op。
            sessionObservations[contentID] = nil
            browserObservations[contentID] = nil
            if !tab.removePane(paneID) {
                remove(tabID: tab.id)
            }
            return
        }
    }

    private func remove(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        for session in tab.sessions {
            sessionObservations[session.id] = nil
        }
        for browser in tab.browsers {
            browserObservations[browser.id] = nil
        }
        tabObservations[tabID] = nil
        tabs.remove(at: index)
        if selectedTabID == tabID {
            let neighbor = min(index, tabs.count - 1)
            selectedTabID = neighbor >= 0 ? tabs[neighbor].id : nil
        }
        // Emptying the project does not close it — the project row stays in the
        // sidebar until the user explicitly closes it.
    }
}
