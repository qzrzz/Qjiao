//
//  FilesFindView.swift
//  kero
//
//  VS Code 风格的全局搜索与替换界面组件。
//

import SwiftUI

/// VS Code 风格全局搜寻视图面板
public struct FilesFindView: View {
    @ObservedObject public var model: FilesFindModel
    public let rootPath: String
    public let onOpenMatch: (String, Int, Int) -> Void
    /// 将 Search 输入区的真实焦点同步给 Files 容器，用于限定 ⌘F 行为。
    public let onInputFocusChanged: (_ searchFocused: Bool, _ anyInputFocused: Bool) -> Void

    @FocusState private var focusedInput: InputField?

    private enum InputField: Hashable {
        case search
        case replace
        case include
        case exclude
    }

    public init(
        model: FilesFindModel,
        rootPath: String,
        onOpenMatch: @escaping (String, Int, Int) -> Void,
        onInputFocusChanged: @escaping (Bool, Bool) -> Void = { _, _ in }
    ) {
        self.model = model
        self.rootPath = rootPath
        self.onOpenMatch = onOpenMatch
        self.onInputFocusChanged = onInputFocusChanged
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 搜索与替换输入工具栏区
            inputSection
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            Divider()

            // 搜索状态统计与快捷控制条
            if !model.statusMessage.isEmpty || !model.results.isEmpty {
                statusToolbar
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                Divider()
            }

            // 搜寻结果树状/列表显示区域
            resultsContentSection
        }
        .background(Color(nsColor: Theme.sidebar))
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                focusedInput = .search
            }
            if !rootPath.isEmpty && !model.options.query.isEmpty && model.results.isEmpty {
                model.performSearch(rootPath: rootPath)
            }
        }
        .onChange(of: rootPath) { _, newPath in
            if !newPath.isEmpty && !model.options.query.isEmpty {
                model.performSearch(rootPath: newPath)
            }
        }
        .onChange(of: focusedInput) { _, input in
            onInputFocusChanged(input == .search, input != nil)
        }
        .onDisappear {
            onInputFocusChanged(false, false)
        }
    }

    // MARK: - 输入框与选项工具栏

    private var inputSection: some View {
        VStack(spacing: 6) {
            // 第一行：展开/折叠 Replace 按钮 + 搜索框
            HStack(spacing: 4) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.isReplaceExpanded.toggle()
                    }
                }) {
                    Image(systemName: model.isReplaceExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Toggle Replace")

                // 搜索输入框 + 三位一体开关 (Aa, \b, .*)
                HStack(spacing: 4) {
                    TextField("Search", text: $model.options.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($focusedInput, equals: .search)
                        .onSubmit {
                            model.performSearch(rootPath: rootPath)
                        }

                    if model.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    } else if !model.options.query.isEmpty {
                        Button(action: {
                            model.clear()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // [Aa] Match Case
                    optionToggleButton(
                        title: "Aa",
                        tooltip: "Match Case",
                        isSelected: $model.options.isCaseSensitive
                    )

                    // [\b] Match Whole Word
                    optionToggleButton(
                        title: "ab",
                        tooltip: "Match Whole Word",
                        isSelected: $model.options.isMatchWholeWord
                    )

                    // [.*] Use Regular Expression
                    optionToggleButton(
                        title: ".*",
                        tooltip: "Use Regular Expression",
                        isSelected: $model.options.isUseRegex
                    )
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(nsColor: Theme.background))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(focusedInput == .search ? Color(nsColor: Theme.accent) : Color.gray.opacity(0.3), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedInput = .search
                }
            }

            // 第二行：替换文本框 (当展开时显示)
            if model.isReplaceExpanded {
                HStack(spacing: 4) {
                    Spacer().frame(width: 16)

                    HStack(spacing: 4) {
                        TextField("Replace", text: $model.options.replaceText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .focused($focusedInput, equals: .replace)
                            .onSubmit {
                                model.replaceAllInProject()
                            }

                        // 一键全局替换按钮
                        Button(action: {
                            model.replaceAllInProject()
                        }) {
                            Image(systemName: "line.3.crossed.swirl.arrow.triangle.forward")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Replace All (⌥⌘Enter)")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: Theme.background))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(focusedInput == .replace ? Color(nsColor: Theme.accent) : Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedInput = .replace
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 第三行：Include / Exclude 过滤器折叠按钮与配置框
            HStack(spacing: 4) {
                Spacer().frame(width: 16)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.isFilterExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .bold))
                        Text(model.isFilterExpanded ? "Hide Details" : "files to include/exclude")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if model.isFilterExpanded {
                VStack(spacing: 4) {
                    // Include Pattern
                    HStack(spacing: 4) {
                        Spacer().frame(width: 16)
                        TextField("files to include (e.g. *.ts, src/**)", text: $model.options.includePattern)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .focused($focusedInput, equals: .include)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: Theme.background))
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                            .onSubmit { model.performSearch(rootPath: rootPath) }
                    }

                    // Exclude Pattern
                    HStack(spacing: 4) {
                        Spacer().frame(width: 16)
                        TextField("files to exclude (e.g. node_modules, *.log)", text: $model.options.excludePattern)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .focused($focusedInput, equals: .exclude)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: Theme.background))
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                            .onSubmit { model.performSearch(rootPath: rootPath) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 选项切换快捷小按钮 (Aa, \b, .*)
    private func optionToggleButton(title: String, tooltip: String, isSelected: Binding<Bool>) -> some View {
        Button(action: {
            isSelected.wrappedValue.toggle()
            if !model.options.query.isEmpty {
                model.performSearch(rootPath: rootPath)
            }
        }) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isSelected.wrappedValue ? Color.white : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(isSelected.wrappedValue ? Color(nsColor: Theme.accent) : Color.clear)
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - 状态与工具栏

    private var statusToolbar: some View {
        HStack(spacing: 6) {
            Text(model.statusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            // 全部展开/全部收起
            Button(action: {
                let allExpanded = model.results.allSatisfy { $0.isExpanded }
                model.toggleExpandAll(!allExpanded)
            }) {
                Image(systemName: model.results.allSatisfy { $0.isExpanded } ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Collapse / Expand All")

            // 清除结果
            Button(action: {
                model.clear()
            }) {
                Image(systemName: "clear")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear Search Results")
        }
    }

    // MARK: - 搜寻结果列表

    private var resultsContentSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.results) { fileResult in
                    FileResultRowView(
                        fileResult: fileResult,
                        model: model,
                        onOpenMatch: onOpenMatch
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 单个文件搜寻结果行 View

private struct FileResultRowView: View {
    let fileResult: FileSearchResult
    @ObservedObject var model: FilesFindModel
    let onOpenMatch: (String, Int, Int) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 文件头行
            HStack(spacing: 6) {
                Button(action: {
                    model.toggleFileExpand(fileResult)
                }) {
                    Image(systemName: fileResult.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)

                // 文件 Icon
                MaterialFileIconView(fileName: fileResult.fileName, isDirectory: false, size: 14)

                // 文件名
                Text(fileResult.fileName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                // 相对路径
                Text(fileResult.relativePath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // 匹配计数 Badge
                Text("\(fileResult.matches.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)

                if isHovered && model.isReplaceExpanded {
                    Button(action: {
                        model.replaceAllInFile(fileResult)
                    }) {
                        Image(systemName: "line.3.crossed.swirl.arrow.triangle.forward")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Replace All in File")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture {
                model.toggleFileExpand(fileResult)
            }

            // 文件下的匹配行列表
            if fileResult.isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fileResult.matches) { match in
                        MatchItemRowView(
                            match: match,
                            fileResult: fileResult,
                            model: model,
                            onOpenMatch: onOpenMatch
                        )
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}

// MARK: - 单个匹配行 View

private struct MatchItemRowView: View {
    let match: MatchItem
    let fileResult: FileSearchResult
    @ObservedObject var model: FilesFindModel
    let onOpenMatch: (String, Int, Int) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // 行号
            Text("\(match.lineNumber)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 24, alignment: .trailing)

            // 行文本高亮显示
            highlightedContent
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovered {
                if model.isReplaceExpanded {
                    Button(action: {
                        model.replaceMatch(in: fileResult, match: match)
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(nsColor: Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Replace Match")
                }

                Button(action: {
                    model.dismissMatch(in: fileResult, match: match)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss Match")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isHovered ? Color(nsColor: Theme.accent).opacity(0.15) : Color.clear)
        .cornerRadius(3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onOpenMatch(fileResult.path, match.lineNumber, match.column)
        }
    }

    /// 高亮显示匹配文本的 View 视图
    private var highlightedContent: some View {
        HStack(spacing: 0) {
            Text(match.previewPrefix)
                .foregroundColor(.primary)
            Text(match.matchedText)
                .foregroundColor(.white)
                .bold()
                .padding(.horizontal, 2)
                .background(Color(nsColor: Theme.accent))
                .cornerRadius(2)
            Text(match.previewSuffix)
                .foregroundColor(.primary)
        }
    }
}
