import { useEffect, useState } from "react";
import { useLatestRelease } from "../Hero/useLatestRelease";
import "./StickyHeader.css";

/**
 * 顶部固定 Header 组件
 * 
 * 当首屏 Hero 区域的 download 按钮滚动离开视口范围时自动淡入展现，
 * 包含品牌标志与导航至 Release 下载及 GitHub 仓库的便捷按钮组。
 */
export function StickyHeader() {
  const [isVisible, setIsVisible] = useState(false);
  const { downloadUrl } = useLatestRelease("qzrzz", "Qjiao");

  useEffect(() => {
    const targetNode = document.getElementById("hero-download");
    if (!targetNode) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        // 当元素脱离视口 (isIntersecting 为 false)，且顶边滚动到了视口上方 (boundingClientRect.top < 0) 时显示 Header
        const isOutOfView = !entry.isIntersecting && entry.boundingClientRect.top < 0;
        setIsVisible(isOutOfView);
      },
      {
        threshold: 0,
      }
    );

    observer.observe(targetNode);

    return () => {
      observer.disconnect();
    };
  }, []);

  /**
   * 点击 Logo 平滑滚动回页面顶部
   */
  const handleScrollToTop = (e: React.MouseEvent<HTMLAnchorElement>) => {
    e.preventDefault();
    window.scrollTo({
      top: 0,
      behavior: "smooth",
    });
  };

  return (
    <header
      className={`stickyHeader ${isVisible ? "stickyHeader--visible" : ""}`}
      aria-hidden={!isVisible}
    >
      <div className="stickyHeaderInner">
        <a
          className="stickyHeaderBrand"
          href="#top"
          onClick={handleScrollToTop}
          title="返回顶部"
        >
          <img src="/qjiao-icon.png" width="32" height="32" alt="Qjiao Logo" />
          <span>Qjiao</span>
        </a>

        <div className="stickyHeaderActions">
          <a
            className="stickyHeaderBtn stickyHeaderBtn--download"
            href={downloadUrl}
            target="_blank"
            rel="noreferrer"
            title="下载最新版本 Qjiao"
          >
            Download
          </a>
          <a
            className="stickyHeaderBtn stickyHeaderBtn--github"
            href="https://github.com/qzrzz/Qjiao"
            target="_blank"
            rel="noreferrer"
            title="前往 GitHub 仓库"
          >
            <GithubIcon />
            <span>Github</span>
          </a>
        </div>
      </div>
    </header>
  );
}

/**
 * GitHub 内联矢量图标组件
 */
function GithubIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 2C6.477 2 2 6.58 2 12.232c0 4.52 2.865 8.356 6.84 9.71.5.095.683-.223.683-.495 0-.242-.01-1.042-.014-1.89-2.782.62-3.369-1.221-3.369-1.221-.455-1.184-1.11-1.5-1.11-1.5-.908-.64.069-.628.069-.628 1.004.072 1.532 1.056 1.532 1.056.892 1.566 2.339 1.113 2.91.851.09-.665.348-1.113.634-1.368-2.22-.26-4.555-1.14-4.555-5.074 0-1.121.39-2.037 1.03-2.755-.104-.26-.447-1.308.097-2.726 0 0 .84-.277 2.75 1.053A9.28 9.28 0 0 1 12 6.85c.85.004 1.706.117 2.504.344 1.909-1.33 2.748-1.053 2.748-1.053.546 1.418.203 2.466.1 2.726.64.718 1.028 1.634 1.028 2.755 0 3.944-2.34 4.812-4.566 5.067.358.32.677.946.677 1.907 0 1.378-.012 2.488-.012 2.827 0 .274.18.594.688.493C19.14 20.584 22 16.75 22 12.232 22 6.58 17.523 2 12 2Z" />
    </svg>
  );
}
