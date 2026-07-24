//
//  SettingsView.swift
//  kero
//

import AppKit
import GhosttyTheme
import SwiftUI

/// The app settings window (Cmd+,).
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared

    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()

    var body: some View {
        CappedIdealHeight(maxHeight: 600) { form }
    }

    private var form: some View {
        Form {
            Section("Appearance") {
                // A plain row rather than LabeledContent: that stamps its own
                // label onto every child, leaving all three previews named
                // "Theme" to VoiceOver instead of System/Light/Dark.
                HStack {
                    Text("Theme")
                    Spacer()
                    ThemePicker(selection: $settings.theme)
                }
                GhosttyThemePicker(
                    title: "Dark colors", selection: $settings.themeDark, dark: true
                )
                GhosttyThemePicker(
                    title: "Light colors", selection: $settings.themeLight, dark: false
                )
                Text("Colors apply to the terminal, editor, and window panels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Font") {
                Picker("Family", selection: $settings.fontFamily) {
                    Text("\(TerminalFont.bundledFamily) (Bundled)").tag("")
                    Divider()
                    ForEach(families.dropFirst(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Text("Size")
                    Slider(
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                }

                Toggle(
                    "Use bundled Chinese terminal font",
                    isOn: $settings.useBundledChineseTerminalFont
                )
                Text("Source Han Sans CN VF Mono1200 is used as the terminal CJK fallback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Thicken font strokes", isOn: $settings.fontThicken)
                Text("Renders terminal text with slightly heavier strokes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                // Exercises regular/bold plus Nerd Font icon fallback.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Qjiao ❯ echo \"the quick brown fox\" 0O 1lI")
                    Text("\u{E0A0} main \u{E0B0} ~/dev/qjiao \u{E711} \u{F024B} \u{F0A7D}")
                    Text("bold — permission denied (os error 13)")
                        .bold()
                }
                .font(Font(previewFont))
                .padding(.vertical, 4)
            }

            Section("Terminal") {
                Toggle(
                    "Move cursor with direct click",
                    isOn: $settings.directClickMovesCursor
                )
                Text("When enabled, an unmodified click at a shell prompt moves the cursor. Selection remains available with ⇧ drag.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Package manager", selection: $settings.packageManagerCommand) {
                    ForEach(PackageManagerCommand.allCases) { command in
                        Text(command.rawValue).tag(command)
                    }
                }
                Text("Used for package scripts launched from the Info panel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Restore session history on relaunch",
                    isOn: $settings.restoreTerminalHistory
                )
                Text("Reopened terminals show their previous scrollback above a fresh shell.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Text Editing") {
                Toggle("Wrap lines to editor width", isOn: $settings.wrapLines)
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: $updater.automaticallyChecksForUpdates
                )

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }
                    .disabled(settings.fontFamily.isEmpty
                        && settings.fontSize == AppSettings.defaultFontSize
                        && !settings.fontThicken
                        && settings.useBundledChineseTerminalFont
                        && settings.theme == .system
                        && settings.themeDark == Theme.defaultDarkThemeName
                        && settings.themeLight == Theme.defaultLightThemeName
                        && !settings.wrapLines
                        && !settings.restoreTerminalHistory
                        && !settings.directClickMovesCursor
                        && settings.packageManagerCommand == .npm)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private var previewFont: NSFont {
        TerminalFont.resolve(
            family: settings.fontFamily,
            size: CGFloat(settings.fontSize),
            useBundledChineseFallback: settings.useBundledChineseTerminalFont
        )
    }

}

/// Sizes its sole child to the child's ideal height, capped at `maxHeight`.
/// A `maxHeight` frame plus `fixedSize` can't express this: the grouped Form
/// is a List, which only scrolls when *proposed* the capped height, yet still
/// has to be measured unconstrained to hug shorter content.
private struct CappedIdealHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let ideal = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

/// Ghostty 主题选择器只在第一层展示精选主题，其余目录收进“全部…”。
private struct GhosttyThemePicker: View {
    let title: String
    @Binding var selection: String
    let dark: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                ForEach(ThemeMenuCatalog.primary(dark: dark), id: \.self) { name in
                    themeItem(name)
                }
                Section("Cool") {
                    ForEach(ThemeMenuCatalog.cool(dark: dark), id: \.self) { name in
                        themeItem(name)
                    }
                }
                Section("Warm") {
                    ForEach(ThemeMenuCatalog.warm(dark: dark), id: \.self) { name in
                        themeItem(name)
                    }
                }
                Divider()
                Menu("全部 \(dark ? "Dark" : "Light") 主题") {
                    ForEach(ThemeMenuCatalog.all(dark: dark), id: \.self) { name in
                        themeItem(name)
                    }
                }
            } label: {
                themeLabel(selection, dark: dark)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func themeItem(_ name: String) -> some View {
        Toggle(isOn: Binding(
            get: { selection == name },
            set: { if $0 { selection = name } }
        )) {
            Label {
                Text(name)
            } icon: {
                Image(nsImage: ThemePreviewImageRenderer.image(for: [
                    Theme.definition(named: name) ?? Theme.globalDefinition(dark: dark)
                ]))
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func themeLabel(_ title: String, dark: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: ThemePreviewImageRenderer.image(for: [
                Theme.definition(named: title) ?? Theme.globalDefinition(dark: dark)
            ]))
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Theme chooser modelled on the Appearance control in System Settings: one
/// tappable preview per option instead of a row of words.
private struct ThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTheme.allCases) { theme in
                ThemeOption(
                    theme: theme,
                    isSelected: selection == theme,
                    select: { selection = theme }
                )
            }
        }
    }
}

private struct ThemeOption: View {
    let theme: AppTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                ThemePreview(theme: theme)
                Text(theme.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    // Without this the row's HStack can squeeze a label to
                    // zero width, wrapping it into blank lines that stretch
                    // that one option taller than its neighbours.
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(isSelected ? 0.15 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature kero window painted in one appearance's real colors. `system`
/// splits down the middle — light on the left, dark on the right — the same
/// way System Settings previews "Auto".
private struct ThemePreview: View {
    let theme: AppTheme

    private static let size = CGSize(width: 76, height: 50)
    private static let corner: CGFloat = 7

    var body: some View {
        ZStack {
            switch theme {
            case .light:
                MiniWindow(dark: false)
            case .dark:
                MiniWindow(dark: true)
            case .system:
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: Self.size.width / 2)
                    }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

/// Sidebar, traffic lights, a tab, and a few lines of terminal output —
/// enough of kero's layout to read at thumbnail size.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let colors = Theme.globalTerminal(dark: dark)
        let text = Color(nsColor: colors.foreground)

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2.5) {
                    dot(0xFF5F57)
                    dot(0xFEBC2E)
                    dot(0x28C840)
                }
                .padding(.bottom, 3)

                bar(11, text.opacity(0.35))
                bar(8, text.opacity(0.35))
                bar(11, text.opacity(0.35))
            }
            .padding(5)
            .frame(minWidth: 22, maxWidth: 22, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: Theme.globalSidebarFill(dark: dark)))

            VStack(alignment: .leading, spacing: 3.5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(text.opacity(0.12))
                    .frame(width: 14, height: 5)
                    .padding(.bottom, 1)

                HStack(spacing: 2) {
                    bar(3, Color(nsColor: colors.cursor))
                    bar(22, text.opacity(0.8))
                }
                bar(30, text.opacity(0.45))
                bar(16, text.opacity(0.45))
                HStack(spacing: 2) {
                    bar(3, Color(nsColor: colors.cursor))
                    bar(7, text.opacity(0.8))
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(colors.background))
        }
    }

    private func dot(_ hex: Int) -> some View {
        Circle()
            .fill(Color(
                .sRGB,
                red: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255
            ))
            .frame(width: 3.5, height: 3.5)
    }

    private func bar(_ width: CGFloat, _ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(fill)
            .frame(width: width, height: 2.5)
    }
}

#Preview {
    SettingsView()
}
