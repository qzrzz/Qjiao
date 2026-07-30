//
//  WindowChrome.swift
//  kero
//

import AppKit
import SwiftUI

/// Keeps the traffic-light buttons aligned with the app's 38pt header bar:
/// 20pt leading, vertically centered on the header's center line. AppKit
/// re-lays the buttons out on various events, so we re-apply after each.
///
/// 窗口亮暗由全局 `AppTheme`（`NSApp.appearance`）决定；项目主题只覆盖配色，
/// 不再改 `window.appearance`。
struct WindowChromeAccessor: NSViewRepresentable {
    static let buttonCenterY: CGFloat = 21
    static let buttonLeading: CGFloat = 16
    static let buttonSpacing: CGFloat = 20

    private let onAttach: (NSWindow) -> Void

    init(onAttach: @escaping (NSWindow) -> Void = { _ in }) {
        self.onAttach = onAttach
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttach: onAttach)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window {
            context.coordinator.attach(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private let onAttach: (NSWindow) -> Void

        init(onAttach: @escaping (NSWindow) -> Void) {
            self.onAttach = onAttach
        }

        func attach(_ window: NSWindow) {
            // SwiftUI background layers can become translucent through the
            // Appearance setting, so the AppKit window must not flatten them
            // onto an opaque system background first.
            window.isOpaque = false
            window.backgroundColor = .clear
            guard self.window !== window else { return }
            self.window = window
            onAttach(window)
            // Keep the window non-movable globally. With hidden title bar +
            // fullSizeContentView, `isMovable == true` lets AppKit claim
            // mouse-drags in the header (including Tabs) as window moves,
            // which steals SwiftUI tab-reorder gestures. Blank header
            // surfaces opt in via WindowDragArea, which briefly re-enables
            // moving only for that interaction.
            window.isMovable = false
            window.isMovableByWindowBackground = false
            reposition()
            // The initial system layout can land after us; catch up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reposition() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reposition() }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reposition()
                    }
                })
            }
        }

        private func reposition() {
            guard let window else { return }
            // 拖窗进行中不要把 isMovable 打回 false，否则会中断 performWindowDrag。
            if WindowDragSession.activeCount == 0 {
                window.isMovable = false
            }
            window.isMovableByWindowBackground = false
            guard !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type),
                      let superview = button.superview
                else { continue }
                let centerInWindow = NSPoint(
                    x: WindowChromeAccessor.buttonLeading + CGFloat(index) * WindowChromeAccessor.buttonSpacing + button.frame.width / 2,
                    y: window.frame.height - WindowChromeAccessor.buttonCenterY
                )
                let center = superview.convert(centerInWindow, from: nil)
                let origin = NSPoint(
                    x: center.x - button.frame.width / 2,
                    y: center.y - button.frame.height / 2
                )
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                }
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// Tracks in-flight `WindowDragArea` drags so `reposition()` does not force
/// `isMovable = false` mid-drag and abort `performWindowDrag`.
private enum WindowDragSession {
    static var activeCount = 0
}

/// 原生 AppKit 窗口拖拽响应视图。
///
/// `hitTest` 在 bounds 内始终认领自己，避免空 NSView 在 SwiftUI 托管下偶发
/// 打不中。拖窗优先原生 `performWindowDrag`（多桌面手感更好）；失败则按屏幕
/// 坐标手动平移。全局 `isMovable == false`，仅在原生拖窗期间短暂打开。
private class WindowDragNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // layer-backed 后 SwiftUI 托管时更稳定地参与 hit-test。
        wantsLayer = true
        // 禁止命中/绘制溢出到标题栏以外的内容区。
        clipsToBounds = true
        layer?.masksToBounds = true
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override var isOpaque: Bool { false }

    /// 无子视图时系统默认 hit-test 偶发不可靠；bounds 内一律由本视图接手。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performTitlebarDoubleClickAction()
            return
        }
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        WindowDragSession.activeCount += 1
        defer {
            WindowDragSession.activeCount = max(0, WindowDragSession.activeCount - 1)
        }

        // 原生拖窗要求 isMovable；阻塞到 mouseUp 后再恢复。
        let previousMovable = window.isMovable
        window.isMovable = true
        let selector = Selector(("performWindowDragWithEvent:"))
        if window.responds(to: selector) {
            _ = window.perform(selector, with: event)
            window.isMovable = previousMovable
            return
        }
        window.isMovable = previousMovable
        trackWindowDragManually(window: window, startEvent: event)
    }

    /// 无原生 performWindowDrag 时的回退：按屏幕坐标差平移窗口。
    private func trackWindowDragManually(window: NSWindow, startEvent: NSEvent) {
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            let current = NSEvent.mouseLocation
            window.setFrameOrigin(
                NSPoint(
                    x: startOrigin.x + (current.x - startMouse.x),
                    y: startOrigin.y + (current.y - startMouse.y)
                )
            )
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let window = self.window else { return nil }

        let menu = NSMenu(title: L10n.t("Window Settings"))

        // 1. 窗口置顶（勾选项）
        let topItem = NSMenuItem(
            title: L10n.t("Keep Window on Top"),
            action: #selector(toggleAlwaysOnTop(_:)),
            keyEquivalent: ""
        )
        topItem.target = self
        topItem.state = window.isAlwaysOnTop ? .on : .off
        menu.addItem(topItem)

        menu.addItem(NSMenuItem.separator())

        // 2. 设置窗口尺寸…
        let sizeItem = NSMenuItem(
            title: L10n.t("Set Window Size…"),
            action: #selector(openWindowSizeDialog(_:)),
            keyEquivalent: ""
        )
        sizeItem.target = self
        menu.addItem(sizeItem)

        return menu
    }

    @objc private func toggleAlwaysOnTop(_ sender: Any) {
        guard let window = self.window else { return }
        window.isAlwaysOnTop.toggle()
        NotificationCenter.default.post(name: .windowAlwaysOnTopDidChange, object: window)
    }

    @objc private func openWindowSizeDialog(_ sender: Any) {
        guard let window = self.window else { return }

        let alert = NSAlert()
        alert.messageText = L10n.t("Set Window Size")
        alert.informativeText = L10n.t("Enter window width and height (px):")
        alert.addButton(withTitle: L10n.t("OK"))
        alert.addButton(withTitle: L10n.t("Cancel"))

        let currentWidth = Int(window.frame.width)
        let currentHeight = Int(window.frame.height)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 72))

        let widthLabel = NSTextField(labelWithString: L10n.t("Width:"))
        widthLabel.frame = NSRect(x: 0, y: 38, width: 60, height: 20)
        widthLabel.alignment = .right
        widthLabel.font = NSFont.systemFont(ofSize: 13)

        let widthField = NSTextField(string: "\(currentWidth)")
        widthField.frame = NSRect(x: 68, y: 36, width: 180, height: 24)
        widthField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        widthField.placeholderString = "1200"

        let heightLabel = NSTextField(labelWithString: L10n.t("Height:"))
        heightLabel.frame = NSRect(x: 0, y: 6, width: 60, height: 20)
        heightLabel.alignment = .right
        heightLabel.font = NSFont.systemFont(ofSize: 13)

        let heightField = NSTextField(string: "\(currentHeight)")
        heightField.frame = NSRect(x: 68, y: 4, width: 180, height: 24)
        heightField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        heightField.placeholderString = "800"

        container.addSubview(widthLabel)
        container.addSubview(widthField)
        container.addSubview(heightLabel)
        container.addSubview(heightField)

        alert.accessoryView = container
        alert.window.initialFirstResponder = widthField

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let wString = widthField.stringValue.trimmingCharacters(in: .whitespaces)
            let hString = heightField.stringValue.trimmingCharacters(in: .whitespaces)

            let parsedW = Int(wString) ?? currentWidth
            let parsedH = Int(hString) ?? currentHeight

            // 限制最小安全尺寸
            let newW = max(300, parsedW)
            let newH = max(200, parsedH)

            let currentFrame = window.frame
            let newOriginY = currentFrame.maxY - CGFloat(newH)
            let newFrame = NSRect(
                x: currentFrame.origin.x,
                y: newOriginY,
                width: CGFloat(newW),
                height: CGFloat(newH)
            )

            window.setFrame(newFrame, display: true, animate: true)
        }
    }
}

/// 明确指定的窗口移动拖拽区域。
/// 仅空白背景应放置此视图；交互控件（Tabs / 按钮 / 输入框）放在其外，
/// 以免与拖窗抢鼠标流。全局 `isMovable` 关闭时，只有本区域能移动窗口。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragNSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Notification.Name {
    static let windowAlwaysOnTopDidChange = Notification.Name("windowAlwaysOnTopDidChange")
}

extension NSWindow {
    /// Mirrors what a standard title bar does on double-click, honoring the
    /// "Double-click a window's title bar to" setting in System Settings.
    /// The global default is absent when set to Zoom, which is the default.
    func performTitlebarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default: // "Maximize" or unset
            performZoom(nil)
        }
    }

    /// 窗口是否保持在其他普通窗口之上（`level == .floating`）。
    var isAlwaysOnTop: Bool {
        get { level == .floating }
        set { level = newValue ? .floating : .normal }
    }
}
