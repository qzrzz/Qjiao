//
//  SessionStore.swift
//  kero
//

import AppKit
import Foundation

/// 项目名称、图标和描述的独立配置内容，和会话布局分开保存。
struct ProjectConfig: Codable {
    var customName: String? = nil
    /// 可选，是否使用自动标题。
    var useAutoTitle: Bool? = nil
    var description: String? = nil
    var icon: ProjectIcon? = nil
    /// 可选，兼容未设置项目级主题的旧项目配置。
    var theme: ProjectTheme? = nil
    /// 可选，兼容添加项目目录字段前创建的配置文件。
    var projectDirectory: String? = nil
    /// Optional so project configuration written before Start existed keeps
    /// decoding without migration.
    var launchCommands: [ProjectLaunchCommand]? = nil
    /// 可选，记录项目是否已被归档。
    var isArchived: Bool? = nil
    /// 可选 AI 写作语言覆盖（`AIWritingLanguage.rawValue`）；nil 表示跟随全局设置。
    var aiWritingLanguage: String? = nil
}

/// 项目配置目录存储。
///
/// 布局（每个项目一个文件夹，关闭项目时可整目录删除）：
/// ```
/// ~/.config/qjiao/projects/{projectId}/
///   config.json   # 名称 / 图标 / 描述 / 主题 / Launchers / 归档…
///   icon.{ext}    # 用户自定义图标托管副本
///   note.txt      # 项目笔记
/// ```
/// Debug 构建根目录为 `qjiao-dev`。
///
/// 兼容旧布局并在首次读写时迁移：
/// - `projects/{id}.json`
/// - `projects/icons/{id}.{ext}`
/// - `notes/{id}.txt`
@MainActor
enum ProjectConfigStore {
    /// 所有项目配置根目录：`…/projects/`。
    static var projectsRootURL: URL {
        AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// 旧版扁平图标目录（仅迁移 / 清理用）。
    static var legacyIconsDirectoryURL: URL {
        projectsRootURL.appendingPathComponent("icons", isDirectory: true)
    }

    /// 旧版笔记根目录（仅迁移 / 清理用）。
    static var legacyNotesDirectoryURL: URL {
        AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("notes", isDirectory: true)
    }

    /// 单个项目的数据目录：`projects/{id}/`。
    static func projectDirectoryURL(for id: UUID) -> URL {
        projectsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// 项目主配置文件：`projects/{id}/config.json`。
    static func configFileURL(for id: UUID) -> URL {
        projectDirectoryURL(for: id).appendingPathComponent("config.json")
    }

    /// 项目笔记文件：`projects/{id}/note.txt`。
    static func noteFileURL(for id: UUID) -> URL {
        projectDirectoryURL(for: id).appendingPathComponent("note.txt")
    }

    /// 读取项目配置；必要时从旧路径迁移后再读。
    static func load(for id: UUID) -> ProjectConfig? {
        migrateIfNeeded(for: id)
        let url = configFileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectConfig.self, from: data)
    }

    /// 将项目配置原子写入 `projects/{id}/config.json`。
    static func save(_ config: ProjectConfig, for id: UUID) {
        do {
            let dir = projectDirectoryURL(for: id)
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            // 若仍有旧布局数据，先迁入本目录再写，避免丢旁路文件。
            migrateIfNeeded(for: id)
            let data = try JSONEncoder().encode(config)
            try data.write(to: configFileURL(for: id), options: .atomic)
            // 旧扁平 JSON 已迁出后删除，避免双份。
            removeLegacyFlatConfig(for: id)
        } catch {
            NSLog("qjiao: failed to save project config \(id): \(error)")
        }
    }

    /// 删除整个项目数据目录（配置 / 图标 / 笔记），并清理旧路径残留。
    static func removeAllData(for id: UUID) {
        let fm = FileManager.default
        let dir = projectDirectoryURL(for: id)
        if fm.fileExists(atPath: dir.path) {
            do {
                try fm.removeItem(at: dir)
            } catch {
                NSLog("qjiao: failed to remove project directory \(dir.path): \(error)")
            }
        }
        removeLegacyFlatConfig(for: id)
        ProjectIconFileStore.removeLegacyIcons(for: id)
        removeLegacyNote(for: id)
    }

    // MARK: - Migration

    /// 将旧布局的配置 / 图标 / 笔记迁入 `projects/{id}/`。
    private static func migrateIfNeeded(for id: UUID) {
        let fm = FileManager.default
        let dir = projectDirectoryURL(for: id)
        let newConfig = configFileURL(for: id)
        let legacyConfig = projectsRootURL.appendingPathComponent("\(id.uuidString).json")

        var config: ProjectConfig?
        var didMigrateConfig = false

        if fm.fileExists(atPath: newConfig.path) {
            if let data = try? Data(contentsOf: newConfig) {
                config = try? JSONDecoder().decode(ProjectConfig.self, from: data)
            }
        } else if fm.fileExists(atPath: legacyConfig.path),
                  let data = try? Data(contentsOf: legacyConfig),
                  let decoded = try? JSONDecoder().decode(ProjectConfig.self, from: data) {
            config = decoded
            didMigrateConfig = true
        }

        // 迁移自定义图标：旧 `projects/icons/{id}.*` → `projects/{id}/icon.*`
        let migratedIconURL = migrateLegacyIcon(for: id)
        if let migratedIconURL {
            // 即使原先没有 config.json（仅有图标），也要落一份配置指向新路径。
            if config == nil {
                config = ProjectConfig(
                    customName: nil,
                    description: nil,
                    icon: .file(migratedIconURL.path),
                    theme: nil,
                    projectDirectory: nil,
                    launchCommands: nil,
                    isArchived: nil
                )
            } else {
                config?.icon = .file(migratedIconURL.path)
            }
            didMigrateConfig = true
        } else if case .file(let path)? = config?.icon,
                  ProjectIconFileStore.isLegacyManagedPath(path),
                  let found = ProjectIconFileStore.existingIconURL(for: id) {
            // 配置仍指向旧 icons 路径，但文件可能已在新目录。
            config?.icon = .file(found.path)
            didMigrateConfig = true
        }

        // 迁移笔记：旧 `notes/{id}.txt` → `projects/{id}/note.txt`
        migrateLegacyNote(for: id)

        guard didMigrateConfig, let config else { return }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: newConfig, options: .atomic)
            removeLegacyFlatConfig(for: id)
        } catch {
            NSLog("qjiao: failed to migrate project config \(id): \(error)")
        }
    }

    /// 旧版 `projects/{id}.json` → 删除（内容已写入新路径）。
    private static func removeLegacyFlatConfig(for id: UUID) {
        let legacy = projectsRootURL.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: legacy)
    }

    /// 旧版 `projects/icons/{id}.*` 迁到 `projects/{id}/icon.*`，返回新路径。
    private static func migrateLegacyIcon(for id: UUID) -> URL? {
        // 新路径已有图标则不再从旧目录搬。
        if ProjectIconFileStore.existingIconURL(for: id) != nil {
            ProjectIconFileStore.removeLegacyIcons(for: id)
            return nil
        }
        let fm = FileManager.default
        let legacyDir = legacyIconsDirectoryURL
        guard let files = try? fm.contentsOfDirectory(atPath: legacyDir.path) else { return nil }
        let prefix = id.uuidString.lowercased()
        guard let name = files.first(where: { $0.lowercased().hasPrefix(prefix) }) else {
            return nil
        }
        let source = legacyDir.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension
        let destName = ext.isEmpty ? "icon" : "icon.\(ext)"
        let destDir = projectDirectoryURL(for: id)
        let dest = destDir.appendingPathComponent(destName)
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: source, to: dest)
            // 清掉同 id 其它扩展名残留。
            ProjectIconFileStore.removeLegacyIcons(for: id)
            return dest
        } catch {
            NSLog("qjiao: failed to migrate project icon \(id): \(error)")
            return nil
        }
    }

    /// 旧版 `notes/{id}.txt` → `projects/{id}/note.txt`。
    private static func migrateLegacyNote(for id: UUID) {
        let fm = FileManager.default
        let dest = noteFileURL(for: id)
        if fm.fileExists(atPath: dest.path) {
            removeLegacyNote(for: id)
            return
        }
        let legacy = legacyNotesDirectoryURL
            .appendingPathComponent("\(id.uuidString).txt")
        guard fm.fileExists(atPath: legacy.path) else { return }
        do {
            try fm.createDirectory(
                at: projectDirectoryURL(for: id), withIntermediateDirectories: true
            )
            try fm.moveItem(at: legacy, to: dest)
        } catch {
            NSLog("qjiao: failed to migrate project note \(id): \(error)")
        }
    }

    private static func removeLegacyNote(for id: UUID) {
        let legacy = legacyNotesDirectoryURL
            .appendingPathComponent("\(id.uuidString).txt")
        try? FileManager.default.removeItem(at: legacy)
    }
}

/// 将用户选择的图片复制到项目配置目录，保证重启后仍可加载（不依赖原路径）。
@MainActor
enum ProjectIconFileStore {
    private static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff",
        "icns", "ico", "bmp", "heic", "heif", "svg",
    ]

    /// 导入图片为项目托管图标（`projects/{id}/icon.{ext}`），返回绝对路径；失败返回 nil。
    static func importImage(from sourceURL: URL, projectID: UUID) -> URL? {
        let fm = FileManager.default
        let ext = sourceURL.pathExtension.lowercased()
        // 允许常见扩展名；无扩展名或未知扩展名但可识别图像时按 png 托管。
        let resolvedExt: String
        if ext.isEmpty {
            resolvedExt = "png"
        } else if allowedExtensions.contains(ext) {
            resolvedExt = ext
        } else if NSImage(contentsOf: sourceURL) != nil {
            resolvedExt = "png"
        } else {
            return nil
        }
        do {
            let dir = ProjectConfigStore.projectDirectoryURL(for: projectID)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // 先清掉该项目旧托管文件（可能扩展名不同，含旧 icons 布局）。
            removeManagedIcons(for: projectID)
            let dest = dir.appendingPathComponent("icon.\(resolvedExt)")
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: sourceURL, to: dest)
            return dest
        } catch {
            NSLog("qjiao: failed to import project icon: \(error)")
            return nil
        }
    }

    /// 删除该项目配置目录下托管的自定义图标文件（不删 config / note）。
    static func removeManagedIcons(for projectID: UUID) {
        let fm = FileManager.default
        let dir = ProjectConfigStore.projectDirectoryURL(for: projectID)
        if let files = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in files where name.lowercased().hasPrefix("icon.") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        removeLegacyIcons(for: projectID)
    }

    /// 查找已存在的托管图标路径（新布局 `icon.*`）。
    static func existingIconURL(for projectID: UUID) -> URL? {
        let dir = ProjectConfigStore.projectDirectoryURL(for: projectID)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }
        guard let name = files.first(where: { $0.lowercased().hasPrefix("icon.") }) else {
            return nil
        }
        return dir.appendingPathComponent(name)
    }

    /// 删除旧布局 `projects/icons/{id}.*`。
    static func removeLegacyIcons(for projectID: UUID) {
        let fm = FileManager.default
        let dir = ProjectConfigStore.legacyIconsDirectoryURL
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let prefix = projectID.uuidString.lowercased()
        for name in files where name.lowercased().hasPrefix(prefix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 路径是否为当前托管布局下的项目图标（`…/projects/{id}/icon.*`）。
    static func isManagedPath(_ path: String) -> Bool {
        let root = ProjectConfigStore.projectsRootURL.standardizedFileURL.path
        let standardized = path.standardizedFilePath
        guard standardized.hasPrefix(root + "/") else {
            return isLegacyManagedPath(path)
        }
        let fileName = (standardized as NSString).lastPathComponent.lowercased()
        return fileName.hasPrefix("icon.")
    }

    /// 路径是否位于旧版 `projects/icons/` 下。
    static func isLegacyManagedPath(_ path: String) -> Bool {
        let icons = ProjectConfigStore.legacyIconsDirectoryURL.standardizedFileURL.path
        return path.standardizedFilePath.hasPrefix(icons)
    }
}

private extension String {
    /// 展开 ~ 并标准化，便于路径前缀比较。
    var standardizedFilePath: String {
        let expanded = (self as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

/// Snapshot of open projects and tabs, saved so a relaunch restores the
/// previous layout. Terminal sessions restore as fresh shells started in
/// their last known working directory — with their previous scrollback
/// replayed above the prompt when the "Restore session history" setting is on
/// (see `historyKey` and `TerminalHistoryStore`); file and diff panes reload
/// from disk.
struct SessionSnapshot: Codable {
    struct ProjectSnapshot: Codable {
        /// A single pane's content — the terminal/file/diff it holds. The case
        /// shapes match the pre-split format exactly, so old saved tabs (which
        /// were one of these directly) still decode; see `TabSnapshot`.
        enum PaneContentSnapshot: Codable {
            case session(workingDirectory: String)
            case file(path: String, editorState: EditorState?)
            case diff(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?)
        }

        struct PaneSnapshot: Codable {
            var content: PaneContentSnapshot
            var weight: Double
            /// Key into the sidecar terminal-history store for a session pane;
            /// nil for files, diffs, or when history restore is off. Optional so
            /// snapshots written before this feature still decode.
            var historyKey: String?
        }

        struct ColumnSnapshot: Codable {
            var panes: [PaneSnapshot]
            var weight: Double
        }

        /// One tab's niri layout: a row of columns plus the focused pane's
        /// position. Decodes the pre-split format too — where a tab *was* a
        /// single content enum — by wrapping it in a one-pane layout.
        struct TabSnapshot: Codable {
            var columns: [ColumnSnapshot]
            var focusedColumn: Int
            var focusedRow: Int
            var customName: String?

            init(
                columns: [ColumnSnapshot], focusedColumn: Int, focusedRow: Int,
                customName: String? = nil
            ) {
                self.columns = columns
                self.focusedColumn = focusedColumn
                self.focusedRow = focusedRow
                self.customName = customName
            }

            enum CodingKeys: String, CodingKey {
                case columns, focusedColumn, focusedRow, customName
            }

            init(from decoder: any Decoder) throws {
                if let container = try? decoder.container(keyedBy: CodingKeys.self),
                   let columns = try? container.decode([ColumnSnapshot].self, forKey: .columns) {
                    self.columns = columns
                    focusedColumn = (try? container.decode(Int.self, forKey: .focusedColumn)) ?? 0
                    focusedRow = (try? container.decode(Int.self, forKey: .focusedRow)) ?? 0
                    customName = try? container.decode(String.self, forKey: .customName)
                    return
                }
                // Legacy: the tab was a single content enum. Wrap it in a
                // one-column, one-pane layout.
                let content = try PaneContentSnapshot(from: decoder)
                columns = [ColumnSnapshot(panes: [PaneSnapshot(content: content, weight: 1)], weight: 1)]
                focusedColumn = 0
                focusedRow = 0
                customName = nil
            }
        }

        /// 项目稳定 ID；旧版快照没有此字段，恢复时会生成新的 ID。
        var id: UUID?
        var customName: String?
        /// 可选，是否使用自动标题。
        var useAutoTitle: Bool?
        /// 可选，确保升级前保存的会话仍能正常恢复。
        var description: String?
        /// 可选，确保升级前保存的会话仍能正常恢复。
        var icon: ProjectIcon?
        /// Optional so snapshots written before project themes existed decode.
        var theme: ProjectTheme?
        /// 项目目录由独立配置文件保存；该字段仅用于旧快照兼容。
        var projectDirectory: String?
        /// 可选，记录项目是否已被归档。
        var isArchived: Bool?
        var tabs: [TabSnapshot]
        var selectedTabIndex: Int?
    }

    var projects: [ProjectSnapshot]
    var selectedProjectIndex: Int?
    /// Optional so snapshots written before sidebar persistence still decode.
    var isLeftSidebarVisible: Bool?
    var isRightPanelVisible: Bool?
    var rightPanelTab: RightPanel?
}

/// Persisted top level: one `SessionSnapshot` per open window, in
/// window-creation order.
private struct AppSnapshot: Codable {
    var windows: [SessionSnapshot]
}

enum SessionStore {
    private static let key = "sessionSnapshot"

    static func save(_ windows: [SessionSnapshot]) {
        guard let data = try? JSONEncoder().encode(AppSnapshot(windows: windows)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [SessionSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let app = try? JSONDecoder().decode(AppSnapshot.self, from: data) {
            return app.windows
        }
        // Pre-multi-window format: the snapshot of a single window.
        if let single = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            return [single]
        }
        return []
    }
}
