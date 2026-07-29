import imageBuild from "./assets/image-build.png";
import "./ImageBuild.css";

/** 图片构建与导出功能组。 */
export function ImageBuild() {
  return (
    <article className="featureGroup imageBuildFeature" data-node-id="1:111">
      <div className="featureInfo">
        <h3>Image Build</h3>
        <p>
          Image compression, resizing, and format conversion
          <br />
          with design-tool-grade export controls.
        </p>
      </div>
      <img
        className="imageBuildFeatureShot"
        src={imageBuild}
        alt="Qjiao image export and compression controls"
      />
    </article>
  );
}
