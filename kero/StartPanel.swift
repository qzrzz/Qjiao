//
//  StartPanel.swift
//  kero
//

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Project-local launchers edited directly inside one continuous list.
struct StartPanel: View {
    @ObservedObject var project: Project
    let runCommand: (ProjectLaunchCommand) -> Void
    let runAllCommands: () -> Void

    @State private var expandedCommandID: UUID?
    @State private var draggedCommandID: UUID?
    @State private var dropTargetCommandID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if project.launchCommands.isEmpty {
                emptyState
            } else {
                commandList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.circle")
                .font(SidebarTypography.secondary(.medium))
                .foregroundStyle(Color(nsColor: Theme.cursor))
            VStack(alignment: .leading, spacing: 1) {
                Text("Start")
                    .font(SidebarTypography.title())
                Text("Project launchers")
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: runAllCommands) {
                Image(systemName: "play.fill")
                    .font(SidebarTypography.title())
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 32)
                    .background(Color(nsColor: Theme.cursor))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(project.launchCommands.isEmpty)
            .help("Run all launchers in order")
            Button(action: addCommand) {
                Image(systemName: "plus")
                    // 与「全部运行」同级可点区域，避免 + 看起来像次要工具图标。
                    .font(SidebarTypography.title(.medium))
                    .frame(width: 34, height: 32)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Add Launcher")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var commandList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(project.launchCommands.enumerated()), id: \.element.id) { index, command in
                    VStack(spacing: 0) {
                        StartCommandRow(
                            command: command,
                            isExpanded: expandedCommandID == command.id,
                            isDropTarget: dropTargetCommandID == command.id,
                            run: { runCommand(command) },
                            toggleExpanded: { toggleExpanded(command.id) },
                            startDrag: {
                                draggedCommandID = command.id
                                return NSItemProvider(object: command.id.uuidString as NSString)
                            }
                        )
                        .onDrop(
                            of: [.plainText],
                            delegate: StartCommandDropDelegate(
                                targetID: command.id,
                                project: project,
                                draggedCommandID: $draggedCommandID,
                                dropTargetCommandID: $dropTargetCommandID
                            )
                        )

                        if expandedCommandID == command.id {
                            StartCommandInlineEditor(
                                command: binding(for: command.id),
                                delete: { delete(command.id) }
                            )
                        }

                        if index < project.launchCommands.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .animation(.easeInOut(duration: 0.15), value: expandedCommandID)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.circle")
                .font(SidebarTypography.emptyIcon())
                .foregroundStyle(.tertiary)
            Text("No project launchers")
                .font(SidebarTypography.body(.medium))
                .foregroundStyle(.secondary)
            Text("Add a terminal command, application, folder, or webpage.")
                .font(SidebarTypography.secondary())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button("Add Launcher", action: addCommand)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .font(SidebarTypography.body(.medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addCommand() {
        let command = ProjectLaunchCommand()
        project.addLaunchCommand(command)
        expandedCommandID = command.id
    }

    private func toggleExpanded(_ id: UUID) {
        expandedCommandID = expandedCommandID == id ? nil : id
    }

    private func delete(_ id: UUID) {
        guard let index = project.launchCommands.firstIndex(where: { $0.id == id }) else { return }
        if expandedCommandID == id { expandedCommandID = nil }
        project.removeLaunchCommands(at: IndexSet(integer: index))
    }

    private func binding(for id: UUID) -> Binding<ProjectLaunchCommand> {
        Binding {
            project.launchCommands.first(where: { $0.id == id }) ?? ProjectLaunchCommand(id: id)
        } set: { updated in
            project.updateLaunchCommand(updated)
        }
    }
}

struct StartCommandRow: View {
    let command: ProjectLaunchCommand
    let isExpanded: Bool
    let isDropTarget: Bool
    let run: () -> Void
    let toggleExpanded: () -> Void
    let startDrag: () -> NSItemProvider

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal")
                .font(SidebarTypography.micro())
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .onDrag(startDrag) {
                    StartCommandDragPreview(command: command)
                }

            StartCommandIcon(command: command)
                .frame(width: 14, height: 14)

            HStack(spacing: 4) {
                Text(command.displayTitle)
                    .font(SidebarTypography.secondary(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("•")
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.tertiary)
                Text(command.type.title)
                    .font(SidebarTypography.micro())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(commandTooltip)

            Button(action: run) {
                Image(systemName: "play.fill")
                    .font(SidebarTypography.micro(.semibold))
                    .foregroundStyle(Color(nsColor: Theme.cursor))
                    .frame(width: 18, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
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
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { isHovering = $0 }
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule()
                    .fill(Color(nsColor: Theme.cursor))
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
        }
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
            Divider()
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
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(Color.primary.opacity(0.025))
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
struct StartCommandDragPreview: View {
    let command: ProjectLaunchCommand

    var body: some View {
        HStack(spacing: 7) {
            StartCommandIcon(command: command)
                .frame(width: 16, height: 16)
            Text(command.displayTitle)
                .font(SidebarTypography.body(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 210, alignment: .leading)
        .background(Color(nsColor: Theme.sidebar))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

struct StartCommandDropDelegate: DropDelegate {
    let targetID: UUID
    let project: Project
    @Binding var draggedCommandID: UUID?
    @Binding var dropTargetCommandID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        draggedCommandID != nil && draggedCommandID != targetID
    }

    func dropEntered(info: DropInfo) {
        guard let draggedCommandID else { return }
        dropTargetCommandID = targetID
        project.moveLaunchCommand(id: draggedCommandID, before: targetID)
    }

    func dropExited(info: DropInfo) {
        if dropTargetCommandID == targetID { dropTargetCommandID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedCommandID = nil
        dropTargetCommandID = nil
        return true
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
