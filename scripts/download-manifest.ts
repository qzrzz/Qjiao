// 官网下载清单：发布脚本写入 docs/download.json，静态站点直链最新安装包。
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export const DOWNLOAD_MANIFEST_SCHEMA_VERSION = 1 as const;

/** 单个可下载安装包。 */
export interface IDownloadAsset {
  name: string;
  url: string;
}

/** `docs/download.json` 的规范结构。 */
export interface IDownloadManifest {
  schemaVersion: typeof DOWNLOAD_MANIFEST_SCHEMA_VERSION;
  version: string;
  tag: string;
  publishedAt: string;
  htmlUrl: string;
  dmg: IDownloadAsset;
  zip: IDownloadAsset;
}

/** 旧版 `latest.json`，供已部署的官网 JS 继续解析。 */
export interface ILegacyLatestJson {
  tag_name: string;
  html_url: string;
  published_at?: string;
  assets: Array<{
    name: string;
    browser_download_url: string;
  }>;
}

/** 由当前发布身份生成下载清单所需的字段。 */
export interface IBuildDownloadManifestInput {
  repository: string;
  version: string;
  tag: string;
  publishedAt: string;
}

const REPO_ROOT = resolve(import.meta.dir, "..");

export const DOWNLOAD_MANIFEST_RELATIVE_PATHS = [
  "docs/download.json",
  "web/public/download.json",
] as const;

export const LEGACY_LATEST_JSON_RELATIVE_PATHS = [
  "docs/latest.json",
  "web/public/latest.json",
] as const;

/** GitHub Release 资产的稳定下载地址。 */
export function releaseAssetUrl(
  repository: string,
  tag: string,
  name: string,
): string {
  return `https://github.com/${repository}/releases/download/${tag}/${name}`;
}

/** 按当前版本构造官网下载清单。 */
export function buildDownloadManifest(
  input: IBuildDownloadManifestInput,
): IDownloadManifest {
  const dmgName = `qjiao-${input.version}.dmg`;
  const zipName = `qjiao-${input.version}.zip`;
  return {
    schemaVersion: DOWNLOAD_MANIFEST_SCHEMA_VERSION,
    version: input.version,
    tag: input.tag,
    publishedAt: input.publishedAt,
    htmlUrl: `https://github.com/${input.repository}/releases/tag/${input.tag}`,
    dmg: {
      name: dmgName,
      url: releaseAssetUrl(input.repository, input.tag, dmgName),
    },
    zip: {
      name: zipName,
      url: releaseAssetUrl(input.repository, input.tag, zipName),
    },
  };
}

/** 从规范清单派生旧版 latest.json，避免已上线页面读到过期链接。 */
export function toLegacyLatestJson(
  manifest: IDownloadManifest,
  repository: string,
): ILegacyLatestJson {
  const notesName = `qjiao-${manifest.version}.md`;
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

/** 判断未知 JSON 是否为可用的官网下载清单。 */
export function isDownloadManifest(value: unknown): value is IDownloadManifest {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<IDownloadManifest>;
  return (
    record.schemaVersion === DOWNLOAD_MANIFEST_SCHEMA_VERSION &&
    typeof record.version === "string" &&
    typeof record.tag === "string" &&
    typeof record.publishedAt === "string" &&
    typeof record.htmlUrl === "string" &&
    isDownloadAsset(record.dmg) &&
    isDownloadAsset(record.zip)
  );
}

/** 优先返回 DMG，其次 ZIP，再退回 Release 页。 */
export function resolveDownloadUrl(
  manifest: IDownloadManifest,
  fallbackUrl: string,
): string {
  if (manifest.dmg.url) return manifest.dmg.url;
  if (manifest.zip.url) return manifest.zip.url;
  if (manifest.htmlUrl) return manifest.htmlUrl;
  return fallbackUrl;
}

/** 把清单写入 docs/ 与 web/public/，并同步旧版 latest.json。 */
export function writeDownloadManifestFiles(
  manifest: IDownloadManifest,
  repository: string,
): string[] {
  const manifestJson = `${JSON.stringify(manifest, null, 2)}\n`;
  const legacyJson = `${JSON.stringify(toLegacyLatestJson(manifest, repository), null, 2)}\n`;
  const written: string[] = [];
  for (const relativePath of DOWNLOAD_MANIFEST_RELATIVE_PATHS) {
    writeTextFile(join(REPO_ROOT, relativePath), manifestJson);
    written.push(relativePath);
  }
  for (const relativePath of LEGACY_LATEST_JSON_RELATIVE_PATHS) {
    writeTextFile(join(REPO_ROOT, relativePath), legacyJson);
    written.push(relativePath);
  }
  return written;
}

function isDownloadAsset(value: unknown): value is IDownloadAsset {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<IDownloadAsset>;
  return typeof record.name === "string" && typeof record.url === "string";
}

function writeTextFile(path: string, contents: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}
