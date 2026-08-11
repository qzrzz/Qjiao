//
//  QjiaoCLIService.swift
//  kero
//

import Foundation
import AppKit
import Darwin
import GhosttyTheme

/// 处理 `qjiao` 命令行入口请求。
@MainActor
final class QjiaoCLIService {
    static let shared = QjiaoCLIService()

    private let automationSocketPath: String
    private var automationServer: QjiaoAutomationSocketServer?
    private var terminalCapabilities: [String: UUID] = [:]
    private var terminationObserver: NSObjectProtocol?

    private init() {
        let nonce = UUID().uuidString.prefix(8)
        automationSocketPath = "/tmp/qjiao-\(getuid())-\(ProcessInfo.processInfo.processIdentifier)-\(nonce).sock"
        do {
            automationServer = try QjiaoAutomationSocketServer(
                path: automationSocketPath
            ) { request, reply in
                Task { @MainActor in
                    reply(await QjiaoCLIService.shared.handleAutomation(request))
                }
            }
        } catch {
            NSLog("qjiao: failed to start automation socket: %@", error.localizedDescription)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.automationServer = nil
                self?.terminalCapabilities = [:]
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// 为每个终端签发独立 capability。环境变量只进入 Qjiao 自己创建的
    /// Shell，不修改用户 dotfiles，也不写入已签名的 App Bundle。
    func terminalEnvironment(for sessionID: UUID) -> [String: String] {
        let capability = UUID().uuidString + UUID().uuidString
        terminalCapabilities[capability] = sessionID
        var environment = [
            "QJIAO_AUTOMATION": "1",
            "QJIAO_AUTOMATION_HELP": "qjiao +agent explain",
            "QJIAO_AUTOMATION_SOCKET": automationSocketPath,
            "QJIAO_AUTOMATION_TOKEN": capability,
            "QJIAO_TERMINAL_ID": sessionID.uuidString,
        ]
        if let executableURL = Bundle.main.executableURL {
            let bin = executableURL.deletingLastPathComponent().path
            let inherited = ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = "\(bin):\(inherited)"
        }
        return environment
    }

    func revokeTerminal(id: UUID) {
        terminalCapabilities = terminalCapabilities.filter { $0.value != id }
    }

    private func handleAutomation(
        _ request: QjiaoAutomationRequest
    ) async -> QjiaoAutomationResponse {
        guard request.version == 1 else {
            return .failure(
                id: request.id,
                code: "unsupported_version",
                message: "Qjiao supports automation protocol version 1."
            )
        }
        guard let terminalID = UUID(uuidString: request.terminalID),
              terminalCapabilities[request.token] == terminalID else {
            return .failure(
                id: request.id,
                code: "unauthorized",
                message: "The terminal automation capability is invalid or expired."
            )
        }
        return await QjiaoAutomationRouter.route(
            request,
            callerTerminalID: terminalID
        )
    }

    static func handleCommandLine(arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let args = Array(arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        if args.first == "+themes" {
            handleThemesCommand(args: Array(args.dropFirst()))
            exit(0)
        }

        if args.first == "+pane" || args.first == "+agent" {
            do {
                try QjiaoAutomationCommandLine.run(
                    namespace: args[0],
                    arguments: Array(args.dropFirst())
                )
                exit(0)
            } catch {
                fputs("qjiao: \(error)\n", stderr)
                exit(1)
            }
        }

        // 处理文件或文件夹路径
        if let targetPath = args.first, !targetPath.hasPrefix("-") {
            openPath(targetPath)
            exit(0)
        }

        return false
    }

    private static func printUsage() {
        print("""
        Qjiao CLI — Terminal workspace for macOS

        Usage:
          qjiao [path]            Open folder or file in Qjiao
          qjiao +themes           Browse and preview themes
          qjiao +themes --list    List all available themes
          qjiao --help            Show this help message
        """)
    }

    private static func handleThemesCommand(args: [String]) {
        let themes = GhosttyThemeCatalog.allThemes.map(\.name)
        if args.contains("--list") {
            for name in themes {
                print(name)
            }
            return
        }

        print(L10n.t("Available themes:"))
        for (idx, name) in themes.prefix(30).enumerated() {
            print("  [\(idx + 1)] \(name)")
        }
        print("\n\(L10n.t("Use Settings -> Appearance to select themes."))")
    }

    private static func openPath(_ rawPath: String) {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                TerminalManager.openDirectories([url.path])
            } else {
                let parentDir = url.deletingLastPathComponent().path
                TerminalManager.openDirectories([parentDir])
            }
        } else {
            fputs("qjiao: path does not exist: \(rawPath)\n", stderr)
        }
    }
}
