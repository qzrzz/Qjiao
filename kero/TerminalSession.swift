//
//  TerminalSession.swift
//  kero
//

import AppKit
import Combine
import Darwin
import Foundation
import GhosttyTerminal

/// One login shell rendered by one long-lived libghostty surface. SwiftUI only
/// reparents the same `KeroTerminalView`, so PTY state, selection, and
/// scrollback survive tab and split-layout changes.
@MainActor
final class TerminalSession: NSObject, nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    @Published var title: String
    @Published var workingDirectory: String?
    @Published var hasExited = false
    /// 标识该 Session 是否由右侧面板 task/脚本命令发起的终端。
    @Published var isTaskRunning = false
    /// 标识该 Session 运行命令结束时是否有错误（exitCode != 0）。
    @Published var taskHasError = false
    /// 终端引擎与视图是否已完成真正的初始化。惰性 Session 在首次访问或进入前台时建联。
    @Published private(set) var isInitialized = false
    /// 每次 Ghostty 收到 OSC 133 命令完成报告时递增，供 Git 等事件消费者观察。
    @Published private(set) var commandCompletionSequence: UInt64 = 0
    /// 是否已确认登录 shell 到达首个提示符（zsh 集成通过 OSC 2 哨兵上报）。
    /// 这是向 PTY 注入命令的最安全时机：shell 初始化期间写入的命令会被回显但不执行。
    private(set) var hasShownPrompt = false
    /// 最近一次向 PTY 注入命令的时间；脚本状态判定以它而非任务创建时刻为基准。
    private(set) var lastCommandInjectedAt: Date?
    /// 待运行命令（zsh 集成执行路径）；哨兵到达时用于判断 eval 是否已接管。
    private var pendingCommand: String?
    private var pendingCommandWritten = false

    /// 项目拖拽回调缓存，延迟装载时应用给新建的 terminalView。
    var pendingOnOpenProjectDirectory: ((URL) -> Bool)? {
        didSet {
            _terminalView?.onOpenProjectDirectory = pendingOnOpenProjectDirectory
        }
    }

    private var _terminalView: KeroTerminalView?
    private var _controller: TerminalController?
    private var _find: TerminalFind?

    @MainActor
    var terminalView: KeroTerminalView {
        ensureInitialized()
        return _terminalView!
    }

    let overlayScrollbar = OverlayScrollbarView()

    @MainActor
    var find: TerminalFind {
        ensureInitialized()
        return _find!
    }
    var onExited: ((TerminalSession) -> Void)?

    private static let persistedHistoryLineLimit = 500

    private let shellPath: String
    private let launchWorkingDirectory: String
    /// 会话创建时刻，用于 Tab 总览显示已运行时间。
    private let startedAt = Date()
    var controller: TerminalController? { _controller }
    private let launchCommand: String
    private let launchDirectoryURL: URL?
    private let shellPidFileURL: URL?
    private let zshIntegrationDirectoryURL: URL?
    private var cachedShellPid: pid_t?
    private var lastScrollbar: TerminalScrollbar?
    private var lastHistorySnapshot: String?
    private(set) var isTerminating = false

    /// 会话是否处于可用状态（既未退出也未在销毁过程中）
    var isUsable: Bool {
        !hasExited && !isTerminating
    }

    init(initialDirectory: String? = nil, restoredHistory: String? = nil, isLazy: Bool = false) {
        let shellPath = Self.loginShell()
        let directory = Self.validWorkingDirectory(initialDirectory)
        let artifacts = Self.makeLaunchArtifacts(
            shellPath: shellPath,
            restoredHistory: restoredHistory
        )
        let launchCommand = Self.makeLaunchCommand(
            shellPath: shellPath,
            pidFileURL: artifacts.pidFileURL,
            replayFileURL: artifacts.replayFileURL
        )

        self.shellPath = shellPath
        launchWorkingDirectory = directory
        self.launchCommand = launchCommand
        launchDirectoryURL = artifacts.directoryURL
        shellPidFileURL = artifacts.pidFileURL
        zshIntegrationDirectoryURL = artifacts.zshIntegrationDirectoryURL
        // 根据 zsh 闲时标题配置格式化初始标题，未改动时退回目录最后一级名称。
        let directoryName = URL(fileURLWithPath: directory).lastPathComponent
        let defaultTitle = directoryName.isEmpty
            ? (shellPath as NSString).lastPathComponent
            : directoryName
        title = AppSettings.shared.zshIdleTitleStyle.formatTitle(for: directory) ?? defaultTitle
        lastHistorySnapshot = restoredHistory
        super.init()

        if !isLazy {
            ensureInitialized()
        }
    }

    /// 惰性初始化底层 TerminalController 与 KeroTerminalView（仅在首次被需要时触发）。
    @MainActor
    func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true

        let controller = TerminalController(
            configSource: .none,
            theme: Self.ghosttyTheme(),
            terminalConfiguration: Self.terminalConfiguration(command: launchCommand)
        )
        let terminalView = KeroTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        self._controller = controller
        self._terminalView = terminalView
        self._find = TerminalFind(terminal: terminalView)

        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: launchWorkingDirectory,
            envVars: Self.surfaceEnvironment(
                shellPath: shellPath,
                zshIntegrationDirectoryURL: zshIntegrationDirectoryURL,
                pendingCommandFile: pendingCommandFileURL,
                shellPidFile: shellPidFileURL
            )
        )
        terminalView.controller = controller
        if let pendingOnOpenProjectDirectory {
            terminalView.onOpenProjectDirectory = pendingOnOpenProjectDirectory
        }
        installOverlayScrollbar()
        applyTheme()
        NSLog("🚀 [TerminalSession] 实例化终端 Session ID: %@, 目录: %@", id.uuidString, launchWorkingDirectory)
    }

    deinit {
        if let launchDirectoryURL {
            try? FileManager.default.removeItem(at: launchDirectoryURL)
        }
    }

    private func installOverlayScrollbar() {
        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            guard let self, let scrollbar = self.lastScrollbar else { return }
            let available = scrollbar.total > scrollbar.len
                ? scrollbar.total - scrollbar.len : 0
            let row = UInt((Double(available) * position).rounded())
            _ = self.terminalView.scrollToRow(row)
        }
    }

    /// Reconfigures libghostty in place when either appearance or terminal
    /// font settings change. Ghostty also uses these values for OSC 10/11
    /// queries, so reported defaults always match the visible theme.
    func applyTheme() {
        guard isInitialized, let controller = _controller, let terminalView = _terminalView else { return }
        _ = controller.setTerminalConfiguration(
            Self.terminalConfiguration(command: launchCommand)
        )
        _ = controller.setTheme(Self.ghosttyTheme())
        // 优先 window / 视图有效外观；未入窗时回落 NSApp（由全局 AppTheme 决定）。
        let isDark = Theme.resolvedIsDark(for: terminalView)
        controller.setColorScheme(isDark ? .dark : .light)
    }

    /// Stops the whole PTY job before releasing the surface. libghostty's
    /// surface teardown owns the final reap; sending HUP first gives shells the
    /// same close signal they received before the backend migration.
    func terminate() {
        guard !hasExited, !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: true, notifyExit: false)
    }

    /// 应用退出时同步停止整个 PTY 作业，避免子进程存活到 Sparkle 替换 App 之后。
    func terminateImmediately() {
        guard !hasExited, !isTerminating else { return }
        isTerminating = true
        guard isInitialized else {
            hasExited = true
            removeLaunchArtifacts()
            return
        }

        _ = shellPid // 在状态改变前缓存 pid，供进程组信号使用。
        signalTerminalJob(SIGHUP)
        signalTerminalJob(SIGKILL)
        hasExited = true
        removeLaunchArtifacts()
    }

    /// Keeps the session and surface alive until the child has either exited
    /// or been force-stopped. Releasing AppTerminalView first can make
    /// libghostty wait synchronously for a process that ignored SIGHUP.
    private func beginTeardown(processAlive: Bool, notifyExit: Bool) {
        guard isInitialized else {
            hasExited = true
            removeLaunchArtifacts()
            if notifyExit { onExited?(self) }
            return
        }
        if processAlive {
            _ = shellPid // Cache it before `hasExited` changes.
            signalTerminalJob(SIGHUP)
        }

        Task { @MainActor [self] in
            if processAlive {
                // Give well-behaved shells a moment to unwind, then guarantee
                // surface teardown cannot wait indefinitely.
                try? await Task.sleep(for: .milliseconds(120))
                signalTerminalJob(SIGKILL)
            } else {
                // Avoid freeing the surface reentrantly from libghostty's
                // process-close callback.
                await Task.yield()
            }
            _terminalView?.controller = nil
            hasExited = true
            removeLaunchArtifacts()
            if notifyExit { onExited?(self) }
        }
    }

    private func signalTerminalJob(_ signal: Int32) {
        var pids = Set<pid_t>()
        if let shellPid { pids.insert(shellPid) }
        if isInitialized, let foreground = _terminalView?.foregroundPid, foreground > 0 {
            pids.insert(foreground)
        }
        for pid in pids where pid > 1 {
            // Interactive shells and their foreground jobs normally lead
            // distinct process groups. Signal the group, then the leader as a
            // fallback for an unusual launch configuration.
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
    }

    private func removeLaunchArtifacts() {
        guard let launchDirectoryURL else { return }
        try? FileManager.default.removeItem(at: launchDirectoryURL)
    }

    /// Short label for the sidebar: the tail of the current directory, if known.
    var directoryLabel: String? {
        guard let dir = workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        let tail = (path as NSString).lastPathComponent
        return tail.isEmpty ? nil : tail
    }

    /// Best-effort live shell directory: OSC 7 first, kernel process metadata
    /// second, then the directory used to launch this session.
    var currentDirectoryPath: String {
        if let dir = workingDirectory {
            if let url = URL(string: dir), url.isFileURL { return url.path }
            if dir.hasPrefix("/") { return dir }
        }
        if let shellPid, let path = Self.processWorkingDirectory(pid: shellPid) {
            return path
        }
        return launchWorkingDirectory
    }

    /// 终端前台作业的工作目录（当该作业非 shell 本身时）。
    /// Coding Agent (如 Claude Code) 切换到其自身的 worktree 时会在进程内执行 chdir，
    /// 而 shell 并没有移动，因此该属性可获取前台作业真实的 CWD。
    /// PTY 代理（ghost-complete）下 Ghostty 的 tcgetpgrp 不可用，改为取 shell 子孙。
    var foregroundDirectoryPath: String? {
        guard let shellPid else { return nil }
        if TerminalProcessIdentity.isNestedUnderPtyProxy(shellPid: shellPid) {
            guard let job = TerminalProcessIdentity.firstNonShellDescendant(of: shellPid) else {
                return nil
            }
            return Self.processWorkingDirectory(pid: job)
        }
        guard let foreground = terminalView.foregroundPid, foreground > 0,
              foreground != shellPid
        else { return nil }
        return Self.processWorkingDirectory(pid: foreground)
    }

    func sendCommand(_ text: String) {
        lastCommandInjectedAt = Date()
        terminalView.sendText(text)
    }

    /// 当全局闲时标题设置发生变化时，更新此 Session 在 Swift 侧的显示标题。
    func updateIdleTitleStyle(_ style: ZshIdleTitleStyle) {
        let directoryName = (currentDirectoryPath as NSString).lastPathComponent
        let fallback = directoryName.isEmpty
            ? (shellPath as NSString).lastPathComponent
            : directoryName
        title = style.formatTitle(for: currentDirectoryPath) ?? fallback
    }


    /// 该会话的登录 shell 是否带有 Qjiao zsh 集成（可收到首个提示符哨兵）。
    private var usesPromptReadySignal: Bool {
        (shellPath as NSString).lastPathComponent == "zsh"
    }

    /// pending 命令文件：zsh 集成在首个提示符时读取并执行它。
    private var pendingCommandFileURL: URL? {
        launchDirectoryURL?.appendingPathComponent("pending_command")
    }

    /// Queues an automated command until this surface has been attached and
    /// its login shell has started. New tabs are mounted asynchronously by
    /// SwiftUI; sending immediately would otherwise be discarded before the
    /// exec-backed PTY exists.
    ///
    /// zsh 会话优先写入 pending 文件、由登录 shell 在首个提示符时自行执行
    /// （不经过 PTY 注入，规避与 shell 初始化竞争）；非 zsh 退回 PTY 轮询注入。
    func sendCommandWhenReady(_ text: String) {
        guard !hasExited else { return }
        if usesPromptReadySignal {
            if hasShownPrompt {
                // shell 已位于提示符：直接注入即可。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, !self.hasExited else { return }
                    self.sendCommand(text)
                }
            } else {
                // 首选：写入 pending 文件，由 zsh 集成在首个提示符时由 shell 自身执行。
                pendingCommand = text
                pendingCommandWritten = writePendingCommand(text)
                scheduleZshInjectionFallback(text)
            }
            return
        }
        // 非 zsh：保持原有 PTY 轮询注入。
        sendCommandWhenReady(text, attempt: 0)
    }

    /// 将待运行命令写入 launch 目录的 pending_command 文件。
    /// - Returns: 是否写入成功。
    @discardableResult
    private func writePendingCommand(_ text: String) -> Bool {
        guard let url = pendingCommandFileURL else {
            NSLog("qjiao: pending command skipped (no launch dir)")
            return false
        }
        let command = text.hasSuffix("\n") ? String(text.dropLast()) : text
        do {
            try command.write(to: url, atomically: true, encoding: .utf8)
            NSLog("qjiao: pending command written: %@", url.path)
            return true
        } catch {
            NSLog("qjiao: failed to write pending command: %@", error.localizedDescription)
            return false
        }
    }

    /// 兜底：若 zsh 集成未生效（提示符哨兵迟迟不来），按旧启发式注入命令。
    /// 注入前先移除 pending 文件，避免集成稍后到达提示符时重复执行同一命令。
    private func scheduleZshInjectionFallback(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.hasExited, !self.hasShownPrompt else { return }
            if let url = self.pendingCommandFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            NSLog("qjiao: zsh integration not detected, PTY injection fallback")
            self.sendCommandWhenReady(text, attempt: 0)
        }
    }

    private func sendCommandWhenReady(_ text: String, attempt: Int) {
        guard !hasExited else { return }
        if terminalView.window != nil, shellPid != nil {
            // The PID file is written immediately before the login shell is
            // exec'd. Give the shell one short run-loop turn to install its
            // prompt before inserting the command.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, !self.hasExited else { return }
                self.sendCommand(text)
            }
            return
        }

        // A slow first launch may need a little time to attach its Metal
        // surface. Stop retrying after five seconds rather than retaining a
        // command for a terminal that failed to start.
        guard attempt < 100 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendCommandWhenReady(text, attempt: attempt + 1)
        }
    }

    /// Clears the emulator's visible screen and scrollback, then asks the
    /// foreground shell to repaint its prompt at the top.
    func clear() {
        _ = terminalView.performBindingAction("clear_screen")
        _ = terminalView.performBindingAction("text:\\x0c")
    }

    /// Styled VT snapshot used by the existing sidecar history store. A
    /// scrollback/PID heuristic keeps a full-screen alternate buffer from
    /// replacing the last saved shell scrollback in normal shell/TUI use.
    func serializedHistory(captureLive: Bool) -> String? {
        guard AppSettings.shared.restoreTerminalHistory else { return nil }
        guard captureLive, isInitialized else { return lastHistorySnapshot }

        // 空闲提示符：无 PTY 代理时比较 tcgetpgrp；代理下改用「无非 shell 子孙」。
        let rootShellIsForeground: Bool = {
            guard let shellPid else { return false }
            if TerminalProcessIdentity.isNestedUnderPtyProxy(shellPid: shellPid) {
                return !TerminalProcessIdentity.hasNonShellDescendants(of: shellPid)
            }
            return terminalView.foregroundPid == shellPid
        }()
        if !rootShellIsForeground,
           !TerminalHistorySerializer.hasPrimaryScrollback(terminalView) {
            // A primary screen with no rows above the viewport and an
            // alternate screen both have no scrollback export. The root shell
            // is foreground only in the former case; a TUI owns its own
            // foreground process group in the latter.
            return lastHistorySnapshot
        }
        switch TerminalHistorySerializer.capture(
            from: terminalView, maxLines: Self.persistedHistoryLineLimit
        ) {
        case .captured(let snapshot):
            lastHistorySnapshot = snapshot
            return snapshot
        case .failed:
            return lastHistorySnapshot
        }
    }

    var shellName: String {
        (shellPath as NSString).lastPathComponent
    }

    /// PID of the root login shell. The launch shim records its own PID before
    /// `exec`, so this remains stable while Ghostty's foreground PID moves to
    /// child jobs and back.
    ///
    /// 当用户安装了 ghost-complete 等 PTY 代理时，shim 的 PID 会先变成 proxy，
    /// 真实 zsh 是其子进程。集成脚本会把 `shell.pid` 回写为内层 shell；在回写
    /// 前这里也会从 proxy 解析到登录 shell，避免侧栏 / Agent 一直盯着 proxy。
    var shellPid: pid_t? {
        if let cachedShellPid, cachedShellPid > 0,
           !TerminalProcessIdentity.isPtyProxyProcess(cachedShellPid) {
            return cachedShellPid
        }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        guard let resolved = TerminalProcessIdentity.resolveLoginShellPid(from: value) else {
            // proxy 尚无子 shell：勿缓存，下次再读。
            return nil
        }
        cachedShellPid = resolved
        return resolved
    }

    /// Whether a child process currently owns this terminal's foreground
    /// process group. An idle prompt keeps the login shell in the foreground.
    ///
    /// ghost-complete 等 PTY 代理下：libghostty 的 `tcgetpgrp` 是**进程组 ID**，
    /// 通常等于 launch shim，**不是** proxy PID，也不能代表内层作业。
    /// 用 shell 祖先是否含 proxy 判断，再用 shell 子孙探测是否有前台作业。
    var isForegroundCommandRunning: Bool {
        guard isInitialized, !hasExited, let shellPid else { return false }

        if TerminalProcessIdentity.isNestedUnderPtyProxy(shellPid: shellPid) {
            return TerminalProcessIdentity.hasNonShellDescendants(of: shellPid)
        }

        guard let foregroundPid = _terminalView?.foregroundPid else { return false }
        // `foregroundPid` is the terminal's foreground *process group* ID
        // (`tcgetpgrp`), which is not necessarily the shell's process ID.
        // Comparing it directly to `shellPid` marked every idle shell whose
        // group leader differed as busy.
        let shellProcessGroup = getpgid(shellPid)
        let idleProcessGroup = shellProcessGroup > 0 ? shellProcessGroup : shellPid
        return foregroundPid > 0 && foregroundPid != idleProcessGroup
    }

    /// 前台作业的可执行名（含 argv 脚本名）。兼容 PTY 代理：代理场景下改扫 shell 子孙。
    var foregroundJobExecutableNames: [String] {
        guard let shellPid else { return [] }
        if TerminalProcessIdentity.isNestedUnderPtyProxy(shellPid: shellPid) {
            return TerminalProcessIdentity.descendantExecutableNames(of: shellPid)
        }
        if let foregroundPid = _terminalView?.foregroundPid, foregroundPid > 0 {
            return TerminalProcessIdentity.foregroundExecutableNames(
                shellPid: shellPid,
                foregroundPgid: foregroundPid
            )
        }
        return []
    }

    /// 当前终端处于需要辅助工具栏的特定交互模式（如 Vi/Vim/Neovim）。
    var activeHelpMode: TerminalHelpMode? {
        guard isInitialized, !hasExited,
              isForegroundCommandRunning
        else { return nil }

        let names = foregroundJobExecutableNames
        for name in names {
            let lower = name.lowercased()
            let base = (lower as NSString).lastPathComponent
            if base == "vi" || base == "vim" || base == "nvim" || base == "view"
                || base == "vimdiff" || base == "ex" || base == "vi.basic" || base == "vi.recovery" {
                return .vi
            }
        }
        let lowerTitle = title.lowercased()
        if lowerTitle.hasPrefix("vi ") || lowerTitle == "vi" || lowerTitle.hasPrefix("vim ") || lowerTitle == "vim" || lowerTitle.hasPrefix("nvim ") || lowerTitle == "nvim" {
            return .vi
        }
        return nil
    }

    /// 在终端底栏点击辅助按钮时，直接向 PTY 发送控制序列并恢复终端焦点。
    func executeHelpCommand(_ command: TerminalHelpCommand) {
        guard isInitialized, let terminalView = _terminalView else { return }

        switch command {
        case .saveAndExit:
            executeViExCommand(":wq", in: terminalView)
        case .exitWithoutSaving:
            executeViExCommand(":q!", in: terminalView)
        case .insertMode:
            Task { @MainActor [weak terminalView] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let terminalView else { return }
                terminalView.window?.makeFirstResponder(terminalView)
                terminalView.performBindingAction("text:\\x1bi")
            }
        case .normalMode:
            Task { @MainActor [weak terminalView] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let terminalView else { return }
                terminalView.window?.makeFirstResponder(terminalView)
                terminalView.performBindingAction("text:\\x1b")
            }
        }
    }

    /// 原子发送 Esc、Ex 命令与 Return，避免输入队列重排或把命令写进正文。
    private func executeViExCommand(
        _ command: String,
        in terminalView: KeroTerminalView
    ) {
        Task { @MainActor [weak terminalView] in
            try? await Task.sleep(for: .milliseconds(20))
            guard let terminalView else { return }
            terminalView.window?.makeFirstResponder(terminalView)
            terminalView.performBindingAction("text:\\x1b\(command)\\x0d")
        }
    }

    // 前台进程图标缓存：按 foreground pgid 节流复用；弱运行时命中（仅 node）
    // 会较短时间后重扫，以便从 argv 识别出 rsbuild 等真实 CLI。
    private var cachedForegroundAppIconPid: pid_t = 0
    private var cachedForegroundAppIcon: TerminalAppIconSource?
    private var cachedForegroundAppIconResolvedAt: ContinuousClock.Instant?
    private var cachedForegroundAppIconIsStrong = false

    /// 当前前台进程若在 `TerminalAppIcons/apps.json`（或用户配置）中有映射，
    /// 返回对应图标来源；空闲或未知程序为 nil。
    var foregroundAppIcon: TerminalAppIconSource? {
        guard isForegroundCommandRunning, let shellPid else {
            if cachedForegroundAppIconPid != 0 {
                cachedForegroundAppIconPid = 0
                cachedForegroundAppIcon = nil
                cachedForegroundAppIconResolvedAt = nil
                cachedForegroundAppIconIsStrong = false
            }
            return nil
        }

        // 缓存键：优先 Ghostty 前台 pgid；PTY 代理下 pgid 无意义，改用 shell pid。
        let cacheKey: pid_t = {
            if TerminalProcessIdentity.isNestedUnderPtyProxy(shellPid: shellPid) {
                return shellPid
            }
            if let fg = terminalView.foregroundPid, fg > 0 {
                return fg
            }
            return shellPid
        }()

        // 强命中（具体 CLI）可较长复用；弱命中 / 未命中约 0.25s 重试。
        if cachedForegroundAppIconPid == cacheKey,
           let resolvedAt = cachedForegroundAppIconResolvedAt
        {
            let age = ContinuousClock.now - resolvedAt
            if cachedForegroundAppIconIsStrong, age < .seconds(2) {
                return cachedForegroundAppIcon
            }
            if !cachedForegroundAppIconIsStrong, age < .milliseconds(250) {
                return cachedForegroundAppIcon
            }
        }

        let names = foregroundJobExecutableNames
        let source = TerminalAppIconCatalog.shared.source(forProcessNames: names)
        // 候选里若出现非 node/npm 的名字且成功匹配，视为强命中。
        let strong = source != nil && names.contains { name in
            !TerminalAppIconCatalog.isWeakRuntimeName(name)
                && TerminalAppIconCatalog.shared.source(forProcessName: name) != nil
        }
        cachedForegroundAppIconPid = cacheKey
        cachedForegroundAppIcon = source
        cachedForegroundAppIconResolvedAt = ContinuousClock.now
        cachedForegroundAppIconIsStrong = strong
        return source
    }

    /// 终端 shell 自会话创建以来的运行时长。
    func runningDurationLabel(at date: Date = .now) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(remainingSeconds)s" }
        return "\(remainingSeconds)s"
    }

    /// 供 Tab 总览后台查询使用的已知目录；不触发内核进程查询。
    var tabListFallbackDirectory: String {
        if let dir = workingDirectory {
            if let url = URL(string: dir), url.isFileURL { return url.path }
            if dir.hasPrefix("/") { return dir }
        }
        return launchWorkingDirectory
    }

    /// Tab 总览所需的后台查询结果。
    struct TabListDetails: Sendable {
        let directory: String
        let memoryLabel: String
    }

    /// 在后台读取 shell 的工作目录和常驻内存，避免影响弹出面板的首帧。
    nonisolated static func loadTabListDetails(
        shellPid: pid_t?, fallbackDirectory: String
    ) -> TabListDetails {
        let directory = shellPid.flatMap(processWorkingDirectory) ?? fallbackDirectory
        guard let shellPid else {
            return TabListDetails(directory: directory, memoryLabel: "—")
        }
        var taskInfo = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(
            shellPid, PROC_PIDTASKINFO, 0, &taskInfo, expectedSize
        ) == expectedSize else {
            return TabListDetails(directory: directory, memoryLabel: "—")
        }
        return TabListDetails(
            directory: directory,
            memoryLabel: ByteCountFormatter.string(
                fromByteCount: Int64(taskInfo.pti_resident_size), countStyle: .memory
            )
        )
    }

    // MARK: - Ghostty configuration

    private static func terminalConfiguration(command: String) -> TerminalConfiguration {
        let settings = AppSettings.shared
        let family = settings.fontFamily.isEmpty
            ? TerminalFont.bundledFamily : settings.fontFamily
        return TerminalConfiguration { builder in
            builder.withFontFamily(family)
            if settings.useBundledChineseTerminalFont {
                // 中文字符优先回退到随应用打包的等宽思源黑体。
                builder.withCustom("font-family", TerminalFont.bundledChineseFamily)
            }
            // Keep Kero's bundled icon font as a fallback after the selected
            // primary face. Repeated font-family entries form Ghostty's list.
            builder.withCustom("font-family", "Symbols Nerd Font Mono")
            builder.withFontSize(Float(settings.fontSize))
            builder.withFontThicken(settings.fontThicken)
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            builder.withBackgroundOpacity(settings.terminalBackgroundOpacity)
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)
            builder.withCustom("window-padding-balance", "false")
            builder.withCustom("window-padding-color", "extend")
            // Kero owns the app-level command map. Leaving Ghostty's defaults
            // installed makes its performKeyEquivalent intercept shortcuts
            // such as Cmd-T, Cmd-N, Cmd-D, Cmd-K, and project/tab navigation
            // before SwiftUI's command menu can handle them.
            builder.withCustom("keybind", "clear")
            // Reinstall only terminal-local editing and scrolling bindings.
            // These preserve the native macOS shell experience without
            // reclaiming any shortcut owned by Kero's command menus.
            for keybind in [
                "alt+left=esc:b",
                "alt+right=esc:f",
                "super+left=text:\\x01",
                "super+right=text:\\x05",
                "super+backspace=text:\\x15",
                "super+home=scroll_to_top",
                "super+end=scroll_to_bottom",
                "super+page_up=scroll_page_up",
                "super+page_down=scroll_page_down",
            ] {
                builder.withCustom("keybind", keybind)
            }
            builder.withCustom("command", "shell:\(command)")
            builder.withCustom("term", "xterm-256color")
            builder.withCustom("shell-integration", "none")
            builder.withCustom(
                "cursor-click-to-move",
                settings.directClickMovesCursor ? "true" : "false"
            )
            // The previous backend retained 500 rows. Ghostty budgets bytes
            // instead, so use a small per-surface cap with enough room for at
            // least that many normally sized rows while keeping synchronous
            // history exports bounded.
            builder.withCustom("scrollback-limit", "4194304")
            // 默认保留 macOS 输入源的 Option 组合文字；需要终端 Meta 快捷键时由用户开启。
            builder.withCustom(
                "macos-option-as-alt",
                settings.macosOptionAsAlt ? "true" : "false"
            )
            builder.withCustom("scrollbar", "never")
            builder.withCustom("clipboard-read", "ask")
            builder.withCustom("clipboard-write", "allow")
            builder.withCustom("clipboard-paste-protection", "true")
        }
    }

    private static func ghosttyTheme() -> GhosttyTerminal.TerminalTheme {
        GhosttyTerminal.TerminalTheme(
            light: ghosttyColors(Theme.terminal(dark: false)),
            dark: ghosttyColors(Theme.terminal(dark: true))
        )
    }

    private static func ghosttyColors(
        _ theme: KeroTerminalTheme
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackground(Theme.hex(theme.background))
            builder.withForeground(Theme.hex(theme.foreground))
            builder.withCursorColor(Theme.hex(theme.cursor))
            for (index, color) in theme.ansi.enumerated() {
                builder.withPalette(index, color: color)
            }
        }
    }

    private static func surfaceEnvironment(
        shellPath: String,
        zshIntegrationDirectoryURL: URL?,
        pendingCommandFile: URL?,
        shellPidFile: URL?
    ) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "QJIAO_CONFIG_DIR": AppSettings.configURL.deletingLastPathComponent().path,
        ]
        // 终端区域设置属于用户的 Shell 环境，应用界面语言不得代替用户注入 LANG/LC_*。
        if (shellPath as NSString).lastPathComponent == "zsh",
           let integrationDirectory = zshIntegrationDirectoryURL?.path {
            let processEnvironment = ProcessInfo.processInfo.environment
            environment["QJIAO_ZSH_INTEGRATION_DIR"] = integrationDirectory
            environment["QJIAO_ZDOTDIR_WAS_SET"] = processEnvironment["ZDOTDIR"] == nil
                ? "0" : "1"
            environment["QJIAO_ORIGINAL_ZDOTDIR"] = processEnvironment["ZDOTDIR"] ?? ""
            environment["ZDOTDIR"] = integrationDirectory
            // 告诉 zsh 集成待运行命令文件的位置（首个提示符时读取执行）。
            if let pendingCommandFile {
                environment["QJIAO_PENDING_COMMAND_FILE"] = pendingCommandFile.path
            }
            // 内层真实 shell 回写 PID（兼容 ghost-complete 等 PTY 代理）。
            if let shellPidFile {
                environment["QJIAO_SHELL_PID_FILE"] = shellPidFile.path
            }
            // 只向本应用新建的 zsh 注入此变量；不会改动用户系统终端的环境。
            if let idleTitle = AppSettings.shared.zshIdleTitleStyle.environmentValue {
                environment["ZSH_THEME_TERM_TITLE_IDLE"] = idleTitle
            }
        }
        return environment
    }

    private struct LaunchArtifacts {
        let directoryURL: URL?
        let pidFileURL: URL?
        let replayFileURL: URL?
        let zshIntegrationDirectoryURL: URL?
    }

    private static func makeLaunchArtifacts(
        shellPath: String,
        restoredHistory: String?
    ) -> LaunchArtifacts {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("kero-terminal-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let pidFile = directory.appendingPathComponent("shell.pid")
            let zshIntegrationDirectory = makeWritableZshIntegrationDirectory(
                shellPath: shellPath,
                launchDirectory: directory
            )
            var replayFile: URL?
            if AppSettings.shared.restoreTerminalHistory,
               let restoredHistory,
               !restoredHistory.isEmpty {
                let file = directory.appendingPathComponent("history.vt")
                let separator = restoredHistory.hasSuffix("\n") ? "" : "\r\n"
                let contents = restoredHistory + separator
                    + TerminalHistorySerializer.restoredBanner() + "\r\n"
                try Data(contents.utf8).write(to: file, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
                replayFile = file
            }
            return LaunchArtifacts(
                directoryURL: directory,
                pidFileURL: pidFile,
                replayFileURL: replayFile,
                zshIntegrationDirectoryURL: zshIntegrationDirectory
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            NSLog("kero: failed to prepare terminal launch files: \(error)")
            return LaunchArtifacts(
                directoryURL: nil,
                pidFileURL: nil,
                replayFileURL: nil,
                zshIntegrationDirectoryURL: nil
            )
        }
    }

    /// 将 zsh 启动代理复制到会话临时目录，避免 Shell 写入已签名的 App Bundle。
    private static func makeWritableZshIntegrationDirectory(
        shellPath: String,
        launchDirectory: URL
    ) -> URL? {
        guard (shellPath as NSString).lastPathComponent == "zsh",
              let bundledDirectory = Bundle.main.resourceURL?
                  .appendingPathComponent("TerminalShellIntegration/zsh", isDirectory: true),
              FileManager.default.fileExists(atPath: bundledDirectory.path) else {
            return nil
        }

        let writableDirectory = launchDirectory
            .appendingPathComponent("zsh-integration", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: bundledDirectory, to: writableDirectory)
            return writableDirectory
        } catch {
            // 集成复制失败时仍允许启动原生 zsh，但绝不能退回不可写的 Bundle 目录。
            NSLog("kero: failed to prepare writable zsh integration: \(error)")
            return nil
        }
    }

    private static func makeLaunchCommand(
        shellPath: String,
        pidFileURL: URL?,
        replayFileURL: URL?
    ) -> String {
        var commands: [String] = []
        if let pidFileURL {
            // PID 文件是该脚本创建的唯一文件，将加紧的 umask 限制在子 shell 内：
            // `umask` 会超出 shim 存活到 exec 的 shell 中，使终端创建的每个文件被静默设为私有。
            // `$$` 在子 shell 中仍展开为当前 shell 的 PID（同 exec 传递的 PID）。
            commands.append(
                "(umask 077; printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path)))"
            )
        }
        if let replayFileURL {
            let path = shellQuote(replayFileURL.path)
            commands.append("if [ -r \(path) ]; then /bin/cat \(path); /bin/rm -f \(path); fi")
        }
        // 部分终端应用通过 Ghostty 标识启用图片等扩展协议。
        commands.append("export TERM_PROGRAM=ghostty")
        if let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, !version.isEmpty {
            commands.append("export TERM_PROGRAM_VERSION=\(shellQuote(version))")
        }
        commands.append("exec \(shellQuote(shellPath)) -l")
        // Ghostty's macOS launcher prepends `exec -l` to a shell command.
        // Make the compound setup one executable command so `exec -l` does
        // not stop after the first shell builtin.
        let script = commands.joined(separator: "; ")
        return "/bin/sh -c \(shellQuote(script))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validWorkingDirectory(_ requested: String?) -> String {
        var isDirectory: ObjCBool = false
        if let requested,
           FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return requested
        }
        return NSHomeDirectory()
    }

    private static func processWorkingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

// MARK: - libghostty surface callbacks

extension TerminalSession: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        // zsh 集成的首个提示符哨兵：仅作为“shell 已就绪”信号，不作为标签标题。
        // 哨兵即首个提示符时刻——zsh 集成会在同一 precmd 中执行 pending 命令，
        // 以此为注入基准，避免状态判定在命令开始前就把脚本标记为已完成。
        if title == "qjiao-prompt-ready" {
            hasShownPrompt = true
            lastCommandInjectedAt = Date()
            // 集成已到首个提示符；若 pending 文件未被消费（eval 未执行，例如
            // QJIAO_PENDING_COMMAND_FILE 未传到 shell），此时 shell 已就绪，
            // 改用 PTY 注入兜底，避免命令永远不执行。
            if let command = pendingCommand {
                let consumed = pendingCommandWritten
                    && !(pendingCommandFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) } ?? false)
                if !consumed {
                    pendingCommand = nil
                    if let url = pendingCommandFileURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                    NSLog("qjiao: pending command not consumed by shell, PTY injection")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self, !self.hasExited else { return }
                        self.sendCommand(command)
                    }
                }
            }
            return
        }
        self.title = title
    }
}

extension TerminalSession: TerminalSurfaceClipboardConfirmationDelegate {
    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    ) {
        guard let window = terminalView.window else {
            request.deny()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .unsafePaste:
            alert.messageText = L10n.t("Warning: Potentially Unsafe Paste")
            alert.informativeText = L10n.t("Pasting this text may execute commands.")
        case .osc52Read:
            alert.messageText = L10n.t("Authorize Clipboard Access")
            alert.informativeText = L10n.t("A terminal program is attempting to read the clipboard.")
        }
        alert.accessoryView = Self.clipboardPreview(request.contents)
        alert.addButton(
            withTitle: request.kind == .unsafePaste ? L10n.t("Paste") : L10n.t("Allow")
        )
        let cancel = alert.addButton(
            withTitle: request.kind == .unsafePaste ? L10n.t("Cancel") : L10n.t("Deny")
        )
        cancel.keyEquivalent = "\u{1b}"
        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn { request.approve() }
            else { request.deny() }
        }
    }

    private static func clipboardPreview(_ contents: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.string = String(contents.prefix(4096))
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }
}

extension TerminalSession: TerminalSurfaceGridResizeDelegate {
    func terminalDidResize(_ size: TerminalGridMetrics) {}
}

extension TerminalSession: TerminalSurfaceFocusDelegate {
    func terminalDidChangeFocus(_ focused: Bool) {}
}

extension TerminalSession: TerminalSurfaceBellDelegate {
    func terminalDidRingBell() {
        NSSound.beep()
        guard !terminalView.hasEffectiveTerminalFocus else { return }
        TerminalNotificationService.shared.post(message: "Terminal bell")
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
}

extension TerminalSession: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive: Bool) {
        guard !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: processAlive, notifyExit: true)
    }
}

extension TerminalSession: TerminalSurfaceDesktopNotificationDelegate {
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TerminalNotificationService.shared.post(message: message)
    }
}

extension TerminalSession: TerminalSurfaceProgressReportDelegate {
    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        terminalView.applyProgressReport(state: state, percent: percent)
    }
}

extension TerminalSession: TerminalSurfaceCommandFinishedDelegate {
    /// zsh 集成输出 OSC 133;D 后由 Ghostty 回调；递增序号可保留连续相同结果的事件。
    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        commandCompletionSequence &+= 1
        if let exitCode {
            taskHasError = (exitCode != 0)
        }
    }
}

extension TerminalSession: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        if terminalView.consumeHistoryExportURL(url, kind: kind) { return }
        guard let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }
}

extension TerminalSession: TerminalSurfaceHoverLinkDelegate {
    func terminalDidUpdateHoverLink(_ url: String?) {
        terminalView.hoveredLink = url
    }
}

extension TerminalSession: TerminalSurfacePwdDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        workingDirectory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).absoluteString : path
        updateIdleTitleStyle(AppSettings.shared.zshIdleTitleStyle)
    }
}

extension TerminalSession: TerminalSurfaceSearchDelegate {
    func terminalDidStartSearch(needle: String) {
        find.started(needle: needle)
    }

    func terminalDidEndSearch() {
        find.ended()
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        find.update(total: total)
    }

    func terminalDidUpdateSearchSelected(_ selected: Int?) {
        find.update(selected: selected)
    }
}

extension TerminalSession: TerminalSurfaceScrollbarDelegate {
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        lastScrollbar = scrollbar
        let active = scrollbar.total > scrollbar.len && scrollbar.len > 0
        let position: Double
        if active {
            position = Double(scrollbar.offset) / Double(scrollbar.total - scrollbar.len)
        } else {
            position = 1
        }
        let proportion = scrollbar.total > 0
            ? Double(scrollbar.len) / Double(scrollbar.total) : 1
        overlayScrollbar.update(
            position: position,
            proportion: proportion,
            active: active
        )
    }
}
