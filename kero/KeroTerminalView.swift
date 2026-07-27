//
//  KeroTerminalView.swift
//  kero
//

import AppKit
import GhosttyTerminal

/// Ghostty's Metal-backed terminal surface with Kero's pane focus, context
/// menu, effective application focus, and Finder/file-tree drop behavior.
final class KeroTerminalView: AppTerminalView {
    /// Fired whenever direct interaction makes this pane the active one.
    var onBecomeFirstResponder: (() -> Void)?
    /// 文件夹拖入终端时创建项目；文件仍按原行为粘贴绝对路径。
    var onOpenProjectDirectory: ((URL) -> Bool)?
    let splitTarget = SplitMenuTarget()

    private let progressBar = KeroTerminalProgressBarView(frame: .zero)
    private var progressReportTimer: Timer?
    private var lastProgressValue: Int?
    private var isCapturingHistoryExport = false
    private var capturedHistoryExportPath: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        installProgressBar()
        registerForDraggedTypes([.fileURL])
    }

    deinit {
        progressReportTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 2
        progressBar.frame = CGRect(
            x: 0, y: bounds.height - height,
            width: bounds.width, height: height
        )
    }

    private func installProgressBar() {
        progressBar.isHidden = true
        addSubview(progressBar)
    }

    /// Mirrors Kero's OSC 9;4 indicator: a two-point bar
    /// at the top of the terminal, with error/pause colors and a 15-second
    /// stale-report timeout.
    func applyProgressReport(state: TerminalProgressState, percent: Int?) {
        if case .remove = state {
            clearProgressReport()
            return
        }

        let resolved: Int?
        switch state {
        case .remove:
            resolved = nil
        case .set:
            resolved = percent ?? 0
        case .error:
            resolved = percent ?? lastProgressValue
        case .indeterminate:
            resolved = nil
        case .pause:
            resolved = percent ?? lastProgressValue ?? 100
        }

        if let resolved {
            lastProgressValue = min(max(resolved, 0), 100)
        }
        progressBar.apply(state: state, progress: lastProgressValueForDisplay(
            state: state, resolved: resolved
        ))
        progressReportTimer?.invalidate()
        progressReportTimer = Timer.scheduledTimer(
            withTimeInterval: 15, repeats: false
        ) { [weak self] _ in
            self?.clearProgressReport()
        }
    }

    private func lastProgressValueForDisplay(
        state: TerminalProgressState, resolved: Int?
    ) -> Int? {
        if case .indeterminate = state { return nil }
        guard let resolved else { return nil }
        return min(max(resolved, 0), 100)
    }

    private func clearProgressReport() {
        progressReportTimer?.invalidate()
        progressReportTimer = nil
        lastProgressValue = nil
        progressBar.apply(state: .remove, progress: nil)
    }

    /// Uses Ghostty's `open` export action as a synchronous host callback. The
    /// delegate consumes that one URL into this slot instead of opening it.
    func captureHistoryExportPath(action: String) -> String? {
        guard !isCapturingHistoryExport else { return nil }
        isCapturingHistoryExport = true
        capturedHistoryExportPath = nil
        defer {
            isCapturingHistoryExport = false
            capturedHistoryExportPath = nil
        }
        guard performBindingAction(action) else { return nil }
        return capturedHistoryExportPath
    }

    func consumeHistoryExportURL(_ url: String, kind: TerminalOpenURLKind) -> Bool {
        guard isCapturingHistoryExport else { return false }
        guard case .text = kind else { return false }
        capturedHistoryExportPath = url
        return true
    }

    /// The terminal is effectively focused only while Kero itself is active,
    /// its window is key, and this exact surface owns the first responder.
    var hasEffectiveTerminalFocus: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // This view is long-lived and reparented as panes split. Resign while
        // the old window still owns us so Ghostty receives FocusOut and draws
        // an inactive cursor instead of retaining stale focus state.
        if newWindow == nil, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        focusForInteraction()
        super.mouseDown(with: event)
    }

    private func focusForInteraction() {
        if window?.firstResponder === self {
            onBecomeFirstResponder?()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: - Context menu

    /// Kero consistently reserves right-click for its terminal/pane menu. This
    /// matches Kero's existing UI, including focusing before Paste.
    override func rightMouseDown(with event: NSEvent) {
        focusForInteraction()
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func rightMouseUp(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? {
        focusForInteraction()
        return contextMenu()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(contextItem("Copy", #selector(copy(_:))))
        menu.addItem(contextItem("Paste", #selector(NSText.paste(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem("Select All", #selector(selectAll(_:))))
        menu.addItem(.separator())
        for item in splitTarget.menuItems() { menu.addItem(item) }
        return menu
    }

    private func contextItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadFileURLs(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadFileURLs(sender) ? .copy : []
    }

    /// 将拖入的文件/文件夹绝对路径进行 Shell 转义并插入到当前终端命令行提示符后。
    /// 外部拖入的文件夹会触发打开项目，内部文件树拖拽则始终作为路径插入。
    /// - Parameter sender: 拖拽 Session 信息
    /// - Returns: 是否成功执行拖放操作
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(sender), !urls.isEmpty else { return false }
        let isInternalFileTreeDrag = FileTreeModel.isDraggingFromTree ||
            (sender.draggingPasteboard.types?.contains(
                NSPasteboard.PasteboardType("com.qjiao.filetree-item")
            ) ?? false) ||
            (FileTreeModel.activeTreeDragPasteboardChangeCount == sender.draggingPasteboard.changeCount)

        FileTreeModel.isDraggingFromTree = false

        if isInternalFileTreeDrag {
            // 内部文件树拖拽到终端：不管是否为文件夹，一律作为路径插入命令行，不触发打开项目
            focusForInteraction()
            let text = urls.map { Self.shellToken(for: $0.path) }.joined(separator: " ")
            sendText(text + " ")
            return true
        }

        let directoryURLs = urls.filter(Self.isDirectory)
        let openedDirectories = directoryURLs.filter { url in
            onOpenProjectDirectory?(url) ?? false
        }
        let fileURLs = urls.filter { !Self.isDirectory($0) }
        // 文件夹被窗口接收为项目后，不再把它的路径输入到当前命令行。
        guard !fileURLs.isEmpty else { return !openedDirectories.isEmpty }
        focusForInteraction()
        let text = fileURLs.map { Self.shellToken(for: $0.path) }.joined(separator: " ")
        sendText(text + " ")
        return true
    }

    private func canReadFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    /// Finder 拖放的 URL 是否指向一个目录。
    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func shellToken(for path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Layer-backed progress indicator used for OSC 9;4 reports. It deliberately
/// ignores hit testing so terminal selection and clicks pass through it.
private final class KeroTerminalProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let barLayer = CALayer()
    private let indeterminateAnimationKey = "keroTerminalProgressIndeterminate"

    private var state: TerminalProgressState = .remove
    private var progress: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        trackLayer.isHidden = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(barLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateForCurrentState(animated: false)
    }

    func apply(state: TerminalProgressState, progress: Int?) {
        self.state = state
        self.progress = progress

        if case .remove = state {
            isHidden = true
            stopIndeterminateAnimation()
            return
        }

        isHidden = false
        let color: NSColor
        switch state {
        case .error:
            color = .systemRed
        case .pause:
            color = .systemOrange
        default:
            color = .controlAccentColor
        }
        barLayer.backgroundColor = color.cgColor
        trackLayer.backgroundColor = color.withAlphaComponent(0.3).cgColor
        updateForCurrentState(animated: true)
    }

    private func updateForCurrentState(animated: Bool) {
        guard !isHidden else { return }
        trackLayer.frame = bounds
        if let progress {
            updateDeterminate(progress: progress, animated: animated)
        } else {
            updateIndeterminate()
        }
    }

    private func updateDeterminate(progress: Int, animated: Bool) {
        trackLayer.isHidden = true
        stopIndeterminateAnimation()
        let width = bounds.width * CGFloat(progress) / 100
        let target = CGRect(x: 0, y: 0, width: width, height: bounds.height)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut)
            )
        } else {
            CATransaction.setDisableActions(true)
        }
        barLayer.frame = target
        CATransaction.commit()
    }

    private func updateIndeterminate() {
        trackLayer.isHidden = false
        let width = bounds.width * 0.25
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        guard width > 0, bounds.width > width else {
            stopIndeterminateAnimation()
            return
        }

        stopIndeterminateAnimation()
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = width / 2
        animation.toValue = bounds.width - width / 2
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barLayer.add(animation, forKey: indeterminateAnimationKey)
    }

    private func stopIndeterminateAnimation() {
        barLayer.removeAnimation(forKey: indeterminateAnimationKey)
    }
}

/// Target for pane-split context-menu items, kept separate from terminal menu
/// validation so these actions remain enabled even when there is no selection.
final class SplitMenuTarget: NSObject {
    var onSplit: ((PaneDropEdge) -> Void)?
    var onClose: (() -> Void)?

    func menuItems() -> [NSMenuItem] {
        var items = [
            item("Split Right", #selector(splitRight)),
            item("Split Left", #selector(splitLeft)),
            item("Split Up", #selector(splitUp)),
            item("Split Down", #selector(splitDown)),
        ]
        if onClose != nil {
            items.append(.separator())
            items.append(item("Close Pane", #selector(closePane)))
        }
        return items
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func splitRight() { onSplit?(.right) }
    @objc private func splitLeft() { onSplit?(.left) }
    @objc private func splitUp() { onSplit?(.top) }
    @objc private func splitDown() { onSplit?(.bottom) }
    @objc private func closePane() { onClose?() }
}
