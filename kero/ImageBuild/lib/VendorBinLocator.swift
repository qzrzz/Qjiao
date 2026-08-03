//
//  VendorBinLocator.swift
//  kero
//
//  定位图片编码 CLI：Bundle VendorBin → 源码 VendorBin → Homebrew → PATH。
//

import Foundation

/// 图片编码 / 压缩 CLI 工具定位器。
///
/// 查找顺序：
/// 1. App Bundle `Resources`（摊平或 `VendorBin/` 子目录）
/// 2. 源码树 `kero/VendorBin`
/// 3. Homebrew 常见路径（`/opt/homebrew/bin`、`/usr/local/bin`）
/// 4. `/usr/bin/which`
///
/// WebP / JXL 在当前 macOS 上 **无法** 用 ImageIO 写出，必须依赖 `cwebp` / `cjxl`。
enum VendorBinLocator {
    /// 支持的工具名（与磁盘文件名一致）。
    ///
    /// - WebP：`cwebp` / `dwebp` / `img2webp` / `webpinfo` / `webp_quality`（编码用 `cwebp`）
    /// - JXL：`cjxl` / `djxl` / `jxlinfo`（编码用 `cjxl`；`scripts/vendor-jxl.sh` 静态编译自包含）
    enum Tool: String, CaseIterable, Sendable {
        case cjpegli
        case oxipng
        case pngquant
        case cwebp
        case dwebp
        case img2webp
        case webpinfo
        case webp_quality
        case cjxl
        case djxl
        case jxlinfo
    }

    /// 解析工具绝对路径；找不到返回 nil。
    static func path(for tool: Tool) -> String? {
        let name = tool.rawValue
        let fm = FileManager.default

        // 1. Bundle Resources
        if let resourceURL = Bundle.main.resourceURL {
            let candidates = [
                resourceURL.appendingPathComponent(name).path,
                resourceURL.appendingPathComponent("VendorBin/\(name)").path,
                resourceURL.appendingPathComponent("kero/VendorBin/\(name)").path,
            ]
            for path in candidates where fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 2. Bundle 资源名
        if let url = Bundle.main.url(forResource: name, withExtension: nil),
           fm.isExecutableFile(atPath: url.path) {
            return url.path
        }
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "VendorBin"),
           fm.isExecutableFile(atPath: url.path) {
            return url.path
        }

        // 3. 源码树 kero/VendorBin（#file 回推）
        let thisFile = URL(fileURLWithPath: #filePath)
        let fromSource = thisFile
            .deletingLastPathComponent() // lib
            .deletingLastPathComponent() // ImageBuild
            .deletingLastPathComponent() // kero
            .appendingPathComponent("VendorBin")
            .appendingPathComponent(name)
            .path
        if fm.isExecutableFile(atPath: fromSource) {
            return fromSource
        }

        // 4. cwd 相对路径
        let cwd = fm.currentDirectoryPath
        for rel in ["kero/VendorBin/\(name)", "VendorBin/\(name)"] {
            let p = (cwd as NSString).appendingPathComponent(rel)
            if fm.isExecutableFile(atPath: p) { return p }
        }

        // 5. Homebrew / 本机安装
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            let p = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return p }
        }

        // 6. which
        if let which = resolveViaWhich(name), fm.isExecutableFile(atPath: which) {
            return which
        }

        return nil
    }

    /// 工具是否可用。
    static func isAvailable(_ tool: Tool) -> Bool {
        path(for: tool) != nil
    }

    /// 汇总 UI 用工具状态。
    static func availability() -> ImageBuildToolAvailability {
        ImageBuildToolAvailability(
            cjpegli: isAvailable(.cjpegli),
            oxipng: isAvailable(.oxipng),
            pngquant: isAvailable(.pngquant),
            cwebp: isAvailable(.cwebp),
            cjxl: isAvailable(.cjxl)
        )
    }

    /// 为指定工具补充 `DYLD_LIBRARY_PATH`（vendored 二进制的 rpath 常不完整）。
    static func libraryPaths(for tool: Tool) -> [String] {
        let fm = FileManager.default
        var dirs: [String] = []

        if let bin = path(for: tool) {
            let binDir = (bin as NSString).deletingLastPathComponent
            // 与二进制同目录（打包摊平后 dylib 可能在此）
            dirs.append(binDir)
            // VendorBin/lib（开发树 + 保留子目录时）
            dirs.append((binDir as NSString).appendingPathComponent("lib"))
            // Homebrew Cellar：…/bin/tool → …/lib
            dirs.append(((binDir as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("lib"))
        }

        // 源码树固定位置（#file 回推），避免仅 cwd 不同时找不到 lib
        let sourceVendorLib = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // lib/
            .deletingLastPathComponent() // ImageBuild/
            .deletingLastPathComponent() // kero/
            .appendingPathComponent("VendorBin/lib")
            .path
        dirs.append(sourceVendorLib)

        let home = NSHomeDirectory()
        switch tool {
        case .cjpegli:
            dirs.append(contentsOf: [
                "\(home)/Project/Test/jpegli/build/lib",
                "/opt/homebrew/opt/jpeg-xl/lib",
                "/opt/homebrew/lib",
            ])
        case .cwebp, .dwebp, .img2webp, .webpinfo, .webp_quality:
            // VendorBin 中的 webp 工具为自包含链接，一般不需要额外 dylib
            dirs.append(contentsOf: [
                "/opt/homebrew/opt/webp/lib",
                "/opt/homebrew/lib",
                "/usr/local/opt/webp/lib",
            ])
        case .cjxl, .djxl, .jxlinfo:
            // 静态 vendor 版仅链系统库；若用户换成 brew 动态版再补路径
            dirs.append(contentsOf: [
                "/opt/homebrew/opt/jpeg-xl/lib",
                "/opt/homebrew/opt/highway/lib",
                "/opt/homebrew/opt/brotli/lib",
                "/opt/homebrew/lib",
                "/usr/local/opt/jpeg-xl/lib",
            ])
        case .oxipng, .pngquant:
            break
        }

        dirs.append(contentsOf: ["/opt/homebrew/lib", "/usr/local/lib"])
        // 去重保序
        var seen = Set<String>()
        return dirs.filter { dir in
            guard fm.fileExists(atPath: dir), !seen.contains(dir) else { return false }
            seen.insert(dir)
            return true
        }
    }

    // MARK: - Private

    private static func resolveViaWhich(_ name: String) -> String? {
        let run = SubprocessRunner.run(
            SubprocessRunner.Config(
                executable: "/usr/bin/which",
                arguments: [name],
                timeout: 10
            )
        )
        guard run.launched, !run.timedOut, run.exitCode == 0 else { return nil }
        let path = String(data: run.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}
