//
//  MarkdownHTML.swift
//  kero
//
//  Lightweight GitHub-flavored Markdown → HTML for the file preview pane.
//  Escapes ordinary text; strips a small set of dangerous HTML tags; leaves
//  a safe subset of raw HTML blocks so README-style documents still render.
//

import Foundation

nonisolated enum MarkdownHTML {
    static func render(_ source: String) -> String {
        let cleaned = stripDangerousHTML(source)
        let lines = cleaned.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        var parser = Parser(lines: lines)
        return parser.render()
    }

    /// Tags that must never reach the preview WebView.
    private static let blockedTags = [
        "script", "iframe", "object", "embed", "form", "link", "meta", "base",
        "svg", "math",
    ]

    private static func stripDangerousHTML(_ source: String) -> String {
        var text = source
        for tag in blockedTags {
            let pair = "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>"
            let lonely = "(?is)<\(tag)\\b[^>]*?/?>"
            text = text.replacingOccurrences(of: pair, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: lonely, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: "(?i)\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            with: "",
            options: .regularExpression
        )
        return text
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "'", with: "&#39;")
    }

    static func isSafeURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = trimmed.removingPercentEncoding ?? trimmed
        if url.isEmpty { return false }
        if url.hasPrefix("#") { return true }
        if url.hasPrefix("/") || url.hasPrefix("./") || url.hasPrefix("../") {
            return true
        }
        if !url.contains(":") { return true }
        guard let scheme = URL(string: url.replacingOccurrences(of: " ", with: "%20"))?
            .scheme?.lowercased()
        else { return false }
        switch scheme {
        case "http", "https", "mailto", "file":
            return true
        default:
            return false
        }
    }

    /// 相对路径按段 percent-encode，保证带空格的 `img src` 能被自定义 scheme 加载。
    static func encodeResourceURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if decoded.hasPrefix("http://")
            || decoded.hasPrefix("https://")
            || decoded.hasPrefix("mailto:")
            || decoded.hasPrefix("file:")
        {
            var allowed = CharacterSet.urlFragmentAllowed
            allowed.insert(charactersIn: ":/?#[]@!$&'()*+,;=-._~")
            return decoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? decoded
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return decoded
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { part in
                String(part).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(part)
            }
            .joined(separator: "/")
    }
}

/// 源码行号：1-based，供编辑器与预览按内容对齐。
nonisolated enum MarkdownSourceLine {
    static func starts(in text: String) -> [Int] {
        var starts = [0]
        let ns = text as NSString
        let length = ns.length
        var index = 0
        while index < length {
            if ns.character(at: index) == 10 {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    static func line(forUTF16Offset offset: Int, starts: [Int]) -> Int {
        guard !starts.isEmpty else { return 1 }
        let clamped = max(0, offset)
        var low = 0
        var high = starts.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if starts[mid] <= clamped {
                low = mid
            } else {
                high = mid
            }
        }
        return low + 1
    }

    static func utf16Offset(ofLine line: Int, starts: [Int]) -> Int {
        guard !starts.isEmpty else { return 0 }
        let index = min(max(line, 1), starts.count) - 1
        return starts[index]
    }
}

nonisolated private struct Parser {
    let lines: [String]
    let lineBase: Int
    var index = 0
    var html = ""

    init(lines: [String], lineBase: Int = 0) {
        self.lines = lines
        self.lineBase = lineBase
    }

    /// 1-based 源码行。`sourceIndex` 省略时用当前 `index`。
    private func lineAttr(_ sourceIndex: Int? = nil) -> String {
        let line = (sourceIndex ?? index) + lineBase + 1
        return " data-line=\"\(line)\""
    }

    mutating func render() -> String {
        skipYAMLFrontMatter()
        while index < lines.count {
            parseBlock()
        }
        return html
    }

    private mutating func skipYAMLFrontMatter() {
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first == "---"
        else { return }
        var cursor = 1
        while cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces) == "---" {
                index = cursor + 1
                return
            }
            cursor += 1
        }
    }

    private mutating func parseBlock() {
        if index >= lines.count { return }
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            index += 1
            return
        }

        if let fence = fenceInfo(trimmed) {
            parseFence(info: fence.language, closer: fence.closer)
            return
        }

        if isHorizontalRule(trimmed) {
            html += "<hr\(lineAttr())>\n"
            index += 1
            return
        }

        if trimmed.hasPrefix("<") {
            parseHTMLBlock()
            return
        }

        if let heading = atxHeading(trimmed) {
            html += "<h\(heading.level)\(lineAttr())>\(renderInline(heading.text))</h\(heading.level)>\n"
            index += 1
            return
        }

        if parseSetextHeading() { return }

        if trimmed.hasPrefix(">") {
            parseBlockquote()
            return
        }

        if parseTable() { return }

        if isListLine(line) {
            parseList(baseIndent: leadingSpaces(line))
            return
        }

        parseParagraph()
    }

    // MARK: - Fences

    private struct Fence {
        var language: String
        var closer: String
    }

    private func fenceInfo(_ trimmed: String) -> Fence? {
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let mark = String(trimmed.prefix(3))
        var rest = trimmed.dropFirst(3)
        while rest.first == mark.first {
            rest = rest.dropFirst()
        }
        let language = rest.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        return Fence(language: language, closer: mark)
    }

    private mutating func parseFence(info language: String, closer: String) {
        let start = index
        index += 1
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(closer), fenceInfo(trimmed) != nil {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        let classAttr = language.isEmpty
            ? ""
            : " class=\"language-\(MarkdownHTML.escapeAttribute(language.lowercased()))\""
        html += "<pre\(lineAttr(start))><code\(classAttr)>\(MarkdownHTML.escape(body.joined(separator: "\n")))</code></pre>\n"
    }

    // MARK: - Headings / rules / HTML

    private func atxHeading(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var rest = trimmed[...]
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    private func isHorizontalRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        let unique = Set(compact)
        return unique.count == 1 && (unique.contains("-") || unique.contains("*") || unique.contains("_"))
    }

    private mutating func parseSetextHeading() -> Bool {
        guard index + 1 < lines.count else { return false }
        let text = lines[index].trimmingCharacters(in: .whitespaces)
        let underline = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isListLine(lines[index]) else { return false }
        let level: Int
        if underline.allSatisfy({ $0 == "=" }), underline.count >= 1 {
            level = 1
        } else if underline.allSatisfy({ $0 == "-" }), underline.count >= 1 {
            level = 2
        } else {
            return false
        }
        html += "<h\(level)\(lineAttr())>\(renderInline(text))</h\(level)>\n"
        index += 2
        return true
    }

    private mutating func parseHTMLBlock() {
        html += "<div\(lineAttr())>\n"
        while index < lines.count {
            let line = lines[index]
            html += line + "\n"
            index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
        }
        html += "</div>\n"
    }

    // MARK: - Quotes / tables / lists / paragraphs

    private mutating func parseBlockquote() {
        let start = index
        var inner: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if trimmed.hasPrefix(">") {
                var rest = trimmed.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                inner.append(String(rest))
                index += 1
            } else if !isListLine(lines[index]), fenceInfo(trimmed) == nil {
                inner.append(lines[index])
                index += 1
            } else {
                break
            }
        }
        var nested = Parser(lines: inner, lineBase: start + lineBase)
        html += "<blockquote\(lineAttr(start))>\(nested.render())</blockquote>\n"
    }

    private mutating func parseTable() -> Bool {
        guard index + 1 < lines.count else { return false }
        let headerLine = lines[index]
        let dividerLine = lines[index + 1]
        guard headerLine.contains("|"), isTableDivider(dividerLine) else { return false }

        let headers = tableCells(headerLine)
        let alignments = tableAlignments(dividerLine)
        guard headers.count >= 1, alignments.count >= 1 else { return false }

        let headerIndex = index
        index += 2
        var rows: [(sourceIndex: Int, cells: [String])] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if !line.contains("|") { break }
            rows.append((index, tableCells(line)))
            index += 1
        }

        html += "<table><thead><tr\(lineAttr(headerIndex))>"
        for (offset, cell) in headers.enumerated() {
            html += "<th\(alignAttr(alignments, offset))>\(renderInline(cell))</th>"
        }
        html += "</tr></thead><tbody>"
        for row in rows {
            html += "<tr\(lineAttr(row.sourceIndex))>"
            for offset in headers.indices {
                let cell = offset < row.cells.count ? row.cells[offset] : ""
                html += "<td\(alignAttr(alignments, offset))>\(renderInline(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table>\n"
        return true
    }

    private func isTableDivider(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            return trimmed.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
                && trimmed.contains("-")
        }
    }

    private func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text = String(text.dropFirst()) }
        if text.hasSuffix("|") { text = String(text.dropLast()) }
        return text.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func tableAlignments(_ line: String) -> [String] {
        tableCells(line).map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            if left && right { return "center" }
            if right { return "right" }
            if left { return "left" }
            return ""
        }
    }

    private func alignAttr(_ alignments: [String], _ offset: Int) -> String {
        guard offset < alignments.count, !alignments[offset].isEmpty else { return "" }
        return " style=\"text-align:\(alignments[offset])\""
    }

    private func isListLine(_ line: String) -> Bool {
        listMarker(line) != nil
    }

    private struct ListMarker {
        var indent: Int
        var ordered: Bool
        var markerWidth: Int
        var checked: Bool?
        var content: String
    }

    private func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingSpaces(line)
        let rest = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            var content = String(rest.dropFirst(2))
            var checked: Bool?
            if content.hasPrefix("[ ] ") {
                checked = false
                content = String(content.dropFirst(4))
            } else if content.lowercased().hasPrefix("[x] ") {
                checked = true
                content = String(content.dropFirst(4))
            }
            return ListMarker(
                indent: indent,
                ordered: false,
                markerWidth: 2,
                checked: checked,
                content: content
            )
        }
        var digits = 0
        for character in rest {
            if character.isNumber { digits += 1 } else { break }
        }
        guard digits > 0, digits < rest.count else { return nil }
        let after = rest.dropFirst(digits)
        guard after.first == "." || after.first == ")" else { return nil }
        let next = after.dropFirst()
        guard next.first == " " || next.first == "\t" else { return nil }
        return ListMarker(
            indent: indent,
            ordered: true,
            markerWidth: digits + 2,
            checked: nil,
            content: String(next.dropFirst())
        )
    }

    private mutating func parseList(baseIndent: Int) {
        guard let first = listMarker(lines[index]) else { return }
        html += first.ordered ? "<ol>\n" : "<ul>\n"
        while index < lines.count {
            guard let marker = listMarker(lines[index]),
                  marker.indent == baseIndent,
                  marker.ordered == first.ordered
            else { break }

            let itemLine = index
            index += 1
            var itemLines = [marker.content]
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if index + 1 < lines.count {
                        let next = lines[index + 1]
                        if leadingSpaces(next) > baseIndent
                            || listMarker(next)?.indent == baseIndent
                        {
                            itemLines.append("")
                            index += 1
                            continue
                        }
                    }
                    break
                }
                if let nested = listMarker(line), nested.indent == baseIndent {
                    break
                }
                let indent = leadingSpaces(line)
                if indent >= baseIndent + 2 {
                    itemLines.append(
                        dropLeading(line, count: min(indent, baseIndent + marker.markerWidth))
                    )
                    index += 1
                    continue
                }
                break
            }

            html += "<li\(lineAttr(itemLine))>"
            if let checked = marker.checked {
                html += "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            }
            if itemLines.count == 1 {
                html += renderInline(itemLines[0])
            } else {
                var nested = Parser(lines: itemLines, lineBase: itemLine + lineBase)
                html += nested.render()
            }
            html += "</li>\n"
        }
        html += first.ordered ? "</ol>\n" : "</ul>\n"
    }

    private func dropLeading(_ line: String, count: Int) -> String {
        var remaining = line
        var removed = 0
        while removed < count, let firstChar = remaining.first {
            if firstChar == " " {
                remaining.removeFirst()
                removed += 1
            } else if firstChar == "\t" {
                remaining.removeFirst()
                removed += 4
            } else {
                break
            }
        }
        return remaining
    }

    private mutating func parseParagraph() {
        let start = index
        var parts: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if trimmed.hasPrefix("#") && atxHeading(trimmed) != nil { break }
            if trimmed.hasPrefix(">") { break }
            if fenceInfo(trimmed) != nil { break }
            if isHorizontalRule(trimmed) { break }
            if isListLine(line) { break }
            if trimmed.hasPrefix("<") { break }
            if index + 1 < lines.count, isTableDivider(lines[index + 1]) { break }
            parts.append(line)
            index += 1
        }
        guard !parts.isEmpty else { return }
        var rendered: [String] = []
        for (offset, part) in parts.enumerated() {
            var text = part.trimmingCharacters(in: .whitespaces)
            let hardBreak = part.hasSuffix("  ") || part.hasSuffix("\\")
            if part.hasSuffix("\\") {
                text = String(text.dropLast())
            }
            var piece = renderInline(text)
            if hardBreak, offset + 1 < parts.count {
                piece += "<br>"
            }
            rendered.append(piece)
        }
        html += "<p\(lineAttr(start))>\(rendered.joined(separator: "\n"))</p>\n"
    }

    // MARK: - Inline

    private func renderInline(_ raw: String) -> String {
        var placeholders: [String: String] = [:]
        var text = raw
        text = replaceCodeSpans(text, placeholders: &placeholders)
        text = MarkdownHTML.escape(text)
        text = replaceImages(text)
        text = replaceLinks(text)
        text = replaceAutolinks(text)
        text = replaceEmphasis(text)
        for (token, value) in placeholders {
            text = text.replacingOccurrences(of: token, with: value)
        }
        return text
    }

    private func replaceCodeSpans(
        _ raw: String,
        placeholders: inout [String: String]
    ) -> String {
        var result = ""
        var remaining = raw[...]
        while let start = remaining.firstIndex(of: "`") {
            result += remaining[..<start]
            var ticks = 0
            var cursor = start
            while cursor < remaining.endIndex, remaining[cursor] == "`" {
                ticks += 1
                cursor = remaining.index(after: cursor)
            }
            let fence = String(repeating: "`", count: ticks)
            let rest = remaining[cursor...]
            if let end = rest.range(of: fence) {
                let code = String(rest[rest.startIndex..<end.lowerBound])
                let token = "\u{001A}CODE\(placeholders.count)\u{001A}"
                placeholders[token] = "<code>\(MarkdownHTML.escape(code))</code>"
                result += token
                remaining = rest[end.upperBound...]
            } else {
                result += fence
                remaining = rest
            }
        }
        result += remaining
        return result
    }

    private func replaceImages(_ text: String) -> String {
        var result = replacePattern(
            text,
            pattern: "!\\[([^\\]]*)\\]\\(\\s*<([^>]+)>\\s*(?:\"([^\"]*)\")?\\s*\\)"
        ) { emitImage($0) }
        result = replacePattern(
            result,
            pattern: "!\\[([^\\]]*)\\]\\(\\s*([^)\\s]+)\\s*(?:\"([^\"]*)\")?\\s*\\)"
        ) { emitImage($0) }
        result = replacePattern(
            result,
            pattern: "!\\[([^\\]]*)\\]\\(\\s*([^)]+?)\\s*\\)"
        ) { emitImage($0) }
        return result
    }

    private func emitImage(_ match: [String]) -> String {
        let alt = MarkdownHTML.escape(match[1])
        let url = match[2].trimmingCharacters(in: .whitespaces)
        guard MarkdownHTML.isSafeURL(url) else {
            return MarkdownHTML.escape("![\(match[1])](\(match[2]))")
        }
        let title = match.count > 3 ? match[3] : ""
        let titleAttr = title.isEmpty
            ? ""
            : " title=\"\(MarkdownHTML.escapeAttribute(title))\""
        let src = MarkdownHTML.escapeAttribute(MarkdownHTML.encodeResourceURL(url))
        return "<img src=\"\(src)\" alt=\"\(alt)\"\(titleAttr)>"
    }

    private func replaceLinks(_ text: String) -> String {
        var result = replacePattern(
            text,
            pattern: "(?<!!)\\[([^\\]]+)\\]\\(\\s*<([^>]+)>\\s*(?:\"([^\"]*)\")?\\s*\\)"
        ) { emitLink($0) }
        result = replacePattern(
            result,
            pattern: "(?<!!)\\[([^\\]]+)\\]\\(\\s*([^)\\s]+)\\s*(?:\"([^\"]*)\")?\\s*\\)"
        ) { emitLink($0) }
        result = replacePattern(
            result,
            pattern: "(?<!!)\\[([^\\]]+)\\]\\(\\s*([^)]+?)\\s*\\)"
        ) { emitLink($0) }
        return result
    }

    private func emitLink(_ match: [String]) -> String {
        let label = match[1]
        let url = match[2].trimmingCharacters(in: .whitespaces)
        guard MarkdownHTML.isSafeURL(url) else {
            return "[\(label)](\(MarkdownHTML.escape(url)))"
        }
        let title = match.count > 3 ? match[3] : ""
        let titleAttr = title.isEmpty
            ? ""
            : " title=\"\(MarkdownHTML.escapeAttribute(title))\""
        let href = MarkdownHTML.escapeAttribute(MarkdownHTML.encodeResourceURL(url))
        return "<a href=\"\(href)\"\(titleAttr)>\(label)</a>"
    }

    private func replaceAutolinks(_ text: String) -> String {
        var result = replacePattern(
            text,
            pattern: "&lt;(https?://[^&]+)&gt;"
        ) { match in
            let url = match[1]
                .replacingOccurrences(of: "&amp;", with: "&")
            guard MarkdownHTML.isSafeURL(url) else { return match[0] }
            let escaped = MarkdownHTML.escapeAttribute(url)
            return "<a href=\"\(escaped)\">\(MarkdownHTML.escape(url))</a>"
        }
        result = replacePattern(
            result,
            pattern: "(?<![\\\"'>])(https?://[^\\s<]+)"
        ) { match in
            var url = match[1]
            var suffix = ""
            while let last = url.last, ".,;:!?)]}\"'".contains(last) {
                suffix.insert(last, at: suffix.startIndex)
                url.removeLast()
            }
            guard MarkdownHTML.isSafeURL(url) else { return match[0] }
            let escaped = MarkdownHTML.escapeAttribute(url)
            return "<a href=\"\(escaped)\">\(MarkdownHTML.escape(url))</a>\(suffix)"
        }
        return result
    }

    private func replaceEmphasis(_ text: String) -> String {
        var result = text
        result = replacePattern(result, pattern: "~~([^~]+)~~") { match in
            "<del>\(match[1])</del>"
        }
        result = replacePattern(result, pattern: "\\*\\*\\*([^*]+)\\*\\*\\*") { match in
            "<strong><em>\(match[1])</em></strong>"
        }
        result = replacePattern(result, pattern: "___([^_]+)___") { match in
            "<strong><em>\(match[1])</em></strong>"
        }
        result = replacePattern(result, pattern: "\\*\\*([^*]+)\\*\\*") { match in
            "<strong>\(match[1])</strong>"
        }
        result = replacePattern(result, pattern: "__([^_]+)__") { match in
            "<strong>\(match[1])</strong>"
        }
        result = replacePattern(result, pattern: "(?<!\\*)\\*([^*]+)\\*(?!\\*)") { match in
            "<em>\(match[1])</em>"
        }
        result = replacePattern(result, pattern: "(?<![A-Za-z0-9_])_([^_]+)_(?![A-Za-z0-9_])") { match in
            "<em>\(match[1])</em>"
        }
        return result
    }

    private func replacePattern(
        _ text: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += nsText.substring(
                    with: NSRange(location: cursor, length: range.location - cursor)
                )
            }
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let groupRange = match.range(at: index)
                if groupRange.location == NSNotFound {
                    groups.append("")
                } else {
                    groups.append(nsText.substring(with: groupRange))
                }
            }
            result += transform(groups)
            cursor = range.location + range.length
        }
        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }
        return result
    }
}
