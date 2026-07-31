//
//  LocalAI.types.swift
//  kero
//
//  LocalAI 统一接口的类型定义：Provider 标识、请求/响应、安装状态与错误。
//

import Foundation

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

/// 本地 AI 调用结果。
struct LocalAIResponse: Sendable, Equatable {
    /// 解析后的主要文本输出（优先 last message / stdout 正文）。
    var text: String
    /// 进程退出码。
    var exitCode: Int32
    /// 实际使用的 Provider。
    var provider: LocalAIProviderID
    /// 完整 stdout。
    var rawStdout: String
    /// 完整 stderr。
    var rawStderr: String
    /// 使用的可执行文件路径。
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

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Local AI is disabled. Choose an AI headless provider in Settings → General."
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
