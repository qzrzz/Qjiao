//
//  MarkdownWysiwygEditor.swift
//  kero
//
//  Markdown 所见即所得编辑器：基于 nodes-app/swift-markdown-engine 的原生
//  TextKit 2 编辑器（MarkdownEngine + MarkdownEngineCodeBlocks）。文本仍写回
//  FileTab，复用脏标记 / 自动保存 / 外部冲突与滚动持久化。
//

import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import SwiftUI

/// Markdown 文件的编辑模式：所见即所得，或源码编辑（可叠加预览）。
enum MarkdownEditorMode: String, CaseIterable, Identifiable {
    case wysiwyg
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wysiwyg: return L10n.t("WYSIWYG")
        case .source: return L10n.t("Source")
        }
    }

    var systemImage: String {
        switch self {
        case .wysiwyg: return "doc.richtext"
        case .source: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 切到该模式按钮的提示文案。
    var switchToTooltip: String {
        switch self {
        case .wysiwyg: return L10n.t("Show WYSIWYG Editor")
        case .source: return L10n.t("Show Source Editor")
        }
    }

    var other: MarkdownEditorMode {
        self == .wysiwyg ? .source : .wysiwyg
    }
}

/// 引擎级共享对象：HighlighterSwiftBridge 初始化较重，全局复用一份；
/// 本地图片 Provider 按 Markdown 目录缓存，避免每次 body 求值都重建。
@MainActor
enum MarkdownEditorSupport {
    static let highlighter = HighlighterSwiftBridge()

    private static var imageProviders: [String: MarkdownLocalImageProvider] = [:]

    static func imageProvider(for directory: URL) -> MarkdownLocalImageProvider {
        let key = directory.standardizedFileURL.path
        if let existing = imageProviders[key] { return existing }
        let provider = MarkdownLocalImageProvider(markdownDirectory: directory)
        imageProviders[key] = provider
        return provider
    }
}

/// 把 `![](assets/…)` 等本地图片解析为 NSImage；不联网。
struct MarkdownLocalImageProvider: EmbeddedImageProvider {
    let markdownDirectory: URL

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        guard let url = Self.resolve(reference.name, relativeTo: markdownDirectory) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// 以 `assets/`（否则 Markdown 所在目录）的修改时间作为缓存指纹，
    /// 图片增删时让引擎的图片缓存失效。
    func fingerprint() -> AnyHashable {
        let assets = markdownDirectory.appendingPathComponent("assets", isDirectory: true)
        let probe = FileManager.default.fileExists(atPath: assets.path)
            ? assets
            : markdownDirectory
        let date = (try? probe.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return date?.timeIntervalSince1970 ?? 0
    }

    /// 解析 Markdown 图片 URL：相对路径按 Markdown 目录，支持 `file://` 与绝对路径。
    /// `http(s)` / `data:` 一律返回 nil（不加载远程资源）。
    static func resolve(_ raw: String, relativeTo directory: URL) -> URL? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // 去掉可选的 Markdown 标题：`assets/a.png "标题"` / `'标题'`
        if let space = name.firstIndex(of: " "), space != name.startIndex {
            name = String(name[..<space])
        }
        // 尖括号包裹的 URL
        if name.hasPrefix("<"), name.hasSuffix(">"), name.count > 2 {
            name = String(name.dropFirst().dropLast())
        }
        let lowered = name.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("data:") || lowered.hasPrefix("mailto:")
        {
            return nil
        }
        if lowered.hasPrefix("file://"), let url = URL(string: name) {
            return url
        }
        guard name.hasPrefix("/") == false else {
            return URL(fileURLWithPath: name)
        }
        let decoded = name.removingPercentEncoding ?? name
        let target = URL(fileURLWithPath: decoded, relativeTo: directory)
            .standardizedFileURL
        return target
    }
}

/// SwiftUI 包装的 WYSIWYG Markdown 编辑器。
struct MarkdownWysiwygEditor: View {
    @ObservedObject var file: FileTab
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme

    let themeName: String
    var isFocused: Bool = true
    var onFocused: () -> Void = {}

    @State private var wikiLinkActive = false

    private var palette: EditorPalette {
        .theme(themeName: themeName, dark: colorScheme == .dark)
    }

    private var font: NSFont {
        TerminalFont.current()
    }

    var body: some View {
        NativeTextViewWrapper(
            text: textBinding,
            isWikiLinkActive: $wikiLinkActive,
            configuration: configuration,
            fontName: font.fontName,
            fontSize: font.pointSize,
            documentId: file.path,
            onPasteImage: { pasteboard in
                MarkdownImageInsert.snippet(from: pasteboard, markdownPath: file.path)
            },
            onTextMutation: { _ in onFocused() },
            onPersistScrollOffset: { _, offsetY in
                file.editorState.scrollY = Double(offsetY)
            },
            restoreScrollOffset: { _ in
                file.editorState.scrollY.map { CGFloat($0) }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(themeIdentity)
        .background {
            WysiwygFocusBridge(isFocused: isFocused, onFocused: onFocused)
        }
        .background(Color(nsColor: palette.background))
        .observeLocalization()
    }

    /// 编辑器主题 / 明暗变化时重建底层视图，让引擎应用新的配色
    /// （引擎只在 makeNSView 时读取 theme，运行时不会重刷）。
    private var themeIdentity: String {
        "\(themeName)-\(colorScheme == .dark ? "dark" : "light")"
    }

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.theme = theme
        config.services = MarkdownEditorServices(
            images: MarkdownEditorSupport.imageProvider(
                for: URL(fileURLWithPath: file.path).deletingLastPathComponent()
            ),
            syntaxHighlighter: MarkdownEditorSupport.highlighter
        )
        config.heightBehavior = .scrolls
        config.rawSourceMode = false
        // 始终显示 Markdown 语法标记（Qjiao 对引擎的补丁），便于直接编辑源码。
        config.revealMarkers = true
        // 链接与普通文本一样点击即编辑，仅 ⌘/⌃ + 点击才跳转。
        config.linksRequireModifierClick = true
        // 缩小标题字号，降低与正文的大小落差。
        config.headings.fontMultipliers = [1.5, 1.3, 1.15, 1.05, 1.0, 0.95]
        // 左右页边距 20pt。
        config.textInsets = TextInsets(horizontal: 20)
        // Markdown 源码使用直引号，关闭智能替换与拼写标记。
        config.spellChecking = SpellCheckingPolicy(
            continuousSpellChecking: false,
            grammarChecking: false,
            automaticSpellingCorrection: false,
            automaticQuoteSubstitution: false
        )
        return config
    }

    private var theme: MarkdownEditorTheme {
        let palette = palette
        let accent = palette.insertionPoint
        var theme = MarkdownEditorTheme()
        theme.bodyText = palette.text
        theme.mutedText = palette.gutterText
        theme.disabledText = palette.gutterText.withAlphaComponent(0.55)
        theme.headingMarker = accent
        theme.link = accent
        theme.incompleteLink = accent.withAlphaComponent(0.75)
        theme.findMatchHighlight = accent.withAlphaComponent(0.28)
        theme.findCurrentMatchHighlight = accent.withAlphaComponent(0.5)
        theme.strikethroughColor = palette.text
        theme.highlightColor = accent.withAlphaComponent(0.35)
        theme.latexLightModeText = .black
        theme.latexDarkModeText = .white
        return theme
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { file.text },
            set: { newValue in
                guard newValue != file.text else { return }
                file.text = newValue
                file.refreshDirtyState()
                file.noteTextChanged()
            }
        )
    }
}

/// 引擎未对外暴露 text view（internal），这里用启发式做两件事：
/// 1. 挂载 / 聚焦边沿时把焦点交给本 pane 的编辑器；
/// 2. 点击进入编辑器时把 pane 标记为已聚焦（`FileTab` 之外的模型状态）。
///
/// 做法：读取同窗口内与本锚点帧最近的 `NativeTextView`（按类型名识别），
/// 再观察 `NSText.didBeginEditingNotification` 做身份比对。
private struct WysiwygFocusBridge: NSViewRepresentable {
    var isFocused: Bool
    var onFocused: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        let coordinator = context.coordinator
        view.onMoveToWindow = { [weak view] in
            coordinator.attach(anchor: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFocused = onFocused
        context.coordinator.setFocused(isFocused)
    }

    @MainActor
    final class Coordinator {
        var onFocused: () -> Void = {}
        private weak var anchor: NSView?
        private weak var engineTextView: NSTextView?
        private var isFocused = false
        private var didFocus = false
        private var observer: NSObjectProtocol?

        func attach(anchor: NSView?) {
            self.anchor = anchor
            installObserverIfNeeded()
            attemptFocus(retries: 12)
        }

        func setFocused(_ focused: Bool) {
            let wasFocused = isFocused
            isFocused = focused
            if focused, !wasFocused { attemptFocus(retries: 12) }
        }

        /// 尝试把焦点交给本 pane 的编辑器；视图创建顺序不定，允许少量重试。
        private func attemptFocus(retries: Int) {
            guard isFocused, !didFocus else { return }
            if engineTextView == nil { resolveEngineTextView() }
            guard let textView = engineTextView, let window = textView.window else {
                guard retries > 0 else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.attemptFocus(retries: retries - 1)
                }
                return
            }
            didFocus = true
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }

        private func installObserverIfNeeded() {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSText.didBeginEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let textView = note.object as? NSTextView else { return }
                    if self.engineTextView == nil { self.resolveEngineTextView() }
                    if textView === self.engineTextView {
                        self.didFocus = true
                        self.onFocused()
                    }
                }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// 选择同窗口内离锚点帧中心最近的 `NativeTextView`（多分屏时区分本 pane）。
        private func resolveEngineTextView() {
            guard let anchor, let window = anchor.window, let content = window.contentView else {
                return
            }
            let anchorRect = anchor.convert(anchor.bounds, to: nil)
            var best: (view: NSTextView, distance: CGFloat)?
            func walk(_ view: NSView) {
                if String(describing: type(of: view)) == "NativeTextView",
                   let textView = view as? NSTextView
                {
                    let rect = view.convert(view.bounds, to: nil)
                    let dx = rect.midX - anchorRect.midX
                    let dy = rect.midY - anchorRect.midY
                    let distance = dx * dx + dy * dy
                    if best == nil || distance < best!.distance {
                        best = (textView, distance)
                    }
                }
                for subview in view.subviews { walk(subview) }
            }
            walk(content)
            engineTextView = best?.view
        }
    }

    @MainActor
    private final class AnchorView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onMoveToWindow?() }
        }
    }
}
