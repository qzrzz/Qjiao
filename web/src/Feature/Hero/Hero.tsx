import { motion, useReducedMotion } from "motion/react";
import { getCurrentLang, uiDictMap, type SupportedLang } from "../../i18n/dict";
import iconBackground from "./assets/icon-background.png";
import iconGlowBottom from "./assets/icon-glow-bottom.svg";
import iconGlowTop from "./assets/icon-glow-top.svg";
import iconMask from "./assets/icon-mask.svg";
import iconPepper from "./assets/icon-pepper.png";
import workspace from "./assets/workspace.png";
import "./Hero.css";
import { useLatestRelease } from "./useLatestRelease";

interface HeroProps {
  lang?: SupportedLang;
}

/** Hero 首屏组件，支持多语言标语与说明。 */
export function Hero({ lang }: HeroProps) {
  const reduceMotion = useReducedMotion();
  const restingPosition = { x: 12.109, y: -5.328 };
  const currentLang = lang || getCurrentLang();
  const { downloadUrl, tagName } = useLatestRelease("qzrzz", "Qjiao", currentLang);
  const dict = uiDictMap[currentLang] || uiDictMap.en;

  return (
    <section className="hero" aria-labelledby="hero-title">
      <div className="heroIcon" aria-hidden="true" data-node-id="1:123">
        <img
          className="heroIconBackground"
          src={iconBackground}
          alt=""
          decoding="sync"
          fetchPriority="high"
        />
        <div className="heroIconArtwork">
          <div
            className="heroIconMaskGroup"
            data-node-id="1:125"
            data-name="Group 2"
            style={{ maskImage: `url("${iconMask}")` }}
          >
            <span
              className="heroIconMaskSource"
              data-node-id="1:126"
              data-name="Mask"
            />
            <img
              className="heroIconBlendBackdrop"
              src={iconBackground}
              alt=""
              decoding="sync"
              fetchPriority="high"
            />
            <div className="heroIconGlow heroIconGlow--top" data-node-id="1:127">
              <div className="heroIconGlowRotated">
                <img src={iconGlowTop} alt="" />
              </div>
            </div>
            <div className="heroIconGlow heroIconGlow--bottom" data-node-id="1:128">
              <div className="heroIconGlowRotated">
                <img src={iconGlowBottom} alt="" />
              </div>
            </div>
            <motion.div
              className="heroIconPepperMotion"
              data-node-id="1:129"
              data-motion-keys="x,y"
              data-motion-wrapper-for="1:129"
              initial={reduceMotion ? restingPosition : { x: 83.797, y: 100.266 }}
              animate={
                reduceMotion
                  ? restingPosition
                  : {
                      x: [83.797, 44.58, 12.109],
                      y: [100.266, 42.501, -5.328],
                    }
              }
              transition={
                reduceMotion
                  ? undefined
                  : {
                      x: {
                        duration: 4,
                        times: [0, 0.1477, 1],
                        ease: ["linear", [0, 0, 0, 0.947]],
                        repeat: Infinity,
                        repeatType: "reverse",
                      },
                      y: {
                        duration: 4,
                        times: [0, 0.1477, 1],
                        ease: ["linear", [0, 0, 0, 0.947]],
                        repeat: Infinity,
                        repeatType: "reverse",
                      },
                    }
              }
            >
              <div className="heroIconPepper">
                <img
                  src={iconPepper}
                  alt=""
                  decoding="sync"
                  fetchPriority="high"
                />
              </div>
            </motion.div>
          </div>
        </div>
      </div>

      <h1 id="hero-title">Qjiao</h1>
      <p className="heroTagline">{dict.heroTagline}</p>
      <p className="heroDescription">{dict.heroDesc}</p>
      <a
        id="hero-download"
        className="heroDownload"
        href={downloadUrl}
        target="_blank"
        rel="noreferrer"
        title={tagName ? `${dict.download} Qjiao ${tagName}` : dict.downloadTitle}
      >
        {dict.download} <span className="sub">{dict.downloadSubText}</span>
      </a>
      <img className="heroWorkspace" src={workspace} alt="Qjiao terminal workspace interface" />
    </section>
  );
}
