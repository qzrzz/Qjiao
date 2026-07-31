//
//  DisplayCycleLayoutProtection.swift
//  kero
//
//  Created for Qjiao.
//

import AppKit
import Foundation

/// 保护在 AppKit `NSDisplayCycleFlush` / `hitTest` 过程中由 SwiftUI (`ScrollViewCommitMutation`)
/// 触发的 `NSHostingView.requestUpdate` -> `setNeedsLayout:` -> `_postWindowNeedsLayout`
/// 避免 AppKit 抛出 `NSException` 导致 SIGABRT 崩溃。
@MainActor
enum DisplayCycleLayoutProtection {
    private static var isInstalled = false

    /// 安装 NSView/NSWindow 方法替换（Swizzling）以防范 display cycle 刷新期间的 re-entrant 布局修改崩溃。
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        swizzleHitTest()
        swizzlePostWindowNeedsLayout()
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
}

private extension NSView {
    /// 拦截 NSView.hitTest，标记当前线程正在执行 hit-testing 流程。
    /// - Parameter point: 命中测试点坐标
    /// - Returns: 命中的 NSView 实例或 nil
    @objc func qjiao_swizzled_hitTest(_ point: NSPoint) -> NSView? {
        let key = "Qjiao_IsInsideHitTest"
        let threadDict = Thread.current.threadDictionary
        let previous = threadDict[key] as? Bool ?? false
        threadDict[key] = true
        defer {
            if previous {
                threadDict[key] = true
            } else {
                threadDict.removeObject(forKey: key)
            }
        }
        return self.qjiao_swizzled_hitTest(point)
    }
}

private extension NSWindow {
    /// 拦截 NSWindow._postWindowNeedsLayout，若处于 hitTest 或 NSDisplayCycleFlush 期间则延迟异步提交。
    @objc func qjiao_swizzled_postWindowNeedsLayout() {
        let isInsideHitTest = Thread.current.threadDictionary["Qjiao_IsInsideHitTest"] as? Bool ?? false

        var isInsideDisplayCycle = isInsideHitTest
        if !isInsideDisplayCycle && Thread.isMainThread {
            let symbols = Thread.callStackSymbols
            for symbol in symbols.prefix(15) {
                if symbol.contains("NSDisplayCycle") || symbol.contains("displayCycle") || symbol.contains("hitTest") {
                    isInsideDisplayCycle = true
                    break
                }
            }
        }

        if isInsideDisplayCycle {
            // 当处于 NSDisplayCycle / hitTest 刷帧期间，将 _postWindowNeedsLayout 延迟到下一个主线程 runloop
            // 避免 AppKit 抛出 "setViewsNeedLayout: called during display cycle update" NSException 导致 SIGABRT 崩溃。
            DispatchQueue.main.async { [weak self] in
                self?.qjiao_swizzled_postWindowNeedsLayout()
            }
        } else {
            self.qjiao_swizzled_postWindowNeedsLayout()
        }
    }
}
