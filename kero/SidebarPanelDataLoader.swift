//
//  SidebarPanelDataLoader.swift
//  kero
//

import Foundation

/** Project / Info 共用的脚本配置文件状态快照。 */
struct SidebarScriptFileState: Equatable {
    let package: SidebarProbe.PackageFileState
    let gradle: GradleFileState
    let just: JustFileState
    let cargo: CargoFileState
    let cmake: CMakeFileState
    let makefile: MakefileFileState

    var hasAnyProjectFile: Bool {
        package.exists
            || gradle.isGradleProject
            || just.hasJustfile
            || cargo.isCargoProject
            || cmake.isCMakeProject
            || makefile.hasMakefile
    }
}

/** Project / Info 共用的脚本目录加载结果。 */
struct SidebarScriptCatalog {
    let packageInfo: SidebarProbe.PackageInfo?
    let packageScripts: [SidebarProbe.PackageScript]
    let gradleScripts: [UniversalProjectScript]
    let justScripts: [UniversalProjectScript]
    let cargoScripts: [UniversalProjectScript]
    let cmakeScripts: [UniversalProjectScript]
    let makefileScripts: [UniversalProjectScript]
}

/** 集中处理右侧栏脚本文件状态与并行解析，避免两个 Model 演化出不同逻辑。 */
enum SidebarPanelDataLoader {
    /** 读取轻量文件元数据，用于跳过没有变化的完整解析。 */
    static func fileState(directory: String) -> SidebarScriptFileState {
        SidebarScriptFileState(
            package: SidebarProbe.packageFileState(directory: directory),
            gradle: GradleScriptProvider.gradleFileState(directory: directory),
            just: JustScriptProvider.justFileState(directory: directory),
            cargo: CargoScriptProvider.cargoFileState(directory: directory),
            cmake: CMakeScriptProvider.cmakeFileState(directory: directory),
            makefile: MakefileScriptProvider.makefileFileState(directory: directory)
        )
    }

    /** 并行解析互不依赖的任务来源；Project 可选择额外读取 package 元信息。 */
    nonisolated static func load(
        directory: String,
        includePackageInfo: Bool
    ) async -> SidebarScriptCatalog {
        async let gradle = GradleScriptProvider().detectScripts(in: directory)
        async let just = JustScriptProvider().detectScripts(in: directory)
        async let cargo = CargoScriptProvider().detectScripts(in: directory)
        async let cmake = CMakeScriptProvider().detectScripts(in: directory)
        async let makefile = MakefileScriptProvider().detectScripts(in: directory)

        let packageInfo = includePackageInfo
            ? SidebarProbe.loadPackageInfo(directory: directory)
            : nil
        let packageScripts = SidebarProbe.loadPackageScripts(directory: directory)

        return await SidebarScriptCatalog(
            packageInfo: packageInfo,
            packageScripts: packageScripts,
            gradleScripts: gradle,
            justScripts: just,
            cargoScripts: cargo,
            cmakeScripts: cmake,
            makefileScripts: makefile
        )
    }
}
