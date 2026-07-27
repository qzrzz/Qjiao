//
//  MacTooltip.swift
//  Qjiao
//
//  原生 macOS 风格可复用 Tooltip 系统
//

import SwiftUI

/// 原生 macOS Tooltip 弹出方位
enum MacTooltipPosition {
    case bottom
    case top
    case leading
    case trailing
}

/// 原生 macOS 视觉风格 Tooltip 气泡视图
struct MacTooltipView: View {
    let text: String
    var shortcut: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.primary)

            if let shortcut, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Material.regularMaterial)
                .shadow(color: Color.black.opacity(0.14), radius: 3, x: 0, y: 1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// 原生 macOS 风格 Tooltip 视图修饰符
struct MacTooltipModifier: ViewModifier {
    let text: String
    var shortcut: String? = nil
    var position: MacTooltipPosition = .bottom
    var delay: Double = 0.1

    @State private var isHovered: Bool = false
    @State private var showTooltip: Bool = false
    @State private var hoverTask: Task<Void, Never>? = nil

    func body(content: Content) -> some View {
        content
            .onHover { over in
                isHovered = over
                hoverTask?.cancel()

                if over {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        if !Task.isCancelled {
                            await MainActor.run {
                                withAnimation(.easeIn(duration: 0.08)) {
                                    showTooltip = true
                                }
                            }
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.06)) {
                        showTooltip = false
                    }
                }
            }
            .overlay(alignment: overlayAlignment) {
                if showTooltip && !text.isEmpty {
                    MacTooltipView(text: text, shortcut: shortcut)
                        .offset(offsetAmount)
                        .zIndex(9999)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(isHovered ? 100 : 1)
    }

    private var overlayAlignment: Alignment {
        switch position {
        case .bottom: return .bottom
        case .top: return .top
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    private var offsetAmount: CGSize {
        switch position {
        case .bottom: return CGSize(width: 0, height: 30)
        case .top: return CGSize(width: 0, height: -30)
        case .leading: return CGSize(width: -8, height: 0)
        case .trailing: return CGSize(width: 8, height: 0)
        }
    }
}

extension View {
    /// 挂载原生 macOS 风格的极速 Tooltip 系统
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
