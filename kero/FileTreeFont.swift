//
//  FileTreeFont.swift
//  kero
//
//  右侧 Files / CWD 文件树的字体解析：读取 AppSettings 的 files 字体配置，
//  并提供与主字号联动的 caption / 行高 / 图标尺寸。
//  默认使用内置 Inter Variable（kero/Fonts/InterVariable.ttf）。
//

import AppKit
import SwiftUI

/// Files 树专用字体工具；与终端 `TerminalFont` 独立。
enum FileTreeFont {
    /// 内置默认字体族显示名（nameID 1 / Family）。
    static let bundledFamily = "Inter Variable"
    /// PostScript / 完整字体名，供 `NSFont(name:)` 与 SwiftUI `.custom` 解析。
    static let bundledFontName = "InterVariable"

    /// 设置页可选的字体族：内置 Inter 置顶，其余为系统已安装族。
    static func selectableFamilies() -> [String] {
        let installed = NSFontManager.shared.availableFontFamilies
            .filter { family in
                !family.hasPrefix(".")
                    && !family.hasPrefix("Symbols Nerd Font")
                    && family != TerminalFont.bundledChineseFamily
                    // 内置默认单独占第一项，避免列表里再出现同名系统 Inter。
                    && family != bundledFamily
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [bundledFamily] + installed
    }

    /// 按 family + size 解析 SwiftUI Font。
    /// 空字符串或内置族名 → 使用 process 内注册的 Inter Variable。
    static func resolve(family: String, size: CGFloat) -> Font {
        if family.isEmpty || family == bundledFamily {
            // 优先 PostScript 名；部分系统只认 family 名时再回退。
            if NSFont(name: bundledFontName, size: size) != nil {
                return .custom(bundledFontName, size: size)
            }
            if NSFont(name: bundledFamily, size: size) != nil {
                return .custom(bundledFamily, size: size)
            }
            // 注册失败时的最终回退，保证树仍可读。
            return .system(size: size)
        }
        return .custom(family, size: size)
    }

    @MainActor
    static var body: Font {
        let settings = AppSettings.shared
        return resolve(family: settings.filesFontFamily, size: CGFloat(settings.filesFontSize))
    }

    /// 文件大小等次要信息，略小于主字号。
    @MainActor
    static var caption: Font {
        let settings = AppSettings.shared
        let size = max(10, CGFloat(settings.filesFontSize) - 1)
        return resolve(family: settings.filesFontFamily, size: size)
    }

    /// 折叠 chevron 等紧凑符号字号。
    @MainActor
    static var compact: Font {
        let settings = AppSettings.shared
        let size = max(9, CGFloat(settings.filesFontSize) - 3)
        return .system(size: size, weight: .semibold)
    }

    /// 密排行最小高度，随字号放大以免裁切。
    @MainActor
    static var rowMinHeight: CGFloat {
        max(SidebarTypography.rowMinHeight, CGFloat(AppSettings.shared.filesFontSize) + 9)
    }

    /// Material 文件图标边长，随字号在 14…20 间缩放。
    @MainActor
    static var iconSize: CGFloat {
        let size = CGFloat(AppSettings.shared.filesFontSize)
        return min(20, max(14, size + 3))
    }
}
