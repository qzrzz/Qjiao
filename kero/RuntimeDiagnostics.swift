//
//  RuntimeDiagnostics.swift
//  kero
//
//  长时间运行异常的低依赖诊断器。诊断路径本身不启动子进程，避免在 FD
//  已耗尽或 Process.run 已失效时令故障进一步恶化。
//

import Darwin
import Foundation

nonisolated final class RuntimeDiagnostics: @unchecked Sendable {
    struct Token: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct LiveEvent: Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let category: String
        let name: String
        let phase: String
        let elapsedMilliseconds: Int?
        let metadata: [String: String]
    }

    struct ActiveOperationSnapshot: Identifiable, Sendable {
        let id: UUID
        let category: String
        let name: String
        let elapsedMilliseconds: Int
        let warningAfterMilliseconds: Int
    }

    struct LiveSnapshot: Sendable {
        let generatedAt: Date
        let openFileDescriptors: Int32
        let softFileDescriptorLimit: UInt64?
        let hardFileDescriptorLimit: UInt64?
        let recordedEventCount: Int
        let events: [LiveEvent]
        let activeOperations: [ActiveOperationSnapshot]
    }

    private struct Event: Codable, Sendable {
        let timestamp: TimeInterval
        let category: String
        let name: String
        let phase: String
        let elapsedMilliseconds: Int?
        let metadata: [String: String]
    }

    private struct ActiveOperation: Sendable {
        let category: String
        let name: String
        let startedAt: Date
        let warningAfter: TimeInterval
        let metadata: [String: String]
        var reportedStall: Bool
    }

    private struct ActiveOperationReport: Codable, Sendable {
        let category: String
        let name: String
        let elapsedMilliseconds: Int
        let warningAfterMilliseconds: Int
        let metadata: [String: String]
    }

    private struct FileDescriptorSnapshot: Codable, Sendable {
        let open: Int32
        let softLimit: UInt64?
        let hardLimit: UInt64?
    }

    private struct Report: Codable, Sendable {
        let schemaVersion: Int
        let generatedAt: TimeInterval
        let reason: String
        let appVersion: String
        let appBuild: String
        let operatingSystem: String
        let processIdentifier: Int32
        let fileDescriptors: FileDescriptorSnapshot
        let recentEvents: [Event]
        let activeOperations: [ActiveOperationReport]
    }

    static let shared = RuntimeDiagnostics()

    private let lock = NSLock()
    private let writerQueue = DispatchQueue(
        label: "com.qzrzz.qjiao.runtime-diagnostics.writer",
        qos: .utility
    )
    private var events: [Event] = []
    private var activeOperations: [UUID: ActiveOperation] = [:]
    private var fdSamples: [Int32] = []
    private var started = false
    private var lastAutomaticReportAt = Date.distantPast

    private static let maximumEventCount = 1_000
    private static let maximumFDSampleCount = 10
    private static let automaticReportCooldown: TimeInterval = 60
    private static let maximumReportCount = 20

    private init() {}

    /// 启动常驻健康巡检。幂等，可在应用初始化阶段安全重复调用。
    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        appendEventLocked(
            Event(
                timestamp: Date().timeIntervalSince1970,
                category: "runtime",
                name: "diagnostics",
                phase: "started",
                elapsedMilliseconds: nil,
                metadata: [:]
            )
        )
        lock.unlock()
        scheduleHealthCheck(after: 10)
    }

    /// 登记一个可能卡住的操作。metadata 只能放离散状态，不应放命令参数或路径。
    func begin(
        category: String,
        name: String,
        warningAfter: TimeInterval,
        metadata: [String: String] = [:]
    ) -> Token {
        let token = Token(id: UUID())
        let safeMetadata = sanitize(metadata)
        lock.lock()
        activeOperations[token.id] = ActiveOperation(
            category: sanitize(category),
            name: sanitize(name),
            startedAt: Date(),
            warningAfter: max(warningAfter, 1),
            metadata: safeMetadata,
            reportedStall: false
        )
        appendEventLocked(
            Event(
                timestamp: Date().timeIntervalSince1970,
                category: sanitize(category),
                name: sanitize(name),
                phase: "started",
                elapsedMilliseconds: nil,
                metadata: safeMetadata
            )
        )
        lock.unlock()
        return token
    }

    func end(
        _ token: Token,
        outcome: String,
        metadata: [String: String] = [:]
    ) {
        let endedAt = Date()
        lock.lock()
        guard let operation = activeOperations.removeValue(forKey: token.id) else {
            lock.unlock()
            return
        }
        let elapsed = Int(endedAt.timeIntervalSince(operation.startedAt) * 1_000)
        appendEventLocked(
            Event(
                timestamp: endedAt.timeIntervalSince1970,
                category: operation.category,
                name: operation.name,
                phase: sanitize(outcome),
                elapsedMilliseconds: elapsed,
                metadata: sanitize(metadata)
            )
        )
        lock.unlock()

        if outcome == "timed-out" || outcome == "watchdog" || outcome == "launch-failed" {
            capture(reason: "\(operation.category).\(operation.name).\(outcome)")
        }
    }

    /// 提供给 Diagnostics 窗口的线程安全只读快照。
    func liveSnapshot() -> LiveSnapshot {
        let now = Date()
        lock.lock()
        let recordedEventCount = events.count
        let liveEvents = events.suffix(200).reversed().map { event in
            LiveEvent(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: event.timestamp),
                category: event.category,
                name: event.name,
                phase: event.phase,
                elapsedMilliseconds: event.elapsedMilliseconds,
                metadata: event.metadata
            )
        }
        let operations = activeOperations.map { id, operation in
            ActiveOperationSnapshot(
                id: id,
                category: operation.category,
                name: operation.name,
                elapsedMilliseconds: Int(now.timeIntervalSince(operation.startedAt) * 1_000),
                warningAfterMilliseconds: Int(operation.warningAfter * 1_000)
            )
        }.sorted { $0.elapsedMilliseconds > $1.elapsedMilliseconds }
        lock.unlock()

        let descriptors = fileDescriptorSnapshot()
        return LiveSnapshot(
            generatedAt: now,
            openFileDescriptors: descriptors.open,
            softFileDescriptorLimit: descriptors.softLimit,
            hardFileDescriptorLimit: descriptors.hardLimit,
            recordedEventCount: recordedEventCount,
            events: liveEvents,
            activeOperations: operations
        )
    }

    func generateManualReport() {
        capture(reason: "manual", force: true)
    }

    /// 立即生成一份诊断报告；自动触发会限流，避免同一故障产生大量文件。
    func capture(reason: String, force: Bool = false) {
        let now = Date()
        lock.lock()
        if !force,
           now.timeIntervalSince(lastAutomaticReportAt) < Self.automaticReportCooldown {
            lock.unlock()
            return
        }
        if !force {
            lastAutomaticReportAt = now
        }
        let recentEvents = events
        let operations = activeOperations.values.map { operation in
            ActiveOperationReport(
                category: operation.category,
                name: operation.name,
                elapsedMilliseconds: Int(now.timeIntervalSince(operation.startedAt) * 1_000),
                warningAfterMilliseconds: Int(operation.warningAfter * 1_000),
                metadata: operation.metadata
            )
        }
        lock.unlock()

        let report = Report(
            schemaVersion: 1,
            generatedAt: now.timeIntervalSince1970,
            reason: sanitize(reason),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processIdentifier: getpid(),
            fileDescriptors: fileDescriptorSnapshot(),
            recentEvents: recentEvents,
            activeOperations: operations.sorted { $0.elapsedMilliseconds > $1.elapsedMilliseconds }
        )
        writerQueue.async { [self] in
            write(report)
        }
    }

    private func scheduleHealthCheck(after delay: TimeInterval) {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay) { [self] in
            performHealthCheck()
            scheduleHealthCheck(after: 30)
        }
    }

    private func performHealthCheck() {
        let now = Date()
        let fdCount = SubprocessRunner.currentOpenFileDescriptorCount()
        var reasons: [String] = []

        lock.lock()
        fdSamples.append(fdCount)
        if fdSamples.count > Self.maximumFDSampleCount {
            fdSamples.removeFirst(fdSamples.count - Self.maximumFDSampleCount)
        }
        appendEventLocked(
            Event(
                timestamp: now.timeIntervalSince1970,
                category: "runtime",
                name: "file-descriptors",
                phase: "sample",
                elapsedMilliseconds: nil,
                metadata: ["open": "\(fdCount)"]
            )
        )

        #if DEBUG
        let warningThreshold: Int32 = 300
        #else
        let warningThreshold: Int32 = 1_500
        #endif
        if fdCount >= warningThreshold {
            reasons.append("fd-threshold")
        }
        if fdSamples.count >= 6,
           zip(fdSamples, fdSamples.dropFirst()).allSatisfy({ nextPair in
               nextPair.1 > nextPair.0
           }),
           let first = fdSamples.first,
           fdCount - first >= 10 {
            reasons.append("fd-sustained-growth")
        }

        for (id, var operation) in activeOperations {
            guard !operation.reportedStall,
                  now.timeIntervalSince(operation.startedAt) >= operation.warningAfter else { continue }
            operation.reportedStall = true
            activeOperations[id] = operation
            reasons.append("\(operation.category).\(operation.name).stalled")
        }
        lock.unlock()

        if let reason = reasons.first {
            NSLog("qjiao runtime diagnostics warning: %@ (open fd: %d)", reason, fdCount)
            capture(reason: reason)
        }
    }

    private func appendEventLocked(_ event: Event) {
        events.append(event)
        if events.count > Self.maximumEventCount {
            events.removeFirst(events.count - Self.maximumEventCount)
        }
    }

    private func fileDescriptorSnapshot() -> FileDescriptorSnapshot {
        var limit = rlimit()
        let hasLimit = getrlimit(RLIMIT_NOFILE, &limit) == 0
        return FileDescriptorSnapshot(
            open: SubprocessRunner.currentOpenFileDescriptorCount(),
            softLimit: hasLimit ? UInt64(limit.rlim_cur) : nil,
            hardLimit: hasLimit ? UInt64(limit.rlim_max) : nil
        )
    }

    private func write(_ report: Report) {
        do {
            let directory = Self.diagnosticsDirectoryURL
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let timestamp = formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent(
                "runtime-\(timestamp)-\(UUID().uuidString.prefix(8)).json"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: url, options: .atomic)
            trimOldReports(in: directory)
            NSLog("qjiao runtime diagnostic report: %@", url.path)
        } catch {
            NSLog("qjiao failed to write runtime diagnostic report: %@", error.localizedDescription)
        }
    }

    private func trimOldReports(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let reports = urls
            .filter { $0.lastPathComponent.hasPrefix("runtime-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for url in reports.dropFirst(Self.maximumReportCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func sanitize(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata.prefix(20) {
            result[sanitize(key)] = sanitize(value)
        }
        return result
    }

    private func sanitize(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: " ")
        return String(normalized.prefix(160))
    }

    static var diagnosticsDirectoryURL: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["QJIAO_DIAGNOSTICS_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let applicationDirectory = "qjiao-dev"
        #else
        let applicationDirectory = "qjiao"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(applicationDirectory)/diagnostics", isDirectory: true)
    }
}
