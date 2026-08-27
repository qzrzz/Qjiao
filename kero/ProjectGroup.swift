//
//  ProjectGroup.swift
//  kero
//

import Combine
import Foundation

/// 侧栏项目分组。`current` / `archived` 是筛选 tab，不能当作归属写入项目；
/// `user` 是可归属的分组（默认「个人」「工作」，也可新建）。
enum ProjectGroupKind: String, Codable, Equatable, Sendable {
    case current
    case archived
    case user
}

/// 左侧边栏底部的一个项目分组 tab。
struct ProjectGroup: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var kind: ProjectGroupKind
    var name: String
    var systemImage: String

    static let currentID = "current"
    static let archivedID = "archived"
    static let personalID = "personal"
    static let workID = "work"

    static let current = ProjectGroup(
        id: currentID,
        kind: .current,
        name: "Current",
        systemImage: "square.stack"
    )
    static let archived = ProjectGroup(
        id: archivedID,
        kind: .archived,
        name: "Archived",
        systemImage: "archivebox"
    )

    static func defaultPersonal() -> ProjectGroup {
        ProjectGroup(
            id: personalID,
            kind: .user,
            name: "Personal",
            systemImage: "person"
        )
    }

    static func defaultWork() -> ProjectGroup {
        ProjectGroup(
            id: workID,
            kind: .user,
            name: "Work",
            systemImage: "briefcase"
        )
    }

    static func untitledUserGroup() -> ProjectGroup {
        ProjectGroup(
            id: UUID().uuidString,
            kind: .user,
            name: L10n.t("New Group"),
            systemImage: "folder"
        )
    }

    /// 内置筛选 tab，不能删除、不能作为项目的 `groupID`。
    var isFilter: Bool {
        kind == .current || kind == .archived
    }

    var isRenamable: Bool { kind == .user }

    /// 默认的个人 / 工作保留，避免空 tab 栏；用户自建分组可删。
    var isDeletable: Bool {
        kind == .user && id != Self.personalID && id != Self.workID
    }

    var displayName: String {
        switch kind {
        case .current:
            return L10n.t("Current")
        case .archived:
            return L10n.t("Archived")
        case .user:
            if id == Self.personalID, name == "Personal" {
                return L10n.t("Personal")
            }
            if id == Self.workID, name == "Work" {
                return L10n.t("Work")
            }
            return name
        }
    }
}

/// 用户分组列表与当前选中 tab。落在 `~/.config/qjiao/project-groups.json`。
@MainActor
final class ProjectGroupStore: ObservableObject {
    static let shared = ProjectGroupStore()

    @Published var userGroups: [ProjectGroup]
    @Published var selectedID: String {
        didSet {
            guard selectedID != oldValue else { return }
            persist()
        }
    }

    /// 侧栏 tab 顺序：个人 / 工作 / 自建分组… / 当前 / 已归档。
    var tabs: [ProjectGroup] {
        userGroups + [.current, .archived]
    }

    var selectedGroup: ProjectGroup {
        tabs.first { $0.id == selectedID } ?? .current
    }

    private init() {
        let loaded = Self.loadFile()
        if let loaded, !loaded.userGroups.isEmpty {
            let groups = Self.normalized(loaded.userGroups)
            userGroups = groups
            let ids = Set(groups.map(\.id) + [ProjectGroup.currentID, ProjectGroup.archivedID])
            if let selected = loaded.selectedID, ids.contains(selected) {
                selectedID = selected
            } else {
                selectedID = ProjectGroup.currentID
            }
        } else {
            userGroups = Self.defaultUserGroups
            selectedID = ProjectGroup.currentID
            persist()
        }
    }

    static var fileURL: URL {
        AppSettings.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("project-groups.json")
    }

    private static let defaultUserGroups: [ProjectGroup] = [
        .defaultPersonal(),
        .defaultWork()
    ]

    func group(id: String) -> ProjectGroup? {
        tabs.first { $0.id == id }
    }

    func addGroup() -> ProjectGroup {
        let group = ProjectGroup.untitledUserGroup()
        userGroups.append(group)
        selectedID = group.id
        persist()
        objectWillChange.send()
        return group
    }

    func renameGroup(id: String, to rawName: String) {
        guard let index = userGroups.firstIndex(where: { $0.id == id }),
              userGroups[index].isRenamable
        else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = userGroups[index]
        guard !trimmed.isEmpty, trimmed != current.name, trimmed != current.displayName else { return }
        userGroups[index].name = trimmed
        persist()
        objectWillChange.send()
    }

    /// 删除自建分组。调用方负责把仍挂在该分组下的项目改为未分组。
    @discardableResult
    func deleteGroup(id: String) -> Bool {
        guard let index = userGroups.firstIndex(where: { $0.id == id }),
              userGroups[index].isDeletable
        else { return false }
        userGroups.remove(at: index)
        if selectedID == id {
            selectedID = ProjectGroup.currentID
        }
        persist()
        objectWillChange.send()
        return true
    }

    private struct FilePayload: Codable {
        var userGroups: [ProjectGroup]
        var selectedID: String?
    }

    private static func loadFile() -> FilePayload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(FilePayload.self, from: data)
    }

    private static func normalized(_ groups: [ProjectGroup]) -> [ProjectGroup] {
        var byID: [String: ProjectGroup] = [:]
        var order: [String] = []
        for group in groups where group.kind == .user {
            if byID[group.id] == nil {
                order.append(group.id)
            }
            byID[group.id] = group
        }
        var result: [ProjectGroup] = [
            byID[ProjectGroup.personalID] ?? .defaultPersonal(),
            byID[ProjectGroup.workID] ?? .defaultWork()
        ]
        for id in order where id != ProjectGroup.personalID && id != ProjectGroup.workID {
            if let group = byID[id] {
                result.append(group)
            }
        }
        return result
    }

    private func persist() {
        let payload = FilePayload(userGroups: userGroups, selectedID: selectedID)
        do {
            let dir = Self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("qjiao: failed to save project groups: \(error)")
        }
    }
}
