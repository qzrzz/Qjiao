import git from "./assets/git.png";
import "./Git.css";

/** Git 可视化操作功能组。 */
export function Git() {
  return (
    <article className="featureGroup gitFeature" data-node-id="1:87">
      <div className="featureInfo">
        <h3>Git</h3>
        <p>
          Visualize common Git operations and generate commit messages with one
          click — powered by your Agent CLI, <strong>NO</strong> API key required.
        </p>
      </div>
      <img className="featureShot" src={git} alt="Qjiao Git changes and commit interface" />
    </article>
  );
}
