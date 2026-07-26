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
    private var packageFileState: SidebarProbe.PackageFileState?
    private var gradleFileState: GradleFileState?
    private var justFileState: JustFileState?
    private var cargoFileState: CargoFileState?
    private var cmakeFileState: CMakeFileState?
    private var makefileFileState: MakefileFileState?
    private var packageLoadID = UUID()

    private var isRefreshingProcesses = false
    private var processGeneration = 0

    func sync(cwd: String, shellName: String, shellPid: pid_t?) {
        if cwdPath != cwd { cwdPath = cwd }
        if self.shellName != shellName { self.shellName = shellName }
        let pid = shellPid ?? 0
        let pidChanged = self.shellPid != pid
        if pidChanged { self.shellPid = pid }

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
            packageFileState = nil
            gradleFileState = nil
            justFileState = nil
            cargoFileState = nil
            cmakeFileState = nil
            makefileFileState = nil
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
            if !packageScripts.isEmpty { packageScripts = [] }
            if !gradleScripts.isEmpty { gradleScripts = [] }
            if !justScripts.isEmpty { justScripts = [] }
            if !cargoScripts.isEmpty { cargoScripts = [] }
            if !cmakeScripts.isEmpty { cmakeScripts = [] }
            if !makefileScripts.isEmpty { makefileScripts = [] }
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let scripts = SidebarProbe.loadPackageScripts(directory: root)
            let gradle = await GradleScriptProvider().detectScripts(in: root)
            let just = await JustScriptProvider().detectScripts(in: root)
            let cargo = await CargoScriptProvider().detectScripts(in: root)
            let cmake = await CMakeScriptProvider().detectScripts(in: root)
            let makefile = await MakefileScriptProvider().detectScripts(in: root)
            await MainActor.run {
                guard let self, self.packageLoadID == loadID else { return }
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

        Task.detached(priority: .utility) { [weak self] in
            let (processes, ports) = SidebarProbe.collect(shellPids: [expectedPid])
            await MainActor.run {
                guard let self else { return }
                if self.processGeneration == generation {
                    self.isRefreshingProcesses = false
                }
                guard self.processGeneration == generation,
                      self.shellPid == expectedPid else { return }
                if self.processes != processes { self.processes = processes }
                if self.ports != ports { self.ports = ports }
            }
        }
    }
}
