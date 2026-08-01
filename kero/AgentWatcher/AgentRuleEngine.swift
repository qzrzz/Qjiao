//
//  AgentRuleEngine.swift
//  kero
//
//  herdr 风格的屏幕/标题规则匹配：region + contains/regex/line_regex + all/any/not。
//

import Foundation

// MARK: - Model

struct AgentGate: Sendable {
    var contains: [String] = []
    var regexPatterns: [String] = []
    var lineRegexPatterns: [String] = []
    var all: [AgentGate] = []
    var any: [AgentGate] = []
    var not: [AgentGate] = []
}

struct AgentRule: Sendable {
    var id: String
    var state: AgentRuleState
    var priority: Int
    var region: String
    var visibleIdle: Bool
    var visibleBlocker: Bool
    var visibleWorking: Bool
    var skipStateUpdate: Bool
    var gate: AgentGate
}

struct AgentManifest: Sendable {
    var id: String
    var rules: [AgentRule]
}

struct AgentDetectionResult: Sendable, Equatable {
    var state: AgentRuleState
    var matchedRuleID: String?
    var skipStateUpdate: Bool
    var visibleIdle: Bool
    var visibleBlocker: Bool
    var visibleWorking: Bool

    static func idleFallback() -> AgentDetectionResult {
        AgentDetectionResult(
            state: .idle,
            matchedRuleID: nil,
            skipStateUpdate: false,
            visibleIdle: false,
            visibleBlocker: false,
            visibleWorking: false
        )
    }
}

struct AgentDetectionInput: Sendable {
    var screen: String
    var oscTitle: String
    var oscProgress: String
}

// MARK: - Engine

enum AgentRuleEngine {
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    static func detect(manifest: AgentManifest, input: AgentDetectionInput) -> AgentDetectionResult {
        var best: (rule: AgentRule, region: String)?

        for rule in manifest.rules {
            let regionText = region(input: input, spec: rule.region)
            guard gateMatches(rule.gate, text: regionText) else { continue }
            if let current = best, current.rule.priority >= rule.priority {
                continue
            }
            best = (rule, rule.region)
        }

        guard let matched = best else {
            return .idleFallback()
        }

        let rule = matched.rule
        let state = rule.state
        return AgentDetectionResult(
            state: state,
            matchedRuleID: rule.id,
            skipStateUpdate: rule.skipStateUpdate,
            visibleIdle: rule.visibleIdle && state == .idle,
            visibleBlocker: rule.visibleBlocker && state == .blocked,
            visibleWorking: rule.visibleWorking && state == .working
        )
    }

    // MARK: Gate

    static func gateMatches(_ gate: AgentGate, text: String) -> Bool {
        let lower = text.lowercased()

        for needle in gate.contains {
            if !lower.contains(needle) { return false }
        }

        for pattern in gate.regexPatterns {
            guard let regex = compiledRegex(pattern) else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, options: [], range: range) == nil {
                return false
            }
        }

        if !gate.lineRegexPatterns.isEmpty {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for pattern in gate.lineRegexPatterns {
                guard let regex = compiledRegex(pattern) else { return false }
                let hit = lines.contains { line in
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    return regex.firstMatch(in: line, options: [], range: range) != nil
                }
                if !hit { return false }
            }
        }

        for nested in gate.all {
            if !gateMatches(nested, text: text) { return false }
        }

        if !gate.any.isEmpty {
            if !gate.any.contains(where: { gateMatches($0, text: text) }) {
                return false
            }
        }

        for nested in gate.not {
            if gateMatches(nested, text: text) { return false }
        }

        return true
    }

    private static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) {
            return cached
        }
        // herdr 使用 Rust regex；ICU 对部分写法兼容。失败则该规则永不命中。
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    // MARK: Regions

    static func region(input: AgentDetectionInput, spec: String) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "osc_title":
            return input.oscTitle
        case "osc_progress":
            return input.oscProgress
        case "whole_recent":
            return input.screen
        case "after_last_prompt_marker":
            return afterLastPromptMarker(input.screen)
        case "whole_recent_without_current_prompt_marker":
            return wholeRecentWithoutCurrentPromptMarker(input.screen)
        case "prompt_box_body":
            return promptBoxBody(input.screen) ?? ""
        case "above_prompt_box":
            return abovePromptBox(input.screen)
        case "last_non_empty_above_prompt_box":
            return lastNonEmptyLine(abovePromptBox(input.screen))
        case "after_last_horizontal_rule":
            return afterLastHorizontalRule(input.screen)
        default:
            if let count = regionCount(trimmed, name: "bottom_non_empty_lines") {
                return bottomNonEmptyLines(input.screen, count: count)
            }
            if let count = regionCount(trimmed, name: "top_non_empty_lines") {
                return topNonEmptyLines(input.screen, count: count)
            }
            return input.screen
        }
    }

    private static func regionCount(_ spec: String, name: String) -> Int? {
        guard spec.hasPrefix(name + "("), spec.hasSuffix(")") else { return nil }
        let innerStart = spec.index(spec.startIndex, offsetBy: name.count + 1)
        let innerEnd = spec.index(before: spec.endIndex)
        let inner = spec[innerStart..<innerEnd].trimmingCharacters(in: .whitespaces)
        return Int(inner)
    }

    private static func bottomNonEmptyLines(_ content: String, count: Int) -> String {
        guard count > 0 else { return "" }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var nonEmptyIndexes: [Int] = []
        for (index, line) in lines.enumerated().reversed() {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                nonEmptyIndexes.append(index)
                if nonEmptyIndexes.count == count { break }
            }
        }
        guard let start = nonEmptyIndexes.last else { return "" }
        return lines[start...].joined(separator: "\n")
    }

    private static func topNonEmptyLines(_ content: String, count: Int) -> String {
        guard count > 0 else { return "" }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var endIndex: Int?
        var seen = 0
        for (index, line) in lines.enumerated() {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                seen += 1
                endIndex = index
                if seen == count { break }
            }
        }
        guard let end = endIndex else { return "" }
        return lines[0...end].joined(separator: "\n")
    }

    private static func afterLastPromptMarker(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.lastIndex(where: isCodexPromptLine) else {
            return content
        }
        let next = index + 1
        guard next < lines.count else { return "" }
        return lines[next...].joined(separator: "\n")
    }

    private static func wholeRecentWithoutCurrentPromptMarker(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if currentCodexPromptIndex(lines) != nil {
            return ""
        }
        return content
    }

    private static func currentCodexPromptIndex(_ lines: [String]) -> Int? {
        // 末尾连续空行之上若是 codex 提示符，视为当前 prompt。
        var index = lines.count - 1
        while index >= 0, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index -= 1
        }
        guard index >= 0, isCodexPromptLine(lines[index]) else { return nil }
        return index
    }

    private static func isCodexPromptLine(_ line: String) -> Bool {
        line == "›" || line.hasPrefix("› ")
    }

    private static func promptBoxBody(_ content: String) -> String? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let top = promptBoxTopBorderIndex(lines) else { return nil }
        let start = top + 1
        let endIndex = lines[start...].firstIndex(where: isHorizontalRule) ?? lines.endIndex
        guard start < endIndex else { return "" }
        return lines[start..<endIndex].joined(separator: "\n")
    }

    private static func abovePromptBox(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let top = promptBoxTopBorderIndex(lines), top > 0 else {
            return content
        }
        return lines[..<top].joined(separator: "\n")
    }

    private static func afterLastHorizontalRule(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lastRuleEnd = 0
        for (index, line) in lines.enumerated() {
            if isHorizontalRule(line) {
                lastRuleEnd = index + 1
            }
        }
        guard lastRuleEnd < lines.count else { return "" }
        return lines[lastRuleEnd...].joined(separator: "\n")
    }

    private static func lastNonEmptyLine(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .reversed()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? ""
    }

    private static func promptBoxTopBorderIndex(_ lines: [String]) -> Int? {
        var borderCount = 0
        for index in lines.indices.reversed() {
            if isHorizontalRule(lines[index]) {
                borderCount += 1
                if borderCount == 2 {
                    return index
                }
            }
        }
        return nil
    }

    /// herdr：以 box-drawing `─` 开头的横线。
    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var ruleChars = 0
        for ch in trimmed {
            if ch == "─" {
                ruleChars += 1
            } else {
                break
            }
        }
        guard ruleChars > 0 else { return false }
        let suffix = trimmed.dropFirst(ruleChars).drop(while: { $0 == " " || $0 == "\t" })
        return suffix.isEmpty || ruleChars >= 3
    }
}
