//
//  SessionInfoModel.swift
//  kero
//

import Combine
import Foundation

/// 右侧 Info 面板：
/// - 路径 / npm scripts：当前终端 cwd
/// - 进程 / 端口：仅当前 session 的 shell 子孙
@MainActor
final class SessionInfoModel: nonisolated ObservableObject {
    typealias PackageScript = SidebarProbe.PackageScript
    typealias ProcessItem = SidebarProbe.ProcessItem
    typealias PortItem = SidebarProbe.PortItem

    @Published private(set) var cwdPath = ""
    @Published private(set) var shellName = ""
    @Published private(set) var shellPid: pid_t = 0
    @Published private(set) var packageScripts: [PackageScript] = []
    @Published private(set) var gradleScripts: [UniversalProjectScript] = []
    @Published private(set) var justScripts: [UniversalProjectScript] = []
    @Published private(set) var cargoScripts: [UniversalProjectScript] = []
    @Published private(set) var cmakeScripts: [UniversalProjectScript] = []
    @Published private(set) var makefileScripts: [UniversalProjectScript] = []
    @Published private(set) var processes: [ProcessItem] = []
    @Published private(set) var ports: [PortItem] = []

    private var packageRoot = ""
    private var scriptFileState: SidebarScriptFileState?
    private var packageLoadID = UUID()
    private var packageLoadTask: Task<Void, Never>?

    private var isRefreshingProcesses = false
    private var processGeneration = 0
    private var processTask: Task<Void, Never>?

    func sync(cwd: String, shellName: String, shellPid: pid_t?) {
        if cwdPath != cwd { cwdPath = cwd }
        if self.shellName != shellName { self.shellName = shellName }
        let pid = shellPid ?? 0
        let pidChanged = self.shellPid != pid
        if pidChanged {
            self.shellPid = pid
            clearProcessData()
        }

        syncPackageScripts(root: cwd)
        refreshProcesses(force: pidChanged)
    }

    /// 手动刷新：强制 scripts + 进程。
    func refresh() {
        syncPackageScripts(root: cwdPath, force: true)
        refreshProcesses(force: true)
    }

    func kill(_ pid: pid_t, force: Bool = false) {
        SidebarProbe.kill(pid, force: force)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshProcesses(force: true)
        }
    }

    // MARK: - Scripts（cwd 下 package.json / Gradle / Just / Cargo / CMake / Makefile Tasks）

    private func syncPackageScripts(root: String, force: Bool = false) {
        guard !root.isEmpty else {
            packageRoot = ""
            scriptFileState = nil
            packageLoadID = UUID()
            packageLoadTask?.cancel()
            clearScriptData()
            return
        }

        let state = SidebarPanelDataLoader.fileState(directory: root)
        let rootChanged = packageRoot != root

        let needsSync = force
            || rootChanged
            || scriptFileState != state
            || (state.gradle.isGradleProject && gradleScripts.isEmpty)
            || (state.just.hasJustfile && justScripts.isEmpty)
            || (state.cargo.isCargoProject && cargoScripts.isEmpty)
            || (state.cmake.isCMakeProject && cmakeScripts.isEmpty)
            || (state.makefile.hasMakefile && makefileScripts.isEmpty)

        guard needsSync else { return }

        packageRoot = root
        scriptFileState = state
        if rootChanged {
            clearScriptData()
        }
        let loadID = UUID()
        packageLoadID = loadID
        packageLoadTask?.cancel()

        guard state.hasAnyProjectFile else {
            clearScriptData()
            return
        }

        packageLoadTask = Task.detached(priority: .utility) { [self] in
            let catalog = await SidebarPanelDataLoader.load(
                directory: root,
                includePackageInfo: false
            )
            guard !Task.isCancelled else { return }
            await apply(catalog, loadID: loadID)
        }
    }

    // MARK: - Processes

    private func refreshProcesses(force: Bool) {
        let pid = shellPid
        guard pid > 0 else {
            if !processes.isEmpty { processes = [] }
            if !ports.isEmpty { ports = [] }
            return
        }
        if isRefreshingProcesses, !force { return }

        isRefreshingProcesses = true
        processGeneration &+= 1
        let generation = processGeneration
        let expectedPid = pid

        processTask?.cancel()
        processTask = Task.detached(priority: .utility) { [self] in
            let (processes, ports) = SidebarProbe.collect(shellPids: [expectedPid])
            guard !Task.isCancelled else { return }
            await apply(
                processes: processes,
                ports: ports,
                generation: generation,
                expectedPid: expectedPid
            )
        }
    }

    /// 切换 CWD 时立即清除旧目录的脚本列表。
    private func clearScriptData() {
        if !packageScripts.isEmpty { packageScripts = [] }
        if !gradleScripts.isEmpty { gradleScripts = [] }
        if !justScripts.isEmpty { justScripts = [] }
        if !cargoScripts.isEmpty { cargoScripts = [] }
        if !cmakeScripts.isEmpty { cmakeScripts = [] }
        if !makefileScripts.isEmpty { makefileScripts = [] }
    }

    /// 只发布发生变化的共享目录解析结果。
    private func apply(_ catalog: SidebarScriptCatalog, loadID: UUID) {
        guard packageLoadID == loadID else { return }
        if packageScripts != catalog.packageScripts { packageScripts = catalog.packageScripts }
        if gradleScripts != catalog.gradleScripts { gradleScripts = catalog.gradleScripts }
        if justScripts != catalog.justScripts { justScripts = catalog.justScripts }
        if cargoScripts != catalog.cargoScripts { cargoScripts = catalog.cargoScripts }
        if cmakeScripts != catalog.cmakeScripts { cmakeScripts = catalog.cmakeScripts }
        if makefileScripts != catalog.makefileScripts { makefileScripts = catalog.makefileScripts }
    }

    /// 切换 Session 时不再短暂保留上一终端的进程与端口。
    private func clearProcessData() {
        if !processes.isEmpty { processes = [] }
        if !ports.isEmpty { ports = [] }
    }

    /// 只接纳当前 Session 对应的后台结果。
    private func apply(
        processes newProcesses: [ProcessItem],
        ports newPorts: [PortItem],
        generation: Int,
        expectedPid: pid_t
    ) {
        if processGeneration == generation {
            isRefreshingProcesses = false
        }
        guard processGeneration == generation, shellPid == expectedPid else { return }
        if processes != newProcesses { processes = newProcesses }
        if ports != newPorts { ports = newPorts }
    }
}
