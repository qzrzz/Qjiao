#!/usr/bin/env bun
/**
 * @file Update Latest Release JSON Script
 * @description 从 GitHub REST API 获取最新 Release 信息并导出为静态 latest.json 文件
 */

import chalk from "chalk";
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** Web 项目根目录与文件路径定义 */
const WEB_DIR = resolve(__dirname, "..");
const PUBLIC_LATEST_JSON = resolve(WEB_DIR, "public", "latest.json");
const DOCS_LATEST_JSON = resolve(WEB_DIR, "../docs", "latest.json");

/** GitHub Release Asset 字段 */
export interface ReleaseAsset {
  name: string;
  browser_download_url: string;
}

/** 静态 latest.json 结构 */
export interface LatestReleaseData {
  tag_name: string;
  html_url: string;
  published_at?: string;
  assets: ReleaseAsset[];
}

/**
 * 获取 GitHub 仓库最新 Release 信息并写入静态 JSON 文件
 *
 * @param owner GitHub 仓库拥有者名称
 * @param repo GitHub 仓库名称
 */
export async function fetchAndUpdateLatestJson(
  owner: string = "qzrzz",
  repo: string = "Qjiao"
): Promise<void> {
  console.log(chalk.bold.cyan("\n🔄 正在获取 GitHub 最新 Release 数据..."));

  const apiUrl = `https://api.github.com/repos/${owner}/${repo}/releases/latest`;
  const defaultReleaseUrl = `https://github.com/${owner}/${repo}/releases/latest`;

  const headers: Record<string, string> = {
    "User-Agent": "Qjiao-Web-Build-Script",
    Accept: "application/vnd.github+json",
  };

  // 如果环境变量中包含 GITHUB_TOKEN（如 GitHub Actions 环境），增加 Bearer 认证提升额度
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  let releaseData: LatestReleaseData = {
    tag_name: "",
    html_url: defaultReleaseUrl,
    assets: [],
  };

  try {
    const res = await fetch(apiUrl, { headers });
    if (!res.ok) {
      console.warn(
        chalk.yellow(`⚠️ 获取 GitHub Release API 返回状态 ${res.status}，将使用保底信息。`)
      );
    } else {
      const data = (await res.json()) as {
        tag_name?: string;
        html_url?: string;
        published_at?: string;
        assets?: Array<{ name: string; browser_download_url: string }>;
      };

      releaseData = {
        tag_name: data.tag_name || "",
        html_url: data.html_url || defaultReleaseUrl,
        published_at: data.published_at || "",
        assets: (data.assets || []).map((asset) => ({
          name: asset.name,
          browser_download_url: asset.browser_download_url,
        })),
      };
      console.log(
        chalk.green(`✔ 成功获取最新 Release 标签: ${chalk.bold(releaseData.tag_name || "未知")}`)
      );
    }
  } catch (error) {
    console.error(chalk.red("✖ 请求 GitHub Release API 发生网络错误:"), error);
  }

  const jsonContent = JSON.stringify(releaseData, null, 2) + "\n";

  // 1. 保存至 web/public/latest.json
  const publicDir = dirname(PUBLIC_LATEST_JSON);
  if (!existsSync(publicDir)) {
    mkdirSync(publicDir, { recursive: true });
  }
  writeFileSync(PUBLIC_LATEST_JSON, jsonContent);
  console.log(chalk.green(`✔ 已写入: ${chalk.gray(PUBLIC_LATEST_JSON)}`));

  // 2. 如果 docs 目录存在，也同步写入 docs/latest.json
  const docsDir = dirname(DOCS_LATEST_JSON);
  if (existsSync(docsDir)) {
    writeFileSync(DOCS_LATEST_JSON, jsonContent);
    console.log(chalk.green(`✔ 已写入: ${chalk.gray(DOCS_LATEST_JSON)}`));
  }

  console.log(chalk.bold.green("🎉 静态 latest.json 更新完成！\n"));
}

if (import.meta.main) {
  fetchAndUpdateLatestJson();
}
