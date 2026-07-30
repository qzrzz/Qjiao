//
//  FinderService.swift
//  kero
//

import AppKit

/// 提供 Qjiao 的 Finder 扩展服务。关联菜单项配置于 Info.plist，
/// AppKit 会将匹配的服务请求转发到此对象。
@MainActor
final class QjiaoApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    /// 打开 Finder 拖投到服务剪贴板上的每一个文件夹，在 Qjiao 中作为项目打开。
    @objc func openInQjiao(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let directories = Self.directories(from: pasteboard)
        guard !directories.isEmpty else {
            error.pointee = L10n.t("Select one or more folders to open in Qjiao.") as NSString
            return
        }

        NSApp.activate()
        TerminalManager.openDirectories(directories)
    }

    private static func directories(from pasteboard: NSPasteboard) -> [String] {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        var candidates = pasteboard.propertyList(forType: filenamesType) as? [String] ?? []

        if candidates.isEmpty,
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL] {
            candidates = urls.map(\.path)
        }

        var isDir: ObjCBool = false
        return candidates.filter { path in
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
