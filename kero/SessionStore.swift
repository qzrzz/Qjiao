//
//  SessionStore.swift
//  kero
//

import Foundation

/// 项目名称、图标和描述的独立配置内容，和会话布局分开保存。
struct ProjectConfig: Codable {
    var customName: String?
    var description: String?
    var icon: ProjectIcon?
    /// 可选，兼容未设置项目级主题的旧项目配置。
    var theme: ProjectTheme?
    /// 可选，兼容添加项目目录字段前创建的配置文件。
    var projectDirectory: String?
    /// Optional so project configuration written before Start existed keeps
    /// decoding without migration.
    var launchCommands: [ProjectLaunchCommand]?
    /// 可选，记录项目是否已被归档。
    var isArchived: Bool?
}

/// 项目配置文件存储。每个项目使用稳定 UUID 对应一个 JSON 文件。
@MainActor
enum ProjectConfigStore {
    private static var directoryURL: URL {
        AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// 用户项目图标托管目录：`…/projects/icons/{projectId}.{ext}`。
    static var iconsDirectoryURL: URL {
        directoryURL.appendingPathComponent("icons", isDirectory: true)
    }

    static func load(for id: UUID) -> ProjectConfig? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectConfig.self, from: data)
    }

    static func save(_ config: ProjectConfig, for id: UUID) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(config)
            try data.write(to: fileURL(for: id), options: .atomic)
        } catch {
            NSLog("qjiao: failed to save project config \(id): \(error)")
        }
    }

    private static func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }
}

/// 将用户选择的图片复制到配置目录，保证重启后仍可加载（不依赖原路径）。
@MainActor
enum ProjectIconFileStore {
    private static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff",
        "icns", "ico", "bmp", "heic", "heif", "svg",
    ]

    /// 导入图片为项目托管图标，返回绝对路径；失败返回 nil。
    static func importImage(from sourceURL: URL, projectID: UUID) -> URL? {
        let fm = FileManager.default
        let ext = sourceURL.pathExtension.lowercased()
        // 允许常见扩展名；无扩展名时按 png 托管。
        let resolvedExt: String
        if ext.isEmpty {
            resolvedExt = "png"
        } else if allowedExtensions.contains(ext) {
            resolvedExt = ext
        } else {
            return nil
        }
        do {
            try fm.createDirectory(
                at: ProjectConfigStore.iconsDirectoryURL,
                withIntermediateDirectories: true
            )
            // 先清掉该项目旧托管文件（可能扩展名不同）。
            removeManagedIcons(for: projectID)
            let dest = ProjectConfigStore.iconsDirectoryURL
                .appendingPathComponent("\(projectID.uuidString).\(resolvedExt)")
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

    /// 删除该项目配置目录下托管的自定义图标文件。
    static func removeManagedIcons(for projectID: UUID) {
        let fm = FileManager.default
        let dir = ProjectConfigStore.iconsDirectoryURL
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let prefix = projectID.uuidString.lowercased()
        for name in files where name.lowercased().hasPrefix(prefix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 路径是否位于托管图标目录内。
    static func isManagedPath(_ path: String) -> Bool {
        let icons = ProjectConfigStore.iconsDirectoryURL.standardizedFileURL.path
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
