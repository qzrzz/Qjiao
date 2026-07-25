//
//  VSCodeEditorTheme.swift
//  kero
//

import AppKit

/// 精选 VS Code 编辑器主题，使用各主题公开的编辑器与语法 token 配色。
enum VSCodeEditorTheme {
    struct Definition {
        let id: String
        let title: String
        let dark: Bool
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        let tokens: [String: NSColor]
    }

    static let darkPlus = Definition(
        id: "vscode.dark-plus", title: "Dark+ (VS Code)", dark: true,
        background: color("1E1E1E"), foreground: color("D4D4D4"), cursor: color("AEAFAD"),
        tokens: tokenColors(
            plain: "D4D4D4", comment: "6A9955", string: "CE9178", number: "B5CEA8",
            keyword: "569CD6", type: "4EC9B0", function: "DCDCAA", variable: "9CDCFE",
            builtin: "C586C0", punctuation: "D4D4D4"
        )
    )

    static let lightPlus = Definition(
        id: "vscode.light-plus", title: "Light+ (VS Code)", dark: false,
        background: color("FFFFFF"), foreground: color("000000"), cursor: color("000000"),
        tokens: tokenColors(
            plain: "000000", comment: "008000", string: "A31515", number: "098658",
            keyword: "0000FF", type: "267F99", function: "795E26", variable: "001080",
            builtin: "AF00DB", punctuation: "000000"
        )
    )

    static let gitHubDark = Definition(
        id: "vscode.github-dark", title: "GitHub Dark", dark: true,
        background: color("0D1117"), foreground: color("C9D1D9"), cursor: color("58A6FF"),
        tokens: tokenColors(
            plain: "C9D1D9", comment: "8B949E", string: "A5D6FF", number: "79C0FF",
            keyword: "FF7B72", type: "7EE787", function: "D2A8FF", variable: "C9D1D9",
            builtin: "F0883E", punctuation: "C9D1D9"
        )
    )

    static let gitHubLight = Definition(
        id: "vscode.github-light", title: "GitHub Light", dark: false,
        background: color("F6F8FA"), foreground: color("1F2328"), cursor: color("0969DA"),
        tokens: tokenColors(
            plain: "1F2328", comment: "59636E", string: "0A3069", number: "0550AE",
            keyword: "CF222E", type: "953800", function: "8250DF", variable: "24292F",
            builtin: "953800", punctuation: "1F2328"
        )
    )

    static let oneDark = Definition(
        id: "vscode.one-dark", title: "One Dark", dark: true,
        background: color("282C34"), foreground: color("ABB2BF"), cursor: color("528BFF"),
        tokens: tokenColors(
            plain: "ABB2BF", comment: "5C6370", string: "98C379", number: "D19A66",
            keyword: "C678DD", type: "E5C07B", function: "61AFEF", variable: "E06C75",
            builtin: "C678DD", punctuation: "ABB2BF"
        )
    )

    static let oneLight = Definition(
        id: "vscode.one-light", title: "One Light", dark: false,
        background: color("FAFAFA"), foreground: color("383A42"), cursor: color("526FFF"),
        tokens: tokenColors(
            plain: "383A42", comment: "A0A1A7", string: "50A14F", number: "986801",
            keyword: "A626A4", type: "C18401", function: "4078F2", variable: "E45649",
            builtin: "A626A4", punctuation: "383A42"
        )
    )

    static let monokaiPro = Definition(
        id: "vscode.monokai-pro", title: "Monokai Pro", dark: true,
        background: color("2D2A2E"), foreground: color("FCFCFA"), cursor: color("FFD866"),
        tokens: tokenColors(
            plain: "FCFCFA", comment: "727072", string: "A9DC76", number: "FF6188",
            keyword: "FF6188", type: "FC9867", function: "A9DC76", variable: "FCFCFA",
            builtin: "AB9DF2", punctuation: "FCFCFA"
        )
    )

    static let xcodeLight = Definition(
        id: "vscode.xcode-light", title: "Xcode Light", dark: false,
        background: color("FFFFFF"), foreground: color("000000"), cursor: color("000000"),
        tokens: tokenColors(
            plain: "000000", comment: "5D6C79", string: "DF0002", number: "1C00CF",
            keyword: "AD3DA4", type: "0B4F79", function: "326D74", variable: "272AD8",
            builtin: "AD3DA4", punctuation: "000000"
        )
    )

    static let xcodeDark = Definition(
        id: "vscode.xcode-dark", title: "Xcode Dark", dark: true,
        background: color("292A30"), foreground: color("F8F8F2"), cursor: color("F8F8F0"),
        tokens: tokenColors(
            plain: "F8F8F2", comment: "75715E", string: "E6DB74", number: "AE81FF",
            keyword: "F92672", type: "66D9EF", function: "A6E22E", variable: "F8F8F2",
            builtin: "F92672", punctuation: "F8F8F2"
        )
    )

    static let ayuLight = Definition(
        id: "vscode.ayu-light", title: "Ayu Light", dark: false,
        background: color("FAFAFA"), foreground: color("575F66"), cursor: color("F29718"),
        tokens: tokenColors(
            plain: "575F66", comment: "ABB0B6", string: "86B300", number: "A37ACC",
            keyword: "FA8D3E", type: "41A6D9", function: "F2AE49", variable: "55B4D4",
            builtin: "FA8D3E", punctuation: "575F66"
        )
    )

    static let ayuDark = Definition(
        id: "vscode.ayu-dark", title: "Ayu Dark", dark: true,
        background: color("0A0E14"), foreground: color("B3B1AD"), cursor: color("E6B450"),
        tokens: tokenColors(
            plain: "B3B1AD", comment: "626A73", string: "C2D94C", number: "E6B450",
            keyword: "FF8F40", type: "59C2FF", function: "FFCC66", variable: "E6B673",
            builtin: "FF8F40", punctuation: "B3B1AD"
        )
    )

    static let solarizedLight = Definition(
        id: "vscode.solarized-light", title: "Solarized Light", dark: false,
        background: color("FDF6E3"), foreground: color("657B83"), cursor: color("268BD2"),
        tokens: tokenColors(
            plain: "657B83", comment: "93A1A1", string: "2AA198", number: "D33682",
            keyword: "859900", type: "B58900", function: "268BD2", variable: "657B83",
            builtin: "CB4B16", punctuation: "657B83"
        )
    )

    static let solarizedDark = Definition(
        id: "vscode.solarized-dark", title: "Solarized Dark", dark: true,
        background: color("002B36"), foreground: color("839496"), cursor: color("268BD2"),
        tokens: tokenColors(
            plain: "839496", comment: "586E75", string: "2AA198", number: "D33682",
            keyword: "859900", type: "B58900", function: "268BD2", variable: "839496",
            builtin: "CB4B16", punctuation: "839496"
        )
    )

    static func definition(named id: String) -> Definition? {
        [darkPlus, lightPlus, gitHubDark, gitHubLight, oneDark, oneLight, monokaiPro,
         xcodeLight, xcodeDark, ayuLight, ayuDark, solarizedLight, solarizedDark]
            .first { $0.id == id }
    }

    static func all(dark: Bool) -> [Definition] {
        [darkPlus, lightPlus, gitHubDark, gitHubLight, oneDark, oneLight, monokaiPro,
         xcodeLight, xcodeDark, ayuLight, ayuDark, solarizedLight, solarizedDark]
            .filter { $0.dark == dark }
    }

    static func color(_ hex: String) -> NSColor {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    private static func tokenColors(
        plain: String, comment: String, string: String, number: String, keyword: String,
        type: String, function: String, variable: String, builtin: String, punctuation: String
    ) -> [String: NSColor] {
        let plainColor = color(plain)
        return [
            "plain": plainColor, "variable": color(variable), "parameter": color(variable),
            "operator": plainColor, "punctuation.special": color(punctuation),
            "comment": color(comment), "string": color(string), "text.literal": color(string),
            "number": color(number), "boolean": color(number), "keyword": color(keyword),
            "keyword.function": color(keyword), "keyword.return": color(keyword),
            "include": color(keyword), "type": color(type), "constructor": color(type),
            "text.title": color(type), "function.call": color(function), "method": color(function),
            "property": color(variable), "variable.builtin": color(builtin),
        ]
    }
}
