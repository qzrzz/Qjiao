//
//  SidebarTypography.swift
//  kero
//

import AppKit
import SwiftUI

/// 应用 chrome 统一字号体系。
///
/// 右侧边栏（Start / Files / CWD / Git / Info）与顶栏 Tabs 共用同一套 token，
/// 避免半点字号散落、列表主文字大小不一致。新增 UI 时应优先用这里的角色，
/// 而不是裸写 pt。
///
/// 可读性底线：列表主文字不低于 13，正文字号不低于 11，图标符号不低于 10；
/// 密排列表行高见 `rowMinHeight`。
enum SidebarTypography {
    /// 面板主标题（如 PanelHeader、Start 标题）。
    static let titleSize: CGFloat = 14
    /// 列表 / Tab 主文字（文件名、脚本名、进程名、命令名、标签标题）。
    /// 是可读性的主杠杆。
    static let bodySize: CGFloat = 13
    /// 次要正文（Tab 旁工具图标、表单、空状态说明、路径等）。
    static let secondarySize: CGFloat = 12.5
    /// 副标题与元信息（路径副行、按钮、目录片段）。
    static let captionSize: CGFloat = 12
    /// 分组标题与更密的辅助信息。
    static let sectionSize: CGFloat = 11
    /// 微标、小图标与紧凑标签。
    static let microSize: CGFloat = 10.5
    /// 更小的操作芯片 / 折叠旁的紧凑符号。
    static let compactSize: CGFloat = 10
    /// 分组折叠 chevron。
    static let chevronSize: CGFloat = 10
    /// 整页空状态大图标。
    static let emptyIconSize: CGFloat = 28
    /// 列表内空状态图标。
    static let emptyInlineIconSize: CGFloat = 20
    /// 密排列表/分组行的最小内容高度，避免放大字号后被裁切。
    static let rowMinHeight: CGFloat = 22

    /// AppKit 测宽用：与 `body()` 同字号的系统字体。
    static var bodyNSFont: NSFont {
        .systemFont(ofSize: bodySize, weight: .regular)
    }

    /// 面板主标题，默认 semibold。
    static func title(
        _ weight: Font.Weight = .semibold,
        design: Font.Design = .default
    ) -> Font {
        .system(size: titleSize, weight: weight, design: design)
    }

    /// 列表主行文字，默认 regular。
    static func body(
        _ weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: bodySize, weight: weight, design: design)
    }

    /// 次要正文，默认 regular。
    static func secondary(
        _ weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: secondarySize, weight: weight, design: design)
    }

    /// 副标题 / 元信息，默认 regular。
    static func caption(
        _ weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: captionSize, weight: weight, design: design)
    }

    /// 分组标题与密排辅助信息，默认 regular（分组标题传 `.semibold`）。
    static func section(
        _ weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: sectionSize, weight: weight, design: design)
    }

    /// 微标与小图标，默认 medium。
    static func micro(
        _ weight: Font.Weight = .medium,
        design: Font.Design = .default
    ) -> Font {
        .system(size: microSize, weight: weight, design: design)
    }

    /// 紧凑符号（如 xmark、continue 芯片），默认 semibold。
    static func compact(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: compactSize, weight: weight)
    }

    /// 分组折叠箭头，默认 semibold。
    static func chevron(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: chevronSize, weight: weight)
    }

    /// 整页空状态图标，默认 light。
    static func emptyIcon(_ weight: Font.Weight = .light) -> Font {
        .system(size: emptyIconSize, weight: weight)
    }

    /// 列表内空状态图标，默认 light。
    static func emptyInlineIcon(_ weight: Font.Weight = .light) -> Font {
        .system(size: emptyInlineIconSize, weight: weight)
    }
}
