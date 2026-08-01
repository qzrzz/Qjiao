//
//  AgentKind.swift
//  kero
//
//  从进程名识别 Coding Agent（对齐 herdr detect::Agent）。
//

import Foundation

/// 已知交互式 Coding Agent。
enum AgentKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case pi
    case claude
    case codex
    case gemini
    case cursor
    case devin
    case agy
    case cline
    case omp
    case mastracode
    case opencode
    case copilot
    case kimi
    case kiro
    case droid
    case amp
    case grok
    case hermes
    case kilo
    case qodercli
    case maki

    /// 显示标签（品牌/CLI 名，不翻译）。
    var displayName: String {
        switch self {
        case .pi: return "pi"
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .cursor: return "cursor"
        case .devin: return "devin"
        case .agy: return "agy"
        case .cline: return "cline"
        case .omp: return "omp"
        case .mastracode: return "mastracode"
        case .opencode: return "opencode"
        case .copilot: return "copilot"
        case .kimi: return "kimi"
        case .kiro: return "kiro"
        case .droid: return "droid"
        case .amp: return "amp"
        case .grok: return "grok"
        case .hermes: return "hermes"
        case .kilo: return "kilo"
        case .qodercli: return "qodercli"
        case .maki: return "maki"
        }
    }

    /// Bundle 内 manifest 文件名（不含扩展名）。
    var manifestResourceName: String {
        switch self {
        case .agy: return "antigravity"
        case .copilot: return "github-copilot"
        default: return rawValue
        }
    }

    /// 是否内置了屏幕规则 manifest（omp / mastracode 主要靠 hook，无 screen manifest）。
    var hasScreenManifest: Bool {
        switch self {
        case .omp, .mastracode:
            return false
        default:
            return true
        }
    }

    /// 从进程可执行名 / argv 候选识别 Agent。
    static func identify(processNames: [String]) -> AgentKind? {
        for name in processNames {
            if let kind = parse(processName: name) {
                return kind
            }
        }
        return nil
    }

    static func parse(processName: String) -> AgentKind? {
        let base = (processName as NSString).lastPathComponent
        let lower = base.lowercased()
        let normalized = lower.hasPrefix("-") ? String(lower.dropFirst()) : lower
        // 版本化后缀：grok-0.2.112-macos-aarch64
        let stripped = stripVersionSuffix(normalized)
        return lookup(stripped) ?? lookup(normalized)
    }

    private static func lookup(_ name: String) -> AgentKind? {
        switch name {
        case "pi": return .pi
        case "claude", "claude-code": return .claude
        case "codex": return .codex
        case "gemini": return .gemini
        case "cursor", "cursor-agent": return .cursor
        case "devin", "devin-cli", "devin cli": return .devin
        case "agy", "antigravity", "antigravity-cli": return .agy
        case "cline": return .cline
        case "omp": return .omp
        case "mastracode", "mastra-code", "mastra code": return .mastracode
        case "opencode", "open-code": return .opencode
        case "copilot", "github-copilot", "ghcs": return .copilot
        case "kimi", "kimi-code", "kimi code": return .kimi
        case "kiro", "kiro-cli": return .kiro
        case "droid": return .droid
        case "amp", "amp-local": return .amp
        case "grok", "grok-build": return .grok
        case "hermes", "hermes-agent": return .hermes
        case "kilo", "kilo-code", "kilo code": return .kilo
        case "qodercli", "qoderclicn", "qoder", "qodercn": return .qodercli
        case "maki": return .maki
        default: return nil
        }
    }

    /// 去掉常见平台/版本后缀，便于匹配 `grok-0.2.x-macos-aarch64`。
    private static func stripVersionSuffix(_ name: String) -> String {
        let markers = ["-0.", "-1.", "-2.", "-3.", "-4.", "-5.", "-6.", "-7.", "-8.", "-9."]
        for marker in markers {
            if let range = name.range(of: marker) {
                return String(name[..<range.lowerBound])
            }
        }
        for platform in ["-macos", "-darwin", "-linux", "-windows", "-aarch64", "-x86_64", "-arm64"] {
            if let range = name.range(of: platform) {
                return String(name[..<range.lowerBound])
            }
        }
        return name
    }
}
