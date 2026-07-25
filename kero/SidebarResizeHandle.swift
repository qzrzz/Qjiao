//
//  SidebarResizeHandle.swift
//  kero
//

import AppKit
import SwiftUI

/// Invisible drag strip overlaid on a sidebar's inner edge. Dragging
/// resizes within `range`; double-click snaps back to `defaultWidth`.
struct SidebarResizeHandle: View {
    /// Edge of the sidebar this handle sits on: `.trailing` for the left
    /// sidebar, `.leading` for the right one (flips the drag direction).
    let edge: HorizontalEdge
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double

    @State private var baseline: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .contentShape(Rectangle())
            // Not `NSCursor.columnResize.push()` from `onHover`, which looks
            // equivalent but loses: it pushes onto the shared cursor stack from
            // outside AppKit's own pointer resolution, and AppKit resets the
            // pointer as it leaves a registered cursor rect — which is what a
            // neighbouring editor is covered in (STTextView adds an I-beam rect
            // over its text). Coming off the text onto the handle, that reset
            // lands after the push and wins, so the handle dragged fine while
            // showing a plain arrow, giving no sign it was there.
            // `pointerStyle` registers through the same resolution instead.
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = baseline ?? width
                        baseline = base
                        let delta = edge == .trailing
                            ? value.translation.width
                            : -value.translation.width
                        width = min(max(base + delta, range.lowerBound), range.upperBound)
                        NSCursor.columnResize.set()
                    }
                    .onEnded { _ in baseline = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { width = defaultWidth }
            )
    }
}

/// 水平分割条：拖动改变上下区域的高度占比；双击恢复默认比例。
///
/// `availableHeight` 是分割条两侧内容区的总高度（不含固定 chrome），
/// 用于把像素位移换算成 fraction。
///
/// 当提供 `isCollapsed` 时：下半区可收起到仅保留 `collapsedBottomHeight`；
/// 从收起状态向上拖会展开，拖到贴底阈值高度会自动收起。
struct VerticalSplitHandle: View {
    @Binding var fraction: Double
    let range: ClosedRange<Double>
    let defaultFraction: Double
    /// 上半 + 下半内容区合计高度，拖动时用位移 / 此值更新比例。
    let availableHeight: CGFloat
    /// 下半区是否收起为仅 tabs；nil 表示不支持收起。
    var isCollapsed: Binding<Bool>? = nil
    /// 收起时下半区高度（通常为 tabs 栏高度）。
    var collapsedBottomHeight: CGFloat = 0

    @State private var baseline: Double?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
            // 加宽命中区，避免只能点中 1pt 分割线。
            Rectangle()
                .fill(Color.clear)
                .frame(height: 7)
                .contentShape(Rectangle())
                .pointerStyle(.rowResize)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            applyDrag(translation: value.translation.height)
                            NSCursor.rowResize.set()
                        }
                        .onEnded { _ in baseline = nil }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        isCollapsed?.wrappedValue = false
                        fraction = defaultFraction
                    }
                )
        }
        .frame(height: 7)
        .accessibilityLabel("Resize right sidebar sections")
    }

    /// 收起时上半区视觉占比：下半仅留 tabs。
    private var collapsedTopFraction: Double {
        let span = max(availableHeight, 1)
        return min(max(Double((availableHeight - collapsedBottomHeight) / span), range.lowerBound), range.upperBound)
    }

    private func applyDrag(translation: CGFloat) {
        let span = max(availableHeight, 1)
        // 从收起态开始拖：以当前「仅 tabs」视觉高度为基准展开。
        if let collapsed = isCollapsed, collapsed.wrappedValue {
            collapsed.wrappedValue = false
            let start = collapsedTopFraction
            baseline = start
            let next = start + translation / span
            commitFraction(next, span: span)
            return
        }

        let base = baseline ?? fraction
        baseline = base
        let next = base + translation / span
        commitFraction(next, span: span)
    }

    private func commitFraction(_ raw: Double, span: CGFloat) {
        let next = min(max(raw, range.lowerBound), range.upperBound)
        // 下半区高度贴近 tabs 栏时视为收起，内容完全隐藏。
        if let collapsed = isCollapsed, collapsedBottomHeight > 0 {
            let bottomHeight = span * (1 - next)
            if bottomHeight <= collapsedBottomHeight + 1 {
                collapsed.wrappedValue = true
                fraction = collapsedTopFraction
                return
            }
            collapsed.wrappedValue = false
        }
        fraction = next
    }
}
