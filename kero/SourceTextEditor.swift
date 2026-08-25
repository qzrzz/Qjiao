//
//  SourceTextEditor.swift
//  kero
//

import AppKit
import STPluginNeon
import STTextView
import SwiftUI

/// Scroll offset and cursor position of a file tab's editor, kept on the
/// `FileTab` so it survives tab switches, and in the session snapshot so it
/// survives relaunches. Every field is optional so decoding tolerates
/// snapshots written by earlier editor stacks.
struct EditorState: Codable, Equatable {
    var selectionLocation: Int?
    var selectionLength: Int?
    var scrollX: Double?
    var scrollY: Double?
}

/// Editor colors resolved from the selected Ghostty theme. Selection color is
/// not included: STTextView always uses the system selection color.
struct EditorPalette: Equatable {
    var text: NSColor
    var background: NSColor
    var insertionPoint: NSColor
    var lineHighlight: NSColor
    var gutterText: NSColor

    static func theme(themeName: String, dark: Bool) -> EditorPalette {
        let resolved = Theme.editorTerminal(themeName, dark: dark)
        let colors = resolved.colors
        let opacity = AppSettings.shared.terminalBackgroundOpacity
        let bg = colors.background.withAlphaComponent(opacity)
        return EditorPalette(
            text: colors.foreground,
            background: bg,
            insertionPoint: colors.cursor,
            lineHighlight: bg.blended(
                withFraction: resolved.isDark ? 0.10 : 0.08,
                of: colors.foreground
            ) ?? bg,
            gutterText: colors.foreground.blended(
                withFraction: resolved.isDark ? 0.45 : 0.55,
                of: bg
            ) ?? colors.foreground
        )
    }

    /// Kept as a compatibility spelling for callers outside the current app.
    static func github(dark: Bool) -> EditorPalette {
        theme(themeName: "", dark: dark)
    }
}

/// STTextView wrapped for SwiftUI: plain-text editing with line numbers and
/// the system search-and-replace find bar (⌘F / ⌥⌘F via the Edit ▸ Find menu,
/// routed here by `FileTab.performFindAction`). Text edits are written
/// straight back to `FileTab.text`; scroll/cursor state is written back to
/// `FileTab.editorState` as it changes and restored when the view is
/// recreated on tab switch or relaunch.
struct SourceTextEditor: NSViewRepresentable {
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var settings = AppSettings.shared
    let file: FileTab
    let font: NSFont
    let palette: EditorPalette
    let syntaxTheme: SyntaxHighlighting.ThemeConfiguration
    let wrapLines: Bool
    var isFocused: Bool = true
    var onFocused: () -> Void = {}
    var onSplit: (PaneDropEdge) -> Void = { _ in }
    var onNewBrowserTab: (String?) -> Void = { _ in }
    var onNewBrowserPane: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(file: file)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = RestorableScrollView()
        let textView = FocusReportingTextView()
        textView.onBecomeFirstResponder = onFocused
        textView.splitTarget.onSplit = onSplit
        textView.splitTarget.onNewBrowserTab = onNewBrowserTab
        textView.splitTarget.onNewBrowserPane = onNewBrowserPane
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView

        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = (settings.terminalBackgroundOpacity == 1)
        // The window uses a full-size content view, so automatic insets
        // would add a titlebar-height top inset that misaligns the gutter
        // numbers against the text by one line.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        // The gutter is a document-height floating subview that scrolls
        // vertically with the text; since macOS 14 NSViews no longer clip
        // subviews by default, so without this the scrolled-away line
        // numbers draw outside the scroll view, over the header above it.
        scrollView.clipsToBounds = true

        // Configure typography before setting the text: the font/color
        // setters restyle the whole document, and restyling after layout
        // used to leave stale layout fragments that broke gutter numbering.
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        // Highlight every match as the query is typed in the find bar, the way
        // the terminal's find bar searches as you type. Off by default in
        // STTextView.
        textView.isIncrementalSearchingEnabled = true
        apply(to: textView, scrollView: scrollView)
        textView.text = file.text

        // Tree-sitter syntax highlighting (STPluginNeon), for file types with
        // a bundled grammar. Added after the text is set so the plugin's
        // initial full-document parse — which runs when the view lands in a
        // window — sees the whole document. The plugin only layers foreground
        // colors as rendering attributes; the font stays kero's (see
        // SyntaxHighlighting.theme).
        if let plugin = SyntaxHighlighting.plugin(
            for: file.path,
            theme: syntaxTheme.theme,
            onCoordinatorReady: { context.coordinator.attachSyntaxHighlighter($0) }
        ) {
            textView.addPlugin(plugin)
        }

        // Captured before the coordinator attaches, because its scroll
        // observer starts overwriting `editorState` immediately.
        let state = file.editorState
        if let location = state.selectionLocation {
            let limit = (textView.text ?? "").utf16.count
            let start = min(max(0, location), limit)
            let length = min(max(0, state.selectionLength ?? 0), limit - start)
            let targetRange = NSRange(location: start, length: length)
            textView.textSelection = targetRange
            DispatchQueue.main.async {
                textView.centerSelectionInVisibleArea(nil)
            }
        }

        context.coordinator.attach(textView: textView, scrollView: scrollView)

        // Restore the saved scroll offset during the first layout pass — while
        // the frame is finally known but before the first paint — so the file
        // opens already at its saved position. Doing this asynchronously (after
        // the initial paint at the top) makes the editor visibly scroll into
        // place and flashes the auto-hiding scroller.
        if state.scrollX != nil || state.scrollY != nil {
            scrollView.restoreOnFirstLayout = { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                let clipView = scrollView.contentView
                // setBoundsOrigin (not scroll(to:)) avoids clamping against a
                // content height that TextKit2 has only estimated so far.
                clipView.setBoundsOrigin(NSPoint(x: state.scrollX ?? 0, y: state.scrollY ?? 0))
                scrollView.reflectScrolledClipView(clipView)
                // Lay out the viewport around the restored offset in this same
                // pass so the region is painted in place, not after a scroll.
                textView.needsLayout = true
            }
        }

        // First real size is when the viewport exists. Plugin setup happens
        // earlier (`viewDidMoveToWindow`), often with `visibleRange == .zero`.
        let coordinator = context.coordinator
        scrollView.onFirstVisibleLayout = { [weak coordinator] in
            coordinator?.noteEditorBecameVisible()
        }

        // Only grab focus on mount when this pane is the focused one, so an
        // unfocused split doesn't steal the caret.
        if isFocused {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        context.coordinator.wasFocused = isFocused
        // Expose the view so a pane-move drag can snapshot it as a thumbnail.
        file.editorView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        (textView as? FocusReportingTextView)?.onBecomeFirstResponder = onFocused
        (textView as? FocusReportingTextView)?.splitTarget.onSplit = onSplit
        (textView as? FocusReportingTextView)?.splitTarget.onNewBrowserTab =
            onNewBrowserTab
        (textView as? FocusReportingTextView)?.splitTarget.onNewBrowserPane =
            onNewBrowserPane
        apply(to: textView, scrollView: scrollView)
        context.coordinator.updateSyntaxTheme(syntaxTheme)
        // Take focus on the unfocused→focused edge (keyboard navigation moving
        // focus here), never on every render.
        if isFocused, !context.coordinator.wasFocused {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        context.coordinator.wasFocused = isFocused
    }

    /// Take exactly the space SwiftUI offers. Without this, SwiftUI sizes the
    /// editor from the scroll view's `fittingSize`, which STTextView derives
    /// from the entire document — enormous for a large file, and degenerate
    /// for an empty one. Because the main window tracks its content's ideal
    /// size, that runaway measurement drives the window size and drops it into
    /// an unbounded layout loop (a hard crash: "more Layout Window passes than
    /// there are views"). Reporting the proposed size keeps the editor a
    /// space-filling pane that never influences the window's size.
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

    /// Guarded assignments: the font/color setters restyle the whole
    /// document, and this runs on every SwiftUI render.
    private func apply(to textView: STTextView, scrollView: NSScrollView) {
        let opacity = settings.terminalBackgroundOpacity
        let targetBg = palette.background

        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != palette.text {
            textView.textColor = palette.text
        }
        if textView.backgroundColor != targetBg {
            textView.backgroundColor = targetBg
            scrollView.backgroundColor = targetBg
        }
        scrollView.drawsBackground = (opacity == 1)
        textView.insertionPointColor = palette.insertionPoint
        textView.selectedLineHighlightColor = palette.lineHighlight
        // false = wrap at the view width, true = expand horizontally.
        textView.isHorizontallyResizable = !wrapLines
        if let gutter = textView.gutterView {
            gutter.textColor = palette.gutterText
            gutter.selectedLineTextColor = palette.text
        }
    }

    @MainActor
    final class Coordinator: NSObject, STTextViewDelegate {
        private let file: FileTab
        private weak var textView: STTextView?
        private weak var scrollView: NSScrollView?
        private weak var syntaxHighlighter: SyntaxHighlightCoordinator?
        private var syntaxThemeKey: String?
        private var scrollObserver: (any NSObjectProtocol)?
        private var lineStarts: [Int] = [0]
        private var lineStartsRevision: UInt64 = .max
        private var lastEmittedMarkdownLine: Double = -1
        /// Last-applied focus state, so `updateNSView` can act only on the
        /// unfocused→focused edge.
        var wasFocused = false

        init(file: FileTab) {
            self.file = file
        }

        func attach(textView: STTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            textView.textDelegate = self
            file.onReloadEditorText = { [weak self] in
                self?.reloadTextFromFile()
            }
            file.onJumpToSelection = { [weak self] range in
                self?.jumpToSelection(range)
            }
            file.onMarkdownScrollToEditor = { [weak self] line in
                self?.scrollToMarkdownLine(line)
            }
            file.emitMarkdownEditorVisibleLine = { [weak self] in
                self?.emitVisibleMarkdownLine(force: true)
            }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let clipView = scrollView?.contentView else { return }
                    self.file.editorState.scrollX = clipView.bounds.origin.x
                    self.file.editorState.scrollY = clipView.bounds.origin.y
                    self.emitVisibleMarkdownLine(force: false)
                }
            }
        }

        func attachSyntaxHighlighter(_ coordinator: SyntaxHighlightCoordinator) {
            syntaxHighlighter = coordinator
        }

        func noteEditorBecameVisible() {
            syntaxHighlighter?.refreshVisibleHighlighting()
        }

        func updateSyntaxTheme(_ configuration: SyntaxHighlighting.ThemeConfiguration) {
            guard syntaxThemeKey != configuration.key else { return }
            syntaxThemeKey = configuration.key
            syntaxHighlighter?.update(theme: configuration.theme)
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard let textView else { return }
            let newText = textView.text ?? ""
            guard newText != file.text else { return }
            file.text = newText
            file.refreshDirtyState()
            file.noteTextChanged()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let selection = textView.textSelection
            file.editorState.selectionLocation = selection.location
            file.editorState.selectionLength = selection.length
            file.updateSelectionSummary(selection)
        }

        /// 格式化工具改写磁盘文件后，将模型中新读入的文本立即同步到已挂载的视图，
        /// 并尽可能恢复原光标或选区。格式化会改变文本长度，因此范围需安全截断。
        private func reloadTextFromFile() {
            guard let textView, textView.text != file.text else { return }
            textView.text = file.text
            let textLength = (file.text as NSString).length
            let location = min(max(0, file.editorState.selectionLocation ?? 0), textLength)
            let length = min(max(0, file.editorState.selectionLength ?? 0), textLength - location)
            let selection = NSRange(location: location, length: length)
            textView.textSelection = selection
            file.updateSelectionSummary(selection)
            textView.needsLayout = true
        }

        /// 跳转并选中指定 range 范围，同时尽可能将其滚动至屏幕/视口垂直中心
        private func jumpToSelection(_ range: NSRange) {
            guard let textView else { return }
            let textLength = (file.text as NSString).length
            let location = min(max(0, range.location), textLength)
            let length = min(max(0, range.length), textLength - location)
            let targetRange = NSRange(location: location, length: length)

            textView.textSelection = targetRange
            file.editorState.selectionLocation = targetRange.location
            file.editorState.selectionLength = targetRange.length
            file.updateSelectionSummary(targetRange)

            textView.scrollRangeToVisible(targetRange)
            textView.centerSelectionInVisibleArea(nil)
            textView.needsLayout = true

            // 异步在下一帧 layout 沉淀后二次确认居中
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(targetRange)
                textView.centerSelectionInVisibleArea(nil)
            }
        }

        private func currentLineStarts() -> [Int] {
            if lineStartsRevision != file.textRevision {
                lineStarts = MarkdownSourceLine.starts(in: file.text)
                lineStartsRevision = file.textRevision
            }
            return lineStarts
        }

        private func emitVisibleMarkdownLine(force: Bool) {
            guard file.isMarkdownFile, let textView else { return }
            if !force, file.isMarkdownScrollEchoSuppressed { return }
            let line = visibleMarkdownLine(in: textView)
            if !force, abs(line - lastEmittedMarkdownLine) < 0.08 { return }
            lastEmittedMarkdownLine = line
            file.onMarkdownScrollToPreview?(line)
        }

        /// 视口顶部对应的源码行（1-based，含行内小数），供预览按块插值而不是跟像素。
        private func visibleMarkdownLine(in textView: STTextView) -> Double {
            let starts = currentLineStarts()
            if let scrollView,
               let document = scrollView.documentView
            {
                let clip = scrollView.contentView.bounds
                let maxY = document.frame.height
                if maxY > clip.height, clip.maxY >= maxY - 2 {
                    return Double(starts.count)
                }
            }
            let y = textView.visibleRect.minY
            let layout = textView.textLayoutManager
            let point = CGPoint(x: max(textView.visibleRect.midX, 1), y: y + 0.5)
            guard let fragment = layout.textLayoutFragment(for: point) else {
                return 1
            }
            var location = fragment.rangeInElement.location
            var lineY = fragment.layoutFragmentFrame.minY
            var lineHeight = max(fragment.layoutFragmentFrame.height, 1)
            for lineFragment in fragment.textLineFragments {
                let top = fragment.layoutFragmentFrame.minY + lineFragment.typographicBounds.minY
                let height = max(lineFragment.typographicBounds.height, 1)
                if y + 0.5 < top { break }
                lineY = top
                lineHeight = height
                if let mapped = layout.location(
                    fragment.rangeInElement.location,
                    offsetBy: lineFragment.characterRange.location
                ) {
                    location = mapped
                }
                if y + 0.5 < top + height { break }
            }
            let offset = layout.offset(from: layout.documentRange.location, to: location)
            let line = MarkdownSourceLine.line(forUTF16Offset: offset, starts: starts)
            let fraction = min(max((y - lineY) / lineHeight, 0), 0.99)
            return Double(line) + Double(fraction)
        }

        private func scrollToMarkdownLine(_ line: Double) {
            guard let textView, let scrollView else { return }
            file.beginMarkdownScrollEchoSuppression()
            let starts = currentLineStarts()
            let whole = max(1, Int(line.rounded(.down)))
            let fraction = min(max(line - Double(whole), 0), 0.99)
            let length = (file.text as NSString).length
            let offset = min(MarkdownSourceLine.utf16Offset(ofLine: whole, starts: starts), length)
            textView.scrollRangeToVisible(NSRange(location: offset, length: 0))

            let layout = textView.textLayoutManager
            guard let location = layout.location(
                layout.documentRange.location,
                offsetBy: offset
            ) else { return }
            let range = NSTextRange(location: location)
            layout.ensureLayout(for: range)
            var targetY: CGFloat?
            layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                targetY = frame.minY + frame.height * CGFloat(fraction)
                return false
            }
            guard let targetY else { return }
            let clip = scrollView.contentView
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            var origin = clip.bounds.origin
            origin.y = min(max(targetY, 0), maxY)
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

/// STTextView that reports when it takes first-responder status (a click, or a
/// programmatic focus), so the owning pane can mark itself focused in the model,
/// and appends pane-split items to its context menu.
final class FocusReportingTextView: STTextView {
    var onBecomeFirstResponder: (() -> Void)?
    /// Owns the split context-menu items, kept off the text view so its own
    /// menu validation doesn't disable them.
    let splitTarget = SplitMenuTarget()

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }

    /// 源码编辑器复制只写纯文本：文档里的字体/颜色是编辑器自己的持久属性，
    /// 带 `.rtf` 复制出去会在富文本应用（Notes、Xcode、浏览器等）里粘贴出
    /// 异常的字体和颜色。`cut` 经由 `copy(_:)` 动态派发，同样生效。
    override func copy(_ sender: Any?) {
        _ = writeSelection(to: NSPasteboard.general, types: [.string])
    }

    /// 只接受纯文本：外部富文本的字体/颜色混入源码文档后，会污染该处
    /// 的 typing attributes（光标停在那里输入的文字带异常样式），并随
    /// 再次复制继续扩散。
    override func paste(_ sender: Any?) {
        _ = readSelection(from: NSPasteboard.general, type: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        for item in splitTarget.browserMenuItems() { menu.addItem(item) }
        menu.addItem(.separator())
        for item in splitTarget.menuItems() { menu.addItem(item) }
        L10n.localizeMenu(menu)
        return menu
    }
}

/// NSScrollView that runs a one-shot restoration during its first real layout
/// pass — before the first paint — so a restored file opens already scrolled to
/// its saved position instead of visibly jumping there afterward.
private final class RestorableScrollView: NSScrollView {
    var restoreOnFirstLayout: (() -> Void)?
    /// Fires once the scroll view has a non-empty frame, after any saved
    /// scroll offset has been applied.
    var onFirstVisibleLayout: (() -> Void)?
    private var lastViewportSize: NSSize = .zero
    private var geometryUpdateScheduled = false

    /// Temporary: set KERO_SCROLLER_DEBUG=1 to trace scroller geometry.
    private func logScroller(_ tag: String) {
        guard ProcessInfo.processInfo.environment["KERO_SCROLLER_DEBUG"] != nil else { return }
        guard let scroller = verticalScroller else { print("[scroller] \(tag) none"); return }
        let scrollerInWindow = scroller.convert(scroller.bounds, to: nil)
        let selfInWindow = convert(bounds, to: nil)
        print("""
        [scroller] \(tag) \
        sv.w=\(Int(bounds.width)) sv.inWindow.x=\(Int(selfInWindow.minX))..\(Int(selfInWindow.maxX)) \
        clip.w=\(Int(contentView.bounds.width)) doc.w=\(Int(documentView?.frame.width ?? -1)) \
        scroller.frame=\(Int(scroller.frame.minX)),w=\(Int(scroller.frame.width)) \
        scroller.inWindow.x=\(Int(scrollerInWindow.minX)) hidden=\(scroller.isHidden) \
        super=\(scroller.superview.map { String(describing: type(of: $0)) } ?? "nil")
        """)
    }

    override func layout() {
        super.layout()
        let viewportSize = contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            scheduleEditorGeometryUpdate()
        }
        logScroller("layout")
        if bounds.width > 0, bounds.height > 0 {
            if let restore = restoreOnFirstLayout {
                restoreOnFirstLayout = nil
                restore()
            }
            if let firstVisible = onFirstVisibleLayout {
                onFirstVisibleLayout = nil
                firstVisible()
            }
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleEditorGeometryUpdate()
    }

    /// STTextView's document view can inherit the viewport's width while the
    /// window is resizing. Re-run its content sizing after AppKit finishes the
    /// scroll-view layout, then clamp the old offset to the new scroll range
    /// and refresh the scroller thumb/proportion.
    private func scheduleEditorGeometryUpdate() {
        guard !geometryUpdateScheduled else { return }
        geometryUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryUpdateScheduled = false
            guard let textView = self.documentView as? STTextView else { return }

            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()

            // Re-place the scrollers against the new width. An overlay scroller
            // that was faded out when the viewport changed keeps the frame it
            // had, so it comes back at the editor's *old* trailing edge — most
            // visibly after ⇧⌘B closes the right panel, where it reappears
            // mid-document with text running past it.
            self.tile()

            let clipView = self.contentView
            let constrainedBounds = clipView.constrainBoundsRect(clipView.bounds)
            if constrainedBounds.origin != clipView.bounds.origin {
                clipView.setBoundsOrigin(constrainedBounds.origin)
            }
            self.reflectScrolledClipView(clipView)
        }
    }
}
