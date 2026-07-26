//
//  ProjectIconPicker.swift
//  kero
//
//  项目自定义图标：列表展示 + SF Symbol / Emoji 选择面板。
//

import AppKit
import SwiftUI

// MARK: - List icon

/// 项目行的图标：没有自定义图标时沿用文件夹样式。
struct ProjectIconView: View {
    let icon: ProjectIcon?
    let isSelected: Bool

    var body: some View {
        switch icon {
        case .sfSymbol(let name):
            Image(systemName: name)
                // 与 Emoji 使用相同字号和图标区域，避免项目列表中两类图标大小不一致。
                .font(SidebarTypography.listIcon())
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
        case .emoji(let emoji):
            Text(emoji)
                // 彩色 Emoji 的实际字形通常比标称字号更宽、更高；保留
                // 额外边距并禁止压缩，避免肤色、组合 Emoji 等被裁掉。
                .font(SidebarTypography.listEmoji())
                .lineLimit(1)
                .fixedSize()
                .frame(width: 24, height: 24)
        case nil:
            Image(systemName: "folder")
                // 默认文件夹图标也保持与自定义 Emoji 相同的尺寸。
                .font(SidebarTypography.listIcon())
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
        }
    }

    private var iconColor: Color {
        isSelected ? Color(nsColor: Theme.cursor) : .secondary
    }
}

// MARK: - SF Symbol catalog

/// 打包的 SF Symbol 名称目录，供图标选择器离线完整浏览。
enum SFSymbolCatalog {
    /// 按名称排序的完整目录；首次访问时从 Bundle 解码一次。
    static let allNames: [String] = {
        guard let url = Bundle.main.url(
            forResource: "SFSymbolCatalog", withExtension: "json"
        ), let data = try? Data(contentsOf: url) else {
            return []
        }
        // 目录值是 SF 版本号，选择器只用 key；JSONSerialization 比
        // decode([String:String]) 略轻，且避免无用字符串分配。
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object.keys.sorted()
    }()

    /// 适合作为项目图标的常用推荐（网格顶部快捷区）。
    static let suggestedNames: [String] = [
        "folder",
        "folder.fill",
        "terminal",
        "chevron.left.forwardslash.chevron.right",
        "swift",
        "hammer",
        "globe",
        "app",
        "shippingbox",
        "server.rack",
        "cpu",
        "memorychip",
        "doc.text",
        "book",
        "star",
        "heart",
        "bolt",
        "leaf",
        "flame",
        "puzzlepiece",
        "cube",
        "archivebox",
        "tray.full",
        "paintbrush",
        "wand.and.stars",
        "gearshape",
        "command",
        "keyboard",
        "network",
        "antenna.radiowaves.left.and.right",
        "externaldrive",
        "internaldrive",
        "cloud",
        "lock",
        "key",
        "person.2",
        "building.2",
        "map",
        "flag",
        "tag",
        "bell",
        "bubble.left.and.bubble.right",
        "chart.bar",
        "chart.line.uptrend.xyaxis",
        "photo",
        "music.note",
        "gamecontroller",
        "car",
        "airplane",
        "bicycle",
    ]

    /// 按查询过滤目录；空查询返回完整列表。多词用空格分隔，要求每个词都命中。
    static func filter(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allNames }
        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        guard !tokens.isEmpty else { return allNames }
        return allNames.filter { name in
            let lower = name.lowercased()
            return tokens.allSatisfy { lower.contains($0) }
        }
    }
}

// MARK: - Picker sheet

/// 为项目选择 SF Symbol 或 Emoji 的面板。
struct ProjectIconPicker: View {
    private enum Source: String, CaseIterable, Identifiable {
        case sfSymbols = "SF Symbols"
        case emoji = "Emoji"

        var id: Self { self }
    }

    @ObservedObject var project: Project
    @Environment(\.dismiss) private var dismiss

    @State private var source: Source
    @State private var symbolName: String
    @State private var symbolSearch: String
    /// 防抖后的检索串，避免 9k+ 目录在每次按键时全量过滤。
    @State private var debouncedSearch: String
    @State private var emoji: String
    @FocusState private var emojiFieldFocused: Bool
    @FocusState private var symbolSearchFocused: Bool

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 6
    )

    init(project: Project) {
        self.project = project
        // 打开时带入当前图标，方便在原基础上改名或换一类。
        switch project.icon {
        case .sfSymbol(let name):
            _source = State(initialValue: .sfSymbols)
            _symbolName = State(initialValue: name)
            _emoji = State(initialValue: "")
        case .emoji(let value):
            _source = State(initialValue: .emoji)
            _symbolName = State(initialValue: "folder")
            _emoji = State(initialValue: value)
        case nil:
            _source = State(initialValue: .sfSymbols)
            _symbolName = State(initialValue: "folder")
            _emoji = State(initialValue: "")
        }
        _symbolSearch = State(initialValue: "")
        _debouncedSearch = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Picker("Icon type", selection: $source) {
                ForEach(Source.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if source == .sfSymbols {
                sfSymbolPicker
            } else {
                emojiPicker
            }

            footer
        }
        .padding(20)
        .frame(width: 400)
        .onChange(of: symbolSearch) { _, newValue in
            // 短延迟后再写 debouncedSearch，输入过程中少做过滤。
            let snapshot = newValue
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                guard symbolSearch == snapshot else { return }
                debouncedSearch = snapshot
            }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            currentIconPreview
            VStack(alignment: .leading, spacing: 2) {
                Text("Project Icon")
                    .font(SidebarTypography.title())
                Text(project.name)
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if project.icon != nil {
                Button("Clear") {
                    project.icon = nil
                    dismiss()
                }
            }
        }
    }

    /// 当前项目图标（或默认 folder）的大预览。
    private var currentIconPreview: some View {
        Group {
            switch project.icon {
            case .sfSymbol(let name):
                Image(systemName: name)
                    .font(SidebarTypography.pickerIcon())
            case .emoji(let value):
                Text(value)
                    .font(SidebarTypography.pickerEmojiPreview())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            case nil:
                Image(systemName: "folder")
                    .font(SidebarTypography.pickerIcon())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: SF Symbols

    private var sfSymbolPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbolName.isEmpty ? "questionmark" : symbolName)
                    .font(SidebarTypography.pickerIcon())
                    .frame(width: 28)
                    .foregroundStyle(symbolName.isEmpty ? .tertiary : .primary)
                TextField("SF Symbol name", text: $symbolName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { useSymbolName() }
                Button("Use") { useSymbolName() }
                    .disabled(!canUseSymbolName)
                    .keyboardShortcut(.defaultAction)
            }

            TextField("Search all SF Symbols", text: $symbolSearch)
                .textFieldStyle(.roundedBorder)
                .focused($symbolSearchFocused)

            HStack {
                Text(resultCountLabel)
                    .font(SidebarTypography.caption())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // 无检索时把推荐区放进同一滚动容器，避免 sheet 被撑得过高。
                    if isSearchEmpty {
                        sectionLabel("Suggested")
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(SFSymbolCatalog.suggestedNames, id: \.self) { symbol in
                                symbolCell(symbol)
                            }
                        }
                        sectionLabel("All Symbols")
                    }

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(filteredSymbols, id: \.self) { symbol in
                            symbolCell(symbol)
                        }
                    }
                }
            }
            .frame(height: 300)
        }
    }

    private var isSearchEmpty: Bool {
        debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(SidebarTypography.caption())
            .foregroundStyle(.secondary)
    }

    private var filteredSymbols: [String] {
        SFSymbolCatalog.filter(debouncedSearch)
    }

    private var resultCountLabel: String {
        let total = SFSymbolCatalog.allNames.count
        let shown = filteredSymbols.count
        let query = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "\(total) SF Symbols"
        }
        return "\(shown) of \(total) SF Symbols"
    }

    private var canUseSymbolName: Bool {
        !symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func symbolCell(_ symbol: String) -> some View {
        let isCurrent: Bool = {
            if case .sfSymbol(let name) = project.icon {
                return name == symbol
            }
            return false
        }()
        return Button {
            select(.sfSymbol(symbol))
        } label: {
            Image(systemName: symbol)
                .font(SidebarTypography.pickerGridIcon())
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(symbol)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isCurrent
                        ? Color(nsColor: Theme.cursor).opacity(0.18)
                        : Color.primary.opacity(0.05)
                )
        )
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: Theme.cursor).opacity(0.55), lineWidth: 1)
            }
        }
    }

    private func useSymbolName() {
        let name = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        select(.sfSymbol(name))
    }

    // MARK: Emoji

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use the macOS Character Viewer to browse and search every Emoji and symbol.")
                .font(SidebarTypography.secondary())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .focused($emojiFieldFocused)
                    .onSubmit { selectEmoji() }
                Button("Use") { selectEmoji() }
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 12) {
                Text(emoji.isEmpty ? "😀" : emoji)
                    .font(SidebarTypography.pickerEmojiPreview())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 46, height: 46)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                Button("Browse All Emoji & Symbols…") {
                    emojiFieldFocused = true
                    DispatchQueue.main.async {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                }
            }
        }
        .frame(minHeight: 200, alignment: .top)
    }

    // MARK: Apply

    private func select(_ icon: ProjectIcon) {
        project.icon = icon
        dismiss()
    }

    /// 采用输入框或 macOS 字符检视器写入的 Emoji。
    private func selectEmoji() {
        let value = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        select(.emoji(value))
    }
}
