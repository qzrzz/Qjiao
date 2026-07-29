import devServerComposite from "./assets/dev-server-composite.png";
import "./DevServer.css";

/** 开发服务器端口识别功能组。 */
export function DevServer() {
  return (
    <article
      className="featureGroup featureGroup--right featureGroup--bottom-copy devServerFeature"
      data-node-id="1:64"
    >
      <div className="featureInfo">
        <h3>Detect Dev Server</h3>
        <p>
          Always know where your services are running
          <br />
          ports and links at a glance
        </p>
      </div>
      <img
        className="devServerFeatureShot"
        src={devServerComposite}
        alt="Detected development server ports"
      />
    </article>
  );
}
