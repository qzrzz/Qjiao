import { describe, test, expect } from "bun:test";
import {
  detectBrowserLanguage,
  getLangUrl,
  getPreferredLanguage,
  getRootRelativePath,
  setPreferredLanguage,
  STORAGE_LANG_KEY,
  autoRedirectDefaultLanguage,
} from "../dict";

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

/**
 * 校验用户系统语言检测与默认语言判断的单元测试
 */
describe("i18n 浏览器语言检测与默认语言判断测试", () => {
  test("当系统首选语言包含中文 (如 zh-CN, zh-TW, zh) 时应匹配为 zh-Hans", () => {
    expect(detectBrowserLanguage(["zh-CN", "en-US"])).toBe("zh-Hans");
    expect(detectBrowserLanguage(["zh-TW"])).toBe("zh-Hans");
    expect(detectBrowserLanguage(["zh"])).toBe("zh-Hans");
  });

  test("当系统首选语言包含日文 (如 ja-JP, ja) 时应匹配为 ja", () => {
    expect(detectBrowserLanguage(["ja-JP", "en-US"])).toBe("ja");
    expect(detectBrowserLanguage(["ja"])).toBe("ja");
  });

  test("当系统首选语言为英文或其他不支持语言时应退回 en", () => {
    expect(detectBrowserLanguage(["en-US", "zh-CN"])).toBe("en");
    expect(detectBrowserLanguage(["fr-FR", "de-DE"])).toBe("en");
    expect(detectBrowserLanguage([])).toBe("en");
  });

  test("应正确读写 localStorage 中的用户语言偏好记录", () => {
    const store = new Map<string, string>();
    const mockStorage = {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, val: string) => store.set(key, val),
      removeItem: (key: string) => store.delete(key),
      clear: () => store.clear(),
    };

    // @ts-ignore
    globalThis.localStorage = mockStorage;
    // @ts-ignore
    globalThis.window = { location: { pathname: "/" } } as any;

    setPreferredLanguage("zh-Hans");
    expect(mockStorage.getItem(STORAGE_LANG_KEY)).toBe("zh-Hans");
    expect(getPreferredLanguage()).toBe("zh-Hans");

    setPreferredLanguage("ja");
    expect(mockStorage.getItem(STORAGE_LANG_KEY)).toBe("ja");
    expect(getPreferredLanguage()).toBe("ja");

    setPreferredLanguage("en");
    expect(mockStorage.getItem(STORAGE_LANG_KEY)).toBe("en");
    expect(getPreferredLanguage()).toBe("en");
  });

  test("处在显式语言子目录路径时，autoRedirectDefaultLanguage 应自动将该语言持久化保存并返回 false", () => {
    const store = new Map<string, string>();
    const mockStorage = {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, val: string) => store.set(key, val),
    };

    let replacedUrl = "";
    // @ts-ignore
    globalThis.localStorage = mockStorage;
    // @ts-ignore
    globalThis.window = {
      location: {
        pathname: "/Qjiao/zh-Hans/",
        search: "",
        hash: "",
        replace: (url: string) => {
          replacedUrl = url;
        },
      },
    } as any;

    const redirected = autoRedirectDefaultLanguage();
    expect(redirected).toBe(false);
    expect(mockStorage.getItem(STORAGE_LANG_KEY)).toBe("zh-Hans");

    // 切换到根路径且偏好语言为 ja 时，测试自动重定向功能
    mockStorage.setItem(STORAGE_LANG_KEY, "ja");
    // @ts-ignore
    globalThis.window.location.pathname = "/Qjiao/";
    const redirectedJa = autoRedirectDefaultLanguage();
    expect(redirectedJa).toBe(true);
    expect(replacedUrl).toBe("./ja/");
  });
});

