//
//  TerminalFont.swift
//  kero
//

import AppKit
import CoreText

/// Terminal font handling, same approach as Otty: bundle JetBrains Mono
/// with the app so the default looks identical on every machine, and let
/// the OS cascade cover glyphs the primary font lacks (CJK, symbols).
enum TerminalFont {
    static let defaultSize: CGFloat = 13
    static let bundledFamily = "JetBrains Mono"
    static let bundledChineseFamily = "Source Han Sans CN VF Mono1200"
    private static let symbolsFontName = "SymbolsNFM"

    /// Registers the bundled JetBrains Mono faces (Regular/Bold/Italic/
    /// BoldItalic), Inter Variable（Files 树默认）、Source Han Sans CN, and the
    /// Symbols Nerd Font for this process only, so nothing is installed
    /// system-wide. Must run before the first terminal / file-tree view is created.
    static func registerBundledFonts() {
        // Xcode's synchronized groups flatten Fonts/ into Contents/Resources。
        // 会一并注册 InterVariable.ttf / InterVariable-Italic.ttf。
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// The terminal font for the current settings (family + size).
    @MainActor
    static func current() -> NSFont {
        let settings = AppSettings.shared
        return resolve(
            family: settings.fontFamily,
            size: CGFloat(settings.fontSize),
            useBundledChineseFallback: settings.useBundledChineseTerminalFont,
            thicken: settings.fontThicken
        )
    }

    /// Resolves a family name to a terminal-ready font. Empty family means
    /// the bundled default; an unknown family falls back to it too.
    ///
    /// The bundled Chinese font and Symbols Nerd Font are attached as CoreText
    /// cascade entries. They cover CJK text and PUA icon glyphs without a
    /// user-installed patched font. JetBrains Mono covers Powerline separators
    /// itself, so those never hit the fallback.
    ///
    /// - Parameter thicken: 近似 Ghostty `font-thicken`：优先 Medium/Semibold 字面，
    ///   否则合成略重字重（设置页 Preview 与 UI 预览用；真实终端仍走 Ghostty 配置）。
    static func resolve(
        family: String,
        size: CGFloat,
        useBundledChineseFallback: Bool,
        thicken: Bool = false
    ) -> NSFont {
        // AppKit weight：5 = regular，7 ≈ medium/semibold，比直接 bold 更接近 thicken。
        let weight = thicken ? 7 : 5
        let base: NSFont
        if !family.isEmpty, family != bundledFamily,
           let chosen = NSFontManager.shared.font(
               withFamily: family, traits: [], weight: weight, size: size
           ) {
            base = chosen
        } else if thicken, let medium = NSFont(name: "JetBrainsMono-Bold", size: size) {
            // 无独立 Medium 时用 Bold 近似加粗描边（仅 Preview；终端仍用 Ghostty thicken）。
            base = medium
        } else if let bundled = NSFont(name: "JetBrainsMono-Regular", size: size) {
            base = bundled
        } else {
            return .monospacedSystemFont(
                ofSize: size,
                weight: thicken ? .medium : .regular
            )
        }
        var cascade = [NSFontDescriptor]()
        if useBundledChineseFallback {
            cascade.append(NSFontDescriptor(name: bundledChineseFamily, size: size))
        }
        cascade.append(NSFontDescriptor(name: symbolsFontName, size: size))
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        let resolved = NSFont(descriptor: descriptor, size: size) ?? base
        // 族内无更重字面时，对 regular 做一次合成加粗作为 thicken 回退。
        if thicken, !resolved.fontDescriptor.symbolicTraits.contains(.bold) {
            return NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask)
        }
        return resolved
    }

    /// 部分 CJK 终端字体使用双宽表意字符，因此不会设置 CoreText 的严格 fixed-pitch 标记，
    /// 但其 ASCII 字符仍然占用一致的终端单元格。代表性 ASCII 样本在 Advance 宽度一致时予以采纳。
    private static func isTerminalMonospaced(_ font: NSFont) -> Bool {
        if font.isFixedPitch { return true }

        let characters: [UniChar] = Array(" ilMW01@#".utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        guard
            CTFontGetGlyphsForCharacters(
                font as CTFont, characters, &glyphs, characters.count
            ), !glyphs.contains(0)
        else { return false }

        var advances = Array(repeating: CGSize.zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(
            font as CTFont, .horizontal, glyphs, &advances, glyphs.count
        )
        guard let width = advances.first?.width, width > 0 else { return false }
        return advances.dropFirst().allSatisfy { abs($0.width - width) < 0.01 }
    }

    /// Fixed-pitch families available for the font picker, bundled default
    /// first. The symbols-only fallback font is not a usable primary font.
    static func selectableFamilies() -> [String] {
        let families = NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard !family.hasPrefix("Symbols Nerd Font"),
                      family != bundledFamily, !family.hasPrefix("."),
                      let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)
                else { return false }
                return isTerminalMonospaced(font)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [bundledFamily] + families
    }
}
