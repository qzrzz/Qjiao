//
//  ImageProcessRunner.swift
//  kero
//
//  在后台运行 VendorBin CLI（cjpegli / oxipng / pngquant），带超时与环境变量。
//

import Foundation

/// 外部图片工具的一次执行结果。
struct ImageProcessCommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// 图片处理专用进程运行器（与 System 面板 runner 解耦，避免污染全局环境）。
enum ImageProcessRunner {
    /// 运行可执行文件；`extraEnvironment` 会合并进子进程环境。
    static func run(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        timeout: Duration = .seconds(120)
    ) async throws -> ImageProcessCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runSync(
                        executable: executable,
                        arguments: arguments,
                        extraEnvironment: extraEnvironment,
                        timeoutSeconds: durationToSeconds(timeout)
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync

    private static func runSync(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String],
        timeoutSeconds: TimeInterval
    ) throws -> ImageProcessCommandResult {
        var env = ProcessInfo.processInfo.environment
        // 合并额外环境；DYLD_* 等需在此设置
        for (key, value) in extraEnvironment {
            if key == "DYLD_LIBRARY_PATH", let existing = env[key], !existing.isEmpty {
                env[key] = value + ":" + existing
            } else {
                env[key] = value
            }
        }

        let run = SubprocessRunner.run(
            SubprocessRunner.Config(
                executable: executable,
                arguments: arguments,
                environment: env,
                timeout: max(timeoutSeconds, 0.1)
            )
        )
        guard run.launched else {
            throw ImageBuildError.vendorToolFailed(
                tool: (executable as NSString).lastPathComponent,
                detail: run.launchError ?? "Unknown launch error"
            )
        }
        if run.timedOut {
            throw ImageBuildError.vendorToolFailed(
                tool: (executable as NSString).lastPathComponent,
                detail: "Timed out after \(Int(timeoutSeconds))s"
            )
        }
        return ImageProcessCommandResult(
            exitCode: run.exitCode,
            stdout: String(data: run.stdout, encoding: .utf8) ?? "",
            stderr: String(data: run.stderr, encoding: .utf8) ?? ""
        )
    }

    private static func durationToSeconds(_ duration: Duration) -> TimeInterval {
        let comps = duration.components
        return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
    }
}
