//
//  FileViewerView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A file opened as a tab in a project. Text content lives here (not in the
/// view) so edits survive tab switches.
@MainActor
final class FileTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()
    /// Mutable so a rename in the file tree can re-point the tab without
    /// tearing it down (the id — hence the editor and its state — is stable).
    @Published private(set) var path: String

    enum Content {
        case text
        case image(NSImage)
        case unavailable(String)
    }

    let content: Content
    /// Current editor text, written back by the editor on every edit. Not
    /// published: the editor owns display, this is only read back for saves.
    var text: String
    /// The content as last loaded from or saved to disk. `isDirty` is the
    /// difference between this and `text`, so undoing edits back to it (or
    /// retyping the same characters) clears the dirty indicator rather than
    /// leaving it stuck on.
    private var savedText = ""
    /// Scroll position and cursor, written back by the editor as they
    /// change. Lives here (not in the view) so the state survives tab
    /// switches, and in the session snapshot so it survives relaunches. Not
    /// published for the same reason as `text`.
    var editorState = EditorState()

    @Published private(set) var isDirty = false
    @Published var saveError: String?
    /// 当前选择的行数与字符数，供底部状态栏展示。
    @Published private(set) var selectionSummary: String?

    /// The editor's scroll view while this file is on screen, so a pane-move
    /// drag can snapshot it for the drag thumbnail. Weak — owned by the mounted
    /// editor, nils out when the pane unmounts.
    weak var editorView: NSView?
    /// 当前挂载编辑器的文本同步回调；使用弱引用捕获，避免文件与协调器互相持有。
    var onReloadEditorText: (() -> Void)?

    private static let maxTextBytes = 5 << 20
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "jxl", "tiff", "bmp", "icns",
    ]

    init(path: String) {
        self.path = path
        let url = URL(fileURLWithPath: path)
        if Self.imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url) {
            content = .image(image)
            text = ""
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            content = .unavailable("Could not read file")
            text = ""
            return
        }
        guard data.count <= Self.maxTextBytes else {
            content = .unavailable("File is too large to open")
            text = ""
            return
        }
        guard let string = String(data: data, encoding: .utf8) else {
            content = .unavailable("Binary file")
            text = ""
            return
        }
        content = .text
        text = string
        savedText = string
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    /// Re-points this tab at a new location after the file (or a directory
    /// above it) was renamed on disk. The bytes are unchanged, so nothing
    /// reloads; subsequent saves write to the new path.
    func updatePath(_ newPath: String) {
        guard newPath != path else { return }
        path = newPath
    }

    /// Recompute `isDirty` from the current `text` against the saved
    /// baseline. Called after every editor change (including undo/redo), so
    /// reverting to the saved content clears the dirty state.
    func refreshDirtyState() {
        let dirty: Bool
        if case .text = content {
            dirty = text != savedText
        } else {
            dirty = false
        }
        if isDirty != dirty {
            isDirty = dirty
        }
    }

    func save() {
        guard case .text = content, isDirty else { return }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            savedText = text
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// 将编辑器选择范围转换为状态栏使用的英文摘要。
    func updateSelectionSummary(_ range: NSRange) {
        guard range.length > 0,
              let swiftRange = Range(range, in: text)
        else {
            selectionSummary = nil
            return
        }
        let selection = String(text[swiftRange])
        let lines = selection.split(separator: "\n", omittingEmptySubsequences: false).count
        selectionSummary = "\(lines) \(lines == 1 ? "line" : "lines") \(selection.count) chars"
    }

    /// 当前编辑器文本的 UTF-8 文件大小；未保存修改也能准确反映在状态栏。
    var editorFileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
    }

    /// 文件扩展名作为轻量语法格式提示；无扩展名时明确显示 Plain Text。
    var languageLabel: String {
        let ext = URL(fileURLWithPath: path).pathExtension
        return ext.isEmpty ? "Plain Text" : ext.uppercased()
    }

    /// 格式化工具改写磁盘文件后重新读取内容并清除未保存状态。
    /// 光标/选区保存在 `editorState`，由挂载的编辑器在同步文本时恢复。
    func reloadFromDisk() {
        guard let data = FileManager.default.contents(atPath: path),
              let formatted = String(data: data, encoding: .utf8)
        else { return }
        text = formatted
        savedText = formatted
        isDirty = false
        saveError = nil
        onReloadEditorText?()
    }
}

/// Content of a file tab: an STTextView editor (line numbers, system find
/// bar), an image preview, or a placeholder for anything binary or
/// oversized.
struct FileViewerView: View {
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject var file: FileTab
    /// Whether this file's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Called when the editor takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}
    /// Splits this pane on the given edge — wired to the context-menu items.
    var onSplit: (PaneDropEdge) -> Void = { _ in }

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch file.content {
        case .text:
            let themeName = colorScheme == .dark
                ? settings.editorThemeDark
                : settings.editorThemeLight
            VStack(spacing: 0) {
                if let error = file.saveError {
                    saveErrorBar(error)
                }
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
                    wrapLines: settings.wrapLines,
                    isFocused: isFocused,
                    onFocused: onFocused,
                    onSplit: onSplit
                )
                if settings.showEditorStatusBar {
                    EditorStatusBar(file: file)
                }
            }
        case .image(let image):
            ImageViewerView(file: file, image: image)
        case .unavailable(let reason):
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.quaternary)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func saveErrorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text("Could not save: \(message)")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }
}

/// 源码编辑器底部状态栏：保存状态、文件大小、选择摘要、语法与可用格式化工具。
private struct EditorStatusBar: View {
    @ObservedObject var file: FileTab
    @ObservedObject private var settings = AppSettings.shared
    @State private var formatters: [EditorFormatter] = []
    @State private var formattingID: String?
    @State private var formatterError: String?

    var body: some View {
        HStack(spacing: 9) {
            Label(file.isDirty ? "Unsaved" : "Saved", systemImage: file.isDirty ? "circle" : "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(file.editorFileSize)
            Spacer()
            if let selection = file.selectionSummary { Text(selection) }
            Button {
                settings.wrapLines.toggle()
            } label: {
                Image(systemName: "text.line.3.summary")
            }
            .buttonStyle(.plain)
            .foregroundStyle(settings.wrapLines ? Color.accentColor : .secondary)
            .help(settings.wrapLines ? "Disable line wrapping" : "Enable line wrapping")
            .accessibilityLabel("Toggle line wrapping")
            Text(file.languageLabel)
            ForEach(formatters) { formatter in
                if formatter.id == formatters.first?.id {
                    formatterButton(formatter)
                        .keyboardShortcut("p", modifiers: [.command, .option])
                } else {
                    formatterButton(formatter)
                }
            }
            if let formatterError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(formatterError)
                    .accessibilityLabel("Formatting failed: \(formatterError)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.primary.opacity(0.035))
        .task(id: file.path) { formatters = EditorFormatter.detectAll(for: file.path) }
    }

    private func format(with formatter: EditorFormatter) {
        if file.isDirty { file.save() }
        guard !file.isDirty else {
            formatterError = file.saveError ?? "Save the file before formatting it."
            return
        }
        formattingID = formatter.id
        formatterError = nil
        let path = file.path
        Task.detached {
            let result = formatter.format(path)
            await MainActor.run {
                formattingID = nil
                if result.succeeded {
                    file.reloadFromDisk()
                } else {
                    formatterError = result.errorMessage
                }
            }
        }
    }

    private func formatterButton(_ formatter: EditorFormatter) -> some View {
        Button { format(with: formatter) } label: {
            HStack(spacing: 3) {
                ZStack {
                    if formattingID == formatter.id {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.68)
                    } else {
                        Image(systemName: formatter.systemImage)
                            .font(.system(size: 11))
                    }
                }
                // 转圈与静态图标占用相同的固定槽位，避免格式化开始/结束时按钮跳动。
                .frame(width: 12, height: 12)
                Text(formatter.title)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(formattingID != nil)
        .help(formatter.id == formatters.first?.id ? "Format document (⌥⌘P)" : "Format document")
    }
}

private enum EditorFormatter: Identifiable {
    case oxfmt(URL)
    case prettier(URL)

    var title: String { switch self { case .oxfmt: "oxc"; case .prettier: "prettier" } }
    var id: String { switch self { case .oxfmt: "oxfmt"; case .prettier: "prettier" } }
    /// 两种格式化器使用同一格式化语义图标，名称负责区分实际工具。
    var systemImage: String { "text.word.spacing" }
    private var executable: URL { switch self { case .oxfmt(let url), .prettier(let url): url } }

    static func detectAll(for path: String) -> [EditorFormatter] {
        let manager = FileManager.default
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        var oxfmt: URL?
        var prettier: URL?
        for _ in 0..<8 {
            let bin = directory.appendingPathComponent("node_modules/.bin")
            let localOxfmt = bin.appendingPathComponent("oxfmt")
            if oxfmt == nil, manager.isExecutableFile(atPath: localOxfmt.path) { oxfmt = localOxfmt }
            let localPrettier = bin.appendingPathComponent("prettier")
            if prettier == nil, manager.isExecutableFile(atPath: localPrettier.path) { prettier = localPrettier }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }
        oxfmt = oxfmt ?? executable(named: "oxfmt")
        prettier = prettier ?? executable(named: "prettier")
        return [oxfmt.map(EditorFormatter.oxfmt), prettier.map(EditorFormatter.prettier)].compactMap { $0 }
    }

    /// 在项目本地依赖之外，继续检测用户 PATH 中全局安装的格式化工具。
    private static func executable(named name: String) -> URL? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty
            else { return nil }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    /// 在目标文件所在目录运行工具，让格式化器按项目上下文解析配置、插件与忽略文件。
    func format(_ path: String) -> FormatterResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        // 文件参数放在 --write 前，兼容 Prettier 文档中的标准调用形式。
        process.arguments = [path, "--write"]
        process.currentDirectoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        process.environment = Self.formatterEnvironment()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let outputText = (String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(outputText?.isEmpty == false ? outputText! : "\(title) exited with code \(process.terminationStatus).")
            }
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// GUI 应用从 Finder 启动时通常没有终端 PATH；本地 npm 二进制的 shebang
    /// 会通过 `/usr/bin/env node` 启动，因此需要补入用户交互式 shell 中的 Node 目录。
    private static func formatterEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard let nodeDirectory = interactiveShellNodeDirectory() else { return environment }

        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let directories = ([nodeDirectory.path] + existingPath.split(separator: ":").map(String.init))
        environment["PATH"] = directories.joined(separator: ":")
        return environment
    }

    /// 从用户的交互式 zsh 中读取 Node 位置，以兼容 nvm、fnm、Volta 与自定义安装目录。
    private static func interactiveShellNodeDirectory() -> URL? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ic", "command -v node"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            else { return nil }

            // shell 初始化脚本可能输出提示信息，从后向前选择实际存在的 Node 可执行文件。
            for line in text.split(whereSeparator: \.isNewline).reversed() {
                let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { continue }
                return URL(fileURLWithPath: path).deletingLastPathComponent()
            }
        } catch {}
        return nil
    }
}

/// 单文件格式化的执行结果；失败信息会通过状态栏提示，避免静默失败。
private enum FormatterResult {
    case success
    case failure(String)

    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }

    var errorMessage: String {
        if case .failure(let message) = self { return message }
        return ""
    }
}

// MARK: - 图像查看器组件与相关模型

/// 图像元数据模型，描述图片像素尺寸、Points 尺寸、缩放因子、分辨率 DPI 及磁盘文件字节大小。
struct ImageMetadata {
    /// 真实像素宽度
    let pixelWidth: Int
    /// 真实像素高度
    let pixelHeight: Int
    /// 逻辑 Points 宽度 (考虑 @2x/@3x)
    let pointWidth: Double
    /// 逻辑 Points 高度 (考虑 @2x/@3x)
    let pointHeight: Double
    /// 水平 DPI 分辨率
    let dpiX: Int
    /// 垂直 DPI 分辨率
    let dpiY: Int
    /// 缩放倍率 (例如 @2x 为 2.0)
    let scaleFactor: Double
    /// 格式化后的磁盘文件大小字符串
    let fileSizeString: String

    /// 初始化解析 NSImage 与对应磁盘路径的元数据，自动支持 @2x/@3x 文件名解包与逻辑尺寸计算
    init(image: NSImage, path: String) {
        let filename = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        var detectedScale: Double = 1.0
        if filename.hasSuffix("@2x") || filename.contains("@2x.") || filename.contains("@2x_") {
            detectedScale = 2.0
        } else if filename.hasSuffix("@3x") || filename.contains("@3x.") || filename.contains("@3x_") {
            detectedScale = 3.0
        }

        var pWidth = Int(image.size.width)
        var pHeight = Int(image.size.height)
        var finalScale = detectedScale

        if let rep = image.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
            pWidth = rep.pixelsWide
            pHeight = rep.pixelsHigh

            let sWidth = image.size.width > 0 ? image.size.width : Double(pWidth)

            var ratioX = Double(pWidth) / sWidth

            if ratioX == 1.0 && detectedScale > 1.0 {
                ratioX = detectedScale
            }

            finalScale = ratioX
        }

        self.pixelWidth = pWidth
        self.pixelHeight = pHeight
        self.scaleFactor = finalScale

        // 计算基准 Logic Points 尺寸 (@2x 下 100px 对应 50pt)
        self.pointWidth = Double(pWidth) / finalScale
        self.pointHeight = Double(pHeight) / finalScale

        self.dpiX = Int(round(finalScale * 72.0))
        self.dpiY = Int(round(finalScale * 72.0))

        // 解析磁盘文件大小或内存图像数据大小 (例如剪贴板或拖拽数据)
        var calculatedSize: Int64 = 0
        if !path.isEmpty,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            calculatedSize = size
        } else if let tiffData = image.tiffRepresentation {
            calculatedSize = Int64(tiffData.count)
        }

        if calculatedSize > 0 {
            self.fileSizeString = ByteCountFormatter.string(fromByteCount: calculatedSize, countStyle: .file)
        } else {
            self.fileSizeString = "Unknown"
        }
    }
}

/// 图像查看器缩放模式预设选项 (英文标题)
enum ImageZoomOption: Hashable, Identifiable, CaseIterable {
    case fit
    case p10
    case p25
    case p50
    case p100
    case p200
    case p400
    case p800

    var id: Self { self }

    /// 下拉菜单英文文案
    var title: String {
        switch self {
        case .fit: return "Fit"
        case .p10: return "10%"
        case .p25: return "25%"
        case .p50: return "50%"
        case .p100: return "100%"
        case .p200: return "200%"
        case .p400: return "400%"
        case .p800: return "800%"
        }
    }

    /// 缩放倍率数值 (nil 表示由视口容器自适应，且不超过 100%)
    var ratio: CGFloat? {
        switch self {
        case .fit: return nil
        case .p10: return 0.10
        case .p25: return 0.25
        case .p50: return 0.50
        case .p100: return 1.00
        case .p200: return 2.00
        case .p400: return 4.00
        case .p800: return 8.00
        }
    }
}

/// 图像查看器背景显示模式 (英文标题)
enum ImageBackgroundMode: String, CaseIterable, Identifiable {
    case defaultTheme = "Default"
    case black = "Black"
    case white = "White"
    case checkerboard = "Light Checkerboard"
    case darkCheckerboard = "Dark Checkerboard"

    var id: String { rawValue }

    /// 英文文案
    var title: String {
        switch self {
        case .defaultTheme: return "Default"
        case .black: return "Black"
        case .white: return "White"
        case .checkerboard: return "Light Checkerboard"
        case .darkCheckerboard: return "Dark Checkerboard"
        }
    }
}

/// 绘制透明棋盘格背景视图 (支持 Light 灰白 / Dark 深灰黑交替底纹)
struct CheckerboardView: View {
    /// 棋盘格单格像素尺寸
    var squareSize: CGFloat = 8
    /// 亮格颜色
    var lightColor: Color = Color(white: 0.92)
    /// 暗格颜色
    var darkColor: Color = Color(white: 0.78)

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))

            for r in 0..<rows {
                for c in 0..<cols {
                    let isEven = (r + c) % 2 == 0
                    let rect = CGRect(x: CGFloat(c) * squareSize,
                                      y: CGFloat(r) * squareSize,
                                      width: squareSize,
                                      height: squareSize)
                    context.fill(Path(rect), with: .color(isEven ? lightColor : darkColor))
                }
            }
        }
    }
}

/// 鼠标滚轮监听组件，用于捕获 NSEvent 滚轮信号实现图片自由连续缩放
struct ScrollWheelListenerView: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollWheelNSView)?.onScroll = onScroll
    }

    class ScrollWheelNSView: NSView {
        var onScroll: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let delta = event.deltaY
            if abs(delta) > 0.001 {
                onScroll?(delta)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}

// MARK: - 标尺与参考线系统模型与绘图组件

/// 参考线方向 (水平/垂直)
enum GuideOrientation: String, CaseIterable, Identifiable, Codable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"

    var id: String { rawValue }
}

/// 参考线模型，保存像素物理坐标 (相对于图像原点 0,0)
struct GuideLine: Identifiable, Equatable, Hashable {
    let id: UUID
    var orientation: GuideOrientation
    /// 图像真实像素坐标 (px)
    var pixelPosition: CGFloat

    init(id: UUID = UUID(), orientation: GuideOrientation, pixelPosition: CGFloat) {
        self.id = id
        self.orientation = orientation
        self.pixelPosition = pixelPosition
    }
}

/// 根据图像 1 物理像素在 View 中的实际 Point 比例 (pixelScale = unrotatedWidth / pixelWidth) 计算主刻度步长 (px)
/// 目标：主刻度在屏幕上约 60pt 间距，自动进位到 1/2/5 × 10^n
func calculateRulerStep(pixelScale: CGFloat) -> CGFloat {
    let targetPointStep: CGFloat = 60.0
    let rawPxStep = targetPointStep / max(pixelScale, 0.0001)

    let exponent = floor(log10(rawPxStep))
    let base = pow(10.0, exponent)
    let fraction = rawPxStep / base

    let stepFactor: CGFloat
    if fraction <= 1.5 {
        stepFactor = 1
    } else if fraction <= 3.5 {
        stepFactor = 2
    } else if fraction <= 7.5 {
        stepFactor = 5
    } else {
        stepFactor = 10
    }

    return base * stepFactor
}

/// 标尺细分数量：主刻度之间固定 10 等分；半步为次刻度，其余为微刻度
/// 使用整数索引迭代，避免浮点累加导致主刻度漏画或错位
private let rulerSubdivisionsPerMajor = 10

/// 参考线视觉线宽：1pt，无投影
private let guideLineVisualThickness: CGFloat = 1
/// 参考线可拖拽命中带厚度（大于视觉线宽，便于鼠标捕获）
private let guideLineHitThickness: CGFloat = 20
/// 图像查看器画布坐标系名称（参考线拖拽 location 换算用）
private let imageViewerCanvasCoordinateSpace = "ImageViewerCanvas"

/// 顶部水平像素标尺绘制组件 (专业级多阶刻度：主刻度+数字、次刻度、细分微刻度)
struct TopRulerCanvas: View {
    let originX: CGFloat
    let pixelScale: CGFloat
    let mouseX: CGFloat?

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Color(nsColor: .windowBackgroundColor)))

            // 标尺底部分界线
            let bottomLine = Path { p in
                p.move(to: CGPoint(x: 0, y: size.height))
                p.addLine(to: CGPoint(x: size.width, y: size.height))
            }
            context.stroke(bottomLine, with: .color(Color.primary.opacity(0.15)), lineWidth: 1)

            guard pixelScale > 0.0001 else { return }

            let stepPx = calculateRulerStep(pixelScale: pixelScale)
            let subStepPx = stepPx / CGFloat(rulerSubdivisionsPerMajor)
            // 可见视口对应的图像像素范围 → 细分刻度索引（含边距）
            let leftPx = -originX / pixelScale
            let rightPx = (size.width - originX) / pixelScale
            let startIndex = Int(floor(leftPx / subStepPx)) - 1
            let endIndex = Int(ceil(rightPx / subStepPx)) + 1

            if startIndex <= endIndex {
                for i in startIndex...endIndex {
                    let currentPx = CGFloat(i) * subStepPx
                    let x = originX + currentPx * pixelScale
                    // 避开左侧 20pt 角标区域
                    guard x >= 20 && x <= size.width else { continue }

                    let mod = ((i % rulerSubdivisionsPerMajor) + rulerSubdivisionsPerMajor) % rulerSubdivisionsPerMajor
                    let isMajor = mod == 0
                    let isMedium = mod == rulerSubdivisionsPerMajor / 2

                    if isMajor {
                        let tickPath = Path { p in
                            p.move(to: CGPoint(x: x, y: size.height - 6))
                            p.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        context.stroke(tickPath, with: .color(Color.primary.opacity(0.55)), lineWidth: 1)

                        let text = Text("\(Int(round(currentPx)))")
                            .font(.system(size: 9, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                        let resolvedText = context.resolve(text)
                        context.draw(resolvedText, at: CGPoint(x: x, y: 6), anchor: .center)
                    } else if isMedium {
                        let tickPath = Path { p in
                            p.move(to: CGPoint(x: x, y: size.height - 4))
                            p.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        context.stroke(tickPath, with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
                    } else {
                        let tickPath = Path { p in
                            p.move(to: CGPoint(x: x, y: size.height - 2.5))
                            p.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        context.stroke(tickPath, with: .color(Color.primary.opacity(0.20)), lineWidth: 1)
                    }
                }
            }

            // 鼠标位置活动指示线
            if let mx = mouseX, mx >= 20 && mx <= size.width {
                let pointerPath = Path { p in
                    p.move(to: CGPoint(x: mx, y: 0))
                    p.addLine(to: CGPoint(x: mx, y: size.height))
                }
                context.stroke(pointerPath, with: .color(Color.accentColor), lineWidth: 1)
            }
        }
        .frame(height: 20)
        .clipped()
    }
}

/// 左侧垂直像素标尺绘制组件 (专业级多阶刻度：主刻度+数字、次刻度、细分微刻度)
struct LeftRulerCanvas: View {
    let originY: CGFloat
    let pixelScale: CGFloat
    let mouseY: CGFloat?

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Color(nsColor: .windowBackgroundColor)))

            // 标尺右侧分界线
            let rightLine = Path { p in
                p.move(to: CGPoint(x: size.width, y: 0))
                p.addLine(to: CGPoint(x: size.width, y: size.height))
            }
            context.stroke(rightLine, with: .color(Color.primary.opacity(0.15)), lineWidth: 1)

            guard pixelScale > 0.0001 else { return }

            let stepPx = calculateRulerStep(pixelScale: pixelScale)
            let subStepPx = stepPx / CGFloat(rulerSubdivisionsPerMajor)
            let topPy = -originY / pixelScale
            let bottomPy = (size.height - originY) / pixelScale
            let startIndex = Int(floor(topPy / subStepPx)) - 1
            let endIndex = Int(ceil(bottomPy / subStepPx)) + 1

            if startIndex <= endIndex {
                for i in startIndex...endIndex {
                    let currentPy = CGFloat(i) * subStepPx
                    let y = originY + currentPy * pixelScale
                    // 避开顶部 20pt 角标区域
                    guard y >= 20 && y <= size.height else { continue }

                    let mod = ((i % rulerSubdivisionsPerMajor) + rulerSubdivisionsPerMajor) % rulerSubdivisionsPerMajor
                    let isMajor = mod == 0
                    let isMedium = mod == rulerSubdivisionsPerMajor / 2

                    if isMajor {
                        let tickPath = Path { p in
                            p.move(to: CGPoint(x: size.width - 6, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(tickPath, with: .color(Color.primary.opacity(0.55)), lineWidth: 1)

                        // 纵向主刻度数字 (逆时针 90 度旋转，中心对齐刻度)
                        var textContext = context
                        textContext.translateBy(x: 6, y: y)
                        textContext.rotate(by: .degrees(-90))

                        let text = Text("\(Int(round(currentPy)))")
                            .font(.system(size: 9, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                        let resolvedText = textContext.resolve(text)
                        textContext.draw(resolvedText, at: .zero, anchor: .center)
                    } else if isMedium {
                        let tickPath = Path { p in
                            p.move(to: CGPoint(x: size.width - 4, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(tickPath, with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
                    } else {
                        let tickPath = Path { p in
                            p.move(to: CGPoint(x: size.width - 2.5, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(tickPath, with: .color(Color.primary.opacity(0.20)), lineWidth: 1)
                    }
                }
            }

            // 鼠标位置活动指示线
            if let my = mouseY, my >= 20 && my <= size.height {
                let pointerPath = Path { p in
                    p.move(to: CGPoint(x: 0, y: my))
                    p.addLine(to: CGPoint(x: size.width, y: my))
                }
                context.stroke(pointerPath, with: .color(Color.accentColor), lineWidth: 1)
            }
        }
        .frame(width: 20)
        .clipped()
    }
}

/// 增强版图像查看器视图，默认开启像素模式，图标化轻量工具栏，支持旋转、自由拖拽、滚轮自由缩放、双图对比模式与标尺参考线系统。
struct ImageViewerView: View {
    @ObservedObject var file: FileTab
    let image: NSImage

    @State private var zoomOption: ImageZoomOption = .fit
    /// 鼠标滚轮/触控板产生的自由放缩倍率 (nil 时表示使用 zoomOption 的预设)
    @State private var customZoomScale: CGFloat? = nil
    /// 触控板 pinch 手势缩放增量
    @GestureState private var gestureMagnification: CGFloat = 1.0
    /// 本地 NSEvent 滚轮监听器引用
    @State private var scrollMonitor: Any? = nil

    /// 持久化记录背景模式，跨标签与应用重启自动恢复上一次选择
    @AppStorage("imageViewerBackgroundMode") private var backgroundMode: ImageBackgroundMode = .defaultTheme
    /// 当前旋转角度 (0°, 90°, 180°, 270°)
    @State private var rotationDegrees: Double = 0
    /// 是否水平镜像翻转
    @State private var isFlippedHorizontal: Bool = false
    /// 是否垂直镜像翻转
    @State private var isFlippedVertical: Bool = false
    /// 累计平移偏移位置
    @State private var offset: CGSize = .zero
    /// 手势进行时的实时拖拽偏移量
    @GestureState private var dragOffset: CGSize = .zero

    // MARK: - 对比模式状态
    /// 是否开启对比模式
    @State private var isCompareMode: Bool = false
    /// 对比图图像 NSImage
    @State private var compareImage: NSImage? = nil
    /// 对比图磁盘路径
    @State private var compareImagePath: String? = nil
    /// 对比图元数据信息
    @State private var compareMetadata: ImageMetadata? = nil
    /// 分界竖线位置比例 (0.05 ~ 0.95)，默认 0.5
    @State private var splitRatio: CGFloat = 0.5
    /// 拖拽竖线手势时的临时增量
    @GestureState private var splitDragOffset: CGFloat = 0
    /// 对比模式拖拽放落指示状态
    @State private var isDropTargeted: Bool = false
    // MARK: - 标尺与参考线系统状态
    /// 是否开启标尺显示 (默认显示)
    @State private var isRulerEnabled: Bool = false
    /// 参考线列表 (物理像素坐标系)
    @State private var guideLines: [GuideLine] = []
    /// 是否锁定参考线 (禁止拖动调整)
    @State private var isGuidesLocked: Bool = false
    /// 是否显示参考线 (隐藏时不渲染)
    @State private var isGuidesVisible: Bool = true

    /// 正在从标尺拖拽新建参考线时的方向与当前像素坐标
    @State private var newGuideOrientation: GuideOrientation? = nil
    @State private var newGuidePixelPos: CGFloat? = nil

    /// 正在拖拽移动已有参考线的 ID 与实时像素坐标
    @State private var draggingGuideId: UUID? = nil
    @State private var draggingGuidePixelPos: CGFloat? = nil

    /// 当前鼠标悬停的参考线 ID
    @State private var hoveredGuideId: UUID? = nil
    /// 鼠标指针在容器窗口坐标系下的当前位置
    @State private var mousePosInContainer: CGPoint? = nil
    /// 是否展示 ImageBuild 处理面板
    @State private var showImageBuild: Bool = false

    /// 获取原图图像及磁盘元数据信息
    private var metadata: ImageMetadata {
        ImageMetadata(image: image, path: file.path)
    }

    /// 动态获取当前主窗口/屏幕的 Retina 像素缩放因子 (Retina 高清屏通常为 2.0 / 3.0，普通屏为 1.0)
    private var screenBackingScale: CGFloat {
        if let windowScale = NSApp.mainWindow?.backingScaleFactor, windowScale > 0 {
            return windowScale
        }
        if let screenScale = NSScreen.main?.backingScaleFactor, screenScale > 0 {
            return screenScale
        }
        return 2.0
    }

    /// 高清屏下适配 1:1 绝对物理像素点对点的基准 Point 宽度
    private var retinaPointWidth: CGFloat {
        CGFloat(metadata.pixelWidth) / screenBackingScale
    }

    /// 高清屏下适配 1:1 绝对物理像素点对点的基准 Point 高度
    private var retinaPointHeight: CGFloat {
        CGFloat(metadata.pixelHeight) / screenBackingScale
    }

    var body: some View {
        GeometryReader { geometry in
            let totalSize = geometry.size
            let toolbarHeight: CGFloat = 32
            let rulerOffset: CGFloat = isRulerEnabled ? 20 : 0

            let canvasAvailableSize = CGSize(
                width: max(10, totalSize.width - rulerOffset),
                height: max(10, totalSize.height - toolbarHeight - 1 - rulerOffset)
            )

            // 判断当前处于第 1, 3 个 90° 旋转象限 (90°, 270°, 450°...)
            let isRotated90or270 = (Int(abs(rotationDegrees) / 90.0) % 2) != 0
            // 90°/270° 旋转时交换宽与高，确保 Retina 高清屏点对点像素精准自适应与视口计算完美
            let effectiveBaseSize = isRotated90or270
                ? CGSize(width: retinaPointHeight, height: retinaPointWidth)
                : CGSize(width: retinaPointWidth, height: retinaPointHeight)

            let currentScale = computeScale(containerSize: canvasAvailableSize, baseSize: effectiveBaseSize)
            let containerSize = CGSize(width: totalSize.width, height: max(10, totalSize.height - toolbarHeight - 1))

            VStack(spacing: 0) {
                // 顶部控制条与元数据面板
                imageControlToolbar(currentScale: currentScale)
                    .frame(height: toolbarHeight)

                Divider()

                let unrotatedWidth = retinaPointWidth * currentScale
                let unrotatedHeight = retinaPointHeight * currentScale
                let boundingWidth = isRotated90or270 ? unrotatedHeight : unrotatedWidth
                let boundingHeight = isRotated90or270 ? unrotatedWidth : unrotatedHeight

                // 图像物理原点 (0,0) 在视口坐标系中的位置：视口中心 − 半宽高 + 平移
                // 与下方固定视口 ZStack 居中布局 + offset 严格对应（不再使用 ScrollView 内容坐标系）
                let originX = (containerSize.width / 2) - (unrotatedWidth / 2) + offset.width + dragOffset.width
                let originY = (containerSize.height / 2) - (unrotatedHeight / 2) + offset.height + dragOffset.height

                // 拖拽平移手势
                let dragGesture = DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                    }

                let totalOffset = CGSize(
                    width: offset.width + dragOffset.width,
                    height: offset.height + dragOffset.height
                )

                // 固定视口画布（不用 ScrollView）：图像始终以视口中心 + offset 定位，
                // 与 originX/Y = container/2 - size/2 + offset 及标尺/参考线坐标系严格一致。
                // 放大超出视口时由 .clipped() 裁剪，平移仅依赖 offset（拖拽 / Cmd·Shift 滚轮）。
                ZStack(alignment: .center) {
                    // 背景铺满整个视口
                    backgroundView
                        .frame(width: containerSize.width, height: containerSize.height)

                    if isCompareMode {
                        // 对比模式：内容包围盒可大于视口，仍以中心 + offset 对齐
                        compareCanvasView(
                            boundingWidth: max(boundingWidth, containerSize.width),
                            boundingHeight: max(boundingHeight, containerSize.height),
                            unrotatedWidth: unrotatedWidth,
                            unrotatedHeight: unrotatedHeight,
                            totalOffset: totalOffset,
                            currentScale: currentScale
                        )
                    } else {
                        singleImageView(
                            unrotatedWidth: unrotatedWidth,
                            unrotatedHeight: unrotatedHeight,
                            totalOffset: totalOffset,
                            currentScale: currentScale
                        )
                    }
                }
                .frame(width: containerSize.width, height: containerSize.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        offset = .zero
                    }
                }
                .contextMenu {
                    imageContextMenu
                }
                .gesture(
                    MagnificationGesture()
                        .updating($gestureMagnification) { val, state, _ in
                            state = val
                        }
                        .onEnded { val in
                            let current = computeScale(containerSize: canvasAvailableSize, baseSize: effectiveBaseSize)
                            customZoomScale = max(0.05, min(20.0, current * val))
                        }
                )
                .overlay(alignment: .topLeading) {
                    if isCompareMode {
                        topLeftOverlay
                            .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isCompareMode {
                        topRightOverlay
                            .padding(10)
                    }
                }
                .overlay {
                    rulerAndGuidesOverlayView(
                        containerSize: containerSize,
                        originX: originX,
                        originY: originY,
                        currentScale: currentScale,
                        unrotatedWidth: unrotatedWidth
                    )
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        mousePosInContainer = location
                    case .ended:
                        mousePosInContainer = nil
                    }
                }
                .onAppear {
                    if scrollMonitor == nil {
                        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                            guard let win = event.window, win == NSApp.keyWindow || win == NSApp.mainWindow else {
                                return event
                            }
                            // Sheet / 模态对话框打开时不缩放，避免滚轮穿透
                            if win.attachedSheet != nil { return event }
                            if !win.sheets.isEmpty { return event }
                            if event.window?.isSheet == true { return event }
                            if NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) {
                                return event
                            }

                            let deltaY = event.deltaY
                            let deltaX = event.deltaX
                            guard abs(deltaY) > 0.01 || abs(deltaX) > 0.01 else { return event }

                            // 计算鼠标在窗口全局坐标系中的位置 (转为 SwiftUI 左上角原点坐标)
                            let winHeight = win.frame.height
                            let mouseX = event.locationInWindow.x
                            let mouseY = winHeight - event.locationInWindow.y
                            let mousePoint = CGPoint(x: mouseX, y: mouseY)

                            // 仅当鼠标位于「图像视口」内时才响应（排除顶部工具栏与分割线）
                            let fullFrame = geometry.frame(in: .global)
                            let imageAreaFrame = CGRect(
                                x: fullFrame.minX,
                                y: fullFrame.minY + toolbarHeight + 1,
                                width: fullFrame.width,
                                height: containerSize.height
                            )
                            guard imageAreaFrame.contains(mousePoint) else {
                                return event
                            }

                            let flags = event.modifierFlags
                            if flags.contains(.command) {
                                // 按住 Cmd 键：垂直平移 (Vertical Pan)
                                let panY = deltaY * 10.0
                                DispatchQueue.main.async {
                                    self.offset.height += panY
                                }
                                return nil
                            } else if flags.contains(.shift) {
                                // 按住 Shift 键：水平平移 (Horizontal Pan)
                                let panX = (abs(deltaX) > abs(deltaY) ? deltaX : deltaY) * 10.0
                                DispatchQueue.main.async {
                                    self.offset.width += panX
                                }
                                return nil
                            } else {
                                // 默认无修饰键：以鼠标指针当前位置为中心缩放 (Zoom around mouse location)
                                let step = deltaY > 0 ? 1.08 : 0.92
                                DispatchQueue.main.async {
                                    let current = self.computeScale(containerSize: canvasAvailableSize, baseSize: effectiveBaseSize)
                                    let targetScale = max(0.05, min(20.0, current * step))
                                    guard current > 0, abs(targetScale - current) > 0.0001 else { return }

                                    let k = targetScale / current

                                    // 鼠标相对于图像视口中心的偏移（与 origin 公式同一坐标系）
                                    let mX = mouseX - imageAreaFrame.midX
                                    let mY = mouseY - imageAreaFrame.midY

                                    // 保持鼠标下的图片像素点位置不变：offset_new = m - (m - offset_old) * k
                                    let newOffsetX = mX - (mX - self.offset.width) * k
                                    let newOffsetY = mY - (mY - self.offset.height) * k

                                    withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.86)) {
                                        self.customZoomScale = targetScale
                                        self.offset = CGSize(width: newOffsetX, height: newOffsetY)
                                    }
                                }
                                return nil
                            }
                        }
                    }
                }
                .onDisappear {
                    if let monitor = scrollMonitor {
                        NSEvent.removeMonitor(monitor)
                        scrollMonitor = nil
                    }
                }
            }
        }
        .sheet(isPresented: $showImageBuild) {
            ImageBuildView(
                session: .fromViewer(path: file.path),
                previewImage: image,
                onDismiss: { outputPath in
                    showImageBuild = false
                    if let outputPath {
                        NSWorkspace.shared.selectFile(outputPath, inFileViewerRootedAtPath: "")
                    }
                }
            )
        }
    }

    /// 对比模式左上角原图元数据浮层 (第一行文件名，第二行像素尺寸与文件大小)
    private var topLeftOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "photo")
                    .font(.system(size: 10))
                Text("Original: \(file.name)")
                    .font(.system(size: 11, weight: .regular))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("\(metadata.pixelWidth) × \(metadata.pixelHeight) px")
                Text("•")
                Text(metadata.fileSizeString)
            }
            .font(.system(size: 10, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Material.thinMaterial)
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
.textSelection(.enabled)
    }

    // MARK: - 标尺与参考线渲染与交互手势层

    // MARK: - 剪贴板与系统 Finder 联动辅助方法

    /// 将当前图片复制到系统剪贴板
    private func copyImageToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// 将当前文件路径复制到系统剪贴板
    private func copyPathToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(file.path, forType: .string)
    }

    /// 将当前图片元数据信息 (格式化文本) 复制到系统剪贴板
    private func copyMetadataInfoToClipboard() {
        let scaleStr = metadata.scaleFactor > 1.0 ? " (@\(Int(metadata.scaleFactor))x)" : ""
        let infoStr = """
        File: \((file.path as NSString).lastPathComponent)
        Dimensions: \(metadata.pixelWidth) × \(metadata.pixelHeight) px
        Resolution: \(metadata.dpiX) DPI\(scaleStr)
        File Size: \(metadata.fileSizeString)
        Path: \(file.path)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(infoStr, forType: .string)
    }

    /// 用系统默认绑定的外部 App (如 Preview / Photoshop) 打开当前图片
    private func openInDefaultApp() {
        guard !file.path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }

    /// 弹窗导出/另存为当前图片文件
    private func exportImage() {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Image"
        savePanel.nameFieldStringValue = (file.path as NSString).lastPathComponent
        savePanel.prompt = "Export"
        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                if let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: targetURL)
                }
            }
        }
    }

    // MARK: - 上下文右键菜单 ViewBuilder

    @ViewBuilder
    private var imageContextMenu: some View {
        // 1. 剪贴板快捷组
        Button {
            copyImageToClipboard()
        } label: {
            Label("Copy Image", systemImage: "doc.on.doc")
        }

        Button {
            copyPathToClipboard()
        } label: {
            Label("Copy Path", systemImage: "link")
        }

        Divider()

        // 2. 视角放缩控制组
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                zoomOption = .fit
                customZoomScale = nil
                offset = .zero
            }
        } label: {
            Label("Fit View", systemImage: "arrow.up.left.and.arrow.down.right")
        }

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                zoomOption = .p100
                customZoomScale = nil
                offset = .zero
            }
        } label: {
            Label("100% Actual Size", systemImage: "1.square")
        }

        Divider()

        // 3. 图像旋转与镜像变换组
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                rotationDegrees += 90
            }
        } label: {
            Label("Rotate 90° Clockwise", systemImage: "rotate.right")
        }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                rotationDegrees -= 90
            }
        } label: {
            Label("Rotate 90° Counter-Clockwise", systemImage: "rotate.left")
        }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isFlippedHorizontal.toggle()
            }
        } label: {
            Label(isFlippedHorizontal ? "Reset Flip Horizontal" : "Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
        }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isFlippedVertical.toggle()
            }
        } label: {
            Label(isFlippedVertical ? "Reset Flip Vertical" : "Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down.fill")
        }

        Divider()

        // 4. 背景模式子菜单
        Menu {
            ForEach(ImageBackgroundMode.allCases) { mode in
                Button {
                    backgroundMode = mode
                } label: {
                    HStack {
                        Text(mode.title)
                        if backgroundMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("Background Mode", systemImage: "square.dashed")
        }

        // 5. 标尺与参考线子菜单
        Menu {
            Toggle("Show Rulers", isOn: $isRulerEnabled)
            Toggle("Show Guides", isOn: $isGuidesVisible)
            Toggle("Lock Guides", isOn: $isGuidesLocked)

            Divider()

            Button(role: .destructive) {
                guideLines.removeAll()
            } label: {
                Label("Clear All Guides", systemImage: "trash")
            }
            .disabled(guideLines.isEmpty)
        } label: {
            Label("Rulers & Guides", systemImage: "ruler")
        }

        Divider()

        // 6. 对比模式
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isCompareMode.toggle()
            }
        } label: {
            Label(isCompareMode ? "Exit Compare Mode" : "Compare Mode", systemImage: "square.split.2x1")
        }

        Divider()

        // 7. ImageBuild：尺寸 / 格式 / 压缩
        Button {
            showImageBuild = true
        } label: {
            Label {
                Text("Image Build…")
            } icon: {
                Image("ImageBuild")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
        }
        .disabled(file.path.isEmpty)

        Divider()

        // 8. 系统 Finder 联动、外部 App 打开与导出
        Button {
            openInDefaultApp()
        } label: {
            Label("Open in Default App", systemImage: "arrow.up.forward.app")
        }

        Button {
            NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Reveal in Finder", systemImage: "finder")
        }

        Button {
            exportImage()
        } label: {
            Label("Export Image...", systemImage: "square.and.arrow.up")
        }

        Button {
            copyMetadataInfoToClipboard()
        } label: {
            Label("Copy Image Info", systemImage: "info.circle")
        }
    }

    /// 标尺、新建参考线拖拽手势与在场参考线渲染覆盖层
    @ViewBuilder
    private func rulerAndGuidesOverlayView(
        containerSize: CGSize,
        originX: CGFloat,
        originY: CGFloat,
        currentScale: CGFloat,
        unrotatedWidth: CGFloat
    ) -> some View {
        let rulerOffset: CGFloat = isRulerEnabled ? 20 : 0
        let pixelScale = unrotatedWidth / max(CGFloat(metadata.pixelWidth), 1.0)

        ZStack(alignment: .topLeading) {
            // 1. 已保存参考线列表渲染层
            if isGuidesVisible {
                ForEach(guideLines) { guide in
                    guideLineItemView(
                        guide: guide,
                        containerSize: containerSize,
                        originX: originX,
                        originY: originY,
                        currentScale: currentScale,
                        rulerOffset: rulerOffset,
                        pixelScale: pixelScale
                    )
                }
            }

            // 2. 正在从标尺向外拖拽新建的临时参考线
            if let newOrient = newGuideOrientation, let newPxPos = newGuidePixelPos {
                tempNewGuideLineView(
                    orientation: newOrient,
                    pixelPos: newPxPos,
                    containerSize: containerSize,
                    originX: originX,
                    originY: originY,
                    currentScale: currentScale,
                    pixelScale: pixelScale
                )
            }

            // 3. 像素标尺栏 (顶部与左侧)
            if isRulerEnabled {
                rulerBarsView(
                    containerSize: containerSize,
                    originX: originX,
                    originY: originY,
                    currentScale: currentScale,
                    pixelScale: pixelScale
                )
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .coordinateSpace(name: imageViewerCanvasCoordinateSpace)
        .allowsHitTesting(isRulerEnabled || !guideLines.isEmpty || newGuideOrientation != nil)
    }

    // MARK: - 参考线智能边缘吸附算子

    /// 计算参考线吸附后的像素坐标 (智能磁吸图像 Top/Center/Bottom 或 Left/Center/Right 边缘)
    private func snapPixelPosition(
        rawPixelPos: CGFloat,
        orientation: GuideOrientation,
        pixelScale: CGFloat
    ) -> (snappedPos: CGFloat, snapLabel: String?) {
        // 约 7pt 屏幕距离换算为图像像素阈值（与 pixelScale 对齐，Retina 下也稳定）
        let snapThresholdPx: CGFloat = 7.0 / max(pixelScale, 0.0001)

        if orientation == .horizontal {
            let targets: [(pos: CGFloat, label: String)] = [
                (0, "Top Edge"),
                (CGFloat(metadata.pixelHeight) / 2.0, "Center"),
                (CGFloat(metadata.pixelHeight), "Bottom Edge")
            ]
            for target in targets {
                if abs(rawPixelPos - target.pos) <= snapThresholdPx {
                    return (target.pos, target.label)
                }
            }
        } else {
            let targets: [(pos: CGFloat, label: String)] = [
                (0, "Left Edge"),
                (CGFloat(metadata.pixelWidth) / 2.0, "Center"),
                (CGFloat(metadata.pixelWidth), "Right Edge")
            ]
            for target in targets {
                if abs(rawPixelPos - target.pos) <= snapThresholdPx {
                    return (target.pos, target.label)
                }
            }
        }
        return (rawPixelPos, nil)
    }

    /// 单条已有参考线的渲染、Hover 高亮、坐标气泡与拖拽/移除逻辑
    @ViewBuilder
    private func guideLineItemView(
        guide: GuideLine,
        containerSize: CGSize,
        originX: CGFloat,
        originY: CGFloat,
        currentScale: CGFloat,
        rulerOffset: CGFloat,
        pixelScale: CGFloat
    ) -> some View {
        let isHovered = hoveredGuideId == guide.id
        let isDragging = draggingGuideId == guide.id
        let activePos = isDragging ? (draggingGuidePixelPos ?? guide.pixelPosition) : guide.pixelPosition
        let snapInfo = snapPixelPosition(rawPixelPos: activePos, orientation: guide.orientation, pixelScale: pixelScale)

        if guide.orientation == .horizontal {
            // 水平参考线 (固定 View Y 坐标)
            let viewY = originY + activePos * pixelScale
            let isOutOfBounds = isDragging && (viewY <= rulerOffset || viewY <= 0 || viewY >= containerSize.height)

            if viewY >= -100 && viewY <= containerSize.height + 100 {
                ZStack(alignment: .leading) {
                    // 扩大命中区域便于拖拽；视觉线仍为 1pt、无投影
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .frame(width: containerSize.width, height: guideLineHitThickness)
                        .contentShape(Rectangle())

                    // 实体参考线：固定 1pt，无投影
                    Rectangle()
                        .fill(isOutOfBounds ? Color.red : (snapInfo.snapLabel != nil ? Color.yellow : (isHovered || isDragging ? Color.accentColor : Color.cyan.opacity(0.85))))
                        .frame(width: containerSize.width, height: guideLineVisualThickness)
                        .allowsHitTesting(false)

                    // 悬停/拖拽时的精准坐标与吸附/删除气泡提示
                    if isHovered || isDragging {
                        let textStr: String = {
                            if isOutOfBounds {
                                return "Release to Delete"
                            } else if let label = snapInfo.snapLabel {
                                return "Y: \(Int(round(activePos))) px • \(label)"
                            } else {
                                return "Y: \(Int(round(activePos))) px"
                            }
                        }()

                        Text(textStr)
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(isOutOfBounds ? Color.red : (snapInfo.snapLabel != nil ? Color.orange : Color.accentColor)))
                            .offset(x: max(30, (mousePosInContainer?.x ?? 50) + 10), y: -14)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: containerSize.width, height: guideLineHitThickness)
                .contentShape(Rectangle())
                .position(x: containerSize.width / 2, y: viewY)
                .onHover { over in
                    hoveredGuideId = over ? guide.id : nil
                }
                .highPriorityGesture(
                    isGuidesLocked ? nil :
                    // 使用画布坐标系，location 与 originY 同一空间（不随命中带宽变化）
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(imageViewerCanvasCoordinateSpace))
                        .onChanged { value in
                            draggingGuideId = guide.id
                            let currentY = value.location.y
                            let rawPx = (currentY - originY) / pixelScale
                            let snapRes = snapPixelPosition(rawPixelPos: rawPx, orientation: .horizontal, pixelScale: pixelScale)
                            draggingGuidePixelPos = snapRes.snappedPos
                        }
                        .onEnded { value in
                            let finalY = value.location.y
                            // 若拖回顶部标尺 (Y <= rulerOffset) 或拖出上下窗口边界，自动清理移除
                            if finalY <= rulerOffset || finalY <= 0 || finalY >= containerSize.height {
                                guideLines.removeAll { $0.id == guide.id }
                            } else if let newPx = draggingGuidePixelPos {
                                if let idx = guideLines.firstIndex(where: { $0.id == guide.id }) {
                                    guideLines[idx].pixelPosition = newPx
                                }
                            }
                            draggingGuideId = nil
                            draggingGuidePixelPos = nil
                        }
                )
            }
        } else {
            // 垂直参考线 (固定 View X 坐标)
            let viewX = originX + activePos * pixelScale
            let isOutOfBounds = isDragging && (viewX <= rulerOffset || viewX <= 0 || viewX >= containerSize.width)

            if viewX >= -100 && viewX <= containerSize.width + 100 {
                ZStack(alignment: .top) {
                    // 扩大命中区域便于拖拽；视觉线仍为 1pt、无投影
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .frame(width: guideLineHitThickness, height: containerSize.height)
                        .contentShape(Rectangle())

                    // 实体参考线：固定 1pt，无投影
                    Rectangle()
                        .fill(isOutOfBounds ? Color.red : (snapInfo.snapLabel != nil ? Color.yellow : (isHovered || isDragging ? Color.accentColor : Color.cyan.opacity(0.85))))
                        .frame(width: guideLineVisualThickness, height: containerSize.height)
                        .allowsHitTesting(false)

                    // 悬停/拖拽时的精准坐标与吸附/删除气泡提示
                    if isHovered || isDragging {
                        let textStr: String = {
                            if isOutOfBounds {
                                return "Release to Delete"
                            } else if let label = snapInfo.snapLabel {
                                return "X: \(Int(round(activePos))) px • \(label)"
                            } else {
                                return "X: \(Int(round(activePos))) px"
                            }
                        }()

                        Text(textStr)
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(isOutOfBounds ? Color.red : (snapInfo.snapLabel != nil ? Color.orange : Color.accentColor)))
                            .offset(x: 12, y: max(30, (mousePosInContainer?.y ?? 50) + 10))
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: guideLineHitThickness, height: containerSize.height)
                .contentShape(Rectangle())
                .position(x: viewX, y: containerSize.height / 2)
                .onHover { over in
                    hoveredGuideId = over ? guide.id : nil
                }
                .highPriorityGesture(
                    isGuidesLocked ? nil :
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(imageViewerCanvasCoordinateSpace))
                        .onChanged { value in
                            draggingGuideId = guide.id
                            let currentX = value.location.x
                            let rawPx = (currentX - originX) / pixelScale
                            let snapRes = snapPixelPosition(rawPixelPos: rawPx, orientation: .vertical, pixelScale: pixelScale)
                            draggingGuidePixelPos = snapRes.snappedPos
                        }
                        .onEnded { value in
                            let finalX = value.location.x
                            // 若拖回左侧标尺 (X <= rulerOffset) 或拖出左右窗口边界，自动清理移除
                            if finalX <= rulerOffset || finalX <= 0 || finalX >= containerSize.width {
                                guideLines.removeAll { $0.id == guide.id }
                            } else if let newPx = draggingGuidePixelPos {
                                if let idx = guideLines.firstIndex(where: { $0.id == guide.id }) {
                                    guideLines[idx].pixelPosition = newPx
                                }
                            }
                            draggingGuideId = nil
                            draggingGuidePixelPos = nil
                        }
                )
            }
        }
    }

    /// 正在从标尺拖拽新建时的临时动态参考线与实时坐标气泡
    @ViewBuilder
    private func tempNewGuideLineView(
        orientation: GuideOrientation,
        pixelPos: CGFloat,
        containerSize: CGSize,
        originX: CGFloat,
        originY: CGFloat,
        currentScale: CGFloat,
        pixelScale: CGFloat
    ) -> some View {
        let snapInfo = snapPixelPosition(rawPixelPos: pixelPos, orientation: orientation, pixelScale: pixelScale)
        let activePos = snapInfo.snappedPos

        if orientation == .horizontal {
            let viewY = originY + activePos * pixelScale
            ZStack(alignment: .leading) {
                // 新建中的临时线：1pt、无投影（与已保存参考线视觉一致）
                Rectangle()
                    .fill(snapInfo.snapLabel != nil ? Color.yellow : Color.accentColor)
                    .frame(width: containerSize.width, height: guideLineVisualThickness)

                let textStr = snapInfo.snapLabel != nil ? "Y: \(Int(round(activePos))) px • \(snapInfo.snapLabel!)" : "Y: \(Int(round(activePos))) px"
                Text(textStr)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(snapInfo.snapLabel != nil ? Color.orange : Color.accentColor))
                    .offset(x: max(30, (mousePosInContainer?.x ?? 50) + 10), y: -14)
            }
            .position(x: containerSize.width / 2, y: viewY)
        } else {
            let viewX = originX + activePos * pixelScale
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(snapInfo.snapLabel != nil ? Color.yellow : Color.accentColor)
                    .frame(width: guideLineVisualThickness, height: containerSize.height)

                let textStr = snapInfo.snapLabel != nil ? "X: \(Int(round(activePos))) px • \(snapInfo.snapLabel!)" : "X: \(Int(round(activePos))) px"
                Text(textStr)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(snapInfo.snapLabel != nil ? Color.orange : Color.accentColor))
                    .offset(x: 12, y: max(30, (mousePosInContainer?.y ?? 50) + 10))
            }
            .position(x: viewX, y: containerSize.height / 2)
        }
    }

    /// 顶部与左侧标尺视图及拖拽/双击创建手势 (包含智能磁吸)
    @ViewBuilder
    private func rulerBarsView(
        containerSize: CGSize,
        originX: CGFloat,
        originY: CGFloat,
        currentScale: CGFloat,
        pixelScale: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // 1. 顶部标尺 (拖拽向下滑动创建水平参考线，双击快速创建)
            TopRulerCanvas(
                originX: originX,
                pixelScale: pixelScale,
                mouseX: mousePosInContainer?.x
            )
            .frame(width: containerSize.width, height: 20)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                let rawPx = (location.x - originX) / pixelScale
                let snapRes = snapPixelPosition(rawPixelPos: rawPx, orientation: .vertical, pixelScale: pixelScale)
                guideLines.append(GuideLine(orientation: .vertical, pixelPosition: snapRes.snappedPos))
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(imageViewerCanvasCoordinateSpace))
                    .onChanged { value in
                        newGuideOrientation = .horizontal
                        let currentY = value.location.y
                        let rawPx = (currentY - originY) / pixelScale
                        let snapRes = snapPixelPosition(rawPixelPos: rawPx, orientation: .horizontal, pixelScale: pixelScale)
                        newGuidePixelPos = snapRes.snappedPos
                    }
                    .onEnded { value in
                        let finalY = value.location.y
                        if finalY > 20, let px = newGuidePixelPos {
                            guideLines.append(GuideLine(orientation: .horizontal, pixelPosition: px))
                        }
                        newGuideOrientation = nil
                        newGuidePixelPos = nil
                    }
            )

            // 2. 左侧标尺 (拖拽向右滑动创建垂直参考线，双击快速创建)
            LeftRulerCanvas(
                originY: originY,
                pixelScale: pixelScale,
                mouseY: mousePosInContainer?.y
            )
            .frame(width: 20, height: containerSize.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                let rawPy = (location.y - originY) / pixelScale
                let snapRes = snapPixelPosition(rawPixelPos: rawPy, orientation: .horizontal, pixelScale: pixelScale)
                guideLines.append(GuideLine(orientation: .horizontal, pixelPosition: snapRes.snappedPos))
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(imageViewerCanvasCoordinateSpace))
                    .onChanged { value in
                        newGuideOrientation = .vertical
                        let currentX = value.location.x
                        let rawPx = (currentX - originX) / pixelScale
                        let snapRes = snapPixelPosition(rawPixelPos: rawPx, orientation: .vertical, pixelScale: pixelScale)
                        newGuidePixelPos = snapRes.snappedPos
                    }
                    .onEnded { value in
                        let finalX = value.location.x
                        if finalX > 20, let px = newGuidePixelPos {
                            guideLines.append(GuideLine(orientation: .vertical, pixelPosition: px))
                        }
                        newGuideOrientation = nil
                        newGuidePixelPos = nil
                    }
            )

            // 3. 左上角 (0,0) 标尺相交按钮块 (独占 20x20 顶角，高于左右标尺层级)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isRulerEnabled.toggle()
                }
            } label: {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "ruler")
                            .font(.system(size: 9))
                            .foregroundStyle(isRulerEnabled ? Color.accentColor : Color.secondary)
                    )
                    .overlay(
                        Rectangle()
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle Rulers")
        }
    }

    /// 对比模式右上角对比图元数据浮层 (第一行文件名与清除按钮，第二行像素尺寸与文件大小)
    @ViewBuilder
    private var topRightOverlay: some View {
        if let compMeta = compareMetadata {
            let name = compareImagePath != nil ? ((compareImagePath! as NSString).lastPathComponent) : "Clipboard Image"
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 10))
                    Text("Compare: \(name)")
                        .font(.system(size: 11, weight: .regular))
                        .lineLimit(1)

                    // 关闭对比图按钮 (回到缺省占位与添加模式)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            compareImage = nil
                            compareImagePath = nil
                            compareMetadata = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove comparison image")
                }
                HStack(spacing: 6) {
                    Text("\(compMeta.pixelWidth) × \(compMeta.pixelHeight) px")
                    Text("•")
                    Text(compMeta.fileSizeString)
                }
                .font(.system(size: 10, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Material.thinMaterial)
            .cornerRadius(6)
            .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
            .textSelection(.enabled)
        }
    }

    /// 单图模式下的图像展示 (放缩 > 100% 自动像素模式 .none，<= 100% 自动高质量模式 .high)
    private func singleImageView(
        unrotatedWidth: CGFloat,
        unrotatedHeight: CGFloat,
        totalOffset: CGSize,
        currentScale: CGFloat
    ) -> some View {
        let isPixelMode = (currentScale > 1.0001)
        return Image(nsImage: image)
            .resizable()
            .interpolation(isPixelMode ? .none : .high)
            .antialiased(!isPixelMode)
            .frame(width: unrotatedWidth, height: unrotatedHeight)
            .rotationEffect(.degrees(rotationDegrees))
            .offset(totalOffset)
            .shadow(color: .black.opacity(backgroundMode == .defaultTheme ? 0.1 : 0.0), radius: 6, x: 0, y: 2)
    }

    /// 对比模式下的图像展示 (双图叠加，分界线左右精确遮罩，动态响应放大像素模式)
    private func compareCanvasView(
        boundingWidth: CGFloat,
        boundingHeight: CGFloat,
        unrotatedWidth: CGFloat,
        unrotatedHeight: CGFloat,
        totalOffset: CGSize,
        currentScale: CGFloat
    ) -> some View {
        let baseSplitX = boundingWidth * splitRatio
        let currentSplitX = max(0, min(boundingWidth, baseSplitX + splitDragOffset))
        let isPixelMode = (currentScale > 1.0001)

        return ZStack(alignment: .center) {
            // 1. 原图层 (位于分界竖线左侧)
            singleImageView(
                unrotatedWidth: unrotatedWidth,
                unrotatedHeight: unrotatedHeight,
                totalOffset: totalOffset,
                currentScale: currentScale
            )
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                        .frame(width: currentSplitX)
                    Spacer(minLength: 0)
                }
                .frame(width: boundingWidth, height: boundingHeight)
            )

            // 2. 对比图层 (位于分界竖线右侧)
            if let compImage = compareImage {
                Image(nsImage: compImage)
                    .resizable()
                    .interpolation(isPixelMode ? .none : .high)
                    .antialiased(!isPixelMode)
                    .frame(width: unrotatedWidth, height: unrotatedHeight)
                    .rotationEffect(.degrees(rotationDegrees))
                    .offset(totalOffset)
                    .shadow(color: .black.opacity(backgroundMode == .defaultTheme ? 0.1 : 0.0), radius: 6, x: 0, y: 2)
                    .mask(
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                                .frame(width: currentSplitX)
                            Rectangle()
                        }
                        .frame(width: boundingWidth, height: boundingHeight)
                    )
            } else {
                // 对比图缺省提示面板 (右侧未添加对比图时展示)
                comparePlaceholderView
                    .frame(width: max(180, boundingWidth - currentSplitX), height: boundingHeight)
                    .offset(x: currentSplitX / 2)
            }

            // 3. 可拖拽分界竖线与两端手柄 (避开中间细节)
            splitDividerLineView(boundingWidth: boundingWidth, boundingHeight: boundingHeight)
        }
        .frame(width: boundingWidth, height: boundingHeight)
        .onDrop(of: [.fileURL, .url, .plainText, .utf8PlainText, .image], isTargeted: $isDropTargeted) { providers in
            handleCompareDrop(providers: providers)
        }
    }

    /// 对比模式缺省占位与操作面板 (支持文件拖拽 Drop、剪贴板粘贴与文件对话框选取)
    private var comparePlaceholderView: some View {
        VStack(spacing: 10) {
            Image(systemName: isDropTargeted ? "square.and.arrow.down.fill" : "photo.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

            Text("Compare Image")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)

            Text("Drop an image file here, or paste from clipboard")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                // 从剪贴板粘贴
                Button {
                    pasteFromClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste")
                    }
                    .font(.system(size: 11, weight: .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Paste image from clipboard")

                // 从文件选择
                Button {
                    openCompareFileDialog()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("Choose...")
                    }
                    .font(.system(size: 11, weight: .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Select a compare image file")
            }
            .padding(.top, 4)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(isDropTargeted ? Color.accentColor.opacity(0.05) : Color.primary.opacity(0.02))
        )
        .onDrop(of: [.fileURL, .url, .plainText, .utf8PlainText, .image], isTargeted: $isDropTargeted) { providers in
            handleCompareDrop(providers: providers)
        }
    }

    /// 精确对齐的可左右拖拽分界竖线，手柄分布在顶端与底端 (无缝无跳变)
    private func splitDividerLineView(boundingWidth: CGFloat, boundingHeight: CGFloat) -> some View {
        let baseSplitX = boundingWidth * splitRatio
        let currentSplitX = max(0, min(boundingWidth, baseSplitX + splitDragOffset))
        let lineOffsetX = currentSplitX - boundingWidth / 2

        let splitDragGesture = DragGesture()
            .updating($splitDragOffset) { value, state, _ in
                state = value.translation.width
            }
            .onEnded { value in
                let finalX = max(0, min(boundingWidth, baseSplitX + value.translation.width))
                splitRatio = max(0.05, min(0.95, finalX / boundingWidth))
            }

        return ZStack {
            // 纤细分界竖线 (无中心遮挡)
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 0)
                .frame(width: 1.5, height: boundingHeight)

            // 仅在顶端和底端放置拖拽手柄胶囊
            VStack {
                endHandleCapsule
                Spacer()
                endHandleCapsule
            }
            .padding(.vertical, 8)
            .frame(height: boundingHeight)
        }
        .offset(x: lineOffsetX)
        .gesture(splitDragGesture)
    }

    /// 位于竖线顶端与底端的小巧双向拖拽手柄
    private var endHandleCapsule: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        )
    }

    /// 从剪贴板提取图像
    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = images.first {
            self.compareImage = img
            self.compareImagePath = nil
            self.compareMetadata = ImageMetadata(image: img, path: "")
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  let url = urls.first,
                  let img = NSImage(contentsOf: url) {
            self.compareImage = img
            self.compareImagePath = url.path
            self.compareMetadata = ImageMetadata(image: img, path: url.path)
        }
    }

    /// 打开文件对话框选择对比图像
    private func openCompareFileDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            self.compareImage = img
            self.compareImagePath = url.path
            self.compareMetadata = ImageMetadata(image: img, path: url.path)
        }
    }

    /// 处理对比图文件/图像拖入 (Drop)，优先从拖拽 Pasteboard 与 ItemProvider 提取真实磁盘文件路径
    private func handleCompareDrop(providers: [NSItemProvider]) -> Bool {
        // A. 优先从系统的 Drag Pasteboard 直接提取文件 URL 或路径 (针对 Finder 拖拽与项目侧边栏文件树拖拽)
        let dragPB = NSPasteboard(name: .drag)
        if let urls = dragPB.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first {
            let path = url.isFileURL ? url.path : (url.path.isEmpty ? url.absoluteString : url.path)
            let cleanPath = (path as NSString).expandingTildeInPath
            if !cleanPath.isEmpty, let img = NSImage(contentsOfFile: cleanPath) ?? NSImage(contentsOf: url) {
                DispatchQueue.main.async {
                    self.compareImage = img
                    self.compareImagePath = cleanPath
                    self.compareMetadata = ImageMetadata(image: img, path: cleanPath)
                }
                return true
            }
        }
        if let paths = dragPB.readObjects(forClasses: [NSString.self], options: nil) as? [String], let rawPath = paths.first {
            let cleanPath = (rawPath as NSString).expandingTildeInPath
            let fileURL = rawPath.hasPrefix("file://") ? URL(string: rawPath) : URL(fileURLWithPath: cleanPath)
            let finalPath = fileURL?.path ?? cleanPath
            if FileManager.default.fileExists(atPath: finalPath), let img = NSImage(contentsOfFile: finalPath) {
                DispatchQueue.main.async {
                    self.compareImage = img
                    self.compareImagePath = finalPath
                    self.compareMetadata = ImageMetadata(image: img, path: finalPath)
                }
                return true
            }
        }

        // B. 从 NSItemProvider 异步解包 (覆盖 Plain Text 路径字符串)
        guard let provider = providers.first else { return false }

        // 1. 尝试按 String 路径提取 (项目侧边栏文件树拖拽传输)
        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { str, _ in
                if let str = str {
                    let cleanPath = (str as NSString).expandingTildeInPath
                    let fileURL = str.hasPrefix("file://") ? URL(string: str) : URL(fileURLWithPath: cleanPath)
                    let finalPath = fileURL?.path ?? cleanPath

                    if FileManager.default.fileExists(atPath: finalPath), let img = NSImage(contentsOfFile: finalPath) ?? (fileURL != nil ? NSImage(contentsOf: fileURL!) : nil) {
                        DispatchQueue.main.async {
                            self.compareImage = img
                            self.compareImagePath = finalPath
                            self.compareMetadata = ImageMetadata(image: img, path: finalPath)
                        }
                        return
                    }
                }
                DispatchQueue.main.async {
                    self.loadObjectUrlFallback(provider: provider)
                }
            }
            return true
        }

        // 2. 尝试按 URL 提取
        loadObjectUrlFallback(provider: provider)
        return true
    }

    /// 第二重降级：使用 canLoadObject(ofClass: URL.self) 尝试提取
    private func loadObjectUrlFallback(provider: NSItemProvider) {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    let path = url.isFileURL ? url.path : (url.path.isEmpty ? url.absoluteString : url.path)
                    let cleanPath = (path as NSString).expandingTildeInPath
                    if !cleanPath.isEmpty, let img = NSImage(contentsOfFile: cleanPath) ?? NSImage(contentsOf: url) {
                        DispatchQueue.main.async {
                            self.compareImage = img
                            self.compareImagePath = cleanPath
                            self.compareMetadata = ImageMetadata(image: img, path: cleanPath)
                        }
                        return
                    }
                }
                DispatchQueue.main.async {
                    self.fallbackLoadNSImage(provider: provider)
                }
            }
        } else {
            fallbackLoadNSImage(provider: provider)
        }
    }

    /// 降级读取纯 NSImage 内存图像 (针对无法提取磁盘 URL 的情况)
    private func fallbackLoadNSImage(provider: NSItemProvider) {
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                if let img = img as? NSImage {
                    DispatchQueue.main.async {
                        self.compareImage = img
                        self.compareImagePath = nil
                        self.compareMetadata = ImageMetadata(image: img, path: "")
                    }
                }
            }
        }
    }

    /// 当前呈现给用户的缩放倍数格式化文本
    private func currentDisplayZoomText(currentScale: CGFloat) -> String {
        if let custom = customZoomScale {
            let percent = Int(round(custom * 100))
            return "\(percent)%"
        } else if zoomOption == .fit {
            let percent = Int(round(currentScale * 100))
            return "Fit (\(percent)%)"
        } else {
            return zoomOption.title
        }
    }

    /// 根据选中的缩放预设选项或滚轮自由数值与容器视口计算实时生效的缩放倍率
    private func computeScale(containerSize: CGSize, baseSize: CGSize) -> CGFloat {
        let base: CGFloat
        if let custom = customZoomScale {
            base = custom
        } else if let ratio = zoomOption.ratio {
            base = ratio
        } else {
            // Fit 自适应模式：保留 32px 安全 Padding 边距，且最大不超过 1.0
            let availableWidth = max(containerSize.width - 32, 1)
            let availableHeight = max(containerSize.height - 32, 1)
            guard baseSize.width > 0 && baseSize.height > 0 else { return 1.0 }
            let fitX = availableWidth / baseSize.width
            let fitY = availableHeight / baseSize.height
            base = min(fitX, fitY, 1.0)
        }
        return base * gestureMagnification
    }

    /// 对应的背景 View
    @ViewBuilder
    private var backgroundView: some View {
        switch backgroundMode {
        case .defaultTheme:
            Color.clear
        case .black:
            Color.black
        case .white:
            Color.white
        case .checkerboard:
            CheckerboardView(
                squareSize: 8,
                lightColor: Color(white: 0.92),
                darkColor: Color(white: 0.78)
            )
        case .darkCheckerboard:
            CheckerboardView(
                squareSize: 8,
                lightColor: Color(white: 0.24),
                darkColor: Color(white: 0.12)
            )
        }
    }

    /// 顶部图像控制与信息面板 (现代化高质感样式，支持悬停光泽高亮与 Accent 描边)
    private func imageControlToolbar(currentScale: CGFloat) -> some View {
        HStack(spacing: 6) {
            // 1. 缩放倍数下拉菜单 (固定 128px 宽度，避免跳变)
            ModernToolbarMenu(fixedWidth: 128, helpText: "Zoom Scale Option") {
                Picker("Zoom", selection: Binding(
                    get: { zoomOption },
                    set: { newValue in
                        zoomOption = newValue
                        customZoomScale = nil
                        if newValue == .fit {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                offset = .zero
                            }
                        }
                    }
                )) {
                    ForEach(ImageZoomOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } labelContent: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                    Text("Zoom: \(currentDisplayZoomText(currentScale: currentScale))")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }

            // 2. 一键快速重置至 Fit 状态
            ModernToolbarButton(isActive: zoomOption == .fit && customZoomScale == nil, helpText: "Reset to Fit View (⌘0)") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    zoomOption = .fit
                    customZoomScale = nil
                    offset = .zero
                }
            } content: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
            }

            // 3. 一键快速缩放至 100% 真实像素尺寸
            ModernToolbarButton(isActive: zoomOption == .p100 && customZoomScale == nil, helpText: "Zoom to 100% Actual Size (⌘1)") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    zoomOption = .p100
                    customZoomScale = nil
                    offset = .zero
                }
            } content: {
                Image(systemName: "1.square")
                    .font(.system(size: 11))
            }

            ModernToolbarDivider()

            // 4. 顺时针旋转按钮 (+90°)
            ModernToolbarButton(helpText: "Rotate 90° Clockwise") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    rotationDegrees += 90
                }
            } content: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 11))
            }

            ModernToolbarDivider()

            // 5. 图片对比模式开关按钮
            ModernToolbarButton(isActive: isCompareMode, helpText: "Image Comparison Mode") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCompareMode.toggle()
                }
            } content: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 11))
            }

            // 6. ImageBuild：尺寸 / 格式转换 / 压缩
            ModernToolbarButton(
                isActive: showImageBuild,
                helpText: "Image Build — 尺寸 / 格式 / 压缩"
            ) {
                showImageBuild = true
            } content: {
                Image("ImageBuild")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 13, height: 13)
            }
            .disabled(file.path.isEmpty)

            // 7. 标尺与参考线控制下拉菜单
            ModernToolbarMenu(isActive: isRulerEnabled, helpText: "Rulers & Reference Guides") {
                Toggle("Show Rulers", isOn: $isRulerEnabled)
                Toggle("Show Guides", isOn: $isGuidesVisible)
                Toggle("Lock Guides", isOn: $isGuidesLocked)

                Divider()

                Button(role: .destructive) {
                    guideLines.removeAll()
                } label: {
                    Label("Clear All Guides", systemImage: "trash")
                }
                .disabled(guideLines.isEmpty)
            } labelContent: {
                Image(systemName: isRulerEnabled ? "ruler.fill" : "ruler")
                    .font(.system(size: 11))
            }

            // 8. 背景模式下拉菜单
            ModernToolbarMenu(helpText: "Background Mode") {
                Picker("Background Mode", selection: $backgroundMode) {
                    ForEach(ImageBackgroundMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } labelContent: {
                Image(systemName: "light.panel.fill")
                    .font(.system(size: 11))
            }

            Spacer(minLength: 4)

            // 9. 响应式元数据数值信息栏 (在窄窗口下平滑自适应降级，绝对避免折行与文本重叠)
            AdaptiveImageMetadataView(metadata: metadata)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.primary.opacity(0.035))
    }
}

// MARK: - 响应式元数据数值信息栏组件

/// 响应式右侧图片元数据数值信息栏 (在宽/中/窄窗口下自动优雅降级，防止文本溢出或挤压工具栏按钮)
private struct AdaptiveImageMetadataView: View {
    let metadata: ImageMetadata

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // 1. 完整宽窗口显示模式
            fullWidthLayout

            // 2. 中等窄窗口模式 (缩短间距，隐藏 @2x 标记与 px 后缀)
            mediumCompactLayout

            // 3. 紧凑窄窗口模式 (只保留像素尺寸与文件大小)
            compactLayout

            // 4. 极窄窗口模式 (仅保留核心像素尺寸)
            minimalLayout
        }
        .font(.system(size: 11, weight: .regular))
        .monospacedDigit()
        .textSelection(.enabled)
        .foregroundStyle(.secondary)
    }

    // 模式 1: 完整宽模式
    private var fullWidthLayout: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 10))
                Text("\(metadata.pixelWidth) × \(metadata.pixelHeight) px")
            }
            HStack(spacing: 3) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 10))
                let scaleLabel = metadata.scaleFactor > 1.0 ? " (@\(Int(metadata.scaleFactor))x)" : ""
                Text("\(metadata.dpiX) DPI\(scaleLabel)")
            }
            HStack(spacing: 3) {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                Text(metadata.fileSizeString)
            }
        }
    }

    // 模式 2: 中等窄模式
    private var mediumCompactLayout: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 10))
                Text("\(metadata.pixelWidth)×\(metadata.pixelHeight)")
            }
            HStack(spacing: 2) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 10))
                Text("\(metadata.dpiX) DPI")
            }
            HStack(spacing: 2) {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                Text(metadata.fileSizeString)
            }
        }
    }

    // 模式 3: 紧凑窄模式
    private var compactLayout: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 10))
                Text("\(metadata.pixelWidth)×\(metadata.pixelHeight)")
            }
            HStack(spacing: 2) {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                Text(metadata.fileSizeString)
            }
        }
    }

    // 模式 4: 极窄模式
    private var minimalLayout: some View {
        HStack(spacing: 2) {
            Image(systemName: "aspectratio")
                .font(.system(size: 10))
            Text("\(metadata.pixelWidth)×\(metadata.pixelHeight)")
        }
    }
}

// MARK: - 现代化极简工具栏微组件

/// 现代化极简精致工具栏按钮 (包含悬停 Hover 光泽高亮、Accent 激活高亮边框与极微轻量触感微动)
private struct ModernToolbarButton<Content: View>: View {
    var isActive: Bool = false
    var helpText: String? = nil
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .foregroundStyle(foregroundColor)
                .shadow(color: isHovered ? Color.black.opacity(0.06) : Color.clear, radius: 2, x: 0, y: 1)
                .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hover
            }
        }
        .help(helpText ?? "")
    }

    private var backgroundColor: Color {
        if isActive {
            return isHovered ? Color.accentColor.opacity(0.24) : Color.accentColor.opacity(0.16)
        } else {
            return isHovered ? Color.primary.opacity(0.09) : Color.primary.opacity(0.04)
        }
    }

    private var borderColor: Color {
        if isActive {
            return Color.accentColor.opacity(isHovered ? 0.45 : 0.3)
        } else {
            return isHovered ? Color.primary.opacity(0.12) : Color.clear
        }
    }

    private var foregroundColor: Color {
        if isActive {
            return Color.accentColor
        } else {
            return isHovered ? Color.primary : Color.primary.opacity(0.82)
        }
    }
}

/// 现代化极简精致工具栏下拉菜单
private struct ModernToolbarMenu<Content: View, LabelContent: View>: View {
    var isActive: Bool = false
    var fixedWidth: CGFloat? = nil
    var helpText: String? = nil
    @ViewBuilder let menuContent: () -> Content
    @ViewBuilder let labelContent: () -> LabelContent

    @State private var isHovered: Bool = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            labelContent()
                .frame(width: fixedWidth, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .foregroundStyle(foregroundColor)
                .shadow(color: isHovered ? Color.black.opacity(0.06) : Color.clear, radius: 2, x: 0, y: 1)
                .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .menuStyle(.borderlessButton)
        .frame(width: fixedWidth)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hover
            }
        }
        .help(helpText ?? "")
    }

    private var backgroundColor: Color {
        if isActive {
            return isHovered ? Color.accentColor.opacity(0.24) : Color.accentColor.opacity(0.16)
        } else {
            return isHovered ? Color.primary.opacity(0.09) : Color.primary.opacity(0.04)
        }
    }

    private var borderColor: Color {
        if isActive {
            return Color.accentColor.opacity(isHovered ? 0.45 : 0.3)
        } else {
            return isHovered ? Color.primary.opacity(0.12) : Color.clear
        }
    }

    private var foregroundColor: Color {
        if isActive {
            return Color.accentColor
        } else {
            return isHovered ? Color.primary : Color.primary.opacity(0.82)
        }
    }
}

/// 细粒度分组垂直分割线
private struct ModernToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
    }
}
