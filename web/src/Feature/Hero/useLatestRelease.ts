import { useEffect, useState } from "react";

/** GitHub Release 资源文件结构定义 */
interface GitHubAsset {
  /** 资源文件名 */
  name: string;
  /** 资源文件直接下载地址 */
  browser_download_url: string;
}

/** GitHub Latest Release API 响应结构定义 */
interface GitHubReleaseResponse {
  /** 发布版本标签名称，如 "v1.0.0" */
  tag_name?: string;
  /** 发布页面 HTML 链接 */
  html_url?: string;
  /** 资源文件列表 */
  assets?: GitHubAsset[];
}

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
 * @returns {ReleaseInfo} 最新 Release 的下载链接、版本显示文本以及加载状态
 */
export function useLatestRelease(
  owner: string = "qzrzz",
  repo: string = "Qjiao"
): ReleaseInfo {
  const defaultReleaseUrl = `https://github.com/${owner}/${repo}/releases/latest`;

  const [info, setInfo] = useState<ReleaseInfo>({
    downloadUrl: defaultReleaseUrl,
    versionText: "macOS",
    tagName: null,
    isLoading: true,
  });

  useEffect(() => {
    let isMounted = true;
    const apiUrl = `https://api.github.com/repos/${owner}/${repo}/releases/latest`;

    fetch(apiUrl)
      .then((res) => {
        if (!res.ok) {
          throw new Error(`请求 GitHub API 失败: ${res.status}`);
        }
        return res.json() as Promise<GitHubReleaseResponse>;
      })
      .then((data) => {
        if (!isMounted) return;

        const tagName = data.tag_name || "";
        const htmlUrl = data.html_url || defaultReleaseUrl;
        const assets = data.assets || [];

        // 优先匹配 .dmg 安装包，其次为 .zip 或 .pkg 等 macOS 发布产物
        const dmgAsset = assets.find((asset) =>
          asset.name.toLowerCase().endsWith(".dmg")
        );
        const zipAsset = assets.find((asset) =>
          asset.name.toLowerCase().endsWith(".zip")
        );
        const pkgAsset = assets.find((asset) =>
          asset.name.toLowerCase().endsWith(".pkg")
        );

        const matchedAsset = dmgAsset || zipAsset || pkgAsset;
        // 如果有可直接下载的 Asset 安装包则优先链接，否则链接到 Tag Release 页面或 Latest 页面
        const finalDownloadUrl = matchedAsset
          ? matchedAsset.browser_download_url
          : htmlUrl;

        setInfo({
          downloadUrl: finalDownloadUrl,
          versionText: "macOS",
          tagName: tagName || null,
          isLoading: false,
        });
      })
      .catch((err) => {
        // 请求 API 失败时（如限流或离线），静默退回到默认 Releases 地址
        if (isMounted) {
          setInfo({
            downloadUrl: defaultReleaseUrl,
            versionText: "macOS",
            tagName: null,
            isLoading: false,
          });
        }
      });

    return () => {
      isMounted = false;
    };
  }, [owner, repo]);

  return info;
}
