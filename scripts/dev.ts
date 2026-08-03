#!/usr/bin/env bun
/**
 * @file 开发模式调试运行脚本
 * @description 使用 Xcode 工具链 (Swift/xcodebuild) 编译，并在前台直接运行 Qjiao 二进制，实时输出控制台 Logs 与 Crash Trace 崩溃报告
 */

import { $ } from "bun";
import { existsSync } from "node:fs";
import chalk from "chalk";

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

  const projectPath = "Qjiao.xcodeproj";
  const scheme = "Qjiao";
  const configuration = "Debug";
  const derivedDataPath = "build/DerivedData";
  const appPath = `${derivedDataPath}/Build/Products/${configuration}/Qjiao.app`;
  const binaryPath = `${appPath}/Contents/MacOS/Qjiao`;

  console.log(chalk.yellow(`🔨 正在使用 Swift/Xcode 工具链编译项目 (${scheme} - ${configuration})...`));

  try {
    const buildResult = await $`xcodebuild -project ${projectPath} -scheme ${scheme} -configuration ${configuration} -derivedDataPath ${derivedDataPath} build`;

    if (buildResult.exitCode !== 0) {
      console.error(chalk.bold.red("❌ 项目编译失败！"));
      process.exit(buildResult.exitCode);
    }

    console.log(chalk.bold.green("✅ 编译成功！"));

    if (existsSync(binaryPath)) {
      console.log(chalk.magenta(`🎉 正在以调试模式在前台启动应用程序: ${chalk.underline(binaryPath)}`));
      console.log(chalk.dim("--------------------- 控制台与崩溃日志 ---------------------"));

      // 在前台直接执行 app 二进制，实时把 stdout/stderr 输出到终端
      const appProcess = await $`${binaryPath}`.nothrow();

      console.log(chalk.dim("-----------------------------------------------------------"));
      if (appProcess.exitCode !== 0) {
        console.error(chalk.bold.red(`💥 应用程序异常退出 (Exit Code: ${appProcess.exitCode})`));
        process.exit(appProcess.exitCode);
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
