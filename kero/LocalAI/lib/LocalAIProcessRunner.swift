//
//  LocalAIProcessRunner.swift
//  kero
//
//  在后台运行 AI CLI 进程：支持 stdin、工作目录、超时、Task 取消与环境变量。
//

import Darwin
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
                    // 正常结束不必强杀；若已退出 terminate 为空操作
                    await box.terminateIfStillRunning()
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
    private var processIdentifier: Int32 = 0

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
        // 避免 CLI 等待交互式确认
        env["CI"] = "1"
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
            process.standardInput = SubprocessRunner.makeEOFStdinPipe()
        }

        do {
            try process.run()
        } catch {
            throw LocalAIError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.processIdentifier = process.processIdentifier

        // 并行读 stdout / stderr，避免一侧写满管道导致进程阻塞死锁
        Task.detached { [weak self] in
            let outBox = LocalAIPipeBuffer()
            let errBox = LocalAIPipeBuffer()
            let readers = DispatchGroup()

            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                outBox.data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                errBox.data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                readers.leave()
            }

            process.waitUntilExit()

            // 读端兜底：进程树可能残留持有写端的孙进程，drain 无法 EOF；
            // 超时后强制关闭读端，保证读取线程与 fd 必然回收。
            if readers.wait(timeout: .now() + 5) == .timedOut {
                try? stdout.fileHandleForReading.close()
                try? stderr.fileHandleForReading.close()
                _ = readers.wait(timeout: .now() + 2)
            }

            let result = LocalAIProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outBox.data, encoding: .utf8) ?? "",
                stderr: String(data: errBox.data, encoding: .utf8) ?? ""
            )
            await self?.complete(result)
        }
    }

    func waitForExit() async throws -> LocalAIProcessResult {
        if let finished { return finished }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LocalAIProcessResult, Error>) in
                if let finished {
                    continuation.resume(returning: finished)
                } else {
                    waiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.terminate() }
        }
    }

    /// 超时 / 取消：SIGTERM 进程组，短暂后 SIGKILL。
    func terminate() {
        forceKill(escalating: true)
    }

    /// 任务正常返回后：仅当仍在跑时清理（避免误杀已结束进程）。
    func terminateIfStillRunning() {
        guard let process, process.isRunning else { return }
        forceKill(escalating: true)
    }

    private func forceKill(escalating: Bool) {
        let pid = processIdentifier
        guard pid > 0 else { return }

        // 仅杀本进程 PID（不使用 -pid 进程组，避免误伤同组无关进程）
        if let process, process.isRunning {
            process.terminate()
        }
        kill(pid, SIGTERM)
        // 尝试清掉直接子进程（agent CLI 常再 fork）
        SubprocessRunner.killDescendants(of: pid, signal: SIGTERM)

        guard escalating else { return }
        let capturedPID = pid
        let capturedProcess = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            if let capturedProcess, capturedProcess.isRunning {
                kill(capturedPID, SIGKILL)
                SubprocessRunner.killDescendants(of: capturedPID, signal: SIGKILL)
                capturedProcess.interrupt()
            } else {
                var status: Int32 = 0
                if waitpid(capturedPID, &status, WNOHANG) == 0 {
                    kill(capturedPID, SIGKILL)
                    SubprocessRunner.killDescendants(of: capturedPID, signal: SIGKILL)
                }
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

/// 线程安全的管道缓冲（Dispatch 回调写入）。
private final class LocalAIPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }
        set {
            lock.lock()
            _data = newValue
            lock.unlock()
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
            "\(home)/.local/share/pi-node/current/bin",
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
