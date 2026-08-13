/** 官网 `download.json` 中的单个安装包。 */
export interface DownloadAsset {
  name: string;
  url: string;
}

/** 发布脚本写入的 `docs/download.json`。 */
export interface DownloadManifest {
  schemaVersion: 1;
  version: string;
  tag: string;
  publishedAt: string;
  htmlUrl: string;
  dmg: DownloadAsset;
  zip: DownloadAsset;
}

/** 旧版 `latest.json`，兼容尚未刷新的静态页。 */
export interface LegacyLatestJson {
  tag_name?: string;
  html_url?: string;
  published_at?: string;
  assets?: Array<{
    name: string;
    browser_download_url: string;
  }>;
}

/** 从静态清单解析出的下载目标。 */
export interface ResolvedReleaseDownload {
  downloadUrl: string;
  tagName: string | null;
}

function isDownloadAsset(value: unknown): value is DownloadAsset {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<DownloadAsset>;
  return typeof record.name === "string" && typeof record.url === "string";
}

/** 判断静态 JSON 是否为新的 download.json 清单。 */
export function isDownloadManifest(value: unknown): value is DownloadManifest {
  if (!value || typeof value !== "object") return false;
  const record = value as Partial<DownloadManifest>;
  return (
    record.schemaVersion === 1 &&
    typeof record.version === "string" &&
    typeof record.tag === "string" &&
    typeof record.htmlUrl === "string" &&
    isDownloadAsset(record.dmg) &&
    isDownloadAsset(record.zip)
  );
}

/** 优先使用 download.json 的 DMG，其次兼容 latest.json，最后退回 GitHub Release 页。 */
export function resolveReleaseDownload(
  data: unknown,
  fallbackUrl: string,
): ResolvedReleaseDownload {
  if (isDownloadManifest(data)) {
    const downloadUrl = data.dmg.url || data.zip.url || data.htmlUrl || fallbackUrl;
    return {
      downloadUrl,
      tagName: data.tag || null,
    };
  }

  const legacy = data as LegacyLatestJson | null;
  const assets = legacy?.assets ?? [];
  const dmgAsset = assets.find((asset) =>
    asset.name.toLowerCase().endsWith(".dmg"),
  );
  const zipAsset = assets.find((asset) =>
    asset.name.toLowerCase().endsWith(".zip"),
  );
  const pkgAsset = assets.find((asset) =>
    asset.name.toLowerCase().endsWith(".pkg"),
  );
  const matched = dmgAsset || zipAsset || pkgAsset;
  return {
    downloadUrl:
      matched?.browser_download_url || legacy?.html_url || fallbackUrl,
    tagName: legacy?.tag_name || null,
  };
}
