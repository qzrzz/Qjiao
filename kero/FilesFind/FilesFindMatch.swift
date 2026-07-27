//
//  FilesFindMatch.swift
//  kero
//
//  全局文本搜寻与文件匹配的数据模型结构定义。
//

import Foundation

/// 搜索选项参数配置结构
public struct SearchOptions: Equatable, Codable {
    /// 搜索查询关键字或正则表达式
    public var query: String = ""
    /// 替换文本内容
    public var replaceText: String = ""
    /// 是否区分大小写 (Aa)
    public var isCaseSensitive: Bool = false
    /// 是否全字匹配 (\b)
    public var isMatchWholeWord: Bool = false
    /// 是否使用正则表达式 (.*)
    public var isUseRegex: Bool = false
    /// 包含的文件 Glob 模式 (例如: *.swift, src/**)
    public var includePattern: String = ""
    /// 排除的文件 Glob 模式 (例如: node_modules, .git, dist)
    public var excludePattern: String = ""

    public init(
        query: String = "",
        replaceText: String = "",
        isCaseSensitive: Bool = false,
        isMatchWholeWord: Bool = false,
        isUseRegex: Bool = false,
        includePattern: String = "",
        excludePattern: String = ""
    ) {
        self.query = query
        self.replaceText = replaceText
        self.isCaseSensitive = isCaseSensitive
        self.isMatchWholeWord = isMatchWholeWord
        self.isUseRegex = isUseRegex
        self.includePattern = includePattern
        self.excludePattern = excludePattern
    }
}

/// 匹配结果显示模式（树形/平铺）
public enum FilesFindDisplayMode: String, CaseIterable, Identifiable {
    case tree
    case list

    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .tree: return "Tree"
        case .list: return "List"
        }
    }
}

/// 单条文本匹配项
public struct MatchItem: Identifiable, Equatable, Sendable {
    /// 匹配项唯一标识符
    public let id: UUID
    /// 文件中的行号（基于 1）
    public let lineNumber: Int
    /// 匹配起始列号（基于 0）
    public let column: Int
    /// 完整行文本
    public let lineContent: String
    /// 匹配文本的 Range 范围
    public let matchRange: NSRange
    /// 匹配的前缀预览字符
    public let previewPrefix: String
    /// 匹配的具体文本片段
    public var matchedText: String
    /// 匹配的后缀预览字符
    public let previewSuffix: String

    public init(
        id: UUID = UUID(),
        lineNumber: Int,
        column: Int = 0,
        lineContent: String,
        matchRange: NSRange,
        previewPrefix: String = "",
        matchedText: String = "",
        previewSuffix: String = ""
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.column = column
        self.lineContent = lineContent
        self.matchRange = matchRange
        self.previewPrefix = previewPrefix
        self.matchedText = matchedText.isEmpty ? (lineContent as NSString).substring(with: matchRange) : matchedText
        self.previewSuffix = previewSuffix
    }
}

/// 单个文件的搜索结果集合
public struct FileSearchResult: Identifiable, Equatable, Sendable {
    /// 文件绝对路径作为 ID
    public var id: String { path }
    /// 文件绝对路径
    public let path: String
    /// 文件名 (例如: main.swift)
    public let fileName: String
    /// 相对项目根目录的路径 (例如: src/utils/main.swift)
    public let relativePath: String
    /// 文件内包含的所有匹配项
    public var matches: [MatchItem]
    /// UI 界面上该文件节点是否展开
    public var isExpanded: Bool

    public init(
        path: String,
        fileName: String,
        relativePath: String,
        matches: [MatchItem] = [],
        isExpanded: Bool = true
    ) {
        self.path = path
        self.fileName = fileName
        self.relativePath = relativePath
        self.matches = matches
        self.isExpanded = isExpanded
    }
}
