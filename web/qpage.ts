import { IPageMeta, ISection, IQPageConfig } from "qpage";

export const config: IQPageConfig = {
  defaultLang: "zh-Hans",
};

import UrlIcon from "./icons/icon-512.png";
import UrlIconFull from "./icons/icon-full.png";

import UrlMainScreenshotImage from "./assets/workspace.png";

export const page: IPageMeta = {
  productTitle: "Qjiao",
  productTitleCN: "青椒终端",
  tagline:
    "面向新手的终端工作区，终端、Agent、文件管理、代码编辑/运行、Git、图片处理... 原生、免费、开源",

  taglineShort: "终端工作区",
  platforms: ["macos"],
  icon: UrlIcon,
  iconFull: UrlIconFull,
  metaDesc: "macOS 文件复制工具。海量小文件、外置磁盘与 NAS 也能快速复制，FastCopy macOS 版本",
  githubRepo: "https://github.com/qzrzz/Qjiao",
  downloadBase: "https://download.qzrzz.com/qjiao",
  mainScreenshotImage: UrlMainScreenshotImage,
};

export const sections: ISection[] = [
  {
    id: "fdl",

    cards: [
      {
        id: "free-cur",
        title: "光标自由移动",
        desc: "像在文本编辑器中一样自然地移动与编辑。",
        video: "./assets/free-cur.mp4",
        style: "center",
      },
    ],
  },

  {
    id: "projects",
    title: "围绕项目高效协作",
    description: "无需离开终端工作区即可完成一切工作 — CLI、AI Agent、文件管理与 Git 交互。",

    cards: [
      {
        id: "agent",
        title: "多 Agent 并行协作",
        desc: "多标签页、多分屏，支持多个 AI Agent 协同工作",
        image: "./assets/agent.png",
        style: "center",
      },
      {
        id: "project",
        title: "项目识别",
        desc: "自定义图标、项目名称与描述，配合色彩主题清晰区分多项目",
        image: "./assets/project-composite.png",
        style: "center",
      },
      {
        id: "files",
        title: "文件管理",
        desc: "在终端旁直接管理文件，本应如此 \n类型图标、文件大小、键盘导航、图片预览及空格键快速预览。",
        image: "./assets/files.png",
        style: "center",
      },
      {
        id: "scripts-tasks",
        title: "脚本与任务",
        desc: "可视化运行 NPM Scripts、Gradle Tasks、Cargo、CMake \n一键快速执行",
        image: "./assets/scripts.png",
        style: "center",
      },
      {
        id: "git",
        title: "Git",
        desc: "可视化常用 Git 操作，一键生成 Commit 提交信息\n由本地 Agent CLI 驱动，无需配置 API Key。",
        image: "./assets/git.png",
        style: "center",
      },
      {
        id: "launchers",
        title: "快捷启动器",
        desc: "快速开启项目所需各种工具\n一键启动应用、文档、终端、打开文件夹。",
        image: "./assets/launchers-composite.png",
        style: "center",
      },
    ],
  },
  {
    id: "web-dev",
    title: "Web 开发体验增强",
    description: "正在开发 Web 项目？你会爱上这些特性。",
    cards: [
      {
        id: "package-manager",
        title: "包管理器集成",
        desc: "快速修改依赖版本、自动识别 NPM Scripts、识别开发服务器端口等。",
        image: "./assets/package-manager.png",
        style: "center",
      },
      {
        id: "dev-server",
        title: "开发服务器端口识别",
        desc: "随时掌握服务运行状态\n端口与预览链接一目了然",
        image: "./assets/dev-server-composite.png",
        style: "center",
      },
      {
        id: "code-formatting",
        title: "代码格式化",
        desc: "内置对 oxfmt 与 Prettier 代码格式化的支持",
        image: "./assets/code-formatting-composite.png",
        style: "center",
      },
      {
        id: "script-runner",
        title: "代码运行器",
        desc: "一键运行 TS、JS、Python、Go 和 Rust 代码文件。",
        image: "./assets/Runner.png",
        style: "center",
      },
      {
        id: "image-viewer",
        title: "强大图片查看器",
        desc: "内置全功能图片查看器，支持元数据、标尺、像素预览与对比模式等。",
        image: "./assets/image-viewer.png",
        style: "center",
      },
      {
        id: "image-build",
        title: "Image Build",
        desc: "图片压缩、调整尺寸与格式转换\n设计工具级别的导出控制。",
        image: "./assets/image-build.png",
        style: "center",
      },
    ],
  },
];
