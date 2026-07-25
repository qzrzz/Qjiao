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
struct LocalProcessRunner: SystemCommandRunner {
    func run(argv: [String], timeout: Duration) async throws -> SystemCommandResult {
        guard let executable = argv.first, !executable.isEmpty else {
            throw SystemCommandError.emptyArgv
        }
        let arguments = Array(argv.dropFirst())
        let path = Self.resolvedPath(executable)

        let box = ProcessBox()
        try await box.start(path: path, arguments: arguments)

        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18

        return try await withThrowingTaskGroup(of: SystemCommandResult.self) { group in
            group.addTask {
                try await box.waitForExit()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(max(seconds, 0.05)))
                await box.terminate()
                throw SystemCommandError.timedOut
            }

            do {
                let result = try await group.next()!
                group.cancelAll()
                await box.terminate()
                return result
            } catch {
                group.cancelAll()
                await box.terminate()
                throw error
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
        return known[name] ?? "/usr/bin/\(name)"
    }
}

/// 跨 task 持有 Process：先 start，再 wait/terminate，避免 continuation 双重 resume。
private actor ProcessBox {
    private var process: Process?
    private var stdout = Pipe()
    private var stderr = Pipe()
    private var finished: SystemCommandResult?
    private var waiters: [CheckedContinuation<SystemCommandResult, Error>] = []
    private var didFinish = false

    func start(path: String, arguments: [String]) async throws {
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
        self.stdout = stdout
        self.stderr = stderr
        self.process = process

        do {
            try process.run()
        } catch {
            throw SystemCommandError.launchFailed(error.localizedDescription)
        }

        // 后台读管道直到进程结束，只完成一次。
        Task.detached { [weak self] in
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = SystemCommandResult(
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
            await self?.complete(result)
        }
    }

    func waitForExit() async throws -> SystemCommandResult {
        if let finished { return finished }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func complete(_ result: SystemCommandResult) {
        guard !didFinish else { return }
        didFinish = true
        finished = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }
}
