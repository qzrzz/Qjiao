//
//  ImageResizing.swift
//  kero
//
//  图像与图标最高质量缩放扩展：基于 Quartz 2D (CGContext) 离屏渲染与最高插值算法（.high / Bicubic / Lanczos），
//  为 AppKit 与 SwiftUI 提供 Retina 屏高清晰度像素对齐图层。
//

import AppKit
import SwiftUI

extension NSImage {
    /// 使用 Quartz 2D 最高品质插值算法（.high / Bicubic / Lanczos）将图像重绘为指定点尺寸的高清像素图层。
    ///
    /// - Parameters:
    ///   - targetPointSize: 显示时的逻辑点尺寸（Pt）
    ///   - scale: 物理像素缩放比（默认获取主屏幕 backingScaleFactor 或 2.0）
    ///   - keepAspectRatio: 是否保持原图宽高比，默认 true
    /// - Returns: 含有 2×/3× 高清 `NSBitmapImageRep` 的 `NSImage`
    func resizedHighQuality(
        to targetPointSize: NSSize,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0,
        keepAspectRatio: Bool = true
    ) -> NSImage {
        guard targetPointSize.width > 0 && targetPointSize.height > 0,
              self.size.width > 0 && self.size.height > 0 else {
            return self
        }

        let displayScale = max(scale, 1.0)
        let drawPointSize: NSSize
        if keepAspectRatio {
            let srcSize = self.size
            let factor = min(targetPointSize.width / srcSize.width, targetPointSize.height / srcSize.height)
            drawPointSize = NSSize(width: max(1, srcSize.width * factor), height: max(1, srcSize.height * factor))
        } else {
            drawPointSize = targetPointSize
        }

        let pixelWidth = max(1, Int(ceil(drawPointSize.width * displayScale)))
        let pixelHeight = max(1, Int(ceil(drawPointSize.height * displayScale)))

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            let fallback = (self.copy() as? NSImage) ?? self
            fallback.size = drawPointSize
            return fallback
        }

        bitmapRep.size = drawPointSize

        guard let nsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            let fallback = (self.copy() as? NSImage) ?? self
            fallback.size = drawPointSize
            return fallback
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let cgContext = nsContext.cgContext
        nsContext.imageInterpolation = .high
        cgContext.interpolationQuality = .high
        cgContext.setShouldAntialias(true)
        cgContext.setAllowsAntialiasing(true)

        let destRect = NSRect(origin: .zero, size: drawPointSize)
        self.draw(in: destRect, from: NSRect(origin: .zero, size: self.size), operation: .copy, fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        let finalImage = NSImage(size: drawPointSize)
        finalImage.addRepresentation(bitmapRep)
        finalImage.isTemplate = self.isTemplate
        return finalImage
    }
}
