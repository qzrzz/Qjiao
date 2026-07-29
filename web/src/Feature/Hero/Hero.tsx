import { Button } from "@base-ui/react/button";
import { motion, useReducedMotion } from "motion/react";
import iconBackground from "./assets/icon-background.png";
import iconGlowBottom from "./assets/icon-glow-bottom.svg";
import iconGlowTop from "./assets/icon-glow-top.svg";
import iconMask from "./assets/icon-mask.svg";
import iconPepper from "./assets/icon-pepper.png";
import workspace from "./assets/workspace.png";
import "./Hero.css";

/** Figma 首屏，包含应用图标关键帧动画与产品主界面。 */
export function Hero() {
  const reduceMotion = useReducedMotion();
  const restingPosition = { x: 12.109, y: -5.328 };

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
      <p className="heroTagline">Beginner-Friendly Terminal Workspace</p>
      <p className="heroDescription">
        Bringing TUI and GUI together — enjoy the power of TUI without the
        barriers of a traditional terminal.
      </p>
      <Button className="heroDownload">Download 13MB Native macOS</Button>
      <img className="heroWorkspace" src={workspace} alt="Qjiao terminal workspace interface" />
    </section>
  );
}
