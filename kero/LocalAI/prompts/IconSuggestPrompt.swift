//
//  IconSuggestPrompt.swift
//  kero/LocalAI/prompts
//
//  AI Select Icon 提示词的**唯一来源**。
//  修改本文件即可调整选图标行为；业务代码只做占位替换与组装。
//

import Foundation

/// 项目图标推荐提示词（`LocalAIIconSuggest`）。
enum IconSuggestPrompt {
    /// 组装完整 prompt。
    /// - Parameters:
    ///   - icons: Material 逻辑名列表文本。
    ///   - projectCtx: 项目上下文（name / path / package.json / README 等）。
    static func build(icons: String, projectCtx: String) -> String {
        """
        \(body)

        ## 输入

        ### Material 内置 icon 列表（type=icon 的 value 必须来自本列表）

        ```text
        \(icons)
        ```

        ### 项目上下文

        ```text
        \(projectCtx)
        ```

        \(outputRequirements)
        """
    }

    /// 角色、优先级与规则（不含运行时列表）。
    static let body: String = """
    你需要为一个项目选择最合适的图标。

    尽快回复!
    No tools, commands, web search, or file access.
    Use only provided context and answer immediately.

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
    """

    /// 输出 JSON 格式与示例。
    static let outputRequirements: String = """
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
