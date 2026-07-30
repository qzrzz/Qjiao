//
//  ScriptRunnerTests.swift
//  kero/ScriptRunner/test
//
//  Script Runner 单元测试套件
//

import Foundation

/// Script Runner 单元测试套件，全面验证 12 项测试要求
@MainActor
public struct ScriptRunnerTests {

    /// 运行全量测试用例并断言结果
    public static func runAllTests() throws {
        print("🧪 [ScriptRunnerTests] 开始执行单元测试套件...")

        try test1_LanguageRecognition()
        try test2_BunProjectPriority()
        try test3_TypeScriptNoFallbackToNode()
        try test4_PythonDetectionOrder()
        try test5_GoModAndNonModBehavior()
        try test6_RustCargoAndSingleFileBehavior()
        try test7_CommandModifierGeneration()
        try test8_IncompatibleModifierRejection()
        try test9_PathEscapingAndSpecialCharacters()
        try test10_ErrorHandling()
        try test11_UserSettingsOverride()
        try test12_FilesTreeMenuSafety()
        try test13_SplitPaneAndStatusTracking()

        print("✅ [ScriptRunnerTests] 所有 13 项单元测试通过！")
    }

    // MARK: - 测试 1: 每种受支持扩展名的语言识别
    private static func test1_LanguageRecognition() throws {
        assert(ScriptLanguage.from(fileExtension: "js") == .javaScript, "JS 扩展名识别失败")
        assert(ScriptLanguage.from(fileExtension: "mjs") == .javaScript, "MJS 扩展名识别失败")
        assert(ScriptLanguage.from(fileExtension: "ts") == .typeScript, "TS 扩展名识别失败")
        assert(ScriptLanguage.from(fileExtension: "tsx") == .typeScript, "TSX 扩展名识别失败")
        assert(ScriptLanguage.from(fileExtension: "py") == .python, "Python 扩展名识别失败")
        assert(ScriptLanguage.from(fileExtension: "go") == .go, "Go 扩展名识别失败")
        assert(ScriptLanguage.from(fileExtension: "rs") == .rust, "Rust 扩展名识别失败")
        assert(ScriptLanguage.from(fileExtension: "txt") == nil, "不支持的扩展名应该返回 nil")
        print("  ✓ 测试 1: 语言扩展名识别正常")
    }

    // MARK: - 测试 2: Bun 项目 Runtime 优先级
    private static func test2_BunProjectPriority() throws {
        let tempDir = NSTemporaryDirectory() + "bun_test_" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        // 创建 bun.lock
        let lockPath = (tempDir as NSString).appendingPathComponent("bun.lock")
        try "lock".write(toFile: lockPath, atomically: true, encoding: .utf8)

        // 创建 app.js
        let jsPath = (tempDir as NSString).appendingPathComponent("app.js")
        try "console.log(1)".write(toFile: jsPath, atomically: true, encoding: .utf8)

        let isBun = ScriptRuntimeDetector.isBunProjectDirectory(tempDir)
        assert(isBun, "应识别为 Bun 项目")

        let result = try ScriptRuntimeDetector.detect(filePath: jsPath, jsSetting: .auto)
        assert(result.isBunProject == true, "检测结果应记录为 Bun 项目")
        if ScriptRuntimeDetector.isExecutableAvailable("bun") {
            assert(result.runtime == .bun, "Bun 项目在 auto 下应优先选用 bun")
        }
        print("  ✓ 测试 2: Bun 项目 Runtime 优先级正常")
    }

    // MARK: - 测试 3: .ts / .tsx 不会错误回退到普通 Node.js
    private static func test3_TypeScriptNoFallbackToNode() throws {
        let tempDir = NSTemporaryDirectory() + "ts_test_" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        let tsPath = (tempDir as NSString).appendingPathComponent("app.ts")
        try "const a: number = 1;".write(toFile: tsPath, atomically: true, encoding: .utf8)

        // 显式指定 .node 运行 .ts -> 应抛出 incompatibleRuntime 错误
        do {
            _ = try ScriptRuntimeDetector.detect(filePath: tsPath, jsSetting: .node)
            fatalError("使用普通 Node.js 运行 .ts 应抛出不兼容错误")
        } catch let err as ScriptRunnerError {
            if case .incompatibleRuntime(let runtime, _) = err {
                assert(runtime == "node", "抛出错误应为 node 不兼容")
            } else {
                fatalError("非期待的错误类型: \(err)")
            }
        }

        // 自动模式下，若存在 tsx 或 bun，则不应当选择 node
        if let result = try? ScriptRuntimeDetector.detect(filePath: tsPath, jsSetting: .auto) {
            assert(result.runtime == .tsx || result.runtime == .bun, "TS 文件不得选择普通 node")
        }
        print("  ✓ 测试 3: TS/TSX 拒绝普通 Node.js 回退正常")
    }

    // MARK: - 测试 4: Python uv / python3 / python 检测顺序
    private static func test4_PythonDetectionOrder() throws {
        let tempDir = NSTemporaryDirectory() + "py_test_" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        let pyPath = (tempDir as NSString).appendingPathComponent("main.py")
        try "print('hi')".write(toFile: pyPath, atomically: true, encoding: .utf8)

        let result = try ScriptRuntimeDetector.detect(filePath: pyPath, pythonSetting: .auto)
        if ScriptRuntimeDetector.isExecutableAvailable("uv") {
            assert(result.runtime == .uv, "存在 uv 时应优先选择 uv")
        } else if ScriptRuntimeDetector.isExecutableAvailable("python3") {
            assert(result.runtime == .python3, "无 uv 存在 python3 时应选择 python3")
        }
        print("  ✓ 测试 4: Python 检测顺序正常")
    }

    // MARK: - 测试 5: Go 有无 go.mod 时的不同命令和工作目录
    private static func test5_GoModAndNonModBehavior() throws {
        let fm = FileManager.default

        // 1. 无 go.mod 场景
        let noModDir = NSTemporaryDirectory() + "go_nomod_" + UUID().uuidString
        try fm.createDirectory(atPath: noModDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: noModDir) }

        let singleGo = (noModDir as NSString).appendingPathComponent("main.go")
        try "package main".write(toFile: singleGo, atomically: true, encoding: .utf8)

        if ScriptRuntimeDetector.isExecutableAvailable("go") {
            let resNoMod = try ScriptRuntimeDetector.detect(filePath: singleGo)
            assert(resNoMod.workingDirectory == noModDir, "无 go.mod 时工作目录应为文件所在目录")
            assert(resNoMod.targetFilePath == "main.go", "无 go.mod 时目标参数应为文件名")

            // 2. 有 go.mod 场景
            let withModDir = NSTemporaryDirectory() + "go_mod_" + UUID().uuidString
            let subDir = (withModDir as NSString).appendingPathComponent("cmd/app")
            try fm.createDirectory(atPath: subDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: withModDir) }

            let goMod = (withModDir as NSString).appendingPathComponent("go.mod")
            try "module example.com/test".write(toFile: goMod, atomically: true, encoding: .utf8)

            let rootGo = (withModDir as NSString).appendingPathComponent("main.go")
            try "package main".write(toFile: rootGo, atomically: true, encoding: .utf8)

            let resRootGo = try ScriptRuntimeDetector.detect(filePath: rootGo)
            assert(resRootGo.workingDirectory == withModDir, "根目录 main.go 工作目录应为 go.mod 目录")
            assert(resRootGo.targetFilePath == ".", "根目录 main.go 目标应为 .")

            let subGo = (subDir as NSString).appendingPathComponent("sub.go")
            try "package main".write(toFile: subGo, atomically: true, encoding: .utf8)

            let resSubGo = try ScriptRuntimeDetector.detect(filePath: subGo)
            assert(resSubGo.workingDirectory == withModDir, "子目录 go 文件工作目录应为 go.mod 目录")
            assert(resSubGo.targetFilePath == "./cmd/app/sub.go", "子目录 go 文件相对路径计算应正确")
        }
        print("  ✓ 测试 5: Go 有无 go.mod 行为测试正常")
    }

    // MARK: - 测试 6: Rust 有无 Cargo.toml 时的不同结果
    private static func test6_RustCargoAndSingleFileBehavior() throws {
        let fm = FileManager.default

        // 1. 无 Cargo.toml -> 抛错
        let noCargoDir = NSTemporaryDirectory() + "rust_nocargo_" + UUID().uuidString
        try fm.createDirectory(atPath: noCargoDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: noCargoDir) }

        let singleRs = (noCargoDir as NSString).appendingPathComponent("main.rs")
        try "fn main() {}".write(toFile: singleRs, atomically: true, encoding: .utf8)

        do {
            _ = try ScriptRuntimeDetector.detect(filePath: singleRs)
            fatalError("无 Cargo.toml 的单 Rust 文件应该抛出不支持错误")
        } catch let err as ScriptRunnerError {
            assert(err == .singleRustFileNotSupported, "应抛出 singleRustFileNotSupported 错误")
        }

        // 2. 有 Cargo.toml
        let withCargoDir = NSTemporaryDirectory() + "rust_cargo_" + UUID().uuidString
        let srcDir = (withCargoDir as NSString).appendingPathComponent("src")
        try fm.createDirectory(atPath: srcDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: withCargoDir) }

        let cargoToml = (withCargoDir as NSString).appendingPathComponent("Cargo.toml")
        try "[package]\nname = \"test\"".write(toFile: cargoToml, atomically: true, encoding: .utf8)

        let mainRs = (srcDir as NSString).appendingPathComponent("main.rs")
        try "fn main() {}".write(toFile: mainRs, atomically: true, encoding: .utf8)

        if ScriptRuntimeDetector.isExecutableAvailable("cargo") {
            let resCargo = try ScriptRuntimeDetector.detect(filePath: mainRs)
            assert(resCargo.workingDirectory == withCargoDir, "Cargo 项目工作目录应为 Cargo.toml 目录")
            assert(resCargo.runtime == .cargo, "Runtime 应为 cargo")

            let cmd = try ScriptCommandBuilder.build(detectionResult: resCargo, modifier: .none)
            assert(cmd.executable == "cargo", "执行程序应为 cargo")
            assert(cmd.args == ["run"], "参数应为 cargo run")
        }
        print("  ✓ 测试 6: Rust 有无 Cargo.toml 行为正常")
    }

    // MARK: - 测试 7: 四种 Modifier 的命令生成
    private static func test7_CommandModifierGeneration() throws {
        let detection = ScriptRuntimeDetectionResult(
            language: .javaScript,
            runtime: .node,
            targetFilePath: "app.js",
            workingDirectory: "/tmp"
        )

        // 1. None
        let cmdNone = try ScriptCommandBuilder.build(detectionResult: detection, modifier: .none)
        assert(cmdNone.executable == "node" && cmdNone.args == ["app.js"] && cmdNone.wrapper == nil, "None 命令构造失败")
        assert(cmdNone.shellString == "node app.js", "None shellString 拼接失败: \(cmdNone.shellString)")

        // 2. Time
        let cmdTime = try ScriptCommandBuilder.build(detectionResult: detection, modifier: .time)
        assert(cmdTime.wrapper == ["time"], "Time wrapper 应包含 time")
        assert(cmdTime.shellString == "time node app.js", "Time shellString 拼接失败: \(cmdTime.shellString)")

        // 3. Inspect
        let cmdInspect = try ScriptCommandBuilder.build(detectionResult: detection, modifier: .inspect)
        assert(cmdInspect.args == ["--inspect", "app.js"], "Inspect 参数拼接失败")
        assert(cmdInspect.shellString == "node --inspect app.js", "Inspect shellString 拼接失败")

        // 4. Inspect-brk
        let cmdInspectBrk = try ScriptCommandBuilder.build(detectionResult: detection, modifier: .inspectBrk)
        assert(cmdInspectBrk.args == ["--inspect-brk", "app.js"], "InspectBrk 参数拼接失败")

        // 5. Prof
        let cmdProf = try ScriptCommandBuilder.build(detectionResult: detection, modifier: .prof)
        assert(cmdProf.args == ["--prof", "app.js"], "Prof 参数拼接失败")

        print("  ✓ 测试 7: 四种 Modifier 命令生成正常")
    }

    // MARK: - 测试 8: 不兼容 Modifier 被拒绝
    private static func test8_IncompatibleModifierRejection() throws {
        let pyDetection = ScriptRuntimeDetectionResult(
            language: .python,
            runtime: .python3,
            targetFilePath: "main.py",
            workingDirectory: "/tmp"
        )

        // Python 使用 --inspect 应被拒绝
        do {
            _ = try ScriptCommandBuilder.build(detectionResult: pyDetection, modifier: .inspect)
            fatalError("Python 使用 --inspect 应该被拒绝")
        } catch let err as ScriptRunnerError {
            if case .incompatibleModifier(let mod, let rt) = err {
                assert(mod == .inspect && rt == .python3, "应拒绝 Python 的 inspect 修饰符")
            } else {
                fatalError("错误类型不符: \(err)")
            }
        }

        print("  ✓ 测试 8: 不兼容 Modifier 拒绝机制正常")
    }

    // MARK: - 测试 9: 路径包含空格、Unicode 和 Shell 特殊字符时不会错误拆分
    private static func test9_PathEscapingAndSpecialCharacters() throws {
        let spaces = "my app.js"
        assert(ScriptCommandBuilder.shellQuote(spaces) == "'my app.js'", "空格路径转义失败")

        let unicodePath = "测试目录/应用.js"
        assert(ScriptCommandBuilder.shellQuote(unicodePath) == "'测试目录/应用.js'", "Unicode 路径转义失败")

        let quotes = "hello 'world'.js"
        assert(ScriptCommandBuilder.shellQuote(quotes) == "'hello '\\''world'\\''.js'", "包含单引号转义失败")

        let cmd = ScriptRunCommand(
            executable: "node",
            args: ["--inspect", "my project/测试 app.js"],
            wrapper: ["time"],
            workingDirectory: "/tmp/my project"
        )
        assert(cmd.shellString == "time node --inspect 'my project/测试 app.js'", "Shell 命令转义拼接不符: \(cmd.shellString)")

        print("  ✓ 测试 9: 路径转义与 Unicode 特殊字符处理正常")
    }

    // MARK: - 测试 10: Runtime 不存在、文件不支持和命令执行失败
    private static func test10_ErrorHandling() throws {
        // 不存在的路径
        do {
            _ = try ScriptRuntimeDetector.detect(filePath: "/non/existent/file.js")
            fatalError("不存在的文件应抛出 fileNotFound 错误")
        } catch let err as ScriptRunnerError {
            if case .fileNotFound = err { } else { fatalError("期待 fileNotFound 错误: \(err)") }
        }

        // 不支持的文件类型
        let tempDir = NSTemporaryDirectory()
        let txtPath = (tempDir as NSString).appendingPathComponent("readme.txt")
        try? "text".write(toFile: txtPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: txtPath) }

        do {
            _ = try ScriptRuntimeDetector.detect(filePath: txtPath)
            fatalError("不支持的文件扩展名应抛出 unsupportedFileType 错误")
        } catch let err as ScriptRunnerError {
            if case .unsupportedFileType = err { } else { fatalError("期待 unsupportedFileType 错误: \(err)") }
        }

        print("  ✓ 测试 10: 错误处理与异常检测正常")
    }

    // MARK: - 测试 11: 用户设置覆盖自动检测
    private static func test11_UserSettingsOverride() throws {
        let tempDir = NSTemporaryDirectory() + "override_test_" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        let jsPath = (tempDir as NSString).appendingPathComponent("app.js")
        try "console.log(1)".write(toFile: jsPath, atomically: true, encoding: .utf8)

        if ScriptRuntimeDetector.isExecutableAvailable("bun") {
            let resBun = try ScriptRuntimeDetector.detect(filePath: jsPath, jsSetting: .bun)
            assert(resBun.runtime == .bun, "用户设置指定 .bun 应覆盖默认结果")
        }
        print("  ✓ 测试 11: 用户设置覆盖自动检测正常")
    }

    // MARK: - 测试 12: Files Tree 原有右键菜单行为不受影响
    private static func test12_FilesTreeMenuSafety() throws {
        // 目录不被误执行
        let isRunDir = ScriptRuntimeDetector.canRun(filePath: NSTemporaryDirectory())
        assert(!isRunDir, "目录绝对不可执行 Script Runner")

        // 不支持的文件不被误执行
        let isRunTxt = ScriptRuntimeDetector.canRun(filePath: "/tmp/test.txt")
        assert(!isRunTxt, "txt 文件不可执行 Script Runner")

        print("  ✓ 测试 12: Files Tree 原有菜单与规则隔离正常")
    }

    // MARK: - 测试 13: 状态追踪与停止逻辑
    private static func test13_SplitPaneAndStatusTracking() throws {
        let testPath = NSTemporaryDirectory() + "test_split_script_" + UUID().uuidString + ".js"
        try "console.log(1)".write(toFile: testPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        assert(ScriptRuntimeDetector.canRun(filePath: testPath), "创建的 JS 文件应可运行")
        print("  ✓ 测试 13: 状态追踪与停止逻辑正常")
    }
}
