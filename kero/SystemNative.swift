//
//  SystemNative.swift
//  kero
//

import Darwin
import Foundation
import SystemConfiguration

/// 通过原生 Darwin / SystemConfiguration API 采集本机系统信息，不创建任何子进程。
///
/// 原先这些指标由 CLI（top / vm_stat / netstat / df / scutil --proxy / sysctl / route）采集：
/// 每 2s 一轮 spawn 10+ 进程，其中 `top -l 2` 单次即消耗约 0.75s CPU（约占单核 37%）。
/// 原生 API 只是几微秒的 Mach trap / syscall，不产生系统级进程采样负担。
enum SystemNative {

    // MARK: - CPU

    /// 系统级 CPU 累计 tick（user / system / idle / nice）。
    /// 与上一次采样差分后即可得到窗口内平均占用率（与活动监视器口径一致）。
    static func cpuLoadInfo() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (
            UInt64(load.cpu_ticks.0),
            UInt64(load.cpu_ticks.1),
            UInt64(load.cpu_ticks.2),
            UInt64(load.cpu_ticks.3)
        )
    }

    // MARK: - Memory

    /// `host_statistics64` 的内存分页统计（与 `vm_stat` 命令行同源同口径）。
    static func vmStatistics() -> VmStatSample? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        return VmStatSample(
            pageSize: UInt64(pageSize),
            freePages: UInt64(vm.free_count),
            wiredPages: UInt64(vm.wire_count),
            purgeablePages: UInt64(vm.purgeable_count),
            // 与 vm_stat 一致：Anonymous pages = internal_page_count。
            anonymousPages: UInt64(vm.internal_page_count),
            // File-backed pages = external_page_count。
            fileBackedPages: UInt64(vm.external_page_count),
            // Pages occupied by compressor（物理占用，非 stored）。
            compressorOccupiedPages: UInt64(vm.compressor_page_count)
        )
    }

    /// `vm.swapusage`（`sysctl -n vm.swapusage` 同源）。
    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var xsu = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsu, &len, nil, 0) == 0 else { return nil }
        return (xsu.xsu_used, xsu.xsu_total)
    }

    /// 物理内存总量（`sysctl hw.memsize` 同源）。
    static func hardwareMemory() -> UInt64? {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0 else { return nil }
        return size
    }

    // MARK: - Disk

    /// 根卷容量（`df -k /` 同源：total = f_blocks，free = f_bavail）。
    static func diskCapacity() -> (total: UInt64, free: UInt64)? {
        var s = statfs()
        guard statfs("/", &s) == 0 else { return nil }
        let blockSize = UInt64(s.f_bsize)
        return (UInt64(s.f_blocks) * blockSize, UInt64(s.f_bavail) * blockSize)
    }

    // MARK: - Network

    /// 各物理网卡累计收发字节（`netstat -ib` 同源：NET_RT_IFLIST2 的 64 位计数）。
    ///
    /// 不用 getifaddrs：其 if_data 字节计数在超过 2^32 后会被截断（en0/lo0 实测与
    /// netstat 差 2^32），而本函数要求精确的差分速率。
    static func networkCounters() -> (inBytes: UInt64, outBytes: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var saw = false
        var offset = 0
        while offset + MemoryLayout<if_msghdr2>.size <= len {
            // 消息头：u_short ifm_msglen + u_char ifm_version + u_char ifm_type。
            let type: UInt8 = buf[offset + 3]
            let messageLength = Int(buf.withUnsafeBytes { raw -> UInt16 in
                var value: UInt16 = 0
                memcpy(&value, raw.baseAddress!.advanced(by: offset), 2)
                return value
            })
            guard messageLength > 0 else { break }
            if type == RTM_IFINFO2 {
                let header = buf.withUnsafeBytes { raw -> if_msghdr2 in
                    var value = if_msghdr2()
                    memcpy(&value, raw.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
                    return value
                }
                if let name = Self.interfaceName(for: header.ifm_index),
                   !Self.isVirtualInterface(name) {
                    totalIn += header.ifm_data.ifi_ibytes
                    totalOut += header.ifm_data.ifi_obytes
                    saw = true
                }
            }
            offset += messageLength
        }
        return saw ? (totalIn, totalOut) : nil
    }

    /// 排除回环与虚拟 bridge/vmenet/gif/stf（与旧 netstat 解析一致）。
    private static func isVirtualInterface(_ name: String) -> Bool {
        name.hasPrefix("lo") || name.hasPrefix("bridge") || name.hasPrefix("vmenet")
            || name.hasPrefix("gif") || name.hasPrefix("stf")
    }

    // MARK: - 本机 IP

    /// 默认路由网卡名（如 `en0`）。
    ///
    /// 读内核路由表 `NET_RT_DUMP`（`route -n get default` 同源）：取首个带 IPv4 网关的默认路由
    /// （dst = 0.0.0.0/0），避免 VPN 产生的无网关桥接默认路由。`SCDynamicStoreCopyPrimaryInterface`
    /// 已从新版 SDK 的 SystemConfiguration 中移除，故直接解析路由表。
    static func primaryInterface() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_DUMP, 0]
        var len: size_t = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var fallbackName: String?
        var offset = 0
        while offset < len {
            let header = buf.withUnsafeBytes { raw -> rt_msghdr in
                raw.load(fromByteOffset: offset, as: rt_msghdr.self)
            }
            let messageLength = Int(header.rtm_msglen)
            guard messageLength > 0 else { break }
            if header.rtm_type == RTM_ADD || header.rtm_type == RTM_GET,
               (header.rtm_addrs & (Int32(1) << Int32(RTAX_DST))) != 0 {
                var cursor = offset + MemoryLayout<rt_msghdr>.size
                var isDefaultV4 = false
                var sawGateway = false
                var gatewayIsV4 = false
                for index in 0..<Int(RTAX_MAX) where (header.rtm_addrs & (Int32(1) << Int32(index))) != 0 {
                    let socketLength = buf.withUnsafeBytes { raw -> Int in
                        let sa = raw.baseAddress!.advanced(by: cursor)
                            .assumingMemoryBound(to: sockaddr.self)
                        return Int(sa.pointee.sa_len)
                    }
                    if index == RTAX_DST, socketLength >= MemoryLayout<sockaddr_in>.size {
                        let sin = buf.withUnsafeBytes { raw in
                            raw.baseAddress!.advanced(by: cursor)
                                .assumingMemoryBound(to: sockaddr_in.self).pointee
                        }
                        isDefaultV4 = sin.sin_family == AF_INET && sin.sin_addr.s_addr == 0
                    }
                    if index == RTAX_GATEWAY {
                        let family = buf.withUnsafeBytes { raw -> sa_family_t in
                            raw.baseAddress!.advanced(by: cursor)
                                .assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                        }
                        sawGateway = true
                        gatewayIsV4 = family == AF_INET
                    }
                    cursor += socketLength
                }
                if isDefaultV4 {
                    if sawGateway && gatewayIsV4, let name = Self.interfaceName(for: header.rtm_index) {
                        return name
                    }
                    if fallbackName == nil, let name = Self.interfaceName(for: header.rtm_index) {
                        fallbackName = name
                    }
                }
            }
            offset += messageLength
        }
        return fallbackName
    }

    private static func interfaceName(for index: UInt16) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// 局域网 IPv4 地址表；优先指定网卡（默认路由网卡），否则取第一个非回环地址。
    static func localIPv4(preferredInterface: String?) -> (interface: String, address: String)? {
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return nil }
        defer { freeifaddrs(first) }

        var pairs: [(interface: String, address: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            ptr = cur.pointee.ifa_next
            guard cur.pointee.ifa_addr.pointee.sa_family == AF_INET else { continue }
            guard let address = cur.pointee.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let addressString = String(cString: host)
            guard !addressString.hasPrefix("127.") else { continue }
            pairs.append((String(cString: cur.pointee.ifa_name), addressString))
        }
        guard !pairs.isEmpty else { return nil }
        if let preferred = preferredInterface,
           let match = pairs.first(where: { $0.interface == preferred }) {
            return match
        }
        return pairs[0]
    }

    // MARK: - Proxy

    /// 系统代理配置（`scutil --proxy` 同源，直接读 SCDynamicStore）。
    static func proxyInfo() -> SystemProxyInfo {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return Self.directProxyInfo
        }

        func boolValue(_ key: String) -> Bool {
            (proxies[key] as? NSNumber)?.boolValue == true
        }
        func intValue(_ key: String) -> Int? {
            (proxies[key] as? NSNumber)?.intValue
        }
        func stringValue(_ key: String) -> String? {
            proxies[key] as? String
        }
        func proxyURL(enableKey: String, hostKey: String, portKey: String, scheme: String) -> String? {
            guard boolValue(enableKey),
                  let host = stringValue(hostKey),
                  let port = intValue(portKey),
                  !host.isEmpty else { return nil }
            return "\(scheme)://\(host):\(port)"
        }

        let http = proxyURL(enableKey: "HTTPEnable", hostKey: "HTTPProxy", portKey: "HTTPPort", scheme: "http")
        let https = proxyURL(enableKey: "HTTPSEnable", hostKey: "HTTPSProxy", portKey: "HTTPSPort", scheme: "http")
        let socks = proxyURL(enableKey: "SOCKSEnable", hostKey: "SOCKSProxy", portKey: "SOCKSPort", scheme: "socks5h")
        let pacCandidate = stringValue("ProxyAutoConfigURLString")
        let pac = boolValue("ProxyAutoConfigEnable") && pacCandidate?.isEmpty == false ? pacCandidate : nil
        let wpad = boolValue("ProxyAutoDiscoveryEnable")
        let bypassHosts = (proxies["ExceptionsList"] as? [String]) ?? []
        let excludeSimple = boolValue("ExcludeSimpleHostnames")
        let enabled = http != nil || https != nil || socks != nil || pac != nil || wpad

        let summary: String
        if let pac {
            summary = "PAC \(pac)"
        } else if wpad {
            summary = "WPAD"
        } else if let endpoint = https {
            summary = "HTTPS \(Self.endpoint(endpoint))"
        } else if let endpoint = http {
            summary = "HTTP \(Self.endpoint(endpoint))"
        } else if let endpoint = socks {
            summary = "SOCKS \(Self.endpoint(endpoint))"
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

    private static var directProxyInfo: SystemProxyInfo {
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

    private static func endpoint(_ url: String) -> String {
        url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
    }
}

/// `host_statistics64` 采集结果：对齐活动监视器的内存分类。
struct VmStatSample: Equatable {
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
