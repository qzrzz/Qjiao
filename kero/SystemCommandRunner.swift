//
//  SystemCommandRunner.swift
//  kero
//

import Foundation

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

/// 本机 `Foundation.Process` 实现；强制 `LANG=C` 以便解析英文输出。
/// 实际执行统一走 `SubprocessRunner`（含超时终止进程树与读端兑底）。
struct LocalProcessRunner: SystemCommandRunner {
    func run(argv: [String], timeout: Duration) async throws -> SystemCommandResult {
        guard let executable = argv.first, !executable.isEmpty else {
            throw SystemCommandError.emptyArgv
        }
        let arguments = Array(argv.dropFirst())
        let path = Self.resolvedPath(executable)

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"
        env["LC_ALL"] = "C"

        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18

        let result = await Task.detached(priority: .utility) {
            SubprocessRunner.run(
                SubprocessRunner.Config(
                    executable: path,
                    arguments: arguments,
                    environment: env,
                    timeout: seconds
                )
            )
        }.value

        guard result.launched else {
            throw SystemCommandError.launchFailed(result.launchError ?? "Unknown launch error")
        }
        if result.timedOut {
            throw SystemCommandError.timedOut
        }
        return SystemCommandResult(
            stdout: String(data: result.stdout, encoding: .utf8) ?? "",
            stderr: String(data: result.stderr, encoding: .utf8) ?? "",
            exitCode: result.exitCode
        )
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
