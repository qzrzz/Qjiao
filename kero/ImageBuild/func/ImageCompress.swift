//
//  ImageCompress.swift
//  kero
//
//  CLI 编码/压缩：
//  - JPEG → cjpegli
//  - PNG  → oxipng / pngquant
//  - WebP → cwebp
//  - JXL  → cjxl
//

import Foundation

/// 基于 CLI 的图片编码与压缩。
enum ImageCompress {
    // MARK: - JPEG (cjpegli)

    /// 用 cjpegli 将输入图压成 JPEG。
    static func compressJPEG(
        inputPath: String,
        outputPath: String,
        quality: Int
    ) async throws {
        try await runVendor(
            tool: .cjpegli,
            arguments: [
                inputPath,
                outputPath,
                "--quality=\(max(1, min(100, quality)))",
            ],
            outputPath: outputPath,
            timeout: .seconds(180)
        )
    }

    // MARK: - WebP (cwebp)

    /// 用 cwebp 编码 WebP。
    /// - Parameters:
    ///   - inputPath: PNG/JPEG 等 cwebp 可读输入
    ///   - outputPath: `.webp`
    ///   - quality: 0…100（有损）
    ///   - lossless: 是否 `-lossless`
    static func compressWebP(
        inputPath: String,
        outputPath: String,
        quality: Int,
        lossless: Bool
    ) async throws {
        var args: [String] = []
        if lossless {
            args.append(contentsOf: ["-lossless", "-q", "100"])
        } else {
            args.append(contentsOf: ["-q", "\(max(0, min(100, quality)))"])
        }
        // 包含 ICC 配置文件以保留色彩空间；适度多线程；保留 alpha
        args.append(contentsOf: ["-metadata", "icc", "-mt", "-o", outputPath, "--", inputPath])

        try await runVendor(
            tool: .cwebp,
            arguments: args,
            outputPath: outputPath,
            timeout: .seconds(180)
        )
    }

    // MARK: - JXL (cjxl)

    /// 用 cjxl 编码 JPEG XL。
    /// - Parameters:
    ///   - quality: 0…100（100 = 数学无损）
    ///   - effort: 1…10
    static func compressJXL(
        inputPath: String,
        outputPath: String,
        quality: Int,
        effort: Int
    ) async throws {
        let q = max(0, min(100, quality))
        let e = max(1, min(10, effort))
        try await runVendor(
            tool: .cjxl,
            arguments: [
                inputPath,
                outputPath,
                "--quality=\(q)",
                "--effort=\(e)",
            ],
            outputPath: outputPath,
            timeout: .seconds(300)
        )
    }

    // MARK: - PNG (oxipng)

    /// 用 oxipng 无损优化 PNG。
    static func optimizePNG(
        inputPath: String,
        outputPath: String?,
        level: Int,
        stripSafe: Bool
    ) async throws {
        guard let tool = VendorBinLocator.path(for: .oxipng) else {
            throw ImageBuildError.vendorToolMissing("oxipng")
        }

        let opt = max(0, min(6, level))
        var args: [String] = [
            "-o", "\(opt)",
            "--force",
        ]
        if stripSafe {
            args.append("-s")
        }
        if let outputPath {
            prepareOutputPath(outputPath)
            args.append(contentsOf: ["--out", outputPath])
        }
        args.append(inputPath)

        let result = try await ImageProcessRunner.run(
            executable: tool,
            arguments: args,
            extraEnvironment: libraryEnv(for: .oxipng),
            timeout: .seconds(300)
        )

        let finalPath = outputPath ?? inputPath
        try ensureSuccess(tool: "oxipng", result: result, outputPath: finalPath)
    }

    // MARK: - PNG quantize (pngquant)

    /// 用 pngquant 量化 PNG 颜色。
    @discardableResult
    static func quantizePNG(
        inputPath: String,
        outputPath: String,
        colors: Int,
        qualityMin: Int,
        qualityMax: Int
    ) async throws -> String {
        let nColors = max(2, min(256, colors))
        let qMin = max(0, min(100, qualityMin))
        let qMax = max(qMin, min(100, qualityMax))

        try await runVendor(
            tool: .pngquant,
            arguments: [
                "\(nColors)",
                "--force",
                "--quality", "\(qMin)-\(qMax)",
                "--output", outputPath,
                "--",
                inputPath,
            ],
            outputPath: outputPath,
            timeout: .seconds(180)
        )
        return outputPath
    }

    // MARK: - Shared runner

    private static func runVendor(
        tool: VendorBinLocator.Tool,
        arguments: [String],
        outputPath: String,
        timeout: Duration
    ) async throws {
        guard let executable = VendorBinLocator.path(for: tool) else {
            throw ImageBuildError.vendorToolMissing(tool.rawValue)
        }

        prepareOutputPath(outputPath)

        let result = try await ImageProcessRunner.run(
            executable: executable,
            arguments: arguments,
            extraEnvironment: libraryEnv(for: tool),
            timeout: timeout
        )
        try ensureSuccess(tool: tool.rawValue, result: result, outputPath: outputPath)
    }

    private static func prepareOutputPath(_ outputPath: String) {
        let outURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputPath) {
            try? FileManager.default.removeItem(atPath: outputPath)
        }
    }

    private static func libraryEnv(for tool: VendorBinLocator.Tool) -> [String: String] {
        let paths = VendorBinLocator.libraryPaths(for: tool)
        guard !paths.isEmpty else { return [:] }
        return ["DYLD_LIBRARY_PATH": paths.joined(separator: ":")]
    }

    private static func ensureSuccess(
        tool: String,
        result: ImageProcessCommandResult,
        outputPath: String
    ) throws {
        guard result.succeeded, FileManager.default.fileExists(atPath: outputPath) else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            throw ImageBuildError.vendorToolFailed(
                tool: tool,
                detail: detail.isEmpty ? "exit \(result.exitCode)" : detail
            )
        }
    }
}
