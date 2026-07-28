//
//  LocalAIPrompts.swift
//  kero/LocalAI/prompts
//
//  LocalAI 提示词目录说明（本文件不导出业务字符串）。
//
//  ## 约定
//
//  - **唯一来源**：所有可调教的提示词正文放在本目录的 `*Prompt.swift` 中。
//  - **禁止**再维护旁路 `.md` / Bundle 资源 / 功能文件内的大段模板副本。
//  - 业务代码（`LocalAI/func/*Suggest.swift`）只负责：收集上下文、调用 `XxxPrompt.build(...)`、
//    替换占位符、调用 `LocalAI.prompt`、解析结果。
//
//  ## 当前模块
//
//  | 文件 | 枚举 | 功能 | 写作语言 |
//  |------|------|------|----------|
//  | `GitCommitPrompt.swift` | `GitCommitPrompt` | AI Git Commit Message | 是（message 正文） |
//  | `IconSuggestPrompt.swift` | `IconSuggestPrompt` | AI Select Icon | 否（仅图标标识） |
//  | `ProjectMetaPrompt.swift` | `ProjectMetaPrompt` | AI Name & Desc & Icon | 是（name / description；icon 除外） |
//
//  写作语言：Settings → General → AI → Writing language（项目可覆盖）。
//  新增 AI 能力时：在本目录新增 `FooPrompt.swift`，并在上表补充一行。
//

import Foundation
