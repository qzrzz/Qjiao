//
//  SoundEffects.swift
//  kero
//
//  应用内事件音效播放服务：命令运行结束 / 失败、Agent 完成时播放系统音效。
//  支持 macOS 系统音效与内置的 WindowsXP / Windows7 音效。
//  各事件可在 Settings → General → Sound Effects 中单独开关（AppSettings `ui.sound-*`）。
//

import AppKit
import Foundation

/// 单个音效条目。
struct SoundItem: Hashable, Identifiable {
    let category: String
    let fileName: String // 带前缀的真实文件名(无扩展名)
    let name: String     // 纯展示名称(去除前缀)

    var id: String { "\(category)/\(name)" }
}

/// 音效分类。
struct SoundCategory: Identifiable {
    let id: String
    let title: String
    let sounds: [SoundItem]
}

/// 应用内事件音效播放服务（主线程使用）。
@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    /// 获取所有音效分类与列表（macOS、WindowsXP、Windows7）。
    static let categories: [SoundCategory] = {
        let macSounds = scanMacOSSystemSounds()
        let xpSounds = scanCustomSounds(category: "WindowsXP", prefix: "XP_")
        let win7Sounds = scanCustomSounds(category: "Windows7", prefix: "Win7_")

        return [
            SoundCategory(id: "macOS", title: "macOS", sounds: macSounds),
            SoundCategory(id: "WindowsXP", title: "WindowsXP", sounds: xpSounds),
            SoundCategory(id: "Windows7", title: "Windows7", sounds: win7Sounds)
        ]
    }()

    /// 根据完整的 soundID（如 "WindowsXP/Windows XP Error" 或 "Glass"）获取显示名称（仅显示音效名称本身）。
    static func displayName(for soundID: String) -> String {
        let (_, name) = parseSoundID(soundID)
        return name
    }

    /// 解析 soundID 为 (category, name)
    static func parseSoundID(_ soundID: String) -> (category: String, name: String) {
        let parts = soundID.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return (parts[0], parts[1])
        } else {
            return ("macOS", soundID.isEmpty ? "Glass" : soundID)
        }
    }

    /// 事件类型。
    enum Kind {
        /// 终端命令成功结束（OSC 133;D 上报 exitCode == 0）。
        case commandSucceeded
        /// 终端命令失败 / 非零退出（OSC 133;D 上报 exitCode != 0）。
        case commandFailed
        /// Agent 从 working 转为 done。
        case agentCompleted
        /// Agent 转为 blocked（待用户处理 / 权限询问等）。
        case agentBlocked

        /// 使用的音效标识符（从 AppSettings 中获取配置）。
        var soundID: String {
            let settings = AppSettings.shared
            switch self {
            case .commandSucceeded: return settings.commandSucceededSoundName
            case .commandFailed: return settings.commandFailedSoundName
            case .agentCompleted: return settings.agentCompletedSoundName
            case .agentBlocked: return settings.agentBlockedSoundName
            }
        }

        /// 对应的事件开关；总开关为 `AppSettings.soundEffectsEnabled`。
        var isEnabled: Bool {
            let settings = AppSettings.shared
            switch self {
            case .commandSucceeded: return settings.commandSucceededSoundEnabled
            case .commandFailed: return settings.commandFailedSoundEnabled
            case .agentCompleted: return settings.agentCompletedSoundEnabled
            case .agentBlocked: return settings.agentBlockedSoundEnabled
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
        let now = Date()
        if let last = lastPlayedAt[kind], now.timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        lastPlayedAt[kind] = now
        playSound(soundID: kind.soundID)
    }

    /// 试听指定音效（无视设置开关，设置页预览使用）。
    func preview(_ soundID: String) {
        playSound(soundID: soundID)
    }

    /// 核心音效播放逻辑。
    private func playSound(soundID: String) {
        let (category, name) = Self.parseSoundID(soundID)

        if category == "macOS" {
            if let sound = NSSound(named: name) {
                sound.play()
                return
            }
            let sysPath = "/System/Library/Sounds/\(name).aiff"
            if let sound = NSSound(contentsOfFile: sysPath, byReference: true) {
                sound.play()
            }
        } else {
            if let url = Self.findAudioFileURL(category: category, name: name),
               let sound = NSSound(contentsOfFile: url.path, byReference: true) {
                sound.play()
            }
        }
    }

    /// 前缀规则。
    private static func filePrefix(for category: String) -> String {
        switch category {
        case "WindowsXP": return "XP_"
        case "Windows7": return "Win7_"
        default: return ""
        }
    }

    /// 定位音频资源文件 URL（包含 Bundle 资源路径与本地开发源码路径）。
    private static func findAudioFileURL(category: String, name: String) -> URL? {
        let prefix = filePrefix(for: category)
        let fileName = name.hasPrefix(prefix) ? name : "\(prefix)\(name)"

        // 1. Bundle 资源目录（无子目录或带有子目录）
        if let url = Bundle.main.url(forResource: fileName, withExtension: "wav", subdirectory: "Sounds/\(category)") ??
                     Bundle.main.url(forResource: fileName, withExtension: "wav") {
            return url
        }
        // 2. 本地项目源码相对路径
        let currentFileURL = URL(fileURLWithPath: #file)
        let keroDir = currentFileURL.deletingLastPathComponent()
        let localURL = keroDir.appendingPathComponent("Sounds").appendingPathComponent(category).appendingPathComponent("\(fileName).wav")
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        return nil
    }

    /// 扫描 macOS 内置系统音效。
    private static func scanMacOSSystemSounds() -> [SoundItem] {
        let fm = FileManager.default
        let soundsURL = URL(fileURLWithPath: "/System/Library/Sounds")
        var names: [String] = []
        if let files = try? fm.contentsOfDirectory(at: soundsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            names = files.compactMap { url -> String? in
                let ext = url.pathExtension.lowercased()
                guard ext == "aiff" || ext == "wav" else { return nil }
                return url.deletingPathExtension().lastPathComponent
            }.sorted()
        }
        if names.isEmpty {
            names = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
        }
        return names.map { SoundItem(category: "macOS", fileName: $0, name: $0) }
    }

    /// 扫描内置自定义音效（WindowsXP / Windows7），去掉前缀后生成展示名称。
    ///
    /// 兼容两种打包布局：
    /// 1. Xcode 同步文件夹会把 wav 拍平到 `Resources/` 根目录（`XP_*.wav` / `Win7_*.wav`）；
    /// 2. 文件夹引用方式打包时位于 `Resources/Sounds/<category>/` 子目录；
    /// 3. 本地开发时直接从源码目录扫描。
    private static func scanCustomSounds(category: String, prefix: String) -> [SoundItem] {
        let fm = FileManager.default
        var soundFileNames: Set<String> = []

        // 候选扫描目录：Bundle 子目录 → Bundle 根目录（拍平布局）→ 本地源码目录
        var candidateDirs: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidateDirs.append(resourceURL.appendingPathComponent("Sounds/\(category)"))
            candidateDirs.append(resourceURL)
        }
        let currentFileURL = URL(fileURLWithPath: #file)
        let keroDir = currentFileURL.deletingLastPathComponent()
        candidateDirs.append(keroDir.appendingPathComponent("Sounds").appendingPathComponent(category))

        for dir in candidateDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in files {
                guard url.pathExtension.lowercased() == "wav" else { continue }
                let rawFileName = url.deletingPathExtension().lastPathComponent
                // 根目录扫描时只收前缀匹配的，避免混入其它资源
                guard rawFileName.hasPrefix(prefix) else { continue }
                soundFileNames.insert(rawFileName)
            }
        }

        return soundFileNames.sorted().map { rawFileName in
            let cleanName: String
            if rawFileName.hasPrefix(prefix) {
                cleanName = String(rawFileName.dropFirst(prefix.count))
            } else {
                cleanName = rawFileName
            }
            return SoundItem(category: category, fileName: rawFileName, name: cleanName)
        }
    }
}
