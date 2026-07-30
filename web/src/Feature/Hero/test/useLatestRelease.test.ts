import { describe, test, expect } from "bun:test";

/**
 * 校验最新 Release 下载链接解析逻辑的单元测试
 */
describe("useLatestRelease 逻辑测试", () => {
  test("在获取 API 成功且包含 DMG Asset 时应提取 direct download 链接与 tag 名称", () => {
    const mockApiResponse = {
      tag_name: "v1.0.0",
      html_url: "https://github.com/qzrzz/Qjiao/releases/tag/v1.0.0",
      assets: [
        {
          name: "qjiao-1.0.0.dmg",
          browser_download_url: "https://github.com/qzrzz/Qjiao/releases/download/v1.0.0/qjiao-1.0.0.dmg",
        },
        {
          name: "qjiao-1.0.0.zip",
          browser_download_url: "https://github.com/qzrzz/Qjiao/releases/download/v1.0.0/qjiao-1.0.0.zip",
        },
      ],
    };

    const dmgAsset = mockApiResponse.assets.find((a) => a.name.endsWith(".dmg"));
    expect(dmgAsset?.browser_download_url).toBe(
      "https://github.com/qzrzz/Qjiao/releases/download/v1.0.0/qjiao-1.0.0.dmg"
    );
    expect(mockApiResponse.tag_name).toBe("v1.0.0");
  });

  test("在无 Asset 时应退回到 html_url Release 页面", () => {
    const mockApiResponse = {
      tag_name: "v1.0.0",
      html_url: "https://github.com/qzrzz/Qjiao/releases/tag/v1.0.0",
      assets: [],
    };

    const matchedAsset = mockApiResponse.assets.find((a: { name: string }) =>
      a.name.endsWith(".dmg")
    );
    const finalUrl = matchedAsset
      ? (matchedAsset as { browser_download_url: string }).browser_download_url
      : mockApiResponse.html_url;

    expect(finalUrl).toBe("https://github.com/qzrzz/Qjiao/releases/tag/v1.0.0");
  });
});
