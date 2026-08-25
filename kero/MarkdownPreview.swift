//
//  MarkdownPreview.swift
//  kero
//
//  Markdown 源文件的左右分栏预览：左侧继续用 STTextView 编辑，右侧 WKWebView
//  渲染 GitHub 风格 HTML；编辑防抖后实时更新，相对图片按文件所在目录解析。
//

import AppKit
import SwiftUI
import WebKit

/// Markdown 专用文件查看：默认为纯编辑；点预览后左右分栏。
struct MarkdownFileViewerView: View {
    @ObservedObject var file: FileTab
    let themeName: String
    var isFocused: Bool
    var onFocused: () -> Void
    var onSplit: (PaneDropEdge) -> Void
    var onNewBrowserTab: (String?) -> Void
    var onNewBrowserPane: (String?) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("markdownPreviewEnabled") private var isPreviewEnabled = false
    @AppStorage("markdownPreviewSplitFraction") private var splitFraction: Double = 0.5
    @AppStorage("markdownWrapLines") private var markdownWrapLines = true

    var body: some View {
        VStack(spacing: 0) {
            if file.hasExternalConflict {
                FileExternalConflictBar(file: file)
            }
            if let error = file.saveError {
                FileSaveErrorBar(message: error)
            }

            GeometryReader { geometry in
                let showPreview = isPreviewEnabled
                let handleWidth: CGFloat = 7
                let totalWidth = geometry.size.width
                let availableWidth = showPreview
                    ? max(10, totalWidth - handleWidth)
                    : totalWidth
                let leftWidth = showPreview
                    ? min(max(availableWidth * splitFraction, 160), availableWidth - 160)
                    : availableWidth
                let rightWidth = showPreview ? max(160, availableWidth - leftWidth) : 0

                HStack(spacing: 0) {
                    editor
                        .frame(width: leftWidth, height: geometry.size.height)

                    if showPreview {
                        HorizontalSplitHandle(
                            fraction: $splitFraction,
                            range: 0.2...0.8,
                            defaultFraction: 0.5,
                            availableWidth: availableWidth
                        )
                        MarkdownPreviewView(
                            file: file,
                            palette: previewPalette,
                            onOpenURL: openPreviewURL
                        )
                        .frame(width: rightWidth, height: geometry.size.height)
                    }
                }
                .frame(width: totalWidth, height: geometry.size.height)
            }

            if settings.showEditorStatusBar {
                EditorStatusBar(file: file)
                    .zIndex(100)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !settings.showEditorStatusBar {
                previewToggleButton
                    .padding(8)
            }
        }
        .observeLocalization()
    }

    private var editor: some View {
        SourceTextEditor(
            file: file,
            font: TerminalFont.current(),
            palette: .theme(
                themeName: themeName,
                dark: colorScheme == .dark
            ),
            syntaxTheme: SyntaxHighlighting.theme(
                themeName: themeName, dark: colorScheme == .dark
            ),
            wrapLines: markdownWrapLines,
            isFocused: isFocused,
            onFocused: onFocused,
            onSplit: onSplit,
            onNewBrowserTab: onNewBrowserTab,
            onNewBrowserPane: onNewBrowserPane
        )
    }

    private var previewPalette: MarkdownPreviewPalette {
        MarkdownPreviewPalette.make(
            themeName: themeName,
            dark: colorScheme == .dark
        )
    }

    private var previewToggleButton: some View {
        Button {
            isPreviewEnabled.toggle()
        } label: {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isPreviewEnabled ? Color(nsColor: Theme.accent) : .secondary
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .macTooltip(
            isPreviewEnabled
                ? L10n.t("Hide Markdown Preview")
                : L10n.t("Show Markdown Preview"),
            position: .bottom
        )
        .accessibilityLabel(L10n.t("Toggle Markdown Preview"))
    }

    private func openPreviewURL(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            onNewBrowserTab(url.absoluteString)
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct MarkdownPreviewPalette: Equatable {
    var background: String
    var foreground: String
    var secondary: String
    var accent: String
    var codeBackground: String
    var border: String
    var isDark: Bool

    static func make(themeName: String, dark: Bool) -> MarkdownPreviewPalette {
        let palette = EditorPalette.theme(themeName: themeName, dark: dark)
        let secondary = palette.text.blended(withFraction: 0.42, of: palette.background)
            ?? palette.text.withAlphaComponent(0.68)
        let border = palette.text.blended(withFraction: 0.82, of: palette.background)
            ?? palette.text.withAlphaComponent(0.18)
        return MarkdownPreviewPalette(
            background: Theme.hex(palette.background),
            foreground: Theme.hex(palette.text),
            secondary: Theme.hex(secondary),
            accent: Theme.hex(palette.insertionPoint),
            codeBackground: Theme.hex(palette.lineHighlight),
            border: Theme.hex(border),
            isDark: dark
        )
    }
}

/// WKWebView 包装：壳页面只加载一次，之后用 JS 换 HTML 以免丢掉滚动位置。
private struct MarkdownPreviewView: NSViewRepresentable {
    @ObservedObject var file: FileTab
    let palette: MarkdownPreviewPalette
    var onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(file: file, onOpenURL: onOpenURL)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            context.coordinator.resources,
            forURLScheme: MarkdownPreviewResourceHandler.scheme
        )
        configuration.userContentController.add(
            context.coordinator.scrollBridge,
            name: MarkdownScrollBridge.messageName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        applyBackground(webView)
        context.coordinator.attach(webView: webView, directory: fileDirectory)
        context.coordinator.loadShell(
            webView,
            palette: palette,
            emptyLabel: L10n.t("Nothing to preview")
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.bindScrollCallbacks()
        context.coordinator.resources.rootDirectory = fileDirectory
        applyBackground(webView)
        context.coordinator.update(
            source: file.text,
            palette: palette,
            revision: file.textRevision,
            path: file.path,
            emptyLabel: L10n.t("Nothing to preview")
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: WKWebView, context: Context
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

    private var fileDirectory: URL {
        URL(fileURLWithPath: file.path).deletingLastPathComponent()
    }

    private func applyBackground(_ webView: WKWebView) {
        let color = NSColor(
            srgbRed: component(palette.background, shift: 16),
            green: component(palette.background, shift: 8),
            blue: component(palette.background, shift: 0),
            alpha: 1
        )
        webView.underPageBackgroundColor = color
    }

    private func component(_ hex: String, shift: Int) -> CGFloat {
        let value = Int(hex, radix: 16) ?? 0
        return CGFloat((value >> shift) & 0xff) / 255
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let file: FileTab
        var onOpenURL: (URL) -> Void
        let resources = MarkdownPreviewResourceHandler()
        let scrollBridge = MarkdownScrollBridge()
        private weak var webView: WKWebView?
        private var didLoadShell = false
        private var pendingHTML: String?
        private var lastHTML = ""
        private var lastPalette: MarkdownPreviewPalette?
        private var lastPath = ""
        private var lastRevision: UInt64 = .max
        private var lastEmptyLabel = ""
        private var updateTask: Task<Void, Never>?

        init(file: FileTab, onOpenURL: @escaping (URL) -> Void) {
            self.file = file
            self.onOpenURL = onOpenURL
            super.init()
            scrollBridge.onLine = { [weak self] line in
                self?.handlePreviewScroll(line)
            }
        }

        func attach(webView: WKWebView, directory: URL) {
            self.webView = webView
            resources.rootDirectory = directory
            bindScrollCallbacks()
        }

        func bindScrollCallbacks() {
            file.onMarkdownScrollToPreview = { [weak self] line in
                self?.scrollToLine(line)
            }
        }

        func loadShell(
            _ webView: WKWebView,
            palette: MarkdownPreviewPalette,
            emptyLabel: String = ""
        ) {
            didLoadShell = false
            lastPalette = palette
            let label = emptyLabel.isEmpty ? lastEmptyLabel : emptyLabel
            lastEmptyLabel = label
            webView.loadHTMLString(
                MarkdownPreviewChrome.html(palette: palette, emptyLabel: label),
                baseURL: MarkdownPreviewResourceHandler.baseURL
            )
        }

        func update(
            source: String,
            palette: MarkdownPreviewPalette,
            revision: UInt64,
            path: String,
            emptyLabel: String
        ) {
            guard let webView else { return }
            if emptyLabel != lastEmptyLabel, didLoadShell {
                lastEmptyLabel = emptyLabel
                setEmptyLabel(emptyLabel)
            } else {
                lastEmptyLabel = emptyLabel
            }
            if lastPalette != palette, didLoadShell {
                lastPalette = palette
                applyTheme(palette)
            }
            if !lastPath.isEmpty, path != lastPath {
                lastHTML = ""
                lastRevision = .max
                loadShell(webView, palette: palette, emptyLabel: emptyLabel)
            }
            lastPath = path
            guard revision != lastRevision else { return }
            lastRevision = revision
            updateTask?.cancel()
            let delay: UInt64 = lastHTML.isEmpty ? 0 : 180_000_000
            updateTask = Task { @MainActor [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                }
                let html = await Task.detached(priority: .userInitiated) {
                    MarkdownHTML.render(source)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.apply(html: html, palette: palette)
            }
        }

        private func apply(html: String, palette: MarkdownPreviewPalette) {
            if lastPalette != palette {
                lastPalette = palette
                applyTheme(palette)
            }
            guard html != lastHTML else { return }
            lastHTML = html
            if didLoadShell {
                setHTML(html)
            } else {
                pendingHTML = html
            }
        }

        private func setHTML(_ html: String) {
            guard let webView else { return }
            let lines = MarkdownSourceLine.starts(in: file.text).count
            struct Payload: Encodable {
                var html: String
                var lines: Int
            }
            guard let payload = encodeJSON(Payload(html: html, lines: lines)) else { return }
            webView.evaluateJavaScript("window.__qjiaoSetMarkdown(\(payload))") { [weak self] _, _ in
                Task { @MainActor in
                    self?.file.emitMarkdownEditorVisibleLine?()
                }
            }
        }

        private func scrollToLine(_ line: Double) {
            guard didLoadShell, let webView, let payload = encodeJSON(line) else { return }
            file.beginMarkdownScrollEchoSuppression()
            webView.evaluateJavaScript("window.__qjiaoScrollToLine(\(payload))")
        }

        private func handlePreviewScroll(_ line: Double) {
            guard !file.isMarkdownScrollEchoSuppressed else { return }
            file.beginMarkdownScrollEchoSuppression()
            file.onMarkdownScrollToEditor?(line)
        }

        private func applyTheme(_ palette: MarkdownPreviewPalette) {
            guard let webView,
                  let payload = encodeJSON(palette.cssVariables)
            else { return }
            webView.evaluateJavaScript("window.__qjiaoSetTheme(\(payload))")
        }

        private func setEmptyLabel(_ label: String) {
            guard let webView, let payload = encodeJSON(label) else { return }
            webView.evaluateJavaScript("window.__qjiaoSetEmpty(\(payload))")
        }

        private func encodeJSON(_ value: some Encodable) -> String? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didLoadShell = true
            if let palette = lastPalette {
                applyTheme(palette)
            }
            if let html = pendingHTML {
                pendingHTML = nil
                setHTML(html)
            } else if !lastHTML.isEmpty {
                setHTML(lastHTML)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            didLoadShell = false
            if let palette = lastPalette {
                loadShell(webView, palette: palette, emptyLabel: lastEmptyLabel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                if let url = navigationAction.request.url {
                    onOpenURL(url)
                }
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// 预览滚动把当前源码行回传给编辑器。
private final class MarkdownScrollBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "qjiaoMarkdownScroll"
    var onLine: ((Double) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let line: Double
        if let value = message.body as? Double {
            line = value
        } else if let value = message.body as? NSNumber {
            line = value.doubleValue
        } else {
            return
        }
        onLine?(line)
    }
}

/// 把预览里的相对图片映射到 Markdown 文件所在目录。
/// WebKit 可能在后台线程回调，因此不能落在默认 MainActor 隔离上。
private final class MarkdownPreviewResourceHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "qjiao-md"
    static let baseURL = URL(string: "\(scheme)://preview/")!

    private let lock = NSLock()
    private var storedRoot = URL(fileURLWithPath: "/")
    var rootDirectory: URL {
        get { lock.withLock { storedRoot } }
        set { lock.withLock { storedRoot = newValue } }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
            )
            return
        }
        guard let target = localFile(for: url) else {
            if url.path == "/" || url.path.isEmpty {
                let data = Data()
                let response = URLResponse(
                    url: url,
                    mimeType: "text/html",
                    expectedContentLength: 0,
                    textEncodingName: "utf-8"
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                return
            }
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
            )
            return
        }
        guard let data = try? Data(contentsOf: target) else {
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
            )
            return
        }
        let mime = mimeType(for: target.pathExtension)
        let response = URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    /// 把 `qjiao-md://preview/assets/foo%20bar.png` 解到 Markdown 目录下的真实文件。
    private func localFile(for requestURL: URL) -> URL? {
        var relative = requestURL.path(percentEncoded: false)
        if relative.hasPrefix("/") {
            relative = String(relative.dropFirst())
        }
        if relative.isEmpty { return nil }
        if let decoded = relative.removingPercentEncoding {
            relative = decoded
        }
        let target = URL(fileURLWithPath: relative, relativeTo: rootDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let root = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path == root.path || target.path.hasPrefix(rootPath) else {
            return nil
        }
        return target
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }
}

private enum MarkdownPreviewChrome {
    static func html(palette: MarkdownPreviewPalette, emptyLabel: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { \(palette.cssDeclarations) }
          html, body {
            margin: 0;
            padding: 0;
            background: var(--md-bg);
            color: var(--md-fg);
            font: 14px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          #content {
            box-sizing: border-box;
            max-width: 860px;
            margin: 0 auto;
            padding: 20px 28px 48px;
            overflow-wrap: anywhere;
          }
          #content:empty::before {
            content: attr(data-empty);
            color: var(--md-muted);
          }
          h1, h2, h3, h4, h5, h6 {
            line-height: 1.3;
            font-weight: 650;
            margin: 1.4em 0 0.6em;
          }
          h1 { font-size: 1.85em; border-bottom: 1px solid var(--md-border); padding-bottom: 0.3em; }
          h2 { font-size: 1.45em; border-bottom: 1px solid var(--md-border); padding-bottom: 0.25em; }
          h3 { font-size: 1.2em; }
          p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
          a {
            color: var(--md-accent);
            text-decoration: underline;
            text-underline-offset: 0.18em;
          }
          a:hover { filter: brightness(1.18); }
          ul, ol { padding-left: 1.6em; }
          li { margin: 0.2em 0; }
          li input[type="checkbox"] { margin-right: 0.4em; }
          blockquote {
            margin-left: 0;
            padding: 0.1em 0 0.1em 0.9em;
            border-left: 3px solid var(--md-accent);
            color: var(--md-muted);
          }
          code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.9em;
            background: var(--md-code);
            padding: 0.12em 0.35em;
            border-radius: 4px;
          }
          pre {
            background: var(--md-code);
            border: 1px solid var(--md-border);
            border-radius: 8px;
            padding: 12px 14px;
            overflow: auto;
          }
          pre code { background: none; padding: 0; font-size: 12px; line-height: 1.55; }
          img { max-width: 100%; height: auto; }
          hr { border: 0; border-top: 1px solid var(--md-border); margin: 1.6em 0; }
          table { border-collapse: collapse; width: 100%; display: block; overflow: auto; }
          th, td {
            border: 1px solid var(--md-border);
            padding: 6px 10px;
          }
          th { background: var(--md-code); font-weight: 600; }
          del { color: var(--md-muted); }
        </style>
        </head>
        <body>
        <article id="content" data-empty="\(MarkdownHTML.escapeAttribute(emptyLabel))"></article>
        <script>
          window.__qjiaoTotalLines = 1;
          window.__qjiaoSuppressScroll = false;
          function codeLineElements() {
            return Array.from(document.querySelectorAll("[data-line]")).filter(el => {
              return !el.querySelector("[data-line]");
            }).map(el => ({
              line: Number(el.getAttribute("data-line")),
              top: el.getBoundingClientRect().top + window.scrollY
            })).filter(item => Number.isFinite(item.line))
              .sort((a, b) => a.line - b.line || a.top - b.top);
          }
          function maxScrollY() {
            return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
          }
          function scrollToSourceLine(line) {
            const els = codeLineElements();
            if (!els.length) return;
            const maxY = maxScrollY();
            const total = window.__qjiaoTotalLines || els[els.length - 1].line;
            if (line <= els[0].line) {
              window.scrollTo(window.scrollX, 0);
              return;
            }
            if (line >= total) {
              window.scrollTo(window.scrollX, maxY);
              return;
            }
            let prev = els[0];
            let next = null;
            for (let i = 1; i < els.length; i++) {
              if (els[i].line > line) { next = els[i]; break; }
              prev = els[i];
            }
            if (!next) {
              const span = Math.max(maxY - prev.top, 1e-6);
              const t = Math.min(Math.max((line - prev.line) / Math.max(total - prev.line, 1e-6), 0), 1);
              window.scrollTo(window.scrollX, Math.max(0, Math.min(maxY, prev.top + span * t)));
              return;
            }
            const span = Math.max(next.line - prev.line, 1e-6);
            const t = (line - prev.line) / span;
            const y = prev.top + (next.top - prev.top) * t;
            window.scrollTo(window.scrollX, Math.max(0, Math.min(maxY, y)));
          }
          function sourceLineForViewport() {
            const y = window.scrollY;
            const maxY = maxScrollY();
            const els = codeLineElements();
            if (!els.length) return 1;
            const total = window.__qjiaoTotalLines || els[els.length - 1].line;
            if (y <= 1) return els[0].line;
            if (maxY > 0 && y >= maxY - 2) return total;
            let prev = els[0];
            let next = null;
            for (let i = 1; i < els.length; i++) {
              if (els[i].top > y + 0.5) { next = els[i]; break; }
              prev = els[i];
            }
            if (!next) {
              const span = Math.max(maxY - prev.top, 1e-6);
              const t = Math.min(Math.max((y - prev.top) / span, 0), 1);
              return prev.line + (total - prev.line) * t;
            }
            const span = Math.max(next.top - prev.top, 1e-6);
            const t = Math.min(Math.max((y - prev.top) / span, 0), 1);
            return prev.line + (next.line - prev.line) * t;
          }
          window.__qjiaoSetMarkdown = function(payload) {
            const html = payload && payload.html != null ? payload.html : (payload || "");
            if (payload && payload.lines) window.__qjiaoTotalLines = payload.lines;
            const el = document.getElementById("content");
            el.innerHTML = html || "";
          };
          window.__qjiaoScrollToLine = function(line) {
            window.__qjiaoSuppressScroll = true;
            scrollToSourceLine(line);
            setTimeout(function() { window.__qjiaoSuppressScroll = false; }, 140);
          };
          window.__qjiaoSetTheme = function(vars) {
            const root = document.documentElement;
            Object.keys(vars || {}).forEach(key => root.style.setProperty(key, vars[key]));
            document.body.style.background = vars["--md-bg"] || "";
            document.body.style.color = vars["--md-fg"] || "";
          };
          window.__qjiaoSetEmpty = function(label) {
            const el = document.getElementById("content");
            if (el) el.setAttribute("data-empty", label || "");
          };
          let scrollFrame = 0;
          window.addEventListener("scroll", function() {
            if (window.__qjiaoSuppressScroll) return;
            if (scrollFrame) cancelAnimationFrame(scrollFrame);
            scrollFrame = requestAnimationFrame(function() {
              scrollFrame = 0;
              const line = sourceLineForViewport();
              try {
                window.webkit.messageHandlers.qjiaoMarkdownScroll.postMessage(line);
              } catch (e) {}
            });
          }, { passive: true });
        </script>
        </body>
        </html>
        """
    }
}

private extension MarkdownPreviewPalette {
    var cssVariables: [String: String] {
        [
            "--md-bg": "#\(background)",
            "--md-fg": "#\(foreground)",
            "--md-muted": "#\(secondary)",
            "--md-accent": "#\(accent)",
            "--md-code": "#\(codeBackground)",
            "--md-border": "#\(border)",
        ]
    }

    var cssDeclarations: String {
        cssVariables.map { "\($0.key): \($0.value);" }.joined(separator: " ")
    }
}
