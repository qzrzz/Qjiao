//
//  RightSidebarGitPanel.swift
//  kero
//

import AppKit
import SwiftUI

// MARK: - Git panel

/// Git 操作目标指示，用于在按钮上展示转圈中状态并进行交互锁死
private enum GitActionTarget: Equatable {
    case stageAll
    case unstageAll
    case discardAll
    case stage(path: String)
    case unstage(path: String)
    case discard(path: String)
    case commit
    case sync
    case branchMenu
    case moreMenu
    case commitMenu
    case initializeRepository
}

struct GitPanel: View {
    private struct FileFingerprint: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?
    }

    private struct PendingDiscard {
        let entry: GitStatusModel.Entry
        let fingerprints: [String: FileFingerprint]
        let branch: String?
        let headOID: String?
    }

    @ObservedObject var model: GitStatusModel
    /// 当前项目（用于解析 AI 写作语言项目覆盖）；无项目时仅用全局设置。
    var project: Project?
    let session: TerminalSession?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let openDiff: (_ entry: GitStatusModel.Entry, _ staged: Bool) -> Void
    /// 打开某个历史提交中一个文件的父→提交 diff。
    let openCommitDiff: (
        _ commit: GitStatusModel.RecentCommit,
        _ file: GitStatusModel.RecentCommit.FileChange
    ) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var aiCommitTasks = LocalAIGitCommitTaskStore.shared
    @ObservedObject private var l10n = L10n.shared

    @State private var commitMessage = ""
    @State private var pendingDiscard: PendingDiscard?
    @State private var pendingDiscardAll: [PendingDiscard] = []
    @State private var confirmDiscardAll = false
    @State private var mergeCollapsed = false
    @State private var stagedCollapsed = false
    @State private var changesCollapsed = false
    @State private var historyCollapsed = true
    @State private var filterText = ""
    @State private var showFilter = false
    @State private var showBranchCreator = false
    @State private var newBranchName = ""
    @State private var operationExpanded = false
    @State private var isPendingAICommit = false
    @State private var activeActionTarget: GitActionTarget?
    @State private var checkedPaths: Set<String> = []
    @State private var knownPaths: Set<String> = []
    /// 提交历史中展开（显示文件列表）的 commit hash 集合。
    @State private var expandedCommitIDs: Set<String> = []
    @FocusState private var branchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            operationBanner

            if model.isRecovering, !model.isRepo {
                // Retry / 手动刷新在无仓库内容时的恢复中：单独展示恢复页，
                // 避免闪回「非仓库」空态。有内容时（isRepo=true）保留内容区
                // 显示，仅顶部刷新按钮转圈，刷新完成直接替换。
                statusFailure(nil)
            } else if let statusError = model.statusError {
                statusFailure(statusError)
            } else if !model.isRepo {
                if model.isResolvingInitialStatus {
                    placeholder(icon: "arrow.clockwise", text: L10n.t("Finding repository…"))
                } else if model.isBusy {
                    placeholder(icon: "hourglass", text: L10n.t("Finishing Git operation…"))
                } else {
                    notRepository
                }
            } else {
                trackingBar
                repositoryOperationBanner
                branchCreator
                commitBox
                filterBar
                changeList()
            }
        }
        .confirmationDialog(
            discardTitle(for: pendingDiscard?.entry),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(discardActionTitle(for: pendingDiscard?.entry),
                   role: .destructive) {
                if let pendingDiscard {
                    if discardSnapshotIsCurrent(pendingDiscard) {
                        beginGitAction(.discard(path: pendingDiscard.entry.path)) {
                            model.discard(pendingDiscard.entry)
                        }
                    } else {
                        model.cancelStaleDiscard()
                    }
                }
                pendingDiscard = nil
            }
            .disabled(model.isInteractionLocked)
        }
        .confirmationDialog(
            "Discard the \(pendingDiscardAll.count) reviewed changes? Untracked and moved files go to the Trash.",
            isPresented: Binding(
                get: { confirmDiscardAll },
                set: {
                    confirmDiscardAll = $0
                    if !$0 { pendingDiscardAll = [] }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("Discard All Changes"), role: .destructive) {
                let snapshot = pendingDiscardAll
                if !snapshot.isEmpty && snapshot.allSatisfy(discardSnapshotIsCurrent) {
                    beginGitAction(.discardAll) {
                        model.discardChanges(snapshot.map(\.entry))
                    }
                } else {
                    model.cancelStaleDiscard()
                }
                pendingDiscardAll = []
                confirmDiscardAll = false
            }
            .disabled(model.isInteractionLocked)
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if !isBusy {
                activeActionTarget = nil
            }
        }
        .onChange(of: model.rootPath) {
            // A dialog must never carry a destructive file target across cwd.
            pendingDiscard = nil
            pendingDiscardAll = []
            confirmDiscardAll = false
            showBranchCreator = false
            newBranchName = ""
            isPendingAICommit = false
            activeActionTarget = nil
            checkedPaths.removeAll()
            knownPaths.removeAll()
            updateSimpleSelection()
        }
        .onChange(of: model.repositoryIdentity) {
            resetRepositoryDrafts()
        }
        .onChange(of: model.stagedEntries) { _, _ in
            updateSimpleSelection()
        }
        .onChange(of: model.changedEntries) { _, _ in
            updateSimpleSelection()
        }
        .onAppear {
            updateSimpleSelection()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if model.isRepo {
                branchMenu
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(SidebarTypography.secondary(.medium))
                    .foregroundStyle(Color(nsColor: Theme.cursor))
                PanelHeader(title: L10n.t("Git"), subtitle: model.rootPath, isSubtitlePath: true)
            }
            if model.isRepo {
                SidebarIconButton(
                    systemImage: "line.3.horizontal.decrease",
                    help: L10n.t("Filter Changed Files"),
                    active: showFilter
                ) {
                    showFilter.toggle()
                    if !showFilter { filterText = "" }
                }
                SidebarRefreshButton(
                    isRefreshing: model.isBusy || model.isResolvingInitialStatus || model.isSwitchingRoot
                ) {
                    // 手动刷新 = 兜底强制刷新：作废在飞扫描、修复 fsmonitor、
                    // 绕开 actor 队列全量重扫，解决各种「普通刷新无效」的异常。
                    model.forceRefresh()
                }
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // Git 面板 Header 空白区域允许拖拽移动窗口
        .background { WindowDragArea() }
    }

    private var branchMenu: some View {
        Menu {
            if !model.branches.isEmpty {
                ForEach(model.branches, id: \.self) { branch in
                    Button {
                        beginGitAction(.branchMenu) {
                            model.switchBranch(to: branch)
                        }
                    } label: {
                        if branch == model.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == model.branch || model.isInteractionLocked)
                }
                Divider()
            }
            Button(L10n.t("Create New Branch…")) {
                newBranchName = ""
                showBranchCreator = true
                DispatchQueue.main.async { branchFieldFocused = true }
            }
            .disabled(model.isInteractionLocked)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: "arrow.triangle.branch")
                        .font(SidebarTypography.secondary(.medium))
                        .foregroundStyle(Color(nsColor: Theme.cursor))
                        .opacity(activeActionTarget == .branchMenu ? 0 : 1)
                    if activeActionTarget == .branchMenu {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 11, height: 11)
                            .accessibilityHidden(true)
                    }
                }
                PanelHeader(title: model.branch ?? "Detached HEAD", subtitle: model.rootPath, isSubtitlePath: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macTooltip(L10n.t("Switch or Create Branch"), position: .bottom)
        .accessibilityLabel("Current branch, \(model.branch ?? "detached HEAD")")
    }

    private var moreMenu: some View {
        SidebarMenuIconButton(
            systemImage: "ellipsis",
            help: L10n.t("More Actions…"),
            showsProgress: activeActionTarget == .moreMenu
        ) {
            Button(L10n.t("Fetch")) {
                beginGitAction(.moreMenu) { model.fetch() }
            }
            .disabled(model.isInteractionLocked || model.remotes.isEmpty)
            Button(L10n.t("Pull (Fast-forward Only)")) {
                beginGitAction(.moreMenu) { model.pull() }
            }
            .disabled(model.isInteractionLocked || !model.hasUpstream)
            if model.hasUpstream {
                Button(L10n.t("Push")) {
                    beginGitAction(.moreMenu) { model.push() }
                }
                .disabled(model.isInteractionLocked)
            } else if model.remotes.count > 1 {
                Menu(L10n.t("Publish Branch to")) {
                    ForEach(model.remotes, id: \.self) { remote in
                        Button(remote) {
                            beginGitAction(.moreMenu) { model.publish(to: remote) }
                        }
                    }
                }
                .disabled(model.isInteractionLocked || model.branch == "detached HEAD")
            } else {
                Button(L10n.t("Publish Branch")) {
                    beginGitAction(.moreMenu) { model.push() }
                }
                .disabled(model.isInteractionLocked || model.remotes.isEmpty || model.branch == "detached HEAD")
            }
            Button(L10n.t("Sync Changes")) {
                beginGitAction(.moreMenu) { model.syncChanges() }
            }
            .disabled(
                model.isInteractionLocked || model.remotes.isEmpty
                    || (!model.hasUpstream && model.remotes.count != 1)
                    || model.branch == "detached HEAD"
            )
            Divider()
            Button(L10n.t("Stash All Changes")) {
                beginGitAction(.moreMenu) { model.stash(includeUntracked: true) }
            }
            .disabled(model.isInteractionLocked || model.totalChangeCount == 0)
            Button(model.stashCount == 1 ? L10n.t("Pop Stash") : L10n.format("Pop Stash (%d)", model.stashCount)) {
                beginGitAction(.moreMenu) { model.stashPop() }
            }
            .disabled(model.isInteractionLocked || model.stashCount == 0)
            Divider()
            Button(L10n.t("Copy Changed Paths")) { copyChangedPaths() }
                .disabled(model.totalChangeCount == 0)
            Button(L10n.t("Copy Repository Path")) { copyToPasteboard(model.repoRoot) }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.repoRoot)])
            } label: {
                Label(L10n.t("Reveal Repository in Finder"), systemImage: "finder")
            }
            Divider()
            Button(L10n.t("Specify Git Repository Path…")) {
                selectCustomGitRepositoryPath()
            }
            .disabled(project == nil)
            if project?.customGitPath != nil {
                Button(L10n.t("Clear Custom Git Repository Path")) {
                    clearCustomGitRepositoryPath()
                }
                .disabled(project == nil)
            }
        }
    }

    @ViewBuilder
    private var trackingBar: some View {
        if let branch = model.branch {
            HStack(spacing: 5) {
                Image(systemName: model.hasUpstream ? "arrow.triangle.2.circlepath" : "icloud.slash")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
                Text(model.upstream ?? (branch == "detached HEAD" ? L10n.t("Detached HEAD") : L10n.t("Unpublished branch")))
                    .font(SidebarTypography.section())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if model.behind > 0 {
                    badge("↓\(model.behind)", label: "\(model.behind) incoming commits")
                }
                if model.ahead > 0 {
                    badge("↑\(model.ahead)", label: "\(model.ahead) outgoing commits")
                }
            }
            .frame(height: SidebarTypography.rowMinHeight)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Repository and operation state

    @ViewBuilder
    private var repositoryOperationBanner: some View {
        if let current = model.repositoryOperation {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge")
                    .font(SidebarTypography.caption(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(current)
                        .font(SidebarTypography.caption(.medium))
                    Text(model.mergeEntries.isEmpty
                         ? L10n.t("Finish or abort from the terminal")
                         : "Resolve and stage \(model.mergeEntries.count) conflicted \(model.mergeEntries.count == 1 ? "file" : "files")")
                        .font(SidebarTypography.section())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(red: 0.74, green: 0.55, blue: 1.0))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.74, green: 0.55, blue: 1.0).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var operationBanner: some View {
        if let operation = model.operation {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    operationIcon(operation)
                    Text(operation.statusLabel)
                        .font(SidebarTypography.caption(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !operation.output.isEmpty {
                        GitChromeIconButton(
                            systemImage: "chevron.right",
                            help: operationExpanded
                                ? L10n.t("Hide Git Output")
                                : L10n.t("Show Git Output"),
                            rotationDegrees: operationExpanded ? 90 : 0
                        ) {
                            operationExpanded.toggle()
                        }
                    }
                    if !operation.isRunning {
                        GitChromeIconButton(
                            systemImage: "xmark",
                            help: L10n.t("Dismiss")
                        ) {
                            operationExpanded = false
                            model.dismissOperation()
                        }
                        .accessibilityLabel(L10n.t("Dismiss Git Result"))
                    }
                }
                if operationExpanded, !operation.output.isEmpty {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Text(operation.output)
                            .font(SidebarTypography.micro(.regular, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 96)
                    .accessibilityLabel(L10n.t("Git Output"))
                }
            }
            .foregroundStyle(operationColor(operation))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(operationColor(operation).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
    }

    @ViewBuilder
    private func operationIcon(_ operation: GitStatusModel.Operation) -> some View {
        switch operation.state {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 11, height: 11)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").font(SidebarTypography.caption())
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(SidebarTypography.caption())
        }
    }

    private func operationColor(_ operation: GitStatusModel.Operation) -> Color {
        switch operation.state {
        case .running: return Color(nsColor: Theme.cursor)
        case .succeeded: return Color(red: 0.25, green: 0.68, blue: 0.33)
        case .failed: return Color(red: 0.88, green: 0.42, blue: 0.36)
        }
    }

    @ViewBuilder
    private var branchCreator: some View {
        if showBranchCreator {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.secondary)
                TextField(L10n.t("New branch name"), text: $newBranchName)
                    .textFieldStyle(.plain)
                    .font(SidebarTypography.secondary())
                    .focused($branchFieldFocused)
                    .onSubmit(createBranch)
                    .onKeyPress(.escape) {
                        showBranchCreator = false
                        return .handled
                    }
                Button(L10n.t("Create"), action: createBranch)
                    .buttonStyle(.borderless)
                    .font(SidebarTypography.caption(.medium))
                    .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isInteractionLocked)
                    .macTooltip(L10n.t("Create New Branch…"), position: .top)
                GitChromeIconButton(
                    systemImage: "xmark",
                    help: L10n.t("Cancel")
                ) {
                    showBranchCreator = false
                }
                .accessibilityLabel(L10n.t("Cancel Branch Creation"))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: Theme.cursor).opacity(0.45))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private func createBranch() {
        let name = newBranchName
        model.createBranch(named: name) { success in
            guard success else { return }
            newBranchName = ""
            showBranchCreator = false
        }
    }

    // MARK: Commit box

    private var commitBox: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                GitCommitMessageEditor(
                    text: $commitMessage,
                    placeholder: commitFieldPlaceholder,
                    onCommit: performPrimaryAction
                )
                .frame(minHeight: 36, maxHeight: 72)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )

                // Message 右侧 AI 生成按钮（sparkles.2）
                aiCommitMessageButton
            }

            if let error = aiCommitTasks.state(for: model.repoRoot).lastError, !error.isEmpty {
                Text(error)
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }

            HStack(spacing: 4) {
                actionButton(
                    icon: "checkmark",
                    title: commitButtonTitle,
                    enabled: canCommit(includeAll: false),
                    help: L10n.t("Commit staged changes"),
                    shortcut: "⌘↩",
                    showsProgress: activeActionTarget == .commit,
                    action: performPrimaryAction
                )
                commitMenu
            }

            if showSyncButton {
                actionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncButtonTitle,
                    enabled: !model.isInteractionLocked,
                    help: L10n.t("Pull remote commits, then push local ones"),
                    showsProgress: activeActionTarget == .sync,
                    action: performSync
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onChange(of: aiCommitTasks.states[aiCommitRepoKey]?.lastMessage) { _, newMessage in
            // 成功生成后写入 Message 输入框
            guard let newMessage, !newMessage.isEmpty else { return }
            if let consumed = aiCommitTasks.consumeMessage(model.repoRoot) {
                commitMessage = consumed
                if isPendingAICommit {
                    isPendingAICommit = false
                    if settings.gitOperationMode == .simple {
                        performSimpleCommit(amend: false)
                    } else {
                        performCommit(includeAll: false)
                    }
                }
            }
        }
        .onChange(of: aiCommitTasks.states[aiCommitRepoKey]?.isRunning) { _, isRunning in
            if isRunning == false && isPendingAICommit {
                let state = aiCommitTasks.state(for: model.repoRoot)
                if state.lastMessage == nil || state.lastMessage?.isEmpty == true {
                    isPendingAICommit = false
                }
            }
        }
    }

    /// 规范化后的仓库 key，与 TaskStore 一致。
    private var aiCommitRepoKey: String {
        (model.repoRoot as NSString).standardizingPath
    }

    /// 当前是否可发起 AI Commit Message（有变更、有仓库、未忙）。
    private var canGenerateAICommitMessage: Bool {
        model.isRepo
            && !model.repoRoot.isEmpty
            && !model.isInteractionLocked
            && !aiCommitTasks.isRunning(model.repoRoot)
            && (model.totalChangeCount > 0 || !model.stagedEntries.isEmpty || !model.changedEntries.isEmpty)
    }

    /// Message 旁的 AI 按钮：进行中显示取消，否则 sparkles.2。
    private var aiCommitMessageButton: some View {
        let running = aiCommitTasks.isRunning(model.repoRoot)
        let enabled = running || (LocalAI.isEnabled && canGenerateAICommitMessage)
        let helpText = running
            ? L10n.t("Cancel AI Commit Message")
            : (LocalAI.isEnabled
                ? L10n.t("Generate commit message with AI")
                : L10n.t("Configure an AI provider in Settings → AI"))
        return GitChromeIconButton(
            systemImage: "sparkles.2",
            help: helpText,
            disabled: !running && (!LocalAI.isEnabled || !canGenerateAICommitMessage),
            isProminent: enabled,
            side: 28,
            cornerRadius: 6,
            showsProgress: running,
            idleBackgroundOpacity: 0.06
        ) {
            if running {
                aiCommitTasks.cancel(model.repoRoot, clearError: true)
            } else {
                startAICommitMessage()
            }
        }
        .accessibilityLabel(
            running ? L10n.t("Cancel AI Commit Message") : L10n.t("AI Commit Message")
        )
    }

    /// 启动 AI 生成 commit message（全局语言 + 项目覆盖 + Gitmoji 开关）。
    private func startAICommitMessage() {
        guard model.isRepo, !model.repoRoot.isEmpty else { return }
        aiCommitTasks.clearError(model.repoRoot)
        let language = project?.resolvedAIWritingLanguage ?? settings.aiWritingLanguage

        let targetPaths: [String]?
        if settings.gitOperationMode == .simple {
            let simplePaths = Set(allSimpleEntries.map(\.path))
            let checked = checkedPaths.filter { simplePaths.contains($0) }
            targetPaths = checked.isEmpty ? nil : Array(checked)
        } else {
            targetPaths = nil
        }

        aiCommitTasks.start(
            repoRoot: model.repoRoot,
            targetPaths: targetPaths,
            language: language,
            useEmoji: settings.gitCommitMessageEmoji
        )
    }

    private var commitMenu: some View {
        GitChromeMenuButton(
            systemImage: "chevron.down",
            help: L10n.t("Commit Options"),
            side: 28,
            cornerRadius: 6,
            idleBackgroundOpacity: 0.06,
            showsProgress: activeActionTarget == .commitMenu
        ) {
            if settings.gitOperationMode == .simple {
                Button(L10n.t("Commit Selected")) { performSimpleCommit(amend: false, trigger: .commitMenu) }
                    .disabled(!canCommit(includeAll: false))
                Divider()
                Button(L10n.t("AI Complete Changes Commit")) { performAICompleteChangesCommit() }
                    .disabled(!canAICompleteChangesCommit)
                Divider()
                Button(L10n.t("Amend Last Commit")) { performSimpleCommit(amend: true, trigger: .commitMenu) }
                    .disabled(!canAmend(includeAll: false))
            } else {
                Button(L10n.t("Commit Staged")) { performCommit(includeAll: false, trigger: .commitMenu) }
                    .disabled(!canCommit(includeAll: false))
                Button(L10n.t("Stage All & Commit")) { performCommit(includeAll: true, trigger: .commitMenu) }
                    .disabled(!canCommit(includeAll: true))
                Divider()
                Button(L10n.t("AI Complete Changes Commit")) { performAICompleteChangesCommit() }
                    .disabled(!canAICompleteChangesCommit)
                Divider()
                Button(L10n.t("Amend Last Commit")) { performCommit(includeAll: false, amend: true, trigger: .commitMenu) }
                    .disabled(!canAmend(includeAll: false))
                Button(L10n.t("Stage All & Amend")) { performCommit(includeAll: true, amend: true, trigger: .commitMenu) }
                    .disabled(!canAmend(includeAll: true))
            }
        }
    }

    /// 是否可以发起 AI 完成变更提交（有仓库、未忙、开启 AI、无进行中 AI 任务、有变更且无冲突）。
    private var canAICompleteChangesCommit: Bool {
        model.isRepo
            && !model.repoRoot.isEmpty
            && !model.isInteractionLocked
            && LocalAI.isEnabled
            && !aiCommitTasks.isRunning(model.repoRoot)
            && (model.totalChangeCount > 0 || !model.stagedEntries.isEmpty || !model.changedEntries.isEmpty)
            && model.mergeEntries.isEmpty
    }

    /// 执行 AI 完成变更提交：先全选/暂存，然后 AI 生成 Commit Message，成功后自动提交。
    private func performAICompleteChangesCommit() {
        guard canAICompleteChangesCommit else { return }
        isPendingAICommit = true
        if settings.gitOperationMode == .simple {
            for entry in allSimpleEntries {
                checkedPaths.insert(entry.path)
            }
            startAICommitMessage()
        } else {
            beginGitAction(.stageAll) {
                model.stageAll { success in
                    guard success else {
                        isPendingAICommit = false
                        activeActionTarget = nil
                        return
                    }
                    startAICommitMessage()
                }
            }
        }
    }

    /// 设置操作进度 target 后调用 model；若 model 早退（校验失败 / isBusy /
    /// failImmediately）从未进入 busy，立刻清掉 target，避免 spinner 永久卡住。
    /// 正常进入 busy 时仍由 `.onChange(of: model.isBusy)` 在结束时清除。
    /// 发起新操作时折叠上一个操作的输出展开区。
    private func beginGitAction(_ target: GitActionTarget, _ work: () -> Void) {
        operationExpanded = false
        activeActionTarget = target
        work()
        if !model.isBusy {
            activeActionTarget = nil
        }
    }

    private func actionButton(
        icon: String, title: String, enabled: Bool, help: String,
        shortcut: String? = nil,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        GitPrimaryActionButton(
            icon: icon,
            title: title,
            enabled: enabled,
            help: help,
            shortcut: shortcut,
            showsProgress: showsProgress,
            action: action
        )
    }

    private func performSync() {
        guard !model.isBusy else { return }
        beginGitAction(.sync) {
            model.syncChanges()
        }
    }

    private var commitFieldPlaceholder: String {
        if settings.gitOperationMode == .simple {
            if checkedEntriesCount == 0 {
                return L10n.t("Message (select changes to use ⌘⏎)")
            }
            if let branch = model.branch {
                return L10n.format("Message (⌘⏎ to commit on \"%@\")", branch)
            }
            return L10n.t("Message (⌘⏎ to commit)")
        }
        if model.stagedEntries.isEmpty {
            return model.recentCommits.isEmpty
                ? L10n.t("Message (stage changes to use ⌘⏎)")
                : L10n.t("Message (stage changes to use ⌘⏎, or choose Amend)")
        }
        if let branch = model.branch {
            return L10n.format("Message (⌘⏎ to commit on \"%@\")", branch)
        }
        return L10n.t("Message (⌘⏎ to commit)")
    }

    private var showSyncButton: Bool {
        model.totalChangeCount == 0 && (model.ahead > 0 || model.behind > 0)
    }

    private var syncButtonTitle: String {
        var title = L10n.t("Sync Changes")
        if model.behind > 0 { title += " \(model.behind)↓" }
        if model.ahead > 0 { title += " \(model.ahead)↑" }
        return title
    }

    private var commitButtonTitle: String {
        if settings.gitOperationMode == .simple {
            let count = checkedEntriesCount
            if count == 1 { return L10n.t("Commit 1 File") }
            if count > 1 {
                return L10n.format("Commit %d Files", count)
            }
            return L10n.t("Commit")
        }
        if model.stagedEntries.count == 1 { return L10n.t("Commit 1 Staged File") }
        if model.stagedEntries.count > 1 {
            return L10n.format("Commit %d Staged Files", model.stagedEntries.count)
        }
        return L10n.t("Commit Staged")
    }

    private func canCommit(includeAll: Bool) -> Bool {
        if settings.gitOperationMode == .simple {
            return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && checkedEntriesCount > 0
                && model.mergeEntries.isEmpty
                && !model.isInteractionLocked
        }
        let hasEligibleChanges = includeAll
            ? (!model.changedEntries.isEmpty || !model.stagedEntries.isEmpty)
            : !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isInteractionLocked
    }

    private func canAmend(includeAll: Bool) -> Bool {
        let hasCommit = !model.recentCommits.isEmpty
        let hasEligibleChanges = (settings.gitOperationMode == .simple)
            ? !allSimpleEntries.isEmpty
            : (!includeAll || !model.changedEntries.isEmpty || !model.stagedEntries.isEmpty)
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommit
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isInteractionLocked
    }

    private func performPrimaryAction() {
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if settings.gitOperationMode == .simple {
            performSimpleCommit()
            return
        }
        if !model.stagedEntries.isEmpty {
            performCommit(includeAll: false)
        } else if !model.changedEntries.isEmpty {
            performCommit(includeAll: true)
        }
    }

    private func performSimpleCommit(amend: Bool = false, trigger: GitActionTarget = .commit) {
        let all = allSimpleEntries
        let checked = all.filter { checkedPaths.contains($0.path) }
        let unchecked = all.filter { !checkedPaths.contains($0.path) }
        beginGitAction(trigger) {
            model.commitSimple(
                message: commitMessage,
                checkedEntries: checked,
                uncheckedEntries: unchecked,
                amend: amend
            ) { success in
                if success {
                    commitMessage = ""
                }
            }
        }
    }

    private func performCommit(includeAll: Bool, amend: Bool = false, trigger: GitActionTarget = .commit) {
        guard amend ? canAmend(includeAll: includeAll) : canCommit(includeAll: includeAll) else { return }
        let submittedMessage = commitMessage
        beginGitAction(trigger) {
            model.commit(message: submittedMessage, includeAll: includeAll, amend: amend) { success in
                if success, commitMessage == submittedMessage { commitMessage = "" }
            }
        }
    }

    // MARK: Filter

    @ViewBuilder
    private var filterBar: some View {
        if showFilter {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.tertiary)
                TextField(L10n.t("Filter changed files"), text: $filterText)
                    .textFieldStyle(.plain)
                    .font(SidebarTypography.secondary())
                if !filterText.isEmpty {
                    GitChromeIconButton(
                        systemImage: "xmark.circle.fill",
                        help: L10n.t("Clear Filter"),
                        side: 18,
                        cornerRadius: 4,
                        font: SidebarTypography.caption(),
                        idleForeground: Color.secondary.opacity(0.75)
                    ) {
                        filterText = ""
                    }
                    .accessibilityLabel(L10n.t("Clear Git Filter"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.045))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: Change list

    /// 变更列表。过滤结果与行渲染均在本次 body 求值内一次性计算：
    /// 行必须作为外层 `LazyVStack` 的**直接子视图**（而非再包一层非懒加载的
    /// `VStack`），否则所有行会被一次性创建布局，数万条变更时主线程直接冻结。
    private func changeList() -> some View {
        let merge = filteredMergeEntries
        let staged = filteredStagedEntries
        let changed = filteredChangedEntries
        let simple = filteredSimpleEntries
        let isSimpleMode = (settings.gitOperationMode == .simple)
        let hasChanges = model.totalChangeCount > 0
        let visibleCount = isSimpleMode ? (merge.count + simple.count) : (merge.count + staged.count + changed.count)

        return GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if model.isSwitchingRoot {
                            switchingBanner
                        }
                        if model.statusLimitHit {
                            limitBanner
                        }
                        if !hasChanges {
                            cleanState
                        } else if visibleCount == 0 {
                            inlinePlaceholder(icon: "line.3.horizontal.decrease", text: L10n.format("No changed files match “%@”", filterText))
                        }
                        if !merge.isEmpty {
                            SidebarSectionHeader(
                                title: L10n.t("MERGE CHANGES"),
                                count: merge.count,
                                isCollapsed: $mergeCollapsed,
                                actions: [],
                                actionsDisabled: model.isInteractionLocked
                            )
                            if !mergeCollapsed {
                                // 行直接挂在 LazyVStack 下，惰性渲染；左边距逐行施加
                                ForEach(merge, id: \.mergeRowID) { entry in
                                    row(entry, status: "U", kind: .merge)
                                        .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
                                }
                            }
                        }
                        if isSimpleMode {
                            if !simple.isEmpty {
                                let allSelected = !simple.isEmpty && simple.allSatisfy { checkedPaths.contains($0.path) }
                                SidebarSectionHeader(
                                    title: L10n.t("CHANGES"),
                                    count: simple.count,
                                    isCollapsed: $changesCollapsed,
                                    actions: filterText.isEmpty ? [
                                        .init(
                                            systemImage: "arrow.uturn.backward",
                                            help: L10n.t("Discard All Changes"),
                                            disabled: model.isInteractionLocked,
                                            showsProgress: activeActionTarget == .discardAll
                                        ) {
                                            requestDiscardAll()
                                        },
                                        .init(
                                            systemImage: allSelected ? "checkmark.square.fill" : "square",
                                            help: allSelected ? L10n.t("Deselect All") : L10n.t("Select All"),
                                            disabled: model.isInteractionLocked,
                                            activeColor: allSelected ? Color(nsColor: Theme.cursor) : nil
                                        ) {
                                            if allSelected {
                                                for entry in simple {
                                                    checkedPaths.remove(entry.path)
                                                }
                                            } else {
                                                for entry in simple {
                                                    checkedPaths.insert(entry.path)
                                                }
                                            }
                                        }
                                    ] : [],
                                    actionsDisabled: model.isInteractionLocked
                                )
                                if !changesCollapsed {
                                    ForEach(simple, id: \.changedRowID) { entry in
                                        let statusChar: Character = (entry.staged != "." && entry.staged != "?") ? entry.staged : entry.unstaged
                                        row(entry, status: statusChar, kind: .simple)
                                            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
                                    }
                                }
                            }
                        } else {
                            if !staged.isEmpty {
                                SidebarSectionHeader(
                                    title: L10n.t("STAGED CHANGES"),
                                    count: staged.count,
                                    isCollapsed: $stagedCollapsed,
                                    actions: filterText.isEmpty ? [
                                        .init(
                                            systemImage: "minus",
                                            help: L10n.t("Unstage All Changes"),
                                            disabled: model.isInteractionLocked,
                                            showsProgress: activeActionTarget == .unstageAll
                                        ) {
                                            beginGitAction(.unstageAll) {
                                                model.unstageAll()
                                            }
                                        }
                                    ] : [],
                                    actionsDisabled: model.isInteractionLocked
                                )
                                if !stagedCollapsed {
                                    ForEach(staged, id: \.stagedRowID) { entry in
                                        row(entry, status: entry.staged, kind: .staged)
                                            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
                                    }
                                }
                            }
                            if !changed.isEmpty {
                                SidebarSectionHeader(
                                    title: L10n.t("CHANGES"),
                                    count: changed.count,
                                    isCollapsed: $changesCollapsed,
                                    actions: filterText.isEmpty ? [
                                        .init(
                                            systemImage: "arrow.uturn.backward",
                                            help: L10n.t("Discard All Changes"),
                                            disabled: model.isInteractionLocked,
                                            showsProgress: activeActionTarget == .discardAll
                                        ) {
                                            requestDiscardAll()
                                        },
                                        .init(
                                            systemImage: "plus",
                                            help: L10n.t("Stage All Changes"),
                                            disabled: model.isInteractionLocked,
                                            showsProgress: activeActionTarget == .stageAll
                                        ) {
                                            beginGitAction(.stageAll) {
                                                model.stageAll()
                                            }
                                        },
                                    ] : [],
                                    actionsDisabled: model.isInteractionLocked
                                )
                                if !changesCollapsed {
                                    ForEach(changed, id: \.changedRowID) { entry in
                                        row(entry, status: entry.unstaged, kind: .unstaged)
                                            .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
                                    }
                                }
                            }
                        }
                        if filterText.isEmpty, !model.recentCommits.isEmpty {
                            SidebarSectionHeader(
                                title: L10n.t("RECENT COMMITS"),
                                count: model.recentCommits.count,
                                isCollapsed: $historyCollapsed,
                                actions: [],
                                actionsDisabled: model.isInteractionLocked
                            )
                            if !historyCollapsed {
                                ForEach(Array(model.recentCommits.enumerated()), id: \.element.id) { index, commit in
                                    GitCommitRow(
                                        commit: commit,
                                        isHead: index == 0,
                                        isLastCommit: index == model.recentCommits.count - 1,
                                        repoRoot: model.repoRoot,
                                        disabled: model.isInteractionLocked,
                                        hasStagedChanges: !model.stagedEntries.isEmpty,
                                        canAICommitMessage: LocalAI.isEnabled
                                            && canGenerateAICommitMessage,
                                        isAICommitRunning: aiCommitTasks.isRunning(model.repoRoot),
                                        isExpanded: expandedCommitIDs.contains(commit.hash),
                                        onToggleExpand: {
                                            if expandedCommitIDs.contains(commit.hash) {
                                                expandedCommitIDs.remove(commit.hash)
                                            } else {
                                                expandedCommitIDs.insert(commit.hash)
                                            }
                                        },
                                        onOpenCommitDiff: { file in
                                            openCommitDiff(commit, file)
                                        },
                                        onAICommitMessage: {
                                            startAICommitMessage()
                                        },
                                        onCancelAICommitMessage: {
                                            aiCommitTasks.cancel(model.repoRoot, clearError: true)
                                        },
                                        onRefreshNeeded: {
                                            model.refresh()
                                        }
                                    )
                                    .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
                                }
                                if model.hasMoreRecentCommits {
                                    Button {
                                        model.loadMoreCommits()
                                    } label: {
                                        HStack(spacing: 5) {
                                            if model.isLoadingMoreCommits {
                                                ProgressView()
                                                    .controlSize(.mini)
                                                    .accessibilityHidden(true)
                                            }
                                            Text(L10n.t("Load More"))
                                                .font(SidebarTypography.section(.medium))
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                                    .disabled(model.isLoadingMoreCommits || model.isInteractionLocked)
                                    // 滚动自动加载：LazyVStack 中按钮进入视口时触发；
                                    // 每次加载完成（commits 数量变化）后若仍可见则继续，
                                    // 直到填满视口或没有更多。loadMoreCommits 内部有幂等守卫。
                                    .task(id: model.recentCommits.count) {
                                        guard model.hasMoreRecentCommits else { return }
                                        model.loadMoreCommits()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)

                    // 填满 Git 面板底部剩余空白区域，允许拖拽移动窗口
                    WindowDragArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 20)
                }
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    private var allSimpleEntries: [GitStatusModel.Entry] {
        var result: [GitStatusModel.Entry] = []
        var seen = Set<String>()
        for entry in model.stagedEntries {
            if seen.insert(entry.path).inserted {
                result.append(entry)
            }
        }
        for entry in model.changedEntries {
            if seen.insert(entry.path).inserted {
                result.append(entry)
            }
        }
        return result
    }

    private var filteredSimpleEntries: [GitStatusModel.Entry] {
        allSimpleEntries.filter(matchesFilter)
    }

    private var checkedEntriesCount: Int {
        allSimpleEntries.filter { checkedPaths.contains($0.path) }.count
    }

    private func updateSimpleSelection() {
        let entries = allSimpleEntries
        let currentPaths = Set(entries.map(\.path))
        checkedPaths.formIntersection(currentPaths)
        knownPaths.formIntersection(currentPaths)
        for entry in entries {
            if !knownPaths.contains(entry.path) {
                knownPaths.insert(entry.path)
                checkedPaths.insert(entry.path)
            }
        }
    }

    private var filteredMergeEntries: [GitStatusModel.Entry] {
        model.mergeEntries.filter(matchesFilter)
    }

    private var filteredStagedEntries: [GitStatusModel.Entry] {
        model.stagedEntries.filter(matchesFilter)
    }

    private var filteredChangedEntries: [GitStatusModel.Entry] {
        model.changedEntries.filter(matchesFilter)
    }

    private func matchesFilter(_ entry: GitStatusModel.Entry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)
    }

    private var cleanState: some View {
        inlinePlaceholder(
            icon: model.ahead > 0 || model.behind > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle",
            text: model.ahead > 0 || model.behind > 0 ? "Working tree clean, sync is pending" : "Working tree clean"
        )
    }

    /// 仓库根切换中（stale-while-revalidate）：旧内容保留展示，提示正在刷新。
    private var switchingBanner: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(L10n.t("Refreshing repository…"))
                .font(SidebarTypography.caption())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    /// 超大仓库：变更条目达到上限，仅显示前 N 条。
    private var limitBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(SidebarTypography.caption())
            Text(L10n.format(
                "Too many changes. Only the first %d are shown.",
                GitScanner.statusEntryLimit
            ))
            .font(SidebarTypography.caption().monospacedDigit())
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.82, green: 0.60, blue: 0.13).opacity(0.08))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(
        _ entry: GitStatusModel.Entry, status: Character, kind: GitEntryRow.Kind
    ) -> some View {
        let isSimple = (kind == .simple)
        return GitEntryRow(
            entry: entry,
            status: status,
            kind: kind,
            disabled: model.isInteractionLocked,
            activeTarget: activeActionTarget,
            isCheckable: isSimple,
            isChecked: checkedPaths.contains(entry.path),
            onToggleCheck: {
                if checkedPaths.contains(entry.path) {
                    checkedPaths.remove(entry.path)
                } else {
                    checkedPaths.insert(entry.path)
                }
            },
            openDiff: {
                guard model.isCurrent(entry) else { return }
                if entry.isDirectoryEntry {
                    // 未跟踪目录条目没有 diff，VS Code 风格改为打开目录。
                    openDirectory(entry)
                    return
                }
                var diffEntry = entry
                if kind == .unstaged && (entry.staged == "R" || entry.staged == "C") {
                    // A staged rename/copy's unstaged side compares the
                    // destination in the index with that same worktree path.
                    diffEntry.origPath = nil
                }
                openDiff(diffEntry, kind == .staged)
            },
            openFile: {
                guard model.isCurrent(entry) else { return }
                if entry.isDirectoryEntry {
                    openDirectory(entry)
                    return
                }
                openIfPossible(entry)
            },
            openToSide: {
                guard model.isCurrent(entry) else { return }
                if entry.isDirectoryEntry {
                    openDirectory(entry)
                    return
                }
                openIfPossible(entry, toSide: true)
            },
            stage: {
                beginGitAction(.stage(path: entry.path)) {
                    model.stage(entry)
                }
            },
            unstage: {
                beginGitAction(.unstage(path: entry.path)) {
                    model.unstage(entry)
                }
            },
            discard: { pendingDiscard = makePendingDiscard(entry) },
            absolutePath: model.absolutePath(for: entry),
            copyRelativePath: { copyToPasteboard(entry.path) },
            insertInTerminal: session.map { session in
                { session.sendCommand(shellQuoted(model.absolutePath(for: entry)) + " ") }
            }
        )
    }

    private func openIfPossible(_ entry: GitStatusModel.Entry, toSide: Bool = false) {
        guard model.isCurrent(entry) else { return }
        let path = model.absolutePath(for: entry)
        guard FileManager.default.fileExists(atPath: path) else { return }
        if toSide {
            openToSide(path)
        } else {
            openFile(path)
        }
    }

    /// 打开未跟踪目录条目（VS Code 中未跟踪目录折叠为目录条目，无 diff）。
    private func openDirectory(_ entry: GitStatusModel.Entry) {
        let path = model.absolutePath(for: entry)
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func discardTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return "" }
        if entry.isUntracked {
            return L10n.format("Delete %@? Its contents will move to the Trash.", entry.fileName)
        }
        if entry.isWorktreeRename, let original = entry.origPath {
            return L10n.format(
                "Undo this rename? %@ will move to the Trash and %@ will be restored.",
                entry.fileName,
                (original as NSString).lastPathComponent
            )
        }
        if entry.isWorktreeCopy {
            return L10n.format("Discard this copy? %@ will move to the Trash.", entry.fileName)
        }
        return L10n.format("Discard changes in %@?", entry.fileName)
    }

    private func discardActionTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return L10n.t("Discard Changes") }
        if entry.isUntracked || entry.isWorktreeCopy { return L10n.t("Move to Trash") }
        if entry.isWorktreeRename { return L10n.t("Undo Rename") }
        return L10n.t("Discard Changes")
    }

    private func makePendingDiscard(_ entry: GitStatusModel.Entry) -> PendingDiscard {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath {
            paths.append(original)
        }
        return PendingDiscard(
            entry: entry,
            fingerprints: Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, fileFingerprint(at: absolutePath(path, for: entry)))
            }),
            branch: model.branch,
            headOID: model.headOID
        )
    }

    private func discardSnapshotIsCurrent(_ pending: PendingDiscard) -> Bool {
        model.isCurrent(pending.entry)
            && model.branch == pending.branch
            && model.headOID == pending.headOID
            && model.changedEntries.contains(pending.entry)
            && pending.fingerprints.allSatisfy { path, fingerprint in
                fileFingerprint(at: absolutePath(path, for: pending.entry)) == fingerprint
            }
    }

    private func absolutePath(_ path: String, for entry: GitStatusModel.Entry) -> String {
        let root = entry.repositoryRoot.isEmpty ? model.repoRoot : entry.repositoryRoot
        return (root as NSString).appendingPathComponent(path)
    }

    private func fileFingerprint(at path: String) -> FileFingerprint {
        let fm = FileManager.default
        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: path)
        guard linkDestination != nil || fm.fileExists(atPath: path) else {
            return FileFingerprint(
                exists: false, size: 0, modificationDate: nil,
                fileNumber: nil, symbolicLinkDestination: nil
            )
        }
        let attributes = try? fm.attributesOfItem(atPath: path)
        return FileFingerprint(
            exists: true,
            size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            symbolicLinkDestination: linkDestination
        )
    }

    private func requestDiscardAll() {
        let entries = (settings.gitOperationMode == .simple) ? allSimpleEntries : model.changedEntries
        pendingDiscardAll = entries.map(makePendingDiscard)
        confirmDiscardAll = !pendingDiscardAll.isEmpty
    }

    // MARK: Bits

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(.quaternary)
            Text(L10n.t(text))
                .font(SidebarTypography.secondary())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func inlinePlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(SidebarTypography.emptyInlineIcon())
                .foregroundStyle(.quaternary)
            Text(L10n.t(text))
                .font(SidebarTypography.caption())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }

    private var notRepository: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(.quaternary)
            VStack(spacing: 4) {
                Text(L10n.t("No Git Repository"))
                    .font(SidebarTypography.body(.medium))
                if let customGitPath = project?.customGitPath, project?.isValidCustomGitPath(customGitPath) == true {
                    Text(L10n.format("Specified path: %@", (customGitPath as NSString).lastPathComponent))
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    Text(L10n.t("Initialize the terminal’s current directory to start tracking changes."))
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            VStack(spacing: 8) {
                Button {
                    beginGitAction(.initializeRepository) {
                        model.initializeRepository()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if activeActionTarget == .initializeRepository {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                        Text(L10n.t("Initialize Repository"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Color(nsColor: Theme.cursor))
                .disabled(model.rootPath.isEmpty || model.isInteractionLocked)

                Button(L10n.t("Specify Git Repository Directory…")) {
                    selectCustomGitRepositoryPath()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(project == nil || model.isInteractionLocked)

                if project?.customGitPath != nil {
                    Button(L10n.t("Clear Custom Git Repository Path")) {
                        clearCustomGitRepositoryPath()
                    }
                    .buttonStyle(.plain)
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func selectCustomGitRepositoryPath() {
        guard let project else { return }
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = L10n.t("Select")
        openPanel.title = L10n.t("Select Git Repository Directory")

        let initialDir: String
        if let customGitPath = project.customGitPath, project.isValidCustomGitPath(customGitPath) {
            initialDir = customGitPath
        } else if !project.projectDirectory.isEmpty, FileManager.default.fileExists(atPath: project.projectDirectory) {
            initialDir = project.projectDirectory
        } else {
            initialDir = NSHomeDirectory()
        }
        openPanel.directoryURL = URL(fileURLWithPath: initialDir, isDirectory: true)

        openPanel.begin { response in
            guard response == .OK, let selectedURL = openPanel.url else { return }
            let selectedPath = selectedURL.path

            if project.isValidCustomGitPath(selectedPath) {
                project.customGitPath = selectedPath
                model.sync(root: selectedPath)
            } else {
                let alert = NSAlert()
                alert.messageText = L10n.t("Invalid Git Repository Path")
                alert.informativeText = L10n.t("The selected directory must be within the project directory.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: L10n.t("OK"))
                alert.runModal()
            }
        }
    }

    private func clearCustomGitRepositoryPath() {
        guard let project else { return }
        project.customGitPath = nil
        model.sync(root: project.gitRoot(followingSessionAt: session?.currentDirectoryPath ?? ""))
    }

    private func statusFailure(_ message: String?) -> some View {
        VStack(spacing: 9) {
            Spacer(minLength: 8)
            Image(systemName: "exclamationmark.triangle")
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
            VStack(spacing: 6) {
                Text(
                    model.isRecovering
                        ? L10n.t("Recovering Git Status…")
                        : L10n.t("Git Status Unavailable")
                )
                .font(SidebarTypography.body(.medium))
                if let message, !message.isEmpty {
                    // 诊断文案可能含多行（命令 / 目录 / exit / recovery steps）；
                    // 可滚动 + 可选中复制，避免截断后无法排查。
                    ScrollView {
                        Text(message)
                            .font(SidebarTypography.caption(design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                } else if model.isRecovering {
                    Text(L10n.t("Repairing fsmonitor and rescanning the repository…"))
                        .font(SidebarTypography.caption())
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            Button {
                model.forceRefresh()
            } label: {
                HStack(spacing: 6) {
                    if model.isRecovering {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.isRecovering ? L10n.t("Recovering…") : L10n.t("Retry"))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // 恢复中允许再次点击以抢占卡住的 recovery；仅真实 git 操作时禁用。
            .disabled(model.isBusy && !model.isRecovering)
            .help(
                model.isRecovering
                    ? L10n.t("Recovering Git status… Click again to restart recovery.")
                    : L10n.t("Retry from scratch: repair fsmonitor and rescan.")
            )
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String, label: String) -> some View {
        Text(text)
            .font(SidebarTypography.caption(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .accessibilityLabel(label)
    }

    private func copyChangedPaths() {
        let paths = Set(
            (model.mergeEntries + model.stagedEntries + model.changedEntries).map(\.path)
        ).sorted()
        copyToPasteboard(paths.joined(separator: "\n"))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resetRepositoryDrafts() {
        commitMessage = ""
        filterText = ""
        showFilter = false
        newBranchName = ""
        showBranchCreator = false
        operationExpanded = false
        pendingDiscard = nil
        pendingDiscardAll = []
        confirmDiscardAll = false
        mergeCollapsed = false
        stagedCollapsed = false
        changesCollapsed = false
        historyCollapsed = true
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Git chrome controls (hover + Tooltip)

/// Git 面板主操作按钮（Commit / Sync）：hover 提亮，并显示 macTooltip，支持工作中转圈。
private struct GitPrimaryActionButton: View {
    let icon: String
    let title: String
    let enabled: Bool
    let help: String
    var shortcut: String? = nil
    var showsProgress: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(SidebarTypography.caption(.semibold))
                }
                Text(title)
                    .font(SidebarTypography.secondary(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: Theme.cursor).opacity(fillOpacity))
            )
            .foregroundStyle(.white.opacity((enabled && !showsProgress) ? 1 : 0.85))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || showsProgress)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .macTooltip((enabled && !showsProgress) ? help : nil, shortcut: shortcut, position: .top)
        .accessibilityLabel(
            showsProgress ? L10n.format("%@, in progress", title) : title
        )
        .accessibilityHint(help)
    }

    private var fillOpacity: Double {
        guard enabled && !showsProgress else { return 0.3 }
        return isHovering ? 1.0 : 0.85
    }
}

/// Git 面板图标按钮：统一 hover 浅底 / 前景提亮 + macTooltip。
private struct GitChromeIconButton: View {
    let systemImage: String
    let help: String
    var disabled: Bool = false
    var isProminent: Bool = false
    var side: CGFloat = 16
    var cornerRadius: CGFloat = 4
    var font: Font = SidebarTypography.compact()
    var rotationDegrees: Double = 0
    var showsProgress: Bool = false
    var idleBackgroundOpacity: Double = 0
    var idleForeground: Color = .secondary
    var tooltipPosition: MacTooltipPosition = .top
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: max(12, side - 14), height: max(12, side - 14))
                } else {
                    Image(systemName: systemImage)
                        .font(font)
                        .rotationEffect(.degrees(rotationDegrees))
                }
            }
            .frame(width: side, height: side)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: rotationDegrees)
        .macTooltip(help, position: tooltipPosition)
        .accessibilityLabel(help)
    }

    private var foreground: Color {
        if disabled {
            return idleForeground.opacity(0.45)
        }
        if isProminent {
            return Color(nsColor: Theme.cursor)
        }
        return isHovering ? .primary : idleForeground
    }

    private var backgroundFill: Color {
        if disabled {
            return Color.primary.opacity(idleBackgroundOpacity * 0.5)
        }
        if isHovering {
            return Color.primary.opacity(max(idleBackgroundOpacity + 0.06, 0.1))
        }
        return Color.primary.opacity(idleBackgroundOpacity)
    }
}

/// Git 面板菜单图标按钮：与 `GitChromeIconButton` 视觉一致。
private struct GitChromeMenuButton<Content: View>: View {
    let systemImage: String
    let help: String
    var side: CGFloat = 28
    var cornerRadius: CGFloat = 6
    var idleBackgroundOpacity: Double = 0.06
    /// 进行中时用 spinner 替换图标（如提交选项菜单）。
    var showsProgress: Bool = false
    var tooltipPosition: MacTooltipPosition = .top
    @ViewBuilder let menuContent: () -> Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            ZStack {
                if showsProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 11, height: 11)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: systemImage)
                        .font(SidebarTypography.compact())
                        .foregroundStyle(isHovering ? .primary : .secondary)
                }
            }
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        Color.primary.opacity(
                            isHovering
                                ? max(idleBackgroundOpacity + 0.06, 0.1)
                                : idleBackgroundOpacity
                        )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .macTooltip(help, position: tooltipPosition)
        .accessibilityLabel(help)
    }
}

private struct GitCommitRow: View {
    let commit: GitStatusModel.RecentCommit
    let isHead: Bool
    /// 是否为当前列表的最后一条（决定提交图竖线是否延续到行底）。
    let isLastCommit: Bool
    let repoRoot: String
    let disabled: Bool
    let hasStagedChanges: Bool
    /// 当前是否可生成 AI Commit Message（LocalAI 已启用且有变更）。
    let canAICommitMessage: Bool
    let isAICommitRunning: Bool
    /// 展开显示该提交改动的文件列表。
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    /// 点击展开列表中的某个文件：打开父→提交的历史 diff。
    let onOpenCommitDiff: (GitStatusModel.RecentCommit.FileChange) -> Void
    let onAICommitMessage: () -> Void
    let onCancelAICommitMessage: () -> Void
    let onRefreshNeeded: () -> Void

    @State private var showEditSheet = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                CommitGraphColumn(
                    isFirst: isHead,
                    continuesBelow: isExpanded || !isLastCommit,
                    isExpanded: isExpanded
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(commit.subject)
                            .font(SidebarTypography.body())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let reference = primaryReference {
                            referenceBadge(reference)
                        }
                        // 展开 / 收起指示：位于第一行（标题行）右侧。
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(SidebarTypography.micro(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 8)
                    }
                    HStack(spacing: 4) {
                        Text(commit.author)
                        Text("·")
                        Text(commit.relativeDate)
                        Spacer(minLength: 8)
                        // hash 右对齐到行尾，使用次级文本色。
                        Text(commit.shortHash)
                            .font(SidebarTypography.section(design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(SidebarTypography.section())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpand)

            if isExpanded {
                commitFiles
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L10n.t("Edit Commit…")) {
                showEditSheet = true
            }
            .disabled(disabled)

            if hasStagedChanges {
                Button(L10n.t("Amend Staged Changes into Commit")) {
                    Task {
                        _ = await GitCommitEditor.amendIntoCommit(
                            in: repoRoot,
                            commitHash: commit.hash,
                            isHead: isHead
                        )
                        onRefreshNeeded()
                    }
                }
                .disabled(disabled)
            }

            Button(L10n.t("Drop Commit"), role: .destructive) {
                Task {
                    _ = await GitCommitEditor.dropCommit(
                        in: repoRoot,
                        commitHash: commit.hash,
                        isHead: isHead
                    )
                    onRefreshNeeded()
                }
            }
            .disabled(disabled)

            Divider()

            // AI 根据当前工作区变更生成 Message，填入上方输入框
            if isAICommitRunning {
                Button {
                    onCancelAICommitMessage()
                } label: {
                    Label(L10n.t("Cancel AI Commit Message"), systemImage: "xmark.circle")
                }
            } else {
                Button {
                    onAICommitMessage()
                } label: {
                    Label(L10n.t("AI Commit Message"), systemImage: "sparkles.2")
                }
                .disabled(disabled || !canAICommitMessage)
            }

            Divider()

            Button(L10n.t("Copy Commit Hash")) { copy(commit.hash) }
            Button(L10n.t("Copy Commit Message")) { copy(commit.subject) }
        }
        .sheet(isPresented: $showEditSheet) {
            GitCommitEditSheet(
                repoRoot: repoRoot,
                commitHash: commit.hash,
                shortHash: commit.shortHash,
                isHead: isHead,
                onComplete: { success, _ in
                    if success {
                        onRefreshNeeded()
                    }
                }
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(commit.subject), \(commit.shortHash), by \(commit.author), \(commit.relativeDate)")
    }

    /// 展开后的文件变更列表：每行一个文件，点击打开父→提交的历史 diff。
    private var commitFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commit.files.enumerated()), id: \.element.id) { fileIndex, file in
                Button {
                    onOpenCommitDiff(file)
                } label: {
                    HStack(spacing: 5) {
                        FileRailColumn(
                            continuesBelow: fileIndex < commit.files.count - 1 || !isLastCommit
                        )
                        Image(systemName: statusIcon(file.status))
                            .font(SidebarTypography.micro(.medium))
                            .foregroundStyle(statusColor(file.status))
                        Text(file.fileName)
                            .font(SidebarTypography.section())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !file.directory.isEmpty {
                            Text(file.directory)
                                .font(SidebarTypography.micro())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .help(file.path)
            }
            if commit.files.isEmpty {
                HStack(spacing: 5) {
                    FileRailColumn(continuesBelow: !isLastCommit)
                    Text(L10n.t("No file changes"))
                        .font(SidebarTypography.section())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
        }
    }

    /// 主要引用徽章：优先带斜杠的分支引用（如 `origin/main`），其次 HEAD 指向；
    /// 与上游 RecentCommitsView 的 primaryReference 同规则。
    private var primaryReference: String? {
        commit.references.first {
            $0.contains("/") && !$0.hasPrefix("HEAD -> ") && !$0.contains("/HEAD")
        } ?? commit.references.first.map {
            $0.hasPrefix("HEAD -> ") ? String($0.dropFirst("HEAD -> ".count)) : $0
        }
    }

    private func referenceBadge(_ reference: String) -> some View {
        Text(reference)
            .font(SidebarTypography.micro(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color(nsColor: Theme.cursor)))
            .frame(maxWidth: 104)
    }

    private func statusIcon(_ status: Character) -> String {
        switch status {
        case "A": return "plus.circle"
        case "D": return "minus.circle"
        case "R": return "arrow.triangle.2.circlepath"
        case "C": return "doc.on.doc"
        case "U": return "exclamationmark.circle"
        default: return "pencil.circle"
        }
    }

    private func statusColor(_ status: Character) -> Color {
        switch status {
        case "A": return Color(red: 0.25, green: 0.73, blue: 0.31)
        case "D": return Color(red: 1.0, green: 0.48, blue: 0.45)
        default: return Color(nsColor: Theme.cursor)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 提交图列：垂直线 + 圆点。线与上游 RecentCommitsView 同规则——
/// 首行线从圆点开始，末行（不续）线到圆点为止，否则贯穿整行。
private struct CommitGraphColumn: View {
    let isFirst: Bool
    let continuesBelow: Bool
    let isExpanded: Bool

    private static let lineX: CGFloat = 10
    private static let lineWidth: CGFloat = 1.5
    /// 图列在头部 HStack 内部（垂直 padding 之外），线底距下一行内容顶的实际
    /// 空隙：本行 padding 下 4 + LazyVStack spacing 1 + 下行 padding 上 4 = 9pt；
    /// 展开时头部→文件区为 4 + 0 + 2 = 6pt。统一向下延伸 9pt 覆盖两种情况，
    /// 与下方起点重叠多画无影响（同色）。
    private static let rowGap: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let top = isFirst ? height / 2 : 0
            let bottom = continuesBelow ? height : height / 2
            let lineHeight = max(0, bottom - top) + (continuesBelow ? Self.rowGap : 0)
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: Theme.cursor).opacity(0.72))
                    .frame(width: Self.lineWidth, height: lineHeight)
                    .position(x: Self.lineX, y: top + lineHeight / 2)
                Circle()
                    .fill(Color(nsColor: Theme.cursor))
                    .frame(width: (isExpanded ? 10 : 8), height: (isExpanded ? 10 : 8))
                    .position(x: Self.lineX, y: height / 2)
            }
            .frame(width: 20, height: height)
        }
        .frame(width: 20)
    }
}

/// 文件行缩进 rail：嵌套在提交图右侧的延续线。
private struct FileRailColumn: View {
    let continuesBelow: Bool

    private static let lineX: CGFloat = 10
    private static let lineWidth: CGFloat = 1.5
    /// 文件行 rail 在文件行 HStack 内部（垂直 padding 之外）：文件行间空隙
    /// 2 + 0 + 2 = 4pt；最后文件行→下一提交行内容顶 2 + 1 + 4 = 7pt。
    /// 统一向下延伸 7pt 覆盖两种情况（重叠多画无影响）。
    private static let rowGap: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if continuesBelow {
                    Rectangle()
                        .fill(Color(nsColor: Theme.cursor).opacity(0.4))
                        .frame(
                            width: Self.lineWidth,
                            height: geo.size.height + Self.rowGap
                        )
                        .position(x: Self.lineX, y: (geo.size.height + Self.rowGap) / 2)
                }
            }
            .frame(width: 20, height: geo.size.height)
        }
        .frame(width: 20)
    }
}

private struct GitEntryRow: View {
    enum Kind {
        case merge, staged, unstaged, simple
    }

    let entry: GitStatusModel.Entry
    let status: Character
    let kind: Kind
    let disabled: Bool
    var activeTarget: GitActionTarget? = nil
    var isCheckable: Bool = false
    var isChecked: Bool = false
    var onToggleCheck: (() -> Void)? = nil
    let openDiff: () -> Void
    let openFile: () -> Void
    let openToSide: () -> Void
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void
    let absolutePath: String
    let copyRelativePath: () -> Void
    let insertInTerminal: (() -> Void)?

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button(action: openDiff) {
                HStack(spacing: 7) {
                    Text(String(status))
                        .font(SidebarTypography.caption(.bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .frame(width: 12)
                    // Git 变更行：未跟踪目录条目（尾斜杠）按目录显示文件夹图标。
                    MaterialFileIconView(
                        fileName: entry.fileName,
                        isDirectory: entry.isDirectoryEntry,
                        size: 14
                    )
                    Text(entry.fileName)
                        .font(SidebarTypography.body())
                        .foregroundStyle(.secondary)
                        .strikethrough(status == "D")
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !isHovering && !isFocused {
                        Text(entry.directory)
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: SidebarTypography.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .accessibilityLabel("\(entry.fileName), \(statusName)")
            .accessibilityHint(kind == .merge ? "Opens conflict changes" : "Opens changes")

            if !disabled || hasProgressInRow {
                hoverActions
                    .opacity(isHovering || isFocused || hasProgressInRow ? 1 : 0.55)
            }

            if isCheckable {
                Button {
                    onToggleCheck?()
                } label: {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(SidebarTypography.micro())
                        .foregroundStyle(
                            disabled
                                ? Theme.secondaryColor.opacity(0.35)
                                : (isChecked ? Color(nsColor: Theme.cursor) : Theme.secondaryColor)
                        )
                        .frame(width: 18, height: 18)
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .macTooltip(isChecked ? L10n.t("Deselect") : L10n.t("Select"), position: .top)
            }
        }
        // Fixed height so action buttons do not grow the dense file row.
        .frame(minHeight: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering || isFocused ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu { menu }
    }

    /// 当前行是否有任何动作正在工作中（转圈中）
    private var hasProgressInRow: Bool {
        activeTarget == .stage(path: entry.path)
            || activeTarget == .unstage(path: entry.path)
            || activeTarget == .discard(path: entry.path)
    }

    private var hoverActions: some View {
        HStack(spacing: 4) {
            switch kind {
            case .merge:
                rowButton(
                    "plus",
                    help: L10n.t("Mark Resolved (Stage)"),
                    showsProgress: activeTarget == .stage(path: entry.path),
                    action: stage
                )
            case .staged:
                rowButton(
                    "minus",
                    help: L10n.t("Unstage Changes"),
                    showsProgress: activeTarget == .unstage(path: entry.path),
                    action: unstage
                )
            case .unstaged, .simple:
                rowButton(
                    "arrow.uturn.backward",
                    help: L10n.t("Discard Changes"),
                    showsProgress: activeTarget == .discard(path: entry.path),
                    action: discard
                )
            }
        }
    }

    private func rowButton(
        _ systemImage: String, help: String, showsProgress: Bool = false, action: @escaping () -> Void
    ) -> some View {
        GitChromeIconButton(
            systemImage: systemImage,
            help: help,
            disabled: disabled || showsProgress,
            side: 18,
            cornerRadius: 4,
            font: SidebarTypography.micro(.semibold),
            showsProgress: showsProgress,
            tooltipPosition: .top
        ) {
            action()
        }
    }

    @ViewBuilder
    private var menu: some View {
        if kind == .merge {
            Button(L10n.t("Open Changes")) { openDiff() }
            Button(L10n.t("Open Conflicted File")) { openFile() }
        } else {
            Button(L10n.t("Open Changes")) { openDiff() }
            Button(L10n.t("Open File")) { openFile() }
        }
        Button(L10n.t("Open File to the Side")) { openToSide() }
        Divider()
        switch kind {
        case .merge:
            Button(L10n.t("Mark Resolved (Stage)")) { stage() }
                .disabled(disabled)
        case .staged:
            Button(L10n.t("Unstage Changes")) { unstage() }
                .disabled(disabled)
        case .unstaged:
            Button(L10n.t("Stage Changes")) { stage() }
                .disabled(disabled)
            Button(destructiveMenuTitle) { discard() }
                .disabled(disabled)
        case .simple:
            Button(destructiveMenuTitle) { discard() }
                .disabled(disabled)
        }
        Divider()
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
        } label: {
            Label(L10n.t("Reveal in Finder"), systemImage: "finder")
        }
        Button(L10n.t("Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(absolutePath, forType: .string)
        }
        Button(L10n.t("Copy Relative Path")) { copyRelativePath() }
        if let insertInTerminal {
            Button(L10n.t("Insert Absolute Path in Terminal")) { insertInTerminal() }
        }
    }

    private var statusName: String {
        switch status {
        case "M": return L10n.t("Modified")
        case "A": return L10n.t("Added")
        case "?": return L10n.t("Untracked")
        case "D": return L10n.t("Deleted")
        case "R": return L10n.t("Renamed")
        case "C": return L10n.t("Copied")
        case "U": return L10n.t("Conflict")
        default: return L10n.t("Changed")
        }
    }

    private var destructiveMenuTitle: String {
        if entry.isUntracked || entry.isWorktreeCopy { return L10n.t("Move to Trash…") }
        if entry.isWorktreeRename { return L10n.t("Undo Rename…") }
        return L10n.t("Discard Changes…")
    }

    private var statusColor: Color {
        switch status {
        case "M": return Color(red: 0.82, green: 0.60, blue: 0.13)
        case "A", "?": return Color(red: 0.25, green: 0.73, blue: 0.31)
        case "D": return Color(red: 1.0, green: 0.48, blue: 0.45)
        case "R", "C": return Color(red: 0.35, green: 0.65, blue: 1.0)
        case "U": return Color(red: 0.74, green: 0.55, blue: 1.0)
        default: return .secondary
        }
    }
}

// MARK: - Git Commit Message Editor (Auto-hiding scrollbar)

struct GitCommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let textView = GitCommitTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
            container.lineFragmentPadding = 0
        }
        textView.textContainerInset = NSSize(width: 6, height: 6)

        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.placeholderString = placeholder
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.allowsUndo = true

        textView.delegate = context.coordinator
        textView.onCommit = onCommit
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? GitCommitTextView else { return }
        // 输入法组合（marked text）期间不整段写回，避免打断组合与其撤销登记。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        textView.placeholderString = placeholder
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private class GitCommitTextView: NSTextView {
    /// 专用撤销管理器：不沿响应链共享窗口的 NSUndoManager。
    /// Git 提交信息编辑器随面板开关 / 提交完成频繁销毁重建，若与窗口共享撤销栈，
    /// 已销毁编辑器的悬垂撤销记录会在 ⌘Z 时触发崩溃（`_undoRedoTextOperation:`）。
    /// 每实例独享一个 UndoManager，随视图一起销毁，杜绝悬垂记录。
    private let undoManagerForText = UndoManager()

    override var undoManager: UndoManager? {
        allowsUndo ? undoManagerForText : nil
    }

    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // ⌘ + Return
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !placeholderString.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let rect = NSRect(
                x: textContainerInset.width,
                y: textContainerInset.height,
                width: bounds.width - textContainerInset.width * 2,
                height: bounds.height - textContainerInset.height * 2
            )
            placeholderString.draw(in: rect, withAttributes: attrs)
        }
    }
}
