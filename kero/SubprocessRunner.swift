//
//  SubprocessRunner.swift
//  kero
//
//  统一子进程执行器：全应用唯一的 Process 启动 / 回收路径。
//
//  集中解决以下历史问题（Bad file descriptor / 线程与 fd 泄漏）：
//  - 共享 FileHandle.nullDevice 被 Process 关闭导致全局 EBADF：
//    一律使用独立 EOF stdin pipe，绝不触碰 nullDevice；
//  - 孙进程继承管道写端后，超时 SIGKILL 直接子进程无法解除
//    readToEnd 阻塞 → 读取线程 + fd 永久泄漏（「使用一段时间后」劣化主因）：
//    等待读端带超时，超时后强制 close 读端 FileHandle 制造 EOF，
//    保证 drain 线程必然退出、fd 必然回收；
//  - 超时只杀直接子进程：SIGTERM → 递归子孙 → SIGKILL 整个进程树；
//  - 未 wait 的僵尸进程累积：内部始终 waitUntilExit 回收。
//
//  调用方职责：业务语义（错误文案、重试、EBADF 检测、actor 串行等）保留在
//  各自模块，IO 细节全部下放本执行器。
//

import Foundation

/// 统一子进程执行器。
enum SubprocessRunner {
    /// 一次执行的完整配置。
    struct Config {
        /// 可执行文件绝对路径（不做 PATH 解析）。
        var executable: String
        var arguments: [String] = []
        /// 工作目录；nil 或空字符串时使用调用方当前目录。
        var workingDirectory: String? = nil
        /// 额外环境变量：以「覆盖」语义合并进继承的环境（同 key 后者胜出）。
        var environment: [String: String] = [:]
        /// stdin 内容；nil 表示关闭 stdin（读端 EOF，子进程立即看到 EOF）。
        var stdinData: Data? = nil
        /// 进程最长运行时间；超时后终止整个进程树并标记 timedOut。
        var timeout: TimeInterval = 45
        /// 进程退出（或超时终止）后，等待 drain 线程退出（读端兜底）的宽限。
        /// 正常情况 EOF 即刻到达；仅当孙进程仍持有写端时才消耗此宽限。
        var drainGrace: TimeInterval = 3

        public init(
            executable: String,
            arguments: [String] = [],
            workingDirectory: String? = nil,
            environment: [String: String] = [:],
            stdinData: Data? = nil,
            timeout: TimeInterval = 45,
            drainGrace: TimeInterval = 3
        ) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.stdinData = stdinData
            self.timeout = timeout
            self.drainGrace = drainGrace
        }
    }

    /// 一次执行的完整结果（Data 原样返回，编码由调用方决定）。
    struct Result {
        /// `Process.run()` 是否成功（false 表示启动失败，见 `launchError`）。
        var launched: Bool
        /// 退出码；未启动为 -1。
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        /// 是否因超时被终止（进程树已被清理）。
        var timedOut: Bool
        /// 启动失败时的完整诊断描述（含 domain / code / underlying）；成功时为 nil。
        var launchError: String?
    }

    /// 同步执行一次子进程。阻塞调用线程直到进程退出或超时。
    ///
    /// 调用方应确保在后台线程 / actor 执行器上调用（勿在主线程）。
    static func run(_ config: Config) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.executable)
        process.arguments = config.arguments
        if let dir = config.workingDirectory, !dir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in config.environment {
            env[key] = value
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let data = config.stdinData {
            let stdin = Pipe()
            process.standardInput = stdin
            try? stdin.fileHandleForWriting.write(data)
            try? stdin.fileHandleForWriting.close()
        } else {
            process.standardInput = makeEOFStdinPipe()
        }

        do {
            try process.run()
        } catch {
            return Result(
                launched: false,
                exitCode: -1,
                stdout: Data(),
                stderr: Data(),
                timedOut: false,
                launchError: describeLaunchError(error)
            )
        }

        // 并行 drain stdout / stderr：避免一侧写满管道缓冲导致子进程阻塞死锁。
        let outRead = stdout.fileHandleForReading
        let errRead = stderr.fileHandleForReading
        var outData = Data()
        var errData = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = (try? outRead.readToEnd()) ?? Data()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = (try? errRead.readToEnd()) ?? Data()
            readers.leave()
        }

        let timedOut = !waitForExitTree(process, timeout: max(config.timeout, 0.5))

        // 读端兜底：进程树可能残留持有写端的孙进程（D-state / 忽略信号等），
        // 此时 drain 线程无法等到 EOF。强制关闭读端 FileHandle 使阻塞中的
        // read 立即返回，保证线程与 fd 必然回收；写端持有者随后收到 EPIPE。
        if readers.wait(timeout: .now() + config.drainGrace) == .timedOut {
            try? outRead.close()
            try? errRead.close()
            _ = readers.wait(timeout: .now() + config.drainGrace)
        }

        return Result(
            launched: true,
            exitCode: process.terminationStatus,
            stdout: outData,
            stderr: errData,
            timedOut: timedOut,
            launchError: nil
        )
    }

    // MARK: - 进程树终止

    /// 等待进程退出；超时则 SIGTERM → 递归子孙 → SIGKILL 整个进程树。
    /// 返回是否在超时前正常退出（false = 超时后被终止）。
    private static func waitForExitTree(_ process: Process, timeout: TimeInterval) -> Bool {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .success {
            return true
        }

        let pid = process.processIdentifier
        if pid > 0 {
            process.terminate()
            killDescendants(of: pid, signal: SIGTERM)
        }
        // 优雅退出宽限；SIGTERM 后退出同样属于超时终止。
        if group.wait(timeout: .now() + 1.5) == .success {
            return false
        }
        if pid > 0 {
            kill(pid, SIGKILL)
            killDescendants(of: pid, signal: SIGKILL)
        }
        // 最终回收，避免僵尸进程累积
        process.waitUntilExit()
        return false
    }

    /// 用 `pgrep -P` 递归查找子孙进程并发信号（尽力而为；失败静默）。
    /// 部分 CLI（agent 类）会再 fork 子进程，只杀直接子进程会留下孤儿。
    nonisolated static func killDescendants(of pid: Int32, signal: Int32) {
        guard pid > 1 else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let child = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)),
                  child > 1
            else { continue }
            kill(child, signal)
            killDescendants(of: child, signal: signal)
        }
    }

    // MARK: - 工具

    /// 独立 stdin：写端立即关闭 → 读端 EOF。
    ///
    /// 绝不用共享 `FileHandle.nullDevice`：旧系统上 Process 退出时会关闭其
    /// 底层 fd，导致后续 `Process.run` 稳定 EBADF，且可能误关已复用的 fd。
    nonisolated static func makeEOFStdinPipe() -> Pipe {
        let pipe = Pipe()
        try? pipe.fileHandleForWriting.close()
        return pipe
    }

    /// 把 `Process.run` 的 Error 展开为可读诊断（domain / code / underlying）。
    nonisolated static func describeLaunchError(_ error: Error) -> String {
        let ns = error as NSError
        var lines: [String] = [
            error.localizedDescription,
            "Launch failed: \(ns.domain) code \(ns.code)",
        ]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append(
                "Underlying: \(underlying.domain) code \(underlying.code) — \(underlying.localizedDescription)"
            )
        }
        return lines.joined(separator: "\n")
    }
}
