import { useEffect, useState } from "react";
import { getCurrentLang, getRootRelativePath, type SupportedLang } from "../../i18n/dict";
import { resolveReleaseDownload } from "./downloadManifest";

/** Release 信息 Hook 返回的状态接口 */
export interface ReleaseInfo {
  /** 下载目标 URL，优先使用 Asset 直接下载链接，保底退至 Release 页面 */
  downloadUrl: string;
  /** 显示在下载按钮上的副标题文本 */
  versionText: string;
  /** Release 版本标签名称（若成功获取） */
  tagName: string | null;
  /** 是否正在加载最新 Release 数据 */
  isLoading: boolean;
}

/**
 * 获取指定 GitHub 仓库最新 Release 下载地址与版本信息的自定义 Hook
 *
 * @param owner GitHub 仓库拥有者名称，默认为 "qzrzz"
 * @param repo GitHub 仓库名称，默认为 "Qjiao"
 * @param lang 当前页面语言（若不传自动从 location 获取）
 * @returns {ReleaseInfo} 最新 Release 的下载链接、版本显示文本以及加载状态
 */
export function useLatestRelease(
  owner: string = "qzrzz",
  repo: string = "Qjiao",
  lang?: SupportedLang
): ReleaseInfo {
  const currentLang = lang || getCurrentLang();
  const defaultReleaseUrl = `https://github.com/${owner}/${repo}/releases/latest`;

  const [info, setInfo] = useState<ReleaseInfo>({
    downloadUrl: defaultReleaseUrl,
    versionText: "macOS",
    tagName: null,
    isLoading: true,
  });

  useEffect(() => {
    let isMounted = true;

    const loadRelease = async () => {
      const manifestUrl = getRootRelativePath("download.json", currentLang);
      const legacyUrl = getRootRelativePath("latest.json", currentLang);

      const data =
        (await fetchStaticJson(manifestUrl)) ??
        (await fetchStaticJson(legacyUrl));
      if (!isMounted) return;

      if (!data) {
        setInfo({
          downloadUrl: defaultReleaseUrl,
          versionText: "macOS",
          tagName: null,
          isLoading: false,
        });
        return;
      }

      const resolved = resolveReleaseDownload(data, defaultReleaseUrl);
      setInfo({
        downloadUrl: resolved.downloadUrl,
        versionText: "macOS",
        tagName: resolved.tagName,
        isLoading: false,
      });
    };

    void loadRelease();

    return () => {
      isMounted = false;
    };
  }, [owner, repo, currentLang, defaultReleaseUrl]);

  return info;
}

async function fetchStaticJson(url: string): Promise<unknown | null> {
  try {
    const response = await fetch(url);
    if (!response.ok) return null;
    return (await response.json()) as unknown;
  } catch {
    return null;
  }
}
