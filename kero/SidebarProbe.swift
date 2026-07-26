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
        var id: String { "\(pid):\(port)" }
        let port: Int
        let pid: pid_t
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

        let psOut = run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,comm="])
        var itemsByPid: [pid_t: ProcessItem] = [:]
        var childPids: [pid_t: [pid_t]] = [:]
        for line in psOut.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            let executable = String(fields[4])
            itemsByPid[pid] = ProcessItem(
                pid: pid,
                name: (executable as NSString).lastPathComponent,
                executable: executable,
                cpu: Double(fields[2]) ?? 0,
                memoryKB: Int(fields[3]) ?? 0
            )
            childPids[ppid, default: []].append(pid)
        }

        // 按 shell 顺序 BFS，已见 pid 跳过（跨 session 共用子树时去重）。
        var processes: [ProcessItem] = []
        var seen = Set<pid_t>()
        for shellPid in roots {
            var queue = childPids[shellPid] ?? []
            while !queue.isEmpty {
                let pid = queue.removeFirst()
                guard seen.insert(pid).inserted else { continue }
                if let item = itemsByPid[pid] {
                    processes.append(item)
                }
                queue.append(contentsOf: childPids[pid] ?? [])
            }
        }

        let portPids = roots + processes.map(\.pid)
        let ports = listeningPorts(pids: portPids, itemsByPid: itemsByPid)
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

    // MARK: - Private

    private nonisolated static func listeningPorts(
        pids: [pid_t], itemsByPid: [pid_t: ProcessItem]
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

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
