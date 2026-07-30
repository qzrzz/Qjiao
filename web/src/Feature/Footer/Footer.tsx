import { useLatestRelease } from "../Hero/useLatestRelease";
import "./Footer.css";

/** 官网页脚，提供品牌识别、下载入口、源码入口与版权信息。 */
export function Footer() {
  const { downloadUrl } = useLatestRelease("qzrzz", "Qjiao");

  return (
    <footer className="siteFooter">
      <div className="siteFooterInner">
        <div className="siteFooterBrandSection">
          <a className="siteFooterBrand" href="#top" aria-label="Back to the top of Qjiao">
            <img src="/qjiao-icon.png" width="40" height="40" alt="" />
            <span>Qjiao</span>
          </a>
          <p className="siteFooterTagline">A beginner-friendly terminal workspace for macOS.</p>
        </div>

        <div className="siteFooterActionsSection">
          <a
            className="siteFooterDownloadBtn"
            href={downloadUrl}
            target="_blank"
            rel="noreferrer"
            title="下载最新版本 Qjiao"
          >
            <DownloadIcon />
            <span>Download</span>
          </a>
          <div className="siteFooterSocialLinks">
            <a
              className="siteFooterLink"
              href="https://github.com/qzrzz/Qjiao"
              target="_blank"
              rel="noreferrer"
            >
              <GithubIcon />
              <span>View on GitHub</span>
            </a>
            <a
              className="siteFooterLink"
              href="https://x.com/qzrz256"
              target="_blank"
              rel="noreferrer"
            >
              <XIcon />
              <span>Follow @qzrz256</span>
            </a>
          </div>
        </div>

        <p className="siteFooterCopyright">
          © 2026 <a href="https://qzrzz.com">Qzrzz.com</a>
        </p>
      </div>
    </footer>
  );
}

/** 下载标识使用内联 SVG 图标。 */
function DownloadIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="7 10 12 15 17 10" />
      <line x1="12" y1="15" x2="12" y2="3" />
    </svg>
  );
}

/** GitHub 标识使用内联图标，避免为单个图标额外请求静态资源。 */
function GithubIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 2C6.477 2 2 6.58 2 12.232c0 4.52 2.865 8.356 6.84 9.71.5.095.683-.223.683-.495 0-.242-.01-1.042-.014-1.89-2.782.62-3.369-1.221-3.369-1.221-.455-1.184-1.11-1.5-1.11-1.5-.908-.64.069-.628.069-.628 1.004.072 1.532 1.056 1.532 1.056.892 1.566 2.339 1.113 2.91.851.09-.665.348-1.113.634-1.368-2.22-.26-4.555-1.14-4.555-5.074 0-1.121.39-2.037 1.03-2.755-.104-.26-.447-1.308.097-2.726 0 0 .84-.277 2.75 1.053A9.28 9.28 0 0 1 12 6.85c.85.004 1.706.117 2.504.344 1.909-1.33 2.748-1.053 2.748-1.053.546 1.418.203 2.466.1 2.726.64.718 1.028 1.634 1.028 2.755 0 3.944-2.34 4.812-4.566 5.067.358.32.677.946.677 1.907 0 1.378-.012 2.488-.012 2.827 0 .274.18.594.688.493C19.14 20.584 22 16.75 22 12.232 22 6.58 17.523 2 12 2Z" />
    </svg>
  );
}

/** X 标识使用内联图标，保持与 GitHub 链接一致的视觉重量。 */
function XIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="currentColor">
      <path d="M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932 6.064-6.933h0Zm-1.29 19.694h2.039L6.486 3.049H4.298L17.61 20.847Z" />
    </svg>
  );
}
