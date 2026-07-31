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

/// `top` 解析出的瞬时字段（CPU 为主；内存仅作 vm_stat 失败时的回退）。
private struct TopSample: Equatable {
    var cpuUsagePercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryUnusedBytes: UInt64?
    var memoryWiredBytes: UInt64?
    var memoryCompressedBytes: UInt64?
}

/// `vm_stat` 解析结果：对齐活动监视器的内存分类。
private struct VmStatSample: Equatable {
    var pageSize: UInt64
    var freePages: UInt64
    var wiredPages: UInt64
    var purgeablePages: UInt64
    var anonymousPages: UInt64
    var fileBackedPages: UInt64
    /// Pages occupied by compressor（物理占用，非 stored）。
    var compressorOccupiedPages: UInt64

    /// App 内存 ≈ 匿名页 − 可清除页。
    var appBytes: UInt64 {
        let appPages = anonymousPages > purgeablePages
            ? anonymousPages - purgeablePages
            : 0
        return appPages * pageSize
    }

    var wiredBytes: UInt64 { wiredPages * pageSize }
    var compressedBytes: UInt64 { compressorOccupiedPages * pageSize }
    var cachedBytes: UInt64 { fileBackedPages * pageSize }
    var freeBytes: UInt64 { freePages * pageSize }
    /// 活动监视器「已使用内存」= App + Wired + Compressed。
    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
}

/// `iostat -Id` 累计字节采样点（约每 30s 一拍）。
private struct DiskIOCumulativeSample: Equatable {
    var at: Date
    var totalBytes: UInt64
}

/// 通过命令行采集本机系统信息；不调用 Darwin/IOKit API，便于日后 SSH 复用命令表。
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

    private var lastDiskCapacityAt: Date?
    private var lastProxyAt: Date?
    private var lastLocalIPAt: Date?
    private var lastPublicIPAt: Date?
    private var lastMemTotalAt: Date?
    private var cachedMemTotal: UInt64?
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
            await self?.initializeNetstatBaseline()
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
        async let routeResult = optionalRun(runner, ["route", "-n", "get", "default"], timeout: .seconds(2))
        async let nwiResult = optionalRun(runner, ["scutil", "--nwi"], timeout: .seconds(3))
        async let publicIPResult = optionalRun(runner, ["curl", "-sS", "--connect-timeout", "3", "--max-time", "5", "https://cloudflare.com/cdn-cgi/trace"], timeout: .seconds(6))

        let routeOut = await routeResult
        let nwiOut = await nwiResult
        let publicIPOut = await publicIPResult

        var next = snapshot

        let preferredIF = routeOut.flatMap(Self.parseDefaultRouteInterface)
        if let nwiOut, let local = Self.parseLocalIPv4(fromNWI: nwiOut, preferredInterface: preferredIF) {
            next.localIPv4Address = local.address
            next.localIPv4Interface = local.interface
        } else {
            next.localIPv4Address = nil
            next.localIPv4Interface = nil
        }
        lastLocalIPAt = Date()

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
        let wantLocalIP = forceSlow || lastLocalIPAt.map { Date().timeIntervalSince($0) >= 15 } ?? true
        let wantPublicIP = forceSlow || lastPublicIPAt.map { Date().timeIntervalSince($0) >= 15 } ?? true
        let refreshingIPThisCycle = wantLocalIP || wantPublicIP
        if refreshingIPThisCycle { isRefreshingIP = true }

        defer {
            if refreshingIPThisCycle { isRefreshingIP = false }
            isRefreshing = false
            if pendingForceRefresh {
                pendingForceRefresh = false
                Task { await self.refresh(forceSlow: true, manual: true) }
            }
        }

        let runner = self.runner
        let wantDisk = forceSlow || lastDiskCapacityAt.map { Date().timeIntervalSince($0) >= 10 } ?? true
        let wantProxy = forceSlow || lastProxyAt.map { Date().timeIntervalSince($0) >= 15 } ?? true
        let wantMemTotal = cachedMemTotal == nil
            || lastMemTotalAt.map { Date().timeIntervalSince($0) >= 60 } ?? true
        // 磁盘写入量：每 30s 一拍（手动/force 可立刻采）。
        let wantDiskIO = forceSlow || manual
            || lastDiskIOSampleAt.map { Date().timeIntervalSince($0) >= Self.diskIOSampleInterval } ?? true

        // 并行跑互不依赖的命令，缩短整轮刷新时间。
        // 网络速率不用 top（累计字节只精确到 G，短间隔差分为 0），改用 netstat -ib。
        // 内存以 vm_stat 为准（对齐活动监视器）；top 的 PhysMem used 含文件缓存会虚高。
        async let topResult = optionalRun(runner, ["top", "-l", "2", "-n", "0", "-s", "1"], timeout: .seconds(8))
        async let vmStatResult = optionalRun(runner, ["vm_stat"], timeout: .seconds(2))
        async let netstatResult = optionalRun(runner, ["netstat", "-ibn"], timeout: .seconds(3))
        async let dfResult = wantDisk
            ? optionalRun(runner, ["df", "-k", "/"], timeout: .seconds(4))
            : nil
        // -I：设备累计 MB（瞬时返回）；每 30s 采样一次。
        async let iostatResult = wantDiskIO
            ? optionalRun(runner, ["iostat", "-Id"], timeout: .seconds(3))
            : nil
        async let proxyResult = wantProxy
            ? optionalRun(runner, ["scutil", "--proxy"], timeout: .seconds(3))
            : nil
        // 本机局域网 IP：默认路由网卡 + scutil --nwi 地址表。
        async let routeResult = wantLocalIP
            ? optionalRun(runner, ["route", "-n", "get", "default"], timeout: .seconds(2))
            : nil
        async let nwiResult = wantLocalIP
            ? optionalRun(runner, ["scutil", "--nwi"], timeout: .seconds(3))
            : nil
        // 本机出口 IP：请求 Cloudflare trace 获取 ip 与 loc。
        async let publicIPResult = wantPublicIP
            ? optionalRun(runner, ["curl", "-sS", "--connect-timeout", "3", "--max-time", "5", "https://cloudflare.com/cdn-cgi/trace"], timeout: .seconds(6))
            : nil
        async let memTotalResult = wantMemTotal
            ? optionalRun(runner, ["sysctl", "-n", "hw.memsize"], timeout: .seconds(2))
            : nil
        // Swap 用量：与 top 同频；输出形如 total = 1024.00M used = 85.31M …
        async let swapResult = optionalRun(runner, ["sysctl", "-n", "vm.swapusage"], timeout: .seconds(2))

        let vmStatOut = await vmStatResult
        let netstatOut = await netstatResult
        let dfOut = await dfResult
        let iostatOut = await iostatResult
        let proxyOut = await proxyResult
        let routeOut = await routeResult
        let nwiOut = await nwiResult
        let publicIPOut = await publicIPResult
        let memTotalOut = await memTotalResult
        let swapOut = await swapResult
        let topOut = await topResult

        var next = snapshot

        if let memTotalOut, let total = UInt64(memTotalOut.trimmingCharacters(in: .whitespacesAndNewlines)) {
            cachedMemTotal = total
            lastMemTotalAt = Date()
            next.memoryTotalBytes = total
        } else if let cached = cachedMemTotal {
            next.memoryTotalBytes = cached
        }

        if let topOut {
            let sample = Self.parseTop(topOut)
            applyTopSample(sample, to: &next)
        }

        // vm_stat 覆盖 top 的 PhysMem used（后者把 Cached Files 算进 used）。
        if let vmStatOut, let vm = Self.parseVmStat(vmStatOut) {
            applyVmStatSample(vm, to: &next)
        }

        if let swapOut, let (used, total) = Self.parseSwapUsage(swapOut) {
            next.memorySwapUsedBytes = used
            next.memorySwapTotalBytes = total
        }

        if let netstatOut, let (inBytes, outBytes) = Self.parseNetstatTotals(netstatOut) {
            applyNetworkCounters(inBytes: inBytes, outBytes: outBytes, to: &next)
        }

        if let dfOut {
            if let (total, free) = Self.parseDf(dfOut) {
                next.diskTotalBytes = total
                next.diskFreeBytes = free
            }
            lastDiskCapacityAt = Date()
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

        if let proxyOut {
            next.proxy = Self.parseProxy(proxyOut)
            lastProxyAt = Date()
        }

        if wantLocalIP {
            let preferredIF = routeOut.flatMap(Self.parseDefaultRouteInterface)
            if let nwiOut, let local = Self.parseLocalIPv4(fromNWI: nwiOut, preferredInterface: preferredIF) {
                next.localIPv4Address = local.address
                next.localIPv4Interface = local.interface
            } else {
                // 无有效局域网 IPv4：清空，避免残留离线地址。
                next.localIPv4Address = nil
                next.localIPv4Interface = nil
            }
            lastLocalIPAt = Date()
        } else {
            next.localIPv4Address = snapshot.localIPv4Address
            next.localIPv4Interface = snapshot.localIPv4Interface
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
        } else if let out = await optionalRun(runner, ["scutil", "--proxy"], timeout: .seconds(3)) {
            proxy = Self.parseProxy(out)
        } else {
            proxy = Self.directProxyInfo
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

    private func applyTopSample(_ sample: TopSample, to snapshot: inout SystemSnapshot) {
        if let cpu = sample.cpuUsagePercent {
            snapshot.cpuUsagePercent = cpu
        }
        // 内存字段仅作 vm_stat 失败时的回退；成功后会被 applyVmStatSample 覆盖。
        // 注意：top 的 PhysMem used ≈ 活动监视器 Used + Cached Files，会虚高。
        if let used = sample.memoryUsedBytes {
            snapshot.memoryUsedBytes = used
        }
        if let wired = sample.memoryWiredBytes {
            snapshot.memoryWiredBytes = wired
        }
        if let compressed = sample.memoryCompressedBytes {
            snapshot.memoryCompressedBytes = compressed
        }
        // 优先 sysctl 总量；否则 used+unused 回退。
        if snapshot.memoryTotalBytes == nil,
           let used = sample.memoryUsedBytes,
           let unused = sample.memoryUnusedBytes {
            snapshot.memoryTotalBytes = used + unused
        }

        // 网络速率改由 netstat 累计字节差分，见 applyNetworkCounters。
        // 磁盘写入量改由 iostat -Id 每 30s 采样，见 applyDiskIOSample。
    }

    /// 用 vm_stat 写入与活动监视器一致的 Used / App / Wired / Compressed / Cached。
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

    /// 在刚打开 System 面板时优先采样一次 netstat 奠定计数基线，并初始化网速为 0 B/s，避免显示破折号 "—"。
    private func initializeNetstatBaseline() async {
        guard lastNetIn == nil, let out = await optionalRun(runner, ["netstat", "-ibn"], timeout: .seconds(2)) else { return }
        if let (inBytes, outBytes) = Self.parseNetstatTotals(out) {
            lastNetIn = inBytes
            lastNetOut = outBytes
            lastNetAt = Date()
            snapshot.netDownloadBytesPerSec = 0
            snapshot.netUploadBytesPerSec = 0
        }
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

    // MARK: - top / vm_stat 解析

    private nonisolated static func parseTop(_ output: String) -> TopSample {
        let sample = lastTopSample(in: output)
        var result = TopSample()

        if let idle = firstMatch(
            #"CPU usage:\s*[\d.]+%\s*user,\s*[\d.]+%\s*sys,\s*([\d.]+)%\s*idle"#,
            in: sample
        ).flatMap(Double.init) {
            result.cpuUsagePercent = min(max(100 - idle, 0), 100)
        }

        // PhysMem: 35G used (4653M wired, 16G compressor), 104M unused.
        // 仅作 vm_stat 不可用时的回退；used 含文件缓存，偏高于活动监视器。
        if let used = parseByteQuantity(
            firstMatch(#"PhysMem:\s*([\d.]+[KMGT]?)\s*used"#, in: sample)
        ) {
            result.memoryUsedBytes = used
        }
        if let unused = parseByteQuantity(
            firstMatch(#"PhysMem:.*?,\s*([\d.]+[KMGT]?)\s*unused"#, in: sample)
        ) {
            result.memoryUnusedBytes = unused
        }
        if let wired = parseByteQuantity(
            firstMatch(#"\(([\d.]+[KMGT]?)\s*wired"#, in: sample)
        ) {
            result.memoryWiredBytes = wired
        }
        if let compressed = parseByteQuantity(
            firstMatch(#"wired,\s*([\d.]+[KMGT]?)\s*compressor"#, in: sample)
        ) {
            result.memoryCompressedBytes = compressed
        }

        return result
    }

    /// 解析 `vm_stat`，按活动监视器口径计算 App / Wired / Compressed / Used。
    private nonisolated static func parseVmStat(_ output: String) -> VmStatSample? {
        // 首行：Mach Virtual Memory Statistics: (page size of 16384 bytes)
        let pageSize = firstMatch(
            #"page size of (\d+)"#,
            in: output
        ).flatMap(UInt64.init) ?? 16_384

        func pages(_ label: String) -> UInt64? {
            // 标签可能带引号，如 "Translation faults"；页数后常有句点。
            firstMatch(
                #"\#(label):\s+(\d+)"#,
                in: output
            ).flatMap(UInt64.init)
        }

        guard let free = pages("Pages free"),
              let wired = pages("Pages wired down"),
              let purgeable = pages("Pages purgeable"),
              let anonymous = pages("Anonymous pages"),
              let fileBacked = pages("File-backed pages"),
              let compressor = pages("Pages occupied by compressor")
        else {
            return nil
        }

        return VmStatSample(
            pageSize: pageSize,
            freePages: free,
            wiredPages: wired,
            purgeablePages: purgeable,
            anonymousPages: anonymous,
            fileBackedPages: fileBacked,
            compressorOccupiedPages: compressor
        )
    }

    /// 解析 `sysctl -n vm.swapusage`：`total = 1024.00M  used = 85.31M  free = …`
    private nonisolated static func parseSwapUsage(_ output: String) -> (used: UInt64, total: UInt64)? {
        let total = parseByteQuantity(
            firstMatch(#"total\s*=\s*([\d.]+[KMGT]?)"#, in: output)
        )
        let used = parseByteQuantity(
            firstMatch(#"used\s*=\s*([\d.]+[KMGT]?)"#, in: output)
        )
        guard let used, let total else { return nil }
        return (used, total)
    }

    /// `route -n get default` → `interface: en0`
    private nonisolated static func parseDefaultRouteInterface(_ output: String) -> String? {
        firstMatch(#"interface:\s*(\S+)"#, in: output)
    }

    /// 从 `scutil --nwi` 取局域网 IPv4；优先默认路由网卡，否则取表中第一项。
    private nonisolated static func parseLocalIPv4(
        fromNWI output: String,
        preferredInterface: String?
    ) -> (interface: String, address: String)? {
        // 形如：
        //      en6 : flags …
        //            address    : 192.168.50.203
        var pairs: [(iface: String, address: String)] = []
        var currentIF: String?
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let iface = firstMatch(#"^([A-Za-z0-9]+)\s*:\s*flags"#, in: trimmed) {
                currentIF = iface
                continue
            }
            if let iface = currentIF,
               let addr = firstMatch(#"^address\s*:\s*([0-9.]+)"#, in: trimmed),
               !addr.hasPrefix("127.") {
                pairs.append((iface, addr))
                currentIF = nil
            }
        }
        guard !pairs.isEmpty else { return nil }
        if let preferred = preferredInterface,
           let match = pairs.first(where: { $0.iface == preferred }) {
            return (match.iface, match.address)
        }
        return (pairs[0].iface, pairs[0].address)
    }

    /// 汇总 `netstat -ib` 各物理/虚拟链路的 Ibytes/Obytes。
    /// 排除 lo* 回环与 bridge*/vmenet*/gif*/stf* 等虚拟链路。
    private nonisolated static func parseNetstatTotals(_ output: String) -> (inBytes: UInt64, outBytes: UInt64)? {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var saw = false

        for line in output.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard raw.contains("<Link") else { continue }
            let cols = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = cols.first else { continue }
            // 排除回环与虚拟 bridge/vmenet/gif/stf
            if name.hasPrefix("lo") || name.hasPrefix("bridge") || name.hasPrefix("vmenet") || name.hasPrefix("gif") || name.hasPrefix("stf") {
                continue
            }
            // 列从右往左固定：Coll Obytes Oerrs Opkts Ibytes Ierrs Ipkts …
            guard cols.count >= 7,
                  let ibytes = UInt64(cols[cols.count - 5]),
                  let obytes = UInt64(cols[cols.count - 2]) else { continue }
            totalIn += ibytes
            totalOut += obytes
            saw = true
        }
        return saw ? (totalIn, totalOut) : nil
    }

    private nonisolated static func lastTopSample(in output: String) -> String {
        let parts = output.components(separatedBy: "Processes:")
        guard parts.count > 1 else { return output }
        return "Processes:" + parts[parts.count - 1]
    }

    // MARK: - df / iostat / proxy / curl

    private nonisolated static func parseDf(_ output: String) -> (total: UInt64, free: UInt64)? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return nil }
        // df 路径过长时第二行可能折行，合并空白列。
        let body = lines.dropFirst().joined(separator: " ")
        let cols = body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard cols.count >= 4,
              let totalK = UInt64(cols[1]),
              let availK = UInt64(cols[3]) else { return nil }
        return (totalK * 1024, availK * 1024)
    }

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

    private nonisolated static func parseProxy(_ output: String) -> SystemProxyInfo {
        func intValue(_ key: String) -> Int? {
            firstMatch(#"\#(key)\s*:\s*(\d+)"#, in: output).flatMap(Int.init)
        }
        func stringValue(_ key: String) -> String? {
            firstMatch(#"\#(key)\s*:\s*(.+)"#, in: output)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func proxyURL(_ enableKey: String, _ hostKey: String, _ portKey: String, scheme: String) -> String? {
            guard intValue(enableKey) == 1,
                  let host = stringValue(hostKey),
                  let port = intValue(portKey),
                  !host.isEmpty else { return nil }
            return "\(scheme)://\(host):\(port)"
        }

        let http = proxyURL("HTTPEnable", "HTTPProxy", "HTTPPort", scheme: "http")
        let https = proxyURL("HTTPSEnable", "HTTPSProxy", "HTTPSPort", scheme: "http")
        let socks = proxyURL("SOCKSEnable", "SOCKSProxy", "SOCKSPort", scheme: "socks5h")
        let pacCandidate = stringValue("ProxyAutoConfigURLString")
        let pac = intValue("ProxyAutoConfigEnable") == 1 && pacCandidate?.isEmpty == false
            ? pacCandidate
            : nil
        let wpad = intValue("ProxyAutoDiscoveryEnable") == 1
        let bypassHosts = Self.proxyExceptions(in: output)
        let excludeSimple = intValue("ExcludeSimpleHostnames") == 1
        let enabled = http != nil || https != nil || socks != nil || pac != nil || wpad

        let summary: String
        if let pac {
            summary = "PAC \(pac)"
        } else if wpad {
            summary = "WPAD"
        } else if let endpoint = https {
            summary = "HTTPS \(Self.proxyEndpoint(endpoint))"
        } else if let endpoint = http {
            summary = "HTTP \(Self.proxyEndpoint(endpoint))"
        } else if let endpoint = socks {
            summary = "SOCKS \(Self.proxyEndpoint(endpoint))"
        } else {
            summary = "Off"
        }
        return SystemProxyInfo(
            enabled: enabled,
            summary: summary,
            httpProxyURL: http,
            httpsProxyURL: https,
            socksProxyURL: socks,
            pacURL: pac,
            wpadEnabled: wpad,
            bypassHosts: bypassHosts,
            excludeSimpleHostnames: excludeSimple
        )
    }

    private nonisolated static var directProxyInfo: SystemProxyInfo {
        SystemProxyInfo(
            enabled: false,
            summary: "Off",
            httpProxyURL: nil,
            httpsProxyURL: nil,
            socksProxyURL: nil,
            pacURL: nil,
            wpadEnabled: false,
            bypassHosts: [],
            excludeSimpleHostnames: false
        )
    }

    private nonisolated static func proxyEndpoint(_ url: String) -> String {
        url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
    }

    /// 从 scutil 的 ExceptionsList 中提取常见的域名绕过规则。
    private nonisolated static func proxyExceptions(in output: String) -> [String] {
        guard let start = output.range(of: "ExceptionsList : <array> {") else { return [] }
        let tail = output[start.upperBound...]
        guard let end = tail.range(of: "}") else { return [] }
        return tail[..<end.lowerBound]
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                firstMatch(#"^\s*\d+\s*:\s*(.+?)\s*$"#, in: String(line))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
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

    // MARK: - 单位解析

    private nonisolated static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private nonisolated static func parseByteQuantity(_ raw: String?) -> UInt64? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return nil }
        let multipliers: [Character: Double] = [
            "K": 1_024,
            "M": 1_024 * 1_024,
            "G": 1_024 * 1_024 * 1_024,
            "T": 1_024 * 1_024 * 1_024 * 1_024,
        ]
        if let mult = multipliers[Character(String(last).uppercased())] {
            let numPart = trimmed.dropLast()
            guard let value = Double(numPart) else { return nil }
            return UInt64(value * mult)
        }
        return UInt64(trimmed)
    }

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
