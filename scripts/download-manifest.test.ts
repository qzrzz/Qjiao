import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  DOWNLOAD_MANIFEST_RELATIVE_PATHS,
  DOWNLOAD_MANIFEST_SCHEMA_VERSION,
  buildDownloadManifest,
  buildDownloadManifestWithFiles,
  computeFileSha256,
  ensureDownloadManifestExists,
  generateManifestFromExistingInfo,
  getFileSize,
  isDownloadManifest,
  releaseAssetUrl,
  resolveDownloadUrl,
  toLegacyLatestJson,
  writeDownloadManifestFiles,
} from "./download-manifest";

const repository = "qzrzz/Qjiao";
const tempTestDir = join(import.meta.dir, ".tmp-manifest-test");

describe("download-manifest 测试套件", () => {
  beforeEach(() => {
    mkdirSync(tempTestDir, { recursive: true });
  });

  afterEach(() => {
    rmSync(tempTestDir, { recursive: true, force: true });
  });

  test("按版本与参数构造规范 download.json", () => {
    const manifest = buildDownloadManifest({
      repository: "qzrzz/QLaunch",
      name: "QLaunch",
      version: "1.0.7",
      build: "11",
      tag: "v1.0.7",
      publishedAt: "2026-08-14T15:09:09.382Z",
      dmg: {
        name: "QLaunch-1.0.7.dmg",
        url: "https://github.com/qzrzz/QLaunch/releases/download/v1.0.7/QLaunch-1.0.7.dmg",
        size: 4872113,
        sha256: "ae216c93956222ddd08840f93940d326cf13f2e1f276f4954fd5327399a71248",
      },
      zip: {
        name: "QLaunch-1.0.7.zip",
        url: "https://github.com/qzrzz/QLaunch/releases/download/v1.0.7/QLaunch-1.0.7.zip",
        size: 5018303,
        sha256: "4eaf7fef5162e3e9419a9e9c42f981c603ef01c130f67be9e2c502da6099ff53",
      },
    });

    expect(manifest.schemaVersion).toBe(DOWNLOAD_MANIFEST_SCHEMA_VERSION);
    expect(manifest.name).toBe("QLaunch");
    expect(manifest.version).toBe("1.0.7");
    expect(manifest.build).toBe("11");
    expect(manifest.tag).toBe("v1.0.7");
    expect(manifest.publishedAt).toBe("2026-08-14T15:09:09.382Z");
    expect(manifest.htmlUrl).toBe("https://github.com/qzrzz/QLaunch/releases/tag/v1.0.7");
    expect(manifest.dmg).toEqual({
      name: "QLaunch-1.0.7.dmg",
      url: "https://github.com/qzrzz/QLaunch/releases/download/v1.0.7/QLaunch-1.0.7.dmg",
      size: 4872113,
      sha256: "ae216c93956222ddd08840f93940d326cf13f2e1f276f4954fd5327399a71248",
    });
    expect(manifest.zip).toEqual({
      name: "QLaunch-1.0.7.zip",
      url: "https://github.com/qzrzz/QLaunch/releases/download/v1.0.7/QLaunch-1.0.7.zip",
      size: 5018303,
      sha256: "4eaf7fef5162e3e9419a9e9c42f981c603ef01c130f67be9e2c502da6099ff53",
    });
    expect(isDownloadManifest(manifest)).toBe(true);
  });

  test("依据本地文件异步计算 size 与 sha256 构造 download.json", async () => {
    const fakeDmgPath = join(tempTestDir, "test-app-1.0.0.dmg");
    const fakeZipPath = join(tempTestDir, "test-app-1.0.0.zip");
    writeFileSync(fakeDmgPath, "dmg-binary-data");
    writeFileSync(fakeZipPath, "zip-binary-data");

    const manifest = await buildDownloadManifestWithFiles({
      repository,
      name: "TestApp",
      version: "1.0.0",
      build: "10",
      tag: "v1.0.0",
      publishedAt: "2026-08-15T00:00:00.000Z",
      dmgPath: fakeDmgPath,
      zipPath: fakeZipPath,
    });

    expect(manifest.name).toBe("TestApp");
    expect(manifest.dmg.size).toBe(getFileSize(fakeDmgPath));
    expect(manifest.dmg.sha256).toBe(await computeFileSha256(fakeDmgPath));
    expect(manifest.zip.size).toBe(getFileSize(fakeZipPath));
    expect(manifest.zip.sha256).toBe(await computeFileSha256(fakeZipPath));
    expect(manifest.dmg.name).toBe("test-app-1.0.0.dmg");
    expect(manifest.zip.name).toBe("test-app-1.0.0.zip");
    expect(isDownloadManifest(manifest)).toBe(true);
  });

  test("isDownloadManifest 严密校验结构合法性", () => {
    expect(isDownloadManifest(null)).toBe(false);
    expect(isDownloadManifest({})).toBe(false);
    expect(
      isDownloadManifest({
        schemaVersion: 1,
        name: "Qjiao",
        version: "1.1.48",
        build: "148",
        tag: "v1.1.48",
        publishedAt: "2026-08-13T12:15:10Z",
        htmlUrl: "https://github.com/qzrzz/Qjiao/releases/tag/v1.1.48",
        dmg: { name: "a.dmg", url: "https://example.com/a.dmg", size: 100, sha256: "abc" },
        zip: { name: "a.zip", url: "https://example.com/a.zip", size: 200, sha256: "def" },
      }),
    ).toBe(true);

    // 缺少必要字段应返回 false
    expect(
      isDownloadManifest({
        schemaVersion: 1,
        name: "Qjiao",
        version: "1.1.48",
        dmg: { name: "a.dmg", url: "https://example.com/a.dmg" },
      }),
    ).toBe(false);
  });

  test("resolveDownloadUrl 优先使用 DMG，缺资产时退回 htmlUrl", () => {
    const manifest = buildDownloadManifest({
      repository,
      version: "1.1.48",
      tag: "v1.1.48",
      publishedAt: "2026-08-13T12:15:10Z",
      dmg: {
        name: "qjiao-1.1.48.dmg",
        url: "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.dmg",
        size: 100,
        sha256: "abc",
      },
      zip: {
        name: "qjiao-1.1.48.zip",
        url: "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.zip",
        size: 100,
        sha256: "abc",
      },
    });
    expect(resolveDownloadUrl(manifest, "https://example.test/fallback")).toBe(
      manifest.dmg.url,
    );

    const withoutPackages = {
      ...manifest,
      dmg: { name: "", url: "", size: 0, sha256: "" },
      zip: { name: "", url: "", size: 0, sha256: "" },
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

  test("writeDownloadManifestFiles 写入 web/download.json 与 docs/download.json", () => {
    const manifest = buildDownloadManifest({
      repository,
      name: "Qjiao",
      version: "1.1.48",
      build: "148",
      tag: "v1.1.48",
      publishedAt: "2026-08-13T12:15:10Z",
      dmg: {
        name: "qjiao-1.1.48.dmg",
        url: "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.dmg",
        size: 12345,
        sha256: "abcdef",
      },
      zip: {
        name: "qjiao-1.1.48.zip",
        url: "https://github.com/qzrzz/Qjiao/releases/download/v1.1.48/qjiao-1.1.48.zip",
        size: 67890,
        sha256: "fedcba",
      },
    });

    const written = writeDownloadManifestFiles(manifest, repository, tempTestDir);
    expect(written).toContain("web/download.json");
    expect(written).toContain("docs/download.json");

    const webContent = JSON.parse(
      readFileSync(join(tempTestDir, "web/download.json"), "utf-8"),
    );
    expect(webContent.version).toBe("1.1.48");
    expect(webContent.name).toBe("Qjiao");
    expect(webContent.dmg.size).toBe(12345);
    expect(webContent.dmg.sha256).toBe("abcdef");

    const docsContent = JSON.parse(
      readFileSync(join(tempTestDir, "docs/download.json"), "utf-8"),
    );
    expect(docsContent.version).toBe("1.1.48");
    expect(docsContent.dmg.sha256).toBe("abcdef");
  });

  test("若无 download.json 时根据现有信息自动生成", async () => {
    // 模拟 release/manifest.json 和本地归档
    const releaseDir = join(tempTestDir, "release");
    const archivesDir = join(releaseDir, "archives");
    mkdirSync(archivesDir, { recursive: true });

    const fakeZip = join(archivesDir, "qjiao-1.1.48.zip");
    writeFileSync(fakeZip, "fake-archive-content");
    const fakeZipSha = await computeFileSha256(fakeZip);

    writeFileSync(
      join(releaseDir, "manifest.json"),
      JSON.stringify({
        schemaVersion: 1,
        entries: [
          {
            version: "1.1.48",
            build: "148",
            tag: "v1.1.48",
            archiveName: "qjiao-1.1.48.zip",
            sha256: fakeZipSha,
            size: fakeZip.length,
            publishedAt: "2026-08-13T12:15:48.539Z",
          },
        ],
      }),
    );

    const generated = await generateManifestFromExistingInfo(tempTestDir, repository);
    expect(generated.version).toBe("1.1.48");
    expect(generated.build).toBe("148");
    expect(generated.zip.sha256).toBe(fakeZipSha);
    expect(isDownloadManifest(generated)).toBe(true);

    const ensured = await ensureDownloadManifestExists(tempTestDir, repository);
    expect(ensured).toEqual(expect.arrayContaining(["web/download.json", "docs/download.json"]));
    expect(existsSync(join(tempTestDir, "web/download.json"))).toBe(true);
    expect(existsSync(join(tempTestDir, "docs/download.json"))).toBe(true);
  });
});
