//
//  LocalAIProcessRunner.swift
//  kero
//
//  在后台运行 AI CLI 进程：支持 stdin、工作目录、超时、Task 取消与环境变量。
//

import Foundation

/// LocalAI 专用进程运行器（与 System / ImageBuild runner 解耦）。
enum LocalAIProcessRunner {
    /// 执行一条 `LocalAICommand`；调用方 `Task.cancel()` 会终止子进程。
    static func run(
        _ command: LocalAICommand,
        timeout: Duration
    ) async throws -> LocalAIProcessResult {
        let box = LocalAIProcessBox()
        try await box.start(command)

        let seconds = durationToSeconds(timeout)

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: LocalAIProcessResult.self) { group in
                group.addTask {
                    try await box.waitForExit()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(seconds, 0.05)))
                    await box.terminate()
                    throw LocalAIError.timedOut(.seconds(Int64(seconds)))
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
        } onCancel: {
            Task { await box.terminate() }
        }
    }

    private static func durationToSeconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}

/// 跨 task 持有 Process：支持 wait / terminate，避免 continuation 双重 resume。
private actor LocalAIProcessBox {
    private var process: Process?
    private var finished: LocalAIProcessResult?
    private var waiters: [CheckedContinuation<LocalAIProcessResult, Error>] = []
    private var didFinish = false

    func start(_ command: LocalAICommand) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments

        if let cwd = command.workingDirectory, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        var env = ProcessInfo.processInfo.environment
        let extraPath = LocalAIExecutableLocatorPathBoost.augmentedPATH(env["PATH"])
        env["PATH"] = extraPath
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        for (key, value) in command.environment {
            env[key] = value
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        if let stdinText = command.stdinText {
            let stdin = Pipe()
            process.standardInput = stdin
            if let data = stdinText.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            try? stdin.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw LocalAIError.launchFailed(error.localizedDescription)
        }
        self.process = process

        Task.detached { [weak self] in
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = LocalAIProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
            await self?.complete(result)
        }
    }

    func waitForExit() async throws -> LocalAIProcessResult {
        if let finished { return finished }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        // 若仍未退，短暂后 interrupt
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            if process.isRunning {
                process.interrupt()
            }
        }
    }

    private func complete(_ result: LocalAIProcessResult) {
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

/// 仅为 PATH 拼接提供内部工具，避免与 Locator 循环依赖语义混淆。
enum LocalAIExecutableLocatorPathBoost {
    static func augmentedPATH(_ existing: String?) -> String {
        var dirs = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dirs += [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.grok/bin",
            "\(home)/.opencode/bin",
            "\(home)/.claude/bin",
            "\(home)/.gemini/antigravity/bin",
            "\(home)/.antigravity/bin",
        ]
        var seen = Set<String>()
        var ordered: [String] = []
        for d in dirs + (existing ?? "").split(separator: ":").map(String.init) {
            guard !d.isEmpty, !seen.contains(d) else { continue }
            seen.insert(d)
            ordered.append(d)
        }
        return ordered.joined(separator: ":")
    }
}
