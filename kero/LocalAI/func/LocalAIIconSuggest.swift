//
//  LocalAIIconSuggest.swift
//  kero
//
//  使用 LocalAI headless CLI 为项目推荐图标，并解析为 ProjectIcon。
//

import AppKit
import Combine
import Foundation

// MARK: - 结果

/// AI 选中的图标（已校验可应用到 `Project.icon`）。
struct LocalAIIconSuggestion: Sendable, Equatable {
    /// 原始 type：`icon` / `sf` / `emoji`。
    var rawType: String
    /// 原始 value。
    var rawValue: String
    /// 解析后的项目图标。
    var icon: ProjectIcon
}

// MARK: - 主入口

/// 通过 LocalAI 根据项目上下文从内置 icon / SF Symbol / Emoji 中选一个图标。
enum LocalAIIconSuggest {
    /// 默认超时：图标选择应较快返回。
    static let defaultTimeout: Duration = .seconds(90)

    /// 为项目请求 AI 选图标；需已在设置中启用 headless provider。
    ///
    /// - Parameter project: 目标项目（读取 name / description / directory）。
    /// - Returns: 校验通过的建议；失败抛出 `LocalAIError` 或 `LocalAIIconSuggestError`。
    @MainActor
    static func suggest(for project: Project) async throws -> LocalAIIconSuggestion {
        guard LocalAI.isEnabled else {
            throw LocalAIError.disabled
        }

        // 先在主线程快照，避免把 Project 带进 detached Task
        let name = project.name
        let description = project.description
        let directory = project.projectDirectory

        let projectCtx = await Task.detached(priority: .userInitiated) {
            buildProjectContext(
                name: name,
                description: description,
                directory: directory
            )
        }.value

        let iconsText = await Task.detached(priority: .userInitiated) {
            buildBuiltinIconsList()
        }.value

        try Task.checkCancellation()

        let prompt = buildPrompt(icons: iconsText, projectCtx: projectCtx)
        // 控制台调试：完整提示词（含内置 icon 列表与项目上下文）
        print(
            """
            [LocalAIIconSuggest] ——— prompt begin ———
            project: \(name)
            directory: \(directory)
            provider: \(LocalAI.selectedProvider.displayName)
            icons chars: \(iconsText.count)  prompt chars: \(prompt.count)
            \(prompt)
            [LocalAIIconSuggest] ——— prompt end ———
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

        // 控制台调试：模型原文与解析字段
        print(
            """
            [LocalAIIconSuggest] ——— response begin ———
            provider: \(response.provider.displayName)
            exitCode: \(response.exitCode)
            executable: \(response.executablePath)
            text:
            \(response.text)
            stderr:
            \(response.rawStderr)
            [LocalAIIconSuggest] ——— response end ———
            """
        )

        try Task.checkCancellation()

        let pick = try parsePickJSON(from: response.text)
        let icon = try resolveIcon(type: pick.type, value: pick.value)
        print(
            "[LocalAIIconSuggest] parsed type=\(pick.type) value=\(pick.value) → \(String(describing: icon))"
        )
        return LocalAIIconSuggestion(rawType: pick.type, rawValue: pick.value, icon: icon)
    }

    /// 建议并直接写入 `project.icon`（会清理旧的托管文件图标）。
    @MainActor
    static func apply(to project: Project) async throws -> LocalAIIconSuggestion {
        let suggestion = try await suggest(for: project)
        if case .file = project.icon {
            ProjectIconFileStore.removeManagedIcons(for: project.id)
        }
        ProjectIconThumbnailCache.clearCache()
        project.objectWillChange.send()
        project.icon = suggestion.icon
        return suggestion
    }

    // MARK: - Prompt

    /// 按产品给定模板拼装提示词。
    static func buildPrompt(icons: String, projectCtx: String) -> String {
        """
        你需要为一个项目选择最合适的图标。

        ## 选择优先级（必须严格遵守）

        1. **Material 内置 icon（最高优先级）**
           - 仔细检查下方 Material Icon Theme 逻辑名列表。
           - 如果存在语义明显匹配的图标，必须直接选择，`type` 为 `icon`，`value` 必须是列表中的**精确逻辑名**。
           - 不要选择 Brands 品牌图；不要编造列表中不存在的名字。

        2. **SF Symbol（中优先级）**
           - 仅当没有任何合适的 Material icon 时，才从你已知的 SF Symbols 中选择。
           - 优先选择 Apple 官方推荐、语义清晰、通用且长期稳定的 Symbol。

        3. **Emoji（最低优先级）**
           - 仅当没有合适的 Material icon，且没有把握选择合适的 SF Symbol 时，才选择一个 Emoji。
           - Emoji 应尽量表达项目的主要用途，而不是装饰性。

        ## 输入

        ### Material 内置 icon 列表（type=icon 的 value 必须来自本列表）

        ```text
        \(icons)
        ```

        ### 项目上下文

        ```text
        \(projectCtx)
        ```

        ## 输出要求

        仅返回一个 JSON，不要输出 Markdown，不要添加解释。

        ```json
        {
          "type": "icon | sf | emoji",
          "value": "..."
        }
        ```

        示例：

        ```json
        {
          "type": "icon",
          "value": "typescript"
        }
        ```

        ```json
        {
          "type": "sf",
          "value": "shippingbox"
        }
        ```

        ```json
        {
          "type": "emoji",
          "value": "🫑"
        }
        ```
        """
    }

    // MARK: - 项目上下文

    /// 组装 name / description / 路径末级 / package.json / README 前 20 行。
    nonisolated static func buildProjectContext(
        name: String,
        description: String?,
        directory: String
    ) -> String {
        var lines: [String] = []
        lines.append("name: \(name)")
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("description: \(description)")
        }

        let pathLeaf: String = {
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            return URL(fileURLWithPath: trimmed).lastPathComponent
        }()
        if !pathLeaf.isEmpty {
            lines.append("pathBasename: \(pathLeaf)")
        }
        if !directory.isEmpty {
            lines.append("directory: \(directory)")
        }

        if !directory.isEmpty {
            let packageMeta = loadPackageNameAndDescription(directory: directory)
            if let n = packageMeta.name, !n.isEmpty {
                lines.append("package.json name: \(n)")
            }
            if let d = packageMeta.description, !d.isEmpty {
                lines.append("package.json description: \(d)")
            }

            if let readme = loadReadmeHead(directory: directory, lineLimit: 20), !readme.isEmpty {
                lines.append("README.md (first 20 lines):")
                lines.append(readme)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 读取 package.json 的 name / description（description 不在 PackageInfo 中）。
    nonisolated private static func loadPackageNameAndDescription(
        directory: String
    ) -> (name: String?, description: String?) {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let package = object as? [String: Any]
        else {
            return (nil, nil)
        }
        let name = (package["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (package["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            name?.isEmpty == false ? name : nil,
            description?.isEmpty == false ? description : nil
        )
    }

    /// 读取 README.md / readme.md 等前 N 行。
    nonisolated private static func loadReadmeHead(directory: String, lineLimit: Int) -> String? {
        let candidates = ["README.md", "Readme.md", "readme.md", "README.MD", "README"]
        let dir = URL(fileURLWithPath: directory)
        let fm = FileManager.default
        for name in candidates {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines.prefix(lineLimit).joined(separator: "\n")
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - 内置 icon 列表

    /// 生成 prompt 中的内置 icon 清单：**仅 Material Icon Theme 逻辑名**（不含 Brands）。
    ///
    /// 缩小 prompt 体积，并引导模型在 `type=icon` 时返回 material 逻辑名。
    nonisolated static func buildBuiltinIconsList() -> String {
        let materialNames = materialIconLogicalNames()
        guard !materialNames.isEmpty else { return "(no material icons found)" }
        // 一行一个逻辑名，作为 type=icon 的 value
        return materialNames.joined(separator: "\n")
    }

    /// Material 逻辑名：扫描 icons 目录（去掉扩展名），不依赖 MainActor catalog。
    nonisolated private static func materialIconLogicalNames() -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        let candidateDirs: [URL] = {
            var urls: [URL] = []
            if let res = Bundle.main.resourceURL {
                urls.append(res.appendingPathComponent("MaterialIcons/icons"))
                urls.append(res.appendingPathComponent("icons"))
            }
            let thisFile = URL(fileURLWithPath: #filePath)
            let kero = thisFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            urls.append(kero.appendingPathComponent("MaterialIcons/icons"))
            return urls
        }()

        let fm = FileManager.default
        for dir in candidateDirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items where url.pathExtension.lowercased() == "svg" {
                let logical = url.deletingPathExtension().lastPathComponent
                if seen.insert(logical).inserted {
                    found.append(logical)
                }
            }
            // 找到第一个有效目录后即可（完整列表）
            if !found.isEmpty { break }
        }
        return found.sorted()
    }

    // MARK: - JSON 解析

    /// 从模型输出中提取 `{ "type", "value" }`。
    nonisolated static func parsePickJSON(from text: String) throws -> (type: String, value: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAIIconSuggestError.emptyResponse
        }

        // 优先整段 JSON；失败则取首个 `{...}` 块。
        if let pick = decodePick(from: trimmed) {
            return pick
        }
        if let block = extractFirstJSONObject(from: trimmed), let pick = decodePick(from: block) {
            return pick
        }
        throw LocalAIIconSuggestError.invalidJSON(trimmed)
    }

    nonisolated private static func decodePick(from string: String) -> (type: String, value: String)? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return nil }
        guard let typeRaw = dict["type"] as? String,
              let valueRaw = dict["value"] as? String
        else { return nil }
        let type = typeRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = valueRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty, !value.isEmpty else { return nil }
        // 兼容 "icon | sf | emoji" 误输出
        let normalizedType: String = {
            if type.contains("emoji") { return "emoji" }
            if type == "sf" || type.contains("symbol") { return "sf" }
            if type == "icon" || type.contains("preset") || type.contains("builtin") { return "icon" }
            return type
        }()
        return (normalizedType, value)
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

    // MARK: - 解析为 ProjectIcon

    /// 将 AI 返回的 type/value 映射到 `ProjectIcon`，并校验存在性。
    @MainActor
    static func resolveIcon(type: String, value: String) throws -> ProjectIcon {
        switch type {
        case "icon":
            return try resolveBuiltinIcon(value)
        case "sf":
            return try resolveSFSymbol(value)
        case "emoji":
            return try resolveEmoji(value)
        default:
            throw LocalAIIconSuggestError.unknownType(type)
        }
    }

    @MainActor
    private static func resolveBuiltinIcon(_ value: String) throws -> ProjectIcon {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw LocalAIIconSuggestError.unknownIcon(value)
        }

        // 去掉可能的 path / 扩展名（模型偶发写成 typescript.svg）
        let fileName = (raw as NSString).lastPathComponent
        let bare = (fileName as NSString).deletingPathExtension

        // 仅解析 Material 逻辑名（prompt 不再提供 Brands）
        let material = ProjectPresetItemCatalog.material
        if let hit = material.first(where: {
            if case .material(let name) = $0.preset {
                return name.caseInsensitiveCompare(fileName) == .orderedSame
                    || name.caseInsensitiveCompare(bare) == .orderedSame
                    || name.caseInsensitiveCompare(raw) == .orderedSame
            }
            return false
        }) {
            return .preset(hit.preset)
        }

        let needle = bare.lowercased()
        if let hit = material.first(where: {
            $0.label.lowercased() == needle
        }) {
            return .preset(hit.preset)
        }

        throw LocalAIIconSuggestError.unknownIcon(value)
    }

    @MainActor
    private static func resolveSFSymbol(_ value: String) throws -> ProjectIcon {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LocalAIIconSuggestError.unknownSFSymbol(value)
        }
        // 系统能渲染即认为有效（比目录更宽松，兼容新系统 Symbol）
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return .sfSymbol(name)
        }
        // 去掉 .fill 再试
        if name.hasSuffix(".fill") {
            let base = String(name.dropLast(5))
            if NSImage(systemSymbolName: base, accessibilityDescription: nil) != nil {
                return .sfSymbol(base)
            }
        }
        // 目录内模糊
        let catalog = SFSymbolCatalog.shared
        let all = catalog.filter("", in: .all)
        if let exact = all.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return .sfSymbol(exact)
        }
        throw LocalAIIconSuggestError.unknownSFSymbol(value)
    }

    nonisolated private static func resolveEmoji(_ value: String) throws -> ProjectIcon {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAIIconSuggestError.invalidEmoji(value)
        }
        // 取第一个扩展字形簇，避免模型输出多余文字
        if let first = trimmed.first {
            // 若整体很短（≤8 标量）当作完整 emoji 序列（含 ZWJ）
            if trimmed.unicodeScalars.count <= 16, !trimmed.contains(where: \.isNewline) {
                // 拒绝明显的英文句子
                if trimmed.unicodeScalars.contains(where: { $0.properties.isEmoji || !$0.isASCII }) {
                    return .emoji(String(trimmed.prefix(8)))
                }
            }
            if first.unicodeScalars.contains(where: { $0.properties.isEmoji }) {
                return .emoji(String(first))
            }
        }
        // 宽松：原样采用（用户可再改）
        if trimmed.count <= 4 {
            return .emoji(trimmed)
        }
        throw LocalAIIconSuggestError.invalidEmoji(value)
    }
}

// MARK: - Errors

/// AI 选图标特有错误。
enum LocalAIIconSuggestError: Error, LocalizedError, Equatable {
    case emptyResponse
    case invalidJSON(String)
    case unknownType(String)
    case unknownIcon(String)
    case unknownSFSymbol(String)
    case invalidEmoji(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "AI returned an empty response."
        case .invalidJSON(let raw):
            let preview = raw.prefix(120)
            return "Could not parse AI icon JSON: \(preview)"
        case .unknownType(let type):
            return "Unknown icon type from AI: \(type)"
        case .unknownIcon(let value):
            return "Built-in icon not found: \(value)"
        case .unknownSFSymbol(let value):
            return "SF Symbol not found: \(value)"
        case .invalidEmoji(let value):
            return "Invalid emoji from AI: \(value)"
        }
    }
}
