//
//  SystemCommandRunner.swift
//  kero
//

import Foundation
import os

/// 命令执行结果；业务层只解析 stdout，与本地/SSH 传输无关。
struct SystemCommandResult: Sendable, Equatable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

/// 系统信息采集的命令执行抽象，便于日后换成 SSH runner。
protocol SystemCommandRunner: Sendable {
    /// 执行 argv（argv[0] 为可执行文件路径或 PATH 中的名字）。
    func run(argv: [String], timeout: Duration) async throws -> SystemCommandResult
}

enum SystemCommandError: Error, LocalizedError {
    case emptyArgv
    case timedOut
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyArgv: return "Empty command"
        case .timedOut: return "Command timed out"
        case .launchFailed(let message): return message
        }
    }
}

/// 线程安全的单次 Claim 记录器，确保 Continuation 只被 resume 一次
private final class ExecutionTracker: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var claimed = false

    func tryClaim() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// 本机 `Foundation.Process` 实现；强制 `LANG=C` 以便解析英文输出。
struct LocalProcessRunner: SystemCommandRunner {
    func run(argv: [String], timeout: Duration) async throws -> SystemCommandResult {
        guard let executable = argv.first, !executable.isEmpty else {
            throw SystemCommandError.emptyArgv
        }
        let arguments = Array(argv.dropFirst())
        let path = Self.resolvedPath(executable)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SystemCommandError.launchFailed(error.localizedDescription)
        }

        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18

        return try await withCheckedThrowingContinuation { continuation in
            let tracker = ExecutionTracker()

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            timer.schedule(deadline: .now() + max(seconds, 0.05))
            timer.setEventHandler {
                if tracker.tryClaim() {
                    if process.isRunning { process.terminate() }
                    timer.cancel()
                    continuation.resume(throwing: SystemCommandError.timedOut)
                }
            }
            timer.resume()

            DispatchQueue.global().async {
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()

                if tracker.tryClaim() {
                    let result = SystemCommandResult(
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? "",
                        exitCode: process.terminationStatus
                    )
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// 将短命令名映射到 macOS 常见绝对路径，便于无 PATH 的场景。
    static func resolvedPath(_ name: String) -> String {
        if name.hasPrefix("/") { return name }
        let known: [String: String] = [
            "top": "/usr/bin/top",
            "sysctl": "/usr/sbin/sysctl",
            "vm_stat": "/usr/bin/vm_stat",
            "df": "/bin/df",
            "iostat": "/usr/sbin/iostat",
            "netstat": "/usr/sbin/netstat",
            "scutil": "/usr/sbin/scutil",
            "route": "/sbin/route",
            "curl": "/usr/bin/curl",
            "which": "/usr/bin/which",
        ]
        let candidate = known[name] ?? "/usr/bin/\(name)"
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        for prefix in ["/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/"] {
            let alt = prefix + name
            if FileManager.default.fileExists(atPath: alt) {
                return alt
            }
        }
        return candidate
    }
}
