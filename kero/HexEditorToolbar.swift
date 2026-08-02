//
//  HexEditorToolbar.swift
//  kero
//

import AppKit
import SwiftUI

/// 十六进制编辑器工具条：默认单行显示查找（文本 / 十六进制，可匹配大小写）；
/// 点击行尾展开按钮展开第二行替换功能（替换当前 / 全部）。
/// 输入即搜索（后台计算），匹配在编辑器中高亮，当前匹配以光标色突出。
///
/// 组件遵循 macOS 规范：输入框为矩形圆角 SwiftUI `TextField`（聚焦高亮描边、
/// 内置左侧图标），模式切换为分段控件，背景为系统材质并带 hairline 分隔线。
///
/// 键盘：⌘F 聚焦查找框，⌘G / ⇧⌘G 下一个 / 上一个匹配（菜单路由），⌘E 用选中字节搜索；
/// 查找框 ↩ 下一个匹配，替换框 ↩ 替换当前匹配。
struct HexEditorToolbar: View {
    @ObservedObject var file: FileTab
    /// 聚焦请求计数：递增一次即让对应输入框成为第一响应者（并全选文本）。
    @State private var findFocusRequest = 0
    @State private var replaceFocusRequest = 0
    /// 替换行是否展开。
    @State private var isReplaceExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                findSection
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)

            if isReplaceExpanded {
                HStack(spacing: 0) {
                    replaceSection
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background {
            // 与编辑器 / 分屏 pane 背景一致的主题色（非材质），仅以 hairline 分隔
            Color(
                nsColor: Theme.background
                    .withAlphaComponent(AppSettings.shared.terminalBackgroundOpacity)
            )
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .animation(.snappy(duration: 0.18), value: isReplaceExpanded)
        .task(id: searchTaskID) {
            await file.performHexSearchAsync()
        }
        .onAppear {
            file.onHexFindAction = handleFindAction
        }
        .onDisappear {
            file.onHexFindAction = nil
        }
    }

    private var searchTaskID: String {
        "\(file.hexFindQuery)|\(file.hexFindMode.rawValue)|\(file.hexFindIgnoreCase)"
    }

    // MARK: - 查找段（第一行）

    private var findSection: some View {
        HStack(spacing: 5) {
            HexToolbarTextField(
                text: $file.hexFindQuery,
                placeholder: L10n.t("Search"),
                onSubmit: { file.hexShowNextMatch(delta: 1) },
                focusRequest: findFocusRequest
            )
            .frame(width: 180)

            modePicker(selection: $file.hexFindMode)

            ToolbarLabelButton(
                title: "Aa",
                isActive: file.hexFindIgnoreCase,
                isEnabled: file.hexFindMode == .text,
                help: L10n.t("Match Case"),
                position: .top
            ) {
                file.hexFindIgnoreCase.toggle()
            }

            ToolbarIconButton(
                systemImage: "chevron.up",
                isEnabled: !file.hexMatches.isEmpty,
                help: L10n.t("Find Previous"),
                shortcut: "⇧↩",
                position: .top
            ) {
                file.hexShowNextMatch(delta: -1)
            }

            ToolbarIconButton(
                systemImage: "chevron.down",
                isEnabled: !file.hexMatches.isEmpty,
                help: L10n.t("Find Next"),
                shortcut: "⌘G",
                position: .top
            ) {
                file.hexShowNextMatch(delta: 1)
            }

            matchCountLabel

            // 展开 / 收起替换行（紧贴查找控件，符合 macOS Find Bar 惯例）
            ToolbarIconButton(
                systemImage: isReplaceExpanded ? "chevron.up" : "chevron.down",
                help: isReplaceExpanded
                    ? L10n.t("Hide Replace")
                    : L10n.t("Show Replace"),
                position: .top
            ) {
                withAnimation(.snappy(duration: 0.18)) {
                    isReplaceExpanded.toggle()
                }
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private var matchCountLabel: some View {
        if let error = file.hexSearchError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .macTooltip(error, position: .top)
        } else if !file.hexFindQuery.isEmpty {
            Text(
                file.hexMatches.isEmpty
                    ? "0/0"
                    : "\(file.hexCurrentMatchIndex + 1)/\(file.hexMatches.count)"
            )
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(
                file.hexMatches.isEmpty
                    ? AnyShapeStyle(.red)
                    : AnyShapeStyle(.secondary)
            )
            .frame(width: 34, alignment: .leading)
            .macTooltip(file.hexMatches.isEmpty ? L10n.t("No matches") : nil, position: .top)
        }
    }

    // MARK: - 替换段（第二行，展开后显示）

    private var replaceSection: some View {
        HStack(spacing: 5) {
            HexToolbarTextField(
                text: $file.hexReplaceQuery,
                placeholder: L10n.t("Replace with…"),
                searchIcon: "arrow.2.squarepath",
                onSubmit: { file.hexReplaceCurrentMatch() },
                focusRequest: replaceFocusRequest
            )
            .frame(width: 150)

            modePicker(selection: $file.hexReplaceMode)

            ToolbarLabelButton(
                title: L10n.t("Replace"),
                isEnabled: !file.hexMatches.isEmpty,
                help: L10n.t("Replace Current Match"),
                shortcut: "↩",
                position: .top
            ) {
                file.hexReplaceCurrentMatch()
            }

            ToolbarLabelButton(
                title: L10n.t("Replace All"),
                isEnabled: !file.hexMatches.isEmpty,
                help: L10n.t("Replace All Matches"),
                position: .top
            ) {
                file.hexReplaceAllMatches()
            }
        }
    }

    // MARK: - 共用组件

    /// TEXT / HEX 模式分段控件。
    private func modePicker(selection: Binding<HexSearchMode>) -> some View {
        Picker("", selection: selection) {
            Text("TEXT").tag(HexSearchMode.text)
            Text("HEX").tag(HexSearchMode.hex)
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
        .frame(width: 78)
        .macTooltip(
            selection.wrappedValue == .hex
                ? L10n.t("Hex Search")
                : L10n.t("Text Search"),
            position: .top
        )
    }

    // MARK: - Find 菜单路由

    private func handleFindAction(_ action: FindAction) {
        switch action {
        case .show:
            findFocusRequest += 1
        case .replace:
            // 替换行未展开时先展开，再聚焦输入框
            if !isReplaceExpanded {
                withAnimation(.snappy(duration: 0.18)) {
                    isReplaceExpanded = true
                }
            }
            replaceFocusRequest += 1
        case .hide:
            break
        case .next:
            file.hexShowNextMatch(delta: 1)
        case .previous:
            file.hexShowNextMatch(delta: -1)
        case .useSelection:
            file.useHexSelectionForFind()
        }
    }
}

// MARK: - 矩形圆角输入框

/// SwiftUI 普通输入框（非 AppKit 控件）：矩形圆角描边、左侧图标、等宽字体；
/// 回车提交（`onSubmit`），聚焦通过递增 `focusRequest` 请求（并全选文本）。
/// 使用 SwiftUI `TextField` 而非原生 `NSSearchField` / `NSTextField`，避免
/// macOS 26+ 对 AppKit 文本控件注入表单自动填充（ViewBridge 远程视图
/// SPCompletionListService）导致后续 borderless NSPanel 显示时崩溃。
private struct HexToolbarTextField: View {
    @Binding var text: String
    var placeholder: String
    /// 左侧图标（SF Symbol）；nil 表示无图标。
    var searchIcon: String? = "magnifyingglass"
    var onSubmit: () -> Void
    var focusRequest: Int

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let searchIcon {
                Image(systemName: searchIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .focused($isFocused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? Color.accentColor
                        : Color.primary.opacity(0.14),
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        // ⌘F / 替换聚焦请求：聚焦并全选已有文本，便于直接覆盖输入。
        .onChange(of: focusRequest) { _, _ in
            isFocused = true
            DispatchQueue.main.async {
                selectAllText()
            }
        }
    }

    /// 聚焦后全选：field editor 是当前 firstResponder 的 NSTextView，
    /// 通过其 delegate（NSTextField）执行全选。
    private func selectAllText() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField,
              field.isEditable else { return }
        field.selectText(nil)
    }
}

// MARK: - 工具条按钮

/// 无边框图标按钮：hover 显示圆形背景，禁用时置灰。
private struct ToolbarIconButton: View {
    let systemImage: String
    var isEnabled = true
    let help: String
    var shortcut: String? = nil
    var position: MacTooltipPosition = .top
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? Color(nsColor: .secondaryLabelColor)
                        : Color(nsColor: .tertiaryLabelColor)
                )
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(
                        isHovering ? Color.primary.opacity(0.08) : Color.clear
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 && isEnabled }
        .macTooltip(help, shortcut: shortcut, position: position)
    }
}

/// 无边框文字按钮（accent 色）：hover 显示圆角背景，激活态（如 Aa 区分大小写）高亮。
private struct ToolbarLabelButton: View {
    let title: String
    var isActive = false
    var isEnabled = true
    let help: String
    var shortcut: String? = nil
    var position: MacTooltipPosition = .top
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    isActive
                        ? Color.accentColor
                        : (isEnabled
                            ? Color(nsColor: .secondaryLabelColor)
                            : Color(nsColor: .tertiaryLabelColor))
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 && isEnabled }
        .macTooltip(help, shortcut: shortcut, position: position)
    }
}
