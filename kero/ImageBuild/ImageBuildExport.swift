//
//  ImageBuildExport.swift
//  kero
//
//  批量导出变体表、尺寸解析与 macOS / Android 模板。
//  单张输入即「仅一张的批量」。
//

import Foundation

// MARK: - 导出变体行

/// 导出配置表一行：`[尺寸][后缀名称]`。
struct ImageExportVariant: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    /// 尺寸描述：`1x` / `512w` / `100x200`（宽×高）等
    var sizeText: String
    /// 文件名后缀（扩展名前）：空 / `@2x` / `_512`
    var suffix: String

    /// 尺寸下拉预置（可输入任意值，菜单快速填入）。
    static let sizePresets: [String] = [
        "0.5x", "1x", "2x", "3x", "4x",
        "16w", "32w", "128w", "256w", "512w", "1024x1024",
    ]

    init(id: UUID = UUID(), sizeText: String = "1x", suffix: String = "") {
        self.id = id
        self.sizeText = sizeText
        self.suffix = suffix
    }

    /// 解析尺寸为缩放模式；失败返回 nil。
    func resizeMode(sourceWidth: Int, sourceHeight: Int) -> ImageResizeMode? {
        ImageExportVariant.parseSize(
            sizeText.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }

    /// 生成输出文件名（不含目录）：`base + suffix + .ext`。
    func outputFileName(baseName: String, format: ImageOutputFormat) -> String {
        let raw = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        // 避免重复扩展名
        let cleanSuffix = raw
        return "\(baseName)\(cleanSuffix).\(format.pathExtension)"
    }

    /// 尺寸字符串解析。
    /// - `""` / `1x`：原尺寸
    /// - `0.5x` / `2x` / `3x`：相对缩放
    /// - `512w`：宽 512，等比
    /// - `256h`：高 256，等比
    /// - `100x200` / `1024x1024`：精确宽×高（不强制锁比例）
    /// - `512`：最长边 512
    static func parseSize(
        _ text: String,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> ImageResizeMode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 注意：返回类型是 Optional，不能写 `return .none`（那是 Optional.nil）
        // 空 / 1x → 保持原尺寸
        if trimmed.isEmpty || trimmed.lowercased() == "1x" {
            return ImageResizeMode.none
        }

        let lower = trimmed.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: " ", with: "")

        // 宽×高：100x200、1024x1024（两侧都有数字，排除 "2x" 缩放）
        if let wxh = parseWidthHeight(lower) {
            return .exact(width: wxh.width, height: wxh.height, keepAspect: false)
        }

        // Nx 缩放：0.5x / 2x / 3x / 4x（整段仅为「数字 + x」）
        if lower.hasSuffix("x"), lower.count >= 2 {
            let numPart = String(lower.dropLast())
            if let n = Double(numPart), n > 0, !numPart.contains("x") {
                // 1x 已在上方处理；此处覆盖 0.5x、2x…
                return .percent(n * 100)
            }
        }

        // 512w / 256h
        if lower.hasSuffix("w"), let w = Int(lower.dropLast()), w > 0 {
            return .exact(width: w, height: nil, keepAspect: true)
        }
        if lower.hasSuffix("h"), let h = Int(lower.dropLast()), h > 0 {
            return .exact(width: nil, height: h, keepAspect: true)
        }

        // 纯数字 → 最长边
        if let edge = Int(lower), edge > 0 {
            return .maxEdge(edge)
        }

        return nil
    }

    /// 解析 `100x200` / `1024×1024` 为宽高；不是 WxH 时返回 nil。
    private static func parseWidthHeight(_ lower: String) -> (width: Int, height: Int)? {
        // 必须恰好一个 x，且两侧均为正整数（排除 "2x" 这种缩放）
        let parts = lower.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let w = Int(parts[0]), w > 0,
              let h = Int(parts[1]), h > 0
        else { return nil }
        return (w, h)
    }
}

// MARK: - 预设模板

/// 模板中的一行导出配置（纯数据，不含运行时 id）。
struct ImageExportTemplateRow: Sendable, Equatable {
    let sizeText: String
    let suffix: String
}

/// 变体表预设模板（macOS / Android 等）。应用时整表替换当前导出设置。
struct ImageExportTemplate: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let rows: [ImageExportTemplateRow]

    /// 内置模板列表。
    static let all: [ImageExportTemplate] = [
        ImageExportTemplate(
            id: "macos-appicon",
            title: L10n.t("macOS App Icon"),
            detail: L10n.t("16w…512w, 1024×1024"),
            rows: [
                .init(sizeText: "16w", suffix: "_16"),
                .init(sizeText: "32w", suffix: "_32"),
                .init(sizeText: "64w", suffix: "_64"),
                .init(sizeText: "128w", suffix: "_128"),
                .init(sizeText: "256w", suffix: "_256"),
                .init(sizeText: "512w", suffix: "_512"),
                .init(sizeText: "1024x1024", suffix: "_1024"),
            ]
        ),
        ImageExportTemplate(
            id: "macos-retina",
            title: L10n.t("macOS 1x / 2x"),
            detail: L10n.t("Original + @2x"),
            rows: [
                .init(sizeText: "1x", suffix: ""),
                .init(sizeText: "2x", suffix: "@2x"),
            ]
        ),
        ImageExportTemplate(
            id: "android-launcher",
            title: L10n.t("Android Launcher"),
            detail: L10n.t("Approximate mdpi…xxxhdpi (preset width)"),
            rows: [
                .init(sizeText: "32w", suffix: "_mdpi"),
                .init(sizeText: "128w", suffix: "_hdpi"),
                .init(sizeText: "128w", suffix: "_xhdpi"),
                .init(sizeText: "256w", suffix: "_xxhdpi"),
                .init(sizeText: "256w", suffix: "_xxxhdpi"),
            ]
        ),
        ImageExportTemplate(
            id: "scale-half-to-4x",
            title: "0.5x … 4x",
            detail: L10n.t("Scale relative to original"),
            rows: [
                .init(sizeText: "0.5x", suffix: "@0.5x"),
                .init(sizeText: "1x", suffix: ""),
                .init(sizeText: "2x", suffix: "@2x"),
                .init(sizeText: "3x", suffix: "@3x"),
                .init(sizeText: "4x", suffix: "@4x"),
            ]
        ),
    ]
}

// MARK: - 会话（打开面板用）

/// 打开 ImageBuild 面板时的会话参数（统一批量；1 张或 N 张输入）。
struct ImageBuildSession: Identifiable, Equatable, Sendable {
    let id: UUID
    var sourcePaths: [String]

    init(id: UUID = UUID(), sourcePaths: [String]) {
        self.id = id
        self.sourcePaths = sourcePaths
    }

    /// 图片查看器：当前文件。
    static func fromViewer(path: String) -> ImageBuildSession {
        ImageBuildSession(sourcePaths: [path])
    }

    /// 文件树：选中的图片路径（过滤非图片）。
    static func fromFileTree(paths: [String]) -> ImageBuildSession {
        let images = paths.filter { ImageBuild.supportsImageExtension(($0 as NSString).pathExtension) }
        return ImageBuildSession(sourcePaths: images)
    }
}

// MARK: - 导出设置持久化

/// Image Build 导出变体表：默认 `1x` + `_build`，用户修改后写入 UserDefaults。
enum ImageBuildExportPreferences {
    private static let storageKey = "imageBuild.exportVariants.v1"

    /// 出厂默认：原尺寸，后缀 `_build` → 如 `icon_build.png`
    static var factoryDefaultVariants: [ImageExportVariant] {
        [ImageExportVariant(sizeText: "1x", suffix: "_build")]
    }

    /// 读取上次记住的导出行；无记录或损坏则回落默认。
    static func loadVariants() -> [ImageExportVariant] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return factoryDefaultVariants
        }
        do {
            let rows = try JSONDecoder().decode([DExportRow].self, from: data)
            let variants = rows.map {
                ImageExportVariant(sizeText: $0.sizeText, suffix: $0.suffix)
            }
            return variants.isEmpty ? factoryDefaultVariants : variants
        } catch {
            return factoryDefaultVariants
        }
    }

    /// 持久化当前导出行（只存尺寸与后缀，id 每次加载重新生成）。
    static func saveVariants(_ variants: [ImageExportVariant]) {
        let rows = variants.map {
            DExportRow(sizeText: $0.sizeText, suffix: $0.suffix)
        }
        guard !rows.isEmpty else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 持久化用 DTO
    private struct DExportRow: Codable, Equatable {
        var sizeText: String
        var suffix: String
    }
}

// MARK: - 批量结果

/// 一次批量任务的汇总。
struct ImageBuildBatchResult: Sendable {
    var results: [ImageBuildResult]
    var successCount: Int { results.filter(\.success).count }
    var failureCount: Int { results.count - successCount }

    var summaryMessage: String {
        if failureCount == 0 {
            return L10n.format("Completed %d files", successCount)
        }
        return L10n.format("%d succeeded, %d failed", successCount, failureCount)
    }
}
