//
//  ScriptRuntimeDetector.swift
//  kero/ScriptRunner
//
//  Script Runner Runtime 检测器
//

import Foundation

/// 负责识别文件语言、查找项目根目录、检测 Runtime 可执行文件并生成结构化检测结果
public struct ScriptRuntimeDetector: Sendable {

    /// 可执行文件路径检测缓存，避免重复 I/O 检查
    private static var executablePathCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// 检查指定文件路径是否支持 Script Runner 运行
    public static func canRun(filePath: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        let ext = (filePath as NSString).pathExtension
        return ScriptLanguage.from(fileExtension: ext) != nil
    }

    /// 核心检测逻辑
    /// - Parameters:
    ///   - filePath: 目标代码文件绝对路径
    ///   - jsSetting: JS/TS 设置
    ///   - pythonSetting: Python 设置
    ///   - goSetting: Go 设置
    ///   - rustSetting: Rust 设置
    /// - Returns: 结构化检测结果 ScriptRuntimeDetectionResult
    /// - Throws: ScriptRunnerError
    public static func detect(
        filePath: String,
        jsSetting: ScriptRunnerJSSetting = .auto,
        pythonSetting: ScriptRunnerPythonSetting = .auto,
        goSetting: ScriptRunnerGoSetting = .auto,
        rustSetting: ScriptRunnerRustSetting = .auto
    ) throws -> ScriptRuntimeDetectionResult {
        let fileManager = FileManager.default

        // 1. 验证文件存在性与类型
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: filePath, isDirectory: &isDir) else {
            throw ScriptRunnerError.fileNotFound(filePath)
        }
        if isDir.boolValue {
            throw ScriptRunnerError.isDirectory(filePath)
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let fileExt = fileURL.pathExtension
        guard let language = ScriptLanguage.from(fileExtension: fileExt) else {
            throw ScriptRunnerError.unsupportedFileType(fileExt)
        }

        let fileDirectory = fileURL.deletingLastPathComponent().path
        let fileName = fileURL.lastPathComponent

        // 2. 根据语言分支处理
        switch language {
        case .javaScript, .typeScript:
            return try detectJavaScriptTypeScript(
                filePath: filePath,
                fileDirectory: fileDirectory,
                fileName: fileName,
                language: language,
                setting: jsSetting
            )

        case .python:
            return try detectPython(
                filePath: filePath,
                fileDirectory: fileDirectory,
                fileName: fileName,
                setting: pythonSetting
            )

        case .go:
            return try detectGo(
                filePath: filePath,
                fileDirectory: fileDirectory,
                fileName: fileName,
                setting: goSetting
            )

        case .rust:
            return try detectRust(
                filePath: filePath,
                fileDirectory: fileDirectory,
                setting: rustSetting
            )
        }
    }

    // MARK: - JS / TS 检测

    private static func detectJavaScriptTypeScript(
        filePath: String,
        fileDirectory: String,
        fileName: String,
        language: ScriptLanguage,
        setting: ScriptRunnerJSSetting
    ) throws -> ScriptRuntimeDetectionResult {
        // 查找根目录（包含 package.json / bun.lock / tsconfig.json）
        let projectRoot = findProjectRoot(
            from: fileDirectory,
            indicatorFiles: ["bun.lock", "bun.lockb", "package.json", "tsconfig.json"]
        )
        let isBunProject = isBunProjectDirectory(projectRoot ?? fileDirectory)

        let workingDirectory = projectRoot ?? fileDirectory
        let relativeTarget = calculateRelativePath(from: workingDirectory, to: filePath)

        let bunAvailable = isExecutableAvailable("bun")
        let nodeAvailable = isExecutableAvailable("node")
        let tsxAvailable = isExecutableAvailable("tsx")

        let selectedRuntime: ScriptRuntime

        switch setting {
        case .bun:
            guard bunAvailable else {
                throw ScriptRunnerError.runtimeNotFound("bun")
            }
            selectedRuntime = .bun

        case .node:
            if language == .typeScript {
                // 普通 Node.js 原生无法直接运行 TypeScript 文件
                throw ScriptRunnerError.incompatibleRuntime(runtime: "node", fileType: language.rawValue)
            }
            guard nodeAvailable else {
                throw ScriptRunnerError.runtimeNotFound("node")
            }
            selectedRuntime = .node

        case .tsx:
            guard tsxAvailable else {
                throw ScriptRunnerError.runtimeNotFound("tsx")
            }
            selectedRuntime = .tsx

        case .auto:
            if language == .typeScript {
                // TS/TSX 优先 tsx，其次 bun，不得直接回退普通 node
                if tsxAvailable {
                    selectedRuntime = .tsx
                } else if bunAvailable {
                    selectedRuntime = .bun
                } else {
                    throw ScriptRunnerError.runtimeNotFound("tsx / bun")
                }
            } else {
                // JS/MJS 优先 Node.js，Bun 项目优先 Bun
                if isBunProject && bunAvailable {
                    selectedRuntime = .bun
                } else if nodeAvailable {
                    selectedRuntime = .node
                } else if bunAvailable {
                    selectedRuntime = .bun
                } else {
                    throw ScriptRunnerError.runtimeNotFound("node / bun")
                }
            }
        }

        return ScriptRuntimeDetectionResult(
            language: language,
            runtime: selectedRuntime,
            targetFilePath: relativeTarget,
            workingDirectory: workingDirectory,
            projectRoot: projectRoot,
            isBunProject: isBunProject
        )
    }

    // MARK: - Python 检测

    private static func detectPython(
        filePath: String,
        fileDirectory: String,
        fileName: String,
        setting: ScriptRunnerPythonSetting
    ) throws -> ScriptRuntimeDetectionResult {
        let projectRoot = findProjectRoot(
            from: fileDirectory,
            indicatorFiles: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"]
        )
        let workingDirectory = projectRoot ?? fileDirectory
        let relativeTarget = calculateRelativePath(from: workingDirectory, to: filePath)

        let uvAvailable = isExecutableAvailable("uv")
        let python3Available = isExecutableAvailable("python3")
        let pythonAvailable = isExecutableAvailable("python")

        let selectedRuntime: ScriptRuntime

        switch setting {
        case .uv:
            guard uvAvailable else {
                throw ScriptRunnerError.runtimeNotFound("uv")
            }
            selectedRuntime = .uv

        case .python:
            if python3Available {
                selectedRuntime = .python3
            } else if pythonAvailable {
                selectedRuntime = .python
            } else {
                throw ScriptRunnerError.runtimeNotFound("python3 / python")
            }

        case .auto:
            // 自动检测优先级: uv -> python3 -> python
            if uvAvailable {
                selectedRuntime = .uv
            } else if python3Available {
                selectedRuntime = .python3
            } else if pythonAvailable {
                selectedRuntime = .python
            } else {
                throw ScriptRunnerError.runtimeNotFound("Python / uv")
            }
        }

        return ScriptRuntimeDetectionResult(
            language: .python,
            runtime: selectedRuntime,
            targetFilePath: relativeTarget,
            workingDirectory: workingDirectory,
            projectRoot: projectRoot
        )
    }

    // MARK: - Go 检测

    private static func detectGo(
        filePath: String,
        fileDirectory: String,
        fileName: String,
        setting: ScriptRunnerGoSetting
    ) throws -> ScriptRuntimeDetectionResult {
        guard isExecutableAvailable("go") else {
            throw ScriptRunnerError.runtimeNotFound("go")
        }

        let goModRoot = findProjectRoot(from: fileDirectory, indicatorFiles: ["go.mod"])

        let workingDirectory: String
        let relativeTarget: String

        if let root = goModRoot {
            workingDirectory = root
            let rel = calculateRelativePath(from: root, to: filePath)
            if rel == fileName && fileDirectory == root {
                relativeTarget = "."
            } else {
                relativeTarget = rel.hasPrefix("./") ? rel : "./\(rel)"
            }
        } else {
            workingDirectory = fileDirectory
            relativeTarget = fileName
        }

        return ScriptRuntimeDetectionResult(
            language: .go,
            runtime: .go,
            targetFilePath: relativeTarget,
            workingDirectory: workingDirectory,
            projectRoot: goModRoot
        )
    }

    // MARK: - Rust 检测

    private static func detectRust(
        filePath: String,
        fileDirectory: String,
        setting: ScriptRunnerRustSetting
    ) throws -> ScriptRuntimeDetectionResult {
        let cargoRoot = findProjectRoot(from: fileDirectory, indicatorFiles: ["Cargo.toml"])
        guard let root = cargoRoot else {
            // 未找到 Cargo.toml -> 不支持运行单 Rust 文件
            throw ScriptRunnerError.singleRustFileNotSupported
        }

        guard isExecutableAvailable("cargo") else {
            throw ScriptRunnerError.runtimeNotFound("cargo")
        }

        return ScriptRuntimeDetectionResult(
            language: .rust,
            runtime: .cargo,
            targetFilePath: "Cargo.toml",
            workingDirectory: root,
            projectRoot: root
        )
    }

    // MARK: - 辅助工具

    /// 向上查找包含特定标志文件的最近项目根目录
    /// - Parameters:
    ///   - fileDirectory: 起始目录路径
    ///   - indicatorFiles: 标志文件名列表
    /// - Returns: 项目根目录绝对路径，若未找到则返回 nil
    public static func findProjectRoot(from fileDirectory: String, indicatorFiles: [String]) -> String? {
        var current = URL(fileURLWithPath: fileDirectory).standardizedFileURL.path
        let homeDir = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let fileManager = FileManager.default

        while !current.isEmpty {
            for indicator in indicatorFiles {
                let candidate = (current as NSString).appendingPathComponent(indicator)
                if fileManager.fileExists(atPath: candidate) {
                    return current
                }
            }

            // 避免向上越过用户 Home 目录或根目录
            if current == homeDir || current == "/" || current == "." {
                break
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current {
                break
            }
            current = parent
        }

        return nil
    }

    /// 判断目录是否为 Bun 项目
    public static func isBunProjectDirectory(_ dirPath: String) -> Bool {
        let fm = FileManager.default
        let bunLock1 = (dirPath as NSString).appendingPathComponent("bun.lock")
        let bunLock2 = (dirPath as NSString).appendingPathComponent("bun.lockb")
        if fm.fileExists(atPath: bunLock1) || fm.fileExists(atPath: bunLock2) {
            return true
        }

        let pkgPath = (dirPath as NSString).appendingPathComponent("package.json")
        if fm.fileExists(atPath: pkgPath),
           let data = fm.contents(atPath: pkgPath),
           let str = String(data: data, encoding: .utf8) {
            return str.contains("\"bun\"") || str.contains("packageManager") && str.contains("bun")
        }
        return false
    }

    /// 判断可执行程序在系统环境中是否存在
    /// - Parameter name: 可执行文件名称（如 "node", "bun", "python3"）
    /// - Returns: 布尔值，是否存在
    public static func isExecutableAvailable(_ name: String) -> Bool {
        cacheLock.lock()
        if let cached = executablePathCache[name] {
            cacheLock.unlock()
            return !cached.isEmpty
        }
        cacheLock.unlock()

        let foundPath = findExecutablePath(name: name)

        cacheLock.lock()
        executablePathCache[name] = foundPath ?? ""
        cacheLock.unlock()

        return foundPath != nil
    }

    /// 模拟底层 PATH 搜索可执行文件路径
    private static func findExecutablePath(name: String) -> String? {
        LocalAIExecutableLocator.findExecutable(name: name)
    }

    /// 计算绝对路径相对于工作目录的相对路径
    public static func calculateRelativePath(from baseDir: String, to filePath: String) -> String {
        let baseStandardized = URL(fileURLWithPath: baseDir).standardizedFileURL.path
        let fileStandardized = URL(fileURLWithPath: filePath).standardizedFileURL.path

        if fileStandardized == baseStandardized {
            return "."
        }

        let prefix = baseStandardized.hasSuffix("/") ? baseStandardized : baseStandardized + "/"
        if fileStandardized.hasPrefix(prefix) {
            return String(fileStandardized.dropFirst(prefix.count))
        }

        return filePath
    }
}
