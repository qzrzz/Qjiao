//
//  SystemReachability.swift
//  kero
//

import Foundation

// MARK: - Interval

/// 可达性探测间隔；`off` 时不展示列表、不轮询。
enum ReachabilityInterval: String, CaseIterable, Identifiable, Codable {
    case s5 = "5s"
    case s10 = "10s"
    case s15 = "15s"
    case s30 = "30s"
    case s60 = "60s"
    case m5 = "5m"
    case m10 = "10m"
    case off = "No"

    var id: String { rawValue }

    /// 按钮收起态与配置存盘用的短标题（如 `30s`）。
    var title: String { rawValue }

    /// 下拉菜单项文案；默认项带 `(Default)` 标注。
    var menuTitle: String {
        self == .default ? "\(rawValue) (Default)" : rawValue
    }

    /// nil 表示关闭探测。
    var seconds: TimeInterval? {
        switch self {
        case .s5: return 5
        case .s10: return 10
        case .s15: return 15
        case .s30: return 30
        case .s60: return 60
        case .m5: return 5 * 60
        case .m10: return 10 * 60
        case .off: return nil
        }
    }

    static let `default`: ReachabilityInterval = .s30
}

// MARK: - HTTP method

enum ReachabilityHTTPMethod: String, CaseIterable, Identifiable, Codable {
    case get = "GET"
    case head = "HEAD"

    var id: String { rawValue }
}

// MARK: - Site config

/// 用户可编辑的可达性探测目标。
struct ReachabilitySite: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var method: ReachabilityHTTPMethod

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        method: ReachabilityHTTPMethod = .get
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.method = method
    }

    /// 兼容旧存档：缺 method 时回落 GET。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        method = try c.decodeIfPresent(ReachabilityHTTPMethod.self, forKey: .method) ?? .get
    }

    static let defaults: [ReachabilitySite] = [
        .init(name: "Baidu", url: "https://www.baidu.com/"),
        .init(name: "Google", url: "https://www.gstatic.com/generate_204"),
        .init(name: "Cloudflare", url: "https://cp.cloudflare.com/generate_204"),
        .init(name: "Github", url: "https://github.com/")
    ]
}

// MARK: - Sample / status

enum SystemReachabilityStatus: Equatable {
    case unknown
    case reachable(latencyMs: Int?)
    case unreachable(reason: String)
}

/// 单次采样：成功延迟或失败（柱状图用）。
struct ReachabilitySample: Equatable {
    /// 成功时的延迟毫秒；失败为 nil。
    var latencyMs: Int?
    var ok: Bool

    static var fail: ReachabilitySample { .init(latencyMs: nil, ok: false) }
    static func ok(_ ms: Int) -> ReachabilitySample { .init(latencyMs: ms, ok: true) }
}

struct SystemReachabilityItem: Identifiable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var method: ReachabilityHTTPMethod
    var status: SystemReachabilityStatus
    /// 最近采样（左旧右新），供柱状图。
    var history: [ReachabilitySample]
    /// 最近一次探测失败的完整错误文案；成功后仍保留，供复制。
    var lastError: String?
}

extension SystemReachabilityStatus {
    /// 不可达时的原因文案。
    var errorMessage: String? {
        if case .unreachable(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Store

enum ReachabilityStore {
    private static let sitesKey = "systemReachabilitySites"
    /// 旧版仅写在 UserDefaults；现已迁入 `AppSettings` / config.toml。
    static let legacyIntervalKey = "systemReachabilityInterval"

    static func loadSites() -> [ReachabilitySite] {
        guard let data = UserDefaults.standard.data(forKey: sitesKey),
              let sites = try? JSONDecoder().decode([ReachabilitySite].self, from: data),
              !sites.isEmpty
        else {
            return ReachabilitySite.defaults
        }
        return sites
    }

    static func saveSites(_ sites: [ReachabilitySite]) {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        UserDefaults.standard.set(data, forKey: sitesKey)
    }

    /// 读取旧 UserDefaults 间隔（若有），用于一次性迁移到 config.toml。
    static func loadLegacyInterval() -> ReachabilityInterval? {
        guard let raw = UserDefaults.standard.string(forKey: legacyIntervalKey),
              let value = ReachabilityInterval(rawValue: raw)
        else {
            return nil
        }
        return value
    }

    static func clearLegacyInterval() {
        UserDefaults.standard.removeObject(forKey: legacyIntervalKey)
    }
}

// MARK: - Bar height

enum ReachabilityBarMetrics {
    static let historyCapacity = 24
    /// 成功柱最小相对高度。
    static let minOkHeight: CGFloat = 0.2
    /// 成功柱最大相对高度。
    static let maxOkHeight: CGFloat = 0.8
    /// 失败柱高度。
    static let failHeight: CGFloat = 1.0
    /// 延迟映射上限（ms），再高也封顶 maxOkHeight。
    static let latencyCapMs: Double = 800

    static func barHeight(for sample: ReachabilitySample) -> CGFloat {
        guard sample.ok else { return failHeight }
        let ms = Double(sample.latencyMs ?? 0)
        let t = min(max(ms / latencyCapMs, 0), 1)
        return minOkHeight + (maxOkHeight - minOkHeight) * t
    }
}
