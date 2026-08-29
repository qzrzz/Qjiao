//
//  LocalAIExecutableLocator.swift
//  kero
//
//  在常见安装路径与 PATH 中定位 AI CLI 可执行文件。
//

import Foundation

/// 定位 grok / codex / claude / agy / opencode / pi 等 AI CLI 与通用命令行工具。
nonisolated enum LocalAIExecutableLocator {
    /// 缓存用户登录 Shell 的 PATH，避免每次高频探测重复拉起子进程。
    private final class ShellEnvironmentCache: @unchecked Sendable {
        static let shared = ShellEnvironmentCache()
        private let lock = NSLock()
        private var cachedDirs: [String]?
        private var lastFetchDate: Date?

        func directories(forceRefresh: Bool = false) -> [String] {
            lock.lock()
            if !forceRefresh,
               let cachedDirs,
               let lastFetchDate,
               Date().timeIntervalSince(lastFetchDate) < 60 {
                let hit = cachedDirs
                lock.unlock()
                return hit
            }
            let stale = cachedDirs
            lock.unlock()

            // `zsh -lc` 可能加载 nvm 等很慢；主线程等待会泵 runloop，SwiftUI
            // 布局中嵌套 AttributeGraph 更新会 abort。缓存未命中时主线程只用
            // 已有结果（或空），后台 refresh 再补全。
            if Thread.isMainThread {
                return stale ?? []
            }

            let fresh = Self.fetchLoginShellPathDirectories()

            lock.lock()
            cachedDirs = fresh
            lastFetchDate = Date()
            lock.unlock()

            return fresh
        }

        func invalidate() {
            lock.lock()
            cachedDirs = nil
            lastFetchDate = nil
            lock.unlock()
        }

        private static func fetchLoginShellPathDirectories() -> [String] {
            let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellExec = FileManager.default.isExecutableFile(atPath: userShell) ? userShell : "/bin/zsh"

            let run = SubprocessRunner.run(
                SubprocessRunner.Config(
                    executable: shellExec,
                    arguments: ["-lc", "echo -n \"$PATH\""],
                    timeout: 5
                )
            )
            guard run.launched, !run.timedOut, run.exitCode == 0 else { return [] }
            guard let text = String(data: run.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return [] }

            return text.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
    }

    /// 获取包含系统标准目录、用户全局包管理器目录（npm/pnpm/yarn/bun/nvm/fnm/volta/asdf/mise 等）及用户登录 Shell PATH 的候选目录列表。
    static func searchDirectories(forceRefresh: Bool = false) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs: [String] = []

        // 1. 用户交互/登录 shell 探测到的 PATH 优先（最符合用户终端真实配置）
        let shellDirs = ShellEnvironmentCache.shared.directories(forceRefresh: forceRefresh)
        dirs.append(contentsOf: shellDirs)

        // 2. 当前进程环境 PATH
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for part in envPath.split(separator: ":") {
                let d = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                if !d.isEmpty { dirs.append(d) }
            }
        }

        // 3. 用户主目录下常见 CLI 与包管理器路径
        let userDirs = [
            "\(home)/.local/bin",
            "\(home)/.bin",
            "\(home)/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.deno/bin",
            // pnpm 全局 bin（macOS 默认在 ~/Library/pnpm，也可在 ~/.local/share/pnpm 或 ~/.pnpm-global/bin）
            "\(home)/Library/pnpm",
            "\(home)/.local/share/pnpm",
            "\(home)/.pnpm-global/bin",
            // npm 全局 bin
            "\(home)/.npm-global/bin",
            "\(home)/.npm/bin",
            "\(home)/.node/bin",
            // yarn 全局 bin
            "\(home)/.yarn/bin",
            "\(home)/.config/yarn/global/node_modules/.bin",
            // volta
            "\(home)/.volta/bin",
            // fnm
            "\(home)/.local/share/fnm/current/bin",
            "\(home)/.fnm/current/bin",
            // nvm current
            "\(home)/.nvm/current/bin",
            // asdf / mise (rtx)
            "\(home)/.asdf/shims",
            "\(home)/.asdf/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.local/share/mise/bin",
            "\(home)/.mise/shims",
            // 各 AI CLI 独立安装目录（pi、grok、claude、codex、antigravity、opencode 等）
            "\(home)/.local/share/pi-node/current/bin",
            "\(home)/.pi/bin",
            "\(home)/.pi-agent/bin",
            "\(home)/.local/share/pi/bin",
            "\(home)/.pi/current/bin",
            "\(home)/.pi/agent/bin",
            "\(home)/.grok/bin",
            "\(home)/.opencode/bin",
            "\(home)/.claude/bin",
            "\(home)/.codex/bin",
            "\(home)/.gemini/antigravity/bin",
            "\(home)/.gemini/antigravity-cli/bin",
            "\(home)/.antigravity/bin",
            "\(home)/.antigravity-ide/antigravity-ide/bin",
            "\(home)/.vite-plus/bin",
            "\(home)/.vite-plus/current/bin",
            "\(home)/.nub/bin",
            "\(home)/.moon/bin",
            "\(home)/.orbstack/bin",
            "\(home)/Library/Application Support/JetBrains/Toolbox/scripts",
            "\(home)/.nix-profile/bin",
        ]
        dirs.append(contentsOf: userDirs)

        // 4. 动态探测版本管理器的多版本目录（nvm / fnm / mise / asdf）
        // nvm: ~/.nvm/versions/node/*/bin
        let nvmNodeDir = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmNodeDir) {
            for ver in versions.sorted().reversed() {
                dirs.append("\(nvmNodeDir)/\(ver)/bin")
            }
        }
        // fnm: ~/.local/share/fnm/node-versions/*/installation/bin
        let fnmNodeDir = "\(home)/.local/share/fnm/node-versions"
        if let versions = try? fm.contentsOfDirectory(atPath: fnmNodeDir) {
            for ver in versions.sorted().reversed() {
                dirs.append("\(fnmNodeDir)/\(ver)/installation/bin")
            }
        }
        // mise: ~/.local/share/mise/installs/node/*/bin
        let miseNodeDir = "\(home)/.local/share/mise/installs/node"
        if let versions = try? fm.contentsOfDirectory(atPath: miseNodeDir) {
            for ver in versions.sorted().reversed() {
                dirs.append("\(miseNodeDir)/\(ver)/bin")
            }
        }

        // 5. 系统标准目录与 Homebrew / MacPorts / Nix
        let systemDirs = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/local/bin",
            "/opt/local/sbin",
            "/nix/var/nix/profiles/default/bin",
            "/Library/Apple/usr/bin",
            "/usr/local/go/bin",
        ]
        dirs.append(contentsOf: systemDirs)

        // 去重并保持优先级
        var seen = Set<String>()
        var uniqueDirs: [String] = []
        for d in dirs {
            let standard = (d as NSString).standardizingPath
            guard !standard.isEmpty, !seen.contains(standard) else { continue }
            seen.insert(standard)
            uniqueDirs.append(standard)
        }
        return uniqueDirs
    }

    /// 构造用于子进程运行的完整 PATH 字符串。
    static func augmentedPATH(_ existing: String? = nil) -> String {
        let dirs = searchDirectories()
        var seen = Set<String>()
        var result: [String] = []

        for d in dirs {
            guard !seen.contains(d) else { continue }
            seen.insert(d)
            result.append(d)
        }
        if let existing = existing {
            for part in existing.split(separator: ":") {
                let d = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !d.isEmpty, !seen.contains(d) else { continue }
                seen.insert(d)
                result.append(d)
            }
        }
        return result.joined(separator: ":")
    }

    /// 查找 CLI 可执行文件的绝对路径；找不到返回 nil。
    ///
    /// - Parameter allowSubprocessFallbacks: 目录扫描失败后是否再跑 `which` /
    ///   登录 shell `command -v`。批量探测应关，避免每个未安装命令都拉起子进程。
    ///   主线程上始终跳过子进程回退。
    static func findExecutable(
        name: String,
        forceRefresh: Bool = false,
        allowSubprocessFallbacks: Bool = true
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fm = FileManager.default
        // 1. 已是绝对路径或包含 ~ 的路径
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        // 2. 遍历各搜索目录
        let dirs = searchDirectories(forceRefresh: forceRefresh)
        for dir in dirs {
            let candidate = "\(dir)/\(trimmed)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        guard allowSubprocessFallbacks, !Thread.isMainThread else { return nil }

        // 3. 回退：通过 /usr/bin/which 在增强 PATH 环境中查找
        if let whichPath = resolveViaWhich(trimmed, dirs: dirs) {
            return whichPath
        }

        // 4. 终极回退：在登录 shell 中执行 command -v
        if let shellPath = resolveViaShell(trimmed) {
            return shellPath
        }

        return nil
    }

    /// 查找 CLI 绝对路径（兼容原 API）；找不到返回 nil。
    static func path(for command: String) -> String? {
        findExecutable(name: command)
    }

    /// 按 Provider 查找；disabled 返回 nil。
    static func path(for provider: LocalAIProviderID) -> String? {
        guard let cmd = provider.cliCommand else { return nil }
        return findExecutable(name: cmd)
    }

    /// 探测所有 AI Provider 的安装状态（不含 disabled）。
    static func probeAll(forceRefresh: Bool = false) -> [LocalAIProviderStatus] {
        var result: [LocalAIProviderStatus] = [
            LocalAIProviderStatus(provider: .disabled, executablePath: nil, version: nil),
        ]
        for id in LocalAIProviderID.allCases where id.isAIProvider {
            let path = findExecutable(name: id.cliCommand ?? id.rawValue, forceRefresh: forceRefresh)
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

    /// 清空 shell 缓存以强制重新扫描。
    static func invalidateCache() {
        ShellEnvironmentCache.shared.invalidate()
    }

    // MARK: - Private

    private static func resolveViaWhich(_ name: String, dirs: [String]) -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dirs.joined(separator: ":")

        let run = SubprocessRunner.run(
            SubprocessRunner.Config(
                executable: "/usr/bin/which",
                arguments: [name],
                environment: env,
                timeout: 5
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

    private static func resolveViaShell(_ name: String) -> String? {
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellExec = FileManager.default.isExecutableFile(atPath: userShell) ? userShell : "/bin/zsh"

        let run = SubprocessRunner.run(
            SubprocessRunner.Config(
                executable: shellExec,
                arguments: ["-lc", "command -v \(AIToolRegistry.shellQuote(name))"],
                timeout: 5
            )
        )
        guard run.launched, !run.timedOut, run.exitCode == 0 else { return nil }
        guard let text = String(data: run.stdout, encoding: .utf8) else { return nil }

        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { continue }
            return path
        }
        return nil
    }
}
