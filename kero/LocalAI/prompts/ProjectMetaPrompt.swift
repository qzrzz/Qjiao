//
//  ProjectMetaPrompt.swift
//  kero/LocalAI/prompts
//
//  AI Name & Desc & Icon 提示词的**唯一来源**。
//  修改本文件即可调整元数据生成行为；业务代码只做占位替换与组装。
//
//  **写作语言**：name / description 遵循 Settings → AI → Writing language
//  （及项目覆盖）；icon 的 type/value 为标识符，不受写作语言影响。
//

import Foundation

/// 项目名称 / 描述 / 图标联合生成提示词（`LocalAIProjectMetaSuggest`）。
enum ProjectMetaPrompt {
    /// 组装完整 prompt。
    /// - Parameters:
    ///   - icons: Material 逻辑名列表文本。
    ///   - projectCtx: 项目上下文（name / path / package.json / README 等）。
    ///   - language: AI 写作语言（仅约束 name / description 自然语言）。
    static func build(
        icons: String,
        projectCtx: String,
        language: AIWritingLanguage
    ) -> String {
        """
        \(body)

        \(writingLanguageSection(language))

        ## Material 内置 icon 列表（icon.type=icon 时 value 必须来自本列表）

        ```text
        \(icons)
        ```

        ## 项目上下文

        ```text
        \(projectCtx)
        ```

        \(outputRequirements)
        """
    }

    /// 角色与字段规则（不含运行时列表与语言段）。
    static let body: String = """
    你需要为项目生成设置信息：显示名称、简短描述、图标。

    尽快回复!
    No tools, commands, web search, or file access.
    Use only provided context and answer immediately.

    ## 输出字段

    1. **name**（必填）
       - 项目在侧边栏显示的标题。
       - 简洁、可读；建议 2–40 个字符。
       - 自然语言部分须遵循下方「写作语言」要求。
       - 不要包含路径、引号、emoji（emoji 放在 icon 里）。
       - 优先采用 package.json name 的可读形式，或 README / 文件夹名提炼。

    2. **description**（必填字段，内容可为空字符串）
       - 一句话说明项目用途或技术栈。
       - 建议不超过 80 个字符；没有把握时用空字符串 `""`。
       - 自然语言部分须遵循下方「写作语言」要求。

    3. **icon**（必填对象）
       - 选择优先级必须严格遵守：
         1) Material 内置 icon（最高）：`type` 为 `"icon"`，`value` 必须是下方列表中的**精确逻辑名**。
         2) SF Symbol（中）：仅当没有合适 Material 时，`type` 为 `"sf"`。
         3) Emoji（最低）：仅当前两者都不合适时，`type` 为 `"emoji"`。
       - 不要编造 Material 列表中不存在的名字。
       - icon 的 type / value 为机器标识，不受写作语言约束。
    """

    /// 注入 Settings「写作语言」；仅作用于 name / description。
    static func writingLanguageSection(_ language: AIWritingLanguage) -> String {
        let label = language.promptLabel
        return """
        ## 写作语言（Writing language）

        - Generate **name** and **description** natural-language text in **\(label)**.
        - Keep technical terms, programming keywords, framework names, library names, API names, product names, and proper nouns in their original English form when that is conventional.
        - Do not translate common development identifiers (e.g. package names, file names).
        - **icon** fields are not natural language: keep `type` / `value` as required identifiers or emoji symbols, independent of writing language.
        """
    }

    /// 输出 JSON 格式与示例。
    static let outputRequirements: String = """
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
