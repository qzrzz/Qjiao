//
//  Tooltip.swift
//  kero
//

import AppKit
import SwiftUI

/// Which side of the anchor view the label hangs off. Controls near the top
/// of a panel use `.below` so the label doesn't run off the window edge.
enum TooltipEdge {
    case above
    case below
}

extension View {
    /// A styled stand-in for `.help()`: same hover-to-reveal behavior, but
    /// themed with the app's materials and quicker than the system's delay.
    ///
    /// 标签通过 Preference 上报锚点；祖先需调用 `tooltipHost()` 在最上层绘制，
    /// 这样不会被 ScrollView 裁剪，也不会被顶栏盖住。
    func tooltip(
        _ text: String,
        edge: TooltipEdge = .above,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        modifier(TooltipModifier(text: text, edge: edge, alignment: alignment))
    }

    /// 在容器最上层绘制 tooltip（加在面板根上，浮于 header / 列表之上）。
    func tooltipHost() -> some View {
        modifier(TooltipHostModifier())
    }
}

// MARK: - Preference

private struct TooltipRequest: Equatable {
    var text: String
    var edge: TooltipEdge
    var alignment: HorizontalAlignment
    var anchor: Anchor<CGRect>
}

private struct TooltipPreferenceKey: PreferenceKey {
    static var defaultValue: [TooltipRequest] { [] }

    static func reduce(value: inout [TooltipRequest], nextValue: () -> [TooltipRequest]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Source

private struct TooltipModifier: ViewModifier {
    let text: String
    let edge: TooltipEdge
    let alignment: HorizontalAlignment

    @State private var isVisible = false
    @State private var revealTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: TooltipPreferenceKey.self, value: .bounds) { anchor in
                guard isVisible, !text.isEmpty else { return [] }
                return [
                    TooltipRequest(
                        text: text,
                        edge: edge,
                        alignment: alignment,
                        anchor: anchor
                    ),
                ]
            }
            .onHover { hovering in
                revealTask?.cancel()
                guard hovering else {
                    isVisible = false
                    return
                }
                revealTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.1)) { isVisible = true }
                }
            }
            .onDisappear {
                revealTask?.cancel()
                isVisible = false
            }
    }
}

// MARK: - Host

private struct TooltipHostModifier: ViewModifier {
    private static let gap: CGFloat = 6
    private static let fontSize: CGFloat = 11
    /// 多行时行距，让 System 指标等多行说明更易扫读。
    private static let multilineLineSpacing: CGFloat = 2
    private static let maxMeasureWidth: CGFloat = 320
    private static let horizontalPadding: CGFloat = 7
    private static let verticalPadding: CGFloat = 4

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TooltipPreferenceKey.self) { requests in
            GeometryReader { geo in
                ForEach(Array(requests.enumerated()), id: \.offset) { _, request in
                    let anchor = geo[request.anchor]
                    let size = measureLabel(request.text)
                    let origin = labelOrigin(
                        anchor: anchor,
                        labelSize: size,
                        edge: request.edge,
                        alignment: request.alignment
                    )
                    tooltipLabel(request.text)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func tooltipLabel(_ text: String) -> some View {
        let multiline = text.contains("\n")
        return Text(text)
            // 单行：比例字 + monospacedDigit（数字/IP 不跳）。
            // 多行：等宽字 + monospacedDigit，标签栏空格填充才能列对齐（Mem/Disk 指标）。
            .font(Self.labelFont(multiline: multiline))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(multiline ? Self.multilineLineSpacing : 0)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
    }

    private static func labelFont(multiline: Bool) -> Font {
        if multiline {
            return .system(size: fontSize, design: .monospaced).monospacedDigit()
        }
        return .system(size: fontSize).monospacedDigit()
    }

    /// 用 NSString 估算标签尺寸，避免再套一层 Preference 循环。
    /// 字体需与 `tooltipLabel` 一致，否则多行会对不齐或被裁切。
    private func measureLabel(_ text: String) -> CGSize {
        let multiline = text.contains("\n")
        let font: NSFont = multiline
            ? .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
            : .monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        if multiline {
            // NSString 测高不直接吃 SwiftUI lineSpacing；用额外行高近似。
            paragraph.lineSpacing = Self.multilineLineSpacing
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]
        let ns = text as NSString
        let bounds = ns.boundingRect(
            with: CGSize(width: Self.maxMeasureWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return CGSize(
            width: ceil(bounds.width) + Self.horizontalPadding * 2,
            height: ceil(bounds.height) + Self.verticalPadding * 2
        )
    }

    private func labelOrigin(
        anchor: CGRect,
        labelSize: CGSize,
        edge: TooltipEdge,
        alignment: HorizontalAlignment
    ) -> CGPoint {
        let x: CGFloat
        switch alignment {
        case .trailing:
            x = anchor.maxX - labelSize.width
        case .center:
            x = anchor.midX - labelSize.width / 2
        default:
            x = anchor.minX
        }

        let y: CGFloat
        switch edge {
        case .above:
            y = anchor.minY - Self.gap - labelSize.height
        case .below:
            y = anchor.maxY + Self.gap
        }
        return CGPoint(x: x, y: y)
    }
}
