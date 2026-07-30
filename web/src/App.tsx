import { Agent } from "./Feature/Agent";
import { CodeFormatting } from "./Feature/CodeFormatting";
import { DevServer } from "./Feature/DevServer";
import { Files } from "./Feature/Files";
import { Footer } from "./Feature/Footer";
import { Git } from "./Feature/Git";
import { Hero } from "./Feature/Hero";
import { ImageBuild } from "./Feature/ImageBuild";
import { ImageViewer } from "./Feature/ImageViewer";
import { Launchers } from "./Feature/Launchers";
import { PackageManager } from "./Feature/PackageManager";
import { Project } from "./Feature/Project";
import { ScriptsTasks } from "./Feature/ScriptsTasks";
import { StickyHeader } from "./Feature/Header";
import { TopBar } from "./Feature/TopBar";
import { Runner } from "./Feature/Runner";

/** Qjiao 产品官网首页，仅负责按设计稿顺序组合独立功能组件。 */
export function App() {
  return (
    <main className="homePage" id="top">
      <StickyHeader />
      <TopBar />
      <Hero />

      <section className="featureCollection" aria-labelledby="projects-heading">
        <header className="pageSectionHeading pageSectionHeading--projects">
          <h2 id="projects-heading">Work Around Projects</h2>
          <p>
            Get your work done without leaving the terminal workspace — CLI, Agents, Files, and Git.
          </p>
        </header>
        <Agent />
        <Project />
        <Files />
        <ScriptsTasks />
        <Git />
        <Launchers />
      </section>

      <section className="featureCollection featureCollection--web" aria-labelledby="web-heading">
        <header className="pageSectionHeading pageSectionHeading--web">
          <h2 id="web-heading">Web Dev Friendly</h2>
          <p>Building web? You’ll love this.</p>
        </header>
        <PackageManager />
        <DevServer />
        <CodeFormatting />
        <Runner />
        <ImageViewer />
        <ImageBuild />
      </section>
      <Footer />
    </main>
  );
}
