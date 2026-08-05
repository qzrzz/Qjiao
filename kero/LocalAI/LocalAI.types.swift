//
//  LocalAI.types.swift
//  kero
//
//  LocalAI 统一接口的类型定义：Provider 标识、请求/响应、安装状态与错误。
//

import Foundation

// MARK: - AI 后端

/// 应用内 AI 功能使用的执行后端。
enum AIBackend: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case cli
    case api

    var id: String { rawValue }

    /// 设置面板展示名。
    var displayName: String {
        switch self {
        case .cli: return L10n.t("Local CLI")
        case .api: return L10n.t("AI API")
        }
    }
}

/// 云端 AI API 推理强度 / 思考级别 (Reasoning Effort)。
enum AIReasoningEffort: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case low
    case medium
    case high
    case disabled

    var id: String { rawValue }

    /// 设置面板展示名。
    var displayName: String {
        switch self {
        case .low: return L10n.t("Low")
        case .medium: return L10n.t("Medium")
        case .high: return L10n.t("High")
        case .disabled: return L10n.t("Disabled")
        }
    }
}

/// 云端 AI API 供应商。
enum AIAPIProviderID: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case anthropic
    case gemini
    case openRouter = "openrouter"
    case xAI = "xai"
    case custom

    var id: String { rawValue }

    /// 设置与任务状态中展示的品牌名。
    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .xAI: return "xAI"
        case .custom: return L10n.t("OpenAI-compatible")
        }
    }

    /// 新选择供应商时使用的可编辑模型建议值。
    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5.6-luna"
        case .deepSeek: return "deepseek-v4-flash"
        case .anthropic: return "claude-sonnet-5"
        case .gemini: return "gemini-3.6-flash"
        case .openRouter: return "openai/gpt-5.6"
        case .xAI: return "grok-4.5"
        case .custom: return ""
        }
    }

    /// 默认 API 根地址；用户仍可在设置中覆盖。
    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .custom: return ""
        }
    }

    /// 供应商使用的 REST 请求协议。
    var protocolStyle: AIAPIProtocolStyle {
        switch self {
        case .anthropic: return .anthropicMessages
        case .gemini: return .geminiGenerateContent
        default: return .openAIChatCompletions
        }
    }
}

/// AI API 的请求协议类型。
enum AIAPIProtocolStyle: Sendable {
    case openAIChatCompletions
    case anthropicMessages
    case geminiGenerateContent
}

/// 一次 AI 调用实际使用的供应商身份。
enum AIProviderIdentity: Sendable, Equatable {
    case cli(LocalAIProviderID)
    case api(AIAPIProviderID)

    /// 日志与任务状态使用的统一展示名。
    var displayName: String {
        switch self {
        case .cli(let provider): return provider.displayName
        case .api(let provider): return provider.displayName
        }
    }
}

// MARK: - 写作语言

/// AI 生成 Git Commit / 描述等内容时使用的自然语言。
///
/// 与界面语言 `AppLanguage` 独立：界面可中文、写作仍用英文，或反之。
/// 全局默认见 `AppSettings.aiWritingLanguage`；项目可在 `Project.aiWritingLanguage` 覆盖。
enum AIWritingLanguage: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case russian = "ru"
    case italian = "it"
    case dutch = "nl"
    case polish = "pl"
    case turkish = "tr"
    case vietnamese = "vi"
    case arabic = "ar"
    case hindi = "hi"

    var id: String { rawValue }

    /// 设置面板与项目覆盖选择器展示名（语言自身名称）。
    var nativeDisplayName: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .italian: return "Italiano"
        case .dutch: return "Nederlands"
        case .polish: return "Polski"
        case .turkish: return "Türkçe"
        case .vietnamese: return "Tiếng Việt"
        case .arabic: return "العربية"
        case .hindi: return "हिन्दी"
        }
    }

    /// 注入提示词的语言标签（给模型读）。
    var promptLabel: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "Simplified Chinese (简体中文)"
        case .chineseTraditional: return "Traditional Chinese (繁體中文)"
        case .japanese: return "Japanese (日本語)"
        case .korean: return "Korean (한국어)"
        case .french: return "French (Français)"
        case .german: return "German (Deutsch)"
        case .spanish: return "Spanish (Español)"
        case .portuguese: return "Portuguese (Português)"
        case .russian: return "Russian (Русский)"
        case .italian: return "Italian (Italiano)"
        case .dutch: return "Dutch (Nederlands)"
        case .polish: return "Polish (Polski)"
        case .turkish: return "Turkish (Türkçe)"
        case .vietnamese: return "Vietnamese (Tiếng Việt)"
        case .arabic: return "Arabic (العربية)"
        case .hindi: return "Hindi (हिन्दी)"
        }
    }
}

// MARK: - Provider

/// 本地 AI headless 提供器标识。
///
/// 通过对应 CLI 的非交互模式执行单轮提示：
/// - `grok`：`grok --single` / headless
/// - `codex`：`codex exec`
/// - `claude`：`claude -p` / `--print`
/// - `agy`：`agy --print` / `-p`
/// - `opencode`：`opencode run`
/// - `pi`：`pi -p` / `--print`
/// - `disabled`：关闭本地 AI 能力
enum LocalAIProviderID: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case disabled
    case grok
    case codex
    case claude
    case agy
    case opencode
    case pi

    var id: String { rawValue }

    /// Codex 默认模型（`codex exec -m`）；请求未显式指定 model 时使用。
    static let codexDefaultModel = "gpt-5.6-luna"

    /// 设置面板与菜单展示名。
    var displayName: String {
        switch self {
        case .disabled: return L10n.t("Disabled")
        case .grok: return "grok"
        case .codex: return "codex"
        case .claude: return "claude"
        case .agy: return "agy"
        case .opencode: return "opencode"
        case .pi: return "pi"
        }
    }

    /// CLI 可执行文件名（disabled 无 CLI）。
    var cliCommand: String? {
        switch self {
        case .disabled: return nil
        case .grok, .codex, .claude, .agy, .opencode, .pi: return rawValue
        }
    }

    /// 是否为可用的 AI 提供器（非 disabled）。
    var isAIProvider: Bool {
        self != .disabled
    }

    /// 设置行副标题：说明 headless / exec 调用方式。
    var commandHint: String {
        switch self {
        case .disabled: return L10n.t("Local AI features are turned off.")
        case .grok: return "grok --single"
        case .codex: return "codex exec"
        case .claude: return "claude --print"
        case .agy: return "agy --print"
        case .opencode: return "opencode run"
        case .pi: return "pi --print"
        }
    }
}

// MARK: - 安装状态

/// 某个 Provider 在本机的探测结果。
struct LocalAIProviderStatus: Identifiable, Equatable, Sendable {
    /// Provider 标识。
    let provider: LocalAIProviderID
    /// 可执行文件绝对路径；未安装或 disabled 时为 nil。
    let executablePath: String?
    /// 探测到的版本字符串（可选，失败时为 nil）。
    let version: String?

    var id: String { provider.id }

    /// 是否已安装且可选用（disabled 视为“始终可选”）。
    var isAvailable: Bool {
        if provider == .disabled { return true }
        return executablePath != nil
    }

    /// Picker 行文案：未安装时附加 “Not installed”。
    var pickerLabel: String {
        if provider == .disabled {
            return provider.displayName
        }
        if isAvailable {
            return provider.displayName
        }
        return "\(provider.displayName) — \(L10n.t("Not installed"))"
    }
}

// MARK: - 请求 / 响应

/// 一次本地 AI 单轮调用请求。
struct LocalAIRequest: Sendable, Equatable {
    /// 用户提示词（必填）。
    var prompt: String
    /// 工作目录；多数 CLI 以此作为项目根。
    var workingDirectory: String?
    /// 可选模型 ID（各 CLI 语义不同，透传给对应 flag）。
    var model: String?
    /// 超时；默认 10 分钟（agent 任务可能较长）。
    var timeout: Duration
    /// 是否尽量自动批准工具执行（各 CLI 映射到不同危险 flag，默认 false）。
    var autoApprove: Bool
    /// 尽量关闭工具 / 子代理 / 联网检索，只做纯文本生成（Git Commit 等场景）。
    var disableTools: Bool
    /// 覆盖全局设置，强制使用某 Provider；nil 时用当前设置。
    var providerOverride: LocalAIProviderID?

    init(
        prompt: String,
        workingDirectory: String? = nil,
        model: String? = nil,
        timeout: Duration = .seconds(600),
        autoApprove: Bool = false,
        disableTools: Bool = false,
        providerOverride: LocalAIProviderID? = nil
    ) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.model = model
        self.timeout = timeout
        self.autoApprove = autoApprove
        self.disableTools = disableTools
        self.providerOverride = providerOverride
    }
}

/// CLI 或 API AI 调用结果。
struct LocalAIResponse: Sendable, Equatable {
    /// 解析后的主要文本输出（优先 last message / stdout 正文）。
    var text: String
    /// CLI 进程退出码；API 成功时为 0。
    var exitCode: Int32
    /// 实际使用的 Provider。
    var provider: AIProviderIdentity
    /// CLI stdout 或 API 原始 JSON。
    var rawStdout: String
    /// 完整 stderr。
    var rawStderr: String
    /// 使用的 CLI 可执行文件路径或 API 请求地址。
    var executablePath: String

    /// 通常以 exit 0 为成功；部分 CLI 非 0 仍可能写出部分结果。
    var succeeded: Bool { exitCode == 0 }
}

// MARK: - 错误

/// LocalAI 调用失败原因。
enum LocalAIError: Error, LocalizedError, Equatable {
    /// 全局设置为 disabled，或强制覆盖为 disabled。
    case disabled
    /// 选中的 CLI 未安装。
    case notInstalled(LocalAIProviderID)
    /// 提示词为空。
    case emptyPrompt
    /// 启动子进程失败。
    case launchFailed(String)
    /// 超时。
    case timedOut(Duration)
    /// CLI 返回非 0，且无法提取有效文本。
    case commandFailed(provider: LocalAIProviderID, exitCode: Int32, stderr: String)
    /// API 模式缺少 Key、模型或有效地址。
    case invalidAPIConfiguration(String)
    /// API 返回了错误状态或无法解析的响应。
    case apiRequestFailed(provider: AIAPIProviderID, statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return L10n.t("AI is disabled. Configure a provider in Settings → AI.")
        case .notInstalled(let id):
            return "\(id.displayName) is not installed or not found in PATH."
        case .emptyPrompt:
            return "Prompt is empty."
        case .launchFailed(let message):
            return "Failed to launch AI CLI: \(message)"
        case .timedOut(let duration):
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return "AI CLI timed out after \(Int(seconds))s."
        case .commandFailed(let provider, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(provider.displayName) exited with code \(exitCode)."
            }
            return "\(provider.displayName) exited with code \(exitCode): \(detail)"
        case .invalidAPIConfiguration(let message):
            return message
        case .apiRequestFailed(let provider, let statusCode, let message):
            return L10n.format(
                "%@ API request failed (%lld): %@",
                provider.displayName,
                Int64(statusCode),
                message
            )
        }
    }
}

// MARK: - 内部命令描述

/// 进程启动描述（由各 Provider 构建）。
struct LocalAICommand: Sendable, Equatable {
    /// 可执行文件绝对路径。
    var executable: String
    /// argv（不含 executable）。
    var arguments: [String]
    /// 工作目录。
    var workingDirectory: String?
    /// 额外环境变量。
    var environment: [String: String]
    /// 写入 stdin 的文本（部分 CLI 从 stdin 读 prompt）。
    var stdinText: String?

    init(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        stdinText: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdinText = stdinText
    }
}

/// 底层进程执行结果。
struct LocalAIProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}
