//
//  DisplayCycleLayoutProtection.swift
//  kero
//
//  Created for Qjiao.
//

import AppKit
import Foundation
import ObjectiveC

/// 保护在 AppKit `NSDisplayCycleFlush` / `hitTest` 过程中由 SwiftUI (`ScrollViewCommitMutation`)
/// 触发的 `NSHostingView.requestUpdate` -> `setNeedsLayout:` -> `_postWindowNeedsLayout`
/// 避免 AppKit 抛出 `NSException` 导致 SIGABRT 崩溃。
///
/// 检测必须走廉价路径：旧实现每次 `_postWindowNeedsLayout` 都 `Thread.callStackSymbols`
/// 符号化（毫秒级），窗口视图变多后主线程会被刷帧拖死。延迟提交按窗口合并，
/// 避免一次 display cycle 里排队出成百上千个 `DispatchQueue.main.async`。
@MainActor
enum DisplayCycleLayoutProtection {
    private static var isInstalled = false

    /// 安装 NSView/NSWindow 方法替换（Swizzling）以防范 display cycle 刷新期间的 re-entrant 布局修改崩溃。
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        swizzleHitTest()
        swizzlePostWindowNeedsLayout()
        // 读不到 `_observersByPhase` 时，用窗口 layout/display 嵌套深度兜底。
        if DisplayCycleProbe.observersIvar == nil {
            swizzleWindowSelector(
                #selector(NSWindow.layoutIfNeeded),
                #selector(NSWindow.qjiao_swizzled_layoutIfNeeded)
            )
            swizzleWindowSelector(
                #selector(NSWindow.displayIfNeeded),
                #selector(NSWindow.qjiao_swizzled_displayIfNeeded)
            )
        }
    }

    private static func swizzleHitTest() {
        let viewClass: AnyClass = NSView.self
        let originalSelector = #selector(NSView.hitTest(_:))
        let swizzledSelector = #selector(NSView.qjiao_swizzled_hitTest(_:))

        guard let originalMethod = class_getInstanceMethod(viewClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(viewClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    private static func swizzlePostWindowNeedsLayout() {
        let windowClass: AnyClass = NSWindow.self
        let originalSelector = Selector(("_postWindowNeedsLayout"))
        let swizzledSelector = #selector(NSWindow.qjiao_swizzled_postWindowNeedsLayout)

        guard let originalMethod = class_getInstanceMethod(windowClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(windowClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    private static func swizzleWindowSelector(_ original: Selector, _ swizzled: Selector) {
        let windowClass: AnyClass = NSWindow.self
        guard let originalMethod = class_getInstanceMethod(windowClass, original),
              let swizzledMethod = class_getInstanceMethod(windowClass, swizzled) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

// MARK: - Cheap cycle detection

private enum DisplayCycleProbe {
    private static let hitTestDepthKey = "Qjiao_HitTestDepth"
    private static let displayDepthKey = "Qjiao_DisplayIfNeededDepth"
    private static let currentSelector = NSSelectorFromString("currentDisplayCycle")

    static let cycleClass: AnyClass? = NSClassFromString("NSDisplayCycle")
    static let observersIvar: Ivar? = {
        guard let cls = cycleClass else { return nil }
        return class_getInstanceVariable(cls, "_observersByPhase")
    }()

    private static let currentCycle: (@convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?)? = {
        guard let cls = cycleClass,
              let method = class_getClassMethod(cls, currentSelector)
        else { return nil }
        return unsafeBitCast(
            method_getImplementation(method),
            to: (@convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?).self
        )
    }()

    static var isInsideHitTest: Bool {
        (Thread.current.threadDictionary[hitTestDepthKey] as? Int ?? 0) > 0
    }

    static var isInsideDisplayIfNeeded: Bool {
        (Thread.current.threadDictionary[displayDepthKey] as? Int ?? 0) > 0
    }

    /// AppKit 正在冲刷当前 display cycle（约束 / 布局 / 绘制观察者未清空）。
    static var isFlushingDisplayCycle: Bool {
        guard let cls = cycleClass,
              let currentCycle,
              let cycle = currentCycle(cls, currentSelector)?.takeUnretainedValue()
        else { return false }
        if let ivar = observersIvar, let raw = object_getIvar(cycle, ivar) {
            if let table = raw as? NSMapTable<AnyObject, AnyObject> {
                return table.count > 0
            }
            if let count = (raw as AnyObject).value(forKey: "count") as? Int {
                return count > 0
            }
        }
        if let table = (cycle as AnyObject).value(forKey: "observersByPhase")
            as? NSMapTable<AnyObject, AnyObject>
        {
            return table.count > 0
        }
        return false
    }

    static var shouldDeferLayout: Bool {
        if isInsideHitTest { return true }
        if observersIvar != nil { return isFlushingDisplayCycle }
        return isInsideDisplayIfNeeded
    }

    static func pushHitTest() {
        adjustDepth(key: hitTestDepthKey, delta: 1)
    }

    static func popHitTest() {
        adjustDepth(key: hitTestDepthKey, delta: -1)
    }

    static func pushDisplayIfNeeded() {
        adjustDepth(key: displayDepthKey, delta: 1)
    }

    static func popDisplayIfNeeded() {
        adjustDepth(key: displayDepthKey, delta: -1)
    }

    private static func adjustDepth(key: String, delta: Int) {
        let dict = Thread.current.threadDictionary
        let next = (dict[key] as? Int ?? 0) + delta
        if next <= 0 {
            dict.removeObject(forKey: key)
        } else {
            dict[key] = next
        }
    }
}

// MARK: - Coalesced deferral

/// 主线程专用：把同一轮 display cycle / hitTest 里的多次 `_postWindowNeedsLayout` 合成一次。
private enum DisplayCycleLayoutQueue {
    private static let pending = NSHashTable<NSWindow>.weakObjects()
    private static var scheduled = false
    private static let installCompletionSelector = NSSelectorFromString(
        "_installDisplayCycleCompletionBlock:"
    )
    private static let installCompletion: (
        @convention(c) (AnyClass, Selector, @escaping () -> Void) -> Void
    )? = {
        let cls: AnyClass = NSApplication.self
        guard let method = class_getClassMethod(cls, installCompletionSelector) else {
            return nil
        }
        return unsafeBitCast(
            method_getImplementation(method),
            to: (@convention(c) (AnyClass, Selector, @escaping () -> Void) -> Void).self
        )
    }()

    static func schedule(_ window: NSWindow) {
        pending.add(window)
        guard !scheduled else { return }
        scheduled = true
        // 已在冲刷中：挂到本轮 cycle 收尾，同帧提交，避免再等一个 runloop。
        // hitTest（通常 observers 为空）则下一拍主队列再发。
        if DisplayCycleProbe.isFlushingDisplayCycle, let installCompletion {
            installCompletion(NSApplication.self, installCompletionSelector, flush)
        } else {
            DispatchQueue.main.async(execute: flush)
        }
    }

    private static func flush() {
        scheduled = false
        let windows = pending.allObjects
        pending.removeAllObjects()
        var stillDeferred = false
        for window in windows {
            if DisplayCycleProbe.shouldDeferLayout {
                pending.add(window)
                stillDeferred = true
            } else {
                window.qjiao_swizzled_postWindowNeedsLayout()
            }
        }
        // 仍不安全时改走下一拍主队列，避免 completion block 与冲刷重叠死循环。
        if stillDeferred {
            scheduled = true
            DispatchQueue.main.async(execute: flush)
        }
    }
}

private extension NSView {
    /// 拦截 NSView.hitTest，标记当前线程正在执行 hit-testing 流程。
    /// - Parameter point: 命中测试点坐标
    /// - Returns: 命中的 NSView 实例或 nil
    @objc func qjiao_swizzled_hitTest(_ point: NSPoint) -> NSView? {
        DisplayCycleProbe.pushHitTest()
        defer { DisplayCycleProbe.popHitTest() }
        return self.qjiao_swizzled_hitTest(point)
    }
}

private extension NSWindow {
    /// 拦截 NSWindow._postWindowNeedsLayout，若处于 hitTest 或 NSDisplayCycleFlush 期间则延迟提交。
    @objc func qjiao_swizzled_postWindowNeedsLayout() {
        if DisplayCycleProbe.shouldDeferLayout {
            DisplayCycleLayoutQueue.schedule(self)
            return
        }
        self.qjiao_swizzled_postWindowNeedsLayout()
    }

    /// 仅在读不到 `_observersByPhase` 时启用：用窗口 layout/display 嵌套深度兜底。
    @objc func qjiao_swizzled_layoutIfNeeded() {
        DisplayCycleProbe.pushDisplayIfNeeded()
        defer { DisplayCycleProbe.popDisplayIfNeeded() }
        self.qjiao_swizzled_layoutIfNeeded()
    }

    @objc func qjiao_swizzled_displayIfNeeded() {
        DisplayCycleProbe.pushDisplayIfNeeded()
        defer { DisplayCycleProbe.popDisplayIfNeeded() }
        self.qjiao_swizzled_displayIfNeeded()
    }
}
