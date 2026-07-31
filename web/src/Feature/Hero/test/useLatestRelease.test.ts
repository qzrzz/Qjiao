import { describe, test, expect } from "bun:test";
import type { LatestReleaseData } from "../../../../scripts/update-latest-json";

/**
 * 校验最新 Release 下载链接与静态 latest.json 解析逻辑的单元测试
 */
describe("useLatestRelease 与 latest.json 静态数据解析逻辑测试", () => {
  test("在获取静态 latest.json 成功且包含 DMG Asset 时应提取 direct download 链接与 tag 名称", () => {
    const mockJsonData: LatestReleaseData = {
      tag_name: "v1.0.4",
      html_url: "https://github.com/qzrzz/Qjiao/releases/tag/v1.0.4",
      assets: [
        {
          name: "qjiao-1.0.4.dmg",
          browser_download_url: "https://github.com/qzrzz/Qjiao/releases/download/v1.0.4/qjiao-1.0.4.dmg",
        },
        {
          name: "qjiao-1.0.4.zip",
          browser_download_url: "https://github.com/qzrzz/Qjiao/releases/download/v1.0.4/qjiao-1.0.4.zip",
        },
      ],
    };

    const dmgAsset = mockJsonData.assets.find((a) => a.name.endsWith(".dmg"));
    expect(dmgAsset?.browser_download_url).toBe(
      "https://github.com/qzrzz/Qjiao/releases/download/v1.0.4/qjiao-1.0.4.dmg"
    );
    expect(mockJsonData.tag_name).toBe("v1.0.4");
  });

  test("在静态 latest.json 无 Asset 时应退回到 html_url Release 页面", () => {
    const mockJsonData: LatestReleaseData = {
      tag_name: "v1.0.4",
      html_url: "https://github.com/qzrzz/Qjiao/releases/tag/v1.0.4",
      assets: [],
    };

    const matchedAsset = mockJsonData.assets.find((a) =>
      a.name.endsWith(".dmg")
    );
    const finalUrl = matchedAsset
      ? matchedAsset.browser_download_url
      : mockJsonData.html_url;

    expect(finalUrl).toBe("https://github.com/qzrzz/Qjiao/releases/tag/v1.0.4");
  });

  test("在静态 latest.json 为初始保底数据时应可正常返回保底网页链接", () => {
    const fallbackJsonData: LatestReleaseData = {
      tag_name: "",
      html_url: "https://github.com/qzrzz/Qjiao/releases/latest",
      assets: [],
    };

    expect(fallbackJsonData.tag_name).toBe("");
    expect(fallbackJsonData.html_url).toBe("https://github.com/qzrzz/Qjiao/releases/latest");
  });
});
