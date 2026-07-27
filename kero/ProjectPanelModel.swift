//
//  ProjectPanelModel.swift
//  kero
//

import Combine
import Foundation

/// 右侧 Project 面板：
/// - 路径 / npm scripts：项目根
/// - 进程 / 端口：项目下全部 session 的 shell 子孙并集
@MainActor
final class ProjectPanelModel: nonisolated ObservableObject {
    typealias PackageScript = SidebarProbe.PackageScript
    typealias PackageInfo = SidebarProbe.PackageInfo
    typealias ProcessItem = SidebarProbe.ProcessItem
    typealias PortItem = SidebarProbe.PortItem

    @Published private(set) var rootPath = ""
    @Published private(set) var packageInfo: PackageInfo?
    @Published private(set) var packageScripts: [PackageScript] = []
    @Published private(set) var gradleScripts: [UniversalProjectScript] = []
    @Published private(set) var justScripts: [UniversalProjectScript] = []
    @Published private(set) var cargoScripts: [UniversalProjectScript] = []
    @Published private(set) var cmakeScripts: [UniversalProjectScript] = []
    @Published private(set) var makefileScripts: [UniversalProjectScript] = []
    @Published private(set) var processes: [ProcessItem] = []
    @Published private(set) var ports: [PortItem] = []
    /// 参与聚合的 shell 数量（header 副标题）。
    @Published private(set) var sessionShellCount = 0

    private var packageRoot = ""
    private var scriptFileState: SidebarScriptFileState?
    private var packageLoadID = UUID()
    private var packageLoadTask: Task<Void, Never>?

    /// 当前用于进程聚合的 shell pid 集合（有序，便于比较）。
    private var shellPids: [pid_t] = []
    private var isRefreshingProcesses = false
    /// 每次启动采集递增，丢弃过期结果。
    private var processGeneration = 0
    private var processTask: Task<Void, Never>?

    /// - Parameters:
    ///   - root: 项目根路径
    ///   - shellPids: 项目内全部 session 的 shell pid
    func sync(root: String, shellPids: [pid_t]) {
        if rootPath != root { rootPath = root }
        let unique = Array(Set(shellPids.filter { $0 > 0 })).sorted()
        let pidsChanged = unique != self.shellPids
        if pidsChanged {
            self.shellPids = unique
            sessionShellCount = unique.count
            clearProcessData()
        }
        syncPackageScripts(root: root)
        // pid 集合变化或定时轮询都会走到这里；始终刷新进程视图。
        refreshProcesses(force: pidsChanged)
    }

    /// 手动刷新：强制重读 package.json / Gradle / Just / Cargo / CMake / Makefile Tasks + 进程。
    func refresh() {
        syncPackageScripts(root: rootPath, force: true)
        refreshProcesses(force: true)
    }

    func kill(_ pid: pid_t, force: Bool = false) {
        SidebarProbe.kill(pid, force: force)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshProcesses(force: true)
        }
    }

    // MARK: - Scripts

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
                includePackageInfo: true
            )
            guard !Task.isCancelled else { return }
            await apply(catalog, loadID: loadID)
        }
    }

    // MARK: - Processes

    private func refreshProcesses(force: Bool) {
        let pids = shellPids
        guard !pids.isEmpty else {
            if !processes.isEmpty { processes = [] }
            if !ports.isEmpty { ports = [] }
            return
        }
        // 非 force 时若已在采，跳过本轮，避免 2s timer 叠 ps/lsof。
        if isRefreshingProcesses {
            if force {
                // 强制刷新排队：当前轮结束后由 generation 保证目标 pid 仍有效即可。
            } else {
                return
            }
        }
        // force 时也允许并发一轮被跳过会导致卡死；改为取消语义：只认最新 generation。
        isRefreshingProcesses = true
        processGeneration &+= 1
        let generation = processGeneration
        let expectedPids = pids

        processTask?.cancel()
        processTask = Task.detached(priority: .utility) { [self] in
            let (processes, ports) = SidebarProbe.collect(shellPids: expectedPids)
            guard !Task.isCancelled else { return }
            await apply(
                processes: processes,
                ports: ports,
                generation: generation,
                expectedPids: expectedPids
            )
        }
    }

    /// 切换目录时立即清空旧目录内容，避免标题与列表来自不同项目。
    private func clearScriptData() {
        if packageInfo != nil { packageInfo = nil }
        if !packageScripts.isEmpty { packageScripts = [] }
        if !gradleScripts.isEmpty { gradleScripts = [] }
        if !justScripts.isEmpty { justScripts = [] }
        if !cargoScripts.isEmpty { cargoScripts = [] }
        if !cmakeScripts.isEmpty { cmakeScripts = [] }
        if !makefileScripts.isEmpty { makefileScripts = [] }
    }

    /// 只发布真正发生变化的目录解析结果。
    private func apply(_ catalog: SidebarScriptCatalog, loadID: UUID) {
        guard packageLoadID == loadID else { return }
        if packageInfo != catalog.packageInfo { packageInfo = catalog.packageInfo }
        if packageScripts != catalog.packageScripts { packageScripts = catalog.packageScripts }
        if gradleScripts != catalog.gradleScripts { gradleScripts = catalog.gradleScripts }
        if justScripts != catalog.justScripts { justScripts = catalog.justScripts }
        if cargoScripts != catalog.cargoScripts { cargoScripts = catalog.cargoScripts }
        if cmakeScripts != catalog.cmakeScripts { cmakeScripts = catalog.cmakeScripts }
        if makefileScripts != catalog.makefileScripts { makefileScripts = catalog.makefileScripts }
    }

    /// PID 根变化时不再短暂展示上一项目的进程与端口。
    private func clearProcessData() {
        if !processes.isEmpty { processes = [] }
        if !ports.isEmpty { ports = [] }
    }

    /// 只接纳最新 PID 集合对应的后台结果。
    private func apply(
        processes newProcesses: [ProcessItem],
        ports newPorts: [PortItem],
        generation: Int,
        expectedPids: [pid_t]
    ) {
        if processGeneration == generation {
            isRefreshingProcesses = false
        }
        guard processGeneration == generation, shellPids == expectedPids else { return }
        if processes != newProcesses { processes = newProcesses }
        if ports != newPorts { ports = newPorts }
    }
}
