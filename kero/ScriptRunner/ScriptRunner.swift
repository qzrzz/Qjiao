//
//  ScriptRunner.swift
//  kero/ScriptRunner
//
//  Script Runner 主控制器与对外入口
//

import AppKit
import Foundation
import Combine

/// Files Tree 文件右键与编辑器底栏 Script Runner 主服务入口
@MainActor
final class ScriptRunner: ObservableObject {
    static let shared = ScriptRunner()

    /// 当前专用于 Script Runner 的分屏终端 Session（按 Project ID 维度记录）
    @Published private(set) var activeSplitSessionsByProject: [UUID: TerminalSession] = [:]

    /// 当前每个文件路径对应的终端 Session
    @Published private(set) var activeSessionsByPath: [String: TerminalSession] = [:]

    /// 当前正在运行脚本的文件路径（用于底栏按钮状态展示）
    @Published private(set) var currentRunningPath: String?

    private init() {}

    /// 检查指定文件路径是否支持 Script Runner 运行
    func canRun(filePath: String) -> Bool {
        ScriptRuntimeDetector.canRun(filePath: filePath)
    }

    /// 获取指定目标文件支持的修饰符列表
    func supportedModifiers(filePath: String) -> [ScriptRunModifier] {
        guard canRun(filePath: filePath) else { return [] }
        let ext = (filePath as NSString).pathExtension
        guard let lang = ScriptLanguage.from(fileExtension: ext) else { return [] }

        switch lang {
        case .javaScript, .typeScript:
            return [.none, .time, .inspect, .inspectBrk, .prof]
        case .python, .go, .rust:
            return [.none, .time]
        }
    }

    /// 检查特定路径的文件当前是否正在运行中
    func isRunning(filePath: String) -> Bool {
        guard currentRunningPath == filePath,
              let session = activeSessionsByPath[filePath] else {
            return false
        }
        return !session.hasExited
    }

    /// 生成结构化运行命令（纯逻辑无 UI 侧依赖）
    func buildRunCommand(
        filePath: String,
        modifier: ScriptRunModifier = .none,
        jsSetting: ScriptRunnerJSSetting? = nil,
        pythonSetting: ScriptRunnerPythonSetting? = nil,
        goSetting: ScriptRunnerGoSetting? = nil,
        rustSetting: ScriptRunnerRustSetting? = nil
    ) throws -> ScriptRunCommand {
        let settings = AppSettings.shared
        let js = jsSetting ?? settings.scriptRunnerJS
        let python = pythonSetting ?? settings.scriptRunnerPython
        let go = goSetting ?? settings.scriptRunnerGo
        let rust = rustSetting ?? settings.scriptRunnerRust

        let detection = try ScriptRuntimeDetector.detect(
            filePath: filePath,
            jsSetting: js,
            pythonSetting: python,
            goSetting: go,
            rustSetting: rust
        )
        return try ScriptCommandBuilder.build(
            detectionResult: detection,
            modifier: modifier
        )
    }

    /// 执行 Script Runner 任务（在新建 Tab 中运行）
    func run(
        filePath: String,
        modifier: ScriptRunModifier = .none,
        manager: TerminalManager? = nil
    ) throws {
        let command = try buildRunCommand(filePath: filePath, modifier: modifier)
        let effectiveManager = manager ?? TerminalManager.registry.first
        guard let project = effectiveManager?.selectedProject else {
            throw ScriptRunnerError.launchFailed(L10n.t("No active project"))
        }

        let session = try ScriptTerminalExecutor.shared.execute(
            command: command,
            targetPath: filePath,
            manager: manager,
            splitPane: false
        )
        trackSession(session, for: filePath, projectID: project.id)
    }

    /// 在当前标签页以上下分屏模式运行脚本（关闭上一次的运行分屏并重新分屏）
    func runInSplitPane(
        filePath: String,
        modifier: ScriptRunModifier = .none,
        manager: TerminalManager? = nil
    ) throws {
        let command = try buildRunCommand(filePath: filePath, modifier: modifier)
        let effectiveManager = manager ?? TerminalManager.registry.first
        guard let project = effectiveManager?.selectedProject else {
            throw ScriptRunnerError.launchFailed(L10n.t("No active project"))
        }

        let projectID = project.id

        // 1. 如果已有之前创建的运行分屏终端，直接关闭它
        if let existingSession = activeSplitSessionsByProject[projectID] {
            project.closeContent(.session(existingSession), terminate: true)
            activeSplitSessionsByProject.removeValue(forKey: projectID)
        }

        // 2. 新建一个标准的上下分屏终端 (.bottom) 运行代码
        let session = try ScriptTerminalExecutor.shared.execute(
            command: command,
            targetPath: filePath,
            manager: manager,
            splitPane: true
        )
        trackSession(session, for: filePath, projectID: projectID)
    }

    /// 停止指定文件路径正在运行的脚本（关闭运行分屏）
    func stop(filePath: String) {
        let effectiveManager = TerminalManager.registry.first
        guard let project = effectiveManager?.selectedProject else { return }

        if let existingSession = activeSessionsByPath[filePath] {
            project.closeContent(.session(existingSession), terminate: true)
            activeSessionsByPath.removeValue(forKey: filePath)
        }
        if currentRunningPath == filePath {
            currentRunningPath = nil
        }
    }

    /// 跟踪 Session 状态
    private func trackSession(_ session: TerminalSession, for filePath: String, projectID: UUID) {
        session.isTaskRunning = true
        activeSplitSessionsByProject[projectID] = session
        activeSessionsByPath[filePath] = session
        currentRunningPath = filePath

        session.onExited = { [weak self] exitedSession in
            Task { @MainActor in
                if self?.currentRunningPath == filePath {
                    self?.currentRunningPath = nil
                }
                if self?.activeSplitSessionsByProject[projectID]?.id == exitedSession.id {
                    self?.activeSplitSessionsByProject.removeValue(forKey: projectID)
                }
                if self?.activeSessionsByPath[filePath]?.id == exitedSession.id {
                    self?.activeSessionsByPath.removeValue(forKey: filePath)
                }
            }
        }
    }
}
