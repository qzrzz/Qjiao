//
//  CommandPaletteView.swift
//  kero
//

import AppKit
import Combine
import FuzzyMatch
import SwiftUI

/// 将命令面板条目分为内置命令、项目文件与已打开会话。
enum PaletteSection: Hashable {
    case command
    case file
    case session

    var title: String {
        switch self {
        case .command: return L10n.t("Commands")
        case .file: return L10n.t("Files")
        case .session: return L10n.t("Sessions")
        }
    }
}

/// 命令面板中的单个可选条目，可执行命令、打开文件或跳转终端会话。
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// 标题后的辅助文字，用于展示文件相对目录或会话工作目录。
    var subtitle: String? = nil
    var shortcut: String? = nil
    var section: PaletteSection = .command
    /// 模糊匹配使用的完整文本；默认回退标题。
    var searchText: String? = nil
    let action: () -> Void
}

@MainActor
private final class PalettePointerSelectionController: ObservableObject {
    private(set) var acceptsPointerSelection = false

    func reset() {
        acceptsPointerSelection = false
    }

    func notePointerMoved() {
        acceptsPointerSelection = true
    }
}

/// Centered ⌘P overlay: fuzzy-searchable list of app actions. Arrow keys
/// move the selection, Return runs it, and Escape clears a query before
/// dismissing an already-empty palette.
struct CommandPaletteView: View {
    private struct ScoredProjectFile {
        let file: ProjectFile
        let score: Double
    }

    private struct ProjectFile: Sendable {
        let name: String
        let relativePath: String
        let absolutePath: String

        var parentPath: String? {
            let parent = (relativePath as NSString).deletingLastPathComponent
            return parent.isEmpty ? nil : parent
        }
    }

    @ObservedObject var manager: TerminalManager
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var selection = 0
    @State private var projectFiles: [ProjectFile] = []
    @StateObject private var pointerSelectionController = PalettePointerSelectionController()
    @FocusState private var searchFocused: Bool

    /// Smith-Waterman 排序兼顾单词边界与连续匹配，适合大项目逐键筛选。
    private static let fuzzyMatcher = FuzzyMatcher(config: .smithWaterman)
    private static let maxFileResults = 50
    /// 非 Git 目录回退扫描时跳过的构建产物与依赖目录。
    private static let excludedDirectoryNames: Set<String> = [
        ".git", "node_modules", "build", "dist", ".build", ".tmp_mit", "DerivedData",
    ]

    /// 窗口 / 材质半透明时，面板必须自带 within-window 模糊，否则只剩一层透色。
    private var needsMaterialBackdrop: Bool {
        settings.windowBackgroundOpacity < 1 || settings.visualEffectAlpha < 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The palette floats over the terminal surface, whose AppKit cursor
            // rect would otherwise show through as an I-beam across the whole
            // backdrop. Each region of the palette states its own pointer.
            Color.black.opacity(0.15)
                .onTapGesture { dismiss() }
                .pointerStyle(.default)

            panel
                .padding(.top, 110)
        }
        .ignoresSafeArea()
        .background(
            PalettePointerEventMonitor(controller: pointerSelectionController)
        )
        .onExitCommand { handleEscapeFromKeyboard() }
        .onDisappear { manager.restoreFocusAfterCommandPalette() }
        .task(id: fileIndexRoot) {
            projectFiles = []
            guard let root = fileIndexRoot else { return }
            let indexingTask = Task.detached(priority: .userInitiated) {
                Self.loadProjectFiles(in: root)
            }
            let files = await withTaskCancellationHandler {
                await indexingTask.value
            } onCancel: {
                indexingTask.cancel()
            }
            guard !Task.isCancelled, root == fileIndexRoot else { return }
            projectFiles = files
        }
    }

    // MARK: - Commands

    private var commands: [PaletteCommand] {
        var items: [PaletteCommand] = [
            PaletteCommand(id: "new-session", title: L10n.t("New Session"), systemImage: "terminal", shortcut: "⌘T") {
                manager.newSession()
            },
            PaletteCommand(
                id: "new-browser-tab",
                title: L10n.t("New Browser Tab"),
                systemImage: "globe"
            ) {
                manager.newBrowserTab()
            },
            PaletteCommand(
                id: "new-browser-pane",
                title: L10n.t("New Browser Pane"),
                systemImage: "globe"
            ) {
                manager.newBrowserPane()
            },
            PaletteCommand(id: "clear-terminal", title: L10n.t("Clear Terminal"), systemImage: "eraser", shortcut: "⌘K") {
                manager.clearActiveTerminal()
            },
            PaletteCommand(id: "split-right", title: L10n.t("Split Right"), systemImage: "rectangle.split.2x1", shortcut: "⌘D") {
                manager.splitRight()
            },
            PaletteCommand(id: "split-left", title: L10n.t("Split Left"), systemImage: "rectangle.split.2x1") {
                manager.splitLeft()
            },
            PaletteCommand(id: "split-down", title: L10n.t("Split Down"), systemImage: "rectangle.split.1x2", shortcut: "⇧⌘D") {
                manager.splitDown()
            },
            PaletteCommand(id: "split-up", title: L10n.t("Split Up"), systemImage: "rectangle.split.1x2") {
                manager.splitUp()
            },
            PaletteCommand(id: "focus-pane-left", title: L10n.t("Focus Pane Left"), systemImage: "arrow.left", shortcut: "⌥⌘←") {
                manager.focusPaneLeft()
            },
            PaletteCommand(id: "focus-pane-right", title: L10n.t("Focus Pane Right"), systemImage: "arrow.right", shortcut: "⌥⌘→") {
                manager.focusPaneRight()
            },
            PaletteCommand(id: "focus-pane-up", title: L10n.t("Focus Pane Up"), systemImage: "arrow.up", shortcut: "⌥⌘↑") {
                manager.focusPaneUp()
            },
            PaletteCommand(id: "focus-pane-down", title: L10n.t("Focus Pane Down"), systemImage: "arrow.down", shortcut: "⌥⌘↓") {
                manager.focusPaneDown()
            },
            PaletteCommand(id: "focus-prev-pane", title: L10n.t("Focus Previous Pane"), systemImage: "arrow.backward.square", shortcut: "⌘[") {
                manager.focusPreviousPane()
            },
            PaletteCommand(id: "focus-next-pane", title: L10n.t("Focus Next Pane"), systemImage: "arrow.forward.square", shortcut: "⌘]") {
                manager.focusNextPane()
            },
            PaletteCommand(id: "toggle-pane-zoom", title: L10n.t("Toggle Pane Zoom"), systemImage: "arrow.up.left.and.arrow.down.right", shortcut: "⇧⌘↩") {
                manager.togglePaneZoom()
            },
            PaletteCommand(id: "equalize-panes", title: L10n.t("Equalize Panes"), systemImage: "rectangle.split.3x1", shortcut: "⌃⌘=") {
                manager.equalizePanes()
            },
            PaletteCommand(id: "resize-pane-up", title: L10n.t("Resize Pane Up"), systemImage: "arrow.up.to.line", shortcut: "⌃⌘↑") {
                manager.resizePaneUp()
            },
            PaletteCommand(id: "resize-pane-down", title: L10n.t("Resize Pane Down"), systemImage: "arrow.down.to.line", shortcut: "⌃⌘↓") {
                manager.resizePaneDown()
            },
            PaletteCommand(id: "resize-pane-left", title: L10n.t("Resize Pane Left"), systemImage: "arrow.left.to.line", shortcut: "⌃⌘←") {
                manager.resizePaneLeft()
            },
            PaletteCommand(id: "resize-pane-right", title: L10n.t("Resize Pane Right"), systemImage: "arrow.right.to.line", shortcut: "⌃⌘→") {
                manager.resizePaneRight()
            },
            PaletteCommand(id: "new-project", title: L10n.t("New Project"), systemImage: "folder.badge.plus", shortcut: "⌘N") {
                manager.newProject()
            },
            PaletteCommand(id: "close-tab", title: L10n.t("Close Tab"), systemImage: "xmark.square", shortcut: "⌘W") {
                manager.closeSelectedTab()
            },
            PaletteCommand(id: "save-file", title: L10n.t("Save File"), systemImage: "square.and.arrow.down", shortcut: "⌘S") {
                manager.saveSelectedFile()
            },
            PaletteCommand(id: "toggle-left-sidebar", title: L10n.t("Toggle Left Sidebar"), systemImage: "sidebar.left", shortcut: "⌘B") {
                manager.toggleLeftSidebar()
            },
            PaletteCommand(id: "toggle-sidebar", title: L10n.t("Toggle Right Sidebar"), systemImage: "sidebar.right", shortcut: "⇧⌘B") {
                manager.toggleSidebar()
            },
            PaletteCommand(id: "toggle-files", title: L10n.t("Toggle Files Panel"), systemImage: "doc.text", shortcut: "⇧⌘E") {
                manager.togglePanel(.files)
            },
            PaletteCommand(id: "toggle-git", title: L10n.t("Toggle Git Panel"), systemImage: "arrow.triangle.branch", shortcut: "⇧⌘G") {
                manager.togglePanel(.git)
            },
            PaletteCommand(id: "toggle-project", title: L10n.t("Toggle Project Panel"), systemImage: "shippingbox", shortcut: nil) {
                manager.togglePanel(.project)
            },
            PaletteCommand(id: "toggle-info", title: L10n.t("Toggle Info Panel"), systemImage: "info.circle", shortcut: "⇧⌘I") {
                manager.togglePanel(.info)
            },
            PaletteCommand(id: "next-tab", title: L10n.t("Next Tab"), systemImage: "arrow.right", shortcut: "⇧⌘]") {
                manager.selectNextTab()
            },
            PaletteCommand(id: "prev-tab", title: L10n.t("Previous Tab"), systemImage: "arrow.left", shortcut: "⇧⌘[") {
                manager.selectPreviousTab()
            },
            PaletteCommand(id: "next-project", title: L10n.t("Next Project"), systemImage: "arrow.right.square", shortcut: "⌥⌘]") {
                manager.selectNextProject()
            },
            PaletteCommand(id: "prev-project", title: L10n.t("Previous Project"), systemImage: "arrow.left.square", shortcut: "⌥⌘[") {
                manager.selectPreviousProject()
            },
        ]

        if let project = manager.selectedProject {
            items.append(
                PaletteCommand(id: "close-project", title: L10n.format("Close Project: %@", project.name), systemImage: "folder.badge.minus") {
                    manager.closeProject(project)
                }
            )
            items.append(
                PaletteCommand(id: "delete-project", title: L10n.format("Delete Project: %@", project.name), systemImage: "trash") {
                    manager.deleteProject(project)
                }
            )
        }

        let visible = manager.visibleProjects
        for project in manager.projects where project.id != manager.selectedProjectID {
            let visibleIndex = visible.firstIndex(where: { $0.id == project.id })
            items.append(
                PaletteCommand(
                    id: "switch-project-\(project.id)",
                    title: "Switch to Project: \(project.name)",
                    systemImage: "folder",
                    shortcut: visibleIndex.flatMap { $0 < 9 ? "⌘\($0 + 1)" : nil }
                ) {
                    manager.revealProjectInSidebar(project)
                }
            )
        }

        items.append(
            PaletteCommand(id: "settings", title: L10n.t("Settings…"), systemImage: "gearshape", shortcut: "⌘,") {
                openWindow(id: "settings")
            }
        )
        return items
    }

    /// Every open terminal session across all projects, as a jump-to entry.
    /// The directory shows as a subtitle and the project name folds into the
    /// searchable text, so typing a repo or folder name finds its sessions.
    private var sessionCommands: [PaletteCommand] {
        manager.projects.flatMap { project in
            project.sessions.map { session in
                let directory = sessionDirectory(session)
                let search = [session.title, project.name, directory]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return PaletteCommand(
                    id: "session-\(session.id)",
                    title: session.title,
                    systemImage: "terminal",
                    subtitle: directory,
                    section: .session,
                    searchText: search
                ) {
                    manager.revealSession(session)
                }
            }
        }
    }

    /// Tilde-abbreviated working directory for a session's subtitle, or nil
    /// when the shell hasn't reported one yet.
    private func sessionDirectory(_ session: TerminalSession) -> String? {
        guard let dir = session.workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        guard !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    /// 当前项目用于文件快速打开的根目录；主目录属于账户边界，不进行整目录索引。
    private var fileIndexRoot: String? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let project = manager.selectedProject
        else { return nil }

        let root: String?
        if !project.projectDirectory.isEmpty,
           FileManager.default.fileExists(atPath: project.projectDirectory) {
            root = project.projectDirectory
        } else if let session = project.selectedSession {
            root = session.currentDirectoryPath
        } else {
            root = nil
        }
        guard let root, !root.isEmpty else { return nil }

        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        return standardizedRoot == home ? nil : root
    }

    private var filtered: [PaletteCommand] {
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return commands + sessionCommands }

        let fuzzyQuery = Self.fuzzyMatcher.prepare(pattern)
        var buffer = Self.fuzzyMatcher.makeBuffer()
        var items = matching(commands, fuzzyQuery, buffer: &buffer)
        items.append(contentsOf: matchingFiles(fuzzyQuery, buffer: &buffer))
        items.append(contentsOf: matching(sessionCommands, fuzzyQuery, buffer: &buffer))
        return items
    }

    /// 在单个分组内按匹配分数排序，分组本身仍维持命令、文件、会话的固定顺序。
    private func matching(
        _ commands: [PaletteCommand],
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> [PaletteCommand] {
        var matches: [(command: PaletteCommand, score: Double, order: Int)] = []
        matches.reserveCapacity(commands.count)
        for (order, command) in commands.enumerated() {
            guard let score = fuzzyScore(
                command.searchText ?? command.title,
                query,
                buffer: &buffer
            ) else { continue }
            matches.append((command, score, order))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.order < $1.order
        }
        return matches.map(\.command)
    }

    /// 扫描全部索引文件，但只为匹配最强的前 50 项创建界面条目。
    private func matchingFiles(
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> [PaletteCommand] {
        var best: [ScoredProjectFile] = []
        best.reserveCapacity(Self.maxFileResults)
        for file in projectFiles {
            guard let score = fileScore(file, query, buffer: &buffer) else {
                continue
            }
            let match = ScoredProjectFile(file: file, score: score)
            if best.count == Self.maxFileResults,
               let weakest = best.last,
               !ranksBefore(match, weakest) {
                continue
            }

            let index = insertionIndex(for: match, in: best)
            best.insert(match, at: index)
            if best.count > Self.maxFileResults {
                best.removeLast()
            }
        }
        return best.map { match in
            let file = match.file
            return PaletteCommand(
                id: "file-\(file.absolutePath)",
                title: file.name,
                systemImage: "doc",
                subtitle: file.parentPath,
                section: .file,
                searchText: file.relativePath
            ) {
                manager.openFile(file.absolutePath)
            }
        }
    }

    /// 文件名直接匹配总是优先于仅命中父目录的结果。
    private func fileScore(
        _ file: ProjectFile,
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        if let basenameScore = fuzzyScore(file.name, query, buffer: &buffer) {
            return 1 + basenameScore
        }
        return fuzzyScore(file.relativePath, query, buffer: &buffer)
    }

    private func insertionIndex(
        for match: ScoredProjectFile,
        in matches: [ScoredProjectFile]
    ) -> Int {
        var lowerBound = 0
        var upperBound = matches.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if ranksBefore(match, matches[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }

    private func ranksBefore(
        _ lhs: ScoredProjectFile,
        _ rhs: ScoredProjectFile
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.file.relativePath.localizedStandardCompare(rhs.file.relativePath)
            == .orderedAscending
    }

    /// 使用预处理查询和复用缓冲区，避免为索引中的每个文件重复分配临时对象。
    @inline(__always)
    private func fuzzyScore(
        _ candidate: String,
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        var candidate = candidate
        return candidate.withUTF8 { bytes in
            Self.fuzzyMatcher.score(
                utf8: bytes,
                against: query,
                buffer: &buffer
            )?.score
        }
    }

    /// 为项目文件名生成模糊匹配高亮范围。
    private func filenameMatchRanges(
        for command: PaletteCommand,
        query: FuzzyQuery
    ) -> [Range<String.Index>] {
        if let ranges = Self.fuzzyMatcher.highlight(command.title, against: query) {
            return ranges
        }
        guard let relativePath = command.searchText,
              relativePath.hasSuffix(command.title),
              let pathRanges = Self.fuzzyMatcher.highlight(relativePath, against: query)
        else { return [] }

        let filenameStart = relativePath.index(
            relativePath.endIndex,
            offsetBy: -command.title.count
        )
        return pathRanges.compactMap { pathRange in
            guard pathRange.upperBound > filenameStart else { return nil }
            let clippedLower = max(pathRange.lowerBound, filenameStart)
            let lowerOffset = relativePath.distance(from: filenameStart, to: clippedLower)
            let upperOffset = relativePath.distance(from: filenameStart, to: pathRange.upperBound)
            guard let lower = command.title.index(
                command.title.startIndex,
                offsetBy: lowerOffset,
                limitedBy: command.title.endIndex
            ),
            let upper = command.title.index(
                command.title.startIndex,
                offsetBy: upperOffset,
                limitedBy: command.title.endIndex
            ) else { return nil }
            return lower..<upper
        }
    }

    /// 仅为当前可见行构建富文本，避免对整个项目索引执行高亮回溯。
    private func attributedTitle(
        _ command: PaletteCommand,
        highlightQuery: FuzzyQuery?,
        isSelected: Bool
    ) -> AttributedString {
        var title = AttributedString(command.title)
        title.font = .system(size: 12.5)
        title.foregroundColor = isSelected ? .primary : .secondary
        guard command.section == .file,
              let highlightQuery
        else { return title }

        for range in filenameMatchRanges(for: command, query: highlightQuery) {
            guard let lower = AttributedString.Index(range.lowerBound, within: title),
                  let upper = AttributedString.Index(range.upperBound, within: title)
            else { continue }
            title[lower..<upper].font = .system(size: 12.5, weight: .semibold)
            title[lower..<upper].foregroundColor = Color(nsColor: Theme.cursor)
        }
        return title
    }

    // MARK: - Project file index

    /// Git 仓库优先使用 ignore-aware 索引，普通目录回退为过滤后的原生遍历。
    private nonisolated static func loadProjectFiles(in root: String) -> [ProjectFile] {
        if let paths = gitProjectFilePaths(in: root) {
            return projectFiles(for: paths, in: root)
        }
        return enumeratedProjectFiles(in: root)
    }

    private nonisolated static func gitProjectFilePaths(in root: String) -> Set<String>? {
        var tracked = GitStatusModel.runGit(
            ["ls-files", "--cached", "--recurse-submodules", "-z"],
            in: root
        )
        // 子模块缺失或损坏时仍应允许搜索仓库中的其他文件。
        if tracked.status != 0 {
            tracked = GitStatusModel.runGit(["ls-files", "--cached", "-z"], in: root)
        }
        let untracked = GitStatusModel.runGit(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            in: root
        )
        guard tracked.status == 0, untracked.status == 0 else { return nil }
        return Set(nulSeparatedPaths(tracked.stdout) + nulSeparatedPaths(untracked.stdout))
    }

    private nonisolated static func nulSeparatedPaths(_ output: String) -> [String] {
        output.split(separator: "\0").map(String.init)
    }

    private nonisolated static func projectFiles(
        for relativePaths: Set<String>,
        in root: String
    ) -> [ProjectFile] {
        let fileManager = FileManager.default
        return relativePaths.compactMap { relativePath in
            guard !Task.isCancelled else { return nil }
            let absolutePath = (root as NSString).appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return ProjectFile(
                name: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                absolutePath: absolutePath
            )
        }
        .sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private nonisolated static func enumeratedProjectFiles(in root: String) -> [ProjectFile] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let keySet = Set(keys)
        let rootPrefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [ProjectFile] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if Self.excludedDirectoryNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keySet) else {
                continue
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true,
                  url.path.hasPrefix(rootPrefix)
            else { continue }

            let relativePath = String(url.path.dropFirst(rootPrefix.count))
            files.append(
                ProjectFile(
                    name: url.lastPathComponent,
                    relativePath: relativePath,
                    absolutePath: url.path
                )
            )
        }
        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("Search commands, files, and sessions…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { handleEscapeFromKeyboard(); return .handled }
                    .onSubmit { runSelected() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            // The field itself only claims its text-height slice of the row,
            // so the rest of the 44pt search bar would fall back to the arrow.
            .contentShape(.rect)
            .pointerStyle(.horizontalText)

            Divider()
                .opacity(0.5)

            results
                .pointerStyle(.default)
        }
        .frame(width: 560)
        .background { panelBackground }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
        .onAppear {
            query = ""
            selection = 0
            pointerSelectionController.reset()
            // Defer to the next runloop tick: assigning focus synchronously
            // inside the appearance pass can be dropped before the field
            // editor is ready, which left the palette opening unfocused.
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: query) {
            selection = 0
            // 筛选结果可能在静止光标下重建，必须等待真实鼠标移动后才允许 hover 选中。
            pointerSelectionController.reset()
        }
    }

    /// 面板背景：`Theme.background` 已含窗口透明度。
    /// 半透明时若只有透色填充、没有材质，会直接透出终端且不模糊；
    /// 因此在透色下垫一层 `withinWindow` 毛玻璃（与主窗口 chrome 策略一致）。
    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            if needsMaterialBackdrop {
                VisualEffectView(
                    material: .popover,
                    blendingMode: .withinWindow,
                    state: .active,
                    // 不跟主窗口 effect-alpha 一起被压暗，保证面板自身仍可读。
                    alphaValue: 1
                )
            }
            shape.fill(Color(nsColor: Theme.background))
        }
        .clipShape(shape)
        .compositingGroup()
    }

    /// 每次渲染只计算一次结果；固定保留分组标题，避免异步文件索引完成后列表跳动。
    @ViewBuilder
    private var results: some View {
        let items = filtered
        let pattern = query.trimmingCharacters(in: .whitespaces)
        let highlightQuery = pattern.isEmpty ? nil : Self.fuzzyMatcher.prepare(pattern)
        if items.isEmpty {
            Text(L10n.t("No matches"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                            if index == 0 || items[index - 1].section != command.section {
                                sectionHeader(command.section, isFirst: index == 0)
                            }
                            row(
                                command,
                                index: index,
                                highlightQuery: highlightQuery
                            )
                                .id(command.id)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 322)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) {
                    if items.indices.contains(selection) {
                        proxy.scrollTo(items[selection].id)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: PaletteSection, isFirst: Bool) -> some View {
        Text(section.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, isFirst ? 4 : 10)
            .padding(.bottom, 3)
    }

    private func row(
        _ command: PaletteCommand,
        index: Int,
        highlightQuery: FuzzyQuery?
    ) -> some View {
        let isSelected = index == selection
        return Button {
            run(command)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.cursor)) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(
                    attributedTitle(
                        command,
                        highlightQuery: highlightQuery,
                        isSelected: isSelected
                    )
                )
                    .lineLimit(1)
                if let subtitle = command.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 12)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
        )
        .background(
            PaletteRowPointerView(
                onEntered: {
                    if pointerSelectionController.acceptsPointerSelection {
                        selection = index
                    }
                },
                onMoved: {
                    if pointerSelectionController.acceptsPointerSelection {
                        selection = index
                    }
                }
            )
        )
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func runSelected() {
        let items = filtered
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    private func run(_ command: PaletteCommand) {
        dismiss()
        command.action()
    }

    private func dismiss() {
        manager.dismissCommandPalette()
    }

    private func handleEscapeFromKeyboard() {
        if query.isEmpty {
            dismissFromKeyboard()
        } else {
            query = ""
        }
    }

    /// Escape reaches us as AppKit's `cancelOperation:`, which SwiftUI can
    /// dispatch inside a view-update pass — flipping the manager's published
    /// `isCommandPaletteVisible` there logs "Publishing changes from within
    /// view updates". Hop to the next runloop so the removal lands cleanly.
    /// (Return and backdrop taps arrive during normal event handling and can
    /// dismiss synchronously.)
    private func dismissFromKeyboard() {
        DispatchQueue.main.async { dismiss() }
    }
}

private struct PalettePointerEventMonitor: NSViewRepresentable {
    let controller: PalettePointerSelectionController

    func makeNSView(context: Context) -> PalettePointerMonitorNSView {
        let view = PalettePointerMonitorNSView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: PalettePointerMonitorNSView, context: Context) {
        nsView.controller = controller
    }

    static func dismantleNSView(
        _ nsView: PalettePointerMonitorNSView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
private final class PalettePointerMonitorNSView: NSView {
    weak var controller: PalettePointerSelectionController?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
            [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard window?.isKeyWindow == true else { return }
                self?.controller?.notePointerMoved()
            }
            return event
        }
    }

    func detach() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

/// 用 AppKit 区分真实移动和筛选重排时合成的 mouseEntered。
private struct PaletteRowPointerView: NSViewRepresentable {
    let onEntered: () -> Void
    let onMoved: () -> Void

    func makeNSView(context: Context) -> PaletteRowPointerNSView {
        let view = PaletteRowPointerNSView()
        view.onEntered = onEntered
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: PaletteRowPointerNSView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onMoved = onMoved
    }
}

private final class PaletteRowPointerNSView: NSView {
    var onEntered: (() -> Void)?
    var onMoved: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeInKeyWindow,
                    .inVisibleRect,
                ],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }

    override func mouseMoved(with event: NSEvent) {
        onMoved?()
    }
}
