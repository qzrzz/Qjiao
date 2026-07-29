//
//  ImageBuild.types.swift
//  kero
//
//  ImageBuild 功能的类型定义：输出格式、缩放模式、处理选项与结果。
//

import Foundation

// MARK: - 输出格式

/// 图片处理支持的输出格式（目标：webp / jpg / png / jxl）。
enum ImageOutputFormat: String, CaseIterable, Identifiable, Sendable, Hashable {
    case webp
    case jpeg
    case png
    case jxl

    var id: String { rawValue }

    /// 菜单 / 界面展示名
    var title: String {
        switch self {
        case .webp: return "WebP"
        case .jpeg: return "JPG"
        case .png: return "PNG"
        case .jxl: return "JXL"
        }
    }

    /// 文件扩展名（小写）
    var pathExtension: String {
        switch self {
        case .webp: return "webp"
        case .jpeg: return "jpg"
        case .png: return "png"
        case .jxl: return "jxl"
        }
    }

    /// 是否为有损可控质量格式
    var isLossy: Bool {
        switch self {
        case .jpeg, .webp, .jxl: return true
        case .png: return false
        }
    }

    /// 编码后端说明（UI 展示）
    var encoderNote: String {
        switch self {
        case .webp: return "cwebp"
        case .jpeg: return "cjpegli / ImageIO"
        case .png: return "ImageIO + oxipng"
        case .jxl: return "cjxl"
        }
    }

    /// 从路径扩展名推断格式；无法识别时返回 nil。
    static func fromPathExtension(_ ext: String) -> ImageOutputFormat? {
        switch ext.lowercased() {
        case "webp": return .webp
        case "jpg", "jpeg", "jpe": return .jpeg
        case "png": return .png
        case "jxl": return .jxl
        default: return nil
        }
    }
}

// MARK: - 缩放模式

/// 图片尺寸调整模式。
enum ImageResizeMode: Equatable, Sendable {
    /// 保持原尺寸
    case none
    /// 按百分比缩放（100 = 原尺寸）
    case percent(Double)
    /// 指定宽高；`keepAspect` 为 true 时按最长边适配，另一维按比例。
    case exact(width: Int?, height: Int?, keepAspect: Bool)
    /// 最长边不超过给定像素（等比缩小，已更小则不变）
    case maxEdge(Int)
}

// MARK: - PNG 压缩策略

/// PNG 压缩策略：无损 oxipng / 有损量化 + 无损。
enum ImagePNGCompressMode: String, CaseIterable, Identifiable, Sendable {
    /// 仅 oxipng 无损优化
    case lossless
    /// pngquant 量化后再 oxipng
    case quantizeThenLossless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lossless: return "Lossless (oxipng)"
        case .quantizeThenLossless: return "Quantize + oxipng"
        }
    }
}

// MARK: - 压缩 UI 模式与简单预设

/// 压缩面板：简单（三档预设）/ 高级（细调参数）。
enum ImageBuildCompressUIMode: String, CaseIterable, Identifiable, Sendable {
    case simple
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: return L10n.t("Simple")
        case .advanced: return L10n.t("Advanced")
        }
    }
}

/// 简单模式三档质量预设（各格式映射到合理编码器参数）。
enum ImageBuildQualityPreset: String, CaseIterable, Identifiable, Sendable {
    /// 优先体积
    case smallest
    /// 体积与画质折中（默认）
    case balanced
    /// 优先画质
    case highQuality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smallest: return L10n.t("Smallest")
        case .balanced: return L10n.t("Balanced")
        case .highQuality: return L10n.t("High Quality")
        }
    }

    var subtitle: String {
        switch self {
        case .smallest: return L10n.t("Prioritize size")
        case .balanced: return L10n.t("Size & quality")
        case .highQuality: return L10n.t("Prioritize quality")
        }
    }

    var systemImage: String {
        switch self {
        case .smallest: return "arrow.down.circle"
        case .balanced: return "scale.3d"
        case .highQuality: return "sparkles"
        }
    }

    /// 将本预设写入 `options` 的编码参数字段（不改路径 / 格式 / 缩放）。
    /// - Parameter forcePNGQuantize: 简单模式「有损压缩 PNG」勾选时，任意档位都做颜色量化。
    func apply(to options: inout ImageBuildOptions, forcePNGQuantize: Bool = false) {
        options.stripMetadata = true
        switch options.format {
        case .jpeg:
            switch self {
            case .smallest:
                // 推荐下限约 68，再低伪影明显
                options.jpegQuality = 68
            case .balanced:
                options.jpegQuality = 85
            case .highQuality:
                options.jpegQuality = 95
            }

        case .webp:
            switch self {
            case .smallest:
                options.webpLossless = false
                options.webpQuality = 55
            case .balanced:
                options.webpLossless = false
                options.webpQuality = 80
            case .highQuality:
                // 有损高画质；无损体积往往更大，留给高级模式
                options.webpLossless = false
                options.webpQuality = 92
            }

        case .jxl:
            switch self {
            case .smallest:
                options.jxlQuality = 70
                options.jxlEffort = 7
            case .balanced:
                options.jxlQuality = 90
                options.jxlEffort = 7
            case .highQuality:
                options.jxlQuality = 96
                options.jxlEffort = 8
            }

        case .png:
            applyPNG(to: &options, forceQuantize: forcePNGQuantize)
        }
    }

    /// PNG：默认各档无损 oxipng；勾选有损时三档均量化，颜色数/质量随档位升高。
    private func applyPNG(to options: inout ImageBuildOptions, forceQuantize: Bool) {
        if forceQuantize {
            options.pngCompressMode = .quantizeThenLossless
            switch self {
            case .smallest:
                options.pngQuantColors = 128
                options.pngQuantQualityMin = 40
                options.pngQuantQualityMax = 75
                options.pngOptLevel = 4
            case .balanced:
                options.pngQuantColors = 192
                options.pngQuantQualityMin = 65
                options.pngQuantQualityMax = 90
                options.pngOptLevel = 2
            case .highQuality:
                options.pngQuantColors = 256
                options.pngQuantQualityMin = 80
                options.pngQuantQualityMax = 95
                options.pngOptLevel = 3
            }
        } else {
            options.pngCompressMode = .lossless
            options.pngQuantColors = 256
            options.pngQuantQualityMin = 65
            options.pngQuantQualityMax = 90
            switch self {
            case .smallest:
                options.pngOptLevel = 4
            case .balanced:
                options.pngOptLevel = 2
            case .highQuality:
                options.pngOptLevel = 4
            }
        }
    }
}

// MARK: - 处理选项

/// 一次 ImageBuild 任务的全部配置。
struct ImageBuildOptions: Equatable, Sendable {
    /// 源文件绝对路径
    var sourcePath: String
    /// 输出文件绝对路径
    var outputPath: String
    /// 输出格式
    var format: ImageOutputFormat
    /// 尺寸调整
    var resize: ImageResizeMode
    /// JPEG 质量（1…100），映射到 cjpegli `--quality`
    var jpegQuality: Int
    /// WebP 质量（0…100），映射到 cwebp `-q`
    var webpQuality: Int
    /// WebP 是否无损（`-lossless`）
    var webpLossless: Bool
    /// JXL 质量（0…100），映射到 cjxl `--quality`；100 为数学无损
    var jxlQuality: Int
    /// JXL 编码 effort（1…10）
    var jxlEffort: Int
    /// oxipng 优化等级 0…6
    var pngOptLevel: Int
    /// PNG 压缩策略
    var pngCompressMode: ImagePNGCompressMode
    /// pngquant 目标颜色数（2…256）
    var pngQuantColors: Int
    /// pngquant 质量区间下限（0…100）
    var pngQuantQualityMin: Int
    /// pngquant 质量区间上限（0…100）
    var pngQuantQualityMax: Int
    /// 是否剥离 PNG 非关键元数据（oxipng `-s`）
    var stripMetadata: Bool

    /// 使用源路径与格式生成默认选项。
    static func defaults(sourcePath: String, format: ImageOutputFormat? = nil) -> ImageBuildOptions {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let resolvedFormat = format
            ?? ImageOutputFormat.fromPathExtension(sourceURL.pathExtension)
            ?? .png
        let outputPath = ImageBuildOptions.defaultOutputPath(
            sourcePath: sourcePath,
            format: resolvedFormat
        )
        return ImageBuildOptions(
            sourcePath: sourcePath,
            outputPath: outputPath,
            format: resolvedFormat,
            resize: .none,
            jpegQuality: 85,
            webpQuality: 80,
            webpLossless: false,
            jxlQuality: 90,
            jxlEffort: 7,
            pngOptLevel: 2,
            pngCompressMode: .lossless,
            pngQuantColors: 256,
            pngQuantQualityMin: 65,
            pngQuantQualityMax: 90,
            stripMetadata: true
        )
    }

    /// 在源文件旁生成默认输出路径：`name.built.ext`。
    static func defaultOutputPath(sourcePath: String, format: ImageOutputFormat) -> String {
        let url = URL(fileURLWithPath: sourcePath)
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        return dir
            .appendingPathComponent("\(base).built.\(format.pathExtension)")
            .path
    }
}

// MARK: - 处理结果

/// ImageBuild 任务执行结果。
struct ImageBuildResult: Sendable, Equatable {
    /// 是否成功写出输出文件
    var success: Bool
    /// 最终输出路径
    var outputPath: String?
    /// 源文件字节数
    var originalBytes: Int64
    /// 输出文件字节数
    var outputBytes: Int64
    /// 输出像素宽
    var outputWidth: Int
    /// 输出像素高
    var outputHeight: Int
    /// 成功时的摘要信息
    var message: String?
    /// 失败原因
    var errorMessage: String?

    /// 相对源文件的体积变化比例（负值表示变小）；源为 0 时为 nil。
    var sizeDeltaRatio: Double? {
        guard originalBytes > 0 else { return nil }
        return Double(outputBytes - originalBytes) / Double(originalBytes)
    }
}

// MARK: - 错误

/// ImageBuild 可抛出的业务错误。
enum ImageBuildError: Error, LocalizedError, Sendable {
    case sourceNotFound(String)
    case cannotLoadImage(String)
    case invalidResize
    case encodeFailed(String)
    case vendorToolMissing(String)
    case vendorToolFailed(tool: String, detail: String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "Source image not found: \(path)"
        case .cannotLoadImage(let detail):
            return "Cannot load image: \(detail)"
        case .invalidResize:
            return "Invalid resize parameters"
        case .encodeFailed(let detail):
            return "Encode failed: \(detail)"
        case .vendorToolMissing(let name):
            return "Vendor tool not found: \(name). Install via Homebrew or place in kero/VendorBin."
        case .vendorToolFailed(let tool, let detail):
            return "\(tool) failed: \(detail)"
        case .writeFailed(let detail):
            return "Write failed: \(detail)"
        }
    }
}

// MARK: - 工具可用性

/// 各编码 CLI 是否可用（UI 角标）。
struct ImageBuildToolAvailability: Sendable, Equatable {
    var cjpegli: Bool
    var oxipng: Bool
    var pngquant: Bool
    var cwebp: Bool
    var cjxl: Bool
}
