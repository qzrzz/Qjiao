//
//  CustomThemeViews.swift
//  kero
//
//  自定义主题管理列表与编辑表单（Settings → Appearance）。
//

import AppKit
import GhosttyTheme
import SwiftUI

// MARK: - Settings row entry

/// Appearance 分区入口：列出自定义主题并打开编辑器。
struct CustomThemesSettingsSection: View {
    @ObservedObject private var store = CustomThemeStore.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var editor: EditorPresentation?

    private enum EditorPresentation: Identifiable, Equatable {
        case create(isDark: Bool, token: UUID = UUID())
        case edit(CustomTheme, token: UUID = UUID())

        var id: String {
            switch self {
            case .create(let isDark, let token): return "create-\(isDark)-\(token.uuidString)"
            case .edit(let theme, let token): return "edit-\(theme.id.uuidString)-\(token.uuidString)"
            }
        }
    }

    var body: some View {
        Section(L10n.t("Custom Themes")) {
            Group {
                if store.themes.isEmpty {
                    Text(L10n.t("No custom themes yet. Create one to set window colors and pair a Ghostty terminal theme."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(store.themes) { theme in
                        customThemeRow(theme)
                    }
                }
                HStack {
                    Spacer()
                    Menu {
                        Button(L10n.t("New Dark Theme…")) {
                            editor = .create(isDark: true)
                        }
                        Button(L10n.t("New Light Theme…")) {
                            editor = .create(isDark: false)
                        }
                    } label: {
                        Label(L10n.t("New Custom Theme"), systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .settingsRowPadding()
        }
        .sheet(item: $editor, onDismiss: {
            editor = nil
        }) { item in
            switch item {
            case .create(let isDark, _):
                CustomThemeEditorSheet(
                    draft: CustomTheme.makeDraft(isDark: isDark),
                    isNew: true,
                    onDismiss: { editor = nil }
                )
            case .edit(let theme, _):
                CustomThemeEditorSheet(
                    draft: theme,
                    isNew: false,
                    onDismiss: { editor = nil }
                )
            }
        }
        // 语言切换时刷新文案
        .environment(\.l10nLanguage, l10n.language)
    }

    private func customThemeRow(_ theme: CustomTheme) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: ThemePreviewImageRenderer.image(for: [theme.windowDefinition]))
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name)
                Text(theme.isDark ? L10n.t("Dark") : L10n.t("Light"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Text(theme.ghosttyTheme)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button(L10n.t("Edit")) {
                editor = .edit(theme)
            }
            .controlSize(.small)
            .help(L10n.t("Edit"))
            Button(role: .destructive) {
                try? CustomThemeStore.shared.delete(id: theme.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Delete"))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editor = .edit(theme)
        }
        .contextMenu {
            Button(L10n.t("Edit")) {
                editor = .edit(theme)
            }
            Button(role: .destructive) {
                try? CustomThemeStore.shared.delete(id: theme.id)
            } label: {
                Label(L10n.t("Delete"), systemImage: "trash")
            }
        }
    }
}

// MARK: - Editor sheet

struct CustomThemeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CustomTheme
    let isNew: Bool
    let onDismiss: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @State private var nameError: String?
    @State private var backgroundColor: Color
    @State private var foregroundColor: Color
    @State private var accentColor: Color

    init(draft: CustomTheme, isNew: Bool, onDismiss: @escaping () -> Void) {
        self._draft = State(initialValue: draft)
        self.isNew = isNew
        self.onDismiss = onDismiss
        self._backgroundColor = State(initialValue: Color(nsColor: draft.backgroundNSColor))
        self._foregroundColor = State(initialValue: Color(nsColor: draft.foregroundNSColor))
        self._accentColor = State(initialValue: Color(nsColor: draft.accentNSColor))
    }

    private func closeSheet() {
        dismiss()
        onDismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    TextField(L10n.t("Name"), text: $draft.name)
                    if let nameError {
                        Text(nameError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Picker(L10n.t("Appearance"), selection: $draft.isDark) {
                        Text(L10n.t("Dark")).tag(true)
                        Text(L10n.t("Light")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.isDark) { _, isDark in
                        // 切换亮暗时，若当前 Ghostty 主题不属于该侧，换为默认。
                        let ghostty = Theme.builtinOrGhosttyDefinition(named: draft.ghosttyTheme)
                        let ghosttyIsDark = ghostty?.isDark ?? isDark
                        if ghosttyIsDark != isDark {
                            draft.ghosttyTheme = isDark
                                ? Theme.defaultDarkThemeName
                                : Theme.defaultLightThemeName
                        }
                    }
                }

                Section(L10n.t("Window Colors")) {
                    colorRow(L10n.t("Background"), color: $backgroundColor) { ns in
                        draft.background = CustomTheme.hex(from: ns)
                    }
                    colorRow(L10n.t("Text"), color: $foregroundColor) { ns in
                        draft.foreground = CustomTheme.hex(from: ns)
                    }
                    Text(L10n.t("Used for sidebar, tabs, and panel labels."))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryColor)
                    colorRow(L10n.t("Accent"), color: $accentColor) { ns in
                        draft.accent = CustomTheme.hex(from: ns)
                    }
                    HStack {
                        Text(L10n.t("Preview"))
                        Spacer()
                        Image(nsImage: ThemePreviewImageRenderer.image(for: [
                            syncedWindowDefinition
                        ]))
                        .scaleEffect(1.4)
                    }
                }

                Section(L10n.t("Terminal Theme")) {
                    Text(L10n.t("Ghostty theme used for the terminal palette."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ghosttyPicker
                    Toggle(isOn: $draft.followBackground) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("Follow background color"))
                            Text(L10n.t("Use the custom theme background for the terminal background."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 420, height: 520)
        .observeLocalization()
        .environment(\.l10nLanguage, l10n.language)
    }

    private var header: some View {
        HStack {
            Text(isNew ? L10n.t("New Custom Theme") : L10n.t("Edit Custom Theme"))
                .font(.headline)
            Spacer()
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button(L10n.t("Delete"), role: .destructive) {
                    try? CustomThemeStore.shared.delete(id: draft.id)
                    closeSheet()
                }
            }
            Spacer()
            Button(L10n.t("Cancel")) { closeSheet() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("Save")) { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private var syncedWindowDefinition: GhosttyThemeDefinition {
        var t = draft
        t.background = CustomTheme.hex(from: NSColor(backgroundColor))
        t.foreground = CustomTheme.hex(from: NSColor(foregroundColor))
        t.accent = CustomTheme.hex(from: NSColor(accentColor))
        return t.windowDefinition
    }

    private func colorRow(
        _ title: String,
        color: Binding<Color>,
        onChange: @escaping (NSColor) -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: color.wrappedValue) { _, newValue in
                    onChange(NSColor(newValue))
                }
            Text("#\(CustomTheme.hex(from: NSColor(color.wrappedValue)))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var ghosttyPicker: some View {
        let dark = draft.isDark
        return Menu {
            ForEach(ThemeMenuCatalog.primary(dark: dark), id: \.self) { name in
                ghosttyItem(name, dark: dark)
            }
            Section(L10n.t("Cool")) {
                ForEach(ThemeMenuCatalog.cool(dark: dark), id: \.self) { name in
                    ghosttyItem(name, dark: dark)
                }
            }
            Section(L10n.t("Warm")) {
                ForEach(ThemeMenuCatalog.warm(dark: dark), id: \.self) { name in
                    ghosttyItem(name, dark: dark)
                }
            }
            Divider()
            Menu(dark ? L10n.t("All Dark Themes") : L10n.t("All Light Themes")) {
                ForEach(ThemeMenuCatalog.all(dark: dark), id: \.self) { name in
                    ghosttyItem(name, dark: dark)
                }
            }
        } label: {
            Label {
                Text(draft.ghosttyTheme)
            } icon: {
                Image(nsImage: ThemePreviewImageRenderer.image(for: [
                    Theme.builtinOrGhosttyDefinition(named: draft.ghosttyTheme)
                        ?? Theme.globalDefinition(dark: dark)
                ]))
            }
            .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
    }

    private func ghosttyItem(_ name: String, dark: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { draft.ghosttyTheme == name },
            set: { if $0 { draft.ghosttyTheme = name } }
        )) {
            Label {
                Text(name)
            } icon: {
                Image(nsImage: ThemePreviewImageRenderer.image(for: [
                    Theme.builtinOrGhosttyDefinition(named: name)
                        ?? Theme.globalDefinition(dark: dark)
                ]))
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func save() {
        var theme = draft
        theme.background = CustomTheme.hex(from: NSColor(backgroundColor))
        theme.foreground = CustomTheme.hex(from: NSColor(foregroundColor))
        theme.accent = CustomTheme.hex(from: NSColor(accentColor))
        theme.name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try CustomThemeStore.shared.save(theme)
            nameError = nil
            closeSheet()
        } catch {
            nameError = error.localizedDescription
        }
    }
}

// MARK: - Shared menu helpers

/// 主题选择菜单中的「自定义」分组内容。
@ViewBuilder
func customThemeMenuSection(
    dark: Bool,
    selection: String?,
    onSelect: @escaping (String) -> Void
) -> some View {
    let names = ThemeMenuCatalog.custom(dark: dark)
    if !names.isEmpty {
        Section(L10n.t("Custom")) {
            ForEach(names, id: \.self) { name in
                let definition = Theme.definition(named: name)
                    ?? Theme.globalDefinition(dark: dark)
                Toggle(isOn: Binding(
                    get: { selection == name },
                    set: { if $0 { onSelect(name) } }
                )) {
                    Label {
                        Text(name)
                    } icon: {
                        Image(nsImage: ThemePreviewImageRenderer.image(for: [definition]))
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
    }
}

private extension View {
    /// 与 SettingsView 内同名 helper 对齐的行内边距（本文件独立使用）。
    func settingsRowPadding() -> some View {
        padding(.vertical, 4)
            .padding(.horizontal, 8)
    }
}
