import type { SectionConfig } from "../content";
import { FeatureCard } from "./FeatureCard";

interface FeatureSectionProps {
  section: SectionConfig;
}

/** 通用分区渲染组件，自动根据 section.id 匹配对应 header 与 collection 样式类。 */
export function FeatureSection({ section }: FeatureSectionProps) {
  const headingId = `${section.id}-heading`;

  // 根据 id 自动匹配 CSS class
  const sectionClassMap: Record<string, { collection?: string; heading?: string }> = {
    projects: { heading: "pageSectionHeading--projects" },
    "web-dev": { collection: "featureCollection--web", heading: "pageSectionHeading--web" },
    web: { collection: "featureCollection--web", heading: "pageSectionHeading--web" },
  };

  const matched = sectionClassMap[section.id] || {};
  const sectionClasses = ["featureCollection", matched.collection, section.className]
    .filter(Boolean)
    .join(" ");
  const headingClasses = ["pageSectionHeading", matched.heading]
    .filter(Boolean)
    .join(" ");

  return (
    <section className={sectionClasses} aria-labelledby={headingId}>
      <header className={headingClasses}>
        <h2 id={headingId}>{section.title}</h2>
        <p>{section.description}</p>
      </header>
      {section.cards.map((card) => (
        <FeatureCard key={card.id} card={card} />
      ))}
    </section>
  );
}
