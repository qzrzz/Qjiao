//
//  HexEditor.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

// MARK: - 排版常量

/// 十六进制编辑器的固定排版：等宽字体下所有列宽都由字符数推导，
/// 点击命中与绘制共用同一套坐标，保证所见即所得。
enum HexLayout {
    /// 每行字节数
    static let bytesPerRow = 16
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let charWidth: CGFloat = ("0" as NSString)
        .size(withAttributes: [.font: font]).width
    static let lineHeight: CGFloat = ceil(("0" as NSString)
        .size(withAttributes: [.font: font]).height)
    /// 行高 = 行文本高 + 上下留白
    static let rowHeight: CGFloat = lineHeight + 6
    /// 列标题栏高度
    static let headerHeight: CGFloat = rowHeight + 2
    static let padding: CGFloat = 10

    static let gutterX: CGFloat = padding
    /// 偏移列（8 位十六进制地址）
    static let gutterWidth: CGFloat = 8 * charWidth
    static let hexX: CGFloat = gutterX + gutterWidth + 3 * charWidth
    /// 十六进制列：16 字节 × 3 字符（2 位数字 + 1 空格），第 8 字节后有 2 字符分组间隙
    static let hexColumnWidth: CGFloat = (CGFloat(bytesPerRow) * 3 + 2) * charWidth
    static let asciiX: CGFloat = hexX + hexColumnWidth + 3 * charWidth
    static let asciiColumnWidth: CGFloat = CGFloat(bytesPerRow) * charWidth
    static let totalWidth: CGFloat = asciiX + asciiColumnWidth + padding

    /// 第 `byteIndex` 个字节的十六进制单元格 x 起点（跳过分组间隙）
    static func byteX(_ byteIndex: Int) -> CGFloat {
        let chars = byteIndex < bytesPerRow / 2 ? byteIndex * 3 : byteIndex * 3 + 2
        return hexX + CGFloat(chars) * charWidth
    }

    /// x 坐标 → 十六进制列内的字节下标；间隙与列尾空白归入相邻字节。
    static func byteIndex(atX x: CGFloat) -> Int? {
        guard x >= hexX, x < hexX + hexColumnWidth else { return nil }
        var raw = Int((x - hexX) / charWidth)
        raw = min(raw, bytesPerRow * 3 - 1)
        if raw >= bytesPerRow / 2 * 3 { raw -= 2 }
        guard raw >= 0 else { return nil }
        return raw / 3
    }
}

// MARK: - 搜索 / 替换 / 跳转模型

/// 搜索输入的解析模式：按 UTF-8 文本字节匹配，或按十六进制字节匹配。
enum HexSearchMode: String, CaseIterable, Identifiable {
    case text = "TEXT"
    case hex = "HEX"

    var id: String { rawValue }
}

/// 十六进制搜索模式：每个模式字节由高 / 低 nibble 组成，nil 表示该 nibble 通配
/// （`??` 整字节通配，`4?` / `?F` nibble 通配）。文本模式无通配。
struct HexSearchPattern: Equatable {
    struct Byte: Equatable {
        var high: UInt8?
        var low: UInt8?

        /// 无通配时的确定字节；含通配返回 nil。
        var value: UInt8? {
            guard let high, let low else { return nil }
            return (high << 4) | low
        }
    }

    let bytes: [Byte]

    /// 解析失败（空输入 / 非法 hex 字符 / 奇数位）时返回 nil。
    static func parse(query: String, mode: HexSearchMode) -> HexSearchPattern? {
        switch mode {
        case .text:
            let bytes = query.utf8.map { Byte(high: $0 >> 4, low: $0 & 0xF) }
            return bytes.isEmpty ? nil : HexSearchPattern(bytes: bytes)
        case .hex:
            var cleaned = query
                .replacingOccurrences(of: "0x", with: " ")
                .replacingOccurrences(of: "0X", with: " ")
            cleaned.removeAll { $0.isWhitespace || $0 == "," || $0 == "_" }
            guard !cleaned.isEmpty else { return nil }

            var pattern: [Byte] = []
            var index = cleaned.startIndex
            while index < cleaned.endIndex {
                let distance = cleaned.distance(from: index, to: cleaned.endIndex)
                let next = cleaned.index(index, offsetBy: min(2, distance))
                let pair = String(cleaned[index..<next])

                if pair.count == 1 {
                    // 奇数长度的最后一个字符：单独 `?` 视为整字节通配，否则非法
                    guard pair == "?" else { return nil }
                    pattern.append(Byte(high: nil, low: nil))
                } else {
                    let chars = Array(pair)
                    let high = nibble(chars[0])
                    let low = nibble(chars[1])
                    guard high != nil || chars[0] == "?",
                          low != nil || chars[1] == "?"
                    else { return nil }
                    pattern.append(Byte(high: high, low: low))
                }
                index = next
            }
            return pattern.isEmpty ? nil : HexSearchPattern(bytes: pattern)
        }
    }

    /// `?` 返回 nil（通配），合法 hex 数字返回其值，非法字符返回哨兵。
    private static func nibble(_ character: Character) -> UInt8? {
        guard character != "?", let value = character.hexDigitValue, value < 16 else {
            return nil
        }
        return UInt8(value)
    }

    /// 在数据中查找全部匹配区间（按位置升序、不重叠）。
    /// `ignoreCase` 仅对文本模式的 ASCII 字母生效（hex 模式天然大小写无关）。
    static func find(pattern: HexSearchPattern, in data: Data, ignoreCase: Bool) -> [Range<Int>] {
        guard !pattern.bytes.isEmpty, !data.isEmpty else { return [] }
        // 忽略大小写：对 ASCII 字母折叠后搜索（折叠不改变字节数与位置映射）
        let folded: [UInt8]
        if ignoreCase {
            folded = data.map(foldByte)
        } else {
            folded = [UInt8](data)
        }
        let hasWildcard = pattern.bytes.contains { $0.high == nil || $0.low == nil }
        if hasWildcard {
            return naiveSearch(pattern: pattern.bytes, in: folded)
        }
        let concrete = pattern.bytes.map { byte in
            let value = (byte.high! << 4) | byte.low!
            return ignoreCase ? foldByte(value) : value
        }
        return kmpSearch(pattern: concrete, in: folded)
    }

    private static func foldByte(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    /// 带 nibble 通配的朴素搜索：模式通常很短，最坏 O(n·m) 在后台任务中可接受。
    private static func naiveSearch(pattern: [Byte], in data: [UInt8]) -> [Range<Int>] {
        let count = data.count
        let length = pattern.count
        guard length <= count else { return [] }
        var matches: [Range<Int>] = []
        var start = 0
        while start <= count - length {
            var matched = true
            for offset in 0..<length {
                let byte = data[start + offset]
                let expected = pattern[offset]
                if let high = expected.high, byte >> 4 != high {
                    matched = false
                    break
                }
                if let low = expected.low, byte & 0xF != low {
                    matched = false
                    break
                }
            }
            if matched {
                matches.append(start..<(start + length))
                start += length
            } else {
                start += 1
            }
        }
        return matches
    }

    /// KMP：无通配的确定模式，最坏 O(n + m)。
    private static func kmpSearch(pattern: [UInt8], in data: [UInt8]) -> [Range<Int>] {
        guard !pattern.isEmpty, pattern.count <= data.count else { return [] }
        var fail = [Int](repeating: 0, count: pattern.count)
        var k = 0
        for i in 1..<pattern.count {
            while k > 0, pattern[i] != pattern[k] { k = fail[k - 1] }
            if pattern[i] == pattern[k] { k += 1 }
            fail[i] = k
        }
        var matches: [Range<Int>] = []
        var j = 0
        for i in 0..<data.count {
            while j > 0, data[i] != pattern[j] { j = fail[j - 1] }
            if data[i] == pattern[j] { j += 1 }
            if j == pattern.count {
                matches.append((i - pattern.count + 1)..<(i + 1))
                j = fail[j - 1]
            }
        }
        return matches
    }
}

/// 工具条 → 编辑器视图的命令：跳转偏移、展示并选中匹配。
enum HexEditorCommand {
    case jump(to: Int)
    case showMatch(index: Int)
}

// MARK: - SwiftUI 包装

/// 二进制文件的十六进制编辑器：偏移 / Hex / ASCII 三列，可点选、拖选、
/// 直接键入十六进制或 ASCII 字符编辑，⌘C / ⌘V / ⌘Z 走编辑器自身的
/// UndoManager（与文本编辑器同策略，避免共享窗口撤销栈的悬垂记录）。
struct HexEditorView: NSViewRepresentable {
    let file: FileTab
    let palette: EditorPalette
    var isFocused: Bool = true
    var onFocused: () -> Void = {}
    var onSplit: (PaneDropEdge) -> Void = { _ in }
    var onNewBrowserTab: (String?) -> Void = { _ in }
    var onNewBrowserPane: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(file: file)
    }

    final class Coordinator: NSObject {
        let file: FileTab
        var wasFocused = false
        var scrollObserver: (any NSObjectProtocol)?

        init(file: FileTab) {
            self.file = file
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        // 与文本编辑器一致：全尺寸内容视图下不叠加标题栏 inset。
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.clipsToBounds = true

        let editor = HexEditorNSView(file: file, palette: palette)
        editor.onFocused = onFocused
        editor.splitTarget.onSplit = onSplit
        editor.splitTarget.onNewBrowserTab = onNewBrowserTab
        editor.splitTarget.onNewBrowserPane = onNewBrowserPane
        scrollView.documentView = editor

        // 恢复光标 / 选区（字节偏移即 editorState 的字符位置语义）
        editor.restore(state: file.editorState)
        // 供分屏拖拽缩略图快照使用。
        file.editorView = scrollView

        // 滚动位置与光标视野在首次布局后恢复；没有保存过滚动位置则滚到光标处。
        let state = file.editorState
        DispatchQueue.main.async { [weak scrollView, weak editor] in
            guard let scrollView, let editor else { return }
            scrollView.layoutSubtreeIfNeeded()
            let clipView = scrollView.contentView
            if state.scrollX != nil || state.scrollY != nil {
                clipView.setBoundsOrigin(NSPoint(x: state.scrollX ?? 0, y: state.scrollY ?? 0))
                scrollView.reflectScrolledClipView(clipView)
            }
            editor.syncDocumentWidth(to: clipView.bounds.width)
            if state.scrollX == nil && state.scrollY == nil {
                editor.scrollCursorIntoViewOnMount()
            }
        }

        // 滚动位置写回 editorState，随会话快照持久化；同时让文档宽度跟随
        // 视口（窄于内容时保留横向滚动）。
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak scrollView, weak file] _ in
            MainActor.assumeIsolated {
                guard let file, let scrollView else { return }
                let clipView = scrollView.contentView
                file.editorState.scrollX = clipView.bounds.origin.x
                file.editorState.scrollY = clipView.bounds.origin.y
                (scrollView.documentView as? HexEditorNSView)?
                    .syncDocumentWidth(to: clipView.bounds.width)
            }
        }

        // 外部文件变动（事件监听）静默重载后刷新视图。
        file.onReloadHexData = { [weak editor] in
            editor?.reloadFromFile()
        }

        if isFocused {
            DispatchQueue.main.async {
                editor.window?.makeFirstResponder(editor)
            }
        }
        context.coordinator.wasFocused = isFocused
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? HexEditorNSView else { return }
        editor.onFocused = onFocused
        editor.splitTarget.onSplit = onSplit
        editor.splitTarget.onNewBrowserTab = onNewBrowserTab
        editor.splitTarget.onNewBrowserPane = onNewBrowserPane
        if editor.palette != palette {
            editor.palette = palette
            editor.needsDisplay = true
        }
        if isFocused, !context.coordinator.wasFocused {
            DispatchQueue.main.async {
                editor.window?.makeFirstResponder(editor)
            }
        }
        context.coordinator.wasFocused = isFocused
    }

    /// 与文本编辑器一致：占满 SwiftUI 给出的空间，不参与窗口理想尺寸计算。
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
}

// MARK: - 编辑器本体

/// 十六进制编辑器核心视图：作为 NSScrollView 的 documentView 存在，
/// 按可见行范围增量绘制，交互（点选 / 拖选 / 键盘编辑 / 剪贴板 / 撤销）
/// 全部在视图内完成，数据模型始终是 `FileTab.hexData`。
final class HexEditorNSView: NSView {
    let file: FileTab
    var palette: EditorPalette
    var onFocused: (() -> Void)?
    /// 分屏上下文菜单项（与终端 / 文本编辑器共用）。
    let splitTarget = SplitMenuTarget()

    /// 光标所在字节偏移
    private(set) var cursor = 0
    /// 拖选 / ⇧ 键选起点；nil 表示无选区
    private var anchor: Int?
    /// 悬停字节（仅高亮，不参与选区）
    private var hoveredOffset: Int?
    /// 当前编辑区域：十六进制（默认）或 ASCII
    private var editMode: HexEditMode = .hex
    /// 连续键入的撤销分组标志
    private var isTypingGroupOpen = false
    /// 撤销栈随 FileTab 生命周期（工具条替换与编辑器键入共用，跨挂载保留）。
    private var hexUndoManager: UndoManager { file.hexUndoManager }
    private var trackingAreaRef: NSTrackingArea?
    /// 监听 FileTab 发布的状态变化：重绘（搜索高亮等）并在数据长度变化时重建几何。
    private var fileObservation: AnyCancellable?
    private var lastDataCount = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { file.hexUndoManager }

    init(file: FileTab, palette: EditorPalette) {
        self.file = file
        self.palette = palette
        super.init(frame: .zero)
        lastDataCount = file.hexData.count
        updateDocumentSize()
        fileObservation = file.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncAfterModelChange()
            }
        }
        // 工具条（搜索跳转 / 替换）通过命令驱动光标与视野。
        file.onHexEditorCommand = { [weak self] command in
            self?.handle(command)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if isTypingGroupOpen {
            file.hexUndoManager.endUndoGrouping()
        }
    }

    /// 模型状态变化后的同步：数据长度变化（工具条替换 / 撤销）时重建几何并夹紧光标，
    /// 其余变化（搜索高亮、dirty 状态）仅重绘。
    private func syncAfterModelChange() {
        if file.hexData.count != lastDataCount {
            lastDataCount = file.hexData.count
            updateDocumentSize()
            clampCursorAndSelection()
        }
        needsDisplay = true
    }

    private func clampCursorAndSelection() {
        let last = max(0, file.hexData.count - 1)
        cursor = min(cursor, last)
        if let anchorValue = anchor {
            let clampedAnchor = min(anchorValue, last)
            if clampedAnchor == cursor {
                anchor = nil
            } else {
                anchor = clampedAnchor
            }
        }
        updateSelectionSummary()
    }

    private func handle(_ command: HexEditorCommand) {
        switch command {
        case .jump(let offset):
            guard file.hexData.count > 0 else { return }
            moveCursor(to: min(max(0, offset), file.hexData.count - 1), extend: false)
            scrollCursorIntoView()
        case .showMatch(let index):
            guard file.hexMatches.indices.contains(index) else { return }
            let range = file.hexMatches[index]
            guard !range.isEmpty else { return }
            anchor = range.lowerBound
            cursor = range.upperBound - 1
            updateSelectionSummary()
            scrollCursorIntoView()
            needsDisplay = true
        }
    }

    // MARK: - 几何

    static func rowCount(for byteCount: Int) -> Int {
        (byteCount + HexLayout.bytesPerRow - 1) / HexLayout.bytesPerRow
    }

    /// 文档高度随数据量变化；宽度跟随视口（至少容纳全部列，窄视口可横向滚动）。
    func updateDocumentSize() {
        let rows = Self.rowCount(for: file.hexData.count)
        let height = HexLayout.headerHeight + CGFloat(rows) * HexLayout.rowHeight + 4
        let width = max(HexLayout.totalWidth, bounds.width)
        let size = NSSize(width: width, height: height)
        if frame.size != size {
            setFrameSize(size)
        }
        needsDisplay = true
    }

    func syncDocumentWidth(to viewportWidth: CGFloat) {
        let width = max(HexLayout.totalWidth, viewportWidth)
        if frame.width != width {
            setFrameSize(NSSize(width: width, height: frame.height))
        }
    }

    // MARK: - 选区 / 光标

    var selectedRange: NSRange {
        guard let anchor else { return NSRange(location: cursor, length: 0) }
        let low = min(anchor, cursor)
        let high = max(anchor, cursor)
        return NSRange(location: low, length: high - low + 1)
    }

    /// 从会话状态恢复光标与选区（字节偏移）。
    func restore(state: EditorState) {
        let count = file.hexData.count
        if count > 0, let location = state.selectionLocation {
            cursor = min(max(0, location), count - 1)
            let length = state.selectionLength ?? 0
            if length > 0 {
                anchor = cursor
                cursor = min(cursor + length - 1, count - 1)
            }
        }
        updateSelectionSummary()
    }

    /// 外部文件变动静默重载后：重建文档尺寸、丢弃撤销历史、夹紧光标。
    func reloadFromFile() {
        file.hexUndoManager.removeAllActions()
        if isTypingGroupOpen {
            file.hexUndoManager.endUndoGrouping()
            isTypingGroupOpen = false
        }
        lastDataCount = file.hexData.count
        updateDocumentSize()
        cursor = min(cursor, max(0, file.hexData.count - 1))
        anchor = nil
        hoveredOffset = nil
        updateSelectionSummary()
        needsDisplay = true
    }

    private func updateSelectionSummary() {
        let range = selectedRange
        file.updateHexSelection(offset: range.location, length: range.length)
    }

    private func scrollCursorIntoView() {
        guard file.hexData.count > 0 else { return }
        let row = cursor / HexLayout.bytesPerRow
        let index = cursor % HexLayout.bytesPerRow
        let y = HexLayout.headerHeight + CGFloat(row) * HexLayout.rowHeight
        let x: CGFloat
        if editMode == .ascii {
            x = HexLayout.asciiX + CGFloat(index) * HexLayout.charWidth
        } else {
            x = HexLayout.byteX(index)
        }
        scrollToVisible(NSRect(
            x: x, y: y,
            width: HexLayout.charWidth * 3, height: HexLayout.rowHeight
        ))
    }

    /// 编辑器挂载时把光标滚入视野（无保存滚动位置时）。
    func scrollCursorIntoViewOnMount() {
        scrollCursorIntoView()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        palette.background.setFill()
        dirtyRect.fill()

        let headerRect = NSRect(x: 0, y: 0, width: bounds.width, height: HexLayout.headerHeight)
        if headerRect.intersects(dirtyRect) {
            drawHeader()
        }

        let data = file.hexData
        let rowCount = Self.rowCount(for: data.count)
        guard rowCount > 0 else { return }

        let bodyTop = HexLayout.headerHeight
        let firstRow = max(0, Int(floor((dirtyRect.minY - bodyTop) / HexLayout.rowHeight)))
        let lastRow = min(
            rowCount - 1,
            Int(ceil((dirtyRect.maxY - bodyTop) / HexLayout.rowHeight))
        )
        guard firstRow <= lastRow else { return }

        let selection = selectedRange
        for row in firstRow...lastRow {
            drawRow(row, data: data, selection: selection)
        }

        if anchor == nil, data.count > 0 {
            drawCaret()
        }
    }

    private func drawHeader() {
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: HexLayout.headerHeight)
        palette.text.withAlphaComponent(0.05).setFill()
        rect.fill()
        palette.text.withAlphaComponent(0.15).setFill()
        NSRect(x: 0, y: HexLayout.headerHeight - 1, width: bounds.width, height: 1).fill()

        let y = (HexLayout.headerHeight - HexLayout.lineHeight) / 2
        drawString(L10n.t("Offset"), at: NSPoint(x: HexLayout.gutterX, y: y), color: palette.gutterText)
        drawString("Hex", at: NSPoint(x: HexLayout.hexX, y: y), color: palette.gutterText)
        drawString("ASCII", at: NSPoint(x: HexLayout.asciiX, y: y), color: palette.gutterText)
    }

    private func drawRow(_ row: Int, data: Data, selection: NSRange) {
        let rowStart = row * HexLayout.bytesPerRow
        let y = HexLayout.headerHeight + CGFloat(row) * HexLayout.rowHeight
        let cellHeight = HexLayout.rowHeight - 2
        let textY = y + 2

        drawString(
            String(format: "%08X", rowStart),
            at: NSPoint(x: HexLayout.gutterX, y: textY),
            color: palette.gutterText
        )

        for index in 0..<HexLayout.bytesPerRow {
            let offset = rowStart + index
            guard offset < data.count else { break }
            let byte = data[offset]
            let hexX = HexLayout.byteX(index)
            let isSelected = selection.contains(offset)
            let isHovered = hoveredOffset == offset
            // 搜索匹配高亮：当前匹配更亮，其余匹配弱化
            let matchIndex = file.hexMatchIndex(containing: offset)
            let isCurrentMatch = matchIndex == file.hexCurrentMatchIndex
                && file.hexMatches.indices.contains(file.hexCurrentMatchIndex)

            let fillColor: NSColor?
            if isSelected {
                fillColor = palette.text.withAlphaComponent(0.30)
            } else if isCurrentMatch {
                fillColor = palette.insertionPoint.withAlphaComponent(0.38)
            } else if matchIndex != nil {
                fillColor = palette.text.withAlphaComponent(0.16)
            } else if isHovered {
                fillColor = palette.text.withAlphaComponent(0.08)
            } else {
                fillColor = nil
            }
            let textColor = isSelected ? palette.background : palette.text

            if let fillColor {
                fillColor.setFill()
                NSRect(x: hexX, y: y + 1, width: HexLayout.charWidth * 2, height: cellHeight).fill()
            }
            drawString(
                String(format: "%02X", byte),
                at: NSPoint(x: hexX, y: textY),
                color: textColor
            )

            let asciiX = HexLayout.asciiX + CGFloat(index) * HexLayout.charWidth
            if let fillColor {
                fillColor.setFill()
                NSRect(x: asciiX, y: y + 1, width: HexLayout.charWidth, height: cellHeight).fill()
            }
            drawString(
                Self.asciiCharacter(for: byte),
                at: NSPoint(x: asciiX, y: textY),
                color: textColor
            )
        }
    }

    private func drawCaret() {
        let row = cursor / HexLayout.bytesPerRow
        let index = cursor % HexLayout.bytesPerRow
        let y = HexLayout.headerHeight + CGFloat(row) * HexLayout.rowHeight
        let x: CGFloat
        if editMode == .ascii {
            x = HexLayout.asciiX + CGFloat(index) * HexLayout.charWidth
        } else {
            x = HexLayout.byteX(index)
        }
        palette.insertionPoint.setFill()
        NSRect(x: x, y: y + 1, width: 1.5, height: HexLayout.rowHeight - 2).fill()
    }

    private func drawString(_ string: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: HexLayout.font,
            .foregroundColor: color,
        ]
        (string as NSString).draw(at: point, withAttributes: attributes)
    }

    static func asciiCharacter(for byte: UInt8) -> String {
        (0x20...0x7E).contains(byte) ? String(UnicodeScalar(byte)) : "."
    }

    // MARK: - 命中测试

    private func offset(at point: NSPoint) -> Int? {
        guard point.y >= HexLayout.headerHeight else { return nil }
        let row = Int((point.y - HexLayout.headerHeight) / HexLayout.rowHeight)
        guard row >= 0, row < Self.rowCount(for: file.hexData.count) else { return nil }
        let base = row * HexLayout.bytesPerRow
        if let byteIndex = HexLayout.byteIndex(atX: point.x) {
            let offset = base + byteIndex
            return offset < file.hexData.count ? offset : nil
        }
        if point.x >= HexLayout.asciiX,
           point.x < HexLayout.asciiX + HexLayout.asciiColumnWidth {
            let index = min(
                Int((point.x - HexLayout.asciiX) / HexLayout.charWidth),
                HexLayout.bytesPerRow - 1
            )
            let offset = base + index
            return offset < file.hexData.count ? offset : nil
        }
        return nil
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        endTypingGroup()
        window?.makeFirstResponder(self)
        onFocused?()
        let point = convert(event.locationInWindow, from: nil)
        guard let offset = offset(at: point) else { return }
        if event.modifierFlags.contains(.shift) {
            if anchor == nil { anchor = cursor }
            cursor = offset
        } else if event.clickCount == 2 {
            // 双击选中当前字节
            anchor = offset
            cursor = offset
        } else {
            anchor = nil
            cursor = offset
        }
        updateSelectionSummary()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let offset = offset(at: point) else { return }
        if anchor == nil { anchor = cursor }
        if offset != cursor {
            cursor = offset
            updateSelectionSummary()
            needsDisplay = true
            autoscroll(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover = offset(at: point)
        if newHover != hoveredOffset {
            hoveredOffset = newHover
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredOffset != nil {
            hoveredOffset = nil
            needsDisplay = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocused?() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        // 失焦时收尾未闭合的键入撤销分组，避免下次键入并入同一步撤销。
        endTypingGroup()
        return super.resignFirstResponder()
    }

    // MARK: - 键盘编辑

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let extend = flags.contains(.shift)
        let keyCode = event.keyCode

        switch keyCode {
        case 123: endTypingGroup(); moveCursor(by: -1, extend: extend)
        case 124: endTypingGroup(); moveCursor(by: 1, extend: extend)
        case 125: endTypingGroup(); moveCursor(by: HexLayout.bytesPerRow, extend: extend)
        case 126: endTypingGroup(); moveCursor(by: -HexLayout.bytesPerRow, extend: extend)
        case 115: endTypingGroup(); moveCursor(to: rowStartOffset(), extend: extend)
        case 119: endTypingGroup(); moveCursor(to: rowEndOffset(), extend: extend)
        case 116: endTypingGroup(); moveCursor(by: -visibleRowCount(), extend: extend)
        case 121: endTypingGroup(); moveCursor(by: visibleRowCount(), extend: extend)
        case 48: // Tab：切换 Hex / ASCII 编辑区域
            endTypingGroup()
            editMode = editMode == .ascii ? .hex : .ascii
            needsDisplay = true
        case 51: // Backspace：当前字节清零并回退一格
            endTypingGroup()
            guard cursor > 0 else { NSSound.beep(); return }
            beginTypingGroup()
            setByte(cursor - 1, to: 0)
            endTypingGroup()
            moveCursor(by: -1, extend: false)
        case 117: // Forward Delete：当前字节清零
            endTypingGroup()
            guard cursor < file.hexData.count else { NSSound.beep(); return }
            beginTypingGroup()
            setByte(cursor, to: 0)
            endTypingGroup()
        case 36, 76: // Return：跳到下一个匹配（⇧ 上一个）
            endTypingGroup()
            file.hexShowNextMatch(delta: event.modifierFlags.contains(.shift) ? -1 : 1)
        default:
            guard !flags.contains(.command), !flags.contains(.control),
                  let characters = event.characters, !characters.isEmpty
            else {
                endTypingGroup()
                super.keyDown(with: event)
                return
            }
            if editMode == .hex, let value = Self.hexValue(of: characters) {
                beginTypingGroup()
                let target = selectionStart()
                setByte(target, to: value)
                moveCursor(to: target + 1, extend: false)
            } else if editMode == .ascii, let byte = Self.asciiValue(of: characters) {
                beginTypingGroup()
                let target = selectionStart()
                setByte(target, to: byte)
                moveCursor(to: target + 1, extend: false)
            } else {
                endTypingGroup()
                NSSound.beep()
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            copySelection(style: editMode == .ascii ? .ascii : .hex)
            return true
        case "x":
            cutSelection()
            return true
        case "v":
            pasteFromPasteboard()
            return true
        case "z":
            endTypingGroup()
            if event.modifierFlags.contains(.shift) {
                file.hexUndoManager.redo()
            } else {
                file.hexUndoManager.undo()
            }
            // 撤销 / 重做可能改变数据长度（替换），重建几何并夹紧光标
            syncAfterModelChange()
            return true
        case "a":
            endTypingGroup()
            guard file.hexData.count > 0 else { return true }
            anchor = 0
            cursor = file.hexData.count - 1
            updateSelectionSummary()
            scrollCursorIntoView()
            needsDisplay = true
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// 十六进制编辑模式下接受的输入：0-9、A-F（大小写均可）。
    private static func hexValue(of characters: String) -> UInt8? {
        guard let character = characters.lowercased().first,
              let value = character.hexDigitValue, value < 16
        else { return nil }
        return UInt8(value)
    }

    /// ASCII 编辑模式下接受的输入：可打印 ASCII（0x20–0x7E）。
    private static func asciiValue(of characters: String) -> UInt8? {
        guard characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value <= 0x7E
        else { return nil }
        return UInt8(scalar.value)
    }

    private func beginTypingGroup() {
        if !isTypingGroupOpen {
            hexUndoManager.beginUndoGrouping()
            isTypingGroupOpen = true
        }
    }

    private func endTypingGroup() {
        if isTypingGroupOpen {
            hexUndoManager.endUndoGrouping()
            isTypingGroupOpen = false
        }
    }

    private func setByte(_ offset: Int, to value: UInt8) {
        guard offset >= 0, offset < file.hexData.count else { NSSound.beep(); return }
        file.setHexByte(at: offset, to: value, undoManager: hexUndoManager)
        anchor = nil
        updateSelectionSummary()
        needsDisplay = true
    }

    /// 有选区时从选区起点开始编辑；无选区时即光标位置。
    private func selectionStart() -> Int {
        guard let anchor else { return cursor }
        return min(anchor, cursor)
    }

    private func moveCursor(by delta: Int, extend: Bool) {
        let count = file.hexData.count
        guard count > 0 else { return }
        moveCursor(to: min(max(0, cursor + delta), count - 1), extend: extend)
    }

    private func moveCursor(to target: Int, extend: Bool) {
        let count = file.hexData.count
        guard count > 0 else { return }
        let clamped = min(max(0, target), count - 1)
        if extend {
            if anchor == nil { anchor = cursor }
        } else {
            anchor = nil
        }
        cursor = clamped
        updateSelectionSummary()
        scrollCursorIntoView()
        needsDisplay = true
    }

    private func rowStartOffset() -> Int {
        (cursor / HexLayout.bytesPerRow) * HexLayout.bytesPerRow
    }

    private func rowEndOffset() -> Int {
        min(rowStartOffset() + HexLayout.bytesPerRow, file.hexData.count) - 1
    }

    private func visibleRowCount() -> Int {
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        return max(1, Int(visibleHeight / HexLayout.rowHeight) - 1)
    }

    // MARK: - 剪贴板

    private enum HexCopyStyle {
        case hex, ascii, cString
    }

    private func copySelection(style: HexCopyStyle) {
        let range = selectedRange
        guard range.length > 0 else { NSSound.beep(); return }
        let data = file.hexData.subdata(
            in: range.location..<min(range.location + range.length, file.hexData.count)
        )
        let string: String
        switch style {
        case .hex:
            string = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .ascii:
            string = data.map { Self.asciiCharacter(for: $0) }.joined()
        case .cString:
            string = data.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func cutSelection() {
        let range = selectedRange
        guard range.length > 0 else { NSSound.beep(); return }
        copySelection(style: editMode == .ascii ? .ascii : .hex)
        file.replaceHexBytes(
            at: range.location,
            with: Data(repeating: 0, count: range.length),
            undoManager: hexUndoManager
        )
        anchor = nil
        updateSelectionSummary()
        needsDisplay = true
    }

    private func pasteFromPasteboard() {
        endTypingGroup()
        guard let string = NSPasteboard.general.string(forType: .string),
              file.hexData.count > 0
        else { NSSound.beep(); return }
        let bytes = Self.pasteBytes(from: string)
        guard !bytes.isEmpty else { NSSound.beep(); return }
        let start = selectionStart()
        let replaced = min(bytes.count, file.hexData.count - start)
        guard replaced > 0 else { NSSound.beep(); return }
        file.replaceHexBytes(at: start, with: bytes, undoManager: hexUndoManager)
        moveCursor(to: start + replaced, extend: false)
        needsDisplay = true
    }

    /// 解析剪贴板内容：去掉 `0x` 前缀与常见分隔符后若全是成对十六进制字符
    /// 则按十六进制字节解析（如 `DE AD BE EF`、`0x12, 0x34`），否则按 UTF-8 文本。
    static func pasteBytes(from string: String) -> Data {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var probe = trimmed
            .replacingOccurrences(of: "0x", with: " ")
            .replacingOccurrences(of: "0X", with: " ")
        probe.removeAll { $0.isWhitespace || $0 == "," || $0 == "_" }
        if !probe.isEmpty, probe.count % 2 == 0, probe.allSatisfy(\.isHexDigit) {
            var data = Data()
            data.reserveCapacity(probe.count / 2)
            var index = probe.startIndex
            while index < probe.endIndex {
                let next = probe.index(index, offsetBy: 2)
                if let value = UInt8(probe[index..<next], radix: 16) {
                    data.append(value)
                }
                index = next
            }
            return data
        }
        return Data(trimmed.utf8)
    }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        // 右键点击的字节成为新光标（不破坏已有选区）。
        let point = convert(event.locationInWindow, from: nil)
        if let offset = offset(at: point),
           !selectedRange.contains(offset) {
            cursor = offset
            anchor = nil
            updateSelectionSummary()
        }

        let menu = NSMenu()
        if selectedRange.length > 0 {
            menu.addItem(
                withTitle: L10n.t("Copy as Hex"),
                action: #selector(copyHex(_:)),
                keyEquivalent: ""
            )
            menu.addItem(
                withTitle: L10n.t("Copy as ASCII"),
                action: #selector(copyASCII(_:)),
                keyEquivalent: ""
            )
            menu.addItem(
                withTitle: L10n.t("Copy as C String"),
                action: #selector(copyCString(_:)),
                keyEquivalent: ""
            )
            menu.addItem(.separator())
        }
        menu.addItem(
            withTitle: L10n.t("Paste"),
            action: #selector(pasteAction(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        for item in splitTarget.menuItems() { menu.addItem(item) }
        needsDisplay = true
        L10n.localizeMenu(menu)
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyHex(_:)), #selector(copyASCII(_:)), #selector(copyCString(_:)):
            return selectedRange.length > 0
        case #selector(pasteAction(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }

    @objc private func copyHex(_ sender: Any?) { copySelection(style: .hex) }
    @objc private func copyASCII(_ sender: Any?) { copySelection(style: .ascii) }
    @objc private func copyCString(_ sender: Any?) { copySelection(style: .cString) }
    @objc private func pasteAction(_ sender: Any?) { pasteFromPasteboard() }
}

private enum HexEditMode {
    case hex, ascii
}

// MARK: - 底部状态栏

/// 十六进制编辑器状态栏：保存状态、文件大小、光标偏移 / 选区字节数，
/// 以及右侧的「跳转到偏移」按钮（弹出 DEC / HEX 对话框）。
struct HexEditorStatusBar: View {
    @ObservedObject var file: FileTab
    @State private var isJumpHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Label(file.isDirty ? L10n.t("Unsaved") : L10n.t("Saved"), systemImage: file.isDirty ? "circle" : "checkmark.circle")
                .foregroundStyle(.secondary)
                .macTooltip(file.isDirty ? L10n.t("Unsaved Changes") : L10n.t("Saved to Disk"), shortcut: "⌘S", position: .top)
            Text(file.editorFileSize)
                .monospacedDigit()
                .macTooltip(L10n.t("File Size"), position: .top)
            Spacer()
            if let summary = file.hexSelectionSummary {
                Text(summary)
                    .monospacedDigit()
                    .macTooltip(L10n.t("Selection Summary"), position: .top)
            }
            Text("Hex")
                .macTooltip(L10n.t("Hex Editor"), position: .top)

            Divider()
                .frame(height: 12)
                .padding(.horizontal, 2)

            Button {
                file.presentHexJumpDialog()
            } label: {
                Image(systemName: "location")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(
                            isJumpHovering
                                ? Color.primary.opacity(0.08)
                                : Color.clear
                        )
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isJumpHovering = $0 }
            .macTooltip(L10n.t("Jump to Offset"), position: .top)
            .accessibilityLabel(L10n.t("Jump to Offset"))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.primary.opacity(0.035))
    }
}
