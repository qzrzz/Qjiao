//
//  SettingsView.swift
//  kero
//

import AppKit
import GhosttyTheme
import SwiftUI
import UniformTypeIdentifiers

/// The app settings window (Cmd+,).
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared
    @State private var selectedSection: SettingsSection = .general

    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()
    /// Files 树可选字体族（内置 Inter 第一项；设置里空字符串映射到该默认）。
    private let filesFontFamilies = FileTreeFont.selectableFamilies()

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
            Divider()
            // 分类切换时内容多少不同；让表单始终填满固定区域，避免窗口和导航跟随内容跳动。
            form
                .frame(maxHeight: .infinity)
        }
        .frame(width: 510, height: 650)
    }

    /// 顶部图标导航借鉴原生设置应用的分类结构，避免全部选项堆在一张长表单中。
    private var sectionPicker: some View {
        HStack(spacing: 7) {
            ForEach(SettingsSection.allCases) { section in
                Button { selectedSection = section } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 15, weight: .medium))
                        Text(section.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(selectedSection == section ? Color.accentColor : .secondary)
                    // 六个分类时略收窄卡片，避免顶栏横向溢出固定窗口宽度。
                    .frame(width: 66, height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selectedSection == section ? Color.accentColor.opacity(0.10) : .clear)
                    )
                    // 让整张可见导航卡片都能点击，而不是仅图标和文字响应点击。
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                // 分类切换后不保留键盘焦点的蓝色描边；选中状态仅由填充色表达。
                .focusEffectDisabled()
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
    }

    private var form: some View {
        Form {
            if selectedSection == .general {
            Section("Appearance") {
                Group {
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
                }
                .settingsRowPadding()
            }

            Section {
                Group {
                    backgroundOpacityControl(
                        "Window background opacity",
                        value: $settings.windowBackgroundOpacity
                    )
                    backgroundOpacityControl(
                        "Terminal background opacity",
                        value: $settings.terminalBackgroundOpacity
                    )
                }
                .settingsRowPadding()
            }

            // 仅在窗口背景不透明度小于 100% (即 < 1) 时显示窗口视觉效果设置
            if settings.windowBackgroundOpacity < 1 {
                Section {
                    Group {
                        Text("Window visual effect material when the window is transparent.")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        Picker("Effect material", selection: $settings.visualEffectMaterial) {
                            Text("Under Window (Default)").tag("underWindowBackground")
                            Text("Sidebar").tag("sidebar")
                            Text("HUD Panel").tag("hud")
                            Text("Popover").tag("popover")
                            Text("Menu").tag("menu")
                            Text("Header View").tag("headerView")
                            Text("Titlebar").tag("titlebar")
                        }

                        Picker("Blending mode", selection: $settings.visualEffectBlendingMode) {
                            Text("Behind Window").tag("behindWindow")
                            Text("Within Window").tag("withinWindow")
                        }

                        Picker("Active state", selection: $settings.visualEffectState) {
                            Text("Follow Application").tag("followsApp")
                            Text("Follow Window Focus").tag("followsWindow")
                            Text("Always Active").tag("active")
                            Text("Always Inactive").tag("inactive")
                        }

                        backgroundOpacityControl(
                            "Visual effect alpha",
                            value: $settings.visualEffectAlpha
                        )
                    }
                    .settingsRowPadding()
                }
            }

            Section("Defaults") {
                Group {
                HStack {
                    Text("Restore all Qjiao preferences to their defaults.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }
                    .disabled(isUsingDefaults)
                }
                }
                .settingsRowPadding()
            }

            Section("Updates") {
                Group {
                    Toggle(
                        "Automatically check for updates",
                        isOn: $updater.automaticallyChecksForUpdates
                    )

                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
                .settingsRowPadding()
            }
            }

            if selectedSection == .terminal {
            Section("Font") {
                Group {
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

                settingWithDescription(
                    "Use bundled Chinese terminal font",
                    "Source Han Sans CN VF Mono1200 is used as the terminal CJK fallback."
                ) {
                    Toggle("", isOn: $settings.useBundledChineseTerminalFont)
                        .labelsHidden()
                }

                settingWithDescription(
                    "Thicken font strokes",
                    "Renders terminal text with slightly heavier strokes."
                ) {
                    Toggle("", isOn: $settings.fontThicken)
                        .labelsHidden()
                }
                }
                .settingsRowPadding()
            }

            Section("Preview") {
                Group {
                    // Exercises regular/bold plus Nerd Font icon fallback.

                    VStack(alignment: .leading, spacing: 6) {

                        Text("Qjiao ❯ echo \"the quick brown fox\" 0O 1lI")

                        Text("\u{E0A0} main \u{E0B0} ~/dev/qjiao \u{E711} \u{F024B} \u{F0A7D}")

                        Text("bold — permission denied (os error 13)")

                            .bold()

                        Text("""
                        ┌────┬──────────────┬──────────┬────────────┐
                        │ ID │ Name         │ 状态     │ Description│
                        ├────┼──────────────┼──────────┼────────────┤
                        │ 06 │ 青椒         │ 测试中   │ Testing    │
                        └────┴──────────────┴──────────┴────────────┘
                        """)

                    }


                .font(Font(previewFont))
                .padding(.vertical, 4)
                }
                .settingsRowPadding()
            }

            Section("Features") {
                Group {
                settingWithDescription(
                    "Move cursor with direct click",
                    "Cursor as naturally as in a text editor."
                ) {
                    Toggle("", isOn: $settings.directClickMovesCursor)
                        .labelsHidden()
                }

                settingWithDescription(
                    "Disable Zsh Auto Title",
                    "Sets DISABLE_AUTO_TITLE=true only for new zsh terminals in Qjiao."
                ) {
                    Toggle("", isOn: $settings.disableZshAutoTitle)
                        .labelsHidden()
                }

                }
                .settingsRowPadding()
            }

            Section {
                Group {
                    settingWithDescription(
                        "Restore session history on relaunch",
                        "Reopened terminals show their previous scrollback above a fresh shell."
                    ) {
                        Toggle("", isOn: $settings.restoreTerminalHistory)
                            .labelsHidden()
                    }
                }
                .settingsRowPadding()
            }
            }

            if selectedSection == .editor {
            Section("Color Theme") {
                Group {
                    EditorThemePicker(
                        title: "Light colors", selection: $settings.editorThemeLight, dark: false
                    )
                    EditorThemePicker(
                        title: "Dark colors", selection: $settings.editorThemeDark, dark: true
                    )
                }
                .settingsRowPadding()
            }

            Section("Text Editing") {
                Group {
                Toggle("Wrap lines to editor width", isOn: $settings.wrapLines)
                Toggle("Show editor status bar", isOn: $settings.showEditorStatusBar)
                }
                .settingsRowPadding()
            }
            }

            if selectedSection == .files {
            Section("Font") {
                Group {
                    Picker("Family", selection: $settings.filesFontFamily) {
                        // 空字符串 = 内置 Inter Variable，与 Terminal 的 bundled 默认同一约定。
                        Text("\(FileTreeFont.bundledFamily) (Bundled)").tag("")
                        Divider()
                        ForEach(filesFontFamilies.dropFirst(), id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }

                    HStack {
                        Text("Size")
                        Slider(
                            value: $settings.filesFontSize,
                            in: AppSettings.filesFontSizeRange,
                            step: 1
                        )
                        Text("\(Int(settings.filesFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Stepper(
                            "",
                            value: $settings.filesFontSize,
                            in: AppSettings.filesFontSizeRange,
                            step: 1
                        )
                        .labelsHidden()
                    }

                    // 预览随当前 Files 字体即时变化，便于对照树中观感。
                    Text("package.json   src/   README.md   1.2 KB")
                        .font(FileTreeFont.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .settingsRowPadding()
            }

            Section("File Tree") {
                Group {
                    settingWithDescription(
                        "Display File Size",
                        "Show each file’s size on the right in the Files and CWD panels."
                    ) {
                        Toggle("", isOn: $settings.displayFileSize)
                            .labelsHidden()
                    }
                }
                .settingsRowPadding()
            }
            }

            if selectedSection == .project {
                ProjectSettingsSectionView(settings: settings)
            }

            if selectedSection == .about {
            Section {
                Group {
                    VStack(spacing: 8) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        Text("Qjiao")
                            .font(.title2.weight(.semibold))
                        Text("A terminal workspace for macOS")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .settingsRowPadding()
            }

            Section("Project") {
                Group {
                    aboutLinkRow(
                        imageName: "GitHubMark",
                        title: "Qjiao GitHub",
                        subtitle: "qzrzz/Qjiao",
                        url: "https://github.com/qzrzz/Qjiao"
                    )
                    aboutLinkRow(
                        systemImage: "person",
                        title: "Author",
                        subtitle: "Qzrzz · qzrzz.com",
                        url: "https://qzrzz.com/"
                    )
                }
                .settingsRowPadding()
            }

            Section("Acknowledgements") {
                Group {
                    aboutLinkRow(
                        systemImage: "arrow.triangle.branch",
                        title: "Forked from egoist/kero",
                        subtitle: "egoist / kero",
                        url: "https://github.com/egoist/kero"
                    )
                    aboutLinkRow(
                        systemImage: "heart",
                        title: "Thanks to egoist",
                        subtitle: "github.com/egoist",
                        url: "https://github.com/egoist"
                    )
                }
                .settingsRowPadding()
            }
            }
        }
        .formStyle(.grouped)
        .frame(width: 510)
    }

    private var previewFont: NSFont {
        TerminalFont.resolve(
            family: settings.fontFamily,
            size: CGFloat(settings.fontSize),
            useBundledChineseFallback: settings.useBundledChineseTerminalFont
        )
    }

    private func backgroundOpacityControl(
        _ title: String, value: Binding<Double>
    ) -> some View {
        HStack {
            Text(title)
            Slider(
                value: value,
                in: AppSettings.backgroundOpacityRange,
                step: 0.05
            )
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
        }
    }

    /// 将设置标题、说明与右侧控件合并为一个表单行，避免标题和说明之间出现分隔线。
    private func settingWithDescription<Control: View>(
        _ title: String,
        _ description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
    }

    /// About 页面中整行可点击的外部链接，统一展示图标、标题、来源和跳转提示。
    private func aboutLinkRow(
        systemImage: String? = nil,
        imageName: String? = nil,
        title: String,
        subtitle: String,
        url: String
    ) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Group {
                    if let imageName {
                        Image(imageName)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .padding(6)
                            .foregroundStyle(.primary)
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isUsingDefaults: Bool {
        settings.fontFamily.isEmpty
            && settings.fontSize == AppSettings.defaultFontSize
            && !settings.fontThicken
            && settings.useBundledChineseTerminalFont
            && settings.theme == .system
            && settings.themeDark == Theme.defaultDarkThemeName
            && settings.themeLight == Theme.defaultLightThemeName
            && settings.windowBackgroundOpacity == 1
            && settings.terminalBackgroundOpacity == 1
            && settings.visualEffectMaterial == "underWindowBackground"
            && settings.visualEffectBlendingMode == "behindWindow"
            && settings.visualEffectState == "followsApp"
            && settings.visualEffectAlpha == 1
            && !settings.wrapLines
            && settings.displayFileSize
            && settings.filesFontFamily.isEmpty
            && settings.filesFontSize == AppSettings.defaultFilesFontSize
            && !settings.restoreTerminalHistory
            && !settings.directClickMovesCursor
            && !settings.disableZshAutoTitle
            && settings.packageManagerCommand == .npm
    }

}

/// 设置页的可见分类；每个分类对应顶部一个图标入口。
private enum SettingsSection: CaseIterable, Identifiable {
    case general
    case terminal
    case editor
    case files
    case project
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .editor: "Editor"
        case .files: "Files"
        case .project: "Project"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .terminal: "terminal"
        case .editor: "text.cursor"
        case .files: "folder"
        case .project: "shippingbox"
        case .about: "info.circle"
        }
    }
}

private extension View {
    /// 将分组中的每个实际设置行直接撑开，绕过 macOS Form 不响应 listRowInsets 的限制。
    func settingsRowPadding() -> some View {
        padding(.vertical, 4)
            .padding(.horizontal, 8)
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

/// 编辑器单一外观的配色选择器；空字符串表示继承全局与项目主题。
private struct EditorThemePicker: View {
    let title: String
    @Binding var selection: String
    let dark: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                followGlobalItem
                Divider()
                Section("VS Code") {
                    ForEach(VSCodeEditorTheme.all(dark: dark), id: \.id) { theme in
                        vscodeThemeItem(theme)
                    }
                }
            } label: {
                themeLabel
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var followGlobalItem: some View {
        Toggle(isOn: Binding(
            get: { selection.isEmpty },
            set: { if $0 { selection = "" } }
        )) {
            Label {
                Text("Default")
            } icon: {
                Image(nsImage: ThemePreviewImageRenderer.image(for: [Theme.globalDefinition(dark: dark)]))
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func vscodeThemeItem(_ theme: VSCodeEditorTheme.Definition) -> some View {
        Toggle(isOn: Binding(
            get: { selection == theme.id },
            set: { if $0 { selection = theme.id } }
        )) {
            Text(theme.title)
        }
    }

    private var themeLabel: some View {
        let label = selection.isEmpty
            ? "Default"
            : VSCodeEditorTheme.definition(named: selection)?.title ?? selection
        let definition = Theme.definition(named: selection) ?? Theme.globalDefinition(dark: dark)
        return Label {
            Text(label)
        } icon: {
            Image(nsImage: ThemePreviewImageRenderer.image(for: [definition]))
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

/// 自动折行排列标签的流式布局
@available(macOS 13.0, *)
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.bounds
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let point = result.points[index]
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var bounds: CGSize = .zero
        var points: [CGPoint] = []

        init(in maxRowWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > maxRowWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                points.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
                bounds.width = max(bounds.width, currentX)
            }
            bounds.height = currentY + lineHeight
        }
    }
}

/// CLI 命令标签 Chips 控件
private struct CLIToolChip: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove \(text)")
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 3.5)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// 添加 CLI 命令的快捷输入框
private struct AddCLIChipField: View {
    @State private var newCommand: String = ""
    let onAdd: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            TextField("Add…", text: $newCommand)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(minWidth:  80, maxWidth: 80)
                .onSubmit {
                    submit()
                }

            if !newCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add") {
                    submit()
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            Capsule()
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func submit() {
        let trimmed = newCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onAdd(trimmed)
            newCommand = ""
        }
    }
}

/// Project 设置分类面板：原生 macOS 风格的 Code 编辑工具与 CLI 工具配置。
private struct ProjectSettingsSectionView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            // ── Section 1: Package Manager 独立分组
            Section("Package Manager") {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Package manager")
                            .font(.system(size: 13, weight: .medium))
                        Text("Used for package scripts launched from the Info panel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $settings.packageManagerCommand) {
                        ForEach(PackageManagerCommand.allCases) { command in
                            Text(command.rawValue).tag(command)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                .settingsRowPadding()
            }

            // ── Section 2: 快捷打开应用程序与 CLI
            Section("External Tools") {
                VStack(alignment: .leading, spacing: 12) {
                    // 顶部说明文本
                    Text("\"快速打开\"可用的应用程序和 CLI")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Divider()
                    // ── 1. 代码编辑工具
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Code Editor Application")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Spacer()
                        Button("Select Application...") {
                            selectCustomEditorApp()
                        }
                        .controlSize(.small)
                    }

                    if settings.customCodeEditorPaths.isEmpty {
                        HStack {
                            Text("Empty")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.top, 2)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(settings.customCodeEditorPaths.enumerated()), id: \.element) { index, path in
                                let url = URL(fileURLWithPath: path)
                                let icon = NSWorkspace.shared.icon(forFile: path)
                                HStack(spacing: 8) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(path)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()

                                    Button("Remove") {
                                        removeCustomEditor(path: path)
                                    }
                                    .font(.system(size: 11))
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red.opacity(0.85))
                                }
                                .padding(.vertical, 4)

                                if index < settings.customCodeEditorPaths.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Divider()

                // ── 2. CLI 工具
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CLI")
                            .font(.system(size: 13, weight: .medium))
                    }

                    if #available(macOS 13.0, *) {
                        FlowLayout(spacing: 6) {
                            ForEach(settings.customCLITools, id: \.self) { cmd in
                                CLIToolChip(text: cmd) {
                                    removeCLITool(cmd)
                                }
                            }
                            AddCLIChipField { newCmd in
                                addCLITool(newCmd)
                            }
                        }
                        .padding(.top, 2)
                    } else {
                        HStack(spacing: 6) {
                            ForEach(settings.customCLITools, id: \.self) { cmd in
                                CLIToolChip(text: cmd) {
                                    removeCLITool(cmd)
                                }
                            }
                            AddCLIChipField { newCmd in
                                addCLITool(newCmd)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .settingsRowPadding()
        }
    }
    }

    private func selectCustomEditorApp() {
        let panel = NSOpenPanel()
        panel.title = "选择代码编辑器应用"
        panel.prompt = "选择"
        panel.allowedContentTypes = [UTType.application, UTType.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !settings.customCodeEditorPaths.contains(path) {
                    settings.customCodeEditorPaths.append(path)
                }
            }
            CodeEditorRegistry.shared.refresh()
        }
    }

    private func removeCustomEditor(path: String) {
        settings.customCodeEditorPaths.removeAll { $0 == path }
        CodeEditorRegistry.shared.refresh()
    }

    private func addCLITool(_ cmd: String) {
        if !settings.customCLITools.contains(cmd) {
            settings.customCLITools.append(cmd)
            AIToolRegistry.shared.refresh()
        }
    }

    private func removeCLITool(_ cmd: String) {
        settings.customCLITools.removeAll { $0 == cmd }
        AIToolRegistry.shared.refresh()
    }
}

#Preview {
    SettingsView()
}
