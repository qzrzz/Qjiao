import imageViewer from "./assets/image-viewer.png";
import "./ImageViewer.css";

/** 内置图片查看器功能组。 */
export function ImageViewer() {
  return (
    <article className="featureGroup imageViewerFeature" data-node-id="1:105">
      <div className="featureInfo">
        <h3>Powerful Image Viewer</h3>
        <p>
          built-in full-featured image viewer with metadata, rulers, pixel
          inspection, comparison mode, and more.
        </p>
      </div>
      <img
        className="featureShot"
        src={imageViewer}
        alt="Qjiao image viewer with rulers and metadata"
      />
    </article>
  );
}
