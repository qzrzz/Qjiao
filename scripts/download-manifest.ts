/**
 * @file download-manifest.ts
 * @description 官网下载清单：发布脚本写入 ./web/download.json 与 ./docs/download.json，提供最新安装包的直链、大小与 SHA-256 哈希。
 */

import chalk from "chalk";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

export const DOWNLOAD_MANIFEST_SCHEMA_VERSION = 1 as const;

/** 单个可下载安装包资产。 */
export interface IDownloadAsset {
  name: string;
  url: string;
  size: number;
  sha256: string;
}

/** `download.json` 的规范结构。 */
export interface IDownloadManifest {
  schemaVersion: typeof DOWNLOAD_MANIFEST_SCHEMA_VERSION;
  name: string;
  version: string;
  build: string;
  tag: string;
  publishedAt: string;
  htmlUrl: string;
  dmg: IDownloadAsset;
  zip: IDownloadAsset;
}

/** 旧版 `latest.json`，供旧版站点解析兼容。 */
export interface ILegacyLatestJson {
  tag_name: string;
  html_url: string;
  published_at?: string;
  assets: Array<{
    name: string;
    browser_download_url: string;
  }>;
}

/** 构造下载清单的输入参数。 */
export interface IBuildDownloadManifestInput {
  repository: string;
  name?: string;
  version: string;
  build?: string;
  tag?: string;
  publishedAt?: string;
  htmlUrl?: string;
  dmg?: {
    name?: string;
    url?: string;
    size?: number;
    sha256?: string;
  };
  zip?: {
    name?: string;
    url?: string;
    size?: number;
    sha256?: string;
  };
}

/** 基于本地文件路径构造下载清单的输入参数。 */
export interface IBuildDownloadManifestFromFilesInput {
  repository: string;
  name?: string;
  version: string;
  build?: string;
  tag?: string;
  publishedAt?: string;
  htmlUrl?: string;
  dmgPath?: string;
  zipPath?: string;
}

const REPO_ROOT = resolve(import.meta.dir, "..");

/** 下载清单的输出目标路径（相对于仓库根目录）。 */
export const DOWNLOAD_MANIFEST_RELATIVE_PATHS = [
  "web/download.json",
  "docs/download.json",
] as const;

/** 兼容旧版 latest.json 的输出路径。 */
export const LEGACY_LATEST_JSON_RELATIVE_PATHS = [
  "docs/latest.json",
] as const;

/**
 * 获取 GitHub Release 资产的完整下载地址。
 *
 * @param repository GitHub 仓库名，如 "qzrzz/Qjiao"
 * @param tag 发布标签名，如 "v1.1.48"
 * @param name 资产文件名，如 "qjiao-1.1.48.dmg"
 * @returns 资产的 GitHub Release 下载 URL
 */
export function releaseAssetUrl(
  repository: string,
  tag: string,
  name: string,
): string {
  return `https://github.com/${repository}/releases/download/${tag}/${name}`;
}

/**
 * 流式计算文件的 SHA-256 哈希值。
 *
 * @param filePath 文件的绝对或相对路径
 * @returns 16 进制小写 SHA-256 字符串；若文件不存在则返回空字符串
 */
export async function computeFileSha256(filePath: string): Promise<string> {
  if (!existsSync(filePath)) return "";
  const hash = new Bun.CryptoHasher("sha256");
  for await (const chunk of Bun.file(filePath).stream()) {
    hash.update(chunk);
  }
  return hash.digest("hex");
}

/**
 * 获取文件字节大小。
 *
 * @param filePath 文件路径
 * @returns 文件大小（字节数）；若文件不存在则返回 0
 */
export function getFileSize(filePath: string): number {
  if (!existsSync(filePath)) return 0;
  return Bun.file(filePath).size;
}

/**
 * 同步构造官网 download.json 清单对象。
 *
 * @param input 清单构造参数
 * @returns 完整的规范 IDownloadManifest 对象
 */
export function buildDownloadManifest(
  input: IBuildDownloadManifestInput,
): IDownloadManifest {
  const name = input.name || "Qjiao";
  const version = input.version;
  const build = input.build || version;
  const tag = input.tag || `v${version}`;
  const publishedAt = input.publishedAt || new Date().toISOString();
  const dmgName = input.dmg?.name || `${name.toLowerCase()}-${version}.dmg`;
  const zipName = input.zip?.name || `${name.toLowerCase()}-${version}.zip`;

  const htmlUrl =
    input.htmlUrl || `https://github.com/${input.repository}/releases/tag/${tag}`;

  return {
    schemaVersion: DOWNLOAD_MANIFEST_SCHEMA_VERSION,
    name,
    version,
    build,
    tag,
    publishedAt,
    htmlUrl,
    dmg: {
      name: dmgName,
      url: input.dmg?.url || releaseAssetUrl(input.repository, tag, dmgName),
      size: input.dmg?.size ?? 0,
      sha256: input.dmg?.sha256 ?? "",
    },
    zip: {
      name: zipName,
      url: input.zip?.url || releaseAssetUrl(input.repository, tag, zipName),
      size: input.zip?.size ?? 0,
      sha256: input.zip?.sha256 ?? "",
    },
  };
}

/**
 * 依据本地 DMG / ZIP 文件异步构造包含完整 size 和 sha256 的 download.json 清单。
 *
 * @param input 包含文件路径的输入参数
 * @returns 完整的规范 IDownloadManifest 对象
 */
export async function buildDownloadManifestWithFiles(
  input: IBuildDownloadManifestFromFilesInput,
): Promise<IDownloadManifest> {
  const name = input.name || "Qjiao";
  const version = input.version;
  const build = input.build || version;
  const tag = input.tag || `v${version}`;
  const publishedAt = input.publishedAt || new Date().toISOString();
  const htmlUrl =
    input.htmlUrl || `https://github.com/${input.repository}/releases/tag/${tag}`;

  const dmgName = input.dmgPath
    ? basename(input.dmgPath)
    : `${name.toLowerCase()}-${version}.dmg`;
  const zipName = input.zipPath
    ? basename(input.zipPath)
    : `${name.toLowerCase()}-${version}.zip`;

  const dmgSize = input.dmgPath ? getFileSize(input.dmgPath) : 0;
  const dmgSha256 = input.dmgPath ? await computeFileSha256(input.dmgPath) : "";

  const zipSize = input.zipPath ? getFileSize(input.zipPath) : 0;
  const zipSha256 = input.zipPath ? await computeFileSha256(input.zipPath) : "";

  return {
    schemaVersion: DOWNLOAD_MANIFEST_SCHEMA_VERSION,
    name,
    version,
    build,
    tag,
    publishedAt,
    htmlUrl,
    dmg: {
      name: dmgName,
      url: releaseAssetUrl(input.repository, tag, dmgName),
      size: dmgSize,
      sha256: dmgSha256,
    },
    zip: {
      name: zipName,
      url: releaseAssetUrl(input.repository, tag, zipName),
      size: zipSize,
      sha256: zipSha256,
    },
  };
}

/**
 * 从规范清单派生旧版 latest.json，供旧版请求保持兼容。
 *
 * @param manifest 规范下载清单
 * @param repository GitHub 仓库名
 * @returns 旧版结构对象
 */
export function toLegacyLatestJson(
  manifest: IDownloadManifest,
  repository: string,
): ILegacyLatestJson {
  const notesName = `${manifest.name.toLowerCase()}-${manifest.version}.md`;
  const appcastName = "appcast.xml";
  return {
    tag_name: manifest.tag,
    html_url: manifest.htmlUrl,
    published_at: manifest.publishedAt,
    assets: [
      {
        name: appcastName,
        browser_download_url: releaseAssetUrl(
          repository,
          manifest.tag,
          appcastName,
        ),
      },
      {
        name: manifest.dmg.name,
        browser_download_url: manifest.dmg.url,
      },
      {
        name: notesName,
        browser_download_url: releaseAssetUrl(
          repository,
          manifest.tag,
          notesName,
        ),
      },
      {
        name: manifest.zip.name,
        browser_download_url: manifest.zip.url,
      },
    ],
  };
}

/**
 * 判断未知数据是否符合 IDownloadManifest 规范格式。
 *
 * @param value 待检查的值
 * @returns 是否符合规范清单
 */
export function isDownloadManifest(value: unknown): value is IDownloadManifest {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<IDownloadManifest>;
  return (
    record.schemaVersion === DOWNLOAD_MANIFEST_SCHEMA_VERSION &&
    typeof record.name === "string" &&
    typeof record.version === "string" &&
    typeof record.build === "string" &&
    typeof record.tag === "string" &&
    typeof record.publishedAt === "string" &&
    typeof record.htmlUrl === "string" &&
    isDownloadAsset(record.dmg) &&
    isDownloadAsset(record.zip)
  );
}

function isDownloadAsset(value: unknown): value is IDownloadAsset {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<IDownloadAsset>;
  return (
    typeof record.name === "string" &&
    typeof record.url === "string" &&
    typeof record.size === "number" &&
    typeof record.sha256 === "string"
  );
}

/**
 * 获取可用的下载地址（优先 DMG，其次 ZIP，最后回退页面）。
 *
 * @param manifest 规范清单
 * @param fallbackUrl 保底 URL
 * @returns 最终下载地址
 */
export function resolveDownloadUrl(
  manifest: IDownloadManifest,
  fallbackUrl: string,
): string {
  if (manifest.dmg.url) return manifest.dmg.url;
  if (manifest.zip.url) return manifest.zip.url;
  if (manifest.htmlUrl) return manifest.htmlUrl;
  return fallbackUrl;
}

/**
 * 将下载清单写入 `./web/download.json` 与 `./docs/download.json`，并同步 `docs/latest.json`。
 *
 * @param manifest 规范下载清单
 * @param repository GitHub 仓库名
 * @param repoRoot 仓库根路径（可选，默认当前仓库根目录）
 * @returns 成功写入的相对文件路径列表
 */
export function writeDownloadManifestFiles(
  manifest: IDownloadManifest,
  repository: string,
  repoRoot: string = REPO_ROOT,
): string[] {
  const manifestJson = `${JSON.stringify(manifest, null, 2)}\n`;
  const legacyJson = `${JSON.stringify(toLegacyLatestJson(manifest, repository), null, 2)}\n`;
  const written: string[] = [];

  for (const relativePath of DOWNLOAD_MANIFEST_RELATIVE_PATHS) {
    writeTextFile(join(repoRoot, relativePath), manifestJson);
    written.push(relativePath);
  }
  for (const relativePath of LEGACY_LATEST_JSON_RELATIVE_PATHS) {
    writeTextFile(join(repoRoot, relativePath), legacyJson);
    written.push(relativePath);
  }
  return written;
}

/**
 * 根据现有项目信息（release/manifest.json、本地 DMG/ZIP 产物等）推导并生成一份默认 download.json 清单。
 *
 * @param repoRoot 仓库根路径
 * @param repository GitHub 仓库名
 * @returns 生成的规范 IDownloadManifest 对象
 */
export async function generateManifestFromExistingInfo(
  repoRoot: string = REPO_ROOT,
  repository: string = "qzrzz/Qjiao",
): Promise<IDownloadManifest> {
  const releaseManifestPath = join(repoRoot, "release", "manifest.json");
  let version = "1.1.48";
  let build = "148";
  let tag = `v${version}`;
  let publishedAt = new Date().toISOString();
  let zipName = `qjiao-${version}.zip`;
  let zipSize = 0;
  let zipSha256 = "";

  if (existsSync(releaseManifestPath)) {
    try {
      const parsed = JSON.parse(readFileSync(releaseManifestPath, "utf-8"));
      if (Array.isArray(parsed?.entries) && parsed.entries.length > 0) {
        const latestEntry = parsed.entries[0];
        version = latestEntry.version || version;
        build = latestEntry.build || build;
        tag = latestEntry.tag || `v${version}`;
        publishedAt = latestEntry.publishedAt || publishedAt;
        zipName = latestEntry.archiveName || `qjiao-${version}.zip`;
        zipSize = latestEntry.size || 0;
        zipSha256 = latestEntry.sha256 || "";
      }
    } catch {}
  }

  // 检查本地 zip
  const localZipPath = join(repoRoot, "release", "archives", zipName);
  if (existsSync(localZipPath)) {
    if (!zipSize) zipSize = getFileSize(localZipPath);
    if (!zipSha256) zipSha256 = await computeFileSha256(localZipPath);
  }

  // 检查本地 dmg
  const dmgName = `qjiao-${version}.dmg`;
  const localDmgPath = join(repoRoot, "build", dmgName);
  let dmgSize = 0;
  let dmgSha256 = "";
  if (existsSync(localDmgPath)) {
    dmgSize = getFileSize(localDmgPath);
    dmgSha256 = await computeFileSha256(localDmgPath);
  }

  return {
    schemaVersion: DOWNLOAD_MANIFEST_SCHEMA_VERSION,
    name: "Qjiao",
    version,
    build,
    tag,
    publishedAt,
    htmlUrl: `https://github.com/${repository}/releases/tag/${tag}`,
    dmg: {
      name: dmgName,
      url: releaseAssetUrl(repository, tag, dmgName),
      size: dmgSize,
      sha256: dmgSha256,
    },
    zip: {
      name: zipName,
      url: releaseAssetUrl(repository, tag, zipName),
      size: zipSize,
      sha256: zipSha256,
    },
  };
}

/**
 * 确保 download.json 文件在目标位置存在；若不存在或格式损坏，则根据现有信息自动生成。
 *
 * @param repoRoot 仓库根路径
 * @param repository GitHub 仓库名
 * @returns 写入或确认存在的文件列表
 */
export async function ensureDownloadManifestExists(
  repoRoot: string = REPO_ROOT,
  repository: string = "qzrzz/Qjiao",
): Promise<string[]> {
  let needsRegenerate = false;

  for (const relativePath of DOWNLOAD_MANIFEST_RELATIVE_PATHS) {
    const fullPath = join(repoRoot, relativePath);
    if (!existsSync(fullPath)) {
      needsRegenerate = true;
      break;
    }
    try {
      const content = JSON.parse(readFileSync(fullPath, "utf-8"));
      if (!isDownloadManifest(content)) {
        needsRegenerate = true;
        break;
      }
    } catch {
      needsRegenerate = true;
      break;
    }
  }

  if (needsRegenerate) {
    const manifest = await generateManifestFromExistingInfo(repoRoot, repository);
    return writeDownloadManifestFiles(manifest, repository, repoRoot);
  }

  return DOWNLOAD_MANIFEST_RELATIVE_PATHS.map((p) => p);
}

function writeTextFile(path: string, contents: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

if (import.meta.main) {
  const manifest = await generateManifestFromExistingInfo();
  const written = writeDownloadManifestFiles(manifest, "qzrzz/Qjiao");
  console.log(chalk.bold.green("✔ download.json 生成成功:"));
  for (const file of written) {
    console.log(`  - ${chalk.cyan(file)}`);
  }
}
