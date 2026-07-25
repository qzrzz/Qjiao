//
//  VisualEffectView.swift
//  kero
//

import AppKit
import SwiftUI

/// Native translucent material background (behind-window blur).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material? = nil
    var blendingMode: NSVisualEffectView.BlendingMode? = nil
    var state: NSVisualEffectView.State? = nil
    var alphaValue: CGFloat? = nil
    var followsApplicationActivity = false

    @ObservedObject private var settings = AppSettings.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        applySettings(to: view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        applySettings(to: view, context: context)
    }

    private func applySettings(to view: NSVisualEffectView, context: Context) {
        view.material = material ?? settings.resolvedVisualEffectMaterial
        view.blendingMode = blendingMode ?? settings.resolvedVisualEffectBlendingMode
        view.alphaValue = alphaValue ?? CGFloat(settings.visualEffectAlpha)

        let isAppFollow = (state == nil && settings.visualEffectState == "followsApp") || followsApplicationActivity
        let explicitState = state ?? settings.resolvedVisualEffectState

        context.coordinator.configure(
            view,
            explicitState: explicitState,
            followsApplicationActivity: isAppFollow
        )
    }

    final class Coordinator {
        private weak var view: NSVisualEffectView?
        private var explicitState: NSVisualEffectView.State?
        private var followsApplicationActivity = false
        private var observers: [NSObjectProtocol] = []

        func configure(
            _ view: NSVisualEffectView,
            explicitState: NSVisualEffectView.State?,
            followsApplicationActivity: Bool
        ) {
            self.view = view
            self.explicitState = explicitState
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
            if let explicitState {
                view?.state = explicitState
            } else if followsApplicationActivity {
                view?.state = NSApp.isActive ? .active : .inactive
            } else {
                view?.state = .followsWindowActiveState
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
