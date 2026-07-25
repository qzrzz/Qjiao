//
//  MaterialFileIcon.swift
//  kero
//
//  右侧 Files / CWD / Git 文件列表图标：匹配逻辑与 SVG 资源来自
//  Material Icon Theme（https://github.com/material-extensions/vscode-material-icon-theme）。
//

import AppKit
import SwiftUI

// MARK: - Catalog

/// 加载并缓存 Material Icon Theme 的关联表与 SVG，按文件名/扩展名/目录名解析图标。
@MainActor
final class MaterialFileIconCatalog {
    static let shared = MaterialFileIconCatalog()

    private struct Manifest: Decodable {
        let file: String
        let folder: String
        let folderExpanded: String
        let rootFolder: String
        let rootFolderExpanded: String
        let fileNames: [String: String]
        let fileExtensions: [String: String]
        let folderNames: [String: String]
        let folderNamesExpanded: [String: String]
        /// icon 逻辑名 → 实际 SVG 文件名（clone 图标文件名可能带 `.clone.svg`）
        let iconFiles: [String: String]
        let light: LightMaps

        struct LightMaps: Decodable {
            let fileNames: [String: String]
            let fileExtensions: [String: String]
            let folderNames: [String: String]
            let folderNamesExpanded: [String: String]
        }
    }

    private let manifest: Manifest?
    private let iconsDirectory: URL?
    /// 已解码的 NSImage，按「逻辑名 + 显示点尺寸」缓存，避免列表滚动时反复读盘。
    private var imageCache: [String: NSImage] = [:]

    private init() {
        // Bundle 内路径：kero/MaterialIcons/ 随同步根目录打进 Resources。
        // 同步组可能保留子目录，也可能把文件摊平到 Resources 根部，两处都试。
        let bundle = Bundle.main
        let jsonURL = Self.locateJSON(in: bundle)
        let iconsDir = Self.locateIconsDirectory(in: bundle)

        if let jsonURL, let data = try? Data(contentsOf: jsonURL) {
            self.manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        } else {
            self.manifest = nil
            #if DEBUG
            print("MaterialFileIcon: material-icons.json not found in bundle")
            #endif
        }

        self.iconsDirectory = iconsDir
        #if DEBUG
        if iconsDir == nil {
            print("MaterialFileIcon: icons directory not found in bundle")
        }
        #endif
    }

    /// 查找关联表 JSON（保留目录或扁平到 Resources 根）。
    private static func locateJSON(in bundle: Bundle) -> URL? {
        let candidates: [URL?] = [
            bundle.url(forResource: "material-icons", withExtension: "json", subdirectory: "MaterialIcons"),
            bundle.url(forResource: "material-icons", withExtension: "json"),
            bundle.resourceURL?.appendingPathComponent("MaterialIcons/material-icons.json"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 查找 SVG 目录；若被摊平则返回 Resources 根（按文件名直接取 svg）。
    private static func locateIconsDirectory(in bundle: Bundle) -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("MaterialIcons/icons", isDirectory: true),
            bundle.resourceURL?.appendingPathComponent("icons", isDirectory: true),
            bundle.resourceURL,
        ]
        for dir in candidates.compactMap({ $0 }) {
            // 用一个稳定存在的默认图标探测目录是否可用。
            let probe = dir.appendingPathComponent("file.svg")
            if fm.fileExists(atPath: probe.path) {
                return dir
            }
        }
        return nil
    }

    /// 解析文件/目录对应的 Material 图标逻辑名（如 `typescript`、`folder-src`）。
    func iconName(
        fileName: String,
        isDirectory: Bool,
        isExpanded: Bool = false,
        isRoot: Bool = false,
        prefersLight: Bool = false
    ) -> String {
        guard let manifest else {
            return isDirectory ? "folder" : "file"
        }

        let key = fileName.lowercased()

        if isDirectory {
            if isRoot {
                return isExpanded ? manifest.rootFolderExpanded : manifest.rootFolder
            }
            if prefersLight {
                if isExpanded, let name = manifest.light.folderNamesExpanded[key] {
                    return name
                }
                if !isExpanded, let name = manifest.light.folderNames[key] {
                    return name
                }
            }
            if isExpanded, let name = manifest.folderNamesExpanded[key] {
                return name
            }
            if let name = manifest.folderNames[key] {
                return name
            }
            return isExpanded ? manifest.folderExpanded : manifest.folder
        }

        // 1) 完整文件名优先（package.json、Dockerfile、.gitignore…）
        if prefersLight, let name = manifest.light.fileNames[key] {
            return name
        }
        if let name = manifest.fileNames[key] {
            return name
        }

        // 2) 最长扩展名优先（d.ts → typescript-def，test.ts → test-ts）
        if let name = matchExtension(key, map: prefersLight ? manifest.light.fileExtensions : [:])
            ?? matchExtension(key, map: manifest.fileExtensions)
        {
            return name
        }

        return manifest.file
    }

    /// 加载指定逻辑名的图标；`pointSize` 为 SwiftUI 显示逻辑点（默认 16）。
    func image(named iconName: String, pointSize: CGFloat = 16) -> NSImage? {
        // 点尺寸取整后做 key，同一列表行共用同一缓存项。
        let sizeKey = String(format: "%.1f", pointSize)
        let cacheKey = "\(iconName)@\(sizeKey)"
        if let hit = imageCache[cacheKey] {
            return hit
        }

        guard let url = svgURL(for: iconName) else { return nil }
        guard let base = NSImage(contentsOf: url) else { return nil }

        // 固定逻辑尺寸，SVG rep 在绘制时按 size 光栅化，列表对齐更稳。
        let sized = base.copy() as? NSImage ?? base
        sized.size = NSSize(width: pointSize, height: pointSize)
        imageCache[cacheKey] = sized
        return sized
    }

    func image(
        fileName: String,
        isDirectory: Bool,
        isExpanded: Bool = false,
        isRoot: Bool = false,
        prefersLight: Bool = false,
        pointSize: CGFloat = 16
    ) -> NSImage? {
        let name = iconName(
            fileName: fileName,
            isDirectory: isDirectory,
            isExpanded: isExpanded,
            isRoot: isRoot,
            prefersLight: prefersLight
        )
        return image(named: name, pointSize: pointSize)
    }

    // MARK: Private

    /// 从最长多段扩展名向下尝试（`foo.bar.baz` → `bar.baz` → `baz`）。
    private func matchExtension(_ lowercasedName: String, map: [String: String]) -> String? {
        guard !map.isEmpty else { return nil }
        let parts = lowercasedName.split(separator: ".", omittingEmptySubsequences: false)
        // 隐藏文件 `.env`：parts 为 ["", "env"]，扩展段从 index 1 开始即可。
        guard parts.count >= 2 else { return nil }
        for i in 1..<parts.count {
            let ext = parts[i...].joined(separator: ".")
            if ext.isEmpty { continue }
            if let name = map[ext] {
                return name
            }
        }
        return nil
    }

    private func svgURL(for iconName: String) -> URL? {
        guard let iconsDirectory, let manifest else { return nil }
        let fileName = manifest.iconFiles[iconName] ?? "\(iconName).svg"
        let url = iconsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - SwiftUI

/// 按文件名/目录状态显示 Material 文件图标；找不到资源时回退 SF Symbol。
struct MaterialFileIconView: View {
    let fileName: String
    let isDirectory: Bool
    var isExpanded: Bool = false
    var isRoot: Bool = false
    var size: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let prefersLight = colorScheme == .light
        if let image = MaterialFileIconCatalog.shared.image(
            fileName: fileName,
            isDirectory: isDirectory,
            isExpanded: isExpanded,
            isRoot: isRoot,
            prefersLight: prefersLight,
            pointSize: size
        ) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: size * 0.85))
                .foregroundStyle(isDirectory ? Color(nsColor: Theme.cursor).opacity(0.8) : Color.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
