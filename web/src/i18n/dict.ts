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

/** 解析当前环境下的语言（优先匹配 pathname，如 /zh-Hans/ /ja/） */
export function getCurrentLang(): SupportedLang {
  if (typeof window === "undefined") return "en";
  const path = window.location.pathname;
  if (path.includes("/zh-Hans") || path.includes("/zh")) return "zh-Hans";
  if (path.includes("/ja")) return "ja";
  return "en";
}

/** 获取多语言页面的目标 URL 路径 */
export function getLangUrl(targetLang: SupportedLang): string {
  const baseUrl = import.meta.env.BASE_URL || "/";
  const cleanBase = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;

  if (targetLang === "en") {
    return cleanBase;
  }
  return `${cleanBase}${targetLang}/`;
}
