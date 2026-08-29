#!/usr/bin/env bun
/**
 * @file Debug 构建与本机测试脚本
 * @description 使用 Xcode 工具链编译 Debug 版本 Qjiao，默认单窗口启动供测试；可选 Time Profiler、Instruments GUI 及堆内存分析
 *
 * 使用方式：
 *   bun run debug              # 默认：编译并以前台单进程启动 Debug 版（一个窗口）
 *   bun run debug -- --record  # 使用 xctrace 录制 Time Profiler（启动 .app，Ctrl-C 结束并保存 .trace）
 *   bun run debug -- --gui     # 打开匹配版本的 Instruments，可手动选择分析模板
 *   bun run debug -- --heap    # 启用 MallocStackLogging 启动应用，支持使用 heap / leaks / malloc_history 分析内存
 */

import { $ } from "bun";
import { existsSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import chalk from "chalk";

/** 项目根目录绝对路径 */
const ROOT_DIR = resolve(import.meta.dir, "..");

/** Xcode 安装信息接口定义 */
interface XcodeInstall {
  /** Xcode.app 路径 */
  appPath: string;
  /** Developer 目录路径 (Contents/Developer) */
  developerDir: string;
  /** Instruments.app 路径 */
  instrumentsPath: string;
  /** 版本号字符串 (例如 "27.0") */
  version: string;
}

/**
 * 将版本号字符串解析为数字数组
 * @param {string} version 版本号字符串 (如 "16.2.0")
 * @returns {number[]} 解析后的数字数组
 */
function parseVersion(version: string): number[] {
  return version.split(".").map((part) => Number.parseInt(part, 10) || 0);
}

/**
 * 比较两个版本号的大小
 * @param {string} left 左侧版本号
 * @param {string} right 右侧版本号
 * @returns {number} left > right 返回正数，left < right 返回负数，相等返回 0
 */
function compareVersion(left: string, right: string): number {
  const a = parseVersion(left);
  const b = parseVersion(right);
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    const delta = (a[index] ?? 0) - (b[index] ?? 0);
    if (delta !== 0) return delta;
  }
  return 0;
}

/**
 * 执行子进程并捕获其 stdout 字符串输出
 * @param {string[]} command 待执行的命令参数数组
 * @returns {Promise<string>} stdout 文本
 */
async function captureCommand(command: string[]): Promise<string> {
  const proc = Bun.spawn(command, {
    cwd: ROOT_DIR,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  if (code !== 0) {
    throw new Error(`命令失败 (exit ${code}): ${command.join(" ")}\n${stderr.trim()}`);
  }
  return stdout.trim();
}

/**
 * 运行命令并在终端实时流式显示输出
 * @param {string[]} command 待执行的命令参数数组
 * @returns {Promise<void>}
 */
async function runCommand(command: string[]): Promise<void> {
  const proc = Bun.spawn(command, {
    cwd: ROOT_DIR,
    env: process.env,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await proc.exited;
  if (code !== 0) {
    throw new Error(`命令失败 (exit ${code}): ${command.join(" ")}`);
  }
}

/**
 * 从 Xcode.app 的 Info.plist 中读取 CFBundleShortVersionString 版本号
 * @param {string} appPath Xcode 应用包路径
 * @returns {Promise<string | null>} 版本号或 null
 */
async function readXcodeVersion(appPath: string): Promise<string | null> {
  try {
    return await captureCommand([
      "defaults",
      "read",
      join(appPath, "Contents/Info"),
      "CFBundleShortVersionString",
    ]);
  } catch {
    return null;
  }
}

/**
 * 根据 DEVELOPER_DIR 路径反推 Xcode.app 路径
 * @param {string} developerDir Developer 目录路径
 * @returns {string} Xcode.app 路径
 */
function appPathFromDeveloperDir(developerDir: string): string {
  return developerDir.replace(/\/Contents\/Developer\/?$/, "");
}

/**
 * 查找并解析系统中最合适的 Xcode 安装
 * 优先匹配环境变量 DEVELOPER_DIR，其次按版本号降序查找（优先 Xcode-beta.app）
 * @returns {Promise<XcodeInstall>} 匹配到的 Xcode 安装信息
 */
async function resolveXcode(): Promise<XcodeInstall> {
  const envDir = process.env.DEVELOPER_DIR;
  if (envDir && existsSync(envDir)) {
    const appPath = appPathFromDeveloperDir(envDir);
    return {
      appPath,
      developerDir: envDir,
      instrumentsPath: join(appPath, "Contents/Applications/Instruments.app"),
      version: (await readXcodeVersion(appPath)) ?? "0",
    };
  }

  const candidates = new Set<string>([
    "/Applications/Xcode-beta.app",
    "/Applications/Xcode.app",
  ]);

  try {
    for (const name of readdirSync("/Applications")) {
      if (/^Xcode.*\.app$/i.test(name)) {
        candidates.add(join("/Applications", name));
      }
    }
  } catch {
    // /Applications 目录无法读取时忽略，回退使用预设路径
  }

  const installs: XcodeInstall[] = [];
  for (const appPath of candidates) {
    const developerDir = join(appPath, "Contents/Developer");
    const instrumentsPath = join(appPath, "Contents/Applications/Instruments.app");
    if (!existsSync(developerDir) || !existsSync(instrumentsPath)) continue;
    const version = await readXcodeVersion(appPath);
    if (!version) continue;
    installs.push({ appPath, developerDir, instrumentsPath, version });
  }

  installs.sort((left, right) => compareVersion(right.version, left.version));
  if (installs.length === 0 || !installs[0]) {
    throw new Error("未找到可用的 Xcode / Instruments（Xcode.app 或 Xcode-beta.app）");
  }
  return installs[0];
}

/**
 * 检查系统是否已启用开发者模式 (Developer Mode)
 * @returns {Promise<boolean | null>} 启用返回 true，禁用返回 false，未知返回 null
 */
async function developerModeEnabled(): Promise<boolean | null> {
  try {
    const status = await captureCommand(["DevToolsSecurity", "-status"]);
    return !/disabled/i.test(status);
  } catch {
    return null;
  }
}

/**
 * 打印开发者模式未启用的警告提示
 */
function printDeveloperModeHelp(): void {
  console.warn(chalk.yellow("⚠️  Developer Mode 当前为关闭状态。"));
  console.warn(chalk.yellow("   请开启：系统设置 → 隐私与安全性 → 开发者模式"));
  console.warn(chalk.yellow("   或执行：sudo DevToolsSecurity -enable\n"));
}

/**
 * 打印 Allocations / Leaks 在当前系统版本中的已知限制与建议
 */
function printAllocationsBugHelp(): void {
  console.warn(chalk.yellow("⚠️  不要使用 Allocations / Leaks 模板。"));
  console.warn(chalk.yellow("   macOS 27 上 liboainject 无法解析 libsystem_pthread.dylib 的 _pthread_self，"));
  console.warn(chalk.yellow("   Instruments 会报 Failed to attach / missing bootstrapping symbols。"));
  console.warn(chalk.cyan("   CPU 分析：bun run debug -- --record（Time Profiler，推荐且稳定）。"));
  console.warn(chalk.cyan("   内存分析：bun run debug -- --heap，然后另开终端执行 heap <pid> / leaks <pid>。\n"));
}

/**
 * 检查当前进程参数中是否包含给定的 Flag 标志
 * @param {string[]} flags 标志列表
 * @returns {boolean} 是否命中任意 Flag
 */
function hasFlag(...flags: string[]): boolean {
  return flags.some((flag) => process.argv.includes(flag));
}

/**
 * 编译 Debug 版本的 Qjiao 应用程序
 * @returns {Promise<{ appPath: string; binaryPath: string }>} 产物路径信息
 */
async function buildDebugApp(): Promise<{ appPath: string; binaryPath: string }> {
  const projectPath = "Qjiao.xcodeproj";
  const scheme = "Qjiao";
  const configuration = "Debug";
  const derivedDataPath = "build/DerivedData";
  const appPath = join(ROOT_DIR, `${derivedDataPath}/Build/Products/${configuration}/Qjiao.app`);
  const binaryPath = join(appPath, "Contents/MacOS/Qjiao");

  console.log(chalk.yellow(`🔨 正在使用 Xcode 工具链编译 Debug 版本 (${scheme} - ${configuration})...`));

  // 调试构建与 dev 保持相同的缓存策略：锁定 Package.resolved、减少构建日志，
  // 并明确选择 Apple Silicon，避免 Xcode 反复匹配多个 macOS destination。
  const buildResult = await $`xcodebuild -quiet -disableAutomaticPackageResolution -project ${projectPath} -scheme ${scheme} -configuration ${configuration} -destination "platform=macOS,arch=arm64" -derivedDataPath ${derivedDataPath} build`.nothrow();

  if (buildResult.exitCode !== 0) {
    throw new Error(
      `项目编译失败 (Exit Code: ${buildResult.exitCode})。若刚更新了 SwiftPM 依赖，请先执行：xcodebuild -resolvePackageDependencies -project Qjiao.xcodeproj -scheme Qjiao -derivedDataPath build/DerivedData`,
    );
  }

  console.log(chalk.bold.green("✅ Debug 版本编译成功！"));

  if (!existsSync(binaryPath)) {
    throw new Error(`未找到 Debug 可执行文件: ${binaryPath}`);
  }

  return { appPath, binaryPath };
}

/**
 * 结束仍在运行的同路径 Debug 进程，避免再次启动时叠出第二个窗口
 * @param {string} binaryPath Debug 可执行文件绝对路径
 */
async function terminateExistingDebugApp(binaryPath: string): Promise<void> {
  const proc = Bun.spawn(["pgrep", "-f", binaryPath], {
    cwd: ROOT_DIR,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [code, stdout] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
  ]);
  if (code !== 0) return;
  const pids = stdout
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => /^\d+$/.test(line));
  if (pids.length === 0) return;
  console.log(chalk.yellow(`⚠️ 结束已在运行的 Debug 进程: ${pids.join(", ")}`));
  await Bun.spawn(["kill", ...pids], {
    cwd: ROOT_DIR,
    stdout: "inherit",
    stderr: "inherit",
  }).exited;
}

/**
 * 以前台单进程启动 Debug 应用，供本机功能测试
 * @param {string} binaryPath 二进制可执行文件绝对路径
 * @returns {Promise<void>}
 */
async function launchForTesting(binaryPath: string): Promise<void> {
  await terminateExistingDebugApp(binaryPath);
  console.log(chalk.bold.cyan("▸ 启动 Debug 应用（单窗口）…"));
  console.log(chalk.dim(`  可执行文件: ${binaryPath}`));
  console.log(chalk.dim("  关闭窗口或 Ctrl-C 结束本次测试。"));
  const child = Bun.spawn(
    [binaryPath, "-ApplePersistenceIgnoreState", "YES"],
    {
      cwd: ROOT_DIR,
      stdin: "inherit",
      stdout: "inherit",
      stderr: "inherit",
    },
  );
  const code = await child.exited;
  if (code !== 0) {
    throw new Error(`进程异常退出，退出码 ${code}`);
  }
}

/**
 * 使用 xctrace 录制 Time Profiler 跟踪数据
 * 必须启动 .app 而不是内部 Mach-O，否则 Launch Services 会再开一份同 bundle id 的实例
 * @param {string} appPath Qjiao.app 绝对路径
 * @returns {Promise<void>}
 */
async function recordTimeProfiler(appPath: string): Promise<void> {
  console.log(chalk.bold.cyan("▸ 启动 xctrace Time Profiler 录制…"));
  console.log(chalk.dim("  在 App 中操作复现性能场景后，按 Ctrl-C 结束录制，结果将自动生成 .trace 文件。"));
  console.log(chalk.dim(`  App 包路径: ${appPath}`));
  await runCommand([
    "xcrun",
    "xctrace",
    "record",
    "--template",
    "Time Profiler",
    "--launch",
    "--",
    appPath,
  ]);
}

/**
 * 启用 MallocStackLogging 环境变量启动应用，便于使用 heap / leaks 分析内存
 * @param {string} executablePath 二进制可执行文件绝对路径
 * @returns {Promise<void>}
 */
async function launchWithHeapLogging(executablePath: string): Promise<void> {
  console.log(chalk.bold.magenta("▸ 以 MallocStackLogging 模式启动应用程序（不经过 liboainject 注入）…"));
  const child = Bun.spawn([executablePath], {
    env: {
      ...process.env,
      MallocStackLogging: "1",
      MallocStackLoggingNoCompact: "1",
    },
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const pid = child.pid;
  console.log(chalk.bold.green(`  PID: ${pid}`));
  console.log(chalk.cyan("  可另开终端执行以下命令进行内存剖析："));
  console.log(chalk.blueBright(`    heap ${pid}`));
  console.log(chalk.blueBright(`    leaks ${pid}`));
  console.log(chalk.blueBright(`    malloc_history ${pid} -all_by_size`));
  const code = await child.exited;
  if (code !== 0) {
    throw new Error(`进程异常退出，退出码 ${code}`);
  }
}

/**
 * 主执行函数：解析 Xcode 环境，编译 Debug 应用并按模式启动
 */
async function main(): Promise<void> {
  console.log(chalk.bold.cyan("🚀 Qjiao Debug 构建与本机测试"));

  const xcode = await resolveXcode();
  process.env.DEVELOPER_DIR = xcode.developerDir;

  const guiMode = hasFlag("--gui", "-g");
  const heapMode = hasFlag("--heap", "--memory", "-m");
  const recordMode = hasFlag("--record", "-r");
  const developerMode = await developerModeEnabled();

  console.log(chalk.blue(`ℹ️ 命中 Xcode 版本: ${chalk.bold(xcode.version)} (${chalk.dim(xcode.appPath)})`));
  if (developerMode === false) {
    printDeveloperModeHelp();
    if (recordMode) {
      throw new Error("请先开启系统 Developer Mode 开发者模式后再使用 xctrace 录制");
    }
  }

  const { appPath, binaryPath } = await buildDebugApp();

  if (heapMode) {
    await terminateExistingDebugApp(binaryPath);
    await launchWithHeapLogging(binaryPath);
    return;
  }

  if (guiMode) {
    printAllocationsBugHelp();
    console.log(chalk.bold.cyan(`▸ 打开 Instruments ${xcode.version}…`));
    console.log(chalk.dim(`  App 包路径: ${appPath}`));
    console.log(chalk.yellow("  提示：请选择 Time Profiler 或 CPU Profiler 模板，再点击 Choose Target → 本 App → Record。"));
    // 不要把 .app 当作 open 的文档参数，否则 Instruments 和 Qjiao 会各开一份
    await runCommand(["open", "-a", xcode.instrumentsPath]);
    return;
  }

  if (recordMode) {
    await terminateExistingDebugApp(binaryPath);
    await recordTimeProfiler(appPath);
    return;
  }

  await launchForTesting(binaryPath);
}

main().catch((error) => {
  console.error(chalk.bold.red(`\n❌ ${error instanceof Error ? error.message : error}`));
  process.exit(1);
});
