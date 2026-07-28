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
    /// 终端引擎与视图是否已完成真正的初始化。惰性 Session 在首次访问或进入前台时建联。
    @Published private(set) var isInitialized = false
    /// 每次 Ghostty 收到 OSC 133 命令完成报告时递增，供 Git 等事件消费者观察。
    @Published private(set) var commandCompletionSequence: UInt64 = 0

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
    private var cachedShellPid: pid_t?
    private var lastScrollbar: TerminalScrollbar?
    private var lastHistorySnapshot: String?
    private var isTerminating = false

    init(initialDirectory: String? = nil, restoredHistory: String? = nil, isLazy: Bool = false) {
        let shellPath = Self.loginShell()
        let directory = Self.validWorkingDirectory(initialDirectory)
        let artifacts = Self.makeLaunchArtifacts(restoredHistory: restoredHistory)
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
            envVars: Self.surfaceEnvironment(shellPath: shellPath)
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

    func sendCommand(_ text: String) {
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


    /// Queues an automated command until this surface has been attached and
    /// its login shell has started. New tabs are mounted asynchronously by
    /// SwiftUI; sending immediately would otherwise be discarded before the
    /// exec-backed PTY exists.
    func sendCommandWhenReady(_ text: String) {
        sendCommandWhenReady(text, attempt: 0)
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

        let rootShellIsForeground = shellPid != nil
            && terminalView.foregroundPid == shellPid
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
    var shellPid: pid_t? {
        if let cachedShellPid, cachedShellPid > 0 { return cachedShellPid }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        cachedShellPid = value
        return value
    }

    /// Whether a child process currently owns this terminal's foreground
    /// process group. An idle prompt keeps the login shell in the foreground.
    var isForegroundCommandRunning: Bool {
        guard isInitialized, !hasExited,
              let shellPid,
              let foregroundPid = _terminalView?.foregroundPid
        else { return false }
        // `foregroundPid` is the terminal's foreground *process group* ID
        // (`tcgetpgrp`), which is not necessarily the shell's process ID.
        // Comparing it directly to `shellPid` marked every idle shell whose
        // group leader differed as busy.
        let shellProcessGroup = getpgid(shellPid)
        let idleProcessGroup = shellProcessGroup > 0 ? shellProcessGroup : shellPid
        return foregroundPid > 0 && foregroundPid != idleProcessGroup
    }

    /// 当前终端处于需要辅助工具栏的特定交互模式（如 Vi/Vim/Neovim）。
    var activeHelpMode: TerminalHelpMode? {
        guard isInitialized, !hasExited,
              let shellPid,
              let foregroundPid = _terminalView?.foregroundPid,
              foregroundPid > 0
        else { return nil }

        let names = TerminalProcessIdentity.foregroundExecutableNames(
            shellPid: shellPid,
            foregroundPgid: foregroundPid
        )
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
        guard isForegroundCommandRunning,
              let shellPid,
              let foregroundPid = terminalView.foregroundPid,
              foregroundPid > 0
        else {
            if cachedForegroundAppIconPid != 0 {
                cachedForegroundAppIconPid = 0
                cachedForegroundAppIcon = nil
                cachedForegroundAppIconResolvedAt = nil
                cachedForegroundAppIconIsStrong = false
            }
            return nil
        }

        // 强命中（具体 CLI）可较长复用；弱命中 / 未命中约 0.25s 重试。
        if cachedForegroundAppIconPid == foregroundPid,
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

        let names = TerminalProcessIdentity.foregroundExecutableNames(
            shellPid: shellPid,
            foregroundPgid: foregroundPid
        )
        let source = TerminalAppIconCatalog.shared.source(forProcessNames: names)
        // 候选里若出现非 node/npm 的名字且成功匹配，视为强命中。
        let strong = source != nil && names.contains { name in
            !TerminalAppIconCatalog.isWeakRuntimeName(name)
                && TerminalAppIconCatalog.shared.source(forProcessName: name) != nil
        }
        cachedForegroundAppIconPid = foregroundPid
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

    private static func surfaceEnvironment(shellPath: String) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "QJIAO_CONFIG_DIR": AppSettings.configURL.deletingLastPathComponent().path,
        ]
        if ProcessInfo.processInfo.environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        if (shellPath as NSString).lastPathComponent == "zsh",
           let integrationDirectory = Bundle.main.resourceURL?
               .appendingPathComponent("TerminalShellIntegration/zsh", isDirectory: true)
               .path {
            let processEnvironment = ProcessInfo.processInfo.environment
            environment["QJIAO_ZSH_INTEGRATION_DIR"] = integrationDirectory
            environment["QJIAO_ZDOTDIR_WAS_SET"] = processEnvironment["ZDOTDIR"] == nil
                ? "0" : "1"
            environment["QJIAO_ORIGINAL_ZDOTDIR"] = processEnvironment["ZDOTDIR"] ?? ""
            environment["ZDOTDIR"] = integrationDirectory
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
    }

    private static func makeLaunchArtifacts(restoredHistory: String?) -> LaunchArtifacts {
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
                replayFileURL: replayFile
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            NSLog("kero: failed to prepare terminal launch files: \(error)")
            return LaunchArtifacts(directoryURL: nil, pidFileURL: nil, replayFileURL: nil)
        }
    }

    private static func makeLaunchCommand(
        shellPath: String,
        pidFileURL: URL?,
        replayFileURL: URL?
    ) -> String {
        var commands = ["umask 077"]
        if let pidFileURL {
            commands.append("printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path))")
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
        // not stop after the first shell builtin (`umask`).
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
    }
}

extension TerminalSession: TerminalSurfaceOpenURLDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        if terminalView.consumeHistoryExportURL(url, kind: kind) { return }
        guard let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
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
