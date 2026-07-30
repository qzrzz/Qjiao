import imageBuild from "./Runner.png";
import "./Runner.css";

/** 图片构建与导出功能组。 */
export function Runner() {
  return (
    <article className="featureGroup RunnerFeature">
      <div className="featureInfo">
        <h3>Script Runner</h3>
        <p>
           Run TS, JS, Python, Go, and Rust files with one click. 
   
        </p>
      </div>
      <img
        className="RunnerFeatureShot"
        src={imageBuild}
        alt="run tsx script"
      />
    </article>
  );
}
