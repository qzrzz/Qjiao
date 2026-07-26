//
//  TerminalPasteboard.swift
//  libghostty-spm
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    /// 将 macOS 剪贴板内容转换为适合终端输入的文本，并识别纯图片内容。
    enum TerminalPasteboard {
        /// Finder 复制的文件优先转换为经过 shell 转义的绝对路径。
        static func terminalText(from pasteboard: NSPasteboard) -> String? {
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty {
                return urls.map(escapedShellPath).joined(separator: " ")
            }
            return pasteboard.string(forType: .string)
        }

        /// 纯图片剪贴板需要转发原始 Ctrl-V，让终端内应用自行读取原生数据。
        static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
            pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        }

        private static func escapedShellPath(_ url: URL) -> String {
            let path = url.path
            let unquotedCharacters = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/"
            )
            if !path.isEmpty,
               path.unicodeScalars.allSatisfy(unquotedCharacters.contains) {
                return path
            }
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
#endif
