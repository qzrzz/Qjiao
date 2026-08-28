//
//  ImageTrim.swift
//  kero
//
//  基于 Core Graphics 的周围透明像素裁剪工具。
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图像透明像素裁剪错误。
enum ImageTrimError: LocalizedError, Equatable {
    case cannotLoadImage
    case completelyTransparent
    case noTransparentMargins
    case cropFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .cannotLoadImage:
            return L10n.t("Failed to load image for trimming.")
        case .completelyTransparent:
            return L10n.t("The image is completely transparent.")
        case .noTransparentMargins:
            return L10n.t("No surrounding transparent pixels found.")
        case .cropFailed:
            return L10n.t("Failed to crop image.")
        case .saveFailed:
            return L10n.t("Failed to save trimmed image.")
        }
    }
}

/// 裁剪结果元数据。
struct ImageTrimResult: Sendable {
    let image: NSImage
    let originalWidth: Int
    let originalHeight: Int
    let trimmedWidth: Int
    let trimmedHeight: Int
    let cropRect: CGRect
}

/// 图片透明像素裁剪工具。
enum ImageTrim {
    /// 从文件 URL 读取图像并裁剪周围透明像素。
    /// - Parameters:
    ///   - fileURL: 图像文件 URL
    ///   - alphaThreshold: 视作透明的最大 Alpha 阈值 (0...255，默认为 0)
    /// - Returns: 裁剪结果
    static func trimTransparentPixels(
        at fileURL: URL,
        alphaThreshold: UInt8 = 0
    ) throws -> ImageTrimResult {
        // 先尝试通过 MaterialFileIconCatalog 或 NSImage 读取
        let image: NSImage?
        if fileURL.pathExtension.lowercased() == "svg" {
            image = MaterialFileIconCatalog.loadSizedImage(at: fileURL, pointSize: 512)
        } else {
            image = NSImage(contentsOf: fileURL)
                ?? MaterialFileIconCatalog.loadSizedImage(at: fileURL, pointSize: 512)
        }

        guard let image else {
            throw ImageTrimError.cannotLoadImage
        }

        return try trimTransparentPixels(from: image, alphaThreshold: alphaThreshold)
    }

    /// 从 NSImage 裁剪周围透明像素。
    /// - Parameters:
    ///   - image: 输入 NSImage
    ///   - alphaThreshold: 视作透明的最大 Alpha 阈值 (0...255，默认为 0，即仅 alpha == 0 视作透明)
    /// - Returns: 裁剪结果
    static func trimTransparentPixels(
        from image: NSImage,
        alphaThreshold: UInt8 = 0
    ) throws -> ImageTrimResult {
        guard let cgImage = ImageResize.cgImage(from: image) else {
            throw ImageTrimError.cannotLoadImage
        }
        return try trimTransparentPixels(from: cgImage, alphaThreshold: alphaThreshold)
    }

    /// 从 CGImage 裁剪周围透明像素。
    /// - Parameters:
    ///   - cgImage: 输入 CGImage
    ///   - alphaThreshold: 视作透明的最大 Alpha 阈值 (0...255，默认为 0)
    /// - Returns: 裁剪结果
    static func trimTransparentPixels(
        from cgImage: CGImage,
        alphaThreshold: UInt8 = 0
    ) throws -> ImageTrimResult {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw ImageTrimError.cannotLoadImage
        }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let totalBytes = bytesPerRow * height
        var pixelData = [UInt8](repeating: 0, count: totalBytes)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageTrimError.cannotLoadImage
        }

        // 将 CGImage 按 Top-Left 坐标系绘制，以便 row 0 对应顶行，row (height - 1) 对应底行
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1

        // 扫描所有像素以获取非透明像素边界
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let alpha = pixelData[rowStart + x * bytesPerPixel + 3]
                if alpha > alphaThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        // 1. 全透明检查
        if maxX < minX || maxY < minY {
            throw ImageTrimError.completelyTransparent
        }

        // 2. 四周无透明像素检查
        if minX == 0 && minY == 0 && maxX == width - 1 && maxY == height - 1 {
            throw ImageTrimError.noTransparentMargins
        }

        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        let cropRect = CGRect(x: minX, y: minY, width: cropWidth, height: cropHeight)

        guard let croppedCG = cgImage.cropping(to: cropRect) else {
            throw ImageTrimError.cropFailed
        }

        let trimmedNSImage = NSImage(cgImage: croppedCG, size: NSSize(width: cropWidth, height: cropHeight))
        return ImageTrimResult(
            image: trimmedNSImage,
            originalWidth: width,
            originalHeight: height,
            trimmedWidth: cropWidth,
            trimmedHeight: cropHeight,
            cropRect: cropRect
        )
    }

    /// 将 NSImage 编码为 PNG 格式并写入目标文件。
    static func writePNG(_ image: NSImage, to destinationURL: URL) throws {
        guard let cg = ImageResize.cgImage(from: image) else {
            throw ImageTrimError.saveFailed
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageTrimError.saveFailed
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageTrimError.saveFailed
        }
        try (data as Data).write(to: destinationURL, options: .atomic)
    }
}
