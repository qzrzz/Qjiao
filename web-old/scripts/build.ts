#!/usr/bin/env bun
import { $ } from "bun";
import chalk from "chalk";
import { existsSync, mkdirSync, rmSync, cpSync, writeFileSync, readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { uiDictMap, type SupportedLang } from "../src/i18n/dict";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** web 项目根路径与目标 docs 目录路径 */
const WEB_DIR = resolve(__dirname, "..");
const DIST_DIR = resolve(WEB_DIR, "dist");
const DOCS_DIR = resolve(WEB_DIR, "../docs");

/**
 * 清空指定的目录内容。如果目录不存在则重新创建空目录。
 * @param dirPath 需要清空的目录绝对路径
 */
export function cleanDirectory(dirPath: string): void {
  if (existsSync(dirPath)) {
    rmSync(dirPath, { recursive: true, force: true });
  }
  mkdirSync(dirPath, { recursive: true });
}

/**
 * 递归复制源目录下的所有内容到目标目录
 * @param srcDir 源目录绝对路径
 * @param destDir 目标目录绝对路径
 */
export function copyDirectoryContents(srcDir: string, destDir: string): void {
  if (!existsSync(srcDir)) {
    throw new Error(`源目录不存在: ${srcDir}`);
  }
  cpSync(srcDir, destDir, { recursive: true });
}

/**
 * 生成并优化的多语言 SEO 静态 HTML 文件
 */
function generateSeoHtml(templateHtml: string, lang: SupportedLang): string {
  const dict = uiDictMap[lang] || uiDictMap.en;

  // 1. 替换 html lang 属性
  let html = templateHtml.replace(/<html lang="[^"]*"/, `<html lang="${lang}"`);

  // 2. 替换 title
  html = html.replace(/<title>.*?<\/title>/, `<title>${dict.siteTitle}</title>`);

  // 3. 构造 SEO 多语言 hreflang 与 description 标签
  const seoHeadTags = `
    <meta name="description" content="${dict.metaDesc}">
    <link rel="alternate" hreflang="en" href="https://qzrzz.github.io/Qjiao/" />
    <link rel="alternate" hreflang="zh-Hans" href="https://qzrzz.github.io/Qjiao/zh-Hans/" />
    <link rel="alternate" hreflang="ja" href="https://qzrzz.github.io/Qjiao/ja/" />
    <link rel="alternate" hreflang="x-default" href="https://qzrzz.github.io/Qjiao/" />
  `;

  // 插入到 </head> 标签前
  html = html.replace("</head>", `${seoHeadTags}\n  </head>`);

  // 如果是在子目录（如 /zh-Hans/ 或 /ja/），调整相对静态资源引用路径前缀，确保资源完美载入
  if (lang !== "en") {
    // 将 href="./" 或 src="./" 转为 ../ 前缀以适应子目录深度
    html = html.replaceAll('="./', '="../');
    html = html.replaceAll('src="./', 'src="../');
    html = html.replaceAll('href="./', 'href="../');
  }

  return html;
}

/**
 * Web 项目多语言 SEO 构建并发布至 GitHub Pages docs 目录的核心流程
 */
export async function buildAndPublishDocs(): Promise<void> {
  console.log(chalk.bold.cyan("\n🚀 开始构建 Web 多语言 (i18n & SEO) 项目...\n"));

  // 1. 执行 Vite 构建
  console.log(chalk.blue("📦 步骤 1/5: 正在执行 Vite 打包构建..."));
  try {
    await $`bunx vite build`.cwd(WEB_DIR);
    console.log(chalk.green("✔ Vite 构建成功完成！\n"));
  } catch (error) {
    console.error(chalk.red("✖ Vite 构建发生错误："), error);
    process.exit(1);
  }

  // 2. 清空目标 docs 目录
  console.log(chalk.blue("🧹 步骤 2/5: 正在清空 ../docs 目录..."));
  cleanDirectory(DOCS_DIR);
  console.log(chalk.green(`✔ 已成功清空: ${chalk.gray(DOCS_DIR)}\n`));

  // 3. 复制 dist 内容至 docs
  console.log(chalk.blue("📋 步骤 3/5: 复制构建产物至 ../docs 目录..."));
  copyDirectoryContents(DIST_DIR, DOCS_DIR);
  console.log(chalk.green(`✔ 内容复制完成\n`));

  // 4. 生成多语言 SEO 静态 HTML 架构 (en / zh-Hans / ja)
  console.log(chalk.blue("🌐 步骤 4/5: 生成多语言 SEO 静态网页 (en, zh-Hans, ja)..."));
  const templateHtmlPath = resolve(DOCS_DIR, "index.html");
  const templateHtml = readFileSync(templateHtmlPath, "utf-8");

  const languages: SupportedLang[] = ["en", "zh-Hans", "ja"];

  for (const lang of languages) {
    const seoHtml = generateSeoHtml(templateHtml, lang);

    if (lang === "en") {
      // 默认英文输出到根 index.html
      writeFileSync(templateHtmlPath, seoHtml);
      console.log(chalk.green(`  ✔ 已生成默认/英文 SEO 静态页: ${chalk.gray("docs/index.html")}`));
    } else {
      // 中文 / 日文生成独立的多语言目录 index.html
      const langDir = resolve(DOCS_DIR, lang);
      mkdirSync(langDir, { recursive: true });
      writeFileSync(resolve(langDir, "index.html"), seoHtml);
      console.log(chalk.green(`  ✔ 已生成 ${lang} SEO 静态页: ${chalk.gray(`docs/${lang}/index.html`)}`));
    }
  }

  // 5. 创建 .nojekyll 解决 GitHub Pages Jekyll 校验限制
  console.log(chalk.blue("\n⚙️  步骤 5/6: 创建 GitHub Pages .nojekyll 文件..."));
  writeFileSync(resolve(DOCS_DIR, ".nojekyll"), "");
  console.log(chalk.green("✔ 已生成 .nojekyll 文件\n"));

  // 6. 确保 download.json 静态数据文件存在
  console.log(chalk.blue("📄 步骤 6/6: 检查静态 download.json 发布文件..."));
  const docsDownloadJsonPath = resolve(DOCS_DIR, "download.json");
  if (!existsSync(docsDownloadJsonPath)) {
    const fallbackDownloadJson = {
      schemaVersion: 1,
      version: "",
      tag: "",
      publishedAt: "",
      htmlUrl: "https://github.com/qzrzz/Qjiao/releases/latest",
      dmg: { name: "", url: "" },
      zip: { name: "", url: "" },
    };
    writeFileSync(docsDownloadJsonPath, JSON.stringify(fallbackDownloadJson, null, 2) + "\n");
    console.log(chalk.yellow(`⚠️ 未找到现存 download.json，已写入默认保底静态页数据: ${chalk.gray("docs/download.json")}`));
  } else {
    console.log(chalk.green(`✔ 静态 Release 数据页构建就绪: ${chalk.gray("docs/download.json")}`));
  }

  console.log(
    chalk.bold.bgGreen.black(
      " 🎉 Web 多语言 i18n & SEO 构建及 GitHub Pages docs 同步完成！ "
    ) + "\n"
  );
}

if (import.meta.main) {
  buildAndPublishDocs();
}
