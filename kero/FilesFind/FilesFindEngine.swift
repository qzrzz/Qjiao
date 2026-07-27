//
//  FilesFindEngine.swift
//  kero
//
//  全局文件文本搜寻引擎实现，包含 ripgrep CLI 驱动与 Swift 多线程并发 fallback 引擎。
//

import Foundation

/// 全局搜寻引擎类，负责高效检索文件内容及文本替换
public final class FilesFindEngine: @unchecked Sendable {
    /// 共享单例引擎实例
    public static let shared = FilesFindEngine()

    private init() {}

    /// 执行搜寻任务，优先使用系统的 ripgrep，若无则使用 Swift 多线程引擎
    /// - Parameters:
    ///   - rootPath: 要搜寻的项目根目录
    ///   - options: 搜寻选项配置
    ///   - onProgress: 发现新文件匹配结果时的增量回调
    /// - Returns: 所有匹配的文件搜索结果数组
    public func search(
        rootPath: String,
        options: SearchOptions,
        onProgress: (@Sendable (FileSearchResult) -> Void)? = nil
    ) async throws -> [FileSearchResult] {
        guard !options.query.isEmpty, FileManager.default.fileExists(atPath: rootPath) else {
            return []
        }

        // 优先尝试查找 ripgrep 二进制
        if let rgPath = findRipgrepExecutable() {
            do {
                return try await searchWithRipgrep(
                    rgPath: rgPath,
                    rootPath: rootPath,
                    options: options,
                    onProgress: onProgress
                )
            } catch {
                // 如果 rg 搜寻异常，降级至 Swift 原生并发搜寻引擎
                return try await searchWithSwiftFallback(
                    rootPath: rootPath,
                    options: options,
                    onProgress: onProgress
                )
            }
        } else {
            return try await searchWithSwiftFallback(
                rootPath: rootPath,
                options: options,
                onProgress: onProgress
            )
        }
    }

    // MARK: - Ripgrep (rg) 搜索引擎实现

    /// 优先使用 Bundle 内置或 VendorBin 目录下的 ripgrep 二进制，其次探测系统常用路径
    private func findRipgrepExecutable() -> String? {
        var candidates: [String] = []
        let fileManager = FileManager.default

        // 1. Bundle 资源路径 (打包成 App 后)
        if let bundlePath = Bundle.main.path(forResource: "rg", ofType: nil) {
            candidates.append(bundlePath)
        }
        if let vendorBinBundlePath = Bundle.main.path(forResource: "rg", ofType: nil, inDirectory: "VendorBin") {
            candidates.append(vendorBinBundlePath)
        }

        // 2. 源代码/工程相对路径 (开发及测试模式下)
        let currentDir = fileManager.currentDirectoryPath
        candidates.append("\(currentDir)/kero/VendorBin/rg")
        candidates.append("\(currentDir)/VendorBin/rg")

        // 3. 项目 App Resources 相对路径
        if let mainExecutableURL = Bundle.main.executableURL {
            let bundleResourceDir = mainExecutableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources").path
            candidates.append("\(bundleResourceDir)/VendorBin/rg")
            candidates.append("\(bundleResourceDir)/rg")
        }

        // 4. 系统常用 PATH 路径
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg",
            "/bin/rg"
        ])

        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// 使用 ripgrep --json 执行高速搜寻
    private func searchWithRipgrep(
        rgPath: String,
        rootPath: String,
        options: SearchOptions,
        onProgress: (@Sendable (FileSearchResult) -> Void)?
    ) async throws -> [FileSearchResult] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var args: [String] = ["--json"]

                if options.isCaseSensitive {
                    args.append("-s") // --case-sensitive
                } else {
                    args.append("-i") // --ignore-case
                }

                if options.isMatchWholeWord {
                    args.append("-w") // --word-regexp
                }

                if !options.isUseRegex {
                    args.append("-F") // --fixed-strings
                }

                // 包含文件通配符
                if !options.includePattern.isEmpty {
                    let patterns = options.includePattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    for pat in patterns where !pat.isEmpty {
                        args.append(contentsOf: ["-g", pat])
                    }
                }

                // 排除文件通配符
                if !options.excludePattern.isEmpty {
                    let patterns = options.excludePattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    for pat in patterns where !pat.isEmpty {
                        let glob = pat.hasPrefix("!") ? pat : "!\(pat)"
                        args.append(contentsOf: ["-g", glob])
                    }
                }

                // 搜索表达式与路径
                args.append(options.query)
                args.append(rootPath)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: rgPath)
                process.arguments = args

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                var fileResultsMap: [String: FileSearchResult] = [:]
                let lock = NSLock()

                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
                    let lines = output.components(separatedBy: .newlines)
                    for line in lines where !line.isEmpty {
                        guard let lineData = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let type = json["type"] as? String, type == "match",
                              let matchData = json["data"] as? [String: Any] else {
                            continue
                        }

                        if let pathDict = matchData["path"] as? [String: Any],
                           let filePath = pathDict["text"] as? String,
                           let lineNumber = matchData["line_number"] as? Int,
                           let linesDict = matchData["lines"] as? [String: Any],
                           let lineTextWithNewline = linesDict["text"] as? String,
                           let submatches = matchData["submatches"] as? [[String: Any]] {

                            let cleanLine = lineTextWithNewline.trimmingCharacters(in: .newlines)
                            let relPath = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) : filePath
                            let fileName = URL(fileURLWithPath: filePath).lastPathComponent

                            for sub in submatches {
                                let start = sub["start"] as? Int ?? 0
                                let end = sub["end"] as? Int ?? 0
                                let matchRange = NSRange(location: start, length: max(0, end - start))
                                let matchedStr = (cleanLine as NSString).substring(with: matchRange)

                                let item = MatchItem(
                                    lineNumber: lineNumber,
                                    column: start,
                                    lineContent: cleanLine,
                                    matchRange: matchRange,
                                    previewPrefix: String(cleanLine.prefix(start)),
                                    matchedText: matchedStr,
                                    previewSuffix: String(cleanLine.dropFirst(end))
                                )

                                lock.lock()
                                if var existing = fileResultsMap[filePath] {
                                    existing.matches.append(item)
                                    fileResultsMap[filePath] = existing
                                } else {
                                    let newResult = FileSearchResult(
                                        path: filePath,
                                        fileName: fileName,
                                        relativePath: relPath,
                                        matches: [item]
                                    )
                                    fileResultsMap[filePath] = newResult
                                    onProgress?(newResult)
                                }
                                lock.unlock()
                            }
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    handle.readabilityHandler = nil
                    
                    lock.lock()
                    let finalResults = Array(fileResultsMap.values)
                    lock.unlock()
                    continuation.resume(returning: finalResults)
                } catch {
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Swift 多线程原生并发搜索 fallback

    /// 当没有安装 ripgrep 时调用的 Swift 原生并发目录及文件扫描引擎
    private func searchWithSwiftFallback(
        rootPath: String,
        options: SearchOptions,
        onProgress: (@Sendable (FileSearchResult) -> Void)?
    ) async throws -> [FileSearchResult] {
        let rootURL = URL(fileURLWithPath: rootPath)
        let fileManager = FileManager.default

        // 默认忽略的敏感及临时目录
        let defaultExcludes: Set<String> = [
            ".git", "node_modules", ".DS_Store", "build", "dist", ".build", ".tmp_mit", "DerivedData"
        ]

        let regex: NSRegularExpression?
        if options.isUseRegex {
            var pattern = options.query
            if options.isMatchWholeWord {
                pattern = "\\b\(pattern)\\b"
            }
            let regexOptions: NSRegularExpression.Options = options.isCaseSensitive ? [] : [.caseInsensitive]
            regex = try? NSRegularExpression(pattern: pattern, options: regexOptions)
        } else {
            regex = nil
        }

        // 递归遍历文件
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var filesToSearch: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let pathComponents = fileURL.pathComponents
            if pathComponents.contains(where: { defaultExcludes.contains($0) }) {
                continue
            }
            var isRegularFile: AnyObject?
            try? (fileURL as NSURL).getResourceValue(&isRegularFile, forKey: .isRegularFileKey)
            if let isFile = isRegularFile as? Bool, isFile {
                // 检查文件体积，避免试图扫描超大文件（例如 > 20MB）
                var fileSize: AnyObject?
                try? (fileURL as NSURL).getResourceValue(&fileSize, forKey: .fileSizeKey)
                if let size = fileSize as? Int, size > 20 * 1024 * 1024 {
                    continue
                }
                filesToSearch.append(fileURL)
            }
        }

        let totalFiles = filesToSearch
        let searchOptions = options

        return await withTaskGroup(of: FileSearchResult?.self) { group in
            for fileURL in totalFiles {
                group.addTask {
                    return self.scanSingleFile(fileURL: fileURL, rootPath: rootPath, options: searchOptions, regex: regex)
                }
            }

            var results: [FileSearchResult] = []
            for await res in group {
                if let res {
                    results.append(res)
                    onProgress?(res)
                }
            }
            return results
        }
    }

    /// 扫描单个文件并返回匹配结果
    private func scanSingleFile(
        fileURL: URL,
        rootPath: String,
        options: SearchOptions,
        regex: NSRegularExpression?
    ) -> FileSearchResult? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let filePath = fileURL.path
        let fileName = fileURL.lastPathComponent
        let relPath = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) : filePath

        var matches: [MatchItem] = []
        let lines = content.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let nsLine = line as NSString

            if let regex {
                let nsMatches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
                for match in nsMatches {
                    let range = match.range
                    let matchedStr = nsLine.substring(with: range)
                    let prefix = String(line.prefix(range.location))
                    let suffix = String(line.dropFirst(range.location + range.length))

                    matches.append(MatchItem(
                        lineNumber: lineNumber,
                        column: range.location,
                        lineContent: line,
                        matchRange: range,
                        previewPrefix: prefix,
                        matchedText: matchedStr,
                        previewSuffix: suffix
                    ))
                }
            } else {
                let query = options.query
                var searchRange = NSRange(location: 0, length: nsLine.length)

                let compareOptions: NSString.CompareOptions = options.isCaseSensitive ? [] : [.caseInsensitive]

                while searchRange.location < nsLine.length {
                    let foundRange = nsLine.range(of: query, options: compareOptions, range: searchRange)
                    if foundRange.location == NSNotFound {
                        break
                    }

                    // 检查全字匹配
                    var isMatch = true
                    if options.isMatchWholeWord {
                        let leftBound = foundRange.location
                        let rightBound = foundRange.location + foundRange.length
                        if leftBound > 0 {
                            let leftChar = nsLine.character(at: leftBound - 1)
                            if CharacterSet.alphanumerics.contains(UnicodeScalar(leftChar)!) {
                                isMatch = false
                            }
                        }
                        if rightBound < nsLine.length {
                            let rightChar = nsLine.character(at: rightBound)
                            if CharacterSet.alphanumerics.contains(UnicodeScalar(rightChar)!) {
                                isMatch = false
                            }
                        }
                    }

                    if isMatch {
                        let matchedStr = nsLine.substring(with: foundRange)
                        let prefix = String(line.prefix(foundRange.location))
                        let suffix = String(line.dropFirst(foundRange.location + foundRange.length))

                        matches.append(MatchItem(
                            lineNumber: lineNumber,
                            column: foundRange.location,
                            lineContent: line,
                            matchRange: foundRange,
                            previewPrefix: prefix,
                            matchedText: matchedStr,
                            previewSuffix: suffix
                        ))
                    }

                    searchRange.location = foundRange.location + max(1, foundRange.length)
                    searchRange.length = nsLine.length - searchRange.location
                }
            }
        }

        guard !matches.isEmpty else { return nil }
        return FileSearchResult(
            path: filePath,
            fileName: fileName,
            relativePath: relPath,
            matches: matches
        )
    }

    // MARK: - 文本替换逻辑

    /// 替换指定文件中的单条匹配项
    /// - Parameters:
    ///   - filePath: 文件路径
    ///   - match: 要替换的匹配项
    ///   - replacementText: 替换目标文本
    public func replace(match: MatchItem, in filePath: String, with replacementText: String) throws {
        let fileURL = URL(fileURLWithPath: filePath)
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)

        let lineIdx = match.lineNumber - 1
        guard lineIdx >= 0 && lineIdx < lines.count else { return }

        let targetLine = lines[lineIdx]
        let nsLine = targetLine as NSString

        if match.matchRange.location + match.matchRange.length <= nsLine.length {
            let updatedLine = nsLine.replacingCharacters(in: match.matchRange, with: replacementText)
            lines[lineIdx] = updatedLine
            let newContent = lines.joined(separator: "\n")
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// 替换单个文件中的所有匹配项
    /// - Parameters:
    ///   - result: 文件匹配结果集
    ///   - replacementText: 替换目标文本
    public func replaceAll(in result: FileSearchResult, with replacementText: String) throws {
        let fileURL = URL(fileURLWithPath: result.path)
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = content.components(separatedBy: .newlines)

        // 按行号降序排列进行替换，避免行变动影响偏移量
        let groupedByLine = Dictionary(grouping: result.matches, by: { $0.lineNumber })
        for (lineNum, matchesInLine) in groupedByLine {
            let lineIdx = lineNum - 1
            guard lineIdx >= 0 && lineIdx < lines.count else { continue }
            var lineStr = lines[lineIdx] as NSString
            let sortedMatches = matchesInLine.sorted(by: { $0.column > $1.column })
            for match in sortedMatches {
                if match.matchRange.location + match.matchRange.length <= lineStr.length {
                    lineStr = lineStr.replacingCharacters(in: match.matchRange, with: replacementText) as NSString
                }
            }
            lines[lineIdx] = lineStr as String
        }

        let newContent = lines.joined(separator: "\n")
        try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
