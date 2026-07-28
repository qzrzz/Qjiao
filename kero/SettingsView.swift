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
    @ObservedObject private var l10n = L10n.shared
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
        .observeLocalization()
        // 依赖 language，切换语言时整页重绘。
        .environment(\.l10nLanguage, l10n.language)
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
            Section(L10n.t("Language")) {
                Group {
                    settingWithDescription(
                        L10n.t("Interface language"),
                        L10n.t("Choose the language used for menus, settings, and panels.")
                    ) {
                        Picker("", selection: $settings.language) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.nativeDisplayName).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .settingsRowPadding()
            }

            Section(L10n.t("Appearance")) {
                Group {
                    // A plain row rather than LabeledContent: that stamps its own
                    // label onto every child, leaving all three previews named
                    // "Theme" to VoiceOver instead of System/Light/Dark.
                    HStack {
                        Text(L10n.t("Theme"))
                        Spacer()
                        ThemePicker(selection: $settings.theme)
                    }
                    GhosttyThemePicker(
                        title: L10n.t("Dark colors"), selection: $settings.themeDark, dark: true
                    )
                    GhosttyThemePicker(
                        title: L10n.t("Light colors"), selection: $settings.themeLight, dark: false
                    )
                    ProjectThemeOverrideHint()

                    settingWithDescription(
                        L10n.t("Short Directory Path"),
                        L10n.t("Display ~ instead of home directory path.")
                    ) {
                        Toggle("", isOn: $settings.displayShortDirPath)
                            .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 12) {
                            Text(L10n.t("Sidebar font size"))
                            Spacer()
                            HStack(spacing: 8) {
                                Slider(
                                    value: $settings.sidebarFontSize,
                                    in: AppSettings.sidebarFontSizeRange,
                                    step: 1
                                )
                                .frame(width: 120)
                                Text("\(Int(settings.sidebarFontSize)) pt")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                                Stepper(
                                    "",
                                    value: $settings.sidebarFontSize,
                                    in: AppSettings.sidebarFontSizeRange,
                                    step: 1
                                )
                                .labelsHidden()
                            }
                        }
                        Text(L10n.t(
                            "Scales text in both sidebars while preserving the existing visual hierarchy."
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .settingsRowPadding()
            }

            CustomThemesSettingsSection()

            Section(L10n.t("Window")) {
                Group {
                    backgroundOpacityControl(
                        L10n.t("Window background opacity"),
                        value: $settings.windowBackgroundOpacity
                    )
                    backgroundOpacityControl(
                        L10n.t("Terminal background opacity"),
                        value: $settings.terminalBackgroundOpacity
                    )
                }
                .settingsRowPadding()
            }

            // 仅在窗口背景不透明度小于 100% (即 < 1) 时显示窗口视觉效果设置
            if settings.windowBackgroundOpacity < 1 {
                Section {
                    Group {
                        Text(L10n.t("Window visual effect material when the window is transparent."))
                            .font(.body)
                            .foregroundStyle(.secondary)

                        Picker(L10n.t("Effect material"), selection: $settings.visualEffectMaterial) {
                            Text(L10n.t("Under Window (Default)")).tag("underWindowBackground")
                            Text(L10n.t("Sidebar")).tag("sidebar")
                            Text(L10n.t("HUD Panel")).tag("hud")
                            Text(L10n.t("Popover")).tag("popover")
                            Text(L10n.t("Menu")).tag("menu")
                            Text(L10n.t("Header View")).tag("headerView")
                            Text(L10n.t("Titlebar")).tag("titlebar")
                        }

                        Picker(L10n.t("Blending mode"), selection: $settings.visualEffectBlendingMode) {
                            Text(L10n.t("Behind Window")).tag("behindWindow")
                            Text(L10n.t("Within Window")).tag("withinWindow")
                        }

                        Picker(L10n.t("Active state"), selection: $settings.visualEffectState) {
                            Text(L10n.t("Follow Application")).tag("followsApp")
                            Text(L10n.t("Follow Window Focus")).tag("followsWindow")
                            Text(L10n.t("Always Active")).tag("active")
                            Text(L10n.t("Always Inactive")).tag("inactive")
                        }

                        backgroundOpacityControl(
                            L10n.t("Visual effect alpha"),
                            value: $settings.visualEffectAlpha
                        )
                    }
                    .settingsRowPadding()
                }
            }

            Section(L10n.t("AI")) {
                Group {
                    LocalAIHeadlessProviderPicker()

                    settingWithDescription(
                        L10n.t("Writing language"),
                        L10n.t(
                            "Language for AI-generated Git commits, descriptions, and similar text. Projects can override this."
                        )
                    ) {
                        Picker("", selection: $settings.aiWritingLanguage) {
                            ForEach(AIWritingLanguage.allCases) { lang in
                                Text(lang.nativeDisplayName).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    settingWithDescription(
                        L10n.t("Git Commit Message Emoji"),
                        L10n.t("Use the Gitmoji convention (e.g. ✨ feat) in AI commit messages.")
                    ) {
                        Toggle("", isOn: $settings.gitCommitMessageEmoji)
                            .labelsHidden()
                    }
                }
                .settingsRowPadding()
            }

            Section(L10n.t("Defaults")) {
                Group {
                HStack {
                    Text(L10n.t("Restore all Qjiao preferences to their defaults."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("Reset to Defaults")) {
                        settings.resetToDefaults()
                    }
                    .disabled(isUsingDefaults)
                }
                }
                .settingsRowPadding()
            }

            Section(L10n.t("Updates")) {
                Group {
                    Toggle(
                        L10n.t("Automatically check for updates"),
                        isOn: $updater.automaticallyChecksForUpdates
                    )

                    Button(L10n.t("Check for Updates…")) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
                .settingsRowPadding()
            }
            }

            if selectedSection == .terminal {
            Section(L10n.t("Font")) {
                Group {
                Picker(L10n.t("Family"), selection: $settings.fontFamily) {
                    Text("\(TerminalFont.bundledFamily) \(L10n.t("(Bundled)"))").tag("")
                    Divider()
                    ForEach(families.dropFirst(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Text(L10n.t("Size"))
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
                    L10n.t("Use bundled Chinese terminal font"),
                    L10n.t("Source Han Sans CN VF Mono1200 is used as the terminal CJK fallback.")
                ) {
                    Toggle("", isOn: $settings.useBundledChineseTerminalFont)
                        .labelsHidden()
                }

                settingWithDescription(
                    L10n.t("Thicken font strokes"),
                    L10n.t("Renders terminal text with slightly heavier strokes.")
                ) {
                    Toggle("", isOn: $settings.fontThicken)
                        .labelsHidden()
                }
                }
                .settingsRowPadding()
            }

            Section(L10n.t("Preview")) {
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

            Section(L10n.t("Features")) {
                Group {
                settingWithDescription(
                    L10n.t("Move cursor with direct click"),
                    L10n.t("Cursor as naturally as in a text editor.")
                ) {
                    Toggle("", isOn: $settings.directClickMovesCursor)
                        .labelsHidden()
                }

                settingWithDescription(
                    L10n.t("Use Option as Alt/Meta"),
                    L10n.t("Sends Option-key combinations to terminal programs as Meta shortcuts instead of macOS text input.")
                ) {
                    Toggle("", isOn: $settings.macosOptionAsAlt)
                        .labelsHidden()
                }

                settingWithDescription(
                    L10n.t("Custom Idle Tab Title"),
                    L10n.t("Zsh controlled tab title setting ($ZSH_THEME_TERM_TITLE_IDLE)")
                ) {
                    Picker("", selection: $settings.zshIdleTitleStyle) {
                        ForEach(ZshIdleTitleStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                settingWithDescription(
                    L10n.t("Enable Terminal help bar"),
                    L10n.t("Shows context-sensitive action bars at the bottom of the terminal, such as Vi editing controls.")
                ) {
                    Toggle("", isOn: $settings.enableTerminalHelpBar)
                        .labelsHidden()
                }

                }
                .settingsRowPadding()
            }

            Section {
                Group {
                    settingWithDescription(
                        L10n.t("Restore session history on relaunch"),
                        L10n.t("Reopened terminals show their previous scrollback above a fresh shell.")
                    ) {
                        Toggle("", isOn: $settings.restoreTerminalHistory)
                            .labelsHidden()
                    }
                }
                .settingsRowPadding()
            }
            }

            if selectedSection == .editor {
            Section(L10n.t("Color Theme")) {
                Group {
                    EditorThemePicker(
                        title: L10n.t("Light colors"), selection: $settings.editorThemeLight, dark: false
                    )
                    EditorThemePicker(
                        title: L10n.t("Dark colors"), selection: $settings.editorThemeDark, dark: true
                    )
                }
                .settingsRowPadding()
            }

            Section(L10n.t("Text Editing")) {
                Group {
                Toggle(L10n.t("Wrap lines to editor width"), isOn: $settings.wrapLines)
                Toggle(L10n.t("Show editor status bar"), isOn: $settings.showEditorStatusBar)
                }
                .settingsRowPadding()
            }
            }

            if selectedSection == .files {
            Section(L10n.t("Font")) {
                Group {
                    Picker(L10n.t("Family"), selection: $settings.filesFontFamily) {
                        // 空字符串 = 内置 Inter Variable，与 Terminal 的 bundled 默认同一约定。
                        Text("\(FileTreeFont.bundledFamily) \(L10n.t("(Bundled)"))").tag("")
                        Divider()
                        ForEach(filesFontFamilies.dropFirst(), id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }

                    HStack {
                        Text(L10n.t("Size"))
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

            Section(L10n.t("File Tree")) {
                Group {
                    settingWithDescription(
                        L10n.t("Display File Size"),
                        L10n.t("Show each file’s size on the right in the Files and CWD panels.")
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
                        Text(L10n.t("A terminal workspace for macOS"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .settingsRowPadding()
            }

            Section(L10n.t("Project")) {
                Group {
                    aboutLinkRow(
                        imageName: "GitHubMark",
                        title: L10n.t("GitHub"),
                        subtitle: "https://github.com/qzrzz/Qjiao",
                        url: "https://github.com/qzrzz/Qjiao"
                    )
                    aboutLinkRow(
                        imageName: "AuthorLogo",
                        isOriginalColor: true,
                        title: L10n.t("Qzrzz"),
                        subtitle: "qzrzz.com",
                        url: "https://qzrzz.com/"
                    )
                }
                .settingsRowPadding()
            }

            Section(L10n.t("Acknowledgements")) {
                Group {
                    aboutLinkRow(
                        systemImage: "arrow.triangle.branch",
                        title: L10n.t("Forked from egoist/kero"),
                        subtitle: "egoist / kero",
                        url: "https://github.com/egoist/kero"
                    )
                    aboutLinkRow(
                        systemImage: "heart",
                        title: L10n.t("Thanks to egoist"),
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
    /// - Parameters:
    ///   - systemImage: SF Symbol 图标名称
    ///   - imageName: Asset Catalog 中的自定义图片名称
    ///   - isOriginalColor: 是否保持图片原本颜色（为 true 时不应用模板渲染和前景色）
    ///   - title: 链接主标题
    ///   - subtitle: 链接副标题/来源说明
    ///   - url: 目标跳转 URL
    private func aboutLinkRow(
        systemImage: String? = nil,
        imageName: String? = nil,
        isOriginalColor: Bool = false,
        title: String,
        subtitle: String,
        url: String
    ) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Group {
                    if let imageName {
                        if isOriginalColor {
                            Image(imageName)
                                .resizable()
                                .scaledToFit()
                                .padding(4)
                        } else {
                            Image(imageName)
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .padding(6)
                                .foregroundStyle(.primary)
                        }
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
            && settings.sidebarFontSize == AppSettings.defaultSidebarFontSize
            && !settings.fontThicken
            && !settings.macosOptionAsAlt
            && settings.useBundledChineseTerminalFont
            && settings.language == .english
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
            && settings.packageManagerCommand == .npm
            && settings.localAIHeadlessProvider == .disabled
            && settings.aiWritingLanguage == .english
            && settings.gitCommitMessageEmoji
    }

}

// MARK: - Local AI headless provider

/// General 设置中的 AI headless provider 选择器：列出支持的 CLI，未安装项不可选并标注。
///
/// 排版与 `settingWithDescription` 对齐：标题用默认字号，说明用 `.callout`，避免 caption 过小难读。
private struct LocalAIHeadlessProviderPicker: View {
    @ObservedObject private var registry = LocalAIRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("AI headless provider"))
                        .fontWeight(.semibold)
                    Text(L10n.t("Provide AI capabilities using a local AI CLI."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                // 使用 Menu 而非 Picker，以便对未安装 CLI 使用 .disabled
                Menu {
                    ForEach(registry.allStatusesForPicker) { status in
                        Button {
                            registry.selectedProvider = status.provider
                        } label: {
                            if status.provider == registry.selectedProvider {
                                Label(status.pickerLabel, systemImage: "checkmark")
                            } else {
                                Text(status.pickerLabel)
                            }
                        }
                        .disabled(!status.isAvailable)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(registry.selectedStatus?.pickerLabel ?? LocalAIProviderID.disabled.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.top, 1)
            }

            // 命令预览靠左（浅灰底、宽度随内容）、刷新靠右，同一行节省纵向空间
            HStack(alignment: .center, spacing: 8) {
                if registry.selectedProvider != .disabled {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        // Form 内 SwiftUI Text.textSelection 常无法选中，用只读 NSTextField
                        SelectableTerminalCommandText(text: registry.selectedProvider.commandHint)
                            .frame(minHeight: 16, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    // 宽度随命令内容；过长时封顶，避免挤掉 Refresh
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: 280, alignment: .leading)
                    .clipped()
                }

                Spacer(minLength: 0)

                Button(L10n.t("Refresh")) {
                    registry.refresh()
                }
                .controlSize(.small)
                .help(L10n.t("Re-scan PATH and common install locations for AI CLIs."))
            }
        }
        .onAppear {
            registry.refresh()
        }
    }
}

/// 设置 Form 内可拖选 / 复制的只读命令文本；宽度随内容，过长时由外层裁切。
private struct SelectableTerminalCommandText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> IntrinsicWidthTextField {
        let field = IntrinsicWidthTextField(string: text)
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = NSColor.secondaryLabelColor
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.allowsEditingTextAttributes = false
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: IntrinsicWidthTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
            nsView.invalidateIntrinsicContentSize()
        }
    }
}

/// 按文字内容报告 intrinsic width，便于预览胶囊贴合命令长度。
private final class IntrinsicWidthTextField: NSTextField {
    override var intrinsicContentSize: NSSize {
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let width = (stringValue as NSString).size(withAttributes: attrs).width.rounded(.up) + 2
        let height = super.intrinsicContentSize.height
        return NSSize(width: max(width, 1), height: height)
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
        case .general: L10n.t("General")
        case .terminal: L10n.t("Terminal")
        case .editor: L10n.t("Editor")
        case .files: L10n.t("Files")
        case .project: L10n.t("Project")
        case .about: L10n.t("About")
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

/// 活动项目覆盖全局配色时显示一行简短提示。
private struct ProjectThemeOverrideHint: View {
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let _ = (themeChanges, l10n.language)
        if let summary = Theme.projectThemeOverrideSummary {
            Label {
                Text(summaryText(summary))
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color(nsColor: Theme.cursor))
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// 例：Project “Foo” overrides colors: Dark = A, Light = B
    private func summaryText(_ summary: ProjectThemeOverrideSummary) -> String {
        var parts: [String] = []
        if let dark = summary.darkOverride {
            parts.append(L10n.format("Dark = %@", dark))
        }
        if let light = summary.lightOverride {
            parts.append(L10n.format("Light = %@", light))
        }
        let themes = parts.joined(separator: ", ")
        if let name = summary.projectName, !name.isEmpty {
            return L10n.format("Project “%@” overrides colors: %@.", name, themes)
        }
        return L10n.format("Project overrides colors: %@.", themes)
    }
}

/// Ghostty / 自定义主题选择器：自定义分组在前，精选主题其次，完整目录收进“全部…”。
private struct GhosttyThemePicker: View {
    let title: String
    @Binding var selection: String
    let dark: Bool
    @ObservedObject private var customThemes = CustomThemeStore.shared

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                customThemeMenuSection(dark: dark, selection: selection) { name in
                    selection = name
                }
                ForEach(ThemeMenuCatalog.primary(dark: dark), id: \.self) { name in
                    themeItem(name)
                }
                Section(L10n.t("Cool")) {
                    ForEach(ThemeMenuCatalog.cool(dark: dark), id: \.self) { name in
                        themeItem(name)
                    }
                }
                Section(L10n.t("Warm")) {
                    ForEach(ThemeMenuCatalog.warm(dark: dark), id: \.self) { name in
                        themeItem(name)
                    }
                }
                Divider()
                Menu(dark ? L10n.t("All Dark Themes") : L10n.t("All Light Themes")) {
                    ForEach(ThemeMenuCatalog.allIncludingCustom(dark: dark), id: \.self) { name in
                        themeItem(name)
                    }
                }
            } label: {
                themeLabel(selection, dark: dark)
            }
            .menuStyle(.borderlessButton)
            // 观察 store，新建/删除后刷新菜单项。
            .id(customThemes.themes.map(\.id))
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
                Section(L10n.t("VS Code")) {
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
                Text(L10n.t("Default"))
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
                Button(L10n.t("Add")) {
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
            Section(L10n.t("Package Manager")) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("Package manager"))
                            .font(.system(size: 13, weight: .medium))
                        Text(L10n.t("Used for package scripts launched from the Info panel."))
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
            Section(L10n.t("External Tools")) {
                VStack(alignment: .leading, spacing: 12) {
                    // 顶部说明文本
                    Text(L10n.t("Applications and CLIs available for quick open"))
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Divider()
                    // ── 1. 代码编辑工具
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("Code Editor Application"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        Spacer()
                        Button(L10n.t("Select Application...")) {
                            selectCustomEditorApp()
                        }
                        .controlSize(.small)
                    }

                    if settings.customCodeEditorPaths.isEmpty {
                        HStack {
                            Text(L10n.t("Empty"))
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

                                    Button(L10n.t("Remove")) {
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
                        Text(L10n.t("CLI"))
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
        panel.title = L10n.t("Select Code Editor Application")
        panel.prompt = L10n.t("Select")
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
