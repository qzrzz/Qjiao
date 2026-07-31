//
//  PaneLayoutView.swift
//  kero
//

import AppKit
import SwiftUI

/// Tiles a tab's recursive split tree. Every divider belongs to the pane
/// rectangle that was split, so nested horizontal and vertical layouts can be
/// combined freely. Only the selected tab's layout is ever mounted.
struct PaneLayoutView: View {
    @ObservedObject var tab: PaneTab
    /// Splits the focused pane on the given edge — from a pane's context menu.
    var onSplit: (PaneDropEdge) -> Void = { _ in }
    /// Closes the pane that owns a context menu action.
    var onClosePane: ((PaneContent) -> Void)?
    /// 由终端、编辑器和网页链接右键菜单触发的浏览器创建动作。
    var onNewBrowserTab: (String?) -> Void = { _ in }
    var onNewBrowserPane: (String?) -> Void = { _ in }

    /// Gap between tiles, which doubles as the divider hit area. The same
    /// value insets the whole grid from the parent, so the spacing around the
    /// panes matches the spacing between them.
    private let gap: CGFloat = 10
    /// Smallest share any single tile may be shrunk to.
    private let minFraction: CGFloat = 0.1
    /// Bounding box the drag thumbnail is scaled to fit within, preserving the
    /// pane's aspect ratio so a tall pane yields a tall thumbnail (rather than
    /// cropping to its empty middle).
    private let thumbnailMaxSize = CGSize(width: 220, height: 160)

    @State private var drag: DragState?
    /// While a divider drag is in flight the new split fraction lives here —
    /// local @State that re-renders only this grid — instead of in `tab.layout`,
    /// whose @Published change would re-render the whole window every frame.
    /// Committed back to the model once, on release.
    @State private var dragLayout: PaneNode?

    /// Global-space frame of every pane, so a pane-move drag can tell which
    /// pane the cursor is over.
    @State private var paneFrames: [UUID: CGRect] = [:]
    /// In-flight pane-move drag: which pane is being carried, where the pointer
    /// is, and which pane it is hovering over (the drop target).
    @State private var paneDrag: PaneMove?
    /// A snapshot of the carried pane, shown as a thumbnail under the cursor.
    @State private var dragThumbnail: NSImage?

    private struct DragState {
        var splitID: UUID
        var fraction: CGFloat
    }

    private struct PaneMove {
        let sourceID: UUID
        var location: CGPoint
        var targetID: UUID?
        var edge: PaneDropEdge?
    }

    var body: some View {
        Group {
            if tab.isZoomed, tab.hasMultiplePanes, let pane = tab.focusedPane {
                // Zoom: the focused pane alone, filling the tab. The grid — and
                // with it the dividers and the other panes — unmounts, exactly
                // like an unselected tab's layout; the focus ring stays as the
                // hint that a split layout is hiding underneath.
                PaneView(
                    tab: tab,
                    pane: pane,
                    showFocusRing: true,
                    allowsMove: false,
                    isMoveSource: false,
                    dropEdge: nil,
                    onMove: { _ in },
                    onMoveEnded: {},
                    onSplit: onSplit,
                    onClosePane: onClosePane,
                    onNewBrowserTab: onNewBrowserTab,
                    onNewBrowserPane: onNewBrowserPane
                )
            } else {
                grid
            }
        }
        // Inset the whole grid from the parent by the same gap used between
        // tiles, so a split tab has even breathing room on every side. A
        // single-pane tab stays full-bleed, exactly as before splits existed.
        .padding(tab.hasMultiplePanes ? gap : 0)
        .onPreferenceChange(PaneFramePreferenceKey.self) { paneFrames = $0 }
        // A divider or pane-move drag can't deliver its ending callback once
        // toggling zoom unmounts its view — drop any in-flight drag state so a
        // stale snapshot never sticks around.
        .onChange(of: tab.isZoomed) {
            drag = nil
            dragLayout = nil
            paneDrag = nil
            dragThumbnail = nil
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let layout = dragLayout ?? tab.layout
            let geometry = layout.geometry(
                in: CGRect(origin: .zero, size: geo.size), gap: gap
            )

            ZStack(alignment: .topLeading) {
                ForEach(geometry.panes) { placement in
                    PaneView(
                        tab: tab,
                        pane: placement.pane,
                        showFocusRing: tab.hasMultiplePanes,
                        allowsMove: true,
                        isMoveSource: paneDrag?.sourceID == placement.pane.id,
                        dropEdge: paneDrag?.targetID == placement.pane.id
                            ? paneDrag?.edge : nil,
                        onMove: {
                            updateDropTarget(
                                source: placement.pane.id, location: $0
                            )
                        },
                        onMoveEnded: { commitPaneMove() },
                        onSplit: onSplit,
                        onClosePane: tab.hasMultiplePanes ? onClosePane : nil,
                        onNewBrowserTab: onNewBrowserTab,
                        onNewBrowserPane: onNewBrowserPane
                    )
                    .frame(
                        width: placement.frame.width,
                        height: placement.frame.height
                    )
                    .offset(x: placement.frame.minX, y: placement.frame.minY)
                }

                ForEach(geometry.dividers) { divider in
                    ResizableDivider(axis: divider.axis) { translation in
                        resizeSplit(
                            divider.id,
                            translation: translation,
                            available: divider.availableLength
                        )
                    } onEnded: {
                        commitDrag()
                    }
                    .frame(
                        width: divider.frame.width,
                        height: divider.frame.height
                    )
                    .offset(x: divider.frame.minX, y: divider.frame.minY)
                }

                // The carried pane's thumbnail, trailing the cursor. Positioned
                // in this grid's local space by subtracting its global origin
                // from the (global) pointer location.
                if let paneDrag {
                    let origin = geo.frame(in: .global).origin
                    let size = thumbnailFrame(for: paneDrag.sourceID)
                    dragThumbnailView(for: paneDrag.sourceID, size: size)
                        // Centered on the pointer, both axes.
                        .offset(
                            x: paneDrag.location.x - origin.x - size.width / 2,
                            y: paneDrag.location.y - origin.y - size.height / 2
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Resizing

    private func resizeSplit(
        _ splitID: UUID, translation: CGFloat, available: CGFloat
    ) {
        guard available > 0 else { return }
        let baseline: CGFloat
        if let drag, drag.splitID == splitID {
            baseline = drag.fraction
        } else {
            guard let fraction = tab.layout.fraction(of: splitID) else { return }
            baseline = fraction
            drag = DragState(splitID: splitID, fraction: fraction)
        }
        let fraction = min(
            max(baseline + translation / available, minFraction),
            1 - minFraction
        )
        dragLayout = tab.layout.settingFraction(of: splitID, to: fraction)
    }

    /// Writes the in-flight split tree back to the model once the drag ends —
    /// a single @Published update instead of one per frame.
    private func commitDrag() {
        if let dragLayout {
            tab.layout = dragLayout
        }
        dragLayout = nil
        drag = nil
    }

    // MARK: - Moving panes

    /// Tracks a pane-move drag: `location` is the pointer in global space. The
    /// drop target is whichever *other* pane's frame contains it (none over a
    /// gap), and the edge is which quadrant of that pane the pointer is in.
    /// Local @State, so only this grid re-renders per frame.
    private func updateDropTarget(source: UUID, location: CGPoint) {
        // First frame of the drag: grab the thumbnail once.
        if paneDrag == nil {
            dragThumbnail = thumbnail(for: source)
        }
        if let (targetID, frame) = paneFrames.first(where: { $0.key != source && $0.value.contains(location) }) {
            paneDrag = PaneMove(sourceID: source, location: location, targetID: targetID, edge: dropEdge(at: location, in: frame))
            NSCursor.closedHand.set()
        } else {
            paneDrag = PaneMove(sourceID: source, location: location, targetID: nil, edge: nil)
            NSCursor.operationNotAllowed.set()
        }
    }

    /// Commits a pane-move on release: splits the target on the chosen edge and
    /// drops the carried pane there.
    private func commitPaneMove() {
        if let paneDrag, let target = paneDrag.targetID, let edge = paneDrag.edge {
            tab.movePane(paneDrag.sourceID, edge, of: target)
        }
        paneDrag = nil
        dragThumbnail = nil
        // Clear the drag cursor; the next hover/move asserts the right one.
        NSCursor.arrow.set()
    }

    /// A snapshot of the carried pane's terminal (falls back to a labeled card
    /// for files), shown centered under the cursor while dragging. `size` is
    /// aspect-matched to the pane, so the whole pane scales down instead of
    /// being cropped.
    @ViewBuilder
    private func dragThumbnailView(for sourceID: UUID, size: CGSize) -> some View {
        let content = tab.allPanes.first { $0.id == sourceID }?.content
        Group {
            if let dragThumbnail {
                Image(nsImage: dragThumbnail)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let content {
                HStack(spacing: 6) {
                    if let fileName = content.materialFileName {
                        MaterialFileIconView(
                            fileName: fileName,
                            isDirectory: false,
                            size: 14
                        )
                    } else {
                        Image(systemName: content.systemImage)
                    }
                    Text(content.title).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(width: size.width, height: size.height, alignment: .center)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: Theme.background)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: Theme.cursor), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .opacity(0.9)
    }

    /// The thumbnail's on-screen size: the source pane's aspect ratio scaled to
    /// fit within `thumbnailMaxSize`.
    private func thumbnailFrame(for sourceID: UUID) -> CGSize {
        guard let frame = paneFrames[sourceID], frame.width > 0, frame.height > 0 else {
            return thumbnailMaxSize
        }
        let scale = min(thumbnailMaxSize.width / frame.width, thumbnailMaxSize.height / frame.height)
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    private func thumbnail(for sourceID: UUID) -> NSImage? {
        switch tab.allPanes.first(where: { $0.id == sourceID })?.content {
        case .session(let session):
            return session.terminalView.paneSnapshot()
        case .file(let file): return file.editorView?.paneSnapshot()
        case .browser(let browser): return browser.webView.paneSnapshot()
        default: return nil
        }
    }

    /// Which edge of `frame` the pointer is nearest — the target is cut into
    /// four triangular quadrants by its diagonals, the standard drop-zone
    /// scheme (VS Code, Ghostty).
    private func dropEdge(at location: CGPoint, in frame: CGRect) -> PaneDropEdge {
        let dx = (location.x - frame.midX) / max(frame.width, 1)
        let dy = (location.y - frame.midY) / max(frame.height, 1)
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        } else {
            return dy < 0 ? .top : .bottom
        }
    }

}

/// Invisible drag strip in the gap between two tiles. Dragging shifts weight
/// between the neighbors; the cursor hints at the resize direction.
private struct ResizableDivider: View {
    let axis: PaneSplitAxis
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            // System pointer resolution rather than pushing onto the cursor
            // stack by hand — see SidebarResizeHandle for why the manual push
            // never showed up next to a file editor.
            .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
            // Global coordinate space is essential: the divider itself shifts
            // as the panes resize, so a local-space translation would be
            // measured against a moving reference frame and oscillate (the
            // divider fights the cursor). Global translation tracks the actual
            // pointer movement regardless. Matches SidebarResizeHandle.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onChanged(
                            axis == .horizontal
                                ? value.translation.width
                                : value.translation.height
                        )
                    }
                    .onEnded { _ in onEnded() }
            )
    }
}

/// One tile: hosts its content and, when the tab holds more than one pane,
/// draws a focus ring (accent for the focused pane, faint otherwise), a thin
/// top strip you can grab to move the pane onto another, and a highlight while
/// it's the drop target.
private struct PaneView: View {
    @ObservedObject var tab: PaneTab
    let pane: Pane
    let showFocusRing: Bool
    /// Whether the top grab strip is offered at all — false while zoomed,
    /// where there is no other pane on screen to drop onto.
    let allowsMove: Bool
    /// The pane currently being carried by a move drag (dimmed).
    let isMoveSource: Bool
    /// When this pane is the drop target, the edge the carried pane will land
    /// on — drives the half-pane preview. Nil when it isn't the target.
    let dropEdge: PaneDropEdge?
    /// Reports the pointer (global space) as the top strip is dragged.
    let onMove: (CGPoint) -> Void
    let onMoveEnded: () -> Void
    /// Splits the focused pane on the given edge (from the content's context
    /// menu).
    let onSplit: (PaneDropEdge) -> Void
    /// Closes this pane from the terminal context menu when the tab is split.
    let onClosePane: ((PaneContent) -> Void)?
    let onNewBrowserTab: (String?) -> Void
    let onNewBrowserPane: (String?) -> Void

    /// Height of the grab strip at the pane's top.
    private let handleHeight: CGFloat = 8

    @State private var isHandleHovered = false
    @State private var isDragging = false

    private var isFocused: Bool { tab.focusedPaneID == pane.id }

    /// Marks this pane focused — invoked when its content takes first-responder
    /// status (a click). Idempotent when already focused.
    private func focus() {
        if tab.focusedPaneID != pane.id {
            tab.focusedPaneID = pane.id
        }
    }

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Single-pane tabs render exactly as before splits existed — no ring,
        // no handle — so nothing about the common case changes.
        if showFocusRing {
            VStack(spacing: 0) {
                if settings.showPaneHeaders {
                    PaneHeaderView(
                        tab: tab,
                        pane: pane,
                        isFocused: isFocused,
                        allowsMove: allowsMove,
                        onMove: onMove,
                        onMoveEnded: onMoveEnded,
                        onSplit: splitFromMenu,
                        onClosePane: onClosePane
                    )
                }
                content
            }
            .overlay { focusRing }
            .overlay(alignment: .top) {
                if allowsMove && !settings.showPaneHeaders { moveHandle }
            }
            .overlay { dropHighlight }
            .opacity(isMoveSource ? 0.55 : 1)
            .background(frameReporter)
        } else {
            content
        }
    }

    /// Focuses this pane, then splits it — the context menu acts on the pane it
    /// was opened over, not whatever held focus before.
    private func splitFromMenu(_ edge: PaneDropEdge) {
        focus()
        onSplit(edge)
    }

    private func newBrowserTabFromMenu(initialURL: String?) {
        focus()
        onNewBrowserTab(initialURL)
    }

    private func newBrowserPaneFromMenu(initialURL: String?) {
        focus()
        onNewBrowserPane(initialURL)
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .session(let session):
            VStack(spacing: 0) {
                TerminalHostView(
                    session: session,
                    isFocused: isFocused,
                    hasMultiplePanes: tab.hasMultiplePanes,
                    onFocused: focus,
                    onSplit: splitFromMenu,
                    onNewBrowserTab: newBrowserTabFromMenu,
                    onNewBrowserPane: newBrowserPaneFromMenu,
                    onClose: onClosePane.map { close in
                        { focus(); close(pane.content) }
                    }
                )
                .overlay(alignment: .topTrailing) {
                    TerminalFindOverlay(find: session.find)
                }

                TerminalHelpBar(session: session)
            }
        case .file(let file):
            FileViewerView(
                file: file,
                isFocused: isFocused,
                onFocused: focus,
                onSplit: splitFromMenu,
                onNewBrowserTab: newBrowserTabFromMenu,
                onNewBrowserPane: newBrowserPaneFromMenu
            )
                .background(Color(nsColor: Theme.background.withAlphaComponent(AppSettings.shared.terminalBackgroundOpacity)))
                .clipShape(RoundedRectangle(cornerRadius: tab.hasMultiplePanes ? 6 : 0, style: .continuous))
        case .browser(let browser):
            BrowserView(
                browser: browser,
                isFocused: isFocused,
                onFocused: focus,
                onNewBrowserTab: newBrowserTabFromMenu,
                onNewBrowserPane: newBrowserPaneFromMenu
            )
            .background(Color(nsColor: Theme.background))
            .clipShape(RoundedRectangle(
                cornerRadius: tab.hasMultiplePanes ? 6 : 0,
                style: .continuous
            ))
        case .diff:
            // Rendered by the always-mounted diff stack behind the layout; stay
            // transparent and non-interactive so clicks and scrolls reach it.
            Color.clear.allowsHitTesting(false)
        }
    }

    private var focusRing: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(
                isFocused
                    ? Color(nsColor: Theme.cursor).opacity(0.85)
                    : Color.primary.opacity(0.06),
                lineWidth: isFocused ? 1.5 : 1
            )
    }

    /// Thin strip pinned to the pane's top edge — an absolutely-positioned grab
    /// handle over the content — that you drag to move this pane onto another.
    /// A grab bar fades in on hover so the zone is easy to find; the strip sits
    /// in the terminal's own top padding, so it doesn't cover text. Global
    /// coordinate space so the reported location survives the layout shifting.
    private var moveHandle: some View {
        Color.clear
            .frame(height: handleHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(isHandleHovered ? 0.9 : 0)
            }
            .contentShape(Rectangle())
            // onContinuousHover (not onHover): re-assert the open hand on every
            // move so it wins against the terminal re-setting its own cursor.
            // On exit, reset explicitly — moving *up* off the handle lands in the
            // gap, which has no cursor management to revert it otherwise. Both
            // guarded by !isDragging so they never fight the drag cursor.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHandleHovered = true
                    if !isDragging { NSCursor.openHand.set() }
                case .ended:
                    isHandleHovered = false
                    if !isDragging { NSCursor.arrow.set() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        isDragging = true
                        onMove(value.location)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onMoveEnded()
                    }
            )
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if let dropEdge {
            GeometryReader { geo in
                let rect = highlightRect(for: dropEdge, in: geo.size)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: Theme.cursor).opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: Theme.cursor), lineWidth: 2)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
        }
    }

    /// The half of the pane that previews where the dragged pane will land.
    private func highlightRect(for edge: PaneDropEdge, in size: CGSize) -> CGRect {
        switch edge {
        case .left:   return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:  return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:    return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }

    private var frameReporter: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PaneFramePreferenceKey.self,
                value: [pane.id: proxy.frame(in: .global)]
            )
        }
    }
}

/// Mounts a session's find bar only while it is open, so a closed bar never
/// sits over the terminal swallowing clicks. Separate from `PaneView` so that
/// opening and closing it re-renders nothing but the overlay.
private struct TerminalFindOverlay: View {
    @ObservedObject var find: TerminalFind

    var body: some View {
        if find.isPresented {
            TerminalFindBar(find: find)
        }
    }
}

/// Collects each pane's global-space frame so a move drag can hit-test the
/// cursor against them.
private struct PaneFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 分屏 Pane 顶部的实时标题栏与控制按钮。
private struct PaneHeaderView: View {
    @ObservedObject var tab: PaneTab
    @ObservedObject private var themeChanges = Theme.changes
    let pane: Pane
    let isFocused: Bool
    let allowsMove: Bool
    let onMove: (CGPoint) -> Void
    let onMoveEnded: () -> Void
    let onSplit: (PaneDropEdge) -> Void
    let onClosePane: ((PaneContent) -> Void)?

    @State private var isDragging = false
    @State private var isHovered = false

    private var title: String {
        switch pane.content {
        case .session(let session):
            let dirName = (session.currentDirectoryPath as NSString).lastPathComponent
            return session.title.isEmpty ? dirName : session.title
        case .file(let file):
            return file.name
        case .browser(let item):
            return item.title.isEmpty ? item.urlString : item.title
        case .diff(let item):
            return item.title
        }
    }

    private var icon: String {
        pane.content.systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(isFocused ? Theme.primaryColor : .secondary)

            Text(title)
                .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                .foregroundColor(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if isHovered || isFocused {
                HStack(spacing: 4) {
                    HeaderIconButton(
                        systemImage: "square.split.1x2",
                        help: L10n.t("Split Right (⌘D)")
                    ) {
                        onSplit(.right)
                    }

                    HeaderIconButton(
                        systemImage: "square.split.2x1",
                        help: L10n.t("Split Down (⇧⌘D)")
                    ) {
                        onSplit(.bottom)
                    }

                    if let onClosePane {
                        HeaderIconButton(
                            systemImage: "xmark",
                            help: L10n.t("Close Pane")
                        ) {
                            onClosePane(pane.content)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            isFocused
                ? Color(nsColor: Theme.background).opacity(0.9)
                : Color(nsColor: Theme.background).opacity(0.6)
        )
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if allowsMove {
                        isDragging = true
                        onMove(value.location)
                    }
                }
                .onEnded { _ in
                    if isDragging {
                        isDragging = false
                        onMoveEnded()
                    }
                }
        )
    }
}

private extension NSView {
    /// A bitmap of the view's current rendering, used as the drag thumbnail.
    func paneSnapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
