import files from "./assets/files.png";
import "./Files.css";

/** 文件管理功能组。 */
export function Files() {
  return (
    <article className="featureGroup filesFeature" data-node-id="1:52">
      <div className="featureInfo">
        <h3>Files</h3>
        <p>
          Full-featured file management without leaving the terminal — icons,
          sizes, keyboard navigation, image previews, Spacebar Quick Look, and more.
        </p>
      </div>
      <img className="featureShot" src={files} alt="Qjiao file manager" />
    </article>
  );
}
