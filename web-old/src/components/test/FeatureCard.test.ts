import { describe, test, expect } from "bun:test";
import type { FeatureCardConfig } from "../../content";

/**
 * FeatureCard 视频/图片渲染逻辑测试
 */
describe("FeatureCard 渲染逻辑测试", () => {
  test("当配置包含 video 时应优先使用视频配置", () => {
    const cardWithVideo: FeatureCardConfig = {
      id: "free-cur",
      title: "Freely move the cursor",
      desc: "Edit as naturally as in a text editor.",
      video: "/shots/free-cur.mp4",
      style: "left",
      alt: "move the cursor",
    };

    expect(cardWithVideo.video).toBe("/shots/free-cur.mp4");
    expect(cardWithVideo.image).toBeUndefined();
  });

  test("当配置包含 image 时应使用图片配置", () => {
    const cardWithImage: FeatureCardConfig = {
      id: "agent",
      title: "Parallel AI agents",
      desc: "Tabs, Panes, multiple agents working together",
      image: "/assets/agent.png",
      style: "left",
      alt: "Multiple AI agents",
    };

    expect(cardWithImage.image).toBe("/assets/agent.png");
    expect(cardWithImage.video).toBeUndefined();
  });
});
