//
//  SidebarProbe.swift
//  kero
//

import Darwin
import Foundation

/// 右侧 Project / Info 共用的进程、端口与 package.json 采集。
/// - 进程/端口：一次 `ps` + 一次 `lsof`，按 shell pid 集合取子孙并集。
/// - scripts：只读指定目录下的 `package.json`，不搜索子目录。
enum SidebarProbe {
    // MARK: - Types

    struct PackageScript: Identifiable, Equatable {
        let name: String
        let command: String
        var id: String { name }
    }

    /// `package.json` 中的包元数据信息（名称、版本、仓库地址）。
    struct PackageInfo: Equatable {
        let name: String?
        let version: String?
        let repositoryUrl: String?

        /// 是否包含至少一项有效数据。
        nonisolated var hasContent: Bool {
            !(name?.isEmpty ?? true) || !(version?.isEmpty ?? true) || !(repositoryUrl?.isEmpty ?? true)
        }
    }

    struct ProcessItem: Identifiable, Equatable {
        var id: pid_t { pid }
        let pid: pid_t
        /// 可执行名，如 `node`。
        let name: String
        /// 完整路径，供 tooltip。
        let executable: String
        let cpu: Double
        /// RSS，单位 KB。
        let memoryKB: Int

        var memoryLabel: String {
            memoryKB >= 1024
                ? String(format: "%.0f MB", Double(memoryKB) / 1024)
                : "\(memoryKB) KB"
        }
    }

    struct PortItem: Identifiable, Equatable {
        nonisolated var id: String { "\(pid):\(port)" }
        let port: Int
        let pid: pid_t
        /// 该监听进程所属的终端 shell，用于精确绑定脚本状态。
        let rootShellPid: pid_t
        let processName: String

        var url: URL? { URL(string: "http://localhost:\(port)/") }
    }

    /// `package.json` 元数据；用于跳过未变更的解码。
    struct PackageFileState: Equatable {
        let exists: Bool
        let modificationDate: Date?
        let size: UInt64?
    }

    // MARK: - Processes / ports

    /// 对多个 shell 根做子孙并集（pid 去重）；单 session 传一个 pid 即可。
    /// 一次 `ps` 建树，再一次 `lsof` 查监听端口，避免按 session 重复扫全机。
    nonisolated static func collect(shellPids: [pid_t]) -> ([ProcessItem], [PortItem]) {
        let roots = Array(Set(shellPids.filter { $0 > 0 })).sorted()
        guard !roots.isEmpty else { return ([], []) }

        let psOut = run("/bin/ps", ["-axo", "pid=,ppid=,state=,pcpu=,rss=,comm="])
        var itemsByPid: [pid_t: ProcessItem] = [:]
        var childPids: [pid_t: [pid_t]] = [:]
        for line in psOut.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            // Z 状态是已经退出、等待父进程回收的条目，既无可查看输出也无法终止。
            guard !fields[2].hasPrefix("Z") else { continue }
            let executable = String(fields[5])
            itemsByPid[pid] = ProcessItem(
                pid: pid,
                name: (executable as NSString).lastPathComponent,
                executable: executable,
                cpu: Double(fields[3]) ?? 0,
                memoryKB: Int(fields[4]) ?? 0
            )
            childPids[ppid, default: []].append(pid)
        }

        // 按 shell 顺序 BFS，已见 pid 跳过（跨 session 共用子树时去重）。
        var processes: [ProcessItem] = []
        var seen = Set<pid_t>()
        var rootByPid: [pid_t: pid_t] = Dictionary(
            uniqueKeysWithValues: roots.map { ($0, $0) }
        )
        for shellPid in roots {
            var queue = childPids[shellPid] ?? []
            var queueIndex = 0
            while queueIndex < queue.count {
                let pid = queue[queueIndex]
                queueIndex += 1
                guard seen.insert(pid).inserted else { continue }
                rootByPid[pid] = shellPid
                if let item = itemsByPid[pid] {
                    processes.append(item)
                }
                queue.append(contentsOf: childPids[pid] ?? [])
            }
        }

        let portPids = roots + processes.map(\.pid)
        let ports = listeningPorts(
            pids: portPids,
            itemsByPid: itemsByPid,
            rootByPid: rootByPid
        )
        return (processes, ports)
    }

    nonisolated static func kill(_ pid: pid_t, force: Bool) {
        Darwin.kill(pid, force ? SIGKILL : SIGTERM)
    }

    // MARK: - package.json

    nonisolated static func packageFileState(directory: String) -> PackageFileState {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return PackageFileState(exists: false, modificationDate: nil, size: nil)
        }
        return PackageFileState(
            exists: true,
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.uint64Value
        )
    }

    /// 读取 `<directory>/package.json` 的 `scripts`；不存在或解析失败返回空。
    nonisolated static func loadPackageScripts(directory: String) -> [PackageScript] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let package = object as? [String: Any],
              let scripts = package["scripts"] as? [String: String]
        else { return [] }

        return scripts
            .map { PackageScript(name: $0.key, command: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 读取 `<directory>/package.json` 的 `name`、`version` 与 `repository` 信息。
    /// - Parameter directory: 目标目录路径
    /// - Returns: 解析到的 PackageInfo 结构体；若文件不存在或全空则返回 nil
    nonisolated static func loadPackageInfo(directory: String) -> PackageInfo? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let package = object as? [String: Any]
        else { return nil }

        let name = package["name"] as? String
        let version = package["version"] as? String

        var repoUrlString: String? = nil
        if let repoString = package["repository"] as? String {
            repoUrlString = sanitizeRepositoryUrl(repoString)
        } else if let repoDict = package["repository"] as? [String: Any],
                  let urlString = repoDict["url"] as? String {
            repoUrlString = sanitizeRepositoryUrl(urlString)
        }

        let info = PackageInfo(
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines),
            version: version?.trimmingCharacters(in: .whitespacesAndNewlines),
            repositoryUrl: repoUrlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return info.hasContent ? info : nil
    }

    /// 清理并规范化 repository 仓库 URL，转为适合浏览器直接打开的 http(s) 链接
    /// - Parameter raw: 原始 package.json 中的 repository 字符串
    /// - Returns: 格式化后的 URL 字符串
    private nonisolated static func sanitizeRepositoryUrl(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasPrefix("git+") {
            url = String(url.dropFirst(4))
        }
        if url.hasPrefix("git://") {
            url = "https://" + url.dropFirst(6)
        }
        if url.hasPrefix("github:") {
            url = "https://github.com/" + url.dropFirst(7)
        }
        if url.hasPrefix("git@") {
            let parts = url.dropFirst(4).split(separator: ":")
            if parts.count == 2 {
                url = "https://\(parts[0])/\(parts[1])"
            }
        }
        if url.hasSuffix(".git") {
            url = String(url.dropLast(4))
        }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }
        return url
    }

    // MARK: - Package Manager Detection

    /// 包管理工具信息与命令生成结构体
    struct PackageManagerInfo: Equatable {
        let name: String

        var installCommand: String { "\(name) install" }
        var publishCommand: String { "\(name) publish" }
        var updateCommand: String {
            name == "yarn" ? "yarn upgrade" : "\(name) update"
        }
    }

    /// 智能检测目标项目所使用的包管理工具（优先级：package.json packageManager > lockfile > 全局设置 > npm）
    /// - Parameters:
    ///   - directory: 项目根目录路径
    ///   - globalSetting: 全局设置中配置的包管理器命令
    /// - Returns: 检测到的 PackageManagerInfo
    nonisolated static func detectPackageManager(directory: String, globalSetting: String = "") -> PackageManagerInfo {
        let packageUrl = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageUrl),
           let object = try? JSONSerialization.jsonObject(with: data),
           let package = object as? [String: Any],
           let pmField = (package["packageManager"] as? String)?.lowercased() {
            if pmField.contains("bun") { return PackageManagerInfo(name: "bun") }
            if pmField.contains("pnpm") { return PackageManagerInfo(name: "pnpm") }
            if pmField.contains("yarn") { return PackageManagerInfo(name: "yarn") }
            if pmField.contains("npm") { return PackageManagerInfo(name: "npm") }
        }

        let fm = FileManager.default
        let path = { (filename: String) -> String in
            URL(fileURLWithPath: directory).appendingPathComponent(filename).path
        }

        if fm.fileExists(atPath: path("bun.lock")) || fm.fileExists(atPath: path("bun.lockb")) {
            return PackageManagerInfo(name: "bun")
        }
        if fm.fileExists(atPath: path("pnpm-lock.yaml")) {
            return PackageManagerInfo(name: "pnpm")
        }
        if fm.fileExists(atPath: path("yarn.lock")) {
            return PackageManagerInfo(name: "yarn")
        }
        if fm.fileExists(atPath: path("package-lock.json")) || fm.fileExists(atPath: path("npm-shrinkwrap.json")) {
            return PackageManagerInfo(name: "npm")
        }

        let lowerGlobal = globalSetting.lowercased()
        if lowerGlobal.contains("bun") { return PackageManagerInfo(name: "bun") }
        if lowerGlobal.contains("pnpm") { return PackageManagerInfo(name: "pnpm") }
        if lowerGlobal.contains("yarn") { return PackageManagerInfo(name: "yarn") }
        if lowerGlobal.contains("npm") { return PackageManagerInfo(name: "npm") }

        return PackageManagerInfo(name: "npm")
    }

    // MARK: - SemVer & Version bump

    /// 智能将版本号中最后一个连续的数字片段 +1
    nonisolated static func bumpVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        let pattern = #"\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex.matches(in: trimmed, range: range)
        guard let lastMatch = matches.last, let matchRange = Range(lastMatch.range, in: trimmed) else {
            return trimmed + ".1"
        }
        let numString = String(trimmed[matchRange])
        if let num = Int(numString) {
            var result = trimmed
            result.replaceSubrange(matchRange, with: String(num + 1))
            return result
        }
        return raw
    }

    /// 智能将版本号中最后一个连续的数字片段 -1
    nonisolated static func decrementVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        let pattern = #"\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex.matches(in: trimmed, range: range)
        guard let lastMatch = matches.last, let matchRange = Range(lastMatch.range, in: trimmed) else {
            return trimmed
        }
        let numString = String(trimmed[matchRange])
        if let num = Int(numString) {
            let prev = max(0, num - 1)
            var result = trimmed
            result.replaceSubrange(matchRange, with: String(prev))
            return result
        }
        return raw
    }

    /// SemVer 版本号计算与更新辅助工具
    struct SemVerComponents: Equatable {
        let raw: String
        let prefix: String
        let numbers: [Int]

        /// 主版本号递增（例：1.2.3 -> 2.0.0）
        var major: String {
            var nums = numbers
            if nums.isEmpty { nums = [0, 0, 0] }
            nums[0] += 1
            while nums.count < 3 { nums.append(0) }
            for i in 1..<nums.count { nums[i] = 0 }
            return prefix + nums.map(String.init).joined(separator: ".")
        }

        /// 次版本号递增（例：1.2.3 -> 1.3.0）
        var minor: String {
            var nums = numbers
            while nums.count < 2 { nums.append(0) }
            nums[1] += 1
            while nums.count < 3 { nums.append(0) }
            for i in 2..<nums.count { nums[i] = 0 }
            return prefix + nums.map(String.init).joined(separator: ".")
        }

        /// 补丁版本号递增（例：1.2.3 -> 1.2.4）
        var patch: String {
            var nums = numbers
            while nums.count < 3 { nums.append(0) }
            nums[2] += 1
            return prefix + nums.map(String.init).joined(separator: ".")
        }
    }

    /// 解析语义化版本号
    nonisolated static func parseSemVer(_ versionString: String) -> SemVerComponents {
        let trimmed = versionString.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefix = ""
        var body = trimmed
        if trimmed.lowercased().hasPrefix("v") {
            prefix = String(trimmed.prefix(1))
            body = String(trimmed.dropFirst(1))
        }

        let parts = body.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        return SemVerComponents(raw: versionString, prefix: prefix, numbers: parts)
    }

    /// 修改指定目录 package.json 中的 version 字段，保留原 JSON 的排版与缩进
    /// - Parameters:
    ///   - directory: 项目根目录
    ///   - newVersion: 目标新版本号
    /// - Returns: 是否更新成功
    @discardableResult
    nonisolated static func updatePackageVersion(directory: String, newVersion: String) -> Bool {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              var content = String(data: data, encoding: .utf8) else { return false }

        let pattern = #"("version"\s*:\s*")[^"]+(")"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(location: 0, length: content.utf16.count)

        if regex.firstMatch(in: content, options: [], range: range) != nil {
            content = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: "$1\(newVersion)$2")
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    /// 在后台异步创建 Git Tag
    /// - Parameters:
    ///   - directory: Git 仓库工作目录
    ///   - tagName: 目标 Tag 标签名（如 "v1.0.0"）
    nonisolated static func createGitTag(directory: String, tagName: String) {
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["tag", tagName]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            try? process.run()
        }
    }

    // MARK: - Private

    private nonisolated static func listeningPorts(
        pids: [pid_t],
        itemsByPid: [pid_t: ProcessItem],
        rootByPid: [pid_t: pid_t]
    ) -> [PortItem] {
        guard !pids.isEmpty else { return [] }
        // 去重后再拼 -p，lsof 列表过长时仍只查相关 pid。
        let unique = Array(Set(pids)).sorted()
        let list = unique.map(String.init).joined(separator: ",")
        let out = run(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", list, "-Fpn"]
        )

        var ports: [PortItem] = []
        var seen = Set<String>()
        var currentPid: pid_t = 0
        for line in out.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                currentPid = pid_t(value) ?? 0
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let item = PortItem(
                    port: port,
                    pid: currentPid,
                    rootShellPid: rootByPid[currentPid] ?? currentPid,
                    processName: itemsByPid[currentPid]?.name ?? "?"
                )
                if seen.insert(item.id).inserted {
                    ports.append(item)
                }
            default:
                break
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    private nonisolated static func run(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        // 用临时文件承接输出，避免 ps 输出超过 Pipe 缓冲区时与 wait 互相阻塞。
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qjiao-sidebar-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL)
        else { return "" }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ""
        }

        // ps/lsof 正常应在毫秒级返回；同时响应 Task 取消，并设置 3 秒硬超时。
        let deadline = Date().addingTimeInterval(3)
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            let isCancelled = withUnsafeCurrentTask { task in
                task?.isCancelled ?? false
            }
            guard !isCancelled, Date() < deadline else {
                process.terminate()
                if finished.wait(timeout: .now() + 0.25) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 0.5)
                }
                break
            }
        }

        try? output.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
