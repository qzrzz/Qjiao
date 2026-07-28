//
//  TerminalHelpBar.swift
//  kero
//

import AppKit
import SwiftUI

/// 终端辅助帮助栏触发的模式类型。
enum TerminalHelpMode: String, CaseIterable, Identifiable {
    case vi

    var id: String { rawValue }
}

/// 终端帮助栏可执行的 Vi 操作。
enum TerminalHelpCommand {
    case saveAndExit
    case exitWithoutSaving
    case insertMode
    case normalMode
}

/// 挂载在终端窗格底部的状态栏视图（类似源码编辑器底部栏 EditorStatusBar）。
struct TerminalHelpBar: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        if settings.enableTerminalHelpBar {
            TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                if let mode = session.activeHelpMode {
                    content(for: mode)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: session.activeHelpMode != nil)
        }
    }

    @ViewBuilder
    private func content(for mode: TerminalHelpMode) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                switch mode {
                case .vi:
                    viHelpContent
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Color.primary.opacity(0.035))
        }
    }

    @ViewBuilder
    private var viHelpContent: some View {
        // [Save & Quit :wq] - 先按 Esc 强制返回命令模式，再执行 :wq\r 立即保存退出
        Button {
            session.executeHelpCommand(.saveAndExit)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 10, weight: .medium))
                Text(L10n.t("Save & Quit"))
                    .font(.system(size: 11, weight: .medium))
                Text(":wq")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(.secondary)
        .foregroundStyle(.primary)
        .macTooltip(L10n.t("Save changes and exit Vi"), position: .top)

        // [Quit Without Saving :q!] - 先按 Esc 强制返回命令模式，再执行 :q!\r 立即不保存退出
        Button {
            session.executeHelpCommand(.exitWithoutSaving)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10, weight: .medium))
                Text(L10n.t("Quit Without Saving"))
                    .font(.system(size: 11, weight: .medium))
                Text(":q!")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(.secondary)
        .foregroundStyle(.secondary)
        .macTooltip(L10n.t("Discard changes and exit Vi"), position: .top)

        // Spacer 分隔
        Spacer(minLength: 4)

        // [Edit(insert)] [Command(normal)]
        HStack(spacing: 6) {
            Button {
                session.executeHelpCommand(.insertMode)
            } label: {
                Text(L10n.t("Edit(insert)"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.secondary)
 

            Button {
                session.executeHelpCommand(.normalMode)
            } label: {
                Text(L10n.t("Command(normal)"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.secondary)
             
        }
    }
}
