//
//  AgentManifestTOML.swift
//  kero
//
//  解析 herdr agent-detection TOML 子集（[[rules]] + inline table / array）。
//  规则来源：https://github.com/herdrdev/herdr (Apache-2.0)
//

import Foundation

enum AgentManifestTOML {
    /// 解析完整 manifest；失败返回 nil。
    static func parse(_ source: String) -> AgentManifest? {
        do {
            let doc = try Parser(source).parseDocument()
            guard let id = doc.string("id") else { return nil }
            let ruleTables = doc.arrayOfTables("rules")
            var rules: [AgentRule] = []
            rules.reserveCapacity(ruleTables.count)
            for table in ruleTables {
                if let rule = parseRule(table) {
                    rules.append(rule)
                }
            }
            guard !rules.isEmpty else { return nil }
            return AgentManifest(id: id, rules: rules)
        } catch {
            return nil
        }
    }

    private static func parseRule(_ table: TomlTable) -> AgentRule? {
        guard let id = table.string("id") else { return nil }
        let stateRaw = table.string("state") ?? "unknown"
        guard let state = AgentRuleState.parse(stateRaw) else { return nil }
        let priority = table.int("priority") ?? 0
        let region = table.string("region") ?? "whole_recent"
        var gate = AgentGate()
        gate.contains = table.stringArray("contains").map { $0.lowercased() }
        gate.regexPatterns = table.stringArray("regex")
        gate.lineRegexPatterns = table.stringArray("line_regex")
        gate.all = table.inlineTableArray("all").compactMap(parseGate)
        gate.any = table.inlineTableArray("any").compactMap(parseGate)
        gate.not = table.inlineTableArray("not").compactMap(parseGate)
        return AgentRule(
            id: id,
            state: state,
            priority: priority,
            region: region,
            visibleIdle: table.bool("visible_idle") ?? false,
            visibleBlocker: table.bool("visible_blocker") ?? false,
            visibleWorking: table.bool("visible_working") ?? false,
            skipStateUpdate: table.bool("skip_state_update") ?? false,
            gate: gate
        )
    }

    private static func parseGate(_ table: TomlTable) -> AgentGate? {
        var gate = AgentGate()
        gate.contains = table.stringArray("contains").map { $0.lowercased() }
        gate.regexPatterns = table.stringArray("regex")
        gate.lineRegexPatterns = table.stringArray("line_regex")
        gate.all = table.inlineTableArray("all").compactMap(parseGate)
        gate.any = table.inlineTableArray("any").compactMap(parseGate)
        gate.not = table.inlineTableArray("not").compactMap(parseGate)
        // 空 gate 在 herdr 中视为恒真；保留即可。
        return gate
    }

    // MARK: - Value types

    private enum TomlValue {
        case string(String)
        case int(Int)
        case bool(Bool)
        case array([TomlValue])
        case table(TomlTable)
    }

    private final class TomlTable {
        var values: [String: TomlValue] = [:]
        var ruleTables: [TomlTable] = []

        func string(_ key: String) -> String? {
            if case .string(let s) = values[key] { return s }
            return nil
        }

        func int(_ key: String) -> Int? {
            if case .int(let n) = values[key] { return n }
            return nil
        }

        func bool(_ key: String) -> Bool? {
            if case .bool(let b) = values[key] { return b }
            return nil
        }

        func stringArray(_ key: String) -> [String] {
            guard case .array(let items) = values[key] else { return [] }
            return items.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
        }

        func inlineTableArray(_ key: String) -> [TomlTable] {
            guard case .array(let items) = values[key] else { return [] }
            return items.compactMap {
                if case .table(let t) = $0 { return t }
                return nil
            }
        }

        func arrayOfTables(_ key: String) -> [TomlTable] {
            // 仅使用 [[rules]]
            if key == "rules" { return ruleTables }
            return []
        }
    }

    // MARK: - Parser

    private struct ParseError: Error {}

    private final class Parser {
        private let scalars: [UnicodeScalar]
        private var index = 0

        init(_ source: String) {
            scalars = Array(source.unicodeScalars)
        }

        func parseDocument() throws -> TomlTable {
            let root = TomlTable()
            while !isAtEnd {
                skipWhitespaceAndComments()
                if isAtEnd { break }
                if peek() == "[" {
                    try parseArrayOfTables(into: root)
                } else {
                    let (key, value) = try parseKeyValue()
                    root.values[key] = value
                }
            }
            return root
        }

        private func parseArrayOfTables(into root: TomlTable) throws {
            // [[rules]]
            try expect("[")
            try expect("[")
            skipSpaces()
            let name = try parseBareKey()
            skipSpaces()
            try expect("]")
            try expect("]")
            skipSpaces()
            skipLineEnd()

            let table = TomlTable()
            while !isAtEnd {
                skipWhitespaceAndComments()
                if isAtEnd { break }
                if peek() == "[" { break }
                let (key, value) = try parseKeyValue()
                table.values[key] = value
            }
            if name == "rules" {
                root.ruleTables.append(table)
            }
        }

        private func parseKeyValue() throws -> (String, TomlValue) {
            let key = try parseBareKey()
            skipSpaces()
            try expect("=")
            skipSpaces()
            let value = try parseValue()
            skipSpaces()
            skipLineEnd()
            return (key, value)
        }

        private func parseValue() throws -> TomlValue {
            skipSpaces()
            guard !isAtEnd else { throw ParseError() }
            let ch = peek()
            if ch == "\"" || ch == "'" {
                return .string(try parseString())
            }
            if ch == "[" {
                return .array(try parseArray())
            }
            if ch == "{" {
                return .table(try parseInlineTable())
            }
            if ch == "t" || ch == "f" {
                return .bool(try parseBool())
            }
            if ch == "-" || (ch >= "0" && ch <= "9") {
                return .int(try parseInt())
            }
            throw ParseError()
        }

        private func parseArray() throws -> [TomlValue] {
            try expect("[")
            var items: [TomlValue] = []
            while !isAtEnd {
                skipWhitespaceAndComments(allowNewline: true)
                if peek() == "]" {
                    advance()
                    break
                }
                items.append(try parseValue())
                skipWhitespaceAndComments(allowNewline: true)
                if peek() == "," {
                    advance()
                    continue
                }
                if peek() == "]" {
                    advance()
                    break
                }
            }
            return items
        }

        private func parseInlineTable() throws -> TomlTable {
            try expect("{")
            let table = TomlTable()
            while !isAtEnd {
                skipWhitespaceAndComments(allowNewline: true)
                if peek() == "}" {
                    advance()
                    break
                }
                let key = try parseBareKey()
                skipSpaces()
                try expect("=")
                skipSpaces()
                let value = try parseValue()
                table.values[key] = value
                skipWhitespaceAndComments(allowNewline: true)
                if peek() == "," {
                    advance()
                    continue
                }
                if peek() == "}" {
                    advance()
                    break
                }
            }
            return table
        }

        private func parseString() throws -> String {
            let quote = peek()
            guard quote == "\"" || quote == "'" else { throw ParseError() }
            advance()
            var result = ""
            while !isAtEnd {
                let ch = peek()
                if ch == quote {
                    advance()
                    return result
                }
                if ch == "\\" && quote == "\"" {
                    advance()
                    guard !isAtEnd else { throw ParseError() }
                    let esc = peek()
                    advance()
                    switch esc {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "\\": result.append("\\")
                    case "\"": result.append("\"")
                    default: result.append(Character(esc))
                    }
                    continue
                }
                if ch == "\n" || ch == "\r" { throw ParseError() }
                result.append(Character(ch))
                advance()
            }
            throw ParseError()
        }

        private func parseBool() throws -> Bool {
            if match("true") { return true }
            if match("false") { return false }
            throw ParseError()
        }

        private func parseInt() throws -> Int {
            var sign = 1
            if peek() == "-" {
                sign = -1
                advance()
            }
            var value = 0
            var digits = 0
            while !isAtEnd {
                let ch = peek()
                guard ch >= "0", ch <= "9" else { break }
                value = value * 10 + Int(ch.value - UnicodeScalar("0").value)
                digits += 1
                advance()
            }
            guard digits > 0 else { throw ParseError() }
            return value * sign
        }

        private func parseBareKey() throws -> String {
            skipSpaces()
            var key = ""
            while !isAtEnd {
                let ch = peek()
                if (ch >= "a" && ch <= "z")
                    || (ch >= "A" && ch <= "Z")
                    || (ch >= "0" && ch <= "9")
                    || ch == "_" || ch == "-" {
                    key.append(Character(ch))
                    advance()
                } else {
                    break
                }
            }
            guard !key.isEmpty else { throw ParseError() }
            return key
        }

        // MARK: Scanner

        private var isAtEnd: Bool { index >= scalars.count }

        private func peek() -> UnicodeScalar {
            scalars[index]
        }

        private func advance() {
            index += 1
        }

        private func expect(_ expected: UnicodeScalar) throws {
            guard !isAtEnd, peek() == expected else { throw ParseError() }
            advance()
        }

        private func match(_ word: String) -> Bool {
            let chars = Array(word.unicodeScalars)
            guard index + chars.count <= scalars.count else { return false }
            for (offset, ch) in chars.enumerated() {
                if scalars[index + offset] != ch { return false }
            }
            index += chars.count
            return true
        }

        private func skipSpaces() {
            while !isAtEnd {
                let ch = peek()
                if ch == " " || ch == "\t" {
                    advance()
                } else {
                    break
                }
            }
        }

        private func skipLineEnd() {
            while !isAtEnd {
                let ch = peek()
                if ch == " " || ch == "\t" {
                    advance()
                    continue
                }
                if ch == "#" {
                    skipComment()
                    continue
                }
                if ch == "\n" {
                    advance()
                    return
                }
                if ch == "\r" {
                    advance()
                    if !isAtEnd, peek() == "\n" { advance() }
                    return
                }
                return
            }
        }

        private func skipComment() {
            while !isAtEnd {
                let ch = peek()
                if ch == "\n" || ch == "\r" { break }
                advance()
            }
        }

        private func skipWhitespaceAndComments(allowNewline: Bool = true) {
            while !isAtEnd {
                let ch = peek()
                if ch == " " || ch == "\t" {
                    advance()
                    continue
                }
                if allowNewline, ch == "\n" || ch == "\r" {
                    advance()
                    continue
                }
                if ch == "#" {
                    skipComment()
                    continue
                }
                break
            }
        }
    }
}

// MARK: - Bundle loader

enum AgentManifestStore {
    private static var cache: [AgentKind: AgentManifest] = [:]
    private static let lock = NSLock()

    static func manifest(for kind: AgentKind) -> AgentManifest? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[kind] {
            return cached
        }
        guard kind.hasScreenManifest else { return nil }
        guard let source = loadSource(named: kind.manifestResourceName),
              let parsed = AgentManifestTOML.parse(source)
        else { return nil }
        cache[kind] = parsed
        return parsed
    }

    /// 预热常用 manifest，避免首次检测卡顿。
    static func warmUp(kinds: [AgentKind] = AgentKind.allCases) {
        for kind in kinds where kind.hasScreenManifest {
            _ = manifest(for: kind)
        }
    }

    private static func loadSource(named name: String) -> String? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: "toml", subdirectory: "AgentWatcher/manifests"),
            bundle.url(forResource: name, withExtension: "toml", subdirectory: "manifests"),
            bundle.url(forResource: name, withExtension: "toml"),
        ]
        for url in candidates {
            if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        // 源码旁路径（开发态 / 同步组未把 toml 拷进 bundle 时）
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("manifests/\(name).toml")
        return try? String(contentsOf: here, encoding: .utf8)
    }
}
