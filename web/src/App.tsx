import { useEffect } from "react";
import { FeatureSection } from "./components/FeatureSection";
import { getSectionsContent } from "./content";
import { Footer } from "./Feature/Footer";
import { StickyHeader } from "./Feature/Header";
import { Hero } from "./Feature/Hero";
import { TopBar } from "./Feature/TopBar";
import { autoRedirectDefaultLanguage, getCurrentLang, type SupportedLang } from "./i18n/dict";

interface AppProps {
  lang?: SupportedLang;
}

/** Qjiao 产品官网首页，支持多语言静态输出与动态感知。 */
export function App({ lang }: AppProps) {
  useEffect(() => {
    autoRedirectDefaultLanguage();
  }, []);

  const currentLang = lang || getCurrentLang();
  const sections = getSectionsContent(currentLang);

  return (
    <main className="homePage" id="top">
      <StickyHeader lang={currentLang} />
      <TopBar lang={currentLang} />
      <Hero lang={currentLang} />

      {sections.map((section) => (
        <FeatureSection key={section.id} section={section} />
      ))}

      <Footer lang={currentLang} />
    </main>
  );
}
