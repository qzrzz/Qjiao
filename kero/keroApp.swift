//
//  keroApp.swift
//  kero
//

import SwiftUI

@main
struct keroApp: App {
    @NSApplicationDelegateAdaptor(QjiaoApplicationDelegate.self)
    private var applicationDelegate

    // Held here so Sparkle starts at launch and background checks run even if
    // the menu is never opened.
    @StateObject private var updater = Updater.shared
    @ObservedObject private var l10n = L10n.shared

    init() {
        // Qjiao's bundled executable also serves as the short-lived `qjiao`
        // automation client. Handle CLI-shaped invocations before creating
        // the normal SwiftUI scene; ordinary launches fall through.
        if CommandLine.arguments.count > 1 {
            _ = QjiaoCLIService.handleCommandLine(arguments: CommandLine.arguments)
        }
        _ = QjiaoCLIService.shared
        SubprocessRunner.boostFileDescriptorLimit()
        SubprocessRunner.startFDMonitor()
        DisplayCycleLayoutProtection.install()
        FileTreeModel.installDragEndMonitor()
        TerminalFont.registerBundledFonts()
        TerminalNotificationService.shared.configure()
        // 确保启动时已从 config 同步语言（AppSettings.shared 会触发加载）。
        _ = AppSettings.shared
    }

    var body: some Scene {
        WindowGroup("Qjiao", id: "main") {
            WindowRootView()
                .observeLocalization()
                .environment(\.l10nLanguage, l10n.language)
        }
        .windowStyle(.hiddenTitleBar)
        // Keep title-bar dragging away from interactive tabs. The empty
        // header surfaces opt in explicitly through WindowDragArea.
        .windowBackgroundDragBehavior(.disabled)
        .defaultSize(width: 900, height: 600)
        .commands {
            // 不用 Settings Scene（偏好面板类型），改为普通 Window 才能正确 hiddenTitleBar。
            SettingsCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            KeroCommands()
        }

        // 设置用独立 Window，而非 Settings Scene：
        // Settings 场景是专用 NSPanel 偏好窗，titlebarAppearsTransparent / fullSizeContentView
        // 等样式受限，左右分栏 + 透明标题栏会显得「窗口类型不对」。
        Window(L10n.t("Settings"), id: "settings") {
            SettingsView()
                .observeLocalization()
                .environment(\.l10nLanguage, l10n.language)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 696, height: 600)
    }
}

/// ⌘, 打开设置 Window（替代系统 Settings Scene 自动菜单项）。
private struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var l10n = L10n.shared

    var body: some Commands {
        let _ = l10n.language
        CommandGroup(replacing: .appSettings) {
            Button(L10n.t("Settings…")) {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// Root of one terminal window. Each window owns its own manager, which
/// claims the next unclaimed window snapshot; the first window to appear
/// reopens windows for any snapshots left over.
private struct WindowRootView: View {
    @StateObject private var manager = TerminalManager()
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ContentView(manager: manager)
            .focusedSceneObject(manager)
            .environment(\.l10nLanguage, l10n.language)
            // 与 config 中的 theme 对齐：首帧即正确，不依赖 NSApp 启动时序。
            .preferredColorScheme(settings.theme.preferredColorScheme)
            .onAppear {
                // 再套一次 appearance：App.init 阶段偶发写入过早，窗口出现后纠正。
                settings.applyAppearance()
                manager.refreshAppearance()
                TerminalManager.openRestoredWindows {
                    openWindow(id: "main")
                }
            }
            .onChange(of: settings.theme) {
                settings.applyAppearance()
                manager.refreshAppearance()
            }
            .onChange(of: colorScheme) {
                // System 模式下随 macOS 亮暗切换刷新终端配色。
                manager.refreshAppearance()
            }
            .onDisappear {
                manager.windowClosed()
            }
    }
}

/// Menu commands routed to the focused window's manager.
private struct KeroCommands: Commands {
    @FocusedObject private var manager: TerminalManager?
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 读取 language，语言切换时菜单标题刷新。
        let _ = l10n.language

        CommandGroup(replacing: .newItem) {
            Button(L10n.t("New Project")) {
                manager?.newProject()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(manager == nil)

            Button(L10n.t("New Session")) {
                manager?.newSession()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(manager == nil)

            Button(L10n.t("New Browser Tab")) {
                manager?.newBrowserTab()
            }
            .disabled(manager == nil)

            Button(L10n.t("New Window")) {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(L10n.t("Close Pane")) {
                // Cmd-W is app-wide: close a pane only when a main window with
                // an open project is key. Otherwise close the key window
                // itself — a non-main window (e.g. Settings), or a main window
                // showing the empty "No open projects" state with no tab left.
                if let manager, manager.selectedProject != nil,
                   NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true {
                    manager.closeSelectedTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button(L10n.t("Save")) {
                manager?.saveSelectedFile()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager == nil)

            Toggle(L10n.t("Auto Save"), isOn: autoSaveMenuBinding)
        }

        CommandGroup(after: .pasteboard) {
            // SwiftUI's Edit menu ships no Find submenu, so Kero owns these
            // outright. They act on the focused pane — Ghostty's search in a
            // terminal, STTextView's find bar in a file editor — rather than on
            // the first responder, which keeps them live while the find bar's
            // text field has keyboard focus. ⇧⌘G is already Toggle Git Panel,
            // so Find Previous is reachable by ⇧↩ in the bar instead.
            Menu(L10n.t("Find")) {
                Button(L10n.t("Search in Files…")) {
                    manager?.openSearchInFiles()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(manager?.selectedProject == nil)

                Divider()

                Button(L10n.t("Find…")) {
                    manager?.performFindAction(.show)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(manager?.canFind != true)

                Button(L10n.t("Find and Replace…")) {
                    manager?.performFindAction(.replace)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(manager?.canReplace != true)

                Button(L10n.t("Find Next")) {
                    manager?.performFindAction(.next)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(manager?.canFind != true)

                Button(L10n.t("Find Previous")) {
                    manager?.performFindAction(.previous)
                }
                .disabled(manager?.canFind != true)

                Button(L10n.t("Use Selection for Find")) {
                    manager?.performFindAction(.useSelection)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(manager?.canFind != true)
            }

            Divider()

            Button(L10n.t("Clear Terminal")) {
                manager?.clearActiveTerminal()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(manager?.canClearActiveTerminal != true)
        }

        // Frees ⌘P from the default Print item for the command palette.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .sidebar) {
            Button(L10n.t("Command Palette…")) {
                manager?.toggleCommandPalette()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(manager == nil)

            Divider()

            Button(L10n.t("Toggle Left Sidebar")) {
                manager?.toggleLeftSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(manager == nil)

            Button(L10n.t("Toggle Right Sidebar")) {
                manager?.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button(L10n.t("Toggle Files Panel")) {
                manager?.togglePanel(.files)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button(L10n.t("Toggle Git Panel")) {
                manager?.togglePanel(.git)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button(L10n.t("Toggle Info Panel")) {
                manager?.togglePanel(.info)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)
        }

        CommandMenu(L10n.t("Git")) {
            Button(L10n.t("Specify Git Repository Path…")) {
                manager?.selectCustomGitRepositoryPath()
            }
            .disabled(manager?.selectedProject == nil)

            if manager?.selectedProject?.customGitPath != nil {
                Button(L10n.t("Clear Custom Git Repository Path")) {
                    manager?.clearCustomGitRepositoryPath()
                }
                .disabled(manager?.selectedProject == nil)
            }
        }

        CommandMenu(L10n.t("Projects")) {
            Button(L10n.t("Next Project")) {
                manager?.selectNextProject()
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(manager == nil)

            Button(L10n.t("Previous Project")) {
                manager?.selectPreviousProject()
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(manager == nil)

            Divider()

            ForEach(Array((manager?.projects ?? []).prefix(9).enumerated()), id: \.element.id) { index, project in
                Button(project.name) {
                    manager?.selectProject(index: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }

        CommandMenu(L10n.t("Browser")) {
            Button(L10n.t("Focus Address Bar")) {
                manager?.focusBrowserAddressBar()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(manager?.hasSelectedBrowser != true)

            Button(L10n.t("Reload Page")) {
                manager?.reloadSelectedBrowser()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(manager?.hasSelectedBrowser != true)

            Button(L10n.t("Stop Loading")) {
                manager?.stopSelectedBrowser()
            }
            .disabled(manager?.hasSelectedBrowser != true)

            Divider()

            Button(L10n.t("Copy Address")) {
                manager?.copySelectedBrowserAddress()
            }
            .disabled(manager?.hasSelectedBrowser != true)

            Button(L10n.t("Open in Default Browser")) {
                manager?.openSelectedPageInDefaultBrowser()
            }
            .disabled(manager?.hasSelectedBrowser != true)
        }

        CommandMenu(L10n.t("Tabs")) {
            Button(L10n.t("Split Right")) {
                manager?.splitRight()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(manager?.canSplit != true)

            Button(L10n.t("Split Down")) {
                manager?.splitDown()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(manager?.canSplit != true)

            Button(L10n.t("Split Left")) {
                manager?.splitLeft()
            }
            .disabled(manager?.canSplit != true)

            Button(L10n.t("Split Up")) {
                manager?.splitUp()
            }
            .disabled(manager?.canSplit != true)

            Divider()

            Button(L10n.t("Focus Pane Left")) {
                manager?.focusPaneLeft()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button(L10n.t("Focus Pane Right")) {
                manager?.focusPaneRight()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button(L10n.t("Focus Pane Up")) {
                manager?.focusPaneUp()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button(L10n.t("Focus Pane Down")) {
                manager?.focusPaneDown()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button(L10n.t("Focus Previous Pane")) {
                manager?.focusPreviousPane()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(manager == nil)

            Button(L10n.t("Focus Next Pane")) {
                manager?.focusNextPane()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(manager == nil)

            Divider()

            Button(L10n.t("Toggle Pane Zoom")) {
                manager?.togglePaneZoom()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(manager?.hasSplitPanes != true)

            Button(L10n.t("Equalize Panes")) {
                manager?.equalizePanes()
            }
            .keyboardShortcut("=", modifiers: [.command, .control])
            .disabled(manager?.hasSplitPanes != true)

            Menu(L10n.t("Resize Pane")) {
                Button(L10n.t("Up")) {
                    manager?.resizePaneUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(manager?.hasSplitPanes != true)

                Button(L10n.t("Down")) {
                    manager?.resizePaneDown()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(manager?.hasSplitPanes != true)

                Button(L10n.t("Left")) {
                    manager?.resizePaneLeft()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(manager?.hasSplitPanes != true)

                Button(L10n.t("Right")) {
                    manager?.resizePaneRight()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(manager?.hasSplitPanes != true)
            }

            Divider()

            Button(L10n.t("Next Tab")) {
                manager?.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Button(L10n.t("Previous Tab")) {
                manager?.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Divider()

            ForEach(Array((manager?.selectedProject?.tabs ?? []).prefix(9).enumerated()), id: \.element.id) { index, tab in
                Button(tab.displayTitle ?? L10n.format("Tab %d", index + 1)) {
                    manager?.selectTab(index: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
        }
    }

    /// 文件菜单「Auto Save」：勾选开启 afterDelay，取消则关闭。设置里选了其它模式时菜单仍显示为已开启。
    private var autoSaveMenuBinding: Binding<Bool> {
        Binding(
            get: { settings.isAutoSaveEnabled },
            set: { settings.setAutoSaveEnabled($0) }
        )
    }
}
