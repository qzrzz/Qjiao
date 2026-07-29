//
//  BrowserView.swift
//  kero
//

import AppKit
import Combine
import ImageIO
import SwiftUI
import WebKit

/// 注入页面的链接右键探针，用于把 WebKit 默认“新窗口”动作映射到 Qjiao Tab / Pane。
private enum BrowserContextMenuSupport {
    static let messageName = "qjiaoContextMenuLink"
    static let script = #"""
    (() => {
      window.addEventListener("contextmenu", event => {
        let element = event.target;
        if (element?.nodeType === Node.TEXT_NODE) {
          element = element.parentElement;
        }
        const link = element?.closest?.("a[href], area[href]");
        window.webkit.messageHandlers.qjiaoContextMenuLink.postMessage(
          link?.href || ""
        );
      }, true);
    })()
    """#
}

/// 将页面脚本得到的链接传回对应的 WebView。
private final class BrowserContextMenuBridge: NSObject, WKScriptMessageHandler {
    weak var webView: BrowserWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        webView?.contextMenuLink = message.body as? String
    }
}

/// 可长期保留的原生网页视图，同时负责 Pane 聚焦和链接右键菜单。
final class BrowserWebView: WKWebView {
    var onFocused: (() -> Void)?
    var onNewBrowserTab: ((String?) -> Void)?
    var onNewBrowserPane: ((String?) -> Void)?

    fileprivate var contextMenuLink: String? {
        didSet {
            guard let contextMenuLink,
                  let url = URL(string: contextMenuLink),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme)
            else {
                contextMenuLinkURL = nil
                return
            }
            contextMenuLinkURL = url
        }
    }

    private var contextMenuLinkURL: URL?
    private static let openLinkInNewTabIdentifier =
        NSUserInterfaceItemIdentifier("qjiao.browser.openLinkInNewTab")
    private static let openLinkInNewPaneIdentifier =
        NSUserInterfaceItemIdentifier("qjiao.browser.openLinkInNewPane")

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        contextMenuLink = nil
        onFocused?()
        super.rightMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let linkURL = contextMenuLinkURL else { return }

        removeDefaultOpenInNewWindow(from: menu)
        guard !menu.items.contains(where: {
            $0.identifier == Self.openLinkInNewTabIdentifier
        }) else { return }

        let insertionIndex = min(1, menu.items.count)
        menu.insertItem(
            linkMenuItem(
                L10n.t("Open Link in New Browser Tab"),
                identifier: Self.openLinkInNewTabIdentifier,
                action: #selector(openLinkInNewTab(_:)),
                linkURL: linkURL
            ),
            at: insertionIndex
        )
        menu.insertItem(
            linkMenuItem(
                L10n.t("Open Link in New Browser Pane"),
                identifier: Self.openLinkInNewPaneIdentifier,
                action: #selector(openLinkInNewPane(_:)),
                linkURL: linkURL
            ),
            at: insertionIndex + 1
        )
        let separatorIndex = insertionIndex + 2
        if separatorIndex < menu.items.count,
           !menu.items[separatorIndex].isSeparatorItem {
            menu.insertItem(.separator(), at: separatorIndex)
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextMenuLink = nil
    }

    private func removeDefaultOpenInNewWindow(from menu: NSMenu) {
        if let item = menu.items.first(where: {
            $0.title == L10n.t("Open Link in New Window")
                || ($0.tag == 1 && $0.action != nil)
        }) {
            menu.removeItem(item)
        }
    }

    private func linkMenuItem(
        _ title: String,
        identifier: NSUserInterfaceItemIdentifier,
        action: Selector,
        linkURL: URL
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.identifier = identifier
        item.target = self
        item.representedObject = linkURL.absoluteString
        return item
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        onNewBrowserTab?(sender.representedObject as? String)
    }

    @objc private func openLinkInNewPane(_ sender: NSMenuItem) {
        onNewBrowserPane?(sender.representedObject as? String)
    }
}

/// 一个浏览器 Pane 的长期状态；WKWebView 随模型保留，切 Tab 时不会丢失页面历史和滚动位置。
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable,
    WKNavigationDelegate, WKUIDelegate
{
    /// 浏览器首次稳定挂载后应该取得的焦点。
    enum InitialFocus {
        case addressBar
        case webContent
        case none
    }

    nonisolated let id = UUID()

    @Published private(set) var title = L10n.t("New Browser Tab")
    @Published private(set) var urlString = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var favicon: NSImage?
    /// 使用序号而非 Bool，确保连续按下 ⌘L 不会被合并。
    @Published private(set) var focusAddressRequest: UInt = 0

    let webView: BrowserWebView

    private var pageTitle: String?
    private var observations: Set<AnyCancellable> = []
    private var initialFocus: InitialFocus?
    private let contextMenuBridge: BrowserContextMenuBridge
    private var faviconTask: Task<Void, Never>?
    private var faviconRevision: UInt = 0

    private static let maximumFaviconBytes = 2 * 1_024 * 1_024
    private static let faviconCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    private static let faviconCandidatesScript = #"""
    (() => {
      const score = link => {
        const sizes = Array.from(link.sizes || []);
        if (link.type === "image/svg+xml" || sizes.includes("any")) return 10000;
        return sizes.reduce((best, size) => {
          const match = size.match(/^(\d+)x(\d+)$/);
          return match
            ? Math.max(best, Math.min(Number(match[1]), Number(match[2])))
            : best;
        }, 0);
      };
      return Array.from(document.querySelectorAll("link[rel][href]"))
        .filter(link => {
          const rel = link.rel.toLowerCase();
          return rel.split(/\s+/).includes("icon")
            || rel.includes("apple-touch-icon");
        })
        .sort((a, b) => score(b) - score(a))
        .map(link => link.href);
    })()
    """#

    init(
        initialURL: String? = nil,
        initialFocus: InitialFocus = .addressBar
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = true

        let contextMenuBridge = BrowserContextMenuBridge()
        let contextWorld = WKContentWorld.defaultClient
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserContextMenuSupport.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: contextWorld
        ))
        configuration.userContentController.add(
            contextMenuBridge,
            contentWorld: contextWorld,
            name: BrowserContextMenuSupport.messageName
        )

        self.contextMenuBridge = contextMenuBridge
        webView = BrowserWebView(frame: .zero, configuration: configuration)
        self.initialFocus = initialFocus
        super.init()

        contextMenuBridge.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observeWebView()
        L10n.shared.$language
            .dropFirst()
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &observations)

        if let initialURL, !initialURL.isEmpty {
            navigate(to: initialURL)
        }
    }

    deinit {
        faviconTask?.cancel()
    }

    /// 快照仅保存可恢复的当前地址，空白页不写入。
    var snapshotURL: String? {
        urlString.isEmpty ? nil : urlString
    }

    /// 仅 HTTP(S) 地址可交给系统默认浏览器。
    var shareURL: URL? {
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    var isBlank: Bool { urlString.isEmpty }

    func consumeInitialFocus() -> InitialFocus? {
        defer { initialFocus = nil }
        return initialFocus
    }

    func requestAddressFocus() {
        focusAddressRequest &+= 1
    }

    /// 将地址栏内容按“显式 URL → 可能的主机名 → 搜索词”解析并打开。
    func navigate(to address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.destination(for: trimmed) else {
            return
        }
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            reload()
        }
    }

    func reload() {
        guard !isBlank else { return }
        errorMessage = nil
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func openInDefaultBrowser() {
        guard let shareURL else { return }
        NSWorkspace.shared.open(shareURL)
    }

    func copyAddress() {
        guard !urlString.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
    }

    private func observeWebView() {
        webView.publisher(for: \.title, options: [.initial, .new])
            .sink { [weak self] title in
                self?.pageTitle = title
                self?.refreshTitle()
            }
            .store(in: &observations)

        webView.publisher(for: \.url, options: [.initial, .new])
            .sink { [weak self] url in
                guard let self else { return }
                urlString = Self.displayAddress(for: url)
                refreshTitle()
            }
            .store(in: &observations)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .sink { [weak self] in self?.canGoBack = $0 }
            .store(in: &observations)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .sink { [weak self] in self?.canGoForward = $0 }
            .store(in: &observations)

        webView.publisher(for: \.isLoading, options: [.initial, .new])
            .sink { [weak self] isLoading in
                guard let self else { return }
                let startedLoading = isLoading && !self.isLoading
                self.isLoading = isLoading
                if startedLoading {
                    self.prepareForFaviconNavigation()
                } else if !isLoading, self.webView.url != nil {
                    self.loadFavicon()
                }
            }
            .store(in: &observations)

        webView.publisher(for: \.estimatedProgress, options: [.initial, .new])
            .sink { [weak self] in self?.estimatedProgress = $0 }
            .store(in: &observations)
    }

    private func refreshTitle() {
        if let pageTitle = pageTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !pageTitle.isEmpty {
            title = pageTitle
        } else if let host = webView.url?.host, !host.isEmpty {
            title = host
        } else {
            title = L10n.t("New Browser Tab")
        }
    }

    private static func displayAddress(for url: URL?) -> String {
        guard let url,
              url.absoluteString != "about:blank",
              url.scheme != nil
        else { return "" }
        return url.absoluteString
    }

    private static func destination(for input: String) -> URL? {
        let lowercased = input.lowercased()
        let explicitPrefixes = [
            "http://", "https://", "file://", "about:", "data:",
        ]
        if explicitPrefixes.contains(where: lowercased.hasPrefix) {
            return urlAllowingSpaces(input)
        }

        if !input.contains(where: \.isWhitespace), looksLikeHost(input) {
            let host = host(in: input).lowercased()
            let useHTTP = host == "localhost"
                || host.hasSuffix(".local")
                || isIPv4(host)
                || host.hasPrefix("[::")
                || hasExplicitPort(input)
            return urlAllowingSpaces(
                "\(useHTTP ? "http" : "https")://\(input)"
            )
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: input)]
        return components?.url
    }

    private static func looksLikeHost(_ input: String) -> Bool {
        let host = host(in: input)
        if host.caseInsensitiveCompare("localhost") == .orderedSame {
            return true
        }
        if host.hasPrefix("[") && host.contains("]") { return true }
        if host.contains(".") { return true }
        return hasExplicitPort(input)
    }

    private static func host(in input: String) -> String {
        let authority = input.split(separator: "/", maxSplits: 1)
            .first.map(String.init) ?? input
        if authority.hasPrefix("["),
           let bracket = authority.firstIndex(of: "]") {
            return String(authority[...bracket])
        }
        return authority.split(separator: ":", maxSplits: 1)
            .first.map(String.init) ?? authority
    }

    private static func isIPv4(_ host: String) -> Bool {
        let components = host.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return components.count == 4
            && components.allSatisfy {
                guard let octet = Int($0) else { return false }
                return (0...255).contains(octet)
            }
    }

    private static func hasExplicitPort(_ input: String) -> Bool {
        let authority = input.split(separator: "/", maxSplits: 1)
            .first.map(String.init) ?? input
        if authority.hasPrefix("["),
           let bracket = authority.firstIndex(of: "]") {
            let remainder = authority[authority.index(after: bracket)...]
            return remainder.first == ":" && Int(remainder.dropFirst()) != nil
        }
        guard let colon = authority.lastIndex(of: ":") else { return false }
        return Int(authority[authority.index(after: colon)...]) != nil
    }

    private static func urlAllowingSpaces(_ string: String) -> URL? {
        if let url = URL(string: string) { return url }
        return string.addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed
        ).flatMap(URL.init(string:))
    }

    // MARK: - Navigation

    private func prepareForFaviconNavigation() {
        errorMessage = nil
        faviconRevision &+= 1
        faviconTask?.cancel()
        faviconTask = nil
        favicon = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        showNavigationError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        showNavigationError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorMessage = L10n.t("The webpage stopped responding.")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased()
        else {
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "file", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    private func showNavigationError(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        errorMessage = nsError.localizedDescription
    }

    // MARK: - Favicon

    private func loadFavicon() {
        faviconTask?.cancel()
        let revision = faviconRevision
        faviconTask = Task { @MainActor [weak self] in
            guard let webView = self?.webView,
                  let pageURL = webView.url
            else { return }

            let result = try? await webView.evaluateJavaScript(
                Self.faviconCandidatesScript
            )
            let declared = result as? [String] ?? []
            var candidates = declared.compactMap {
                URL(string: $0, relativeTo: pageURL)?.absoluteURL
            }
            if let conventional = URL(
                string: "/favicon.ico",
                relativeTo: pageURL
            )?.absoluteURL {
                candidates.append(conventional)
            }

            var seen = Set<String>()
            for candidate in candidates
            where seen.insert(candidate.absoluteString).inserted {
                guard !Task.isCancelled else { return }

                if candidate.scheme?.lowercased() != "data",
                   let cached = Self.faviconCache.object(
                       forKey: candidate as NSURL
                   ) {
                    guard let self, faviconRevision == revision else { return }
                    favicon = cached
                    return
                }

                guard let data = await Self.faviconData(from: candidate),
                      !Task.isCancelled,
                      let image = Self.faviconImage(from: data)
                else { continue }

                if candidate.scheme?.lowercased() != "data" {
                    Self.faviconCache.setObject(
                        image,
                        forKey: candidate as NSURL,
                        cost: data.count
                    )
                }
                guard let self, faviconRevision == revision else { return }
                favicon = image
                return
            }
        }
    }

    private static func faviconData(from url: URL) async -> Data? {
        switch url.scheme?.lowercased() {
        case "data":
            return faviconData(fromDataURL: url)
        case "http", "https":
            var request = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 10
            )
            request.setValue(
                "image/avif,image/webp,image/svg+xml,image/*,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            guard let (data, response) = try? await URLSession.shared.data(
                for: request
            ),
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode),
            data.count <= maximumFaviconBytes
            else { return nil }
            return data
        default:
            return nil
        }
    }

    private static func faviconData(fromDataURL url: URL) -> Data? {
        let value = url.absoluteString
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let metadata = value[..<comma].lowercased()
        let payload = String(value[value.index(after: comma)...])
        let data: Data?
        if metadata.hasSuffix(";base64") {
            data = Data(
                base64Encoded: payload,
                options: .ignoreUnknownCharacters
            )
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, data.count <= maximumFaviconBytes else { return nil }
        return data
    }

    /// 将站点图标解码为有界位图，避免页面控制的超大图片占用异常内存。
    private static func faviconImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        let favicon = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        favicon.isTemplate = false
        return favicon
    }

    // MARK: - Web UI

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? L10n.t("Webpage")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("OK"))
        present(alert, for: webView) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? L10n.t("Webpage")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("OK"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        present(alert, for: webView) {
            completionHandler($0 == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = webView.title ?? L10n.t("Webpage")
        alert.informativeText = prompt
        alert.addButton(withTitle: L10n.t("OK"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        present(alert, for: webView) { response in
            completionHandler(
                response == .alertFirstButtonReturn
                    ? field.stringValue
                    : nil
            )
        }
    }

    private func present(
        _ alert: NSAlert,
        for webView: WKWebView,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// 独立观察 favicon 到达的浏览器内容图标。
struct BrowserFaviconView: View {
    @ObservedObject var browser: BrowserTab
    let size: CGFloat
    var fallbackSystemImage = "globe"

    @ViewBuilder
    var body: some View {
        if let favicon = browser.favicon {
            Image(nsImage: favicon)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(
                    cornerRadius: max(1.5, size * 0.18),
                    style: .continuous
                ))
        } else {
            Image(systemName: fallbackSystemImage)
                .frame(width: size, height: size)
        }
    }
}

/// 浏览器页面和原生导航栏；网页使用 WKWebView，工具栏沿用 Qjiao 主题。
struct BrowserView: View {
    @ObservedObject var browser: BrowserTab
    let isFocused: Bool
    let onFocused: () -> Void
    let onNewBrowserTab: (String?) -> Void
    let onNewBrowserPane: (String?) -> Void

    @ObservedObject private var themeChanges = Theme.changes
    @State private var address = ""
    @State private var addressFocused = false
    @State private var addressFocusRequest: UInt = 0
    @State private var webContentFocusRequest: UInt = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                BrowserWebViewRepresentable(
                    browser: browser,
                    onFocused: onFocused,
                    onNewBrowserTab: onNewBrowserTab,
                    onNewBrowserPane: onNewBrowserPane,
                    focusRequest: webContentFocusRequest
                )

                if browser.isBlank {
                    Color(nsColor: Theme.background)
                        .overlay {
                            Image(systemName: "globe")
                                .font(.system(size: 34, weight: .ultraLight))
                                .foregroundStyle(.tertiary)
                        }
                        .allowsHitTesting(false)
                }

                if let errorMessage = browser.errorMessage {
                    errorState(errorMessage)
                }
            }
            .overlay(alignment: .top) { progress }
        }
        .background(Color(nsColor: Theme.background))
        .onAppear { address = browser.urlString }
        .task(id: browser.id) {
            // 分屏插入会短暂挂载过渡视图；延迟到稳定实例再消费一次性焦点。
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            let initialFocus = browser.consumeInitialFocus()
            guard isFocused else { return }
            applyFocus(initialFocus ?? currentFocusStrategy)
        }
        .onChange(of: isFocused) {
            guard isFocused else { return }
            applyFocus(currentFocusStrategy)
        }
        .onChange(of: browser.urlString) {
            if !addressFocused {
                address = browser.urlString
            }
        }
        .onChange(of: browser.focusAddressRequest) {
            focusAddressField()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                toolbarButton(
                    "chevron.left",
                    help: L10n.t("Back"),
                    disabled: !browser.canGoBack,
                    action: browser.goBack
                )
                toolbarButton(
                    "chevron.right",
                    help: L10n.t("Forward"),
                    disabled: !browser.canGoForward,
                    action: browser.goForward
                )
                toolbarButton(
                    browser.isLoading ? "xmark" : "arrow.clockwise",
                    help: browser.isLoading
                        ? L10n.t("Stop")
                        : L10n.t("Reload Page (⌘R)"),
                    disabled: browser.isBlank && !browser.isLoading,
                    action: browser.reloadOrStop
                )
            }
            .frame(width: 94, alignment: .leading)

            Spacer(minLength: 0)
            addressField.frame(maxWidth: 720)
            Spacer(minLength: 0)

            HStack(spacing: 2) {
                toolbarButton(
                    "doc.on.doc",
                    help: L10n.t("Copy Address"),
                    disabled: browser.urlString.isEmpty,
                    action: browser.copyAddress
                )
                toolbarButton(
                    "arrow.up.right.square",
                    help: L10n.t("Open in Default Browser"),
                    disabled: browser.shareURL == nil,
                    action: browser.openInDefaultBrowser
                )
            }
            .frame(width: 94, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Color(nsColor: Theme.background))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            Image(systemName: addressIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)

            BrowserAddressField(
                text: $address,
                focusRequest: addressFocusRequest,
                onFocus: {
                    addressFocused = true
                    onFocused()
                },
                onBlur: { addressFocused = false },
                onSubmit: { browser.navigate(to: address) },
                onCancel: { address = browser.urlString }
            )
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(addressFocused ? 0.09 : 0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    addressFocused
                        ? Color(nsColor: Theme.accent).opacity(0.65)
                        : Color.primary.opacity(0.08),
                    lineWidth: addressFocused ? 1.5 : 1
                )
        )
    }

    private var addressIcon: String {
        if browser.isBlank { return "magnifyingglass" }
        guard let url = browser.webView.url else { return "magnifyingglass" }
        switch url.scheme?.lowercased() {
        case "https": return "lock.fill"
        case "http": return "globe"
        default: return "doc"
        }
    }

    @ViewBuilder
    private var progress: some View {
        if browser.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color(nsColor: Theme.accent))
                    .frame(
                        width: geometry.size.width
                            * max(0.04, min(1, browser.estimatedProgress))
                    )
            }
            .frame(height: 2)
            .allowsHitTesting(false)
        }
    }

    private func toolbarButton(
        _ systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onFocused()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(
                    cornerRadius: 6,
                    style: .continuous
                ))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.t("This webpage couldn’t be loaded."))
                .font(.headline)
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(L10n.t("Try Again")) { browser.reload() }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
    }

    private var currentFocusStrategy: BrowserTab.InitialFocus {
        browser.isBlank ? .addressBar : .webContent
    }

    private func focusAddressField() {
        addressFocusRequest &+= 1
    }

    private func applyFocus(_ strategy: BrowserTab.InitialFocus) {
        switch strategy {
        case .addressBar: focusAddressField()
        case .webContent: webContentFocusRequest &+= 1
        case .none: break
        }
    }
}

/// 地址栏首次点击选中全部；进入编辑后恢复正常光标定位。
final class BrowserAddressTextField: NSTextField {
    var isActivelyEditing = false

    override func mouseDown(with event: NSEvent) {
        guard isActivelyEditing else {
            selectText(nil)
            return
        }
        super.mouseDown(with: event)
    }

    @discardableResult
    func focusAndSelectAll() -> Bool {
        guard let window, window.makeFirstResponder(self) else { return false }
        selectText(nil)
        return true
    }
}

/// AppKit 地址输入框包装，避免 SwiftUI TextField 与 WKWebView 焦点互相覆盖。
private struct BrowserAddressField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusRequest: focusRequest,
            onFocus: onFocus,
            onBlur: onBlur,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> BrowserAddressTextField {
        let field = BrowserAddressTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        // 地址中的端口、IP 和版本号使用等宽数字，避免编辑时宽度跳动。
        field.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = L10n.t("Search or enter website name")
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.setAccessibilityLabel(L10n.t("Search or enter website name"))
        return field
    }

    func updateNSView(
        _ field: BrowserAddressTextField,
        context: Context
    ) {
        context.coordinator.update(from: self)
        field.placeholderString = L10n.t("Search or enter website name")
        field.setAccessibilityLabel(L10n.t("Search or enter website name"))
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        guard focusRequest != context.coordinator.handledFocusRequest else {
            return
        }
        context.coordinator.handledFocusRequest = focusRequest
        context.coordinator.focus(field)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var handledFocusRequest: UInt?
        private var onFocus: () -> Void
        private var onBlur: () -> Void
        private var onSubmit: () -> Void
        private var onCancel: () -> Void

        init(
            text: Binding<String>,
            focusRequest: UInt,
            onFocus: @escaping () -> Void,
            onBlur: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            handledFocusRequest = focusRequest == 0 ? 0 : nil
            self.onFocus = onFocus
            self.onBlur = onBlur
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func update(from field: BrowserAddressField) {
            text = field.$text
            onFocus = field.onFocus
            onBlur = field.onBlur
            onSubmit = field.onSubmit
            onCancel = field.onCancel
        }

        func focus(_ field: BrowserAddressTextField) {
            focus(field, attemptsRemaining: 6)
        }

        private func focus(
            _ field: BrowserAddressTextField,
            attemptsRemaining: Int
        ) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                if field.focusAndSelectAll() { return }
                guard attemptsRemaining > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focus(
                        field,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                }
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? BrowserAddressTextField)?
                .isActivelyEditing = true
            onFocus()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? BrowserAddressTextField)?
                .isActivelyEditing = false
            onBlur()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                text.wrappedValue = textView.string
                onSubmit()
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// 将长期持有的 WKWebView 挂载进当前 Pane，并可靠恢复网页内容焦点。
private struct BrowserWebViewRepresentable: NSViewRepresentable {
    @ObservedObject var browser: BrowserTab
    let onFocused: () -> Void
    let onNewBrowserTab: (String?) -> Void
    let onNewBrowserPane: (String?) -> Void
    let focusRequest: UInt

    func makeCoordinator() -> Coordinator {
        Coordinator(handledFocusRequest: focusRequest)
    }

    func makeNSView(context: Context) -> BrowserWebView {
        browser.webView.onFocused = onFocused
        browser.webView.onNewBrowserTab = onNewBrowserTab
        browser.webView.onNewBrowserPane = onNewBrowserPane
        return browser.webView
    }

    func updateNSView(_ webView: BrowserWebView, context: Context) {
        webView.onFocused = onFocused
        webView.onNewBrowserTab = onNewBrowserTab
        webView.onNewBrowserPane = onNewBrowserPane
        guard focusRequest != context.coordinator.handledFocusRequest else {
            return
        }
        context.coordinator.handledFocusRequest = focusRequest
        context.coordinator.focus(webView)
    }

    static func dismantleNSView(
        _ webView: BrowserWebView,
        coordinator: Coordinator
    ) {
        webView.onFocused = nil
        webView.onNewBrowserTab = nil
        webView.onNewBrowserPane = nil
    }

    final class Coordinator {
        var handledFocusRequest: UInt?

        init(handledFocusRequest: UInt) {
            self.handledFocusRequest = handledFocusRequest == 0 ? 0 : nil
        }

        func focus(_ webView: BrowserWebView) {
            focus(webView, attemptsRemaining: 6)
        }

        private func focus(
            _ webView: BrowserWebView,
            attemptsRemaining: Int
        ) {
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView else { return }
                if let window = webView.window,
                   window.makeFirstResponder(webView) {
                    return
                }
                guard attemptsRemaining > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focus(
                        webView,
                        attemptsRemaining: attemptsRemaining - 1
                    )
                }
            }
        }
    }
}
