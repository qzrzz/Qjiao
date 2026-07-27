//
//  FilesFindModel.swift
//  kero
//
//  FilesFind 的 ViewModel 状态管理中心，负责搜索防抖、结果状态同步、流式 UI 刷新及替换控制。
//

import Combine
import Foundation

@MainActor
public final class FilesFindModel: ObservableObject {
    /// 搜寻配置参数
    @Published public var options: SearchOptions = SearchOptions()
    /// 是否正在搜寻中
    @Published public var isSearching: Bool = false
    /// 搜寻结果集
    @Published public var results: [FileSearchResult] = []
    /// 替换框是否展开
    @Published public var isReplaceExpanded: Bool = false
    /// 高级过滤条件（Include / Exclude）是否展开
    @Published public var isFilterExpanded: Bool = false
    /// 显示模式 (Tree / List)
    @Published public var displayMode: FilesFindDisplayMode = .tree
    /// 搜寻耗时提示与状态文案
    @Published public var statusMessage: String = ""
    /// 搜索耗时（秒）
    @Published public var searchDuration: Double = 0.0

    /// 当前搜索任务引用
    private var currentTask: Task<Void, Never>?
    /// 当前项目路径
    private var currentRootPath: String = ""

    public init() {}

    /// 总匹配结果数
    public var totalMatchCount: Int {
        results.reduce(0) { $0 + $1.matches.count }
    }

    /// 涉及的匹配文件总数
    public var totalFileCount: Int {
        results.count
    }

    /// 执行异步搜索
    /// - Parameter rootPath: 项目根目录绝对路径
    public func performSearch(rootPath: String) {
        currentRootPath = rootPath
        currentTask?.cancel()

        guard !options.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            statusMessage = ""
            return
        }

        isSearching = true
        statusMessage = "Searching…"
        results = []

        let startTime = Date()

        currentTask = Task {
            do {
                let searchEngine = FilesFindEngine.shared
                let localOptions = options

                let searchResults = try await searchEngine.search(
                    rootPath: rootPath,
                    options: localOptions,
                    onProgress: { [weak self] newResult in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if let index = self.results.firstIndex(where: { $0.path == newResult.path }) {
                                self.results[index] = newResult
                            } else {
                                self.results.append(newResult)
                            }
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                self.results = searchResults
                self.isSearching = false
                let elapsed = Date().timeIntervalSince(startTime)
                self.searchDuration = elapsed

                if searchResults.isEmpty {
                    self.statusMessage = "No results found."
                } else {
                    let fileStr = self.totalFileCount == 1 ? "file" : "files"
                    let matchStr = self.totalMatchCount == 1 ? "result" : "results"
                    self.statusMessage = "\(self.totalMatchCount) \(matchStr) in \(self.totalFileCount) \(fileStr) (\(String(format: "%.2f", elapsed))s)"
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.isSearching = false
                self.statusMessage = "Search error: \(error.localizedDescription)"
            }
        }
    }

    /// 取消当前搜索任务
    public func cancelSearch() {
        currentTask?.cancel()
        currentTask = nil
        isSearching = false
        statusMessage = "Search cancelled."
    }

    /// 清空搜寻输入与结果
    public func clear() {
        cancelSearch()
        options.query = ""
        options.replaceText = ""
        results = []
        statusMessage = ""
    }

    /// 展开或折叠所有文件匹配节点
    /// - Parameter expand: true 为全部展开，false 为全部收起
    public func toggleExpandAll(_ expand: Bool) {
        for i in 0..<results.count {
            results[i].isExpanded = expand
        }
    }

    /// 展开/折叠指定文件的匹配结果
    /// - Parameter result: 目标文件搜索结果
    public func toggleFileExpand(_ result: FileSearchResult) {
        if let index = results.firstIndex(where: { $0.path == result.path }) {
            results[index].isExpanded.toggle()
        }
    }

    /// 从搜索结果中移除某个匹配项
    /// - Parameters:
    ///   - result: 目标文件搜索结果
    ///   - match: 匹配项
    public func dismissMatch(in result: FileSearchResult, match: MatchItem) {
        guard let fileIdx = results.firstIndex(where: { $0.path == result.path }) else { return }
        results[fileIdx].matches.removeAll(where: { $0.id == match.id })
        if results[fileIdx].matches.isEmpty {
            results.remove(at: fileIdx)
        }
    }

    /// 替换单个匹配项
    /// - Parameters:
    ///   - result: 目标文件搜索结果
    ///   - match: 匹配项
    public func replaceMatch(in result: FileSearchResult, match: MatchItem) {
        do {
            try FilesFindEngine.shared.replace(match: match, in: result.path, with: options.replaceText)
            dismissMatch(in: result, match: match)
            if !currentRootPath.isEmpty {
                // 重新刷新文件搜索
                performSearch(rootPath: currentRootPath)
            }
        } catch {
            statusMessage = "Replace failed: \(error.localizedDescription)"
        }
    }

    /// 替换指定文件中的所有匹配项
    /// - Parameter result: 目标文件搜索结果
    public func replaceAllInFile(_ result: FileSearchResult) {
        do {
            try FilesFindEngine.shared.replaceAll(in: result, with: options.replaceText)
            results.removeAll(where: { $0.path == result.path })
            if !currentRootPath.isEmpty {
                performSearch(rootPath: currentRootPath)
            }
        } catch {
            statusMessage = "Replace all failed: \(error.localizedDescription)"
        }
    }

    /// 替换项目中的所有匹配项
    public func replaceAllInProject() {
        guard !results.isEmpty else { return }
        let currentResults = results
        for res in currentResults {
            try? FilesFindEngine.shared.replaceAll(in: res, with: options.replaceText)
        }
        if !currentRootPath.isEmpty {
            performSearch(rootPath: currentRootPath)
        }
    }
}
