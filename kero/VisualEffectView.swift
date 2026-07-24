//
//  VisualEffectView.swift
//  kero
//

import AppKit
import SwiftUI

/// Native translucent material background (behind-window blur).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    /// A settings window becoming key should not make the app's main window
    /// look disabled. When enabled, the material follows application activity
    /// rather than this individual window's key status.
    var followsApplicationActivity = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        context.coordinator.configure(
            view,
            followsApplicationActivity: followsApplicationActivity
        )
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        context.coordinator.configure(
            view,
            followsApplicationActivity: followsApplicationActivity
        )
    }

    final class Coordinator {
        private weak var view: NSVisualEffectView?
        private var followsApplicationActivity = false
        private var observers: [NSObjectProtocol] = []

        func configure(
            _ view: NSVisualEffectView,
            followsApplicationActivity: Bool
        ) {
            self.view = view
            let behaviorChanged = self.followsApplicationActivity != followsApplicationActivity
            guard behaviorChanged || (followsApplicationActivity && observers.isEmpty) else {
                updateState()
                return
            }
            self.followsApplicationActivity = followsApplicationActivity
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            if followsApplicationActivity {
                let center = NotificationCenter.default
                observers = [
                    center.addObserver(
                        forName: NSApplication.didBecomeActiveNotification,
                        object: NSApp,
                        queue: .main
                    ) { [weak self] _ in self?.updateState() },
                    center.addObserver(
                        forName: NSApplication.didResignActiveNotification,
                        object: NSApp,
                        queue: .main
                    ) { [weak self] _ in self?.updateState() },
                ]
            }
            updateState()
        }

        private func updateState() {
            view?.state = followsApplicationActivity
                ? (NSApp.isActive ? .active : .inactive)
                : .followsWindowActiveState
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
