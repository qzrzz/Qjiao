//
//  ImageConvert.swift
//  kero
//
//  原生可写格式编码（PNG / JPEG）。WebP / JXL 走 CLI（见 ImageCompress）。
//
//  说明：当前 macOS ImageIO 与 sips **无法写出** WebP / JPEG XL
//  （CGImageDestinationCreateWithURL 对 org.webmproject.webp / public.jpeg-xl 返回 nil）。
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片格式转换（仅原生可写格式）。
enum ImageConvert {
    /// 将 NSImage 编码为 PNG 或 JPEG 并写入目标路径。
    /// - Note: `.webp` / `.jxl` 请使用 `ImageCompress`，不要走此路径。
    static func write(
        image: NSImage,
        format: ImageOutputFormat,
        to path: String,
        lossyQuality: Double
    ) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        switch format {
        case .png:
            try writePNG(image, to: url)
        case .jpeg:
            try writeJPEG(image, to: url, quality: lossyQuality)
        case .webp, .jxl:
            throw ImageBuildError.encodeFailed(
                "\(format.title) cannot be written via ImageIO; requires \(format.encoderNote)"
            )
        }
    }

    /// 将图像写成临时 PNG，供 cjpegli / cwebp / cjxl / oxipng 消费。
    static func writeTemporaryPNG(_ image: NSImage) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qjiao-imagebuild", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        try writePNG(image, to: url)
        return url
    }

    // MARK: - Private encoders

    /// 将 NSImage 编码为 PNG 二进制数据。
    /// - Note: 使用 ImageIO CGImageDestination 确保完整的 sRGB / ICC 色彩空间标注，避免 NSBitmapImageRep 丢失 sRGB 导致的 cwebp 颜色偏差。
    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let data = pngData(image) else {
            throw ImageBuildError.encodeFailed("PNG encode failed")
        }
        try data.write(to: url, options: .atomic)
    }

    /// 将 NSImage 编码为 JPEG 二进制数据。
    /// - Parameters:
    ///   - image: 待编码图像
    ///   - url: 输出目标 URL
    ///   - quality: 0…1 质量压缩系数
    private static func writeJPEG(_ image: NSImage, to url: URL, quality: Double) throws {
        guard let data = jpegData(image, quality: quality) else {
            throw ImageBuildError.encodeFailed("JPEG encode failed")
        }
        try data.write(to: url, options: .atomic)
    }

    /// 通过 CGImageDestination 生成 PNG Data，完整保留色彩空间与 sRGB 块。
    private static func pngData(_ image: NSImage) -> Data? {
        guard let cg = ImageResize.cgImage(from: image) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 通过 CGImageDestination 生成 JPEG Data，保留色彩空间与质量配置。
    private static func jpegData(_ image: NSImage, quality: Double) -> Data? {
        guard let cg = ImageResize.cgImage(from: image) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let q = max(0, min(1, quality))
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q
        ]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
