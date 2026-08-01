//
//  TabSwitcher.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// 管理 Ctrl-Tab 切换手势；按住 Control 时只预选，松开后才真正切换。
@MainActor
final class TabSwitcherController: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var highlightedTabID: UUID?
    @Published private(set) var terminalPreviews: [UUID: String] = [:]
    /// 唤起切换手势时截取的 Tab 顺序列表（手势期间冻结，防止高亮卡片重新洗牌）。
    @Published private(set) var orderedTabIDs: [UUID] = []

    private weak var activeProject: Project?
    private var originalTabID: UUID?
    private var previewTask: Task<Void, Never>?
    private var isConsumingTabKey = false
    private var isConsumingEscapeKey = false
    private var acceptsPointerHighlight = false

    /// 切换器在界面中渲染的 Tab 列表（按 Recency 或默认顺序）。
    func orderedTabs(in project: Project) -> [PaneTab] {
        guard AppSettings.shared.tabSwitcherSortByRecency else { return project.tabs }
        let ordered = orderedTabIDs.compactMap { id in
            project.tabs.first { $0.id == id }
        }
        return ordered.isEmpty ? project.tabs : ordered
    }

    /// 处理窗口级键盘事件；返回 true 表示事件应被切换器消费。
    func handle(_ event: NSEvent, manager: TerminalManager) -> Bool {
        switch event.type {
        case .mouseMoved:
            // 切换器刚出现时可能正好位于静止指针下，等待真实移动后才允许 Hover 改写键盘选择。
            acceptsPointerHighlight = isPresented
        case .keyUp:
            if event.keyCode == 48, isConsumingTabKey {
                isConsumingTabKey = false
                return true
            }
            if event.keyCode == 53, isConsumingEscapeKey {
                isConsumingEscapeKey = false
                return true
            }
        case .keyDown:
            if isPresented, event.keyCode == 53 {
                isConsumingEscapeKey = true
                cancel()
                return true
            }
            guard event.keyCode == 48 else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control),
                  flags.isDisjoint(with: [.command, .option])
            else {
                isConsumingTabKey = false
                return false
            }
            if cycle(
                    manager: manager,
                    reverse: flags.contains(.shift)
            ) {
                isConsumingTabKey = true
                return true
            }
        case .flagsChanged:
            if isPresented, !event.modifierFlags.contains(.control) {
                commit()
                return true
            }
        default:
            break
        }
        return false
    }

    /// 点击列表项时立即选择并关闭切换器。
    func select(_ tabID: UUID, in project: Project) {
        guard project.tabs.contains(where: { $0.id == tabID }) else { return }
        project.selectTab(tabID)
        reset()
    }

    /// 指针移动到卡片后仅调整候选项，不提前切换真实标签。
    func highlight(_ tabID: UUID, in project: Project) {
        guard acceptsPointerHighlight,
              isPresented,
              activeProject === project,
              highlightedTabID != tabID,
              project.tabs.contains(where: { $0.id == tabID })
        else { return }
        highlightedTabID = tabID
    }

    private func cycle(manager: TerminalManager, reverse: Bool) -> Bool {
        guard let project = manager.selectedProject,
              project.tabs.count > 1,
              let selectedID = project.selectedTabID else { return false }

        if activeProject !== project || !isPresented {
            previewTask?.cancel()
            activeProject = project
            originalTabID = selectedID
            if AppSettings.shared.tabSwitcherSortByRecency {
                orderedTabIDs = project.tabsByRecency.map(\.id)
                let tabs = orderedTabs(in: project)
                let initialIndex = (reverse ? (tabs.count - 1) : 1) % tabs.count
                highlightedTabID = tabs[initialIndex].id
            } else {
                orderedTabIDs = project.tabs.map(\.id)
                highlightedTabID = selectedID
            }
            acceptsPointerHighlight = false
            let contentIDs = Set(project.tabs.flatMap(\.allContents).map(\.id))
            terminalPreviews = terminalPreviews.filter { contentIDs.contains($0.key) }
            isPresented = true
            refreshTerminalPreviews(in: project)
            return true
        }

        let tabs = orderedTabs(in: project)
        guard let currentID = highlightedTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentID })
        else {
            cancel()
            return false
        }
        let offset = reverse ? -1 : 1
        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        highlightedTabID = tabs[nextIndex].id
        return true
    }

    private func commit() {
        guard let project = activeProject,
              let tabID = highlightedTabID,
              project.tabs.contains(where: { $0.id == tabID }) else {
            cancel()
            return
        }
        project.selectTab(tabID)
        reset()
    }

    func cancel() {
        reset()
    }

    private func reset() {
        previewTask?.cancel()
        previewTask = nil
        isPresented = false
        highlightedTabID = nil
        originalTabID = nil
        activeProject = nil
        acceptsPointerHighlight = false
    }

    /// 只为已经初始化的终端刷新预览。访问惰性 Session 的 `terminalView`
    /// 会启动 Shell，因此必须先过滤，保证打开切换器不会改变后台生命周期。
    private func refreshTerminalPreviews(in project: Project) {
        let sessions = project.tabs
            .flatMap(\.sessions)
            .filter(\.isInitialized)
        guard !sessions.isEmpty else { return }

        previewTask = Task { @MainActor [weak self] in
            await Task.yield()
            for session in sessions {
                guard !Task.isCancelled,
                      let self,
                      self.isPresented,
                      session.isInitialized
                else { return }
                if let preview = TerminalHistorySerializer.previewText(
                    from: session.terminalView,
                    maxLines: 28,
                    maxColumns: 140
                ), terminalPreviews[session.id] != preview {
                    terminalPreviews[session.id] = preview
                }
                await Task.yield()
            }
        }
    }
}

/// 将 Ctrl-Tab 监听限制在当前 Qjiao 窗口，避免干扰其他窗口和应用。
struct TabSwitcherEventMonitor: NSViewRepresentable {
    let manager: TerminalManager
    let controller: TabSwitcherController

    func makeNSView(context: Context) -> TabSwitcherMonitorView {
        let view = TabSwitcherMonitorView()
        view.manager = manager
        view.controller = controller
        return view
    }

    func updateNSView(_ view: TabSwitcherMonitorView, context: Context) {
        view.manager = manager
        view.controller = controller
    }

    static func dismantleNSView(
        _ view: TabSwitcherMonitorView,
        coordinator: ()
    ) {
        view.detach()
    }
}

@MainActor
final class TabSwitcherMonitorView: NSView {
    weak var manager: TerminalManager?
    weak var controller: TabSwitcherController?

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .mouseMoved]
        ) { [weak self, weak window] event in
            guard let self,
                  let window,
                  window.isKeyWindow,
                  let manager,
                  let controller else { return event }
            return controller.handle(event, manager: manager) ? nil : event
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller?.cancel()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller?.cancel()
            }
        })
    }

    func detach() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// 切换器尺寸与上游保持一致，确保卡片密度、圆角和预览比例统一。
private enum TabSwitcherMetrics {
    static let cardWidth: CGFloat = 194
    static let cardHeight: CGFloat = 169
    static let cardHorizontalInset: CGFloat = 9
    static let cardBottomInset: CGFloat = 14
    static let previewWidth: CGFloat = 176
    static let previewHeight: CGFloat = 119
    static let titleSpacing: CGFloat = 9
    static let gridInset: CGFloat = 8
    static let previewCornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 16
    static let containerCornerRadius: CGFloat = 26
}

/// 与上游一致的居中预览网格；最多五列，空间不足时自动收缩并垂直滚动。
struct TabSwitcherOverlay: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var project: Project
    @ObservedObject var controller: TabSwitcherController
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let columnCount = columnsPerRow(availableWidth: geometry.size.width)

            ZStack {
                Color.clear
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: gridColumns(count: columnCount),
                            alignment: .leading,
                            spacing: 0
                        ) {
                            ForEach(Array(controller.orderedTabs(in: project).enumerated()), id: \.element.id) {
                                index, tab in
                                TabSwitcherCard(
                                    manager: manager,
                                    tab: tab,
                                    index: index,
                                    isHighlighted: tab.id == controller.highlightedTabID,
                                    terminalPreviews: controller.terminalPreviews,
                                    onHighlight: {
                                        controller.highlight(tab.id, in: project)
                                    },
                                    onSelect: {
                                        controller.select(tab.id, in: project)
                                    }
                                )
                                .id(tab.id)
                            }
                        }
                        .padding(TabSwitcherMetrics.gridInset)
                    }
                    .frame(
                        width: overlayWidth(columnCount: columnCount),
                        height: overlayHeight(
                            columnCount: columnCount,
                            availableHeight: geometry.size.height
                        )
                    )
                    .onAppear {
                        guard let tabID = controller.highlightedTabID else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(tabID, anchor: .center)
                        }
                    }
                    .onChange(of: controller.highlightedTabID) {
                        guard let tabID = controller.highlightedTabID else { return }
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(tabID, anchor: .center)
                        }
                    }
                }
                .background {
                    switcherBackground
                        .clipShape(RoundedRectangle(
                            cornerRadius: TabSwitcherMetrics.containerCornerRadius,
                            style: .continuous
                        ))
                        .shadow(
                            color: .black.opacity(colorScheme == .light ? 0.18 : 0.28),
                            radius: 24,
                            y: 10
                        )
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: TabSwitcherMetrics.containerCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        borderColor,
                        lineWidth: colorScheme == .light ? 0.5 : 1.5
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.t("Tab switcher"))
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    @ViewBuilder
    private var switcherBackground: some View {
        if colorScheme == .light {
            Color(red: 0.981, green: 0.979, blue: 0.985)
        } else {
            Color(nsColor: Theme.background)
        }
    }

    private var borderColor: Color {
        colorScheme == .light
            ? .black.opacity(0.28)
            : .primary.opacity(0.18)
    }

    private func columnsPerRow(availableWidth: CGFloat) -> Int {
        let outsideInsets: CGFloat = 44 + TabSwitcherMetrics.gridInset * 2
        let usableWidth = max(
            TabSwitcherMetrics.cardWidth,
            availableWidth - outsideInsets
        )
        let fittingCount = Int(usableWidth / TabSwitcherMetrics.cardWidth)
        return min(5, max(1, min(project.tabs.count, fittingCount)))
    }

    private func gridColumns(count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.fixed(TabSwitcherMetrics.cardWidth), spacing: 0),
            count: count
        )
    }

    private func overlayWidth(columnCount: Int) -> CGFloat {
        CGFloat(columnCount) * TabSwitcherMetrics.cardWidth
            + TabSwitcherMetrics.gridInset * 2
    }

    private func overlayHeight(
        columnCount: Int,
        availableHeight: CGFloat
    ) -> CGFloat {
        let rowCount = (project.tabs.count + columnCount - 1) / columnCount
        let contentHeight = CGFloat(rowCount) * TabSwitcherMetrics.cardHeight
            + TabSwitcherMetrics.gridInset * 2
        let minimumHeight = TabSwitcherMetrics.cardHeight
            + TabSwitcherMetrics.gridInset * 2
        return min(contentHeight, max(minimumHeight, availableHeight - 44))
    }
}

/// 单个标签卡片包含布局缩略图、内容图标、标题和未保存标记。
private struct TabSwitcherCard: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var tab: PaneTab
    let index: Int
    let isHighlighted: Bool
    let terminalPreviews: [UUID: String]
    let onHighlight: () -> Void
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: TabSwitcherMetrics.titleSpacing) {
            TabSwitcherThumbnail(
                tab: tab,
                terminalPreviews: terminalPreviews
            )
            .frame(
                width: TabSwitcherMetrics.previewWidth,
                height: TabSwitcherMetrics.previewHeight
            )
            .clipShape(RoundedRectangle(
                cornerRadius: TabSwitcherMetrics.previewCornerRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(
                    cornerRadius: TabSwitcherMetrics.previewCornerRadius,
                    style: .continuous
                )
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            }

            HStack(spacing: 8) {
                cardIcon
                    .frame(width: 16, height: 16)

                Text(tab.displayTitle ?? "Tab \(index + 1)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary.opacity(isHighlighted ? 1 : 0.82))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if tab.focusedContent?.isDirty == true {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, TabSwitcherMetrics.cardHorizontalInset)
        .padding(.top, TabSwitcherMetrics.cardHorizontalInset)
        .padding(.bottom, TabSwitcherMetrics.cardBottomInset)
        .frame(
            width: TabSwitcherMetrics.cardWidth,
            height: TabSwitcherMetrics.cardHeight,
            alignment: .topLeading
        )
        .background {
            if isHighlighted {
                RoundedRectangle(
                    cornerRadius: TabSwitcherMetrics.cardCornerRadius,
                    style: .continuous
                )
                .fill(highlightedBackground)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHighlighted)
        .overlay {
            TabSwitcherPointerSurface(
                onPointerEntered: onHighlight,
                onClick: onSelect
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tab \(index + 1), \(tab.displayTitle ?? "Untitled")")
        .accessibilityValue(isHighlighted ? "Selected on release" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityAction { onSelect() }
    }

    private var highlightedBackground: Color {
        colorScheme == .light
            ? Color(red: 0.838, green: 0.835, blue: 0.841)
            : Color.primary.opacity(0.20)
    }

    /// 与顶部标签栏共用内容图标。终端图标定时读取前台应用状态，
    /// 例如 Codex、Node 或构建工具；惰性终端会停留在通用终端图标。
    @ViewBuilder
    private var cardIcon: some View {
        if case .session(let session)? = tab.focusedContent {
            TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                TabContentIcon(
                    content: tab.focusedContent,
                    showsCommandSpinner: manager.isRightSidebarCommandRunning(
                        sessionID: session.id
                    ),
                    tint: iconTint
                )
            }
        } else {
            TabContentIcon(
                content: tab.focusedContent,
                tint: iconTint
            )
        }
    }

    private var iconTint: Color {
        isHighlighted ? .primary : .secondary
    }
}

/// 使用 AppKit TrackingArea 提供可靠的卡片 Hover 与点击。
private struct TabSwitcherPointerSurface: NSViewRepresentable {
    let onPointerEntered: () -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> TabSwitcherPointerNSView {
        let view = TabSwitcherPointerNSView()
        view.onPointerEntered = onPointerEntered
        view.onClick = onClick
        return view
    }

    func updateNSView(
        _ view: TabSwitcherPointerNSView,
        context: Context
    ) {
        view.onPointerEntered = onPointerEntered
        view.onClick = onClick
    }
}

/// 卡片级 AppKit 交互宿主。
@MainActor
private final class TabSwitcherPointerNSView: NSView {
    var onPointerEntered: (() -> Void)?
    var onClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEntered?()
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerEntered?()
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(localPoint) else { return }
        onClick?()
    }
}

/// 按真实递归分屏几何绘制标签缩略图，缩放状态下仅展示当前聚焦 Pane。
private struct TabSwitcherThumbnail: View {
    @ObservedObject var tab: PaneTab
    let terminalPreviews: [UUID: String]

    private let paneGap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            if tab.isZoomed, let pane = tab.focusedPane {
                TabSwitcherPanePreview(
                    content: pane.content,
                    terminalPreview: terminalPreviews[pane.content.id]
                )
            } else {
                let placements = tab.layout.geometry(
                    in: CGRect(origin: .zero, size: geometry.size), gap: paneGap
                ).panes
                ZStack(alignment: .topLeading) {
                    ForEach(placements) { placement in
                        TabSwitcherPanePreview(
                            content: placement.pane.content,
                            terminalPreview: terminalPreviews[
                                placement.pane.content.id
                            ]
                        )
                        .frame(
                            width: placement.frame.width,
                            height: placement.frame.height
                        )
                        .offset(
                            x: placement.frame.minX,
                            y: placement.frame.minY
                        )
                    }
                }
            }
        }
        .background(Color(nsColor: Theme.background))
    }
}

/// 根据 Pane 类型生成不依赖真实视图挂载的预览内容。
private struct TabSwitcherPanePreview: View {
    let content: PaneContent
    let terminalPreview: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch content {
            case .session(let session):
                terminalPreviewView(session)
            case .file(let file):
                filePreviewView(file)
            case .browser(let browser):
                browserPreviewView(browser)
            case .diff(let diff):
                diffPreviewView(diff)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
        .clipped()
    }

    @ViewBuilder
    private func terminalPreviewView(_ session: TerminalSession) -> some View {
        if let terminalPreview, !terminalPreview.isEmpty {
            Text(terminalPreview)
                .font(.system(size: 5.2, design: .monospaced))
                .foregroundStyle(Color(nsColor: previewForeground))
                .lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .bottomLeading
                )
                .padding(5)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Color(nsColor: Theme.accent))
                Text(session.title)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                Text(session.currentDirectoryPath)
                    .font(.system(size: 5.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func filePreviewView(_ file: FileTab) -> some View {
        switch file.content {
        case .text:
            Text(textExcerpt(
                file.text,
                aroundUTF16: file.editorState.selectionLocation
            ))
            .font(.system(size: 5.2, design: .monospaced))
            .foregroundStyle(Color(nsColor: previewForeground))
            .lineSpacing(0)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(5)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(5)
        case .unavailable(let reason):
            VStack(spacing: 4) {
                Image(systemName: "doc")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(reason)
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(6)
        }
    }

    private func diffPreviewView(_ diff: DiffTab) -> some View {
        HStack(spacing: 1) {
            Text(textExcerpt(diff.web.oldContent))
                .foregroundStyle(Color.red.opacity(0.76))
                .background(Color.red.opacity(0.07))
            Text(textExcerpt(diff.web.newContent))
                .foregroundStyle(Color.green.opacity(0.76))
                .background(Color.green.opacity(0.07))
        }
        .font(.system(size: 4.5, design: .monospaced))
        .lineSpacing(0)
        .fixedSize(horizontal: false, vertical: true)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(4)
    }

    /// 浏览器预览不重新渲染网页，使用 favicon、标题和地址避免切换器触发额外加载。
    private func browserPreviewView(_ browser: BrowserTab) -> some View {
        VStack(spacing: 5) {
            BrowserFaviconView(
                browser: browser,
                size: 18,
                fallbackSystemImage: browser.isLoading
                    ? "globe.americas.fill"
                    : "globe"
            )
            .font(.system(size: 17, weight: .light))
            .foregroundStyle(Color(nsColor: Theme.accent))
            Text(browser.title)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
            if !browser.urlString.isEmpty {
                Text(browser.urlString)
                    .font(.system(size: 5.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(6)
    }

    private var previewForeground: NSColor {
        Theme.terminal(dark: colorScheme == .dark).foreground
    }

    /// 先限制 UTF-16 采样范围再分行，避免大文件或 Diff 拖慢切换器。
    private func textExcerpt(
        _ text: String,
        aroundUTF16 location: Int? = nil
    ) -> String {
        let source = text as NSString
        guard source.length > 0 else { return "" }

        let center = min(max(0, location ?? 0), source.length)
        let prefixLength = location == nil ? 0 : 1_200
        let start = max(0, center - prefixLength)
        let length = min(7_000, source.length - start)
        var sample = source.substring(
            with: NSRange(location: start, length: length)
        )
        if start > 0, let newline = sample.firstIndex(of: "\n") {
            sample.removeSubrange(...newline)
        }

        return sample
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(26)
            .map { String($0.prefix(120)) }
            .joined(separator: "\n")
    }
}
