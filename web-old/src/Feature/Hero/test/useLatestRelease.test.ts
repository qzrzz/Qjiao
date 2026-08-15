import { describe, test, expect } from "bun:test";
import {
  resolveReleaseDownload,
  type DownloadManifest,
  type LegacyLatestJson,
} from "../downloadManifest";

const fallbackUrl = "https://github.com/qzrzz/Qjiao/releases/latest";

/**
 * 校验最新 Release 下载链接与静态 download.json / latest.json 解析逻辑
 */
describe("useLatestRelease 与 download.json 静态数据解析逻辑测试", () => {
  test("在获取 download.json 成功且包含 DMG 时应提取 direct download 链接与 tag 名称", () => {
    const manifest: DownloadManifest = {
      schemaVersion: 1,
      version: "1.1.48",
      tag: "v1.1.48",
      publishedAt: "2026-08-13T12:15:10Z",
      htmlUrl: "https://github.com/qzrzz/Qjiao/releases/tag/v1.1.48",
      dmg: {
        name: "qjiao-1.1.48.dmg",
        url: "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.dmg",
      },
      zip: {
        name: "qjiao-1.1.48.zip",
        url: "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.zip",
      },
    };

    expect(resolveReleaseDownload(manifest, fallbackUrl)).toEqual({
      downloadUrl:
        "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.dmg",
      tagName: "v1.1.48",
    });
  });

  test("在 download.json 无安装包直链时应退回到 htmlUrl Release 页面", () => {
    const manifest: DownloadManifest = {
      schemaVersion: 1,
      version: "1.1.48",
      tag: "v1.1.48",
      publishedAt: "2026-08-13T12:15:10Z",
      htmlUrl: "https://github.com/qzrzz/Qjiao/releases/tag/v1.1.48",
      dmg: { name: "", url: "" },
      zip: { name: "", url: "" },
    };

    expect(resolveReleaseDownload(manifest, fallbackUrl).downloadUrl).toBe(
      "https://github.com/qzrzz/Qjiao/releases/tag/v1.1.48",
    );
  });

  test("兼容旧版 latest.json：有 DMG 时直链，无资产时退回 Release 页", () => {
    const legacy: LegacyLatestJson = {
      tag_name: "v1.0.4",
      html_url: "https://github.com/qzrzz/Qjiao/releases/tag/v1.0.4",
      assets: [
        {
          name: "qjiao-1.0.4.dmg",
          browser_download_url:
            "https://github.com/qzrzz/Qjiao/releases/download/v1.0.4/qjiao-1.0.4.dmg",
        },
      ],
    };

    expect(resolveReleaseDownload(legacy, fallbackUrl)).toEqual({
      downloadUrl:
        "https://github.com/qzrzz/Qjiao/releases/download/v1.0.4/qjiao-1.0.4.dmg",
      tagName: "v1.0.4",
    });

    expect(
      resolveReleaseDownload(
        {
          tag_name: "v1.0.4",
          html_url: "https://github.com/qzrzz/Qjiao/releases/tag/v1.0.4",
          assets: [],
        },
        fallbackUrl,
      ).downloadUrl,
    ).toBe("https://github.com/qzrzz/Qjiao/releases/tag/v1.0.4");
  });

  test("在静态清单为初始保底数据时应退回 GitHub latest 页面", () => {
    expect(
      resolveReleaseDownload(
        {
          schemaVersion: 1,
          version: "",
          tag: "",
          publishedAt: "",
          htmlUrl: fallbackUrl,
          dmg: { name: "", url: "" },
          zip: { name: "", url: "" },
        },
        fallbackUrl,
      ),
    ).toEqual({
      downloadUrl: fallbackUrl,
      tagName: null,
    });
  });
});
