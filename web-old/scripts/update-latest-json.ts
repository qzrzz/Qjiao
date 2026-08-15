#!/usr/bin/env bun
/**
 * @file Update Latest Release JSON Script
 * @description 从 GitHub REST API 获取最新 Release 并写入 download.json
 */

import chalk from "chalk";
import {
  buildDownloadManifest,
  writeDownloadManifestFiles,
  type IDownloadManifest,
} from "../../scripts/download-manifest";

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

  const repository = `${owner}/${repo}`;
  const apiUrl = `https://api.github.com/repos/${repository}/releases/latest`;

  const headers: Record<string, string> = {
    "User-Agent": "Qjiao-Web-Build-Script",
    Accept: "application/vnd.github+json",
  };

  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  let manifest: IDownloadManifest = buildDownloadManifest({
    repository,
    version: "",
    tag: "",
    publishedAt: "",
  });
  manifest = {
    ...manifest,
    htmlUrl: `https://github.com/${repository}/releases/latest`,
    dmg: { name: "", url: "" },
    zip: { name: "", url: "" },
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
        published_at?: string;
        assets?: Array<{ name?: string; browser_download_url?: string }>;
      };
      const tag = data.tag_name || "";
      const version = tag.startsWith("v") ? tag.slice(1) : tag;
      const assets = data.assets ?? [];
      const dmg = assets.find((asset) => asset.name?.toLowerCase().endsWith(".dmg"));
      const zip = assets.find((asset) => asset.name?.toLowerCase().endsWith(".zip"));
      manifest = buildDownloadManifest({
        repository,
        version,
        tag,
        publishedAt: data.published_at || "",
      });
      if (dmg?.name && dmg.browser_download_url) {
        manifest.dmg = { name: dmg.name, url: dmg.browser_download_url };
      }
      if (zip?.name && zip.browser_download_url) {
        manifest.zip = { name: zip.name, url: zip.browser_download_url };
      }
      console.log(
        chalk.green(`✔ 成功获取最新 Release 标签: ${chalk.bold(manifest.tag || "未知")}`)
      );
    }
  } catch (error) {
    console.error(chalk.red("✖ 请求 GitHub Release API 发生网络错误:"), error);
  }

  const written = writeDownloadManifestFiles(manifest, repository);
  for (const path of written) {
    console.log(chalk.green(`✔ 已写入: ${chalk.gray(path)}`));
  }

  console.log(chalk.bold.green("🎉 静态 download.json 更新完成！\n"));
}

if (import.meta.main) {
  fetchAndUpdateLatestJson();
}
