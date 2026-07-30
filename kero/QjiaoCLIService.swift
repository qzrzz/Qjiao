//
//  QjiaoCLIService.swift
//  kero
//

import Foundation
import AppKit
import GhosttyTheme

/// 处理 `qjiao` 命令行入口请求。
@MainActor
final class QjiaoCLIService {
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
