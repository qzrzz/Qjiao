//
//  RightSidebarGitPanel.swift
//  kero
//

import AppKit
import SwiftUI

// MARK: - Git panel

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

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var aiCommitTasks = LocalAIGitCommitTaskStore.shared

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
    @FocusState private var branchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            operationBanner

            if let statusError = model.statusError {
                statusFailure(statusError)
            } else if !model.isRepo {
                if model.isResolvingInitialStatus {
                    placeholder(icon: "arrow.clockwise", text: "Finding repository…")
                } else if model.isBusy {
                    placeholder(icon: "hourglass", text: "Finishing Git operation…")
                } else {
                    notRepository
                }
            } else {
                trackingBar
                repositoryOperationBanner
                branchCreator
                commitBox
                filterBar
                changeList
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
                        model.discard(pendingDiscard.entry)
                    } else {
                        model.cancelStaleDiscard()
                    }
                }
                pendingDiscard = nil
            }
            .disabled(model.isBusy)
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
                    model.discardChanges(snapshot.map(\.entry))
                } else {
                    model.cancelStaleDiscard()
                }
                pendingDiscardAll = []
                confirmDiscardAll = false
            }
            .disabled(model.isBusy)
        }
        .onChange(of: model.rootPath) {
            // A dialog must never carry a destructive file target across cwd.
            pendingDiscard = nil
            pendingDiscardAll = []
            confirmDiscardAll = false
            showBranchCreator = false
            newBranchName = ""
        }
        .onChange(of: model.repositoryIdentity) {
            resetRepositoryDrafts()
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
                PanelHeader(title: L10n.t("Git"), subtitle: model.rootPath)
            }
            if model.isRepo {
                GitHeaderIconButton(
                    systemImage: "line.3.horizontal.decrease",
                    help: L10n.t("Filter Changed Files"),
                    active: showFilter
                ) {
                    showFilter.toggle()
                    if !showFilter { filterText = "" }
                }
                SidebarRefreshButton(
                    isRefreshing: model.isBusy || model.isResolvingInitialStatus
                ) {
                    model.refresh()
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
                        model.switchBranch(to: branch)
                    } label: {
                        if branch == model.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == model.branch || model.isBusy)
                }
                Divider()
            }
            Button(L10n.t("Create New Branch…")) {
                newBranchName = ""
                showBranchCreator = true
                DispatchQueue.main.async { branchFieldFocused = true }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(SidebarTypography.secondary(.medium))
                    .foregroundStyle(Color(nsColor: Theme.cursor))
                PanelHeader(title: model.branch ?? "Detached HEAD", subtitle: model.rootPath)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(L10n.t("Switch or Create Branch"))
        .accessibilityLabel("Current branch, \(model.branch ?? "detached HEAD")")
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.t("Fetch")) { model.fetch() }
                .disabled(model.isBusy || model.remotes.isEmpty)
            Button(L10n.t("Pull (Fast-forward Only)")) { model.pull() }
                .disabled(model.isBusy || !model.hasUpstream)
            if model.hasUpstream {
                Button(L10n.t("Push")) { model.push() }
                    .disabled(model.isBusy)
            } else if model.remotes.count > 1 {
                Menu(L10n.t("Publish Branch to")) {
                    ForEach(model.remotes, id: \.self) { remote in
                        Button(remote) { model.publish(to: remote) }
                    }
                }
                .disabled(model.isBusy || model.branch == "detached HEAD")
            } else {
                Button(L10n.t("Publish Branch")) { model.push() }
                    .disabled(model.isBusy || model.remotes.isEmpty || model.branch == "detached HEAD")
            }
            Button(L10n.t("Sync Changes")) { model.syncChanges() }
                .disabled(
                    model.isBusy || model.remotes.isEmpty
                        || (!model.hasUpstream && model.remotes.count != 1)
                        || model.branch == "detached HEAD"
                )
            Divider()
            Button(L10n.t("Stash All Changes")) { model.stash(includeUntracked: true) }
                .disabled(model.isBusy || model.totalChangeCount == 0)
            Button(model.stashCount == 1 ? "Pop Stash" : "Pop Stash (\(model.stashCount))") {
                model.stashPop()
            }
            .disabled(model.isBusy || model.stashCount == 0)
            Divider()
            Button(L10n.t("Copy Changed Paths")) { copyChangedPaths() }
                .disabled(model.totalChangeCount == 0)
            Button(L10n.t("Copy Repository Path")) { copyToPasteboard(model.repoRoot) }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.repoRoot)])
            } label: {
                Label(L10n.t("Reveal Repository in Finder"), systemImage: "finder")
            }
        } label: {
            GitHeaderMenuIcon()
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("More Actions…"))
        .accessibilityLabel(L10n.t("More Git Actions"))
    }

    private struct GitHeaderIconButton: View {
        let systemImage: String
        let help: String
        var disabled: Bool = false
        var active: Bool = false
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(SidebarTypography.caption(.medium))
                    .foregroundStyle(
                        active
                            ? Color(nsColor: Theme.cursor)
                            : (disabled ? .secondary.opacity(0.4) : (isHovering ? .primary : .secondary))
                    )
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(
                                active
                                    ? Color(nsColor: Theme.cursor).opacity(0.12)
                                    : (isHovering && !disabled ? Color.primary.opacity(0.08) : Color.clear)
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .onHover { isHovering = $0 }
            .help(help)
            .accessibilityLabel(help)
        }
    }

    private struct GitHeaderMenuIcon: View {
        @State private var isHovering = false

        var body: some View {
            Image(systemName: "ellipsis")
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .onHover { isHovering = $0 }
        }
    }

    @ViewBuilder
    private var trackingBar: some View {
        if let branch = model.branch {
            HStack(spacing: 5) {
                Image(systemName: model.hasUpstream ? "arrow.triangle.2.circlepath" : "icloud.slash")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
                Text(model.upstream ?? (branch == "detached HEAD" ? "Detached HEAD" : "Unpublished branch"))
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
                         ? "Finish or abort from the terminal"
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
                        Button {
                            operationExpanded.toggle()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(SidebarTypography.compact())
                                .rotationEffect(.degrees(operationExpanded ? 90 : 0))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(operationExpanded ? "Hide Git Output" : "Show Git Output")
                        .accessibilityLabel(operationExpanded ? "Hide Git Output" : "Show Git Output")
                    }
                    if !operation.isRunning {
                        Button {
                            operationExpanded = false
                            model.dismissOperation()
                        } label: {
                            Image(systemName: "xmark")
                                .font(SidebarTypography.compact())
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("Dismiss"))
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
                TextField("New branch name", text: $newBranchName)
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
                    .disabled(newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                Button {
                    showBranchCreator = false
                } label: {
                    Image(systemName: "xmark").font(SidebarTypography.compact())
                }
                .buttonStyle(.plain)
                .help(L10n.t("Cancel"))
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
                    help: L10n.t("Commit staged changes (⌘Return)"),
                    action: performPrimaryAction
                )
                commitMenu
            }

            if showSyncButton {
                actionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncButtonTitle,
                    enabled: !model.isBusy,
                    help: L10n.t("Pull remote commits, then push local ones"),
                    action: model.syncChanges
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
            && !model.isBusy
            && !aiCommitTasks.isRunning(model.repoRoot)
            && (model.totalChangeCount > 0 || !model.stagedEntries.isEmpty || !model.changedEntries.isEmpty)
    }

    /// Message 旁的 AI 按钮：进行中显示取消，否则 sparkles.2。
    private var aiCommitMessageButton: some View {
        let running = aiCommitTasks.isRunning(model.repoRoot)
        return Button {
            if running {
                aiCommitTasks.cancel(model.repoRoot, clearError: true)
            } else {
                startAICommitMessage()
            }
        } label: {
            Group {
                if running {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "sparkles.2")
                        .font(SidebarTypography.caption(.semibold))
                }
            }
            .frame(width: 28, height: 28)
            .foregroundStyle(
                running || (LocalAI.isEnabled && canGenerateAICommitMessage)
                    ? Color(nsColor: Theme.cursor)
                    : Color.secondary.opacity(0.55)
            )
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!running && (!LocalAI.isEnabled || !canGenerateAICommitMessage))
        .help(
            running
                ? L10n.t("Cancel AI Commit Message")
                : (LocalAI.isEnabled
                    ? L10n.t("Generate commit message with AI")
                    : L10n.t("Enable AI headless provider in Settings → General"))
        )
        .accessibilityLabel(
            running ? L10n.t("Cancel AI Commit Message") : L10n.t("AI Commit Message")
        )
    }

    /// 启动 AI 生成 commit message（全局语言 + 项目覆盖 + Gitmoji 开关）。
    private func startAICommitMessage() {
        guard model.isRepo, !model.repoRoot.isEmpty else { return }
        aiCommitTasks.clearError(model.repoRoot)
        let language = project?.resolvedAIWritingLanguage ?? settings.aiWritingLanguage
        aiCommitTasks.start(
            repoRoot: model.repoRoot,
            language: language,
            useEmoji: settings.gitCommitMessageEmoji
        )
    }

    private var commitMenu: some View {
        Menu {
            Button(L10n.t("Commit Staged")) { performCommit(includeAll: false) }
                .disabled(!canCommit(includeAll: false))
            Button(L10n.t("Stage All & Commit")) { performCommit(includeAll: true) }
                .disabled(!canCommit(includeAll: true))
            Divider()
            Button(L10n.t("Amend Last Commit")) { performCommit(includeAll: false, amend: true) }
                .disabled(!canAmend(includeAll: false))
            Button(L10n.t("Stage All & Amend")) { performCommit(includeAll: true, amend: true) }
                .disabled(!canAmend(includeAll: true))
        } label: {
            Image(systemName: "chevron.down")
                .font(SidebarTypography.compact())
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("Commit Options"))
        .accessibilityLabel(L10n.t("Commit Options"))
    }

    private func actionButton(
        icon: String, title: String, enabled: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(SidebarTypography.caption(.semibold))
                Text(title)
                    .font(SidebarTypography.secondary(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: Theme.cursor).opacity(enabled ? 0.85 : 0.3))
            )
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(title)
    }

    private var commitFieldPlaceholder: String {
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
        if model.stagedEntries.count == 1 { return L10n.t("Commit 1 Staged File") }
        if model.stagedEntries.count > 1 {
            return L10n.format("Commit %d Staged Files", model.stagedEntries.count)
        }
        return L10n.t("Commit Staged")
    }

    private func canCommit(includeAll: Bool) -> Bool {
        let hasEligibleChanges = includeAll
            ? (!model.changedEntries.isEmpty || !model.stagedEntries.isEmpty)
            : !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func canAmend(includeAll: Bool) -> Bool {
        let hasCommit = !model.recentCommits.isEmpty
        let hasEligibleChanges = !includeAll
            || !model.changedEntries.isEmpty
            || !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommit
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func performPrimaryAction() {
        performCommit(includeAll: false)
    }

    private func performCommit(includeAll: Bool, amend: Bool = false) {
        guard amend ? canAmend(includeAll: includeAll) : canCommit(includeAll: includeAll) else { return }
        let submittedMessage = commitMessage
        model.commit(message: submittedMessage, includeAll: includeAll, amend: amend) { success in
            if success, commitMessage == submittedMessage { commitMessage = "" }
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
                TextField("Filter changed files", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(SidebarTypography.secondary())
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(SidebarTypography.caption())
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("Clear Filter"))
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

    private var changeList: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if model.totalChangeCount == 0 {
                            cleanState
                        } else if visibleChangeCount == 0 {
                            inlinePlaceholder(icon: "line.3.horizontal.decrease", text: "No changed files match “\(filterText)”")
                        }
                        if !filteredMergeEntries.isEmpty {
                            SidebarSectionHeader(
                                title: L10n.t("MERGE CHANGES"),
                                count: filteredMergeEntries.count,
                                isCollapsed: $mergeCollapsed,
                                actions: [],
                                actionsDisabled: model.isBusy
                            )
                            if !mergeCollapsed {
                                // 展开分组内容添加统一的 12pt 左边距
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(filteredMergeEntries, id: \.mergeRowID) { entry in
                                        row(entry, status: "U", kind: .merge)
                                    }
                                }
                                .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
                            }
                        }
                        if !filteredStagedEntries.isEmpty {
                            SidebarSectionHeader(
                                title: L10n.t("STAGED CHANGES"),
                                count: filteredStagedEntries.count,
                                isCollapsed: $stagedCollapsed,
                                actions: filterText.isEmpty ? [
                                    .init(systemImage: "minus", help: L10n.t("Unstage All Changes")) {
                                        model.unstageAll()
                                    }
                                ] : [],
                                actionsDisabled: model.isBusy
                            )
                            if !stagedCollapsed {
                                // 展开分组内容添加统一的 12pt 左边距
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(filteredStagedEntries, id: \.stagedRowID) { entry in
                                        row(entry, status: entry.staged, kind: .staged)
                                    }
                                }
                                .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
                            }
                        }
                        if !filteredChangedEntries.isEmpty {
                            SidebarSectionHeader(
                                title: L10n.t("CHANGES"),
                                count: filteredChangedEntries.count,
                                isCollapsed: $changesCollapsed,
                                actions: filterText.isEmpty ? [
                                    .init(systemImage: "arrow.uturn.backward", help: L10n.t("Discard All Changes")) {
                                        requestDiscardAll()
                                    },
                                    .init(systemImage: "plus", help: L10n.t("Stage All Changes")) {
                                        model.stageAll()
                                    },
                                ] : [],
                                actionsDisabled: model.isBusy
                            )
                            if !changesCollapsed {
                                // 展开分组内容添加统一的 12pt 左边距
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(filteredChangedEntries, id: \.changedRowID) { entry in
                                        row(entry, status: entry.unstaged, kind: .unstaged)
                                    }
                                }
                                .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
                            }
                        }
                        if filterText.isEmpty, !model.recentCommits.isEmpty {
                            SidebarSectionHeader(
                                title: L10n.t("RECENT COMMITS"),
                                count: model.recentCommits.count,
                                isCollapsed: $historyCollapsed,
                                actions: [],
                                actionsDisabled: model.isBusy
                            )
                            if !historyCollapsed {
                                // 展开分组内容添加统一的 12pt 左边距
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(model.recentCommits) { commit in
                                        GitCommitRow(
                                            commit: commit,
                                            isHead: commit.hash == model.recentCommits.first?.hash,
                                            repoRoot: model.repoRoot,
                                            disabled: model.isBusy,
                                            hasStagedChanges: !model.stagedEntries.isEmpty,
                                            canAICommitMessage: LocalAI.isEnabled
                                                && canGenerateAICommitMessage,
                                            isAICommitRunning: aiCommitTasks.isRunning(model.repoRoot),
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
                                    }
                                }
                                .padding(.leading, SidebarPanelMetrics.expandedContentLeading)
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

    private var filteredMergeEntries: [GitStatusModel.Entry] {
        model.mergeEntries.filter(matchesFilter)
    }

    private var filteredStagedEntries: [GitStatusModel.Entry] {
        model.stagedEntries.filter(matchesFilter)
    }

    private var filteredChangedEntries: [GitStatusModel.Entry] {
        model.changedEntries.filter(matchesFilter)
    }

    private var visibleChangeCount: Int {
        filteredMergeEntries.count + filteredStagedEntries.count + filteredChangedEntries.count
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

    private func row(
        _ entry: GitStatusModel.Entry, status: Character, kind: GitEntryRow.Kind
    ) -> some View {
        GitEntryRow(
            entry: entry,
            status: status,
            kind: kind,
            disabled: model.isBusy,
            openDiff: {
                guard model.isCurrent(entry) else { return }
                var diffEntry = entry
                if kind == .unstaged && (entry.staged == "R" || entry.staged == "C") {
                    // A staged rename/copy's unstaged side compares the
                    // destination in the index with that same worktree path.
                    diffEntry.origPath = nil
                }
                openDiff(diffEntry, kind == .staged)
            },
            openFile: { openIfPossible(entry) },
            openToSide: { openIfPossible(entry, toSide: true) },
            stage: { model.stage(entry) },
            unstage: { model.unstage(entry) },
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
        pendingDiscardAll = model.changedEntries.map(makePendingDiscard)
        confirmDiscardAll = !pendingDiscardAll.isEmpty
    }

    // MARK: Bits

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(.quaternary)
            Text(text)
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
            Text(text)
                .font(SidebarTypography.caption())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }

    private var notRepository: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(.quaternary)
            VStack(spacing: 2) {
                Text(L10n.t("No Git Repository"))
                    .font(SidebarTypography.body(.medium))
                Text(L10n.t("Initialize the terminal’s current directory to start tracking changes."))
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Button(L10n.t("Initialize Repository")) {
                model.initializeRepository()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color(nsColor: Theme.cursor))
            .disabled(model.rootPath.isEmpty || model.isBusy)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func statusFailure(_ message: String) -> some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
            VStack(spacing: 3) {
                Text(L10n.t("Git Status Unavailable"))
                    .font(SidebarTypography.body(.medium))
                Text(message)
                    .font(SidebarTypography.caption(design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            Button(L10n.t("Retry")) { model.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy || model.isResolvingInitialStatus)
            Spacer()
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

private struct GitCommitRow: View {
    let commit: GitStatusModel.RecentCommit
    let isHead: Bool
    let repoRoot: String
    let disabled: Bool
    let hasStagedChanges: Bool
    /// 当前是否可生成 AI Commit Message（LocalAI 已启用且有变更）。
    let canAICommitMessage: Bool
    let isAICommitRunning: Bool
    let onAICommitMessage: () -> Void
    let onCancelAICommitMessage: () -> Void
    let onRefreshNeeded: () -> Void

    @State private var showEditSheet = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .font(SidebarTypography.body())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(commit.shortHash)
                    .font(SidebarTypography.section(design: .monospaced))
                    .foregroundStyle(Color(nsColor: Theme.cursor).opacity(0.85))
                Text("·")
                Text(commit.author)
                Text("·")
                Text(commit.relativeDate)
            }
            .font(SidebarTypography.section())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .textSelection(.enabled)
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

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct GitEntryRow: View {
    enum Kind {
        case merge, staged, unstaged
    }

    let entry: GitStatusModel.Entry
    let status: Character
    let kind: Kind
    let disabled: Bool
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
        HStack(spacing: 2) {
            Button(action: openDiff) {
                HStack(spacing: 7) {
                    Text(String(status))
                        .font(SidebarTypography.caption(.bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .frame(width: 12)
                    // Git 变更行：按文件名匹配 Material 图标（目录变更极少，按文件处理）。
                    MaterialFileIconView(
                        fileName: entry.fileName,
                        isDirectory: false,
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

            if !disabled {
                hoverActions
                    .opacity(isHovering || isFocused ? 1 : 0.55)
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

    private var hoverActions: some View {
        HStack(spacing: 4) {
            switch kind {
            case .merge:
                rowButton("plus", help: L10n.t("Mark Resolved (Stage)"), action: stage)
            case .staged:
                rowButton("minus", help: L10n.t("Unstage Changes"), action: unstage)
            case .unstaged:
                rowButton("arrow.uturn.backward", help: L10n.t("Discard Changes"), action: discard)
                rowButton("plus", help: L10n.t("Stage Changes"), action: stage)
            }
        }
    }

    private func rowButton(
        _ systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidebarTypography.micro(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
        if textView.string != text {
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
