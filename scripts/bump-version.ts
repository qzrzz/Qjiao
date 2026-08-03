#!/usr/bin/env bun
/**
 * @file 版本号自动递增脚本
 * @description 用于自动递增 Qjiao.xcodeproj/project.pbxproj 中的 MARKETING_VERSION 与 CURRENT_PROJECT_VERSION
 */

import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import chalk from "chalk";

/** 项目 project.pbxproj 文件的绝对路径 */
const PBXPROJ_PATH = resolve(process.cwd(), "Qjiao.xcodeproj/project.pbxproj");

/**
 * 解析并计算下一个版本号与 Build 号
 * @param {string} currentMarketing 当前 MARKETING_VERSION (例如 "1.1.25")
 * @param {number} currentBuild 当前 CURRENT_PROJECT_VERSION (例如 125)
 * @param {string} [type="patch"] 递增类型 ("patch" | "minor" | "major" | 具体版本号)
 * @returns {{ newMarketing: string; newBuild: number }} 计算出的新版本号与新 Build 号
 */
function calculateNextVersion(
  currentMarketing: string,
  currentBuild: number,
  type: string = "patch"
): { newMarketing: string; newBuild: number } {
  const parts = currentMarketing.split(".").map((n) => parseInt(n, 10));
  let major = parts[0] || 1;
  let minor = parts[1] || 0;
  let patch = parts[2] || 0;

  if (type === "patch") {
    patch += 1;
  } else if (type === "minor") {
    minor += 1;
    patch = 0;
  } else if (type === "major") {
    major += 1;
    minor = 0;
    patch = 0;
  } else if (/^\d+\.\d+\.\d+$/.test(type)) {
    return {
      newMarketing: type,
      newBuild: currentBuild + 1,
    };
  } else {
    console.error(chalk.red(`❌ 无效的版本类型参数: "${type}"`));
    console.log(chalk.yellow("提示: 可使用 'patch' (默认), 'minor', 'major' 或具体的语义化版本号 (例如 '1.2.0')"));
    process.exit(1);
  }

  return {
    newMarketing: `${major}.${minor}.${patch}`,
    newBuild: currentBuild + 1,
  };
}

/**
 * 主执行函数：读取、递增并更新 project.pbxproj 中的版本配置
 */
function main() {
  console.log(chalk.bold.cyan("📦 正在递增 Qjiao 项目版本号..."));

  let content: string;
  try {
    content = readFileSync(PBXPROJ_PATH, "utf-8");
  } catch (error) {
    console.error(chalk.red(`❌ 无法读取 project.pbxproj 文件: ${PBXPROJ_PATH}`));
    process.exit(1);
  }

  // 匹配查找 MARKETING_VERSION 与 CURRENT_PROJECT_VERSION
  const marketingMatch = content.match(/MARKETING_VERSION\s*=\s*([^;]+);/);
  const buildMatch = content.match(/CURRENT_PROJECT_VERSION\s*=\s*([^;]+);/);

  if (!marketingMatch || !buildMatch) {
    console.error(chalk.red("❌ 未能在 project.pbxproj 中找到 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION"));
    process.exit(1);
  }

  const oldMarketing = marketingMatch[1].trim();
  const oldBuildStr = buildMatch[1].trim();
  const oldBuild = parseInt(oldBuildStr, 10);

  // 获取命令行传入的递增类型（默认为 patch）
  const argType = process.argv[2]?.toLowerCase() || "patch";
  const { newMarketing, newBuild } = calculateNextVersion(oldMarketing, oldBuild, argType);

  // 替换配置项中的版本信息
  const updatedContent = content
    .replace(new RegExp(`MARKETING_VERSION\\s*=\\s*${oldMarketing};`, "g"), `MARKETING_VERSION = ${newMarketing};`)
    .replace(new RegExp(`CURRENT_PROJECT_VERSION\\s*=\\s*${oldBuildStr};`, "g"), `CURRENT_PROJECT_VERSION = ${newBuild};`);

  writeFileSync(PBXPROJ_PATH, updatedContent, "utf-8");

  console.log(chalk.bold.green("✅ 版本号递增更新成功！"));
  console.log(chalk.bold(`  MARKETING_VERSION:       ${chalk.red(oldMarketing)} ➔ ${chalk.green(newMarketing)}`));
  console.log(chalk.bold(`  CURRENT_PROJECT_VERSION: ${chalk.red(oldBuildStr)} ➔ ${chalk.green(newBuild.toString())}`));
}

main();
