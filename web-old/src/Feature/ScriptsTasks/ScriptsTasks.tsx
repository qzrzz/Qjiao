import scripts from "./assets/scripts.png";
import "./ScriptsTasks.css";

/** Scripts 与 Tasks 可视化运行功能组。 */
export function ScriptsTasks() {
  return (
    <article className="featureGroup featureGroup--right scriptsTasksFeature" data-node-id="1:58">
      <div className="featureInfo">
        <h3>Scripts &amp; Tasks</h3>
        <p>
          NPM Scripts, Gradle Tasks, Cargo, CMake, and more visualize your
          commands and run them with one click
        </p>
      </div>
      <img className="featureShot" src={scripts} alt="Visual task and script runner" />
    </article>
  );
}
