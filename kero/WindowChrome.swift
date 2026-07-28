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

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

        func attach(_ window: NSWindow) {
            // SwiftUI background layers can become translucent through the
            // Appearance setting, so the AppKit window must not flatten them
            // onto an opaque system background first.
            window.isOpaque = false
            window.backgroundColor = .clear
            guard self.window !== window else { return }
            self.window = window
            // 允许自定义标题栏和 Header 空白区域通过 WindowDragArea 拖拽移动窗口。
            window.isMovable = true
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
            window.isMovable = true
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

/// 原生 AppKit 窗口拖拽响应视图。
/// 当鼠标在空白区域按下并拖动时，直接触发系统原生 `performWindowDrag(with:)`；
/// 当双击时，触发标准 macOS 标题栏双击动作（缩放/最小化）。
private class WindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performTitlebarDoubleClickAction()
        } else if let window = self.window, window.isMovable {
            let selector = Selector(("performWindowDragWithEvent:"))
            if window.responds(to: selector) {
                _ = window.perform(selector, with: event)
            } else {
                super.mouseDown(with: event)
            }
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// 明确指定的窗口移动拖拽区域。
/// 前景交互控件（按钮/输入框）在其上方正常响应点击，未被占用的空白背景区域将自动接收鼠标事件并平滑拖动窗口。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
