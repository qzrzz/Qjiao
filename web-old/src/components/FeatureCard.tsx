import React from "react";
import type { FeatureCardConfig } from "../content";

interface FeatureCardProps {
  card: FeatureCardConfig;
}

/** 格式化文本换行（处理带有 '\n' 的文本） */
function renderMultilineText(text: string): React.ReactNode {
  const lines = text.split("\n");
  return lines.map((line, index) => (
    <React.Fragment key={index}>
      {line}
      {index < lines.length - 1 && <br />}
    </React.Fragment>
  ));
}

/**
 * 现代规整的通用功能卡片组件。
 * 符合 left, right, bottom 3 种规范化卡片风格与 BEM 命名规范。
 */
export function FeatureCard({ card }: FeatureCardProps) {
  const {
    id,
    title,
    desc,
    image,
    video,
    style = "left",
    alt,
    cardClassName,
    dataNodeId,
  } = card;

  // BEM 规范类名推导：
  // 1. 基础类: featureCard
  // 2. 风格修饰类: featureCard--left | featureCard--right | featureCard--bottom
  // 3. 卡片ID修饰类: featureCard--<id> (如 featureCard--dev-server)
  const containerClasses = [
    "featureCard",
    `featureCard--${style}`,
    `featureCard--${id}`,
    cardClassName,
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <article className={containerClasses} data-node-id={dataNodeId}>
      <div className="featureCard__info">
        <h3>{title}</h3>
        <p>{renderMultilineText(desc)}</p>
      </div>
      {video ? (
        <div className="featureCard__videoContainer">
          <video
            className="featureCard__video"
            src={video}
            autoPlay
            loop
            muted
            playsInline
            aria-label={alt || title}
          />
        </div>
      ) : (
        <img className="featureCard__shot" src={image} alt={alt || title} />
      )}
    </article>
  );
}
