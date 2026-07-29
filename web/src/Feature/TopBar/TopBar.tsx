import "./TopBar.css";

/** 官网顶部栏，说明 Qjiao 与上游 Kero 的关系。 */
export function TopBar() {
  return (
    <header className="siteTopBar">
      <div className="siteTopBarInner">
        <a
          className="siteTopBarGithub"
          href="https://github.com/qzrzz/Qjiao"
          target="_blank"
          rel="noreferrer"
          aria-label="Qjiao on GitHub"
        >
          <GithubIcon />
          <span>GitHub</span>
        </a>
        <span>
          Another flavor of {" "}
          <a href="https://github.com/egoist/kero" target="_blank" rel="noreferrer">
            egoist/kero
          </a>
        </span>
      </div>
    </header>
  );
}

/** GitHub 标识用于官网仓库入口。 */
function GithubIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 2C6.477 2 2 6.58 2 12.232c0 4.52 2.865 8.356 6.84 9.71.5.095.683-.223.683-.495 0-.242-.01-1.042-.014-1.89-2.782.62-3.369-1.221-3.369-1.221-.455-1.184-1.11-1.5-1.11-1.5-.908-.64.069-.628.069-.628 1.004.072 1.532 1.056 1.532 1.056.892 1.566 2.339 1.113 2.91.851.09-.665.348-1.113.634-1.368-2.22-.26-4.555-1.14-4.555-5.074 0-1.121.39-2.037 1.03-2.755-.104-.26-.447-1.308.097-2.726 0 0 .84-.277 2.75 1.053A9.28 9.28 0 0 1 12 6.85c.85.004 1.706.117 2.504.344 1.909-1.33 2.748-1.053 2.748-1.053.546 1.418.203 2.466.1 2.726.64.718 1.028 1.634 1.028 2.755 0 3.944-2.34 4.812-4.566 5.067.358.32.677.946.677 1.907 0 1.378-.012 2.488-.012 2.827 0 .274.18.594.688.493C19.14 20.584 22 16.75 22 12.232 22 6.58 17.523 2 12 2Z" />
    </svg>
  );
}
