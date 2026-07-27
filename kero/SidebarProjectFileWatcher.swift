//
//  SidebarProjectFileWatcher.swift
//  kero
//

import Darwin
import Foundation

/**
 监听 Project / Info 面板关心的项目配置文件。

 同时监听配置文件与其所在目录：文件监听负责捕获内容写入，目录监听负责捕获编辑器常见的
 “写临时文件后原子替换”以及配置文件新增、删除。事件会短暂防抖，避免一次保存触发多次解析。
 */
@MainActor
final class SidebarProjectFileWatcher {
    private static let rootFileNames = [
        "package.json",
        "build.gradle",
        "build.gradle.kts",
        "settings.gradle",
        "settings.gradle.kts",
        "gradlew",
        "Justfile",
        "justfile",
        "Cargo.toml",
        "CMakeLists.txt",
        "Makefile",
        "makefile",
        "GNUmakefile",
    ]
    private static let ignoredDirectoryNames = Set([
        ".git",
        ".gradle",
        ".idea",
        "bin",
        "build",
        "node_modules",
        "obj",
        "out",
    ])

    private let onChange: () -> Void
    private var directory = ""
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /** 开始监听目录；目录未变化时保留现有监听器。 */
    func watch(directory: String) {
        let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard !directory.isEmpty else {
            stop()
            return
        }
        guard normalized != self.directory || sources.isEmpty else { return }
        stopSources()
        self.directory = normalized
        rebuildSources()
    }

    /** 面板不再需要文件信息时停止监听。 */
    func stop() {
        directory = ""
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        stopSources()
    }

    private func rebuildSources() {
        stopSources()
        guard !directory.isEmpty else { return }

        for path in watchedPaths(in: directory) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.scheduleChange()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            sources.append(source)
            source.resume()
        }
    }

    /**
     返回需要监听的目录和文件。

     Gradle 模块脚本只扫描项目根的下一层目录，因此无需递归监听整个仓库，避免大型项目产生
     不必要的文件描述符和事件。
     */
    private func watchedPaths(in root: String) -> [String] {
        let fileManager = FileManager.default
        var paths = Set([root])

        for name in Self.rootFileNames {
            let path = URL(fileURLWithPath: root).appendingPathComponent(name).path
            if fileManager.fileExists(atPath: path) {
                paths.insert(path)
            }
        }

        let cargoDirectory = URL(fileURLWithPath: root).appendingPathComponent(".cargo")
        if fileManager.fileExists(atPath: cargoDirectory.path) {
            paths.insert(cargoDirectory.path)
            for name in ["config", "config.toml"] {
                let path = cargoDirectory.appendingPathComponent(name).path
                if fileManager.fileExists(atPath: path) {
                    paths.insert(path)
                }
            }
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            guard !Self.ignoredDirectoryNames.contains(child.lastPathComponent),
                  (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            paths.insert(child.path)
            for name in ["build.gradle", "build.gradle.kts"] {
                let path = child.appendingPathComponent(name).path
                if fileManager.fileExists(atPath: path) {
                    paths.insert(path)
                }
            }
        }

        return paths.sorted()
    }

    private func scheduleChange() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.directory.isEmpty else { return }
            // 保存动作可能替换 inode；先重建监听器，再通知 Model 重读文件。
            self.rebuildSources()
            self.onChange()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func stopSources() {
        let currentSources = sources
        sources = []
        currentSources.forEach { $0.cancel() }
    }
}
