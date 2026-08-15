import packageManager from "./assets/package-manager.png";
import "./PackageManager.css";

/** 包管理器支持功能组。 */
export function PackageManager() {
  return (
    <article className="featureGroup packageManagerFeature" data-node-id="1:99">
      <div className="featureInfo">
        <h3>Package manager support</h3>
        <p>
          Quickly edit package versions, detect NPM Scripts, discover dev server
          ports, and more.
        </p>
      </div>
      <img
        className="featureShot"
        src={packageManager}
        alt="Package version and dependency management in Qjiao"
      />
    </article>
  );
}
