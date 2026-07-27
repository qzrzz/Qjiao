//
//  ImageResize.swift
//  kero
//
//  基于 Core Graphics 的高质量图片缩放。
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// 图片尺寸调整工具。
enum ImageResize {
    /// 读取源图像像素尺寸。
    static func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        // 回退：用 CGImage 或逻辑尺寸
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (cg.width, cg.height)
        }
        return (max(1, Int(image.size.width.rounded())), max(1, Int(image.size.height.rounded())))
    }

    /// 根据模式计算目标像素尺寸；无需缩放时返回 nil。
    static func targetPixelSize(
        sourceWidth: Int,
        sourceHeight: Int,
        mode: ImageResizeMode
    ) throws -> (width: Int, height: Int)? {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw ImageBuildError.invalidResize
        }

        switch mode {
        case .none:
            return nil

        case .percent(let percent):
            guard percent > 0 else { throw ImageBuildError.invalidResize }
            if abs(percent - 100) < 0.000_1 { return nil }
            let scale = percent / 100.0
            let w = max(1, Int((Double(sourceWidth) * scale).rounded()))
            let h = max(1, Int((Double(sourceHeight) * scale).rounded()))
            if w == sourceWidth && h == sourceHeight { return nil }
            return (w, h)

        case .exact(let width, let height, let keepAspect):
            if width == nil && height == nil {
                throw ImageBuildError.invalidResize
            }
            if keepAspect {
                // 指定一边则等比；两边都给则按「适应」缩放（不放大超出任一边）
                if let w = width, let h = height {
                    let scale = min(Double(w) / Double(sourceWidth), Double(h) / Double(sourceHeight))
                    let tw = max(1, Int((Double(sourceWidth) * scale).rounded()))
                    let th = max(1, Int((Double(sourceHeight) * scale).rounded()))
                    if tw == sourceWidth && th == sourceHeight { return nil }
                    return (tw, th)
                }
                if let w = width {
                    let scale = Double(w) / Double(sourceWidth)
                    let th = max(1, Int((Double(sourceHeight) * scale).rounded()))
                    if w == sourceWidth && th == sourceHeight { return nil }
                    return (max(1, w), th)
                }
                if let h = height {
                    let scale = Double(h) / Double(sourceHeight)
                    let tw = max(1, Int((Double(sourceWidth) * scale).rounded()))
                    if tw == sourceWidth && h == sourceHeight { return nil }
                    return (tw, max(1, h))
                }
            } else {
                let tw = max(1, width ?? sourceWidth)
                let th = max(1, height ?? sourceHeight)
                if tw == sourceWidth && th == sourceHeight { return nil }
                return (tw, th)
            }
            return nil

        case .maxEdge(let maxEdge):
            guard maxEdge > 0 else { throw ImageBuildError.invalidResize }
            let longest = max(sourceWidth, sourceHeight)
            if longest <= maxEdge { return nil }
            let scale = Double(maxEdge) / Double(longest)
            let tw = max(1, Int((Double(sourceWidth) * scale).rounded()))
            let th = max(1, Int((Double(sourceHeight) * scale).rounded()))
            return (tw, th)
        }
    }

    /// 将 NSImage 缩放为指定像素尺寸，返回新的位图图像。
    static func resize(_ image: NSImage, toWidth width: Int, height: Int) throws -> NSImage {
        guard width > 0, height > 0 else { throw ImageBuildError.invalidResize }

        guard let sourceCG = cgImage(from: image) else {
            throw ImageBuildError.cannotLoadImage("Failed to create CGImage for resize")
        }

        let colorSpace = sourceCG.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = {
            // 优先保留 alpha
            if sourceCG.alphaInfo == .none || sourceCG.alphaInfo == .noneSkipLast
                || sourceCG.alphaInfo == .noneSkipFirst {
                return CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            }
            return CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }()

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ImageBuildError.encodeFailed("Cannot create graphics context for resize")
        }

        ctx.interpolationQuality = .high
        ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let scaled = ctx.makeImage() else {
            throw ImageBuildError.encodeFailed("Resize produced empty image")
        }

        let result = NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
        return result
    }

    /// 按模式缩放；无需缩放时原样返回。
    static func apply(_ image: NSImage, mode: ImageResizeMode) throws -> NSImage {
        let (sw, sh) = pixelSize(of: image)
        guard let target = try targetPixelSize(sourceWidth: sw, sourceHeight: sh, mode: mode) else {
            return image
        }
        return try resize(image, toWidth: target.width, height: target.height)
    }

    // MARK: - Helpers

    /// 从 NSImage 取出 CGImage（优先表示层，再 proposed rect）。
    static func cgImage(from image: NSImage) -> CGImage? {
        if let rep = image.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep,
           let cg = rep.cgImage {
            return cg
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
