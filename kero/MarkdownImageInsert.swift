//
//  MarkdownImageInsert.swift
//  kero
//
//  Markdown 编辑：把剪贴板 / 拖入的图片落到 md 同级 assets/，
//  并插入 `![](assets/…)`。来源已在 assets 内则直接复用，不复制。
//

import AppKit
import UniformTypeIdentifiers

enum MarkdownImageInsert {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "jxl",
        "tiff", "tif", "bmp", "icns", "svg",
    ]

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty {
            return urls.contains(where: isImageFile)
        }
        return pasteboard.types?.contains(where: isImageDataType) == true
    }

    /// 从粘贴板生成要插入的 Markdown。无可插入图片时返回 nil。
    static func snippet(from pasteboard: NSPasteboard, markdownPath: String) -> String? {
        let urls = fileURLs(from: pasteboard).filter(isImageFile)
        if !urls.isEmpty {
            return insert(urls: urls, markdownPath: markdownPath)
        }
        if !fileURLs(from: pasteboard).isEmpty {
            return nil
        }
        guard pasteboard.types?.contains(where: isImageDataType) == true,
              let image = NSImage(pasteboard: pasteboard),
              image.isValid
        else { return nil }
        return insert(image: image, markdownPath: markdownPath)
    }

    static func insert(urls: [URL], markdownPath: String) -> String? {
        let snippets = urls.compactMap { url -> String? in
            do {
                return try store(file: url, markdownPath: markdownPath)
            } catch {
                return nil
            }
        }
        guard !snippets.isEmpty else { return nil }
        return snippets.joined(separator: "\n")
    }

    static func insert(image: NSImage, markdownPath: String) -> String? {
        guard let data = pngData(from: image) else { return nil }
        do {
            return try store(data: data, preferredName: "image.png", markdownPath: markdownPath)
        } catch {
            return nil
        }
    }

    static func isImageFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values?.isDirectory == true { return false }
        if values?.isRegularFile == false { return false }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return true
        }
        return false
    }

    // MARK: - Store

    private static func store(file source: URL, markdownPath: String) throws -> String {
        let markdownDir = URL(fileURLWithPath: markdownPath).deletingLastPathComponent()
        if let existing = reusedAssetsPath(source: source, markdownDir: markdownDir) {
            return markdownImage(
                alt: source.deletingPathExtension().lastPathComponent,
                relativePath: existing
            )
        }
        let assetsDir = assetsDirectory(for: markdownDir)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        var destination = assetsDir.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            if isSameFile(source, destination) {
                return markdownImage(
                    alt: source.deletingPathExtension().lastPathComponent,
                    relativePath: relativePath(from: markdownDir, to: destination)
                )
            }
            destination = uniqueURL(in: assetsDir, preferredName: source.lastPathComponent)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return markdownImage(
            alt: destination.deletingPathExtension().lastPathComponent,
            relativePath: relativePath(from: markdownDir, to: destination)
        )
    }

    private static func store(data: Data, preferredName: String, markdownPath: String) throws -> String {
        let markdownDir = URL(fileURLWithPath: markdownPath).deletingLastPathComponent()
        let assetsDir = assetsDirectory(for: markdownDir)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let destination = uniqueURL(in: assetsDir, preferredName: preferredName)
        try data.write(to: destination, options: .atomic)
        return markdownImage(
            alt: destination.deletingPathExtension().lastPathComponent,
            relativePath: relativePath(from: markdownDir, to: destination)
        )
    }

    /// 来源已在 md 同级 `assets/`（含子目录）内：返回相对 md 文件目录的路径。
    private static func reusedAssetsPath(source: URL, markdownDir: URL) -> String? {
        let assetsDir = assetsDirectory(for: markdownDir)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let file = source.resolvingSymlinksInPath().standardizedFileURL
        let assetsPath = assetsDir.path
        let filePath = file.path
        let prefix = assetsPath.hasSuffix("/") ? assetsPath : assetsPath + "/"
        guard filePath == assetsPath || filePath.hasPrefix(prefix) else { return nil }
        guard filePath != assetsPath else { return nil }
        return relativePath(from: markdownDir, to: file)
    }

    private static func assetsDirectory(for markdownDir: URL) -> URL {
        markdownDir.appendingPathComponent("assets", isDirectory: true)
    }

    private static func relativePath(from directory: URL, to file: URL) -> String {
        let dirPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return "assets/\(file.lastPathComponent)"
    }

    private static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let aStd = a.resolvingSymlinksInPath().standardizedFileURL
        let bStd = b.resolvingSymlinksInPath().standardizedFileURL
        if aStd.path == bStd.path { return true }
        guard let aID = try? aStd.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier,
            let bID = try? bStd.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier
        else { return false }
        return aID.isEqual(bID)
    }

    private static func markdownImage(alt: String, relativePath: String) -> String {
        let safeAlt = alt
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        return "![\(safeAlt)](\(markdownDestination(relativePath)))"
    }

    private static func markdownDestination(_ relative: String) -> String {
        relative
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "#", with: "%23")
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func isImageDataType(_ type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .png, .tiff:
            return true
        default:
            let raw = type.rawValue
            return raw == "public.png"
                || raw == "public.tiff"
                || raw == "public.jpeg"
                || raw == "public.heic"
                || raw.hasPrefix("public.image")
        }
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            urls.append(contentsOf: objects.map(\.standardizedFileURL))
        }
        if urls.isEmpty,
           let paths = pasteboard.propertyList(
               forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
           ) as? [String]
        {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0).standardizedFileURL })
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
