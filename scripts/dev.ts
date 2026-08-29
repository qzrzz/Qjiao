#!/usr/bin/env bun
/**
 * @file 开发模式调试运行脚本
 * @description 使用 Xcode 工具链 (Swift/xcodebuild) 编译，并在前台直接运行 Qjiao 二进制，实时输出控制台 Logs 与 Crash Trace 崩溃报告
 */

import { $ } from "bun";
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import chalk from "chalk";

const BUILD_STAMP_PATH = "build/DerivedData/.qjiao-dev-build-stamp";
const BUILD_STAMP_VERSION = 2;
const BUILD_INPUT_PATHS = [
  "kero",
  "Vendor",
  "icon",
  "Qjiao.xcodeproj/project.pbxproj",
  "Qjiao.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
  "Qjiao.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
  "Qjiao.xcodeproj/xcshareddata/xcschemes/Qjiao.xcscheme",
  "scripts/dev.ts",
];
const IGNORED_INPUT_DIRECTORIES = new Set([
  ".build",
  ".git",
  ".swiftpm",
  "build",
  "node_modules",
  "zig-out",
]);

/**
 * 返回目录树中最新输入的修改时间；构建产物与 Git 元数据不参与判断。
 */
function newestModificationTime(path: string): number {
  const stat = statSync(path, { throwIfNoEntry: false });
  if (!stat) return Number.POSITIVE_INFINITY;
  if (!stat.isDirectory()) return stat.mtimeMs;

  let newest = stat.mtimeMs;
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    if (entry.name === ".DS_Store" || IGNORED_INPUT_DIRECTORIES.has(entry.name)) continue;
    newest = Math.max(newest, newestModificationTime(`${path}/${entry.name}`));
  }
  return newest;
}

/**
 * 构造 Debug 产物的工具链与构建参数签名。
 */
function buildStampContents(developerDir: string | undefined): string {
  const xcodeInfoPath = developerDir
    ? `${developerDir}/Contents/Info.plist`
    : undefined;
  let xcodeInfoMTime: number | "unknown" = "unknown";
  if (xcodeInfoPath) {
    try {
      xcodeInfoMTime = statSync(xcodeInfoPath, { throwIfNoEntry: false })?.mtimeMs ?? "unknown";
    } catch {
      // 无法读取版本信息时保留 unknown；路径本身仍会参与签名。
    }
  }
  return [
    `version=${BUILD_STAMP_VERSION}`,
    `developerDir=${developerDir ?? "xcode-select"}`,
    `xcodeInfoMTime=${xcodeInfoMTime}`,
    "configuration=Debug",
    "destination=platform=macOS,arch=arm64",
  ].join("\n") + "\n";
}

function needsBuild(binaryPath: string, expectedStamp: string): boolean {
  if (process.env.QJIAO_FORCE_BUILD === "1" || !existsSync(binaryPath) || !existsSync(BUILD_STAMP_PATH)) {
    return true;
  }

  let stamp: number;
  try {
    if (readFileSync(BUILD_STAMP_PATH, "utf8") !== expectedStamp) return true;
    stamp = statSync(BUILD_STAMP_PATH).mtimeMs;
  } catch {
    return true;
  }
  return BUILD_INPUT_PATHS.some((path) => newestModificationTime(path) > stamp);
}

/**
 * 获取可用的 Xcode 开发者目录
 * 优先检查 Xcode-beta.app（适配当前开发环境），其次检查 Xcode.app
 * @returns {string | undefined} Xcode 路径或 undefined
 */
function getDeveloperDir(): string | undefined {
  const betaPath = "/Applications/Xcode-beta.app";
  const standardPath = "/Applications/Xcode.app";

  if (existsSync(betaPath)) {
    return betaPath;
  }
  if (existsSync(standardPath)) {
    return standardPath;
  }
  return undefined;
}

/**
 * 主执行函数：编译并在终端调试模式下运行 Qjiao 应用程序
 */
async function main() {
  console.log(chalk.bold.cyan("🚀 开始启动 Qjiao 开发环境 (调试模式)..."));

  const developerDir = getDeveloperDir();
  if (developerDir) {
    console.log(chalk.blue(`ℹ️ 使用 Xcode SDK 路径: ${chalk.bold(developerDir)}`));
    process.env.DEVELOPER_DIR = developerDir;
  } else {
    console.log(chalk.yellow("⚠️ 未找到特定 Xcode 应用包，使用系统默认 xcodebuild"));
  }
  const expectedBuildStamp = buildStampContents(developerDir);

  const projectPath = "Qjiao.xcodeproj";
  const scheme = "Qjiao";
  const configuration = "Debug";
  const derivedDataPath = "build/DerivedData";
  const appPath = `${derivedDataPath}/Build/Products/${configuration}/Qjiao.app`;
  const binaryPath = `${appPath}/Contents/MacOS/Qjiao`;

  try {
    if (needsBuild(binaryPath, expectedBuildStamp)) {
      console.log(chalk.yellow(`🔨 正在使用 Swift/Xcode 工具链编译项目 (${scheme} - ${configuration})...`));

      // 开发启动固定使用 lockfile 中的依赖，避免每次都尝试更新 SwiftPM 包；
      // -quiet 显著减少 100+ target 图及资源处理日志的终端渲染开销。
      const buildResult = await $`xcodebuild -quiet -disableAutomaticPackageResolution -project ${projectPath} -scheme ${scheme} -configuration ${configuration} -destination "platform=macOS,arch=arm64" -derivedDataPath ${derivedDataPath} build`.nothrow();

      if (buildResult.exitCode !== 0) {
        console.error(chalk.bold.red("❌ 项目编译失败！"));
        console.error(chalk.yellow("若刚更新了 SwiftPM 依赖，请先执行：xcodebuild -resolvePackageDependencies -project Qjiao.xcodeproj -scheme Qjiao -derivedDataPath build/DerivedData"));
        process.exit(buildResult.exitCode);
      }

      writeFileSync(BUILD_STAMP_PATH, expectedBuildStamp);
      console.log(chalk.bold.green("✅ 编译成功！"));
    } else {
      console.log(chalk.green("⚡️ Debug 产物已是最新，跳过编译（QJIAO_FORCE_BUILD=1 可强制重建）。"));
    }

    if (existsSync(binaryPath)) {
      console.log(chalk.magenta(`🎉 正在以调试模式在前台启动应用程序: ${chalk.underline(binaryPath)}`));
      console.log(chalk.dim("--------------------- 控制台与崩溃日志 ---------------------"));

      // 在前台直接执行 app 二进制，实时把 stdout/stderr 输出到终端
      const proc = Bun.spawn([binaryPath], {
        stdout: "inherit",
        stderr: "inherit",
        stdin: "inherit",
      });
      const exitCode = await proc.exited;

      console.log(chalk.dim("-----------------------------------------------------------"));
      if (exitCode !== 0) {
        console.error(chalk.bold.red(`💥 应用程序异常退出 (Exit Code: ${exitCode})`));
        process.exit(exitCode);
      } else {
        console.log(chalk.bold.green("✨ 应用程序已正常退出"));
      }
    } else {
      console.error(chalk.bold.red(`❌ 找不到可执行二进制文件: ${binaryPath}`));
      process.exit(1);
    }
  } catch (error) {
    console.error(chalk.bold.red("❌ 运行过程中发生错误:"), error);
    process.exit(1);
  }
}

main();
