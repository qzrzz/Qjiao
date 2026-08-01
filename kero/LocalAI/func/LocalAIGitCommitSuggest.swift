//
//  LocalAIGitCommitSuggest.swift
//  kero
//
//  使用 LocalAI 根据 git diff 生成 Conventional Commit + 可选 Gitmoji 提交说明。
//  提示词唯一来源：`LocalAI/prompts/GitCommitPrompt.swift`（`GitCommitPrompt`）。
//

import Foundation

// MARK: - 结果

/// AI 生成的 Git Commit Message（纯文本，可直接写入输入框）。
struct LocalAIGitCommitSuggestion: Sendable, Equatable {
    /// 清理后的 commit message 全文。
    var message: String
}

// MARK: - 主入口

/// 通过 LocalAI 根据仓库 diff 生成 commit message。
enum LocalAIGitCommitSuggest {
    /// 默认超时：纯文本生成应较快；超时后强杀 CLI，避免一直转圈。
    static let defaultTimeout: Duration = .seconds(45)

    /// 注入 prompt 的变更摘要最大字符数（越小越快）。
    static let maxDiffCharacters = 10_000

    /// 单个文件 patch 上限；锁文件 / 生成物更严。
    static let maxPatchPerFile = 800
    static let maxPatchPerNoiseFile = 120

    /// 未跟踪文件最多列出条数（不读正文）。
    static let maxUntrackedList = 15

    /// 收集 diff 并请求 AI；需已配置可用的 CLI 或 API provider。
    ///
    /// - Parameters:
    ///   - repoRoot: 仓库根目录绝对路径。
    ///   - language: 写作语言（已解析项目覆盖后的最终值）。
    ///   - useEmoji: 是否按 Gitmoji 规范加 emoji。
    /// - Returns: 仅含 message 的结果。
    ///
    /// 非 MainActor：可在后台 Task 中调用，避免 CLI 等待时拖住 UI。
    static func suggest(
        repoRoot: String,
        language: AIWritingLanguage,
        useEmoji: Bool
    ) async throws -> LocalAIGitCommitSuggestion {
        let enabled = await MainActor.run { LocalAI.isEnabled }
        guard enabled else {
            throw LocalAIError.disabled
        }
        let provider = await MainActor.run { LocalAI.selectedProvider }
        let providerName = provider.displayName
        // CLI Codex 固定使用 gpt-5.6-luna；API 后端使用设置中的模型。
        let modelOverride: String?
        if case .cli(.codex) = provider {
            modelOverride = LocalAIProviderID.codexDefaultModel
        } else {
            modelOverride = nil
        }

        let root = repoRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw LocalAIGitCommitSuggestError.invalidRepo
        }

        let diff = try await Task.detached(priority: .userInitiated) {
            try collectDiff(in: root)
        }.value

        try Task.checkCancellation()

        let prompt = try await Task.detached(priority: .userInitiated) {
            try buildPrompt(diff: diff, language: language, useEmoji: useEmoji)
        }.value

        try Task.checkCancellation()

        print(
            """
            [LocalAIGitCommitSuggest] ——— prompt begin ———
            repo: \(root)
            language: \(language.rawValue)
            useEmoji: \(useEmoji)
            diff chars: \(diff.count)  prompt chars: \(prompt.count)
            provider: \(providerName)
            model: \(modelOverride ?? "(default)")
            \(prompt)
            [LocalAIGitCommitSuggest] ——— prompt end ———
            """
        )

        // disableTools：禁止 CLI 再跑 git/读文件，只根据已给 diff 写 message；否则易卡权限/转圈
        let response = try await LocalAI.prompt(
            LocalAIRequest(
                prompt: prompt,
                workingDirectory: root,
                model: modelOverride,
                timeout: defaultTimeout,
                autoApprove: false,
                disableTools: true
            )
        )

        print(
            """
            [LocalAIGitCommitSuggest] ——— response begin ———
            provider: \(response.provider.displayName)
            exitCode: \(response.exitCode)
            executable: \(response.executablePath)
            text:
            \(response.text)
            stderr:
            \(response.rawStderr)
            [LocalAIGitCommitSuggest] ——— response end ———
            """
        )

        try Task.checkCancellation()

        let message = sanitizeMessage(response.text)
        guard !message.isEmpty else {
            throw LocalAIGitCommitSuggestError.emptyResponse
        }

        return LocalAIGitCommitSuggestion(message: message)
    }

    // MARK: - Diff

    /// 检查仓库中是否有已暂存 (Staged) 的文件变更。
    ///
    /// 通过解析 `git status --porcelain=v1` 中每个文件的首个状态字符（Index 状态）：
    /// - 若首字符不是 `' '`（未暂存/无变更）、`'?'`（未跟踪）、`'!'`（忽略），则代表 index 中存在已暂存变更。
    /// - Parameter repoRoot: 仓库根目录路径。
    /// - Returns: 若存在已暂存变更返回 true，否则返回 false。
    nonisolated static func hasStagedChanges(in repoRoot: String) -> Bool {
        let status = GitStatusModel.runGit(
            ["status", "--porcelain=v1", "--no-renames"],
            in: repoRoot
        )
        guard status.status == 0 else { return false }
        for line in status.stdout.split(separator: "\n") {
            guard line.count >= 2 else { continue }
            let stagedChar = line.first!
            if stagedChar != "?" && stagedChar != " " && stagedChar != "!" {
                return true
            }
        }
        return false
    }

    /// 收集并精简变更摘要（分情况处理）：
    /// 1. 如果已暂存 (Staged) 存在：仅仅包含已暂存 (Staged) 变更，绝对不包含已变更 (Unstaged) 或未跟踪文件。
    /// 2. 如果已暂存 (Staged) 为空：才包含已变更 (Unstaged diff) 与未跟踪文件 (Untracked paths)。
    ///
    /// - Parameter repoRoot: 仓库根目录绝对路径。
    /// - Returns: 格式化与截断后的 Git Diff 字符串。
    /// - Throws: `LocalAIGitCommitSuggestError.noChanges` 当没有任何可用的变更时。
    nonisolated static func collectDiff(in repoRoot: String) throws -> String {
        // 1) 判断已暂存 (Staged) 变更是否存在
        if hasStagedChanges(in: repoRoot) {
            // 已暂存存在：仅描述已暂存 (Staged)
            let stagedSummary = compactDiffSection(
                title: "Staged",
                cached: true,
                in: repoRoot
            )
            if let stagedSummary {
                return finalizeDiff(stagedSummary)
            } else {
                // 若已暂存存在但在 compactDiffSection 中未提取出 patch，仍抛出无有效变更，绝不降级至 Unstaged
                throw LocalAIGitCommitSuggestError.noChanges
            }
        }

        // 2) 若已暂存 (Staged) 为空：才收集已变更 (Unstaged patch + 未跟踪路径列表)
        var sections: [String] = []
        if let unstaged = compactDiffSection(
            title: "Unstaged",
            cached: false,
            in: repoRoot
        ) {
            sections.append(unstaged)
        }

        let untracked = listUntrackedPaths(in: repoRoot)
        if !untracked.isEmpty {
            var block = "## Untracked files (paths only)\n"
            for path in untracked.prefix(maxUntrackedList) {
                block += "- \(path)\n"
            }
            if untracked.count > maxUntrackedList {
                block += "- … and \(untracked.count - maxUntrackedList) more\n"
            }
            sections.append(block)
        }

        let combined = sections.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw LocalAIGitCommitSuggestError.noChanges
        }
        return finalizeDiff(combined)
    }

    /// 生成单侧（staged 或 worktree）精简 diff；无变更时返回 nil。
    nonisolated private static func compactDiffSection(
        title: String,
        cached: Bool,
        in repoRoot: String
    ) -> String? {
        let base = cached
            ? ["diff", "--cached"]
            : ["diff"]

        // 文件状态列表（轻量）
        let nameStatus = GitStatusModel.runGit(
            base + ["--name-status", "--find-renames", "--no-color"],
            in: repoRoot
        )
        let names = nameStatus.status == 0
            ? nameStatus.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // 行数统计（轻量）
        let stat = GitStatusModel.runGit(
            base + ["--stat=72", "--no-color"],
            in: repoRoot
        )
        let statText = stat.status == 0
            ? stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // 实际 patch：无上下文、忽略空白、跳过二进制
        let patchRun = GitStatusModel.runGit(
            base + [
                "--no-color",
                "--find-renames",
                "--unified=0",
                "--ignore-space-change",
                "--diff-filter=ACDMRTUXB",
            ],
            in: repoRoot
        )
        let rawPatch = patchRun.status == 0
            ? patchRun.stdout
            : ""

        let hasNames = !names.isEmpty
        let hasPatch = !rawPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasNames || hasPatch else { return nil }

        var out = "## \(title)\n"
        if hasNames {
            out += "### name-status\n\(names)\n"
        }
        if !statText.isEmpty {
            out += "### stat\n\(statText)\n"
        }
        if hasPatch {
            let clipped = clipPatchByFile(rawPatch)
            if !clipped.isEmpty {
                out += "### patch (unified=0, truncated)\n```diff\n\(clipped)\n```\n"
            }
        }
        return out
    }

    /// 按文件切分 patch，单文件与总量双重截断；噪声文件更短。
    nonisolated private static func clipPatchByFile(_ raw: String) -> String {
        // git diff 以 "diff --git " 分文件
        let chunks = splitGitPatchFiles(raw)
        guard !chunks.isEmpty else {
            return truncate(raw.trimmingCharacters(in: .whitespacesAndNewlines), max: maxDiffCharacters)
        }

        var result = ""
        var remaining = maxDiffCharacters
        for chunk in chunks {
            guard remaining > 80 else {
                result += "\n… [remaining files omitted]\n"
                break
            }
            let path = patchPrimaryPath(chunk)
            if shouldSkipPatchPath(path) {
                let note = "diff --git \(path)\n… [skipped bulky/generated file]\n"
                if note.count <= remaining {
                    result += note
                    remaining -= note.count
                }
                continue
            }
            let limit = isNoisePath(path) ? maxPatchPerNoiseFile : maxPatchPerFile
            let piece = truncate(chunk.trimmingCharacters(in: .whitespacesAndNewlines), max: min(limit, remaining))
            if piece.isEmpty { continue }
            result += piece
            if !result.hasSuffix("\n") { result += "\n" }
            remaining = maxDiffCharacters - result.count
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 将完整 `git diff` 输出拆成每个文件一块。
    nonisolated private static func splitGitPatchFiles(_ raw: String) -> [String] {
        let marker = "diff --git "
        var parts: [String] = []
        var current = ""
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix(marker), !current.isEmpty {
                parts.append(current)
                current = s + "\n"
            } else {
                current += s + "\n"
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current)
        }
        return parts
    }

    /// 从 `diff --git a/foo b/foo` 取路径名。
    nonisolated private static func patchPrimaryPath(_ chunk: String) -> String {
        guard let first = chunk.split(separator: "\n", maxSplits: 1).first else { return "" }
        // diff --git a/path b/path
        let tokens = first.split(separator: " ")
        if tokens.count >= 3 {
            var p = String(tokens[2])
            if p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
            if p.hasPrefix("a/") { p = String(p.dropFirst(2)) }
            return p
        }
        return String(first)
    }

    /// 完全跳过（过大、无助于写 message）。
    nonisolated private static func shouldSkipPatchPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let base = (path as NSString).lastPathComponent.lowercased()
        // 常见巨型生成物 / 二进制扩展
        if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") || lower.hasSuffix(".ico")
            || lower.hasSuffix(".pdf") || lower.hasSuffix(".zip") || lower.hasSuffix(".gz")
            || lower.hasSuffix(".woff") || lower.hasSuffix(".woff2") || lower.hasSuffix(".ttf")
            || lower.hasSuffix(".mp4") || lower.hasSuffix(".icns")
        {
            return true
        }
        // 资源目录里整批 SVG 图标等
        if lower.contains("/materialicons/") || lower.contains("/icons/") && lower.hasSuffix(".svg") {
            return true
        }
        // Xcode / 构建产物
        if lower.contains("/deriveddata/") || lower.contains("/build/")
            || base == ".ds_store"
        {
            return true
        }
        return false
    }

    /// 锁文件等：只留极短片段。
    nonisolated private static func isNoisePath(_ path: String) -> Bool {
        let base = (path as NSString).lastPathComponent.lowercased()
        if base == "package-lock.json" || base == "pnpm-lock.yaml" || base == "yarn.lock"
            || base == "bun.lock" || base == "bun.lockb" || base == "cargo.lock"
            || base == "poetry.lock" || base == "composer.lock" || base == "go.sum"
            || base.hasSuffix(".min.js") || base.hasSuffix(".min.css")
            || base.hasSuffix(".map") || base == "changelog.md"
        {
            return true
        }
        return false
    }

    /// 未跟踪路径列表（不读文件内容）。
    nonisolated private static func listUntrackedPaths(in repoRoot: String) -> [String] {
        let status = GitStatusModel.runGit(
            ["status", "--porcelain=v1", "-uall", "--no-renames"],
            in: repoRoot
        )
        guard status.status == 0 else { return [] }
        return status.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("??") }
            .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func finalizeDiff(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxDiffCharacters { return trimmed }
        return truncate(trimmed, max: maxDiffCharacters)
    }

    nonisolated private static func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        let head = String(text.prefix(max))
        return head + "\n… [truncated]"
    }

    // MARK: - Prompt

    /// 组装完整提示词：`GitCommitPrompt`（唯一来源）+ 语言 + emoji 开关 + diff。
    nonisolated static func buildPrompt(
        diff: String,
        language: AIWritingLanguage,
        useEmoji: Bool
    ) throws -> String {
        let gitmojiBlock = useEmoji
            ? GitCommitPrompt.emojiEnabledNote
            : GitCommitPrompt.emojiDisabledNote

        let langBlock = GitCommitPrompt.languageInstruction
            .replacingOccurrences(
                of: GitCommitPrompt.placeholderLang,
                with: language.promptLabel
            )

        var template = GitCommitPrompt.template
            .replacingOccurrences(of: GitCommitPrompt.placeholderGitMoji, with: gitmojiBlock)
            .replacingOccurrences(of: GitCommitPrompt.placeholderLangBlockTypo, with: langBlock)
            .replacingOccurrences(of: GitCommitPrompt.placeholderLang, with: langBlock)

        if !useEmoji {
            template += "\n\n" + GitCommitPrompt.emojiDisabledAppendix
        }

        template += "\n\n" + GitCommitPrompt.diffSection(diffBody: diff)
        template += "\n\n" + GitCommitPrompt.finalInstruction

        return template
    }

    // MARK: - 清理

    /// 去掉模型常见的包裹（代码块、引号、前后说明）。
    nonisolated static func sanitizeMessage(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // 整段被 ``` 或 ```text 包裹
        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if lines.first?.hasPrefix("```") == true {
                lines.removeFirst()
            }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 去掉可能的 “Here is the commit message:” 类前缀（首行无 type 时）
        let typePrefixes = [
            "feat", "fix", "docs", "style", "refactor", "perf", "test",
            "build", "ci", "chore", "i18n",
        ]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first {
            let stripped = first.trimmingCharacters(in: .whitespaces)
            let looksLikeCommit = typePrefixes.contains { type in
                stripped.hasPrefix(type + "(")
                    || stripped.hasPrefix(type + ":")
                    || stripped.contains(" " + type + "(")
                    || stripped.contains(" " + type + ":")
            }
            // 首行是 emoji + type 或纯 type
            let startsWithEmojiType: Bool = {
                guard let space = stripped.firstIndex(of: " ") else { return false }
                let after = stripped[stripped.index(after: space)...]
                return typePrefixes.contains { after.hasPrefix($0 + "(") || after.hasPrefix($0 + ":") }
            }()
            if !looksLikeCommit && !startsWithEmojiType, lines.count > 1 {
                // 若后续行才是真正 message，丢掉首行寒暄
                let rest = lines.dropFirst().joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.split(separator: "\n").first.map({ line in
                    let s = line.trimmingCharacters(in: .whitespaces)
                    return typePrefixes.contains {
                        s.hasPrefix($0 + "(") || s.hasPrefix($0 + ":")
                            || s.contains(" " + $0 + "(") || s.contains(" " + $0 + ":")
                    }
                }) == true {
                    text = rest
                }
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 错误

/// Git Commit Message AI 生成失败原因。
enum LocalAIGitCommitSuggestError: Error, LocalizedError, Equatable {
    case invalidRepo
    case noChanges
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidRepo:
            return L10n.t("No Git repository available.")
        case .noChanges:
            return L10n.t("No changes to summarize for a commit message.")
        case .emptyResponse:
            return L10n.t("AI returned an empty commit message.")
        }
    }
}
