//
//  SystemInfoModel.swift
//  kero
//

import Combine
import Foundation

/// 系统代理摘要（来自 `scutil --proxy`）。
struct SystemProxyInfo: Equatable {
    var enabled: Bool
    /// 一行摘要，如 `HTTP 127.0.0.1:7890` 或 `Off`。
    var summary: String
    /// HTTP URL 使用的代理。
    var httpProxyURL: String?
    /// HTTPS URL 使用的代理。
    var httpsProxyURL: String?
    /// 未配置对应 HTTP(S) 代理时可回退使用的 SOCKS 代理。
    var socksProxyURL: String?
    /// 系统自动代理配置（PAC）的地址；curl 无法直接执行 PAC 时保留此值以报告原因。
    var pacURL: String?
    /// 系统启用了 WPAD 自动发现；curl 无法直接执行该配置。
    var wpadEnabled: Bool
    /// 系统设置中应绕过代理的主机模式。
    var bypassHosts: [String]
    /// 系统设置中是否绕过无点号的简单主机名。
    var excludeSimpleHostnames: Bool

    /// 供界面展示和复制的优先代理端点。
    var curlProxyURL: String? { httpsProxyURL ?? httpProxyURL ?? socksProxyURL }

    /// 终端代理环境变量（zsh/bash 一行 `export`）；无可用 HTTP(S)/SOCKS 时为 nil。
    /// 示例：`export https_proxy=http://127.0.0.1:1886 http_proxy=http://127.0.0.1:1886 all_proxy=socks5://127.0.0.1:1886`
    var shellExportCommand: String? {
        let http = httpProxyURL
        let https = httpsProxyURL
        // shell 侧常用 socks5；curl 探测用的 socks5h 在此转为 socks5。
        let socks = socksProxyURL.map {
            $0.replacingOccurrences(of: "socks5h://", with: "socks5://")
        }

        // 仅 SOCKS：三项都指向 SOCKS。
        if http == nil, https == nil, let socks {
            return "export https_proxy=\(socks) http_proxy=\(socks) all_proxy=\(socks)"
        }

        var assignments: [String] = []
        // 顺序与常见终端习惯一致：https → http → all。
        if let https {
            assignments.append("https_proxy=\(https)")
        } else if let http {
            // 仅有 HTTP 代理时，HTTPS 也指向同一端点。
            assignments.append("https_proxy=\(http)")
        }
        if let http {
            assignments.append("http_proxy=\(http)")
        } else if let https {
            assignments.append("http_proxy=\(https)")
        }
        if let socks {
            assignments.append("all_proxy=\(socks)")
        } else if let fallback = https ?? http {
            // 无 SOCKS 时用 HTTP 代理填 all_proxy，便于 git 等读取。
            assignments.append("all_proxy=\(fallback)")
        }

        guard !assignments.isEmpty else { return nil }
        return "export " + assignments.joined(separator: " ")
    }
}

/// curl 依据目标 URL 与系统代理设置得到的连接方式。
private enum CurlProxyDecision {
    case direct
    case proxy(String)
    case unsupported(String)
}

private extension SystemProxyInfo {
    /// 按目标协议和系统例外规则决定 curl 的代理参数。
    nonisolated func decision(for url: URL) -> CurlProxyDecision {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else {
            return .unsupported("Invalid URL")
        }
        if shouldBypassProxy(for: host) { return .direct }
        if pacURL != nil || wpadEnabled {
            return .unsupported("System PAC/WPAD proxy is not supported")
        }
        switch scheme {
        case "http":
            if let httpProxyURL { return .proxy(httpProxyURL) }
        case "https":
            if let httpsProxyURL { return .proxy(httpsProxyURL) }
        default:
            return .unsupported("Only HTTP and HTTPS URLs are supported")
        }
        if let socksProxyURL { return .proxy(socksProxyURL) }
        return .direct
    }

    /// scutil 的 ExceptionsList 常见形式为域名、`.example.com` 或 `*.example.com`。
    private nonisolated func shouldBypassProxy(for host: String) -> Bool {
        if excludeSimpleHostnames, !host.contains(".") { return true }
        return bypassHosts.contains { raw in
            let rule = raw.lowercased()
            if rule == "*" || rule == host { return true }
            let suffix = rule.hasPrefix("*.") ? String(rule.dropFirst()) : rule
            return suffix.hasPrefix(".") && host.hasSuffix(suffix)
        }
    }
}

/// 一次 CLI 采集快照；字段均为可选，单项失败时 UI 显示 —。
struct SystemSnapshot: Equatable {
    var cpuUsagePercent: Double?
    var memoryTotalBytes: UInt64?
    /// 与活动监视器「已使用内存」一致：App + Wired + Compressed（不含文件缓存）。
    var memoryUsedBytes: UInt64?
    /// App 内存（匿名页 − purgeable），与活动监视器「App 内存」对齐。
    var memoryAppBytes: UInt64?
    /// Wired（不可换出）。
    var memoryWiredBytes: UInt64?
    /// Compressor 占用的物理页（活动监视器「被压缩」）。
    var memoryCompressedBytes: UInt64?
    /// 文件缓存（file-backed pages），可被系统回收。
    var memoryCachedBytes: UInt64?
    /// 真正空闲页（Pages free）。
    var memoryFreeBytes: UInt64?
    /// 交换区已用 / 总量（`sysctl vm.swapusage`）。
    var memorySwapUsedBytes: UInt64?
    var memorySwapTotalBytes: UInt64?
    var diskTotalBytes: UInt64?
    var diskFreeBytes: UInt64?
    /// 最近 1 分钟磁盘传输量（字节）；折线采样源。
    /// 注：macOS iostat 的 MB 为设备读写合计，无单独写入列。
    var diskWriteBytesLastMinute: Double?
    /// 自首次磁盘检测起的累计传输量（字节）；行内文本展示。
    var diskWriteBytesSession: Double?
    /// 自首次磁盘检测起的累计时长（秒）。
    var diskWriteElapsedSeconds: TimeInterval?
    var netDownloadBytesPerSec: Double?
    var netUploadBytesPerSec: Double?
    /// 本机局域网 IPv4（优先默认路由网卡）。
    var localIPv4Address: String?
    /// 对应网卡名，如 `en0` / `en6`。
    var localIPv4Interface: String?
    /// 本机出口 IP（通过 Cloudflare trace 获取）。
    var publicIPv4Address: String?
    /// 出口 IP 所在国家/地区代码（如 `JP`）。
    var publicIPLocation: String?
    /// 出口 IP 所在国家/地区的 Emoji 国旗（如 `🇯🇵`）。
    var publicIPLocationEmoji: String?
    var proxy: SystemProxyInfo?
    var reachability: [SystemReachabilityItem] = []
    var updatedAt: Date?
}

/// `iostat -Id` 累计字节采样点（约每 30s 一拍）。
private struct DiskIOCumulativeSample: Equatable {
    var at: Date
    var totalBytes: UInt64
}

/// 采集本机系统信息。
///
/// CPU / 内存 / 网络 / 磁盘容量 / 代理 / 本机 IP 走原生 Darwin / SystemConfiguration API
/// （见 `SystemNative`，无子进程、开销极低）；仅 `iostat -Id`（磁盘写入量，30s 一拍）与
/// `curl`（出口 IP、可达性探测）保留命令执行，便于日后 SSH 复用命令表。
@MainActor
final class SystemInfoModel: nonisolated ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var isRefreshing = false
    /// IP 地址（局域网 & 出口 IP）是否正在刷新中。
    @Published private(set) var isRefreshingIP = false
    /// CPU 占用率历史（0...100），供一行高折线使用。
    @Published private(set) var cpuHistory: [Double] = []
    /// 内存使用率历史（0...1）。
    @Published private(set) var memoryHistory: [Double] = []
    /// 最近 1 分钟磁盘传输量历史（字节），供折线使用；每 30s 一点。
    @Published private(set) var diskWriteHistory: [Double] = []

    /// 可达性站点（可编辑，持久化）。
    @Published private(set) var sites: [ReachabilitySite]
    /// 可达性探测间隔。
    @Published private(set) var reachabilityInterval: ReachabilityInterval

    /// CPU/Mem 折线保留采样点数（约 2s × 60 ≈ 2 分钟）。
    static let historyCapacity = 60
    /// 磁盘折线保留点数（30s × 60 ≈ 30 分钟）。
    static let diskWriteHistoryCapacity = 60

    private let runner: any SystemCommandRunner
    private var pollTask: Task<Void, Never>?
    private var reachTask: Task<Void, Never>?
    /// 每次重启轮询都会更换，用于阻止已取消轮次继续发车。
    private var reachScheduleID = UUID()
    private var isActive = false
    /// 手动刷新可打断「进行中」的节流，排队一次 forceSlow。
    private var pendingForceRefresh = false
    /// 正在探测中的站点（UI 显示 `...`）。
    @Published private(set) var probingSiteIDs: Set<UUID> = []

    /// 速率采样的上一拍累计字节。
    private var lastNetIn: UInt64?
    private var lastNetOut: UInt64?
    private var lastNetAt: Date?
    /// 磁盘累计传输采样（约 30s 一拍，用于最近 1 分钟窗口）。
    private var diskIOSamples: [DiskIOCumulativeSample] = []
    /// 会话起点：首次成功采样时的设备累计字节。
    private var diskIOSessionBaseline: UInt64?
    /// 会话起点时间。
    private var diskIOSessionStartedAt: Date?
    /// 上次磁盘写入检测时间。
    private var lastDiskIOSampleAt: Date?
    /// 磁盘写入检测间隔。
    private static let diskIOSampleInterval: TimeInterval = 30
    /// 最近 1 分钟窗口长度。
    private static let diskWriteWindow: TimeInterval = 60
    /// 采样保留略长于窗口，便于取窗口起点基线。
    private static let diskIOSampleRetain: TimeInterval = 120

    private var lastPublicIPAt: Date?
    private var cachedMemTotal: UInt64?
    /// 上一次 CPU 累计 tick（host_statistics），用于两拍差分。
    private var lastCpuTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    /// 各站点历史采样（按 id）。
    private var reachHistory: [UUID: [ReachabilitySample]] = [:]
    /// 各站点最近一次失败原因（成功后仍保留，直到下次失败覆盖）。
    private var lastErrors: [UUID: String] = [:]

    init(runner: any SystemCommandRunner = LocalProcessRunner()) {
        self.runner = runner
        let loaded = ReachabilityStore.loadSites()
        self.sites = loaded
        self.reachabilityInterval = AppSettings.shared.systemReachabilityInterval
        self.snapshot.reachability = loaded.map {
            SystemReachabilityItem(
                id: $0.id, name: $0.name, url: $0.url, method: $0.method,
                status: .unknown, history: [], lastError: nil
            )
        }
    }

    /// 右侧 System 可见且下半区展开时启动轮询；否则停止。
    func setActive(_ active: Bool) {
        guard active != isActive else {
            if active {
                Task { await refresh(forceSlow: false) }
                restartReachabilityLoop()
            }
            return
        }
        isActive = active
        pollTask?.cancel()
        pollTask = nil
        reachTask?.cancel()
        reachTask = nil
        guard active else {
            // 停用时清空磁盘会话与采样，下次打开重新累计。
            resetDiskIOSession()
            return
        }
        pollTask = Task { [weak self] in
            self?.initializeBaselines()
            // 首拍留 1s 采样窗口，让 CPU 差分立即有值（原 top -l 2 首显约 1.8s）。
            try? await Task.sleep(for: .seconds(1))
            await self?.refresh(forceSlow: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await self?.refresh(forceSlow: false)
            }
        }
        restartReachabilityLoop()
    }

    /// UI 手动刷新：强制慢指标（不含可达性间隔逻辑）。
    func refreshNow() {
        Task { await refresh(forceSlow: true, manual: true) }
    }

    // MARK: - Reachability configuration

    func setReachabilityInterval(_ interval: ReachabilityInterval) {
        reachabilityInterval = interval
        AppSettings.shared.systemReachabilityInterval = interval
        if interval == .off {
            // 关闭时清空列表展示（保留配置 sites）。
            var snap = snapshot
            snap.reachability = []
            snapshot = snap
        } else {
            rebuildReachabilityItemsPreservingHistory()
        }
        restartReachabilityLoop()
    }

    func addSite(name: String, url: String, method: ReachabilityHTTPMethod = .get) {
        let site = ReachabilitySite(name: name, url: url, method: method)
        sites.append(site)
        ReachabilityStore.saveSites(sites)
        rebuildReachabilityItemsPreservingHistory()
        // 站点数量改变后重排自动探测时间槽。
        restartReachabilityLoop()
        Task { await probeSites(ids: [site.id]) }
    }

    func updateSite(id: UUID, name: String, url: String, method: ReachabilityHTTPMethod) {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        let shouldReprobe = sites[index].url != url || sites[index].method != method
        sites[index].name = name
        sites[index].url = url
        sites[index].method = method
        ReachabilityStore.saveSites(sites)
        rebuildReachabilityItemsPreservingHistory()
        // URL 或 HTTP 方法变更后立刻按新配置重测。
        if shouldReprobe {
            Task { await probeSites(ids: [id]) }
        }
    }

    func deleteSite(id: UUID) {
        sites.removeAll { $0.id == id }
        reachHistory[id] = nil
        lastErrors[id] = nil
        ReachabilityStore.saveSites(sites)
        rebuildReachabilityItemsPreservingHistory()
        // 站点数量改变后重排自动探测时间槽。
        restartReachabilityLoop()
    }

    func setSiteMethod(id: UUID, method: ReachabilityHTTPMethod) {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        guard sites[index].method != method else { return }
        sites[index].method = method
        ReachabilityStore.saveSites(sites)
        rebuildReachabilityItemsPreservingHistory()
        Task { await probeSites(ids: [id]) }
    }

    func probeSiteNow(id: UUID) {
        Task { await probeSites(ids: [id]) }
    }

    func probeAllNow() {
        Task { await probeSites(ids: sites.map(\.id)) }
    }

    private func rebuildReachabilityItemsPreservingHistory() {
        guard reachabilityInterval != .off else {
            var snap = snapshot
            snap.reachability = []
            snapshot = snap
            return
        }
        var snap = snapshot
        snap.reachability = sites.map { site in
            let prev = snapshot.reachability.first { $0.id == site.id }
            return SystemReachabilityItem(
                id: site.id,
                name: site.name,
                url: site.url,
                method: site.method,
                status: prev?.status ?? .unknown,
                history: reachHistory[site.id] ?? prev?.history ?? [],
                lastError: lastErrors[site.id] ?? prev?.lastError
            )
        }
        snapshot = snap
    }

    private func restartReachabilityLoop() {
        // 已发出的 curl 由 probingSiteIDs 去重；旧轮尚未发出的请求用 token 阻止。
        reachScheduleID = UUID()
        reachTask?.cancel()
        reachTask = nil
        guard isActive, let seconds = reachabilityInterval.seconds else { return }
        let scheduleID = reachScheduleID
        reachTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let ids = self.sites.map(\.id)
                guard !ids.isEmpty else {
                    try? await Task.sleep(for: .seconds(seconds))
                    continue
                }

                // 每到用户设定的间隔准点开启一轮；同轮请求间隔 1 秒。
                // 批次独立发车，因此站点数多于间隔秒数时也不会推迟下一轮开始。
                Task { [weak self, ids] in
                    for (index, id) in ids.enumerated() {
                        guard let self,
                              self.reachScheduleID == scheduleID,
                              self.isActive,
                              self.reachabilityInterval.seconds != nil
                        else { break }
                        Task { [weak self] in
                            await self?.probeSites(ids: [id])
                        }
                        if index < ids.count - 1 {
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// 强制刷新本机局域网 IP 与出口 IP，并同步更新 isRefreshingIP 动画状态。
    func refreshIP() async {
        guard isActive else { return }
        guard !isRefreshingIP else { return }
        isRefreshingIP = true
        defer { isRefreshingIP = false }

        let runner = self.runner
        async let publicIPResult = optionalRun(runner, ["curl", "-sS", "--connect-timeout", "3", "--max-time", "5", "https://cloudflare.com/cdn-cgi/trace"], timeout: .seconds(6))
        let publicIPOut = await publicIPResult

        var next = snapshot

        // 本机局域网 IP：原生读路由表 + getifaddrs，瞬时完成。
        let preferredIF = SystemNative.primaryInterface()
        if let local = SystemNative.localIPv4(preferredInterface: preferredIF) {
            next.localIPv4Address = local.address
            next.localIPv4Interface = local.interface
        } else {
            next.localIPv4Address = nil
            next.localIPv4Interface = nil
        }

        if let publicIPOut, let parsed = Self.parseCloudflareTrace(publicIPOut) {
            next.publicIPv4Address = parsed.ip
            next.publicIPLocation = parsed.loc
            next.publicIPLocationEmoji = parsed.emoji
        } else {
            next.publicIPv4Address = nil
            next.publicIPLocation = nil
            next.publicIPLocationEmoji = nil
        }
        lastPublicIPAt = Date()

        next.updatedAt = Date()
        if snapshot != next {
            snapshot = next
        }
    }

    func refresh(forceSlow: Bool = true, manual: Bool = false) async {
        guard isActive else { return }
        if isRefreshing {
            if manual || forceSlow { pendingForceRefresh = true }
            return
        }
        isRefreshing = true
        // 出口 IP 仍需联网 curl（15s 节流）；本地 IP 走原生 API，瞬时完成无需节流。
        let wantPublicIP = forceSlow || lastPublicIPAt.map { Date().timeIntervalSince($0) >= 15 } ?? true
        if wantPublicIP { isRefreshingIP = true }

        defer {
            if wantPublicIP { isRefreshingIP = false }
            isRefreshing = false
            if pendingForceRefresh {
                pendingForceRefresh = false
                Task { await self.refresh(forceSlow: true, manual: true) }
            }
        }

        let runner = self.runner
        // 磁盘写入量：iostat -Id 每 30s 一拍（手动/force 可立刻采）。
        let wantDiskIO = forceSlow || manual
            || lastDiskIOSampleAt.map { Date().timeIntervalSince($0) >= Self.diskIOSampleInterval } ?? true

        // 仅剩两个联网 / 低频命令走子进程：Cloudflare trace（出口 IP，15s）与
        // iostat（磁盘写入量，30s）。其余指标全部由原生 API 采集（SystemNative）。
        async let publicIPResult = wantPublicIP
            ? optionalRun(runner, ["curl", "-sS", "--connect-timeout", "3", "--max-time", "5", "https://cloudflare.com/cdn-cgi/trace"], timeout: .seconds(6))
            : nil
        async let iostatResult = wantDiskIO
            ? optionalRun(runner, ["iostat", "-Id"], timeout: .seconds(3))
            : nil

        let publicIPOut = await publicIPResult
        let iostatOut = await iostatResult

        var next = snapshot

        // CPU：host_statistics 两次累计 tick 差分，得到窗口内平均占用率。
        if let ticks = SystemNative.cpuLoadInfo() {
            if let previous = lastCpuTicks {
                let deltaUser = Self.deltaTick(ticks.user, previous.user)
                let deltaSystem = Self.deltaTick(ticks.system, previous.system)
                let deltaIdle = Self.deltaTick(ticks.idle, previous.idle)
                let deltaNice = Self.deltaTick(ticks.nice, previous.nice)
                let total = deltaUser + deltaSystem + deltaIdle + deltaNice
                if total > 0 {
                    let busy = deltaUser + deltaSystem + deltaNice
                    next.cpuUsagePercent = min(max(Double(busy) / Double(total) * 100, 0), 100)
                }
            }
            lastCpuTicks = ticks
        }

        // 内存：host_statistics64 → 与活动监视器一致的 Used / App / Wired / Compressed / Cached。
        if let vm = SystemNative.vmStatistics() {
            applyVmStatSample(vm, to: &next)
        }

        if let (used, total) = SystemNative.swapUsage() {
            next.memorySwapUsedBytes = used
            next.memorySwapTotalBytes = total
        }

        if let total = SystemNative.hardwareMemory() {
            cachedMemTotal = total
            next.memoryTotalBytes = total
        } else if let cached = cachedMemTotal {
            next.memoryTotalBytes = cached
        }

        if let (total, free) = SystemNative.diskCapacity() {
            next.diskTotalBytes = total
            next.diskFreeBytes = free
        }

        // 网络速率：getifaddrs 网卡累计字节差分（原 netstat -ib）。
        if let (inBytes, outBytes) = SystemNative.networkCounters() {
            applyNetworkCounters(inBytes: inBytes, outBytes: outBytes, to: &next)
        }

        // 累计 MB → 最近 1 分钟量 + 会话累计 + 累计时长；并追加折线点。
        var didSampleDiskIO = false
        if let iostatOut, let totalBytes = Self.parseIostatCumulativeBytes(iostatOut) {
            applyDiskIOSample(totalBytes, to: &next)
            didSampleDiskIO = true
        } else {
            // 非采样拍：保留上次磁盘写入字段。
            next.diskWriteBytesLastMinute = snapshot.diskWriteBytesLastMinute
            next.diskWriteBytesSession = snapshot.diskWriteBytesSession
            next.diskWriteElapsedSeconds = snapshot.diskWriteElapsedSeconds
        }

        next.proxy = SystemNative.proxyInfo()

        // 本机局域网 IP：默认路由网卡（路由表）+ getifaddrs 地址表。
        let preferredIF = SystemNative.primaryInterface()
        if let local = SystemNative.localIPv4(preferredInterface: preferredIF) {
            next.localIPv4Address = local.address
            next.localIPv4Interface = local.interface
        } else {
            // 无有效局域网 IPv4：清空，避免残留离线地址。
            next.localIPv4Address = nil
            next.localIPv4Interface = nil
        }

        if wantPublicIP {
            if let publicIPOut, let parsed = Self.parseCloudflareTrace(publicIPOut) {
                next.publicIPv4Address = parsed.ip
                next.publicIPLocation = parsed.loc
                next.publicIPLocationEmoji = parsed.emoji
            } else {
                next.publicIPv4Address = nil
                next.publicIPLocation = nil
                next.publicIPLocationEmoji = nil
            }
            lastPublicIPAt = Date()
        } else {
            next.publicIPv4Address = snapshot.publicIPv4Address
            next.publicIPLocation = snapshot.publicIPLocation
            next.publicIPLocationEmoji = snapshot.publicIPLocationEmoji
        }

        // 可达性由独立 reachTask 按间隔探测，避免拖慢 2s 资源轮询。
        next.reachability = snapshot.reachability

        next.updatedAt = Date()
        if snapshot != next {
            snapshot = next
        }
        // CPU/Mem 每拍追加；磁盘折线仅在 30s 写入采样时追加。
        appendHistories(from: next, includeDiskWrite: didSampleDiskIO)
    }

    /// 探测指定站点（走系统代理），并追加柱状图历史。
    private func probeSites(ids: [UUID]) async {
        guard isActive, reachabilityInterval != .off else { return }
        let pending = ids.filter { !probingSiteIDs.contains($0) }
        guard !pending.isEmpty else { return }

        probingSiteIDs.formUnion(pending)
        // 探测中把对应行标为 unknown，延迟栏显示 `...`；保留 lastError。
        var snap = snapshot
        snap.reachability = sites.map { site in
            let prev = snap.reachability.first { $0.id == site.id }
            let checking = pending.contains(site.id)
            return SystemReachabilityItem(
                id: site.id,
                name: site.name,
                url: site.url,
                method: site.method,
                status: checking ? .unknown : (prev?.status ?? .unknown),
                history: reachHistory[site.id] ?? prev?.history ?? [],
                lastError: lastErrors[site.id] ?? prev?.lastError
            )
        }
        snapshot = snap

        defer { probingSiteIDs.subtract(pending) }

        let proxy: SystemProxyInfo
        if let existing = snapshot.proxy {
            proxy = existing
        } else {
            proxy = SystemNative.proxyInfo()
        }
        let targets = sites.filter { pending.contains($0.id) }
        let runner = self.runner

        let results: [(UUID, SystemReachabilityStatus, ReachabilitySample)] = await withTaskGroup(
            of: (UUID, SystemReachabilityStatus, ReachabilitySample).self
        ) { group in
            for site in targets {
                group.addTask {
                    await Self.probeOne(runner: runner, site: site, proxy: proxy)
                }
            }
            var list: [(UUID, SystemReachabilityStatus, ReachabilitySample)] = []
            for await item in group { list.append(item) }
            return list
        }

        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.0, ($0.1, $0.2)) })
        for site in targets {
            guard let (status, sample) = byId[site.id] else { continue }
            var hist = reachHistory[site.id] ?? []
            hist.append(sample)
            if hist.count > ReachabilityBarMetrics.historyCapacity {
                hist.removeFirst(hist.count - ReachabilityBarMetrics.historyCapacity)
            }
            reachHistory[site.id] = hist
            // 仅在失败时覆盖 lastError；成功后仍保留上一次错误供复制。
            if let message = status.errorMessage, !message.isEmpty {
                lastErrors[site.id] = message
            }
        }

        snap = snapshot
        snap.reachability = sites.map { site in
            let prev = snap.reachability.first { $0.id == site.id }
            let status = byId[site.id]?.0 ?? prev?.status ?? .unknown
            return SystemReachabilityItem(
                id: site.id,
                name: site.name,
                url: site.url,
                method: site.method,
                status: status,
                history: reachHistory[site.id] ?? [],
                lastError: lastErrors[site.id] ?? prev?.lastError
            )
        }
        snapshot = snap
    }

    /// 将当前快照压入定长环形缓冲，供 sparkline 绘制。
    private func appendHistories(from snap: SystemSnapshot, includeDiskWrite: Bool) {
        if let cpu = snap.cpuUsagePercent {
            append(&cpuHistory, min(max(cpu, 0), 100), capacity: Self.historyCapacity)
        }
        if let used = snap.memoryUsedBytes, let total = snap.memoryTotalBytes, total > 0 {
            append(&memoryHistory, min(max(Double(used) / Double(total), 0), 1), capacity: Self.historyCapacity)
        }
        // 磁盘折线只用「最近 1 分钟传输量」，且仅 30s 采样拍追加。
        if includeDiskWrite, let lastMin = snap.diskWriteBytesLastMinute {
            append(&diskWriteHistory, max(lastMin, 0), capacity: Self.diskWriteHistoryCapacity)
        }
    }

    private func append(_ series: inout [Double], _ value: Double, capacity: Int) {
        series.append(value)
        if series.count > capacity {
            series.removeFirst(series.count - capacity)
        }
    }

    private func resetDiskIOSession() {
        diskIOSamples = []
        diskIOSessionBaseline = nil
        diskIOSessionStartedAt = nil
        lastDiskIOSampleAt = nil
        diskWriteHistory = []
        var snap = snapshot
        snap.diskWriteBytesLastMinute = nil
        snap.diskWriteBytesSession = nil
        snap.diskWriteElapsedSeconds = nil
        snapshot = snap
    }

    private func optionalRun(
        _ runner: any SystemCommandRunner,
        _ argv: [String],
        timeout: Duration
    ) async -> String? {
        guard let result = try? await runner.run(argv: argv, timeout: timeout) else { return nil }
        return result.stdout
    }

    /// 用 host_statistics64 写入与活动监视器一致的 Used / App / Wired / Compressed / Cached。
    private func applyVmStatSample(_ sample: VmStatSample, to snapshot: inout SystemSnapshot) {
        snapshot.memoryUsedBytes = sample.usedBytes
        snapshot.memoryAppBytes = sample.appBytes
        snapshot.memoryWiredBytes = sample.wiredBytes
        snapshot.memoryCompressedBytes = sample.compressedBytes
        snapshot.memoryCachedBytes = sample.cachedBytes
        snapshot.memoryFreeBytes = sample.freeBytes
    }

    /// 每 30s 用 `iostat -Id` 设备累计字节，更新：
    /// - 最近 1 分钟传输量（折线）
    /// - 会话累计传输量（文本）
    /// - 累计时长
    private func applyDiskIOSample(_ totalBytes: UInt64, to snapshot: inout SystemSnapshot) {
        let now = Date()
        lastDiskIOSampleAt = now

        // 会话起点：第一次成功检测。
        if diskIOSessionBaseline == nil {
            diskIOSessionBaseline = totalBytes
            diskIOSessionStartedAt = now
        }
        if let baseline = diskIOSessionBaseline, totalBytes >= baseline {
            snapshot.diskWriteBytesSession = Double(totalBytes - baseline)
        }
        if let started = diskIOSessionStartedAt {
            snapshot.diskWriteElapsedSeconds = now.timeIntervalSince(started)
        }

        diskIOSamples.append(DiskIOCumulativeSample(at: now, totalBytes: totalBytes))
        let retainBefore = now.addingTimeInterval(-Self.diskIOSampleRetain)
        diskIOSamples.removeAll { $0.at < retainBefore }

        // 最近 1 分钟：至少两拍才能差分。
        guard diskIOSamples.count >= 2 else {
            snapshot.diskWriteBytesLastMinute = 0
            return
        }
        let windowStart = now.addingTimeInterval(-Self.diskWriteWindow)
        // 优先取 ≤ 窗口起点的最近样本；未满 1 分钟则用最早样本。
        let windowBaseline = diskIOSamples.last(where: { $0.at <= windowStart })
            ?? diskIOSamples.first
        guard let windowBaseline, totalBytes >= windowBaseline.totalBytes else {
            snapshot.diskWriteBytesLastMinute = 0
            return
        }
        snapshot.diskWriteBytesLastMinute = Double(totalBytes - windowBaseline.totalBytes)
    }

    /// 在刚打开 System 面板时奠定原生采样基线：网卡累计字节 + CPU tick，
    /// 让首轮刷新即可差分出速率 / 占用率，而不是显示破折号 "—"。
    private func initializeBaselines() {
        if lastNetIn == nil, let (inBytes, outBytes) = SystemNative.networkCounters() {
            lastNetIn = inBytes
            lastNetOut = outBytes
            lastNetAt = Date()
            snapshot.netDownloadBytesPerSec = 0
            snapshot.netUploadBytesPerSec = 0
        }
        if lastCpuTicks == nil {
            lastCpuTicks = SystemNative.cpuLoadInfo()
        }
    }

    /// UInt32 tick 差分包回绕（host_cpu_load_info 的 tick 为 natural_t）。
    private nonisolated static func deltaTick(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous
            ? current - previous
            : current + (UInt64(UInt32.max) + 1) - previous
    }

    /// 用 netstat 精确字节计数做差分；in→下载，out→上传。
    private func applyNetworkCounters(inBytes: UInt64, outBytes: UInt64, to snapshot: inout SystemSnapshot) {
        let now = Date()
        if let lastIn = lastNetIn, let lastOut = lastNetOut, let lastAt = lastNetAt {
            let dt = now.timeIntervalSince(lastAt)
            if dt > 0.1 {
                let downRate = inBytes >= lastIn ? Double(inBytes - lastIn) / dt : 0
                let upRate = outBytes >= lastOut ? Double(outBytes - lastOut) / dt : 0
                snapshot.netDownloadBytesPerSec = downRate
                snapshot.netUploadBytesPerSec = upRate
                lastNetIn = inBytes
                lastNetOut = outBytes
                lastNetAt = now
            } else {
                // 两次采样间隔低于 100ms 时，保留当前速率状态，不重置采样基线
                snapshot.netDownloadBytesPerSec = snapshot.netDownloadBytesPerSec ?? 0
                snapshot.netUploadBytesPerSec = snapshot.netUploadBytesPerSec ?? 0
            }
        } else {
            // 首次采样（备用逻辑）：确立基线并初始化为 0 B/s，避免显示破折号 "—"
            snapshot.netDownloadBytesPerSec = 0
            snapshot.netUploadBytesPerSec = 0
            lastNetIn = inBytes
            lastNetOut = outBytes
            lastNetAt = now
        }
    }

    // MARK: - iostat / curl 解析

    /// 解析 `iostat -Id`：各盘累计 MB 之和 → 字节。
    /// 格式示例：`KB/t  xfrs  MB` 三列一组；首行数据为启动以来累计。
    private nonisolated static func parseIostatCumulativeBytes(_ output: String) -> UInt64? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let dataLines = lines.filter { line in
            let lower = line.lowercased()
            return !lower.contains("kb/t") && !lower.hasPrefix("disk")
        }
        // 单次 -Id 只有一行累计；若带 -w 多拍也取第一行（启动以来总量）。
        guard let first = dataLines.first else { return nil }
        let nums = first.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        var sumMB = 0.0
        var i = 2
        while i < nums.count {
            sumMB += nums[i]
            i += 3
        }
        guard sumMB >= 0 else { return nil }
        return UInt64((sumMB * 1_024 * 1_024).rounded())
    }

    private nonisolated static func probeOne(
        runner: any SystemCommandRunner,
        site: ReachabilitySite,
        proxy: SystemProxyInfo
    ) async -> (UUID, SystemReachabilityStatus, ReachabilitySample) {
        guard let url = URL(string: site.url),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return probeFailure(site, reason: "Only HTTP and HTTPS URLs are supported")
        }
        let proxyDecision = proxy.decision(for: url)
        if case .unsupported(let reason) = proxyDecision {
            return probeFailure(site, reason: reason)
        }

        // -sS 静默但仍报错；-o /dev/null 丢弃 GET 响应体。
        // HEAD 的响应头可能仍写到 stdout，故通过唯一标记提取 -w 结果。
        // time_starttransfer 更接近「首字节」延迟；-L 跟随重定向。
        var argv = [
            "curl", "-q", "-sS", "-o", "/dev/null",
            "-w", "\\n__QJIAO_CURL_RESULT__ %{http_code} %{time_starttransfer}",
            "--connect-timeout", "2",
            "--max-time", "4",
            "-L",
            "--max-redirs", "5",
            "--proto", "=http,https",
            "--proto-redir", "=http,https",
        ]
        // GET 是 curl 默认方法；HEAD 必须用 -I，不能只改写请求方法字符串。
        if site.method == .head {
            argv.append("-I")
        }
        if case .proxy(let proxyURL) = proxyDecision {
            argv += ["-x", proxyURL]
        }
        // --url 令以 - 开头的配置值也只会被当作 URL，而不会成为 curl 参数。
        argv += ["--url", site.url]

        do {
            let result = try await runner.run(argv: argv, timeout: .seconds(6))
            let parts = result.stdout
                .components(separatedBy: "__QJIAO_CURL_RESULT__")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                ?? []
            let code = parts.first.flatMap { Int($0) } ?? 0
            let transfer = parts.dropFirst().first.flatMap { Double($0) }
            // 夹在合理范围，避免异常大数把 UI 撑破。
            let ms = transfer.map { max(min(Int(($0 * 1000).rounded()), 99_999), 0) } ?? 0
            // 定义为“能访问到网站”：收到任意有效 HTTP 响应即表示可达。
            if (100...599).contains(code) {
                return (
                    site.id,
                    .reachable(latencyMs: ms),
                    .init(latencyMs: ms, ok: true)
                )
            }
            let stderr = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let methodTag = site.method.rawValue
            let reason: String
            if code > 0 {
                let base = "\(methodTag) HTTP \(code)"
                reason = stderr.isEmpty ? base : "\(base): \(stderr)"
            } else if !stderr.isEmpty {
                reason = "\(methodTag): \(stderr)"
            } else {
                reason = "\(methodTag) failed"
            }
            // 保留完整错误（上限防止异常 stderr 撑爆剪贴板）；UI 复制用 lastError。
            return (
                site.id,
                .unreachable(reason: String(reason.prefix(2_000))),
                .init(latencyMs: nil, ok: false)
            )
        } catch {
            let message = "\(site.method.rawValue): \(error.localizedDescription)"
            return (
                site.id,
                .unreachable(reason: String(message.prefix(2_000))),
                .init(latencyMs: nil, ok: false)
            )
        }
    }

    private nonisolated static func probeFailure(
        _ site: ReachabilitySite,
        reason: String
    ) -> (UUID, SystemReachabilityStatus, ReachabilitySample) {
        let message = "\(site.method.rawValue): \(reason)"
        return (
            site.id,
            .unreachable(reason: String(message.prefix(2_000))),
            .init(latencyMs: nil, ok: false)
        )
    }

    // MARK: - Cloudflare trace / 国旗解析

    /// 解析 `cloudflare.com/cdn-cgi/trace` 输出，提取出口 `ip` 与位置代码 `loc`，并将 `loc` 转换为 Emoji 国旗图标。
    /// - Parameter text: cloudflare trace 返回的 Key-Value 文本
    /// - Returns: 包含出口 IP、位置代码与 Emoji 图标的元组，若未找到 IP 则返回 nil
    private nonisolated static func parseCloudflareTrace(_ text: String) -> (ip: String, loc: String?, emoji: String?)? {
        var ip: String?
        var loc: String?
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                if key == "ip" && !val.isEmpty {
                    ip = val
                } else if key == "loc" && !val.isEmpty {
                    loc = val
                }
            }
        }
        guard let ip = ip else { return nil }
        let emoji = loc.flatMap { countryCodeToEmoji($0) }
        return (ip, loc, emoji)
    }

    /// 将两位 ISO 3166-1 alpha-2 国家/地区代码转换为 Emoji 国旗图标（例如 "JP" -> "🇯🇵"）。
    /// - Parameter code: 两位大写或小写的 ISO 国家/地区代码
    /// - Returns: 对应的 Emoji 国旗字符串，格式不合法时返回 nil
    private nonisolated static func countryCodeToEmoji(_ code: String) -> String? {
        let uppercase = code.uppercased()
        guard uppercase.count == 2 else { return nil }
        var emoji = ""
        for scalar in uppercase.unicodeScalars {
            guard scalar.value >= 0x41 && scalar.value <= 0x5A else { return nil }
            guard let regionalScalar = UnicodeScalar(0x1F1E6 + (scalar.value - 0x41)) else { return nil }
            emoji.unicodeScalars.append(regionalScalar)
        }
        return emoji
    }
}
