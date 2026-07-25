//
//  NotePanel.swift
//  kero
//

import AppKit
import SwiftUI

/// 右侧下半区 Note tab：按当前项目的纯文本草稿本，自动保存。
struct NotePanel: View {
    @ObservedObject var model: NoteModel
    /// 无选中项目时不可编辑，显示空状态。
    let hasProject: Bool

    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if hasProject {
                editor
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 面板不可见时先刷盘，避免仅依赖防抖而丢最后一次编辑。
        .onDisappear { model.flush() }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(
                text: model.text,
                font: .systemFont(ofSize: SidebarTypography.bodySize),
                textColor: Theme.terminal(dark: colorScheme == .dark).foreground,
                // 侧栏背景已由 RightSidebar 绘制；编辑器透明，避免叠色。
                backgroundColor: .clear,
                insertionPointColor: Theme.cursor,
                isEditable: true,
                onTextChange: { model.updateText($0) }
            )

            if model.text.isEmpty {
                Text("Write a note…")
                    .font(SidebarTypography.body())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project note")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(SidebarTypography.emptyInlineIcon())
                .foregroundStyle(.tertiary)
            Text("No project selected")
                .font(SidebarTypography.body(.medium))
                .foregroundStyle(.secondary)
            Text("Open a project to keep notes")
                .font(SidebarTypography.section())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No project selected for notes")
    }
}

// MARK: - Plain text editor (NSTextView)

/// 侧栏用的轻量纯文本编辑器：自动换行、系统字体、主题色光标，不做语法高亮。
/// 必须报告 `sizeThatFits` 为提议尺寸，避免 NSTextView 用文档高度撑破窗口布局。
///
/// 键盘：Note 获焦时吞掉工作区级 ⌘ 快捷键（新建会话、关面板、切 Tab 等），
/// 避免菜单项抢走按键；保留文本编辑键（由 NSTextView 处理）与少量系统级菜单。
struct PlainTextEditor: NSViewRepresentable {
    var text: String
    var font: NSFont
    var textColor: NSColor
    var backgroundColor: NSColor
    var insertionPointColor: NSColor
    var isEditable: Bool
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NoteScrollView()
        let textView = NoteTextView()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.scrollerInsets = NSEdgeInsets()
        scrollView.clipsToBounds = true

        // 文档视图填满 scroll view 宽度，并随文本增高。
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainerInset = NSSize(width: 8, height: 8)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear

        apply(to: textView)
        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onTextChange = onTextChange
        apply(to: textView)

        // 仅在外部文本与当前不同时写回，避免光标跳动。
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
    }

    /// 填满 SwiftUI 给出的空间，禁止用文档 ideal size 反推窗口尺寸。
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        func resolve(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return value
        }
        return CGSize(
            width: resolve(proposal.width, fallback: nsView.frame.width),
            height: resolve(proposal.height, fallback: nsView.frame.height)
        )
    }

    private func apply(to textView: NSTextView) {
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
        }
        if textView.insertionPointColor != insertionPointColor {
            textView.insertionPointColor = insertionPointColor
        }
        textView.backgroundColor = backgroundColor
        textView.isEditable = isEditable
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void
        weak var textView: NSTextView?

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }
    }
}

// MARK: - 快捷键隔离

/// Note 获焦时的 ⌘ 键策略：先交给文本编辑，再处理本地查找，最后吞掉工作区快捷键。
private enum NoteKeyEquivalentPolicy {
    /// 仍放行到主菜单的系统级命令（退出 / 设置 / 隐藏 / 最小化）。
    private static let passthroughCharacters: Set<Character> = ["q", ",", "h", "m"]

    /// 在 `super.performKeyEquivalent` 未处理时调用。
    /// - Returns: `true` 表示已消费（含主动吞掉）；`false` 继续交给菜单。
    static func handleUnclaimed(
        _ event: NSEvent,
        textView: NSTextView?
    ) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let ch = chars.count == 1 ? chars.first : nil

        // NSTextView.super 经常不认菜单级编辑快捷键；显式处理，避免被下方吞掉。
        if let ch, let textView,
           !flags.contains(.option), !flags.contains(.control),
           handleStandardEditing(ch, flags: flags, textView: textView) {
            return true
        }

        // 本地查找：不要落到 Kero 菜单的「按当前 pane 查找」（会打开终端/文件查找）。
        if let ch, ch == "f", !flags.contains(.shift), !flags.contains(.option),
           let textView {
            runFind(on: textView, action: .showFindPanel)
            return true
        }
        if let ch, ch == "g", !flags.contains(.option), let textView {
            runFind(
                on: textView,
                action: flags.contains(.shift) ? .previous : .next
            )
            return true
        }

        if let ch, passthroughCharacters.contains(ch),
           !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control) {
            return false
        }

        // 其余 ⌘ / ⌘⇧ / ⌘⌥ 组合一律吞掉，避免新建会话、关面板、切项目等。
        return true
    }

    /// 处理全选 / 剪贴板 / 撤销等标准编辑键。
    private static func handleStandardEditing(
        _ ch: Character,
        flags: NSEvent.ModifierFlags,
        textView: NSTextView
    ) -> Bool {
        let shift = flags.contains(.shift)
        switch ch {
        case "a" where !shift:
            textView.selectAll(nil)
            return true
        case "c" where !shift:
            textView.copy(nil)
            return true
        case "v" where !shift:
            textView.paste(nil)
            return true
        case "x" where !shift:
            textView.cut(nil)
            return true
        case "z":
            if shift {
                textView.undoManager?.redo()
            } else {
                textView.undoManager?.undo()
            }
            return true
        default:
            return false
        }
    }

    private static func runFind(on textView: NSTextView, action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        textView.performFindPanelAction(item)
    }
}

/// 查找栏获焦时 firstResponder 是栏内字段；在 scroll view 上拦截，避免快捷键漏到菜单。
private final class NoteScrollView: NSScrollView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard ownsKeyboardFocus else { return false }
        let textView = documentView as? NSTextView
        return NoteKeyEquivalentPolicy.handleUnclaimed(event, textView: textView)
    }

    /// 键盘焦点是否在本笔记编辑器（正文或查找栏）内。
    private var ownsKeyboardFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === documentView || responder.isDescendant(of: self)
    }
}

/// Note 正文：不参与 ideal-size 测量；获焦时隔离工作区快捷键。
private final class NoteTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        // 不参与 SwiftUI ideal-size 测量；由 sizeThatFits 固定为提议尺寸。
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 先让 NSTextView 处理拷贝/粘贴/全选/撤销等标准编辑键。
        if super.performKeyEquivalent(with: event) { return true }
        return NoteKeyEquivalentPolicy.handleUnclaimed(event, textView: self)
    }
}
