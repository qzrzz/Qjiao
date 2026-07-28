//
//  GitCommitPrompt.swift
//  kero/LocalAI/prompts
//
//  AI Git Commit Message 提示词的**唯一来源**。
//  修改本文件即可调整生成行为；不要再维护旁路 .md 或其它副本。
//
//  占位符（由 LocalAIGitCommitSuggest 替换）：
//  - `{{GitMoji}}`：开启/关闭 emoji 时的说明片段
//  - `{{GtiCommitLang}}` / `{{GitCommitLang}}`：写作语言指令块
//

import Foundation

/// Git Commit Message 相关提示词模板（单一真相源）。
enum GitCommitPrompt {
    // MARK: - 占位符名

    /// 注入 Gitmoji 开关说明。
    static let placeholderGitMoji = "{{GitMoji}}"
    /// 语言指令块（模板内历史拼写）。
    static let placeholderLangBlockTypo = "{{GtiCommitLang}}"
    /// 语言指令块 / 语言名。
    static let placeholderLang = "{{GitCommitLang}}"

    // MARK: - 主模板

    /// 主体指南：角色、格式、类型表、写作规则。含 `{{GitMoji}}` 与 `{{GtiCommitLang}}`。
    static let template: String = """
    # Git Commit Message Guide

    ## Role and Purpose

    You will act as a git commit message generator. When receiving a git diff, you will ONLY output the commit message itself, nothing else. No explanations, no questions, no additional comments.

    ## Hard constraints (must follow)

    - Generate the commit message **only** from the content provided in this prompt (diff / name-status / stat / untracked paths).
    - **Do not** run any tools, shell commands, git commands, or other programs.
    - **Do not** read, search, open, or edit any files outside this prompt.
    - **Do not** explore the repository, fetch remote state, stage, commit, or modify the working tree.
    - **Do not** ask clarifying questions. If the provided content is incomplete, still produce a best-effort message from what you have.

    ## Output Format

    ### Single Type Changes

    ```
    <emoji> <type>(<scope>): <subject>
      <body>
    ```

    ### Multiple Type Changes

    ```
    <emoji> <type>(<scope>): <subject>
      <body of type 1>

    <emoji> <type>(<scope>): <subject>
      <body of type 2>
    ...
    ```

    ## Type Reference

    | Type     | Emoji | Description          | Example Scopes      |
    | -------- | ----- | -------------------- | ------------------- |
    | feat     | ✨    | New feature          | user, payment       |
    | fix      | 🐛    | Bug fix              | auth, data          |
    | docs     | 📝    | Documentation        | README, API         |
    | style    | 💄    | Code style           | formatting          |
    | refactor | ♻️    | Code refactoring     | utils, helpers      |
    | perf     | ⚡️    | Performance          | query, cache        |
    | test     | ✅    | Testing              | unit, e2e           |
    | build    | 📦    | Build system         | webpack, npm        |
    | ci       | 👷    | CI config            | Travis, Jenkins     |
    | chore    | 🔧    | Other changes        | scripts, config     |
    | i18n     | 🌐    | Internationalization | locale, translation |

    ## Git Emoji (GitMoji)

    {{GitMoji}}

    ## Writing Rules

    ### Subject Line

    - Imperative mood
    - No capitalization
    - No period at end
    - Max 50 characters

    ### Body

    - Bullet points with "-"
    - Max 72 chars per line
    - Explain what and why
    - Use [] for different types

    ## Critical Requirements

    - Output ONLY the commit message
    - NO additional text or explanations
    - NO questions or comments
    - NO formatting instructions or metadata
    - NO tool use, NO shell/git, NO extra investigation — only the given content

    ## Remember!!!

    You are a pure commit message generator operating offline on the attached diff text. Your response must contain NOTHING but the commit message itself.

    {{GtiCommitLang}}
    """

    // MARK: - 语言

    /// 写作语言指令。含 `{{GitCommitLang}}`（替换为具体语言名，如 English）。
    static let languageInstruction: String = """
    Generate the commit message in {{GitCommitLang}}.

    Requirements:

    - Use {{GitCommitLang}} for the natural language description.
    - Keep technical terms, programming keywords, framework names, library names, API names, and product names in their original English form.
    - Do not translate common development terms.
    """

    // MARK: - Emoji 开关片段（注入 {{GitMoji}}）

    /// 设置开启「Git Commit Message Emoji」时：按 GitMoji 规范自选，不列举全表。
    static let emojiEnabledNote: String = """
    Use GitMoji emoji, NO web search or external lookup.
    """

    /// 设置关闭 emoji 时。
    static let emojiDisabledNote: String = """
    Do NOT use any emoji or Gitmoji in the commit message.
    Output format without emoji:

    <type>(<scope>): <subject>
      <body>
    """

    /// 关闭 emoji 时追加在模板末尾的覆盖说明。
    static let emojiDisabledAppendix: String = """
    ## Emoji disabled

    The user disabled Git Commit Message Emoji.
    Do not put any emoji at the start of type lines.
    Use: `<type>(<scope>): <subject>` only.
    """

    // MARK: - Diff / 收尾（运行时拼接）

    /// Diff 段标题与说明；`diffBody` 为已采集的变更摘要。
    static func diffSection(diffBody: String) -> String {
        """
        ## Git Diff to Summarize

        The block below is the **entire** source of truth. Write the message only from this text.

        \(diffBody)
        """
    }

    /// 最终硬性指令（每次请求末尾追加）。
    static let finalInstruction: String = """
    ## Final Instruction

    - Base the commit message **only** on the content provided above. Do not gather more context.
    - **Do not execute any extra actions**: no tools, no shell, no git commands, no file reads/writes, no repo exploration, no staging/committing, not search internet.
    - Output ONLY the commit message. No markdown fences, no preface, no explanation, no questions.
    """
}
