//
//  NoteStore.swift
//  kero
//

import Combine
import Foundation

/// 按项目持久化的纯文本笔记，落在项目配置目录 `projects/{projectId}/note.txt`。
/// 与 `ProjectConfig` JSON 分离，避免大段笔记反复编解码配置；关闭项目时随目录一并删除。
@MainActor
enum NoteStore {
    /// 读取项目笔记；无文件时返回空字符串。会触发旧路径迁移。
    static func load(for id: UUID) -> String {
        // 借 ProjectConfigStore 的迁移逻辑把 `notes/{id}.txt` 搬进项目目录。
        _ = ProjectConfigStore.load(for: id)
        let url = ProjectConfigStore.noteFileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 原子写入项目笔记。空内容时删除文件，避免残留空笔记。
    static func save(_ text: String, for id: UUID) {
        let url = ProjectConfigStore.noteFileURL(for: id)
        do {
            if text.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            try FileManager.default.createDirectory(
                at: ProjectConfigStore.projectDirectoryURL(for: id),
                withIntermediateDirectories: true
            )
            guard let data = text.data(using: .utf8) else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("qjiao: failed to save note \(id): \(error)")
        }
    }
}

/// 右侧 Note 面板的编辑状态：绑定当前项目、防抖落盘、切换项目时先刷盘再加载。
@MainActor
final class NoteModel: ObservableObject {
    /// 编辑器当前文本；空项目时保持空串且不可编辑由视图层处理。
    @Published var text: String = ""

    /// 当前绑定的项目；nil 表示无选中项目。
    private(set) var projectID: UUID?

    /// 防抖写盘，避免每个按键都触盘。
    private var saveWorkItem: DispatchWorkItem?
    private static let saveDelay: TimeInterval = 0.4

    /// 切换到指定项目的笔记。会先把未落盘内容刷到旧项目。
    func bind(to projectID: UUID?) {
        guard projectID != self.projectID else { return }
        flush()
        self.projectID = projectID
        if let projectID {
            text = NoteStore.load(for: projectID)
        } else {
            text = ""
        }
    }

    /// 文本变更入口：更新状态并安排防抖保存。
    func updateText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        scheduleSave()
    }

    /// 立即把当前文本写入磁盘（切换项目 / 收起面板时调用）。
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard let projectID else { return }
        NoteStore.save(text, for: projectID)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    deinit {
        // 析构路径不保证在 MainActor；取消待办即可，最后一次内容已由 flush 覆盖或即将丢弃。
        saveWorkItem?.cancel()
    }
}
