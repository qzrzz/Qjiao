import { describe, expect, test } from "bun:test";
import {
  buildDownloadManifest,
  isDownloadManifest,
  releaseAssetUrl,
  resolveDownloadUrl,
  toLegacyLatestJson,
} from "./download-manifest";

const repository = "qzrzz/Qjiao";

describe("download-manifest", () => {
  test("按版本构造 GitHub Release 直链与 tag 页面", () => {
    const manifest = buildDownloadManifest({
      repository,
      version: "1.1.48",
      tag: "v1.1.48",
      publishedAt: "2026-08-13T12:15:10Z",
    });

    expect(manifest.schemaVersion).toBe(1);
    expect(manifest.version).toBe("1.1.48");
    expect(manifest.tag).toBe("v1.1.48");
    expect(manifest.htmlUrl).toBe(
      "https://github.com/qzrzz/Qjiao/releases/tag/v1.1.48",
    );
    expect(manifest.dmg).toEqual({
      name: "qjiao-1.1.48.dmg",
      url: "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.dmg",
    });
    expect(manifest.zip).toEqual({
      name: "qjiao-1.1.48.zip",
      url: "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.zip",
    });
    expect(isDownloadManifest(manifest)).toBe(true);
  });

  test("resolveDownloadUrl 优先使用 DMG，缺资产时退回 htmlUrl", () => {
    const manifest = buildDownloadManifest({
      repository,
      version: "1.1.48",
      tag: "v1.1.48",
      publishedAt: "2026-08-13T12:15:10Z",
    });
    expect(resolveDownloadUrl(manifest, "https://example.test/fallback")).toBe(
      manifest.dmg.url,
    );

    const withoutPackages = {
      ...manifest,
      dmg: { name: "", url: "" },
      zip: { name: "", url: "" },
    };
    expect(
      resolveDownloadUrl(withoutPackages, "https://example.test/fallback"),
    ).toBe(manifest.htmlUrl);

    const empty = {
      ...withoutPackages,
      htmlUrl: "",
    };
    expect(resolveDownloadUrl(empty, "https://example.test/fallback")).toBe(
      "https://example.test/fallback",
    );
  });

  test("旧版 latest.json 包含 DMG / ZIP 直链，供已部署页面继续解析", () => {
    const manifest = buildDownloadManifest({
      repository,
      version: "1.1.48",
      tag: "v1.1.48",
      publishedAt: "2026-08-13T12:15:10Z",
    });
    const legacy = toLegacyLatestJson(manifest, repository);
    const dmg = legacy.assets.find((asset) => asset.name.endsWith(".dmg"));

    expect(legacy.tag_name).toBe("v1.1.48");
    expect(dmg?.browser_download_url).toBe(manifest.dmg.url);
    expect(
      releaseAssetUrl(repository, "v1.1.48", "qjiao-1.1.48.dmg"),
    ).toBe(manifest.dmg.url);
  });
});
