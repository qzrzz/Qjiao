//
//  ImageBuild.swift
//  kero
//
//  图片处理入口：缩放 + 格式转换（webp / jpg / png / jxl）+ 压缩。
//
//  编码路径：
//  - PNG  → ImageIO 写出 → 可选 pngquant → oxipng
//  - JPG  → cjpegli（失败回退 ImageIO）
//  - WebP → cwebp（macOS ImageIO 无法写出 WebP）
//  - JXL  → cjxl（macOS ImageIO 无法写出 JXL）
//

import AppKit
import Foundation

/// ImageBuild 功能门面：串联缩放 → 编码 / 压缩流水线。
enum ImageBuild {
    /// 支持作为输入的图片扩展名。
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "jxl", "tiff", "tif", "bmp", "icns",
    ]

    /// 是否为可处理的图片扩展名。
    static func supportsImageExtension(_ ext: String) -> Bool {
        imageExtensions.contains(ext.lowercased())
    }

    /// 执行一次完整的图片构建任务。
    static func build(_ options: ImageBuildOptions) async -> ImageBuildResult {
        do {
            return try await buildThrowing(options)
        } catch let error as ImageBuildError {
            return failureResult(options: options, message: error.errorDescription)
        } catch {
            return failureResult(options: options, message: error.localizedDescription)
        }
    }

    /// 可抛出版本。
    static func buildThrowing(_ options: ImageBuildOptions) async throws -> ImageBuildResult {
        let sourcePath = options.sourcePath
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw ImageBuildError.sourceNotFound(sourcePath)
        }

        let originalBytes = fileSize(sourcePath)

        guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
            throw ImageBuildError.cannotLoadImage(sourcePath)
        }

        // 1. 缩放
        let workingImage = try ImageResize.apply(sourceImage, mode: options.resize)
        let (outW, outH) = ImageResize.pixelSize(of: workingImage)

        // 2. 按格式编码
        switch options.format {
        case .jpeg:
            try await encodeJPEG(workingImage: workingImage, options: options)
        case .png:
            try await encodePNG(workingImage: workingImage, options: options)
        case .webp:
            try await encodeWebP(workingImage: workingImage, options: options)
        case .jxl:
            try await encodeJXL(workingImage: workingImage, options: options)
        }

        let outputPath = options.outputPath
        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw ImageBuildError.writeFailed("Output missing after build: \(outputPath)")
        }

        let outputBytes = fileSize(outputPath)
        let saved = originalBytes > 0
            ? Double(originalBytes - outputBytes) / Double(originalBytes) * 100.0
            : 0
        let sizeLabel = ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
        let origLabel = ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file)
        let deltaText: String
        if outputBytes <= originalBytes {
            deltaText = String(format: "saved %.1f%%", saved)
        } else {
            deltaText = String(format: "grew %.1f%%", -saved)
        }

        return ImageBuildResult(
            success: true,
            outputPath: outputPath,
            originalBytes: originalBytes,
            outputBytes: outputBytes,
            outputWidth: outW,
            outputHeight: outH,
            message: "\(options.format.title) · \(outW)×\(outH) · \(origLabel) → \(sizeLabel) (\(deltaText))",
            errorMessage: nil
        )
    }

    /// 探测各 Vendor / 系统工具是否可用。
    static func toolAvailability() -> ImageBuildToolAvailability {
        VendorBinLocator.availability()
    }

    /// 解析某次导出的输出路径，以及是否与源路径相同（将覆盖原文）。
    static func resolveOutputPath(
        sourcePath: String,
        variant: ImageExportVariant,
        format: ImageOutputFormat,
        outputDirectory: String?
    ) -> (path: String, overwritesSource: Bool) {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outDir = (outputDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? sourceURL.deletingLastPathComponent().path
        let fileName = variant.outputFileName(baseName: baseName, format: format)
        let outputPath = (outDir as NSString).appendingPathComponent(fileName)
        let srcStd = (sourcePath as NSString).standardizingPath
        let outStd = (outputPath as NSString).standardizingPath
        return (outputPath, srcStd == outStd)
    }

    /// 当前配置是否会导致任一输出覆盖任一源文件。
    static func wouldOverwriteAnySource(
        sourcePaths: [String],
        variants: [ImageExportVariant],
        format: ImageOutputFormat,
        outputDirectory: String?
    ) -> Bool {
        let effectiveVariants: [ImageExportVariant] = variants.isEmpty
            ? [ImageExportVariant(sizeText: "1x", suffix: "")]
            : variants
        for sourcePath in sourcePaths {
            for variant in effectiveVariants {
                if resolveOutputPath(
                    sourcePath: sourcePath,
                    variant: variant,
                    format: format,
                    outputDirectory: outputDirectory
                ).overwritesSource {
                    return true
                }
            }
        }
        return false
    }

    /// 批量：多个源 × 可选变体表。
    /// - Parameters:
    ///   - sourcePaths: 输入路径列表
    ///   - template: 编码参数模板（路径会被覆盖）
    ///   - variants: 变体表；为空时每源输出一个 `name.built.ext`
    ///   - outputDirectory: 输出目录；nil 则与各自源同目录
    ///   - allowOverwriteSource: 为 true 时允许输出路径与源相同并覆盖；否则跳过该项
    ///   - onProgress: 每完成一项回调 `(current, total)`，在主线程更新 UI
    static func buildBatch(
        sourcePaths: [String],
        template: ImageBuildOptions,
        variants: [ImageExportVariant],
        outputDirectory: String?,
        allowOverwriteSource: Bool = false,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> ImageBuildBatchResult {
        var results: [ImageBuildResult] = []
        let effectiveVariants: [ImageExportVariant] = variants.isEmpty
            ? [ImageExportVariant(sizeText: "1x", suffix: "")]
            : variants

        // 总任务数 = 源文件数 × 变体行数（每项都会计入进度）
        let total = max(1, sourcePaths.count * effectiveVariants.count)
        var current = 0

        @MainActor
        func advanceProgress() async {
            current += 1
            onProgress?(current, total)
        }

        for sourcePath in sourcePaths {
            guard FileManager.default.fileExists(atPath: sourcePath) else {
                for _ in effectiveVariants {
                    results.append(
                        ImageBuildResult(
                            success: false,
                            outputPath: nil,
                            originalBytes: 0,
                            outputBytes: 0,
                            outputWidth: 0,
                            outputHeight: 0,
                            message: nil,
                            errorMessage: "找不到文件：\((sourcePath as NSString).lastPathComponent)"
                        )
                    )
                    await advanceProgress()
                }
                continue
            }
            guard let image = NSImage(contentsOfFile: sourcePath) else {
                for _ in effectiveVariants {
                    results.append(
                        ImageBuildResult(
                            success: false,
                            outputPath: nil,
                            originalBytes: fileSize(sourcePath),
                            outputBytes: 0,
                            outputWidth: 0,
                            outputHeight: 0,
                            message: nil,
                            errorMessage: "无法读取：\((sourcePath as NSString).lastPathComponent)"
                        )
                    )
                    await advanceProgress()
                }
                continue
            }

            let (sw, sh) = ImageResize.pixelSize(of: image)

            for variant in effectiveVariants {
                guard let resize = variant.resizeMode(sourceWidth: sw, sourceHeight: sh) else {
                    results.append(
                        ImageBuildResult(
                            success: false,
                            outputPath: nil,
                            originalBytes: fileSize(sourcePath),
                            outputBytes: 0,
                            outputWidth: 0,
                            outputHeight: 0,
                            message: nil,
                            errorMessage: "无法解析尺寸「\(variant.sizeText)」"
                        )
                    )
                    await advanceProgress()
                    continue
                }

                let resolved = resolveOutputPath(
                    sourcePath: sourcePath,
                    variant: variant,
                    format: template.format,
                    outputDirectory: outputDirectory
                )
                // 将覆盖原文但未勾选允许时，直接失败（UI 应已拦截开始）
                if resolved.overwritesSource && !allowOverwriteSource {
                    results.append(
                        ImageBuildResult(
                            success: false,
                            outputPath: nil,
                            originalBytes: fileSize(sourcePath),
                            outputBytes: 0,
                            outputWidth: 0,
                            outputHeight: 0,
                            message: nil,
                            errorMessage: "将覆盖原文件，请勾选「覆盖原文件」：\((sourcePath as NSString).lastPathComponent)"
                        )
                    )
                    await advanceProgress()
                    continue
                }

                var options = template
                options.sourcePath = sourcePath
                options.outputPath = resolved.path
                options.resize = resize

                let result = await build(options)
                results.append(result)
                await advanceProgress()
            }
        }

        return ImageBuildBatchResult(results: results)
    }

    // MARK: - Format pipelines

    /// JPEG：优先 cjpegli；不可用或失败时回退 ImageIO。
    private static func encodeJPEG(
        workingImage: NSImage,
        options: ImageBuildOptions
    ) async throws {
        let quality01 = Double(options.jpegQuality) / 100.0

        if VendorBinLocator.isAvailable(.cjpegli) {
            let tempPNG = try ImageConvert.writeTemporaryPNG(workingImage)
            defer { try? FileManager.default.removeItem(at: tempPNG) }
            do {
                try await ImageCompress.compressJPEG(
                    inputPath: tempPNG.path,
                    outputPath: options.outputPath,
                    quality: options.jpegQuality
                )
                return
            } catch {
                // 回退 ImageIO
            }
        }

        try ImageConvert.write(
            image: workingImage,
            format: .jpeg,
            to: options.outputPath,
            lossyQuality: quality01
        )
    }

    /// PNG：写出 → 可选 pngquant → oxipng。
    private static func encodePNG(
        workingImage: NSImage,
        options: ImageBuildOptions
    ) async throws {
        let outputPath = options.outputPath
        try ImageConvert.write(
            image: workingImage,
            format: .png,
            to: outputPath,
            lossyQuality: 1.0
        )

        var workingPath = outputPath

        if options.pngCompressMode == .quantizeThenLossless,
           VendorBinLocator.isAvailable(.pngquant) {
            let quantURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qjiao-imagebuild")
                .appendingPathComponent("\(UUID().uuidString)-q.png")
            try FileManager.default.createDirectory(
                at: quantURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try await ImageCompress.quantizePNG(
                    inputPath: workingPath,
                    outputPath: quantURL.path,
                    colors: options.pngQuantColors,
                    qualityMin: options.pngQuantQualityMin,
                    qualityMax: options.pngQuantQualityMax
                )
                if FileManager.default.fileExists(atPath: outputPath) {
                    try FileManager.default.removeItem(atPath: outputPath)
                }
                try FileManager.default.moveItem(atPath: quantURL.path, toPath: outputPath)
                workingPath = outputPath
            } catch {
                try? FileManager.default.removeItem(at: quantURL)
            }
        }

        if VendorBinLocator.isAvailable(.oxipng) {
            try await ImageCompress.optimizePNG(
                inputPath: workingPath,
                outputPath: nil,
                level: options.pngOptLevel,
                stripSafe: options.stripMetadata
            )
        }
    }

    /// WebP：临时 PNG → cwebp（必须）。
    private static func encodeWebP(
        workingImage: NSImage,
        options: ImageBuildOptions
    ) async throws {
        guard VendorBinLocator.isAvailable(.cwebp) else {
            throw ImageBuildError.vendorToolMissing("cwebp")
        }
        let tempPNG = try ImageConvert.writeTemporaryPNG(workingImage)
        defer { try? FileManager.default.removeItem(at: tempPNG) }
        try await ImageCompress.compressWebP(
            inputPath: tempPNG.path,
            outputPath: options.outputPath,
            quality: options.webpQuality,
            lossless: options.webpLossless
        )
    }

    /// JXL：临时 PNG → cjxl（必须）。
    private static func encodeJXL(
        workingImage: NSImage,
        options: ImageBuildOptions
    ) async throws {
        guard VendorBinLocator.isAvailable(.cjxl) else {
            throw ImageBuildError.vendorToolMissing("cjxl")
        }
        let tempPNG = try ImageConvert.writeTemporaryPNG(workingImage)
        defer { try? FileManager.default.removeItem(at: tempPNG) }
        try await ImageCompress.compressJXL(
            inputPath: tempPNG.path,
            outputPath: options.outputPath,
            quality: options.jxlQuality,
            effort: options.jxlEffort
        )
    }

    // MARK: - Helpers

    private static func fileSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    private static func failureResult(options: ImageBuildOptions, message: String?) -> ImageBuildResult {
        ImageBuildResult(
            success: false,
            outputPath: nil,
            originalBytes: fileSize(options.sourcePath),
            outputBytes: 0,
            outputWidth: 0,
            outputHeight: 0,
            message: nil,
            errorMessage: message
        )
    }
}
