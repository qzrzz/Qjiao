//
//  MacTooltip.swift
//  Qjiao
//
//  原生 macOS 风格 Tooltip：独立 NSPanel 浮层，避免被侧栏 / ScrollView 裁切；
//  使用 NSVisualEffectView(.toolTip + .behindWindow) 实现真实毛玻璃背景。
//

import AppKit
import SwiftUI

/// 原生 macOS Tooltip 弹出方位（相对锚点控件）
enum MacTooltipPosition {
    case bottom
    case top
    case leading
    case trailing
}

// MARK: - Presenter (single global panel)

@MainActor
enum MacTooltipPresenter {
    private static var panel: NSPanel?
    /// 透明根容器（大于气泡，给 layer 阴影留边，避免被窗口裁切）。
    private static var rootView: NSView?
    /// 实际气泡（毛玻璃 + 描边 + 投影源）。
    private static var bubbleView: NSView?
    private static var effectView: NSVisualEffectView?
    private static var titleLabel: NSTextField?
    private static var shortcutLabel: NSTextField?
    private static var shortcutContainer: NSView?
    private static var contentStack: NSStackView?
    private static var showTask: Task<Void, Never>?
    private static weak var currentAnchor: NSView?
    private static weak var parentWindow: NSWindow?
    private static var resignObserver: NSObjectProtocol?
    private static var moveObserver: NSObjectProtocol?

    private static let gap: CGFloat = 6
    private static let horizontalPadding: CGFloat = 7
    private static let verticalPadding: CGFloat = 3.5
    private static let cornerRadius: CGFloat = 5
    /// 窗口比气泡多出的边距，专门容纳轻投影（系统窗口会裁掉 bounds 外阴影）。
    private static let shadowOutset: CGFloat = 8

    /// 延迟展示；同一时刻全局仅一个 tooltip。
    static func scheduleShow(
        text: String,
        shortcut: String?,
        anchor: NSView,
        position: MacTooltipPosition,
        delay: TimeInterval
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, anchor.window != nil else { return }

        cancelShowTask()
        currentAnchor = anchor

        showTask = Task { @MainActor in
            let nanos = UInt64(max(0, delay) * 1_000_000_000)
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled else { return }
            guard currentAnchor === anchor, anchor.window != nil else { return }
            showNow(text: trimmed, shortcut: shortcut, anchor: anchor, position: position)
        }
    }

    static func hide(for anchor: NSView? = nil) {
        if let anchor, let currentAnchor, currentAnchor !== anchor {
            return
        }
        cancelShowTask()
        currentAnchor = nil
        detachFromParent()
        panel?.orderOut(nil)
    }

    private static func cancelShowTask() {
        showTask?.cancel()
        showTask = nil
    }

    private static func showNow(
        text: String,
        shortcut: String?,
        anchor: NSView,
        position: MacTooltipPosition
    ) {
        guard let hostWindow = anchor.window else { return }
        let panel = ensurePanel()
        updateContent(text: text, shortcut: shortcut)

        contentStack?.layoutSubtreeIfNeeded()
        effectView?.layoutSubtreeIfNeeded()
        let fitting = contentStack?.fittingSize
            ?? CGSize(width: 80, height: 22)
        let bubbleSize = CGSize(
            width: max(ceil(fitting.width), 24),
            height: max(ceil(fitting.height), 18)
        )
        let panelSize = CGSize(
            width: bubbleSize.width + shadowOutset * 2,
            height: bubbleSize.height + shadowOutset * 2
        )
        layoutBubble(bubbleSize: bubbleSize, panelSize: panelSize)

        let rectInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorScreen = hostWindow.convertToScreen(rectInWindow)
        // 定位按「气泡」几何算，再减去阴影边距得到窗口原点。
        let bubbleOrigin = clampedOrigin(
            preferred: position,
            anchorScreen: anchorScreen,
            size: bubbleSize,
            screen: hostWindow.screen ?? NSScreen.main
        )
        let panelOrigin = CGPoint(
            x: bubbleOrigin.x - shadowOutset,
            y: bubbleOrigin.y - shadowOutset
        )
        panel.setFrame(CGRect(origin: panelOrigin, size: panelSize), display: true)

        if parentWindow !== hostWindow {
            detachFromParent()
            hostWindow.addChildWindow(panel, ordered: .above)
            parentWindow = hostWindow
            installWindowObservers(for: hostWindow)
        }

        panel.appearance = hostWindow.effectiveAppearance
        effectView?.appearance = hostWindow.effectiveAppearance
        updateChromeColors(bubbleSize: bubbleSize)

        panel.orderFront(nil)
    }

    private static func layoutBubble(bubbleSize: CGSize, panelSize: CGSize) {
        panel?.setContentSize(panelSize)
        rootView?.frame = NSRect(origin: .zero, size: panelSize)
        // AppKit 坐标原点在左下：气泡居中于透明根容器。
        bubbleView?.frame = NSRect(
            x: shadowOutset,
            y: shadowOutset,
            width: bubbleSize.width,
            height: bubbleSize.height
        )
        effectView?.frame = bubbleView?.bounds ?? .zero
    }

    private static func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 不用系统窗口阴影（过重）；在扩大后的透明窗口内画轻 layer 阴影。
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 38))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        // 气泡本体：投影源（不 masksToBounds）
        let bubble = NSView(frame: NSRect(x: shadowOutset, y: shadowOutset, width: 80, height: 22))
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = cornerRadius
        bubble.layer?.masksToBounds = false
        bubble.layer?.backgroundColor = NSColor.clear.cgColor
        bubble.layer?.shadowColor = NSColor.black.cgColor
        bubble.layer?.shadowOpacity = 0.18
        bubble.layer?.shadowRadius = 3
        bubble.layer?.shadowOffset = CGSize(width: 0, height: -0.5)

        // 真毛玻璃：behindWindow 模糊面板下方内容（含宿主窗口）。
        let effect = NSVisualEffectView(frame: bubble.bounds)
        effect.material = .toolTip
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let title = makeLabel(weight: .regular, color: .labelColor)
        let shortcut = makeLabel(weight: .semibold, color: .secondaryLabelColor)
        shortcut.font = .systemFont(ofSize: 10, weight: .semibold)

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3.5
        badge.translatesAutoresizingMaskIntoConstraints = false
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(shortcut)
        NSLayoutConstraint.activate([
            shortcut.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 4),
            shortcut.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -4),
            shortcut.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            shortcut.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1),
        ])

        let stack = NSStackView(views: [title, badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(
            top: verticalPadding,
            left: horizontalPadding,
            bottom: verticalPadding,
            right: horizontalPadding
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        bubble.addSubview(effect)
        root.addSubview(bubble)
        panel.contentView = root

        self.panel = panel
        self.rootView = root
        self.bubbleView = bubble
        self.effectView = effect
        self.titleLabel = title
        self.shortcutLabel = shortcut
        self.shortcutContainer = badge
        self.contentStack = stack
        updateChromeColors(bubbleSize: bubble.bounds.size)
        return panel
    }

    private static func makeLabel(weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: weight)
        label.textColor = color
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private static func updateContent(text: String, shortcut: String?) {
        titleLabel?.stringValue = text
        let hasShortcut = !(shortcut?.isEmpty ?? true)
        shortcutLabel?.stringValue = shortcut ?? ""
        shortcutContainer?.isHidden = !hasShortcut
        contentStack?.layoutSubtreeIfNeeded()
        effectView?.layoutSubtreeIfNeeded()
    }

    private static func updateChromeColors(bubbleSize: CGSize) {
        // 轻投影：画在 bubble 上，落在 root 透明边距内
        if let bubble = bubbleView {
            bubble.layer?.shadowColor = NSColor.black.cgColor
            bubble.layer?.shadowOpacity = 0.18
            bubble.layer?.shadowRadius = 3
            bubble.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
            if bubbleSize.width > 0, bubbleSize.height > 0 {
                bubble.layer?.shadowPath = CGPath(
                    roundedRect: CGRect(origin: .zero, size: bubbleSize),
                    cornerWidth: cornerRadius,
                    cornerHeight: cornerRadius,
                    transform: nil
                )
            }
        }
        // 描边放轻：接近系统 tooltip 的细边
        effectView?.layer?.borderWidth = 0.5
        effectView?.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.18).cgColor
        shortcutContainer?.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(0.08).cgColor
        titleLabel?.textColor = .labelColor
        shortcutLabel?.textColor = .secondaryLabelColor
    }

    /// 优先按 preferred 放置；放不下则翻转；再夹进屏幕可见区。
    private static func clampedOrigin(
        preferred: MacTooltipPosition,
        anchorScreen: CGRect,
        size: CGSize,
        screen: NSScreen?
    ) -> CGPoint {
        let visible = screen?.visibleFrame
            ?? NSRect(origin: .zero, size: size)
        let candidates = orderedPositions(preferred)

        for position in candidates {
            let origin = origin(for: position, anchor: anchorScreen, size: size)
            let frame = CGRect(origin: origin, size: size)
            if visible.insetBy(dx: 2, dy: 2).contains(frame) {
                return origin
            }
        }

        var origin = origin(for: preferred, anchor: anchorScreen, size: size)
        origin.x = min(
            max(origin.x, visible.minX + 2),
            max(visible.maxX - size.width - 2, visible.minX + 2)
        )
        origin.y = min(
            max(origin.y, visible.minY + 2),
            max(visible.maxY - size.height - 2, visible.minY + 2)
        )
        return origin
    }

    private static func orderedPositions(_ preferred: MacTooltipPosition) -> [MacTooltipPosition] {
        switch preferred {
        case .top: return [.top, .bottom, .trailing, .leading]
        case .bottom: return [.bottom, .top, .trailing, .leading]
        case .leading: return [.leading, .trailing, .top, .bottom]
        case .trailing: return [.trailing, .leading, .top, .bottom]
        }
    }

    /// Cocoa 屏幕坐标：原点在左下，y 向上。
    private static func origin(
        for position: MacTooltipPosition,
        anchor: CGRect,
        size: CGSize
    ) -> CGPoint {
        switch position {
        case .top:
            return CGPoint(
                x: anchor.midX - size.width / 2,
                y: anchor.maxY + gap
            )
        case .bottom:
            return CGPoint(
                x: anchor.midX - size.width / 2,
                y: anchor.minY - gap - size.height
            )
        case .leading:
            return CGPoint(
                x: anchor.minX - gap - size.width,
                y: anchor.midY - size.height / 2
            )
        case .trailing:
            return CGPoint(
                x: anchor.maxX + gap,
                y: anchor.midY - size.height / 2
            )
        }
    }

    private static func installWindowObservers(for window: NSWindow) {
        removeWindowObservers()
        let center = NotificationCenter.default
        resignObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in hide() }
        }
        moveObserver = center.addObserver(
            forName: NSWindow.willMoveNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in hide() }
        }
    }

    private static func removeWindowObservers() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
    }

    private static func detachFromParent() {
        if let panel, let parentWindow {
            parentWindow.removeChildWindow(panel)
        }
        parentWindow = nil
        removeWindowObservers()
    }
}

// MARK: - SwiftUI bridge

/// 持有锚点 NSView，供 `onHover` 取屏幕坐标。
private final class MacTooltipAnchorHolder {
    weak var view: NSView?
}

private struct MacTooltipAnchorInstaller: NSViewRepresentable {
    let holder: MacTooltipAnchorHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MacTooltipPresenter.hide(for: nsView)
    }
}

/// 原生 macOS 风格 Tooltip 视图修饰符
struct MacTooltipModifier: ViewModifier {
    let text: String
    var shortcut: String? = nil
    var position: MacTooltipPosition = .bottom
    var delay: Double = 0.1

    /// 用 class 引用保持锚点；`@State` 保证 modifier 重建时不丢实例。
    @State private var anchorHolder = MacTooltipAnchorHolder()

    func body(content: Content) -> some View {
        content
            .background(
                MacTooltipAnchorInstaller(holder: anchorHolder)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                if hovering {
                    guard let anchor = anchorHolder.view, anchor.window != nil else { return }
                    MacTooltipPresenter.scheduleShow(
                        text: text,
                        shortcut: shortcut,
                        anchor: anchor,
                        position: position,
                        delay: delay
                    )
                } else {
                    MacTooltipPresenter.hide(for: anchorHolder.view)
                }
            }
            .onDisappear {
                MacTooltipPresenter.hide(for: anchorHolder.view)
            }
    }
}

extension View {
    /// 挂载原生 macOS 风格的极速 Tooltip（独立浮层，不裁切、真模糊）。
    /// - Parameters:
    ///   - text: 提示标题文本
    ///   - shortcut: 快捷键文本（如 "⌘0"）
    ///   - position: 弹出方位 (默认 .bottom)
    ///   - delay: 悬停出现延迟秒数 (默认 0.1 秒)
    func macTooltip(
        _ text: String?,
        shortcut: String? = nil,
        position: MacTooltipPosition = .bottom,
        delay: Double = 0.1
    ) -> some View {
        guard let text, !text.isEmpty else { return AnyView(self) }
        return AnyView(self.modifier(MacTooltipModifier(
            text: text,
            shortcut: shortcut,
            position: position,
            delay: delay
        )))
    }
}
