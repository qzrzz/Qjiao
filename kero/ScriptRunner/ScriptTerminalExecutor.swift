//
//  ScriptTerminalExecutor.swift
//  kero/ScriptRunner
//
//  Script Runner 终端执行器
//

import AppKit
import Foundation

/// 负责将 ScriptRunCommand 接入 Qjiao 现有 Terminal 与进程管理框架
@MainActor
final class ScriptTerminalExecutor {
    static let shared = ScriptTerminalExecutor()

    private init() {}

    /// 在终端中运行命令
    /// - Parameters:
    ///   - command: 强类型运行命令
    ///   - targetPath: 目标文件路径
    ///   - manager: 可选 TerminalManager 实例
    ///   - splitPane: 是否使用当前 Tab 上下分屏
    /// - Throws: ScriptRunnerError
    /// - Returns: 关联的 TerminalSession 实例
    @discardableResult
    func execute(
        command: ScriptRunCommand,
        targetPath: String,
        manager: TerminalManager? = nil,
        splitPane: Bool = false
    ) throws -> TerminalSession {
        guard let effectiveManager = manager ?? TerminalManager.registry.first,
              let project = effectiveManager.selectedProject else {
            throw ScriptRunnerError.launchFailed(L10n.t("No active project"))
        }

        let workingDir = !command.workingDirectory.isEmpty
            ? command.workingDirectory
            : (!project.projectDirectory.isEmpty ? project.projectDirectory : NSHomeDirectory())

        // 首次运行：分屏走当前 Tab 下方；非分屏新建独立 Tab。
        // 再次运行时的「原地替换」由 ScriptRunner / TerminalManager 在调用前处理。
        let session: TerminalSession
        if splitPane {
            if let splitSession = project.newSplitSession(directory: workingDir, toward: .bottom) {
                session = splitSession
            } else {
                session = project.newSession(directory: workingDir)
            }
        } else {
            session = project.newSession(directory: workingDir)
        }

        // 在终端显示并执行 Shell 命令
        let fullShellCmd = command.shellString
        session.sendCommandWhenReady(fullShellCmd + "\n")
        return session
    }
}
