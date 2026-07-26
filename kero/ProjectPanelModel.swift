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
    private var packageFileState: SidebarProbe.PackageFileState?
    private var gradleFileState: GradleFileState?
    private var justFileState: JustFileState?
    private var cargoFileState: CargoFileState?
    private var cmakeFileState: CMakeFileState?
    private var makefileFileState: MakefileFileState?
    private var packageLoadID = UUID()

    /// 当前用于进程聚合的 shell pid 集合（有序，便于比较）。
    private var shellPids: [pid_t] = []
    private var isRefreshingProcesses = false
    /// 每次启动采集递增，丢弃过期结果。
    private var processGeneration = 0

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
            packageFileState = nil
            gradleFileState = nil
            justFileState = nil
            cargoFileState = nil
            cmakeFileState = nil
            makefileFileState = nil
            if packageInfo != nil { packageInfo = nil }
            if !packageScripts.isEmpty { packageScripts = [] }
            if !gradleScripts.isEmpty { gradleScripts = [] }
            if !justScripts.isEmpty { justScripts = [] }
            if !cargoScripts.isEmpty { cargoScripts = [] }
            if !cmakeScripts.isEmpty { cmakeScripts = [] }
            if !makefileScripts.isEmpty { makefileScripts = [] }
            return
        }

        let state = SidebarProbe.packageFileState(directory: root)
        let gState = GradleScriptProvider.gradleFileState(directory: root)
        let jState = JustScriptProvider.justFileState(directory: root)
        let cState = CargoScriptProvider.cargoFileState(directory: root)
        let cmState = CMakeScriptProvider.cmakeFileState(directory: root)
        let mkState = MakefileScriptProvider.makefileFileState(directory: root)

        let needsSync = force
            || packageRoot != root
            || packageFileState != state
            || gradleFileState != gState
            || justFileState != jState
            || cargoFileState != cState
            || cmakeFileState != cmState
            || makefileFileState != mkState
            || (gState.isGradleProject && gradleScripts.isEmpty)
            || (jState.hasJustfile && justScripts.isEmpty)
            || (cState.isCargoProject && cargoScripts.isEmpty)
            || (cmState.isCMakeProject && cmakeScripts.isEmpty)
            || (mkState.hasMakefile && makefileScripts.isEmpty)

        guard needsSync else { return }

        packageRoot = root
        packageFileState = state
        gradleFileState = gState
        justFileState = jState
        cargoFileState = cState
        cmakeFileState = cmState
        makefileFileState = mkState
        let loadID = UUID()
        packageLoadID = loadID

        guard state.exists || gState.isGradleProject || jState.hasJustfile || cState.isCargoProject || cmState.isCMakeProject || mkState.hasMakefile else {
            if packageInfo != nil { packageInfo = nil }
            if !packageScripts.isEmpty { packageScripts = [] }
            if !gradleScripts.isEmpty { gradleScripts = [] }
            if !justScripts.isEmpty { justScripts = [] }
            if !cargoScripts.isEmpty { cargoScripts = [] }
            if !cmakeScripts.isEmpty { cmakeScripts = [] }
            if !makefileScripts.isEmpty { makefileScripts = [] }
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let info = SidebarProbe.loadPackageInfo(directory: root)
            let scripts = SidebarProbe.loadPackageScripts(directory: root)
            let gradle = await GradleScriptProvider().detectScripts(in: root)
            let just = await JustScriptProvider().detectScripts(in: root)
            let cargo = await CargoScriptProvider().detectScripts(in: root)
            let cmake = await CMakeScriptProvider().detectScripts(in: root)
            let makefile = await MakefileScriptProvider().detectScripts(in: root)
            await MainActor.run {
                guard let self, self.packageLoadID == loadID else { return }
                if self.packageInfo != info { self.packageInfo = info }
                if self.packageScripts != scripts { self.packageScripts = scripts }
                if self.gradleScripts != gradle { self.gradleScripts = gradle }
                if self.justScripts != just { self.justScripts = just }
                if self.cargoScripts != cargo { self.cargoScripts = cargo }
                if self.cmakeScripts != cmake { self.cmakeScripts = cmake }
                if self.makefileScripts != makefile { self.makefileScripts = makefile }
            }
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

        Task.detached(priority: .utility) { [weak self] in
            let (processes, ports) = SidebarProbe.collect(shellPids: expectedPids)
            await MainActor.run {
                guard let self else { return }
                // 仅最新一轮写回；中间被 force 打断的旧结果丢弃。
                if self.processGeneration == generation {
                    self.isRefreshingProcesses = false
                }
                guard self.processGeneration == generation,
                      self.shellPids == expectedPids else { return }
                if self.processes != processes { self.processes = processes }
                if self.ports != ports { self.ports = ports }
            }
        }
    }
}
