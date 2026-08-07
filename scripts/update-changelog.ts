#!/usr/bin/env bun
/**
 * @file 调用 pi AI 更新 CHANGELOG.md
 * @description 只做一件事：以非交互模式（pi -p）把「为当前版本撰写更新记录」的
 *              任务完全交给 AI。AI 自行读取 git 提交与 CHANGELOG.md 现有格式，
 *              并直接编辑文件，脚本不做任何内容解析或写入。
 */

import { spawnSync } from "node:child_process";
import { accessSync, constants, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import chalk from "chalk";

/** 项目 project.pbxproj 文件的绝对路径 */
const PBXPROJ_PATH = resolve(process.cwd(), "Qjiao.xcodeproj/project.pbxproj");

/** 从 project.pbxproj 读取当前 MARKETING_VERSION（仅作为提示词参数） */
function currentVersion(): string {
  try {
    const match = readFileSync(PBXPROJ_PATH, "utf-8").match(/MARKETING_VERSION\s*=\s*([^;]+);/);
    return match ? match[1].trim() : "";
  } catch {
    return "";
  }
}

/** 解析 pi 可执行文件路径：优先 PATH，其次常见全局安装位置 */
function resolvePiBinary(): string {
  const candidates = [
    ...(process.env.PATH ?? "").split(":").map((dir) => resolve(dir, "pi")),
    resolve(homedir(), ".npm-global/bin/pi"),
    resolve(homedir(), ".local/bin/pi"),
  ];
  for (const candidate of candidates) {
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // 继续尝试下一个候选路径
    }
  }
  return "pi"; // 兜底：交给系统 PATH 处理
}

/** 主执行函数 */
function main() {
  const version = currentVersion();
  const prompt = [
    `为 CHANGELOG.md 添加版本 ${version || "（版本号请从 Qjiao.xcodeproj/project.pbxproj 的 MARKETING_VERSION 读取）"} 的版本更新记录。`,
    "",
    "请自行完成以下工作：",
    "- 阅读 CHANGELOG.md 了解现有格式与条目风格",
    "- 查看最近的 git 提交，总结用户可见的变化",
    "- 按 Keep a Changelog 风格在顶部添加新的 ## [版本] 小节",
    "",
    "要求：言简意赅，用英文撰写，与现有条目风格保持一致；不要修改其他文件。",
  ].join("\n");

  console.log(chalk.bold.cyan(`🤖 正在调用 pi AI 更新 CHANGELOG.md（v${version || "?"}）...`));

  const result = spawnSync(resolvePiBinary(), ["-p", prompt], {
    cwd: process.cwd(),
    stdio: "inherit",
  });

  if (result.status !== 0) {
    console.error(chalk.red(`❌ pi 调用失败（退出码 ${result.status}）`));
    process.exit(result.status ?? 1);
  }
}

main();
