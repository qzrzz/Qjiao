//
//  SoundEffects.swift
//  kero
//
//  应用内事件音效播放服务：命令运行结束 / 失败、Agent 完成时播放系统音效。
//  各事件可在 Settings → General → Sound Effects 中单独开关（AppSettings `ui.sound-*`）。
//

import AppKit
import Foundation

/// 应用内事件音效播放服务（主线程使用）。
///
/// 直接使用 macOS 内置系统音效（`/System/Library/Sounds`），随系统音量输出，
/// 不额外打包音频资源。用户可通过 `AppSettings` 的 `ui.sound-*` 配置开关。
@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    /// 事件类型。
    enum Kind {
        /// 终端命令成功结束（OSC 133;D 上报 exitCode == 0）。
        case commandSucceeded
        /// 终端命令失败 / 非零退出（OSC 133;D 上报 exitCode != 0）。
        case commandFailed
        /// Agent 从 working 转为 done。
        case agentCompleted

        /// 使用的系统音效名称（macOS 内建音效，位于 /System/Library/Sounds）。
        var soundName: String {
            switch self {
            case .commandSucceeded: return "Glass"
            case .commandFailed: return "Basso"
            case .agentCompleted: return "Tink"
            }
        }

        /// 对应的事件开关；总开关为 `AppSettings.soundEffectsEnabled`。
        var isEnabled: Bool {
            let settings = AppSettings.shared
            switch self {
            case .commandSucceeded: return settings.commandSucceededSoundEnabled
            case .commandFailed: return settings.commandFailedSoundEnabled
            case .agentCompleted: return settings.agentCompletedSoundEnabled
            }
        }
    }

    /// 同一事件类型的最短播放间隔，避免大量命令同时结束时音效叠爆。
    private static let minimumInterval: TimeInterval = 0.4
    private var lastPlayedAt: [Kind: Date] = [:]

    private init() {}

    /// 播放指定事件音效；未开启对应开关或间隔内已播放过则忽略。
    func play(_ kind: Kind) {
        guard AppSettings.shared.soundEffectsEnabled, kind.isEnabled else { return }
        preview(kind)
    }

    /// 试听指定事件音效（无视设置开关，设置页预览用）。
    func preview(_ kind: Kind) {
        let now = Date()
        if let last = lastPlayedAt[kind], now.timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        lastPlayedAt[kind] = now
        NSSound(named: kind.soundName)?.play()
    }
}
