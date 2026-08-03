//
//  TerminalHostView.swift
//  kero
//

import AppKit
import GhosttyTerminal
import SwiftUI

/// Hosts a session's long-lived Ghostty terminal view in SwiftUI,
/// wrapped in a container that insets the terminal content while pinning
/// the session's overlay scrollbar to the container's true trailing edge.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Whether this terminal's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Whether the tab contains multiple split panes.
    var hasMultiplePanes: Bool = false
    /// Called when the terminal takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}
    /// Splits this pane on the given edge — wired to the context-menu items.
    var onSplit: (PaneDropEdge) -> Void = { _ in }
    var onNewBrowserTab: (String?) -> Void = { _ in }
    var onNewBrowserPane: (String?) -> Void = { _ in }
    /// Closes this pane when the terminal is part of a split layout.
    var onClose: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.focusOnAppear = isFocused
        container.updateCornerRadius(hasMultiplePanes: hasMultiplePanes)
        mount(session: session, into: container)
        context.coordinator.mountedSessionID = session.id
        context.coordinator.isFocused = isFocused
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let container = view as? TerminalContainerView else { return }

        // 任务重跑会在同一 pane 原地替换 Session；若不 remount，容器仍挂着
        // 已 terminate 的旧 terminal（“Process exited…”），新会话永远看不见。
        if context.coordinator.mountedSessionID != session.id {
            mount(session: session, into: container)
            context.coordinator.mountedSessionID = session.id
            // 会话身份变了：视为重新获得焦点边沿，便于聚焦新 terminal。
            context.coordinator.isFocused = false
        }

        session.terminalView.setSurfaceVisible(true)
        session.terminalView.onBecomeFirstResponder = onFocused
        session.terminalView.splitTarget.onSplit = onSplit
        session.terminalView.splitTarget.onNewBrowserTab = onNewBrowserTab
        session.terminalView.splitTarget.onNewBrowserPane = onNewBrowserPane
        session.terminalView.splitTarget.onClose = onClose
        container.focusOnAppear = isFocused
        container.updateCornerRadius(hasMultiplePanes: hasMultiplePanes)
        // Take focus only on the unfocused→focused edge (keyboard navigation,
        // a split landing here), never on every render — that would fight the
        // user for focus and make sidebar text fields untypable.
        if isFocused, !context.coordinator.isFocused {
            container.requestTerminalFocus()
        }
        context.coordinator.isFocused = isFocused
    }

    /// 将 `session` 的 terminal + 覆盖滚动条挂入容器；会先清空旧子视图。
    private func mount(session: TerminalSession, into container: TerminalContainerView) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        let terminal = session.terminalView
        // 从后台停车区回到前台时恢复 GPU surface 合成。
        terminal.setSurfaceVisible(true)
        terminal.onBecomeFirstResponder = onFocused
        terminal.splitTarget.onSplit = onSplit
        terminal.splitTarget.onNewBrowserTab = onNewBrowserTab
        terminal.splitTarget.onNewBrowserPane = onNewBrowserPane
        terminal.splitTarget.onClose = onClose
        let scrollbar = session.overlayScrollbar
        terminal.translatesAutoresizingMaskIntoConstraints = false
        scrollbar.translatesAutoresizingMaskIntoConstraints = false
        container.terminal = terminal
        container.addSubview(terminal)
        container.addSubview(scrollbar, positioned: .above, relativeTo: terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollbar.topAnchor.constraint(equalTo: container.topAnchor),
            scrollbar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollbar.widthAnchor.constraint(equalToConstant: OverlayScrollbarView.stripWidth),
        ])
    }

    final class Coordinator {
        var isFocused = false
        /// 当前挂载在 NSView 上的 session；用于检测原地替换。
        var mountedSessionID: UUID?
    }
}

/// Keeps every non-visible terminal attached to the window. libghostty starts
/// an exec surface only after attachment and drains process/title/bell events
/// from its app tick, so parking preserves the eager/background session
/// behavior Kero had before the backend migration without drawing those panes
/// into the visible layout.
struct TerminalParkingView: NSViewRepresentable {
    let sessions: [TerminalSession]

    func makeNSView(context: Context) -> TerminalParkingContainerView {
        TerminalParkingContainerView(frame: .zero)
    }

    func updateNSView(_ view: TerminalParkingContainerView, context: Context) {
        view.mount(sessions)
    }

    static func dismantleNSView(
        _ view: TerminalParkingContainerView, coordinator: ()
    ) {
        view.unmountAll()
    }
}

final class TerminalParkingContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mount(_ sessions: [TerminalSession]) {
        let activeSessions = sessions.filter(\.isInitialized)
        let desired = Set(activeSessions.map { ObjectIdentifier($0.terminalView) })
        for subview in subviews where !desired.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }

        for session in activeSessions {
            let terminal = session.terminalView
            // 后台会话仍保持挂载和事件处理，但不再持有持续合成的可见 surface。
            terminal.setSurfaceVisible(false)
            guard terminal.superview !== self else { continue }
            let parkedSize = terminal.frame.size
            if terminal.window?.firstResponder === terminal {
                terminal.window?.makeFirstResponder(nil)
            }
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = true
            let hasUsableSize =
                parkedSize.width.isFinite && parkedSize.height.isFinite
                && parkedSize.width > 0 && parkedSize.height > 0
            terminal.frame = NSRect(
                origin: .zero,
                size: hasUsableSize
                    ? parkedSize
                    : NSSize(width: 800, height: 600)
            )
            addSubview(terminal)
        }
    }

    func unmountAll() {
        for subview in subviews { subview.removeFromSuperview() }
    }
}

/// Focuses the terminal when its pane is the focused one — on first appearance
/// and when navigation moves focus here. `TerminalHostView` drives the edge;
/// this only performs the makeFirstResponder.
private final class TerminalContainerView: NSView {
    weak var terminal: NSView?
    var focusOnAppear = true {
        didSet {
            if !focusOnAppear { pendingFocusRequest = false }
        }
    }
    private var pendingFocusRequest = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func updateCornerRadius(hasMultiplePanes: Bool) {
        let radius: CGFloat = hasMultiplePanes ? 6 : 0
        if layer?.cornerRadius != radius {
            layer?.cornerRadius = radius
            layer?.masksToBounds = hasMultiplePanes
            layer?.cornerCurve = .continuous
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
        guard focusOnAppear else { return }
        requestTerminalFocus()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard focusOnAppear, pendingFocusRequest else { return }
        focusTerminalIfPossible()
    }

    func requestTerminalFocus() {
        pendingFocusRequest = true
        focusTerminalIfPossible()
    }

    private func focusTerminalIfPossible() {
        guard NSApp.isActive, let window, window.isKeyWindow, let terminal else {
            return
        }
        DispatchQueue.main.async { [weak self, weak window, weak terminal] in
            guard
                let self,
                let window,
                let terminal,
                self.focusOnAppear,
                NSApp.isActive,
                window.isKeyWindow,
                terminal.window === window
            else { return }
            if window.makeFirstResponder(terminal) {
                self.pendingFocusRequest = false
            }
        }
    }
}
