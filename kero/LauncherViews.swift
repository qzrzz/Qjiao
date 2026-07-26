//
//  LauncherViews.swift
//  kero
//

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Launcher 列表行，包含拖拽、运行与展开入口。
struct StartCommandRow: View {
    let command: ProjectLaunchCommand
    let isExpanded: Bool
    var isDragged: Bool = false
    let run: () -> Void
    let toggleExpanded: () -> Void
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false
    @State private var isHoveringHandle = false
    @State private var isHoveringRunBtn = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal")
                .font(SidebarTypography.micro())
                .foregroundStyle(isHoveringHandle ? .primary : .tertiary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .onHover { isHoveringHandle = $0 }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { gesture in
                            onDrag(gesture.location)
                        }
                        .onEnded { _ in
                            onDragEnded()
                        }
                )

            StartCommandIcon(command: command)
                .frame(width: 14, height: 14)

            Text(command.displayTitle)
                .font(SidebarTypography.secondary())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(commandTooltip)

            Button(action: run) {
                Image(systemName: "play.fill")
                    .font(SidebarTypography.micro(.semibold))
                    .foregroundStyle(isHoveringRunBtn ? Color.white : Color(nsColor: Theme.cursor))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHoveringRunBtn ? Color(nsColor: Theme.cursor) : (isHovering ? Color.primary.opacity(0.08) : Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringRunBtn = $0 }
            .help("Run \(command.displayTitle)")

            Button(action: toggleExpanded) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(SidebarTypography.caption(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide Options" : "Show Options")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .opacity(isDragged ? 0.4 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                // 展开卡片已有同色背景，避免行头 hover 再叠一层而局部变深。
                .fill(isHovering && !isDragged && !isExpanded ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { isHovering = $0 }
        .onChange(of: isDragged) { _, newValue in
            if !newValue {
                isHovering = false
                isHoveringHandle = false
                isHoveringRunBtn = false
            }
        }
        .animation(.snappy(duration: 0.2), value: isDragged)
    }

    private var commandTooltip: String {
        switch command.type {
        case .application:
            let arguments = command.content.isEmpty ? "No arguments" : command.content
            return "\(command.target)\n\(arguments)"
        default:
            return command.content
        }
    }
}

struct StartCommandInlineEditor: View {
    @Binding var command: ProjectLaunchCommand
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Type", selection: $command.type) {
                ForEach(ProjectLaunchCommandType.allCases) { type in
                    Label(type.title, systemImage: type.systemImage).tag(type)
                }
            }

            TextField(
                command.type == .terminal ? "Tab title" : "Name",
                text: $command.title,
                prompt: Text(command.type == .terminal ? "Optional tab title" : "Optional name")
            )
            typeEditor

            HStack {
                Spacer()
                Button("Delete", role: .destructive, action: delete)
                    .controlSize(.small)
            }
        }
        .font(SidebarTypography.secondary())
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var typeEditor: some View {
        switch command.type {
        case .terminal:
            TextField("Command", text: $command.content, axis: .vertical)
                .lineLimit(2...4)
            Picker("Split", selection: $command.split) {
                ForEach(ProjectLaunchSplit.allCases) { split in
                    Text(split.title).tag(split)
                }
            }
            Text("Runs in a new terminal at the project directory.")
                .foregroundStyle(.secondary)

        case .application:
            HStack {
                TextField("Application", text: $command.target)
                Button("Choose…", action: chooseApplication)
                    .controlSize(.small)
            }
            HStack(spacing: 5) {
                Text("Templates")
                    .foregroundStyle(.secondary)
                Button("VS Code") { command.target = "/Applications/Visual Studio Code.app" }
                Button("WebStorm") { command.target = "/Applications/WebStorm.app" }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            TextField("Arguments", text: $command.content, axis: .vertical)
                .lineLimit(1...3)
            Text("Argument text is passed to the application as one argument.")
                .foregroundStyle(.secondary)

        case .finderFolder:
            HStack {
                TextField("Folder", text: $command.content)
                Button("Choose…", action: chooseFolder)
                    .controlSize(.small)
            }
            Text("Opens this folder in Finder.")
                .foregroundStyle(.secondary)

        case .web:
            TextField("URL", text: $command.content)
            Text("A scheme is optional; https:// is used when omitted.")
                .foregroundStyle(.secondary)
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        command.target = url.path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        command.content = url.path
    }

}

/// An opaque, compact drag image avoids the translucent snapshot AppKit makes
/// from an entire sidebar row (which looks especially muddy over materials).
struct LauncherFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LauncherFrameReader: View {
    let commandID: UUID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: LauncherFramePreferenceKey.self,
                value: [commandID: proxy.frame(in: .global)]
            )
        }
    }
}

struct StartCommandIcon: View {
    let command: ProjectLaunchCommand

    var body: some View {
        switch command.type {
        case .terminal:
            Image(systemName: command.type.systemImage)
                .foregroundStyle(Color(nsColor: Theme.cursor))

        case .application:
            if !command.target.isEmpty {
                Image(nsImage: NSWorkspace.shared.icon(forFile: command.target))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: command.type.systemImage)
                    .foregroundStyle(.secondary)
            }

        case .finderFolder:
            Image(systemName: command.type.systemImage)
                .foregroundStyle(Color(nsColor: .systemBlue))

        case .web:
            if let url = faviconURL(for: command.content) {
                CachedFavicon(url: url)
            } else {
                Image(systemName: command.type.systemImage)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func faviconURL(for text: String) -> URL? {
        let rawURL = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: rawURL), let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }
}

/// Reuses webpage favicons across row redraws and application launches. The
/// disk layer intentionally shares the project's existing config root so dev
/// and release builds keep separate caches along with their settings.
private struct CachedFavicon: View {
    let url: URL
    @StateObject private var loader: FaviconLoader

    init(url: URL) {
        self.url = url
        _loader = StateObject(wrappedValue: FaviconLoader(url: url))
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private final class FaviconLoader: ObservableObject {
    private static let memoryCache = NSCache<NSURL, NSImage>()

    @Published private(set) var image: NSImage?

    init(url: URL) {
        if let cached = Self.memoryCache.object(forKey: url as NSURL) {
            image = cached
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let data: Data?
            if let cached = Self.loadFromDisk(url: url) {
                data = cached
            } else {
                data = try? await URLSession.shared.data(from: url).0
                if let data { Self.saveToDisk(data, url: url) }
            }
            guard let data, let image = NSImage(data: data) else { return }
            Self.memoryCache.setObject(image, forKey: url as NSURL)
            self.image = image
        }
    }

    private static func loadFromDisk(url: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    private static func saveToDisk(_ data: Data, url: URL) {
        let directory = AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? data.write(to: fileURL(for: url), options: .atomic)
    }

    private static func fileURL(for url: URL) -> URL {
        let key = url.absoluteString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        let directory = AppSettings.configURL.deletingLastPathComponent()
            .appendingPathComponent("favicons", isDirectory: true)
        return directory.appendingPathComponent(String(key, radix: 16) + ".ico")
    }
}

// MARK: - LauncherItemWrapper

/// 单个 Launcher 条目容器，供独立 Start 面板与 Project 侧边栏共用。
struct LauncherItemWrapper: View {
    let command: ProjectLaunchCommand
    @Binding var commandBinding: ProjectLaunchCommand
    let isExpanded: Bool
    let isDragged: Bool
    let run: () -> Void
    let toggleExpanded: () -> Void
    let delete: () -> Void
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isExpanded {
                // 背景完整覆盖行头与编辑区；内容不添加条件 padding，确保行头坐标不变。
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                StartCommandRow(
                    command: command,
                    isExpanded: isExpanded,
                    isDragged: isDragged,
                    run: run,
                    toggleExpanded: toggleExpanded,
                    onDrag: onDrag,
                    onDragEnded: onDragEnded
                )

                if isExpanded {
                    StartCommandInlineEditor(
                        command: $commandBinding,
                        delete: delete
                    )
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
    }
}
