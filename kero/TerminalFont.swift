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
    /// BoldItalic), Source Han Sans CN, and the Symbols Nerd Font for this process only, so
    /// nothing is installed system-wide. Must run before the first
    /// terminal view is created.
    static func registerBundledFonts() {
        // Xcode's synchronized groups flatten Fonts/ into Contents/Resources.
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
            useBundledChineseFallback: settings.useBundledChineseTerminalFont
        )
    }

    /// Resolves a family name to a terminal-ready font. Empty family means
    /// the bundled default; an unknown family falls back to it too.
    ///
    /// The bundled Chinese font and Symbols Nerd Font are attached as CoreText
    /// cascade entries. They cover CJK text and PUA icon glyphs without a
    /// user-installed patched font. JetBrains Mono covers Powerline separators
    /// itself, so those never hit the fallback.
    static func resolve(
        family: String,
        size: CGFloat,
        useBundledChineseFallback: Bool
    ) -> NSFont {
        let base: NSFont
        if !family.isEmpty, family != bundledFamily,
           let chosen = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            base = chosen
        } else if let bundled = NSFont(name: "JetBrainsMono-Regular", size: size) {
            base = bundled
        } else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        var cascade = [NSFontDescriptor]()
        if useBundledChineseFallback {
            cascade.append(NSFontDescriptor(name: bundledChineseFamily, size: size))
        }
        cascade.append(NSFontDescriptor(name: symbolsFontName, size: size))
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: descriptor, size: size) ?? base
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
                return font.isFixedPitch
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [bundledFamily] + families
    }
}
