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

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let data = bitmapData(image, using: .png, properties: [:]) else {
            throw ImageBuildError.encodeFailed("PNG encode failed")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func writeJPEG(_ image: NSImage, to url: URL, quality: Double) throws {
        let q = max(0, min(1, quality))
        let props: [NSBitmapImageRep.PropertyKey: Any] = [
            .compressionFactor: q
        ]
        guard let data = bitmapData(image, using: .jpeg, properties: props) else {
            throw ImageBuildError.encodeFailed("JPEG encode failed")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func bitmapData(
        _ image: NSImage,
        using format: NSBitmapImageRep.FileType,
        properties: [NSBitmapImageRep.PropertyKey: Any]
    ) -> Data? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return rep.representation(using: format, properties: properties)
        }
        guard let cg = ImageResize.cgImage(from: image) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: format, properties: properties)
    }
}
