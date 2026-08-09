//
//  RightSidebarSharedViews.swift
//  kero
//

import SwiftUI

// MARK: - Shared panel chrome

/// 侧边栏/面板统一路径输入框样式控件。
/// 使用 TextField 纯文本框，界面字体 (caption)，次要颜色，右侧渐隐遮罩。
/// 当设置 `displayShortDirPath` 开启时，自动将用户 Home 目录替换为 `~`。
struct SidebarPathTextField: View {
    let path: String
    @ObservedObject private var settings = AppSettings.shared

    var formattedPath: String {
        guard !path.isEmpty else { return "—" }
        if settings.displayShortDirPath {
            return (path as NSString).abbreviatingWithTildeInPath
        }
        return path
    }

    var body: some View {
        TextField("", text: .constant(formattedPath))
            .textFieldStyle(.plain)
            .font(SidebarTypography.caption())
            .foregroundStyle(Theme.secondaryColor)
            .lineLimit(1)
            .help(path)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
    }
}

struct PanelHeader: View {
    let title: String
    let subtitle: String?
    var titleFont: Font = SidebarTypography.title()
    var subtitleTruncationMode: Text.TruncationMode = .head
    var isSubtitlePath: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(titleFont)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                if isSubtitlePath {
                    SidebarPathTextField(path: subtitle)
                } else {
                    Text(subtitle)
                        .font(SidebarTypography.caption())
                        // PID 作为辅助信息显示，但在浅色模式下保持足够对比度。
                        .foregroundStyle(Theme.secondaryColor)
                        .lineLimit(1)
                        .truncationMode(subtitleTruncationMode)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/** 将路径转义为可安全传给 shell 的单引号参数。 */
func rightSidebarShellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/** 侧边栏/面板统一图标按钮：标准 22x22 尺寸，5pt 圆角，支持 hover 态与 active 态。 */
struct SidebarIconButton: View {
    let systemImage: String
    let help: String
    var shortcut: String? = nil
    var active: Bool = false
    var disabled: Bool = false
    var tooltipPosition: MacTooltipPosition = .bottom
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidebarTypography.caption(.medium))
                .scaleEffect(systemImage.hasPrefix("doc") ? 0.86 : 1)
                .foregroundStyle(
                    active
                        ? Color(nsColor: Theme.cursor)
                        : (disabled ? Theme.secondaryColor.opacity(0.4) : (isHovering ? Theme.primaryColor : Theme.secondaryColor))
                )
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            active
                                ? Color(nsColor: Theme.cursor).opacity(0.12)
                                : (isHovering && !disabled ? Theme.primaryColor.opacity(0.08) : Color.clear)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: active)
        .macTooltip(help, shortcut: shortcut, position: tooltipPosition)
        .accessibilityLabel(help)
    }
}

/** 侧边栏/面板统一菜单图标按钮：带下拉菜单的标准图标按钮，支持 hover 态与 active 态。 */
struct SidebarMenuIconButton<Content: View>: View {
    let systemImage: String
    let help: String
    var shortcut: String? = nil
    var active: Bool = false
    var disabled: Bool = false
    /// 进行中时用 spinner 替换图标（如 Git 更多操作菜单）。
    var showsProgress: Bool = false
    var tooltipPosition: MacTooltipPosition = .bottom
    @ViewBuilder let menuContent: () -> Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            ZStack {
                if showsProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 11, height: 11)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: systemImage)
                        .font(SidebarTypography.caption(.medium))
                        .foregroundStyle(
                            active
                                ? Color(nsColor: Theme.cursor)
                                : (disabled ? Theme.secondaryColor.opacity(0.4) : (isHovering ? Theme.primaryColor : Theme.secondaryColor))
                        )
                }
            }
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        active
                            ? Color(nsColor: Theme.cursor).opacity(0.12)
                            : (isHovering && !disabled ? Theme.primaryColor.opacity(0.08) : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: active)
        .macTooltip(help, shortcut: shortcut, position: tooltipPosition)
        .accessibilityLabel(help)
    }
}

/** Project / Info 共用的刷新按钮：hover 高亮，刷新期间旋转并禁止重复点击。 */
struct SidebarRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let helpText = isRefreshing ? L10n.t("Refreshing…") : L10n.t("Refresh")
        return Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(
                    isRefreshing
                        ? Color(nsColor: Theme.cursor)
                        : (isHovering ? Theme.primaryColor : Theme.secondaryColor)
                )
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(
                    isRefreshing
                        ? .linear(duration: 0.7).repeatForever(autoreverses: false)
                        : .default,
                    value: isRefreshing
                )
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            isHovering && !isRefreshing
                                ? Theme.primaryColor.opacity(0.08)
                                : Color.clear
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .macTooltip(helpText, position: .bottom)
        .accessibilityLabel(helpText)
    }
}

/// 分组标题行内操作按钮：行 hover 时提高不透明度，自身 hover 时浅底高亮 + Tooltip；支持工作中转圈。
private struct SidebarSectionHeaderActionButton: View {
    let systemImage: String
    let help: String
    let disabled: Bool
    var showsProgress: Bool = false
    var activeColor: Color? = nil
    let rowHovering: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: systemImage)
                        .font(SidebarTypography.micro())
                }
            }
            .foregroundStyle(
                (disabled || showsProgress)
                    ? Theme.secondaryColor.opacity(0.35)
                    : (activeColor ?? (isHovering ? Theme.primaryColor : Theme.secondaryColor))
            )
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isHovering && !disabled && !showsProgress
                            ? Theme.primaryColor.opacity(0.1)
                            : Color.clear
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(disabled || showsProgress)
        .opacity((disabled || showsProgress) ? 0.45 : (rowHovering || isHovering ? 1 : 0.55))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .macTooltip(help, position: .top)
        .accessibilityLabel(help)
    }
}

/** 右侧栏各面板共用的可折叠分组标题。 */
struct SidebarSectionHeader: View {
    /// 分组标题上的行内操作项定义
    struct Action: Identifiable {
        let id = UUID()
        let systemImage: String
        let help: String
        var disabled: Bool = false
        var showsProgress: Bool = false
        var activeColor: Color? = nil
        let perform: () -> Void
    }

    let title: String
    let count: Int
    @Binding var isCollapsed: Bool
    let actions: [Action]
    var actionsDisabled = false
    var trailingView: AnyView? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(SidebarTypography.chevron())
                        .foregroundStyle(Theme.secondaryColor)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(title)
                        .font(SidebarTypography.section(.semibold))
                        // 分组标题使用次级文字色，提升浅色模式下的可读性。
                        .foregroundStyle(Theme.secondaryColor)
                    // 数量紧跟标题，不再右对齐到行尾。
                    if count > 0 {
                        Text("\(count)")
                            .font(SidebarTypography.micro().monospacedDigit())
                            .foregroundStyle(Theme.secondaryColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.primaryColor.opacity(0.08)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                if let trailingView {
                    trailingView
                }
                ForEach(actions) { action in
                    SidebarSectionHeaderActionButton(
                        systemImage: action.systemImage,
                        help: action.help,
                        disabled: action.disabled || actionsDisabled,
                        showsProgress: action.showsProgress,
                        activeColor: action.activeColor,
                        rowHovering: isHovering,
                        action: action.perform
                    )
                }
            }
        }
        // Fixed height so the taller hover buttons don't grow the header.
        .frame(height: SidebarTypography.rowMinHeight)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(actions) { action in
                Button(action.help, action: action.perform)
                    .disabled(actionsDisabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}
