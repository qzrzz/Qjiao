//
//  LocalAIExecutableLocator.swift
//  kero
//
//  在常见安装路径与 PATH 中定位 AI CLI 可执行文件。
//

import Foundation

/// 定位 grok / codex / claude / agy / opencode / pi 等 AI CLI。
enum LocalAIExecutableLocator {
    /// 常见 PATH 与各 CLI 默认安装目录。
    private static let searchDirectories: [String] = {
        var dirs = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // 各产品默认安装位置
        dirs.append("\(home)/.local/bin")
        dirs.append("\(home)/.bun/bin")
        dirs.append("\(home)/.cargo/bin")
        dirs.append("\(home)/.npm-global/bin")
        // pi：npm 全局安装（npm i -g @earendil-works/pi-coding-agent）或 curl 安装脚本
        // （pi.dev/install.sh 同样落入 npm prefix bin；无系统 node 时自带独立 node 于 ~/.local/share/pi-node）
        dirs.append("\(home)/.local/share/pi-node/current/bin")
        dirs.append("\(home)/.nvm/current/bin")
        dirs.append("\(home)/.grok/bin")
        dirs.append("\(home)/.opencode/bin")
        dirs.append("\(home)/.claude/bin")
        dirs.append("\(home)/.gemini/antigravity/bin")
        dirs.append("\(home)/.antigravity/bin")
        dirs.append("\(home)/.codex/bin")

        // 进程环境 PATH（沙盒 App 可能较空，仍尽量合并）
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for part in envPath.split(separator: ":") {
                let d = String(part)
                if !d.isEmpty, !dirs.contains(d) {
                    dirs.append(d)
                }
            }
        }
        return dirs
    }()

    /// 查找 CLI 绝对路径；找不到返回 nil。
    static func path(for command: String) -> String? {
        let fm = FileManager.default
        // 已是绝对路径
        if command.hasPrefix("/"), fm.isExecutableFile(atPath: command) {
            return command
        }
        for dir in searchDirectories {
            let candidate = "\(dir)/\(command)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // 回退：/usr/bin/which（继承登录 shell 较完整的 PATH 较难，这里用当前 env）
        return resolveViaWhich(command)
    }

    /// 按 Provider 查找；disabled 返回 nil。
    static func path(for provider: LocalAIProviderID) -> String? {
        guard let cmd = provider.cliCommand else { return nil }
        return path(for: cmd)
    }

    /// 探测所有 AI Provider 的安装状态（不含 disabled）。
    static func probeAll() -> [LocalAIProviderStatus] {
        var result: [LocalAIProviderStatus] = [
            LocalAIProviderStatus(provider: .disabled, executablePath: nil, version: nil),
        ]
        for id in LocalAIProviderID.allCases where id.isAIProvider {
            let path = path(for: id)
            result.append(
                LocalAIProviderStatus(
                    provider: id,
                    executablePath: path,
                    version: nil
                )
            )
        }
        return result
    }

    // MARK: - Private

    private static func resolveViaWhich(_ name: String) -> String? {
        var env = ProcessInfo.processInfo.environment
        // which 需要合理 PATH
        let pathValue = searchDirectories.joined(separator: ":")
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = pathValue + ":" + existing
        } else {
            env["PATH"] = pathValue
        }

        let run = SubprocessRunner.run(
            SubprocessRunner.Config(
                executable: "/usr/bin/which",
                arguments: [name],
                environment: env,
                timeout: 10
            )
        )
        guard run.launched, !run.timedOut, run.exitCode == 0 else { return nil }
        let text = String(data: run.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, FileManager.default.isExecutableFile(atPath: text) else {
            return nil
        }
        return text
    }
}
