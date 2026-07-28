//
//  GitCommitEditor.swift
//  kero
//

import AppKit
import SwiftUI

/// Git 提交编辑器：提供修改 Git 历史中任意提交（Reword 提交信息、修改作者、修补改动及丢弃提交）的核心逻辑与 UI 弹窗。
public enum GitCommitEditor {

    /// 提交详细信息结构体
    public struct CommitDetails: Sendable, Equatable {
        /// 完整 Commit Hash
        public let hash: String
        /// 短 Commit Hash
        public let shortHash: String
        /// 作者姓名
        public let authorName: String
        /// 作者邮箱
        public let authorEmail: String
        /// 提交日期文本
        public let dateString: String
        /// 提交标题 (Subject)
        public let subject: String
        /// 提交正文 (Body)
        public let body: String

        /// 完整的提交信息 (Subject + Body)
        public var fullMessage: String {
            body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? subject
                : "\(subject)\n\n\(body)"
        }
    }

    /// Git 命令操作结果结构体
    public struct EditResult: Sendable {
        /// 是否成功
        public let success: Bool
        /// Git 命令完整输出日志
        public let output: String
        /// 失败时的错误原因
        public let errorMessage: String?
    }

    // MARK: - Core Operations

    /**
     获取指定提交的完整详细信息 (包括 Subject, Body, Author, Email 等)。
     - Parameters:
       - repoRoot: 仓库根目录路径
       - commitHash: 目标提交 Hash
     - Returns: `CommitDetails` 结构体，获取失败返回 `nil`
     */
    public static func getCommitDetails(
        in repoRoot: String,
        commitHash: String
    ) async -> CommitDetails? {
        let args = [
            "log", "-1",
            "--pretty=format:%H%x1f%h%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%b",
            commitHash
        ]
        let res = await runGitAsync(args, in: repoRoot)
        guard res.status == 0 else { return nil }

        let fields = res.stdout.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count >= 7 else { return nil }

        return CommitDetails(
            hash: String(fields[0]),
            shortHash: String(fields[1]),
            authorName: String(fields[2]),
            authorEmail: String(fields[3]),
            dateString: String(fields[4]),
            subject: String(fields[5]),
            body: String(fields[6])
        )
    }

    /**
     修改指定提交的 Commit Message (Reword)。
     对于 HEAD 提交直接使用 `git commit --amend`；对于历史提交使用 `git commit-tree` + `git rebase --onto` 无缝重放。
     - Parameters:
       - repoRoot: 仓库根路径
       - commitHash: 目标提交 Hash
       - newMessage: 新的提交信息
       - isHead: 是否为 HEAD 提交
     - Returns: `EditResult` 操作结果
     */
    public static func rewordCommit(
        in repoRoot: String,
        commitHash: String,
        newMessage: String,
        isHead: Bool
    ) async -> EditResult {
        let cleanMessage = newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else {
            return EditResult(success: false, output: "", errorMessage: "Commit message cannot be empty")
        }

        if isHead {
            let res = await runGitAsync(["commit", "--amend", "-m", cleanMessage], in: repoRoot)
            return makeResult(from: res, label: "Reword HEAD commit")
        }

        // 历史提交：1. 获取该提交的 tree 和 parent
        let treeRes = await runGitAsync(["rev-parse", "\(commitHash)^{tree}"], in: repoRoot)
        guard treeRes.status == 0 else {
            return EditResult(success: false, output: treeRes.stderr, errorMessage: "Failed to resolve commit tree")
        }
        let treeHash = treeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let parentRes = await runGitAsync(["rev-parse", "--verify", "\(commitHash)^"], in: repoRoot)
        let parentHash = parentRes.status == 0 ? parentRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        // 获取原 commit 的 author / committer 信息保持一致
        let envLog = await runGitAsync(["log", "-1", "--pretty=format:%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd", commitHash], in: repoRoot)
        var env: [String: String] = [:]
        if envLog.status == 0 {
            let parts = envLog.stdout.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 6 {
                env["GIT_AUTHOR_NAME"] = parts[0]
                env["GIT_AUTHOR_EMAIL"] = parts[1]
                env["GIT_AUTHOR_DATE"] = parts[2]
                env["GIT_COMMITTER_NAME"] = parts[3]
                env["GIT_COMMITTER_EMAIL"] = parts[4]
                env["GIT_COMMITTER_DATE"] = parts[5]
            }
        }

        // 2. 创建新 commit-tree
        var commitTreeArgs = ["commit-tree", treeHash]
        if let parentHash {
            commitTreeArgs += ["-p", parentHash]
        }
        commitTreeArgs += ["-m", cleanMessage]

        let newCommitRes = await runGitAsync(commitTreeArgs, in: repoRoot, environment: env)
        guard newCommitRes.status == 0 else {
            return EditResult(success: false, output: newCommitRes.stderr, errorMessage: "Failed to create reworded commit tree")
        }
        let newCommitHash = newCommitRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 将后续提交 rebase 到新 commit 上
        let rebaseRes = await runGitAsync(["rebase", "--onto", newCommitHash, commitHash, "HEAD"], in: repoRoot)
        return makeResult(from: rebaseRes, label: "Reword historical commit \(commitHash.prefix(7))")
    }

    /**
     修改指定提交的作者信息 (Author Name & Email)。
     - Parameters:
       - repoRoot: 仓库根路径
       - commitHash: 目标提交 Hash
       - authorName: 新的作者姓名
       - authorEmail: 新的作者邮箱
       - isHead: 是否为 HEAD 提交
     - Returns: `EditResult` 操作结果
     */
    public static func updateAuthor(
        in repoRoot: String,
        commitHash: String,
        authorName: String,
        authorEmail: String,
        isHead: Bool
    ) async -> EditResult {
        let name = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else {
            return EditResult(success: false, output: "", errorMessage: "Author name and email cannot be empty")
        }

        let authorSpec = "\(name) <\(email)>"

        if isHead {
            let res = await runGitAsync(["commit", "--amend", "--author=\(authorSpec)", "--no-edit"], in: repoRoot)
            return makeResult(from: res, label: "Update HEAD author")
        }

        // 历史提交：获取原有 message、tree、parent
        let msgRes = await runGitAsync(["log", "-1", "--format=%B", commitHash], in: repoRoot)
        guard msgRes.status == 0 else {
            return EditResult(success: false, output: msgRes.stderr, errorMessage: "Failed to get commit message")
        }
        let message = msgRes.stdout

        let treeRes = await runGitAsync(["rev-parse", "\(commitHash)^{tree}"], in: repoRoot)
        guard treeRes.status == 0 else {
            return EditResult(success: false, output: treeRes.stderr, errorMessage: "Failed to resolve commit tree")
        }
        let treeHash = treeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let parentRes = await runGitAsync(["rev-parse", "--verify", "\(commitHash)^"], in: repoRoot)
        let parentHash = parentRes.status == 0 ? parentRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        var env: [String: String] = [
            "GIT_AUTHOR_NAME": name,
            "GIT_AUTHOR_EMAIL": email,
        ]

        let dateRes = await runGitAsync(["log", "-1", "--format=%ad", commitHash], in: repoRoot)
        if dateRes.status == 0 {
            let d = dateRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            env["GIT_AUTHOR_DATE"] = d
            env["GIT_COMMITTER_DATE"] = d
        }

        var commitTreeArgs = ["commit-tree", treeHash]
        if let parentHash {
            commitTreeArgs += ["-p", parentHash]
        }
        commitTreeArgs += ["-m", message]

        let newCommitRes = await runGitAsync(commitTreeArgs, in: repoRoot, environment: env)
        guard newCommitRes.status == 0 else {
            return EditResult(success: false, output: newCommitRes.stderr, errorMessage: "Failed to create commit tree with new author")
        }
        let newCommitHash = newCommitRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let rebaseRes = await runGitAsync(["rebase", "--onto", newCommitHash, commitHash, "HEAD"], in: repoRoot)
        return makeResult(from: rebaseRes, label: "Update author for commit \(commitHash.prefix(7))")
    }

    /**
     将当前暂存区的改动修补合并到指定提交 (Fixup / Amend into commit)。
     - Parameters:
       - repoRoot: 仓库根路径
       - commitHash: 目标提交 Hash
       - isHead: 是否为 HEAD 提交
     - Returns: `EditResult` 操作结果
     */
    public static func amendIntoCommit(
        in repoRoot: String,
        commitHash: String,
        isHead: Bool
    ) async -> EditResult {
        if isHead {
            let res = await runGitAsync(["commit", "--amend", "--no-edit"], in: repoRoot)
            return makeResult(from: res, label: "Amend staged changes into HEAD")
        }

        // 步骤 1：先为当前暂存区生成一个 fixup commit
        let fixupRes = await runGitAsync(["commit", "--fixup", commitHash], in: repoRoot)
        guard fixupRes.status == 0 else {
            return EditResult(success: false, output: fixupRes.stderr, errorMessage: "Failed to create fixup commit. Ensure changes are staged.")
        }

        // 步骤 2：使用非交互式 autosquash rebase
        let env = ["GIT_SEQUENCE_EDITOR": "true"]
        let rebaseRes = await runGitAsync(["rebase", "-i", "--autosquash", "\(commitHash)^"], in: repoRoot, environment: env)
        return makeResult(from: rebaseRes, label: "Amend changes into commit \(commitHash.prefix(7))")
    }

    /**
     从 Git 历史中丢弃/删除指定的提交。
     - Parameters:
       - repoRoot: 仓库根路径
       - commitHash: 目标提交 Hash
       - isHead: 是否为 HEAD 提交
     - Returns: `EditResult` 操作结果
     */
    public static func dropCommit(
        in repoRoot: String,
        commitHash: String,
        isHead: Bool
    ) async -> EditResult {
        if isHead {
            let res = await runGitAsync(["reset", "--hard", "HEAD^"], in: repoRoot)
            return makeResult(from: res, label: "Drop HEAD commit")
        }

        let rebaseRes = await runGitAsync(["rebase", "--onto", "\(commitHash)^", commitHash, "HEAD"], in: repoRoot)
        return makeResult(from: rebaseRes, label: "Drop commit \(commitHash.prefix(7))")
    }

    // MARK: - Private Process Helpers

    private static func makeResult(from res: (status: Int32, stdout: String, stderr: String), label: String) -> EditResult {
        let combined = [res.stdout, res.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if res.status == 0 {
            return EditResult(success: true, output: combined.isEmpty ? "\(label) succeeded." : combined, errorMessage: nil)
        } else {
            let err = combined.isEmpty ? "\(label) failed with exit code \(res.status)" : combined
            return EditResult(success: false, output: combined, errorMessage: err)
        }
    }

    private static func runGitAsync(
        _ args: [String],
        in directory: String,
        environment: [String: String]? = nil
    ) async -> (status: Int32, stdout: String, stderr: String) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)

            var env = ProcessInfo.processInfo.environment
            if let environment {
                for (k, v) in environment {
                    env[k] = v
                }
            }
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                return (process.terminationStatus, stdout, stderr)
            } catch {
                return (-1, "", error.localizedDescription)
            }
        }.value
    }
}

// MARK: - SwiftUI Edit Commit Sheet

/// 编辑 Git Commit 提交信息与作者的弹出窗口视图。
public struct GitCommitEditSheet: View {
    let repoRoot: String
    let commitHash: String
    let shortHash: String
    let isHead: Bool
    let onComplete: (_ success: Bool, _ errorMessage: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var authorName: String = ""
    @State private var authorEmail: String = ""
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil
    @State private var selectedTab: Int = 0

    public init(
        repoRoot: String,
        commitHash: String,
        shortHash: String,
        isHead: Bool,
        onComplete: @escaping (_ success: Bool, _ errorMessage: String?) -> Void
    ) {
        self.repoRoot = repoRoot
        self.commitHash = commitHash
        self.shortHash = shortHash
        self.isHead = isHead
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header 标头
            HStack(spacing: 8) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(nsColor: Theme.cursor))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L10n.t("Edit Commit"))
                            .font(SidebarTypography.body(.semibold))
                        Text(shortHash)
                            .font(SidebarTypography.caption(.medium, design: .monospaced))
                            .foregroundStyle(Color(nsColor: Theme.cursor))
                        if isHead {
                            Text(L10n.t("HEAD"))
                                .font(SidebarTypography.micro(.bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.12)))
                        }
                    }
                    Text(L10n.t("Modify commit message or author info"))
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            // 模式切换器 Picker
            Picker("", selection: $selectedTab) {
                Text(L10n.t("Commit Message")).tag(0)
                Text(L10n.t("Author Info")).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // 内容区
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.t("Loading commit details…"))
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    if selectedTab == 0 {
                        // Edit Message Tab
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.t("Subject"))
                                .font(SidebarTypography.caption(.medium))
                                .foregroundStyle(.secondary)
                            TextField("Commit title", text: $subject)
                                .textFieldStyle(.roundedBorder)
                                .font(SidebarTypography.body())

                            Text(L10n.t("Description (Optional)"))
                                .font(SidebarTypography.caption(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)

                            TextEditor(text: $bodyText)
                                .font(SidebarTypography.body(design: .monospaced))
                                .padding(4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                )
                                .frame(minHeight: 90)
                        }
                    } else {
                        // Edit Author Tab
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.t("Author Name"))
                                    .font(SidebarTypography.caption(.medium))
                                    .foregroundStyle(.secondary)
                                TextField("e.g. John Doe", text: $authorName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(SidebarTypography.body())
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.t("Author Email"))
                                    .font(SidebarTypography.caption(.medium))
                                    .foregroundStyle(.secondary)
                                TextField("e.g. john@example.com", text: $authorEmail)
                                    .textFieldStyle(.roundedBorder)
                                    .font(SidebarTypography.body())
                            }

                            Spacer()
                        }
                        .padding(.top, 4)
                    }

                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
                            Text(errorMessage)
                                .font(SidebarTypography.caption())
                                .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            // Footer 底部控制栏
            HStack(spacing: 10) {
                Button(L10n.t("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button {
                    saveChanges()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(L10n.t("Save Changes"))
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: Theme.cursor))
                .controlSize(.regular)
                .disabled(isLoading || isSaving || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: 320)
        .task {
            await loadDetails()
        }
    }

    private func loadDetails() async {
        isLoading = true
        if let details = await GitCommitEditor.getCommitDetails(in: repoRoot, commitHash: commitHash) {
            subject = details.subject
            bodyText = details.body
            authorName = details.authorName
            authorEmail = details.authorEmail
        }
        isLoading = false
    }

    private func saveChanges() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        Task {
            let result: GitCommitEditor.EditResult
            if selectedTab == 0 {
                let fullMsg = bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? subject.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "\(subject.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(bodyText.trimmingCharacters(in: .whitespacesAndNewlines))"
                result = await GitCommitEditor.rewordCommit(
                    in: repoRoot,
                    commitHash: commitHash,
                    newMessage: fullMsg,
                    isHead: isHead
                )
            } else {
                result = await GitCommitEditor.updateAuthor(
                    in: repoRoot,
                    commitHash: commitHash,
                    authorName: authorName,
                    authorEmail: authorEmail,
                    isHead: isHead
                )
            }

            isSaving = false
            if result.success {
                onComplete(true, nil)
                dismiss()
            } else {
                errorMessage = result.errorMessage ?? "Operation failed"
                onComplete(false, result.errorMessage)
            }
        }
    }
}
