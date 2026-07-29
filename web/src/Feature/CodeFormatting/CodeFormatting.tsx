import codeFormattingComposite from "./assets/code-formatting-composite.png";
import "./CodeFormatting.css";

/** 代码格式化功能组。 */
export function CodeFormatting() {
  return (
    <article
      className="featureGroup featureGroup--right featureGroup--bottom-copy codeFormattingFeature"
      data-node-id="1:70"
    >
      <div className="featureInfo">
        <h3>Code Formatting</h3>
        <p>Built-in editor support for oxfmt and Prettier</p>
      </div>
      <img
        className="codeFormattingFeatureShot"
        src={codeFormattingComposite}
        alt="Formatting with oxfmt and Prettier"
      />
    </article>
  );
}
