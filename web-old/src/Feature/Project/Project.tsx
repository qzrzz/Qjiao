import projectComposite from "./assets/project-composite.png";
import "./Project.css";

/** 项目识别功能组。 */
export function Project() {
  return (
    <article className="featureGroup projectFeature" data-node-id="1:46">
      <div className="featureInfo">
        <h3>Project</h3>
        <p>Icons, names, and descriptions with themes to clearly distinguish projects</p>
      </div>
      <img
        className="projectFeatureShot"
        src={projectComposite}
        alt="Qjiao project overview and project icon picker"
      />
    </article>
  );
}
