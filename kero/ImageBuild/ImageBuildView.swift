//
//  ImageBuildView.swift
//  kero
//
//  ImageBuild 面板：统一批量（1 张或 N 张输入）；简单·高级压缩；变体表与模板。
//

import AppKit
import SwiftUI

/// ImageBuild 设置与导出弹窗。
struct ImageBuildView: View {
    let session: ImageBuildSession
    var onDismiss: (_ primaryOutputPath: String?) -> Void

    // MARK: - State

    @State private var format: ImageOutputFormat = .png

    @State private var compressUIMode: ImageBuildCompressUIMode = .simple
    @State private var qualityPreset: ImageBuildQualityPreset = .balanced
    @State private var lossyPNG: Bool = false
    @State private var simplePNGQuantQualityMin: Int = 65
    @State private var simplePNGQuantQualityMax: Int = 90

    @State private var jpegQuality: Double = 85
    @State private var webpQuality: Double = 80
    @State private var webpLossless: Bool = false
    @State private var jxlQuality: Double = 90
    @State private var jxlEffort: Double = 7
    @State private var pngOptLevel: Double = 2
    @State private var pngCompressMode: ImagePNGCompressMode = .lossless
    @State private var pngQuantColors: Double = 256
    @State private var stripMetadata: Bool = true

    /// 导出变体（默认 1x + _build，用户修改后持久化）
    @State private var variants: [ImageExportVariant] = ImageBuildExportPreferences.loadVariants()
    @State private var outputDirectory: String = ""
    /// 当导出将覆盖原文时，须勾选此项才能真正开始
    @State private var allowOverwriteSource: Bool = false
    /// 未勾选覆盖却点了开始：高亮 + 抖动提示
    @State private var overwriteNeedsAttention: Bool = false
    @State private var overwriteShakeOffset: CGFloat = 0
    /// 跳过下一次 variants 自动保存（避免 init/加载时写盘）
    @State private var suppressVariantPersist: Bool = false

    @State private var isBuilding: Bool = false
    /// 当前完成项序号（1-based，处理中）
    @State private var buildProgressCurrent: Int = 0
    /// 总任务数
    @State private var buildProgressTotal: Int = 0
    @State private var resultMessage: String?
    @State private var resultError: String?
    @State private var lastRevealPath: String?

    /// 多图时当前聚焦的源图下标
    @State private var focusedSourceIndex: Int = 0
    /// 路径 → 缩略图（异步填充）
    @State private var thumbnailCache: [String: NSImage] = [:]
    /// 路径 → 像素尺寸
    @State private var sizeCache: [String: (width: Int, height: Int)] = [:]

    private let tools: ImageBuildToolAvailability
    private let sourcePaths: [String]
    private let primaryImage: NSImage?
    private let primaryPixelSize: (width: Int, height: Int)

    /// Asset Catalog 矢量图标（模板渲染，随 tint 变色）
    private static let iconName = "ImageBuild"
    private static let labelWidth: CGFloat = 82
    /// 多图缩略图边长
    private static let batchThumbSize: CGFloat = 48
    /// 缩略图最多预加载数量
    private static let batchThumbLoadLimit = 48

    // MARK: - Init

    init(
        sourcePath: String,
        sourceImage: NSImage,
        onDismiss: @escaping (_ outputPath: String?) -> Void
    ) {
        self.init(
            session: .fromViewer(path: sourcePath),
            previewImage: sourceImage,
            onDismiss: onDismiss
        )
    }

    init(
        session: ImageBuildSession,
        previewImage: NSImage? = nil,
        onDismiss: @escaping (_ outputPath: String?) -> Void
    ) {
        self.session = session
        self.onDismiss = onDismiss
        self.sourcePaths = session.sourcePaths

        let first = session.sourcePaths.first ?? ""
        if let previewImage {
            primaryImage = previewImage
            primaryPixelSize = ImageResize.pixelSize(of: previewImage)
        } else if let img = NSImage(contentsOfFile: first) {
            primaryImage = img
            primaryPixelSize = ImageResize.pixelSize(of: img)
        } else {
            primaryImage = nil
            primaryPixelSize = (0, 0)
        }

        if let firstPath = session.sourcePaths.first {
            let dir = URL(fileURLWithPath: firstPath).deletingLastPathComponent().path
            _outputDirectory = State(initialValue: dir)
            let fmt = ImageOutputFormat.fromPathExtension(
                URL(fileURLWithPath: firstPath).pathExtension
            ) ?? .png
            _format = State(initialValue: fmt)
        }

        // 导出设置：默认 1x/_build，或用户上次修改后的记忆
        _variants = State(initialValue: ImageBuildExportPreferences.loadVariants())

        tools = ImageBuild.toolAvailability()
    }

    // MARK: - Body

    private static let overwriteToggleScrollID = "imagebuild.overwriteToggle"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        sourceCard
                        settingsCard
                        exportCard
                    }
                    .padding(12)
                }
                .background(ScrollWheelBlocker())
                .onChange(of: overwriteNeedsAttention) { _, needs in
                    if needs {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(Self.overwriteToggleScrollID, anchor: .center)
                        }
                    }
                }
            }
            // 进度 / 完成 / 错误固定在窗口下部，不随内容滚动
            statusBar
            Divider()
            footer
        }
        .frame(width: 450, height: sheetHeight)
        .onAppear {
            applySimplePreset(qualityPreset)
            if sourcePaths.count > 1 { Task { await loadBatchThumbnails() } }
        }
        .onChange(of: format) { _, _ in
            if compressUIMode == .simple { applySimplePreset(qualityPreset) }
        }
        .onChange(of: qualityPreset) { _, p in
            if compressUIMode == .simple { applySimplePreset(p) }
        }
        .onChange(of: lossyPNG) { _, _ in
            if compressUIMode == .simple { applySimplePreset(qualityPreset) }
        }
        .onChange(of: compressUIMode) { _, m in
            if m == .simple { applySimplePreset(qualityPreset) }
        }
        // 配置变化后若不再覆盖原文，自动取消勾选与提示
        .onChange(of: wouldOverwriteSource) { _, risks in
            if !risks {
                allowOverwriteSource = false
                clearOverwriteAttention()
            }
        }
        .onChange(of: allowOverwriteSource) { _, allowed in
            if allowed { clearOverwriteAttention() }
        }
        // 用户改过导出行后记住（尺寸 / 后缀 / 增删 / 模板）
        .onChange(of: variants) { _, newValue in
            if suppressVariantPersist {
                suppressVariantPersist = false
                return
            }
            ImageBuildExportPreferences.saveVariants(newValue)
        }
    }

    private var sheetHeight: CGFloat {
        let base: CGFloat = compressUIMode == .simple ? 520 : 560
        let multiExtra: CGFloat = sourcePaths.count > 1 ? 56 : 0
        let extra = CGFloat(max(0, variants.count - 2)) * 28
        return min(720, base + multiExtra + extra)
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 8) {
            Image(Self.iconName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            Text(L10n.t("Image Build"))
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 8)

            Button {
                onDismiss(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("Close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 固定底栏上方的状态区：处理中 / 成功摘要 / 错误。
    @ViewBuilder
    private var statusBar: some View {
        if isBuilding || resultError != nil || resultMessage != nil {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Group {
                    if isBuilding {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.t("Processing…"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if buildProgressTotal > 0 {
                                Text("\(buildProgressCurrent)/\(buildProgressTotal)")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else if let resultError {
                        statusBanner(resultError, kind: .error)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else if let resultMessage {
                        HStack(alignment: .center, spacing: 8) {
                            statusBanner(resultMessage, kind: .success)
                            if lastRevealPath != nil {
                                Button(L10n.t("Reveal")) {
                                    if let path = lastRevealPath {
                                        NSWorkspace.shared.selectFile(
                                            path,
                                            inFileViewerRootedAtPath: ""
                                        )
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button(L10n.t("Cancel")) { onDismiss(nil) }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
            Button(isBuilding ? L10n.t("Processing…") : L10n.t("Start Build")) {
                requestStartBuild()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.regular)
            // 始终可点（非构建中且基础条件满足），覆盖校验在点击后用抖动提示
            .disabled(isBuilding || !canBuildBase)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Cards

    private var sourceCard: some View {
        card {
            // 多张：缩略图条；一张：单文件信息（同为批量语义）
            if sourcePaths.count > 1 {
                batchSourceContent
            } else {
                singleSourceContent
            }
        }
    }

    /// 单张：大缩略图 + 文件信息
    private var singleSourceContent: some View {
        HStack(spacing: 10) {
            sourceThumb(image: primaryImage, size: 44, highlighted: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(sourceSummaryTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .help(sourcePaths.first ?? "")
                metaLine(
                    width: primaryPixelSize.width,
                    height: primaryPixelSize.height,
                    path: sourcePaths.first
                )
            }
            Spacer(minLength: 0)
        }
    }

    /// 批量：横向缩略图条 + 当前项详情
    private var batchSourceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L10n.t("Source Images"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(sourcePaths.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(sourcePaths.enumerated()), id: \.offset) { index, path in
                        Button {
                            focusedSourceIndex = index
                        } label: {
                            batchThumbCell(path: path, index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }

            // 当前聚焦项详情（仅文件名与元数据，不用序号勾选，避免误解为处理进度/勾选态）
            if sourcePaths.indices.contains(focusedSourceIndex) {
                let path = sourcePaths[focusedSourceIndex]
                HStack(spacing: 8) {
                    sourceThumb(
                        image: thumbnailCache[path]
                            ?? (focusedSourceIndex == 0 ? primaryImage : nil),
                        size: 36,
                        highlighted: false
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .help(path)
                        let size = sizeCache[path]
                            ?? (focusedSourceIndex == 0 ? primaryPixelSize : (0, 0))
                        metaLine(width: size.width, height: size.height, path: path)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func batchThumbCell(path: String, index: Int) -> some View {
        let focused = focusedSourceIndex == index
        let img = thumbnailCache[path] ?? (index == 0 ? primaryImage : nil)
        return sourceThumb(image: img, size: Self.batchThumbSize, highlighted: focused)
            .help((path as NSString).lastPathComponent)
    }

    /// 缩略图；缩放使用像素插值（`.none`），小图放大不糊边。
    private func sourceThumb(image: NSImage?, size: CGFloat, highlighted: Bool) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .background(Color.primary.opacity(0.04))
            } else {
                ZStack {
                    Color.primary.opacity(0.04)
                    ProgressView()
                        .controlSize(.mini)
                }
                .frame(width: size, height: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    highlighted ? Color.primary.opacity(0.28) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    private func metaLine(width: Int, height: Int, path: String?) -> some View {
        HStack(spacing: 6) {
            if width > 0, height > 0 {
                Text("\(width)×\(height)")
                    .monospacedDigit()
            }
            if let path, let sizeLabel = fileSizeLabel(path: path) {
                if width > 0 { Text("·") }
                Text(sizeLabel)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// 后台加载批量缩略图与尺寸（限流，避免一次读太多大图）。
    @MainActor
    private func loadBatchThumbnails() async {
        let paths = Array(sourcePaths.prefix(Self.batchThumbLoadLimit))
        if let first = paths.first {
            if let primaryImage {
                thumbnailCache[first] = primaryImage
            }
            if primaryPixelSize.width > 0 {
                sizeCache[first] = primaryPixelSize
            }
        }

        await withTaskGroup(of: (String, NSImage?, (Int, Int)?).self) { group in
            for path in paths {
                group.addTask(priority: .utility) {
                    Self.loadThumbAndSize(path: path, maxPixel: 96)
                }
            }
            for await (path, image, size) in group {
                if let image {
                    thumbnailCache[path] = image
                }
                if let size {
                    sizeCache[path] = size
                }
            }
        }
    }

    /// 解码缩略图与像素尺寸（后台线程）。
    nonisolated private static func loadThumbAndSize(
        path: String,
        maxPixel: CGFloat
    ) -> (String, NSImage?, (Int, Int)?) {
        guard let image = NSImage(contentsOfFile: path) else {
            return (path, nil, nil)
        }
        // 像素尺寸
        var pixelW = Int(image.size.width.rounded())
        var pixelH = Int(image.size.height.rounded())
        if let rep = image.representations.first as? NSBitmapImageRep {
            pixelW = rep.pixelsWide
            pixelH = rep.pixelsHigh
        } else if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            pixelW = cg.width
            pixelH = cg.height
        }
        let size: (Int, Int)? = pixelW > 0 ? (pixelW, pixelH) : nil

        let pw = CGFloat(max(pixelW, 1))
        let ph = CGFloat(max(pixelH, 1))
        let scale = min(1, maxPixel / max(pw, ph))
        let tw = max(1, (pw * scale).rounded())
        let th = max(1, (ph * scale).rounded())
        let thumb = NSImage(size: NSSize(width: tw, height: th))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(
            in: NSRect(x: 0, y: 0, width: tw, height: th),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        thumb.unlockFocus()
        return (path, thumb, size)
    }

    private var settingsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                labeledRow(L10n.t("Format")) {
                    Picker("", selection: $format) {
                        ForEach(ImageOutputFormat.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }

                labeledRow(L10n.t("Compression")) {
                    Picker("", selection: $compressUIMode) {
                        ForEach(ImageBuildCompressUIMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 160, alignment: .leading)
                    Spacer(minLength: 0)
                }

                if compressUIMode == .simple {
                    Picker("", selection: $qualityPreset) {
                        ForEach(ImageBuildQualityPreset.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)

                    if format == .png {
                        Toggle(L10n.t("Lossy PNG (quantize colors)"), isOn: $lossyPNG)
                            .font(.system(size: 11))
                            .toggleStyle(.checkbox)
                    }
                } else {
                    advancedCompressBlock
                }

                if let warning = formatAvailabilityWarning {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedCompressBlock: some View {
        switch format {
        case .jpeg:
            compactSlider(L10n.t("Quality"), value: $jpegQuality, range: 1...100)
        case .webp:
            Toggle(L10n.t("Lossless"), isOn: $webpLossless)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
            if !webpLossless {
                compactSlider(L10n.t("Quality"), value: $webpQuality, range: 0...100)
            }
        case .jxl:
            compactSlider(L10n.t("Quality"), value: $jxlQuality, range: 0...100)
            compactSlider(L10n.t("Effort"), value: $jxlEffort, range: 1...10)
        case .png:
            Picker("", selection: $pngCompressMode) {
                Text(L10n.t("Lossless")).tag(ImagePNGCompressMode.lossless)
                Text(L10n.t("Quantize")).tag(ImagePNGCompressMode.quantizeThenLossless)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            compactSlider(L10n.t("Level"), value: $pngOptLevel, range: 0...6)
            if pngCompressMode == .quantizeThenLossless {
                compactSlider(L10n.t("Colors"), value: $pngQuantColors, range: 2...256)
            }
            Toggle(L10n.t("Strip metadata"), isOn: $stripMetadata)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
        }
    }

    private var exportCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L10n.t("Export"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(L10n.format("%d items", variants.count))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Menu {
                        ForEach(ImageExportTemplate.all) { tpl in
                            Button {
                                // 整表替换，不追加到现有行
                                applyExportTemplate(tpl)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(tpl.title)
                                    Text(tpl.detail)
                                        .font(.caption)
                                }
                            }
                        }
                    } label: {
                        Label(L10n.t("Templates"), systemImage: "square.grid.2x2")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.t("Replace current export settings with a template"))

                    Button {
                        variants.append(ImageExportVariant(sizeText: "1x", suffix: "_build"))
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("Add an export row"))
                }

                // 表头
                HStack(spacing: 6) {
                    Text(L10n.t("Size"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.t("Suffix"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 18)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)

                VStack(spacing: 4) {
                    ForEach($variants) { $row in
                        HStack(spacing: 6) {
                            // 尺寸：可输入 + 预置下拉
                            sizeFieldWithPresets(text: $row.sizeText)
                            TextField("", text: $row.suffix)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11).monospaced())
                            Button {
                                guard variants.count > 1 else { return }
                                variants.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(
                                        variants.count > 1
                                            ? Color.secondary
                                            : Color.secondary.opacity(0.35)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(variants.count <= 1)
                            .frame(width: 18)
                        }
                    }
                }

                if let name = outputFileNamePreview {
                    Text(L10n.format("Filename preview: %@", name))
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(name)
                }

                if wouldOverwriteSource {
                    Toggle(isOn: $allowOverwriteSource) {
                        Text(L10n.t("Overwrite source file"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(overwriteNeedsAttention ? Color.yellow : Color.primary)
                    }
                    .toggleStyle(.checkbox)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                overwriteNeedsAttention
                                    ? Color.yellow.opacity(0.22)
                                    : Color.clear
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                overwriteNeedsAttention
                                    ? Color.yellow.opacity(0.85)
                                    : Color.clear,
                                lineWidth: 1.5
                            )
                    )
                    .offset(x: overwriteShakeOffset)
                    .id(Self.overwriteToggleScrollID)
                    .help(L10n.t("Export settings will overwrite source files; check this box to allow processing"))
                }

                Divider().opacity(0.5)

                HStack(spacing: 6) {
                    Text(L10n.t("Directory"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    TextField("", text: $outputDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button(L10n.t("Choose…")) { chooseOutputDirectory() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Shared chrome

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    private func labeledRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
    }

    private func statusBanner(_ text: String, kind: BannerKind) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(kind == .error ? Color.red : Color.secondary)
            .monospacedDigit()
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private enum BannerKind {
        case error, success
    }

    // MARK: - Derived

    private var sourceSummaryTitle: String {
        if sourcePaths.count == 1 {
            return (sourcePaths[0] as NSString).lastPathComponent
        }
        return L10n.format("%d selected images", sourcePaths.count)
    }

    private func fileSizeLabel(path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// 当前聚焦源图 + 首行变体将生成的文件名（与 buildBatch 命名一致）。
    private var outputFileNamePreview: String? {
        guard let variant = variants.first else { return nil }
        let path: String
        if sourcePaths.indices.contains(focusedSourceIndex) {
            path = sourcePaths[focusedSourceIndex]
        } else if let first = sourcePaths.first {
            path = first
        } else {
            return nil
        }
        let resolved = ImageBuild.resolveOutputPath(
            sourcePath: path,
            variant: variant,
            format: format,
            outputDirectory: outputDirectory.isEmpty ? nil : outputDirectory
        )
        return (resolved.path as NSString).lastPathComponent
    }

    /// 当前导出配置是否会使任一输出覆盖源文件。
    private var wouldOverwriteSource: Bool {
        ImageBuild.wouldOverwriteAnySource(
            sourcePaths: sourcePaths,
            variants: variants,
            format: format,
            outputDirectory: outputDirectory.isEmpty ? nil : outputDirectory
        )
    }

    /// 基础可构建条件（不含覆盖确认；覆盖在点击开始时提示）。
    private var canBuildBase: Bool {
        guard !sourcePaths.isEmpty, !variants.isEmpty else { return false }
        switch format {
        case .webp: return tools.cwebp
        case .jxl: return tools.cjxl
        case .jpeg, .png: return true
        }
    }

    /// 点击「开始处理」：缺覆盖确认时滚动+黄色抖动，不开始任务。
    private func requestStartBuild() {
        guard canBuildBase, !isBuilding else { return }
        if wouldOverwriteSource && !allowOverwriteSource {
            promptOverwriteConfirmation()
            return
        }
        clearOverwriteAttention()
        Task { await runBuild() }
    }

    /// 高亮覆盖勾选、抖动，并滚到可见（由 ScrollViewReader onChange 驱动 scrollTo）。
    private func promptOverwriteConfirmation() {
        // 先关再开，保证再次点击仍会触发 scrollTo
        overwriteNeedsAttention = false
        overwriteShakeOffset = 0
        DispatchQueue.main.async {
            overwriteNeedsAttention = true
            // 抖动：左右快速偏移
            let sequence: [CGFloat] = [0, -8, 8, -6, 6, -3, 3, 0]
            for (i, x) in sequence.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.035 * Double(i)) {
                    withAnimation(.linear(duration: 0.03)) {
                        overwriteShakeOffset = x
                    }
                }
            }
        }
    }

    private func clearOverwriteAttention() {
        overwriteNeedsAttention = false
        overwriteShakeOffset = 0
    }

    private var formatAvailabilityWarning: String? {
        switch format {
        case .webp where !tools.cwebp:
            return L10n.t("Cannot export WebP currently")
        case .jxl where !tools.cjxl:
            return L10n.t("Cannot export JXL currently")
        default:
            return nil
        }
    }

    // MARK: - Build

    private func makeTemplateOptions() -> ImageBuildOptions {
        if compressUIMode == .simple {
            applySimplePreset(qualityPreset)
        }
        var opts = ImageBuildOptions.defaults(
            sourcePath: sourcePaths.first ?? "/tmp/x.png",
            format: format
        )
        opts.format = format
        opts.jpegQuality = Int(jpegQuality)
        opts.webpQuality = Int(webpQuality)
        opts.webpLossless = webpLossless
        opts.jxlQuality = Int(jxlQuality)
        opts.jxlEffort = Int(jxlEffort)
        opts.pngOptLevel = Int(pngOptLevel)
        opts.pngCompressMode = pngCompressMode
        opts.pngQuantColors = Int(pngQuantColors)
        opts.pngQuantQualityMin = simplePNGQuantQualityMin
        opts.pngQuantQualityMax = simplePNGQuantQualityMax
        opts.stripMetadata = stripMetadata
        opts.resize = .none
        return opts
    }

    @MainActor
    private func runBuild() async {
        isBuilding = true
        resultError = nil
        resultMessage = nil
        lastRevealPath = nil
        let total = max(1, sourcePaths.count * max(1, variants.count))
        buildProgressCurrent = 0
        buildProgressTotal = total

        let template = makeTemplateOptions()
        let dir = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

        let batch = await ImageBuild.buildBatch(
            sourcePaths: sourcePaths,
            template: template,
            variants: variants,
            outputDirectory: dir.isEmpty ? nil : dir,
            allowOverwriteSource: allowOverwriteSource,
            onProgress: { current, total in
                buildProgressCurrent = current
                buildProgressTotal = total
            }
        )

        isBuilding = false
        buildProgressCurrent = batch.results.count
        buildProgressTotal = max(buildProgressTotal, batch.results.count)
        if batch.failureCount == batch.results.count {
            resultError = batch.results.compactMap(\.errorMessage).first ?? L10n.t("Processing failed")
            resultMessage = nil
        } else {
            resultMessage = batch.summaryMessage
            resultError = batch.failureCount > 0
                ? batch.results.compactMap(\.errorMessage).first
                : nil
            lastRevealPath = batch.results.reversed().compactMap(\.outputPath).first
        }
    }

    // MARK: - Helpers

    /// 用模板**完整替换**当前导出变体表（不追加）；每行新 UUID 以免列表复用旧行。
    private func applyExportTemplate(_ template: ImageExportTemplate) {
        variants = template.rows.map { row in
            ImageExportVariant(
                id: UUID(),
                sizeText: row.sizeText,
                suffix: row.suffix
            )
        }
        // onChange(variants) 会持久化本次模板选择
        allowOverwriteSource = false
        clearOverwriteAttention()
    }

    /// 尺寸：可输入（含 100x200）+ 预置下拉。
    private func sizeFieldWithPresets(text: Binding<String>) -> some View {
        HStack(spacing: 0) {
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospacedDigit())
            Menu {
                ForEach(ImageExportVariant.sizePresets, id: \.self) { preset in
                    Button(preset) {
                        text.wrappedValue = preset
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(L10n.t("Preset sizes"))
        }
    }

    private func compactSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func applySimplePreset(_ preset: ImageBuildQualityPreset) {
        var options = ImageBuildOptions.defaults(
            sourcePath: sourcePaths.first ?? "/tmp/x.png",
            format: format
        )
        options.format = format
        preset.apply(to: &options, forcePNGQuantize: format == .png && lossyPNG)
        jpegQuality = Double(options.jpegQuality)
        webpQuality = Double(options.webpQuality)
        webpLossless = options.webpLossless
        jxlQuality = Double(options.jxlQuality)
        jxlEffort = Double(options.jxlEffort)
        pngOptLevel = Double(options.pngOptLevel)
        pngCompressMode = options.pngCompressMode
        pngQuantColors = Double(options.pngQuantColors)
        stripMetadata = options.stripMetadata
        simplePNGQuantQualityMin = options.pngQuantQualityMin
        simplePNGQuantQualityMax = options.pngQuantQualityMax
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: outputDirectory.isEmpty ? NSHomeDirectory() : outputDirectory
        )
        panel.begin { response in
            if response == .OK, let url = panel.url {
                outputDirectory = url.path
            }
        }
    }
}

// MARK: - 滚轮隔离

/// 在 sheet 内吞掉 scrollWheel，防止穿透到背后 ImageViewer 的缩放逻辑。
private struct ScrollWheelBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollWheelBlockerNSView {
        ScrollWheelBlockerNSView()
    }

    func updateNSView(_ nsView: ScrollWheelBlockerNSView, context: Context) {}

    final class ScrollWheelBlockerNSView: NSView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }

        override var acceptsFirstResponder: Bool { true }
    }
}
