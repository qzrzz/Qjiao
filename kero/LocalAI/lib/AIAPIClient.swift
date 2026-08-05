//
//  AIAPIClient.swift
//  kero
//
//  通过 URLSession 调用 OpenAI-compatible、Anthropic Messages 与 Gemini REST API。
//

import Foundation

/// 一次 API 调用所需的不可变配置快照。
struct AIAPIConfiguration: Sendable {
    let provider: AIAPIProviderID
    let apiKey: String
    let model: String
    let baseURL: String
}

/// 云端 AI API 的统一客户端。
enum AIAPIClient {
    /// 发送单轮纯文本提示，并转换为现有 `LocalAIResponse`。
    static func prompt(
        _ request: LocalAIRequest,
        configuration: AIAPIConfiguration
    ) async throws -> LocalAIResponse {
        let urlRequest = try makeURLRequest(request, configuration: configuration)
        let startedAt = Date()
        let metricsDelegate = AIAPIRequestMetricsDelegate()
        logRequest(urlRequest, configuration: configuration)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(
                for: urlRequest,
                delegate: metricsDelegate
            )
        } catch is CancellationError {
            logNetworkMetrics(metricsDelegate.snapshot, startedAt: startedAt)
            logRequestFailure(CancellationError(), configuration: configuration)
            throw CancellationError()
        } catch {
            logNetworkMetrics(metricsDelegate.snapshot, startedAt: startedAt)
            logRequestFailure(error, configuration: configuration)
            if Task.isCancelled { throw CancellationError() }
            throw LocalAIError.apiRequestFailed(
                provider: configuration.provider,
                statusCode: 0,
                message: error.localizedDescription
            )
        }

        try Task.checkCancellation()
        logNetworkMetrics(metricsDelegate.snapshot, startedAt: startedAt)
        logResponse(
            response,
            data: data,
            duration: Date().timeIntervalSince(startedAt),
            configuration: configuration
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalAIError.apiRequestFailed(
                provider: configuration.provider,
                statusCode: 0,
                message: L10n.t("The API returned an invalid HTTP response.")
            )
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(httpResponse.statusCode) else {
            throw LocalAIError.apiRequestFailed(
                provider: configuration.provider,
                statusCode: httpResponse.statusCode,
                message: extractErrorMessage(json: json, data: data)
            )
        }

        let text = try extractText(
            json: json,
            provider: configuration.provider,
            statusCode: httpResponse.statusCode
        )
        return LocalAIResponse(
            text: text,
            exitCode: 0,
            provider: .api(configuration.provider),
            rawStdout: String(data: data, encoding: .utf8) ?? "",
            rawStderr: "",
            executablePath: urlRequest.url?.absoluteString ?? configuration.baseURL
        )
    }

    /// 根据供应商协议构建请求地址、鉴权头与 JSON Body。
    private static func makeURLRequest(
        _ request: LocalAIRequest,
        configuration: AIAPIConfiguration
    ) throws -> URLRequest {
        let provider = configuration.provider
        let endpoint: String
        let body: [String: Any]

        switch provider.protocolStyle {
        case .openAIChatCompletions:
            endpoint = appendPath("chat/completions", to: configuration.baseURL)
            body = [
                "model": configuration.model,
                "messages": [["role": "user", "content": request.prompt]],
            ]
        case .anthropicMessages:
            endpoint = appendPath("messages", to: configuration.baseURL)
            body = [
                "model": configuration.model,
                "max_tokens": 4096,
                "messages": [["role": "user", "content": request.prompt]],
            ]
        case .geminiGenerateContent:
            guard let escapedModel = configuration.model.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) else {
                throw LocalAIError.invalidAPIConfiguration(L10n.t("The AI model ID is invalid."))
            }
            endpoint = appendPath("models/\(escapedModel):generateContent", to: configuration.baseURL)
            body = ["contents": [["parts": [["text": request.prompt]]]]]
        }

        guard let url = URL(string: endpoint),
              let host = url.host?.lowercased(),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && isLoopbackHost(host))
        else {
            throw LocalAIError.invalidAPIConfiguration(
                L10n.t("Enter a valid HTTPS API base URL. HTTP is only allowed for localhost.")
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds(request.timeout)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch provider.protocolStyle {
        case .openAIChatCompletions:
            urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropicMessages:
            urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiGenerateContent:
            urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// 打印实际发出的 HTTP 请求，包含完整 URL、Header、Body 以及可直接运行的 curl 命令。
    private static func logRequest(
        _ request: URLRequest,
        configuration: AIAPIConfiguration
    ) {
        let headers = request.allHTTPHeaderFields ?? [:]
        let headerLines = headers.keys.sorted().map { name in
            "\(name): \(headers[name] ?? "")"
        }.joined(separator: "\n")
        let rawURL = request.url?.absoluteString ?? ""
        let body = formattedJSON(request.httpBody)
        let curlCmd = makeCurlCommand(request)

        print(
            """
            [LocalAI API] ——— HTTP request begin ———
            provider: \(configuration.provider.displayName)
            model: \(configuration.model)
            method: \(request.httpMethod ?? "POST")
            url: \(rawURL)
            timeout: \(String(format: "%.1f", request.timeoutInterval))s
            body bytes: \(request.httpBody?.count ?? 0)
            headers:
            \(headerLines)
            body:
            \(body)
            curl:
            \(curlCmd)
            [LocalAI API] ——— HTTP request end ———
            """
        )
    }

    /// 根据 `URLRequest` 生成可直接在终端中复制运行的 curl 命令字符串。
    /// - Parameter request: 发出的 HTTP 请求
    /// - Returns: 格式化后的 curl 命令行文本
    private static func makeCurlCommand(_ request: URLRequest) -> String {
        guard let url = request.url?.absoluteString,
              let method = request.httpMethod else {
            return ""
        }

        var components = ["curl -X \(method) \(shellQuote(url))"]

        if let headers = request.allHTTPHeaderFields {
            for key in headers.keys.sorted() {
                if let value = headers[key] {
                    components.append("-H \(shellQuote("\(key): \(value)"))")
                }
            }
        }

        if let bodyData = request.httpBody,
           let bodyString = String(data: bodyData, encoding: .utf8),
           !bodyString.isEmpty {
            components.append("-d \(shellQuote(bodyString))")
        }

        return components.joined(separator: " \\\n  ")
    }

    /// 对字符串进行单引号包裹和转义，确保在 shell 中可安全直接执行。
    /// - Parameter string: 原始文本
    /// - Returns: 单引号包裹并转义后的文本
    private static func shellQuote(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// 打印供应商 HTTP 响应，便于结合请求定位协议与解析问题。
    private static func logResponse(
        _ response: URLResponse,
        data: Data,
        duration: TimeInterval,
        configuration: AIAPIConfiguration
    ) {
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        print(
            """
            [LocalAI API] ——— HTTP response begin ———
            provider: \(configuration.provider.displayName)
            status: \(statusCode.map(String.init) ?? "non-HTTP")
            duration: \(String(format: "%.0f", duration * 1_000))ms
            body:
            \(formattedJSON(data))
            [LocalAI API] ——— HTTP response end ———
            """
        )
    }

    /// 网络层未产生响应时也记录失败原因。
    private static func logRequestFailure(
        _ error: Error,
        configuration: AIAPIConfiguration
    ) {
        print(
            """
            [LocalAI API] HTTP request failed
            provider: \(configuration.provider.displayName)
            error: \(error.localizedDescription)
            """
        )
    }

    /// 打印 DNS、TCP/TLS、上传、首字节等阶段耗时，用于定位请求慢在本地还是供应商。
    private static func logNetworkMetrics(
        _ snapshot: AIAPIRequestMetricsSnapshot?,
        startedAt: Date
    ) {
        let elapsed = Date().timeIntervalSince(startedAt) * 1_000
        guard let snapshot else {
            print(
                "[LocalAI API] HTTP metrics unavailable; elapsed: "
                    + String(format: "%.0fms", elapsed)
            )
            return
        }

        let transactions = snapshot.transactions.enumerated().map { index, item in
            """
            transaction \(index + 1): protocol=\(item.networkProtocol) reused=\(item.reusedConnection) proxy=\(item.proxyConnection)
              dns: \(formatMilliseconds(item.dnsMilliseconds))
              connect: \(formatMilliseconds(item.connectMilliseconds))
              tls: \(formatMilliseconds(item.tlsMilliseconds))
              upload: \(formatMilliseconds(item.uploadMilliseconds))
              ttfb: \(formatMilliseconds(item.timeToFirstByteMilliseconds))
              download: \(formatMilliseconds(item.downloadMilliseconds))
            """
        }.joined(separator: "\n")

        print(
            """
            [LocalAI API] ——— HTTP metrics begin ———
            elapsed: \(String(format: "%.0f", elapsed))ms
            task: \(String(format: "%.0f", snapshot.taskMilliseconds))ms
            redirects: \(snapshot.redirectCount)
            \(transactions.isEmpty ? "transactions: unavailable" : transactions)
            [LocalAI API] ——— HTTP metrics end ———
            """
        )
    }

    /// 缺失的阶段表示请求在进入该阶段前已失败或超时。
    private static func formatMilliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0fms", $0) } ?? "n/a"
    }

    /// 将 JSON 负载格式化为可读文本，非 JSON 数据回退为 UTF-8 原文。
    private static func formattedJSON(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "<empty>" }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(
               withJSONObject: object,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let text = String(data: formatted, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
    }

    /// 从三类供应商响应中提取纯文本正文。
    private static func extractText(
        json: [String: Any]?,
        provider: AIAPIProviderID,
        statusCode: Int
    ) throws -> String {
        let text: String?
        switch provider.protocolStyle {
        case .openAIChatCompletions:
            let choices = json?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            text = message?["content"] as? String
        case .anthropicMessages:
            let content = json?["content"] as? [[String: Any]]
            text = content?
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        case .geminiGenerateContent:
            let candidates = json?["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            text = parts?
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw LocalAIError.apiRequestFailed(
                provider: provider,
                statusCode: statusCode,
                message: L10n.t("The API returned an empty or unsupported response.")
            )
        }
        return trimmed
    }

    /// 尽量保留供应商返回的错误详情，同时限制非 JSON 响应长度。
    private static func extractErrorMessage(json: [String: Any]?, data: Data) -> String {
        if let error = json?["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = json?["message"] as? String { return message }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return L10n.t("Unknown API error") }
        return String(raw.prefix(800))
    }

    /// 在保留供应商根路径的前提下追加 REST 资源。
    private static func appendPath(_ path: String, to baseURL: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/"
            + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 本机兼容服务可使用 HTTP，其余地址必须使用 HTTPS，避免 API Key 明文传输。
    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// 将 `Duration` 转成 URLSession 可用的秒数，并保证最少一秒。
    private static func timeoutSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return max(1, seconds)
    }
}

/// URLSession 网络阶段耗时的可并发传递快照。
private struct AIAPIRequestMetricsSnapshot: Sendable {
    let taskMilliseconds: Double
    let redirectCount: Int
    let transactions: [AIAPITransactionMetricsSnapshot]
}

/// 单次 HTTP 交易的 DNS、连接、TLS 与数据传输耗时。
private struct AIAPITransactionMetricsSnapshot: Sendable {
    let networkProtocol: String
    let reusedConnection: Bool
    let proxyConnection: Bool
    let dnsMilliseconds: Double?
    let connectMilliseconds: Double?
    let tlsMilliseconds: Double?
    let uploadMilliseconds: Double?
    let timeToFirstByteMilliseconds: Double?
    let downloadMilliseconds: Double?
}

/// 只收集当次 data task 的网络指标，不改变 URLSession 请求行为。
private final class AIAPIRequestMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: AIAPIRequestMetricsSnapshot?

    /// URLSession 回调与 async 请求处于不同线程，通过锁读取不可变快照。
    var snapshot: AIAPIRequestMetricsSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let transactions = metrics.transactionMetrics.map { item in
            AIAPITransactionMetricsSnapshot(
                networkProtocol: item.networkProtocolName ?? "unknown",
                reusedConnection: item.isReusedConnection,
                proxyConnection: item.isProxyConnection,
                dnsMilliseconds: Self.milliseconds(
                    from: item.domainLookupStartDate,
                    to: item.domainLookupEndDate
                ),
                connectMilliseconds: Self.milliseconds(
                    from: item.connectStartDate,
                    to: item.connectEndDate
                ),
                tlsMilliseconds: Self.milliseconds(
                    from: item.secureConnectionStartDate,
                    to: item.secureConnectionEndDate
                ),
                uploadMilliseconds: Self.milliseconds(
                    from: item.requestStartDate,
                    to: item.requestEndDate
                ),
                timeToFirstByteMilliseconds: Self.milliseconds(
                    from: item.requestEndDate,
                    to: item.responseStartDate
                ),
                downloadMilliseconds: Self.milliseconds(
                    from: item.responseStartDate,
                    to: item.responseEndDate
                )
            )
        }
        let snapshot = AIAPIRequestMetricsSnapshot(
            taskMilliseconds: metrics.taskInterval.duration * 1_000,
            redirectCount: metrics.redirectCount,
            transactions: transactions
        )
        lock.lock()
        storedSnapshot = snapshot
        lock.unlock()
    }

    /// 两个阶段时间点均存在时才输出耗时。
    private static func milliseconds(from start: Date?, to end: Date?) -> Double? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start) * 1_000)
    }
}
