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

import Darwin
import Foundation

/// 统一子进程执行器。
nonisolated enum SubprocessRunner {
    /// 一次执行的完整配置。
    struct Config: Sendable {
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
    struct Result: Sendable {
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
    nonisolated static func run(_ config: Config) -> Result {
        ensureStandardFileDescriptorsOpen()
        let diagnosticToken = RuntimeDiagnostics.shared.begin(
            category: "subprocess",
            name: URL(fileURLWithPath: config.executable).lastPathComponent,
            warningAfter: max(config.timeout + 4, 5),
            metadata: ["timeout-seconds": String(format: "%.1f", config.timeout)]
        )
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
        // 必须为子进程创建独立的 stdin Pipe，避免继承父进程 terminal fd。
        // 关键点：绝对不可在 process.run() 之前关闭 fileHandleForWriting！
        // posix_spawn 会自动对 Pipe 的句柄进行重定向；如果在 posix_spawn 前就 close 写端 fd，
        // 系统在 posix_spawn file actions 处理已关闭的描述符时会直接抛出 EBADF (NSPOSIXErrorDomain code 9)。
        let stdin = Pipe()
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            try? stdin.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
            let launchError = describeLaunchError(error)
            RuntimeDiagnostics.shared.end(
                diagnosticToken,
                outcome: "launch-failed",
                metadata: [
                    "error-domain": (error as NSError).domain,
                    "error-code": "\((error as NSError).code)",
                ]
            )
            return Result(
                launched: false,
                exitCode: -1,
                stdout: Data(),
                stderr: Data(),
                timedOut: false,
                launchError: launchError
            )
        }

        // 进程拉起成功后，写完 stdin 内容（若有）并关闭写端，向子进程发送 EOF
        if let data = config.stdinData {
            try? stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

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

        // 显式回收所有 Pipe 的读写句柄，杜绝文件描述符 (FD) 泄漏
        try? stdin.fileHandleForReading.close()
        try? outRead.close()
        try? stdout.fileHandleForWriting.close()
        try? errRead.close()
        try? stderr.fileHandleForWriting.close()

        let result = Result(
            launched: true,
            // 极端情况下进程陷入不可中断的内核 I/O，SIGKILL 后仍不会立刻
            // reap。此时绝不能再读 terminationStatus（仅退出后有效），更不能
            // 为了回收而无限阻塞刷新链路。
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            stdout: outData,
            stderr: errData,
            timedOut: timedOut,
            launchError: nil
        )
        RuntimeDiagnostics.shared.end(
            diagnosticToken,
            outcome: timedOut ? "timed-out" : "completed",
            metadata: ["exit-code": "\(result.exitCode)"]
        )
        return result
    }

    // MARK: - 进程树终止

    /// 等待进程退出；超时则 SIGTERM → 递归子孙 → SIGKILL 整个进程树。
    /// 返回是否在超时前正常退出（false = 超时后被终止）。
    private static func waitForExitTree(_ process: Process, timeout: TimeInterval) -> Bool {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if !process.isRunning || exited.wait(timeout: .now() + timeout) == .success {
            process.terminationHandler = nil
            return true
        }

        let pid = process.processIdentifier
        if pid > 0 {
            process.terminate()
            killDescendants(of: pid, signal: SIGTERM)
        }
        // 优雅退出宽限；SIGTERM 后退出同样属于超时终止。
        if exited.wait(timeout: .now() + 1.5) == .success {
            process.terminationHandler = nil
            return false
        }
        if pid > 0 {
            kill(pid, SIGKILL)
            killDescendants(of: pid, signal: SIGKILL)
        }
        // SIGKILL 后也只给有限宽限。D-state / 坏网络卷上的进程可能无法立即
        // 退出；继续 waitUntilExit 会把 Git / Project 刷新永久卡在 spinner。
        // Foundation 在真正退出时仍会执行 terminationHandler 并完成回收。
        _ = exited.wait(timeout: .now() + 2)
        process.terminationHandler = nil
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
        let errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do {
            try task.run()
            // pgrep 只是超时清理的辅助工具，本身也必须有上限，否则会让原命令
            // 已超时后仍卡在“查找子进程”。
            if exited.wait(timeout: .now() + 2) == .timedOut, task.isRunning {
                task.terminate()
                _ = exited.wait(timeout: .now() + 1)
            }
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForWriting.close()
            return
        }
        task.terminationHandler = nil
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForWriting.close()

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

    /// 确保标准文件描述符（0: stdin, 1: stdout, 2: stderr）在当前进程中保持打开状态。
    ///
    /// 在 macOS GUI 应用中，若标准句柄被意外关闭，新创建的 Pipe 会被分配到 0/1/2 号句柄。
    /// 随后 Cocoa Process.run() 的 posix_spawn file actions 在重定向并关闭句柄时，会把 Pipe 的读写端误关，
    /// 抛出 EBADF (NSPOSIXErrorDomain code 9)。此函数确保 0/1/2 描述符始终有效。
    nonisolated static func ensureStandardFileDescriptorsOpen() {
        for fd in Int32(0)...Int32(2) {
            if fcntl(fd, F_GETFD) == -1 {
                let flags = (fd == 0) ? O_RDONLY : O_WRONLY
                let devNull = open("/dev/null", flags)
                if devNull != -1 && devNull != fd {
                    dup2(devNull, fd)
                    close(devNull)
                }
            }
        }
    }

    /// 在应用启动时提升当前进程的 open file descriptor 软限制（rlimit）。
    ///
    /// macOS 默认给 GUI App 设置的软限制较小（通常为 256 或 1024）。将软限制提升至
    /// 65536（不超过系统硬限制）可为多项目、多终端 Tab 及并发 Git 扫描提供安全缓冲；
    /// 这不是泄漏修复，设置失败必须保留诊断。
    nonisolated static func boostFileDescriptorLimit() {
        ensureStandardFileDescriptorsOpen()
        var rl = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &rl) == 0 else {
            NSLog("qjiao: getrlimit(RLIMIT_NOFILE) failed: errno=\(errno)")
            return
        }

        let requestedLimit = rlim_t(65536)
        let targetLimit = min(requestedLimit, rl.rlim_max)
        guard targetLimit > rl.rlim_cur else { return }

        var updated = rl
        updated.rlim_cur = targetLimit
        guard setrlimit(RLIMIT_NOFILE, &updated) == 0 else {
            NSLog(
                "qjiao: setrlimit(RLIMIT_NOFILE) failed: errno=\(errno), "
                    + "soft=\(rl.rlim_cur), hard=\(rl.rlim_max), target=\(targetLimit)"
            )
            return
        }

        var verified = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &verified) == 0,
              verified.rlim_cur >= targetLimit
        else {
            NSLog("qjiao: rlimit verification failed after setrlimit")
            return
        }
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

    /// 启动运行时健康巡检。除 FD 阈值外，还会检测持续增长与卡住的刷新操作，
    /// 并在异常时写入脱敏 JSON 报告。
    nonisolated static func startFDMonitor() {
        RuntimeDiagnostics.shared.start()
    }

    /// 获取当前进程打开的文件描述符数量（仅在统计与巡检时使用）。
    nonisolated static func currentOpenFileDescriptorCount() -> Int32 {
        var count: Int32 = 0
        let tableSize = getdtablesize()
        for fd in 0..<tableSize {
            if fcntl(fd, F_GETFD) != -1 {
                count += 1
            }
        }
        return count
    }
}
