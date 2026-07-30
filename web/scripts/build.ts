#!/usr/bin/env bun
import { $ } from "bun";
import chalk from "chalk";
import { existsSync, mkdirSync, rmSync, cpSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** web 项目根路径与目标 docs 目录路径 */
const WEB_DIR = resolve(__dirname, "..");
const DIST_DIR = resolve(WEB_DIR, "dist");
const DOCS_DIR = resolve(WEB_DIR, "../docs");

/**
 * 清空指定的目录内容。如果目录不存在则重新创建空目录。
 * @param dirPath 需要清空的目录绝对路径
 */
export function cleanDirectory(dirPath: string): void {
  if (existsSync(dirPath)) {
    // 递归删除现有目录
    rmSync(dirPath, { recursive: true, force: true });
  }
  // 重新新建空目录
  mkdirSync(dirPath, { recursive: true });
}

/**
 * 递归复制源目录下的所有内容到目标目录
 * @param srcDir 源目录绝对路径
 * @param destDir 目标目录绝对路径
 */
export function copyDirectoryContents(srcDir: string, destDir: string): void {
  if (!existsSync(srcDir)) {
    throw new Error(`源目录不存在: ${srcDir}`);
  }
  cpSync(srcDir, destDir, { recursive: true });
}

/**
 * Web 项目构建并发布至 GitHub Pages docs 目录的核心流程
 */
export async function buildAndPublishDocs(): Promise<void> {
  console.log(chalk.bold.cyan("\n🚀 开始构建 Web 项目...\n"));

  // 1. 执行 Vite 构建
  console.log(chalk.blue("📦 步骤 1/4: 正在执行 Vite 构建..."));
  try {
    await $`bunx vite build`.cwd(WEB_DIR);
    console.log(chalk.green("✔ Vite 构建成功完成！\n"));
  } catch (error) {
    console.error(chalk.red("✖ Vite 构建发生错误："), error);
    process.exit(1);
  }

  // 2. 清空目标 docs 目录
  console.log(chalk.blue("🧹 步骤 2/4: 正在清空 ../docs 目录..."));
  cleanDirectory(DOCS_DIR);
  console.log(chalk.green(`✔ 已成功清空: ${chalk.gray(DOCS_DIR)}\n`));

  // 3. 复制 dist 构建产物至 docs
  console.log(chalk.blue("📋 步骤 3/4: 复制 dist 内容至 ../docs 目录..."));
  copyDirectoryContents(DIST_DIR, DOCS_DIR);
  console.log(
    chalk.green(
      `✔ 已将内容从 ${chalk.gray("web/dist")} 复制到 ${chalk.gray("docs")}\n`
    )
  );

  // 4. 创建 .nojekyll 解决 GitHub Pages 的 Jekyll 资源忽略问题
  console.log(chalk.blue("⚙️  步骤 4/4: 创建 GitHub Pages .nojekyll 文件..."));
  writeFileSync(resolve(DOCS_DIR, ".nojekyll"), "");
  console.log(chalk.green("✔ 已生成 .nojekyll 文件\n"));

  console.log(
    chalk.bold.bgGreen.black(
      " 🎉 Web 构建及 GitHub Pages docs 同步完成！ "
    ) + "\n"
  );
}

if (import.meta.main) {
  buildAndPublishDocs();
}
