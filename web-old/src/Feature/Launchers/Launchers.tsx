import launchersComposite from "./assets/launchers-composite.png";
import "./Launchers.css";

/** 应用、文档与终端启动器功能组。 */
export function Launchers() {
  return (
    <article className="featureGroup launchersFeature" data-node-id="1:93">
      <div className="featureInfo">
        <h3>Launchers</h3>
        <p>
          Start working in seconds.
          <br />
          launch apps, docs, and terminals instantly.
        </p>
      </div>
      <img
        className="launchersFeatureShot"
        src={launchersComposite}
        alt="Qjiao launcher interface"
      />
    </article>
  );
}
