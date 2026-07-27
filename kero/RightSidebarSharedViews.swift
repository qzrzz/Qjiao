//
//  RightSidebarSharedViews.swift
//  kero
//

import SwiftUI

// MARK: - Shared panel chrome

struct PanelHeader: View {
    let title: String
    let subtitle: String?
    var titleFont: Font = SidebarTypography.title()
    var subtitleTruncationMode: Text.TruncationMode = .head

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(titleFont)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SidebarTypography.caption())
                    // PID 作为辅助信息显示，但在浅色模式下保持足够对比度。
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(subtitleTruncationMode)
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
    var active: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(
                    active
                        ? Color(nsColor: Theme.cursor)
                        : (disabled ? .secondary.opacity(0.4) : (isHovering ? .primary : .secondary))
                )
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            active
                                ? Color(nsColor: Theme.cursor).opacity(0.12)
                                : (isHovering && !disabled ? Color.primary.opacity(0.08) : Color.clear)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: active)
        .help(help)
        .accessibilityLabel(help)
    }
}

/** 侧边栏/面板统一菜单图标按钮：带下拉菜单的标准图标按钮，支持 hover 态与 active 态。 */
struct SidebarMenuIconButton<Content: View>: View {
    let systemImage: String
    let help: String
    var active: Bool = false
    var disabled: Bool = false
    @ViewBuilder let menuContent: () -> Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            Image(systemName: systemImage)
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(
                    active
                        ? Color(nsColor: Theme.cursor)
                        : (disabled ? .secondary.opacity(0.4) : (isHovering ? .primary : .secondary))
                )
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            active
                                ? Color(nsColor: Theme.cursor).opacity(0.12)
                                : (isHovering && !disabled ? Color.primary.opacity(0.08) : Color.clear)
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
        .help(help)
        .accessibilityLabel(help)
    }
}

/** Project / Info 共用的刷新按钮：hover 高亮，刷新期间旋转并禁止重复点击。 */
struct SidebarRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(SidebarTypography.caption(.medium))
                .foregroundStyle(
                    isRefreshing
                        ? Color(nsColor: Theme.cursor)
                        : (isHovering ? Color.primary : Color.secondary)
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
                                ? Color.primary.opacity(0.08)
                                : Color.clear
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .onHover { isHovering = $0 }
        .help(isRefreshing ? "Refreshing…" : "Refresh")
        .accessibilityLabel(isRefreshing ? "Refreshing" : "Refresh")
    }
}

/** 右侧栏各面板共用的可折叠分组标题。 */
struct SidebarSectionHeader: View {
    struct Action: Identifiable {
        let id = UUID()
        let systemImage: String
        let help: String
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
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(title)
                        .font(SidebarTypography.section(.semibold))
                        // 分组标题使用次级文字色，提升浅色模式下的可读性。
                        .foregroundStyle(.secondary)
                    // 数量紧跟标题，不再右对齐到行尾。
                    if count > 0 {
                        Text("\(count)")
                            .font(SidebarTypography.micro())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
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
                    Button(action: action.perform) {
                        Image(systemName: action.systemImage)
                            .font(SidebarTypography.micro())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(actionsDisabled)
                    .opacity(actionsDisabled ? 0.3 : (isHovering ? 1 : 0.55))
                    .help(action.help)
                    .accessibilityLabel(action.help)
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
