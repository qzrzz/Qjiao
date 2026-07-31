export type SupportedLang = "en" | "zh-Hans" | "ja";

export interface UiDict {
  siteTitle: string;
  metaDesc: string;
  topBarFlavor: string;
  topBarFlavorLink: string;
  heroTagline: string;
  heroDesc: string;
  download: string;
  downloadSubText: string;
  downloadTitle: string;
  backToTop: string;
  github: string;
  viewOnGithub: string;
  followX: string;
  footerTagline: string;
  langSwitchName: string;
}

export const uiDictMap: Record<SupportedLang, UiDict> = {
  en: {
    siteTitle: "Qjiao - Beginner-Friendly Terminal Workspace",
    metaDesc:
      "Bringing TUI and GUI together — enjoy the power of TUI without the barriers of a traditional terminal. macOS native, free, no subscription.",
    topBarFlavor: "Another flavor of",
    topBarFlavorLink: "egoist/kero",
    heroTagline: "Beginner-Friendly Terminal Workspace",
    heroDesc:
      "Bringing TUI and GUI together — enjoy the power of TUI without the barriers of a traditional terminal. macOS native, free, no subscription.",
    download: "Download",
    downloadSubText: "macOS",
    downloadTitle: "Download Qjiao latest release",
    backToTop: "Back to top",
    github: "Github",
    viewOnGithub: "View on GitHub",
    followX: "Follow @qzrz256",
    footerTagline: "A beginner-friendly terminal workspace for macOS.",
    langSwitchName: "English",
  },
  "zh-Hans": {
    siteTitle: "Qjiao - 面向新手的终端工作区",
    metaDesc:
      "结合 TUI 与 GUI 的优势 — 享受 TUI 的强大功能，摒弃传统终端的门槛。原生、免费、开源。",
    topBarFlavor: "另一个风味的",
    topBarFlavorLink: "egoist/kero",
    heroTagline: "面向新手的终端工作区",
    heroDesc: "结合 TUI 与 GUI 的优势 — 享受 TUI 的强大功能，摒弃传统终端的门槛。原生、免费、开源。",
    download: "下载",
    downloadSubText: "macOS",
    downloadTitle: "下载最新版本 Qjiao",
    backToTop: "返回顶部",
    github: "Github",
    viewOnGithub: "在 GitHub 查看源码",
    followX: "关注 @qzrz256",
    footerTagline: "面向新手的终端工作区",
    langSwitchName: "简体中文",
  },
  ja: {
    siteTitle: "Qjiao - 初心者にも易しいターミナルワークスペース",
    metaDesc:
      "TUI と GUI の利点を融合 — TUI の強力な機能を活かしながら、従来のターミナルの敷居をなくす。ネイティブ、無料、オープンソース。",
    topBarFlavor: "もうひとつのフレーバー：",
    topBarFlavorLink: "egoist/kero",
    heroTagline: "初心者にも易しいターミナルワークスペース",
    heroDesc:
      "TUI と GUI の利点を融合 — TUI の強力な機能を活かしながら、従来のターミナルの敷居をなくす。ネイティブ、無料、オープンソース。",
    download: "ダウンロード",
    downloadSubText: "macOS",
    downloadTitle: "Qjiao の最新リリースをダウンロード",
    backToTop: "トップへ戻る",
    github: "Github",
    viewOnGithub: "GitHub で見る",
    followX: "@qzrz256 をフォロー",
    footerTagline: "macOS向け初心者フレンドリーなターミナルワークスペース。",
    langSwitchName: "日本語",
  },
};

/** 语言选择持久化存储在 localStorage 中的 key */
export const STORAGE_LANG_KEY = "qjiao_lang";

/** 解析当前环境下的语言（优先匹配 pathname，如 /zh-Hans/ /ja/） */
export function getCurrentLang(): SupportedLang {
  if (typeof window === "undefined") return "en";
  const path = window.location.pathname;
  if (path.includes("/zh-Hans") || path.includes("/zh")) return "zh-Hans";
  if (path.includes("/ja")) return "ja";
  return "en";
}

/**
 * 根据浏览器环境 (navigator.languages / navigator.language) 检测用户的系统语言偏好
 *
 * @param customLangs 可选的语言代码数组（用于单元测试模拟）
 * @returns {SupportedLang} 匹配到的支持语言，默认为 "en"
 */
export function detectBrowserLanguage(customLangs?: readonly string[]): SupportedLang {
  let languagesList: readonly string[] = [];

  if (customLangs) {
    languagesList = customLangs;
  } else if (typeof navigator !== "undefined") {
    languagesList = navigator.languages || (navigator.language ? [navigator.language] : []);
  }

  for (const lang of languagesList) {
    const lower = lang.toLowerCase();
    if (lower.startsWith("zh")) {
      return "zh-Hans";
    }
    if (lower.startsWith("ja")) {
      return "ja";
    }
    if (lower.startsWith("en")) {
      return "en";
    }
  }

  return "en";
}

/**
 * 获取当前用户的首选语言
 * 优先级：localStorage 用户偏好缓存 > 浏览器系统语言检测 > 默认 "en"
 *
 * @returns {SupportedLang} 用户首选语言
 */
export function getPreferredLanguage(): SupportedLang {
  if (typeof window !== "undefined" && typeof localStorage !== "undefined") {
    try {
      const saved = localStorage.getItem(STORAGE_LANG_KEY);
      if (saved === "zh-Hans" || saved === "ja" || saved === "en") {
        return saved as SupportedLang;
      }
    } catch {
      // 忽略 localStorage 访问受限的异常
    }
  }

  return detectBrowserLanguage();
}

/**
 * 持久化保存用户的语言选择偏好到 localStorage
 *
 * @param lang 目标语言代码
 */
export function setPreferredLanguage(lang: SupportedLang): void {
  if (typeof window !== "undefined" && typeof localStorage !== "undefined") {
    try {
      localStorage.setItem(STORAGE_LANG_KEY, lang);
    } catch {
      // 忽略 localStorage 写入受限异常
    }
  }
}

/**
 * 自动根据用户的首选语言处理页面重定向与偏好同步记录
 * 当用户处于根路径 (如 / 或 /index.html) 时，如果检测到的首选语言非英文 (如 zh-Hans 或 ja)，
 * 则自动重定向至对应语言的子目录页面；如果已经处于显式语言子目录中，则同步保存该语言偏好。
 *
 * @returns {boolean} 是否触发了页面重定向
 */
export function autoRedirectDefaultLanguage(): boolean {
  if (typeof window === "undefined") return false;

  const path = window.location.pathname;
  const isExplicitSubpath = path.includes("/zh-Hans") || path.includes("/ja");

  if (isExplicitSubpath) {
    const currentLang = path.includes("/zh-Hans") ? "zh-Hans" : "ja";
    setPreferredLanguage(currentLang);
    return false;
  }

  const preferredLang = getPreferredLanguage();
  if (preferredLang !== "en") {
    const search = window.location.search;
    const hash = window.location.hash;
    const redirectUrl = `./${preferredLang}/${search}${hash}`;
    window.location.replace(redirectUrl);
    return true;
  }

  return false;
}

/**
 * 根据当前语言与目标语言，获取多语言页面的目标 URL 相对路径
 * 解决在非英文子目录下点击语言切换跳转路径叠加导致的 404 问题
 *
 * @param targetLang 目标语言
 * @param currentLang 当前页面语言（若未提供则自动匹配当前环境）
 * @returns {string} 正确的目标相对 URL 路径
 */
export function getLangUrl(
  targetLang: SupportedLang,
  currentLang?: SupportedLang
): string {
  const cur = currentLang || getCurrentLang();

  // 当前处于英文根目录
  if (cur === "en") {
    if (targetLang === "en") return "./";
    return `./${targetLang}/`;
  }

  // 当前处于非英文子目录（如 /zh-Hans/ 或 /ja/）
  if (targetLang === "en") {
    return "../";
  }
  if (targetLang === cur) {
    return "./";
  }
  return `../${targetLang}/`;
}

/**
 * 获取相对于根目录的静态文件相对路径
 * 例如在 /zh-Hans/ 子目录下获取根目录的 latest.json 需返回 ../latest.json
 *
 * @param filename 文件相对名（如 "latest.json"）
 * @param currentLang 当前页面语言（若未提供则自动匹配当前环境）
 * @returns {string} 正确的根路径相对文件 URL
 */
export function getRootRelativePath(
  filename: string,
  currentLang?: SupportedLang
): string {
  const cur = currentLang || getCurrentLang();
  const cleanFilename = filename.startsWith("/") ? filename.slice(1) : filename;

  if (cur === "en") {
    return `./${cleanFilename}`;
  }
  return `../${cleanFilename}`;
}
