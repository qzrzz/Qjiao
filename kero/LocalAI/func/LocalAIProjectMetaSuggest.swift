//
//  LocalAIProjectMetaSuggest.swift
//  kero
//
//  使用 LocalAI 为项目一次生成：显示名称、描述、图标（Material / SF / Emoji）。
//  与 LocalAIIconSuggest 并列的独立功能；上下文与 Material 列表复用其工具方法。
//

import AppKit
import Combine
import Foundation

// MARK: - 结果

/// AI 生成的项目元数据（名称 / 描述 / 图标）。
struct LocalAIProjectMetaSuggestion: Sendable, Equatable {
    /// 项目显示名（将写入 `customName`）。
    var name: String
    /// 项目描述（空字符串表示清空描述）。
    var description: String
    /// 解析后的图标；解析失败时为 nil（仍应用 name/description）。
    var icon: ProjectIcon?
    /// 图标原始 type / value（调试用）。
    var iconRawType: String?
    var iconRawValue: String?
}

// MARK: - 主入口

/// 通过 LocalAI 根据项目上下文生成名称、描述与图标。
enum LocalAIProjectMetaSuggest {
    /// 默认超时：比单纯选图标略长。
    static let defaultTimeout: Duration = .seconds(120)

    /// 请求 AI 生成元数据；需已启用 headless provider。
    @MainActor
    static func suggest(for project: Project) async throws -> LocalAIProjectMetaSuggestion {
        guard LocalAI.isEnabled else {
            throw LocalAIError.disabled
        }

        let currentName = project.name
        let currentDescription = project.description
        let directory = project.projectDirectory

        let projectCtx = await Task.detached(priority: .userInitiated) {
            // 复用图标功能的上下文采集（name / path / package.json / README）
            LocalAIIconSuggest.buildProjectContext(
                name: currentName,
                description: currentDescription,
                directory: directory
            )
        }.value

        let iconsText = await Task.detached(priority: .userInitiated) {
            LocalAIIconSuggest.buildBuiltinIconsList()
        }.value

        try Task.checkCancellation()

        let prompt = buildPrompt(icons: iconsText, projectCtx: projectCtx)
        print(
            """
            [LocalAIProjectMetaSuggest] ——— prompt begin ———
            project: \(currentName)
            directory: \(directory)
            provider: \(LocalAI.selectedProvider.displayName)
            icons chars: \(iconsText.count)  prompt chars: \(prompt.count)
            \(prompt)
            [LocalAIProjectMetaSuggest] ——— prompt end ———
            """
        )

        let response = try await LocalAI.prompt(
            LocalAIRequest(
                prompt: prompt,
                workingDirectory: directory.isEmpty ? nil : directory,
                timeout: defaultTimeout,
                autoApprove: false
            )
        )

        print(
            """
            [LocalAIProjectMetaSuggest] ——— response begin ———
            provider: \(response.provider.displayName)
            exitCode: \(response.exitCode)
            executable: \(response.executablePath)
            text:
            \(response.text)
            stderr:
            \(response.rawStderr)
            [LocalAIProjectMetaSuggest] ——— response end ———
            """
        )

        try Task.checkCancellation()

        let raw = try parseMetaJSON(from: response.text)
        let name = sanitizeName(raw.name)
        guard !name.isEmpty else {
            throw LocalAIProjectMetaSuggestError.emptyName
        }
        let description = sanitizeDescription(raw.description)

        var icon: ProjectIcon?
        var iconType: String?
        var iconValue: String?
        if let t = raw.iconType, let v = raw.iconValue, !t.isEmpty, !v.isEmpty {
            iconType = t
            iconValue = v
            do {
                icon = try LocalAIIconSuggest.resolveIcon(type: t, value: v)
            } catch {
                // 名称/描述仍可用；图标解析失败时打日志并跳过
                print(
                    "[LocalAIProjectMetaSuggest] icon resolve failed type=\(t) value=\(v): \(error.localizedDescription)"
                )
            }
        }

        print(
            "[LocalAIProjectMetaSuggest] parsed name=\(name) description=\(description) icon=\(String(describing: icon))"
        )

        return LocalAIProjectMetaSuggestion(
            name: name,
            description: description,
            icon: icon,
            iconRawType: iconType,
            iconRawValue: iconValue
        )
    }

    /// 生成并写入项目：customName / description / icon。
    @MainActor
    static func apply(to project: Project) async throws -> LocalAIProjectMetaSuggestion {
        let suggestion = try await suggest(for: project)

        project.customName = suggestion.name
        project.description = suggestion.description.isEmpty ? nil : suggestion.description

        if let icon = suggestion.icon {
            if case .file = project.icon {
                ProjectIconFileStore.removeManagedIcons(for: project.id)
            }
            ProjectIconThumbnailCache.clearCache()
            project.objectWillChange.send()
            project.icon = icon
        } else {
            // 仅名称/描述变更时也落盘
            project.saveConfig()
        }

        return suggestion
    }

    // MARK: - Prompt

    /// 名称 + 描述 + 图标 联合提示词（Material 列表仅作 icon 候选）。
    static func buildPrompt(icons: String, projectCtx: String) -> String {
        """
        你需要为 macOS 终端工作区中的一个项目设置：显示名称、简短描述、图标。

        ## 输出字段

        1. **name**（必填）
           - 项目在侧边栏显示的标题。
           - 简洁、可读；中文或英文均可；建议 2–40 个字符。
           - 不要包含路径、引号、emoji（emoji 放在 icon 里）。
           - 优先采用 package.json name 的可读形式，或 README / 文件夹名提炼。

        2. **description**（必填字段，内容可为空字符串）
           - 一句话说明项目用途或技术栈。
           - 建议不超过 80 个字符；没有把握时用空字符串 `""`。

        3. **icon**（必填对象）
           - 选择优先级必须严格遵守：
             1) Material 内置 icon（最高）：`type` 为 `"icon"`，`value` 必须是下方列表中的**精确逻辑名**。
             2) SF Symbol（中）：仅当没有合适 Material 时，`type` 为 `"sf"`。
             3) Emoji（最低）：仅当前两者都不合适时，`type` 为 `"emoji"`。
           - 不要编造 Material 列表中不存在的名字。

        ## Material 内置 icon 列表（icon.type=icon 时 value 必须来自本列表）

        ```text
        \(icons)
        ```

        ## 项目上下文

        ```text
        \(projectCtx)
        ```

        ## 输出要求

        仅返回一个 JSON，不要输出 Markdown，不要添加解释。

        ```json
        {
          "name": "项目显示名",
          "description": "一句话描述",
          "icon": {
            "type": "icon | sf | emoji",
            "value": "..."
          }
        }
        ```

        示例：

        ```json
        {
          "name": "Qjiao",
          "description": "macOS 终端工作区，基于 Kero 二次开发",
          "icon": { "type": "icon", "value": "folder-client" }
        }
        ```

        ```json
        {
          "name": "API Server",
          "description": "Node.js backend",
          "icon": { "type": "sf", "value": "server.rack" }
        }
        ```

        ```json
        {
          "name": "Notes",
          "description": "",
          "icon": { "type": "emoji", "value": "📝" }
        }
        ```
        """
    }

    // MARK: - 解析

    private struct RawMeta {
        var name: String
        var description: String
        var iconType: String?
        var iconValue: String?
    }

    /// 从模型输出提取 name / description / icon。
    nonisolated private static func parseMetaJSON(from text: String) throws -> RawMeta {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAIProjectMetaSuggestError.emptyResponse
        }

        if let meta = decodeMeta(from: trimmed) {
            return meta
        }
        if let block = extractFirstJSONObject(from: trimmed), let meta = decodeMeta(from: block) {
            return meta
        }
        throw LocalAIProjectMetaSuggestError.invalidJSON(trimmed)
    }

    nonisolated private static func decodeMeta(from string: String) -> RawMeta? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return nil }

        // name
        guard let nameRaw = dict["name"] as? String else { return nil }
        let name = nameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        // description：允许缺省 → 空
        let description: String = {
            if let s = dict["description"] as? String {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }()

        // icon：对象 { type, value } 或扁平 iconType/iconValue
        var iconType: String?
        var iconValue: String?
        if let iconObj = dict["icon"] as? [String: Any] {
            iconType = (iconObj["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            iconValue = (iconObj["value"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let t = dict["iconType"] as? String, let v = dict["iconValue"] as? String {
            iconType = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            iconValue = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let t = iconType {
            iconType = normalizeIconType(t)
        }

        return RawMeta(
            name: name,
            description: description,
            iconType: iconType,
            iconValue: iconValue
        )
    }

    nonisolated private static func normalizeIconType(_ type: String) -> String {
        if type.contains("emoji") { return "emoji" }
        if type == "sf" || type.contains("symbol") { return "sf" }
        if type == "icon" || type.contains("preset") || type.contains("material")
            || type.contains("builtin")
        {
            return "icon"
        }
        return type
    }

    nonisolated private static func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...i])
                    }
                default: break
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    nonisolated private static func sanitizeName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉模型偶发包裹的引号
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")),
           s.count >= 2
        {
            s = String(s.dropFirst().dropLast())
        }
        // 单行
        if let nl = s.firstIndex(of: "\n") {
            s = String(s[..<nl])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 60 {
            s = String(s.prefix(60))
        }
        return s
    }

    nonisolated private static func sanitizeDescription(_ description: String) -> String {
        var s = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // 压成单行
        s = s.replacingOccurrences(of: "\n", with: " ")
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        if s.count > 120 {
            s = String(s.prefix(120))
        }
        return s
    }
}

// MARK: - Errors

/// AI 生成项目元数据失败原因。
enum LocalAIProjectMetaSuggestError: Error, LocalizedError, Equatable {
    case emptyResponse
    case invalidJSON(String)
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "AI returned an empty response."
        case .invalidJSON(let raw):
            let preview = raw.prefix(120)
            return "Could not parse AI project meta JSON: \(preview)"
        case .emptyName:
            return "AI returned an empty project name."
        }
    }
}
