import agent from "./assets/agent.png";
import "./Agent.css";

/** AI Agent 功能组。 */
export function Agent() {
  return (
    <article className="featureGroup agentFeature" data-node-id="1:76">
      <div className="featureInfo">
        <h3>Parallel AI agents</h3>
        <p>Tabs, Panes, multiple agents working together</p>
      </div>
      <img className="featureShot" src={agent} alt="Multiple AI agents working in Qjiao panes" />
    </article>
  );
}
