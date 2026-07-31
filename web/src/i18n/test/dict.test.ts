import { describe, test, expect } from "bun:test";
import { getLangUrl, getRootRelativePath } from "../dict";

/**
 * 校验多语言目标 URL 与根目录静态文件相对路径计算逻辑的单元测试
 */
describe("i18n dict 路径解析逻辑测试", () => {
  test("处于英文根目录 (en) 时，应正确生成各语言的相对跳转路径", () => {
    expect(getLangUrl("en", "en")).toBe("./");
    expect(getLangUrl("zh-Hans", "en")).toBe("./zh-Hans/");
    expect(getLangUrl("ja", "en")).toBe("./ja/");
  });

  test("处于中文子目录 (zh-Hans) 时，应正确生成向上退一级或切换至其他语言的相对路径", () => {
    expect(getLangUrl("en", "zh-Hans")).toBe("../");
    expect(getLangUrl("zh-Hans", "zh-Hans")).toBe("./");
    expect(getLangUrl("ja", "zh-Hans")).toBe("../ja/");
  });

  test("处于日文子目录 (ja) 时，应正确生成向上退一级或切换至其他语言的相对路径", () => {
    expect(getLangUrl("en", "ja")).toBe("../");
    expect(getLangUrl("zh-Hans", "ja")).toBe("../zh-Hans/");
    expect(getLangUrl("ja", "ja")).toBe("./");
  });

  test("根据当前所在语言，应精确计算根目录下静态文件 (如 latest.json) 的相对路径", () => {
    expect(getRootRelativePath("latest.json", "en")).toBe("./latest.json");
    expect(getRootRelativePath("latest.json", "zh-Hans")).toBe("../latest.json");
    expect(getRootRelativePath("latest.json", "ja")).toBe("../latest.json");
  });
});
