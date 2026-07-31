import agentImg from "./Feature/Agent/assets/agent.png";
import projectImg from "./Feature/Project/assets/project-composite.png";
import filesImg from "./Feature/Files/assets/files.png";
import scriptsImg from "./Feature/ScriptsTasks/assets/scripts.png";
import gitImg from "./Feature/Git/assets/git.png";
import launchersImg from "./Feature/Launchers/assets/launchers-composite.png";

import packageManagerImg from "./Feature/PackageManager/assets/package-manager.png";
import devServerImg from "./Feature/DevServer/assets/dev-server-composite.png";
import codeFormattingImg from "./Feature/CodeFormatting/assets/code-formatting-composite.png";
import runnerImg from "./Feature/Runner/Runner.png";
import imageViewerImg from "./Feature/ImageViewer/assets/image-viewer.png";
import imageBuildImg from "./Feature/ImageBuild/assets/image-build.png";
import VideoFreeCur from "./shots/free-cur.mp4";

import type { SupportedLang } from "./i18n/dict";

/** 卡片布局类型：left（默认）、right、bottom */
export type CardStyle = "left" | "right" | "bottom";

/** 极简功能卡片配置接口 */
export interface FeatureCardConfig {
  /** 卡片唯一 ID */
  id: string;
  /** 功能标题 */
  title: string;
  /** 功能描述（支持用 \n 表示换行） */
  desc: string;
  /** 功能截图图片 */
  image?: string;
  /** 功能演示视频（支持视频像图片一样自动循环播放展示） */
  video?: string;
  /** 布局样式：left (默认) | right | bottom */
  style?: CardStyle;
  /** 图片 / 视频 alt 替代文本 */
  alt?: string;
  /** 可选覆盖：自定义卡片容器 className */
  cardClassName?: string;
  /** 可选覆盖：自定义截图图片/视频 className */
  shotClassName?: string;
  /** 可选覆盖：设计稿节点 ID */
  dataNodeId?: string;
}

/** 分区配置接口 */
export interface SectionConfig {
  /** 分区 ID */
  id: string;
  /** 分区标题 */
  title: string;
  /** 分区描述说明 */
  description: string;
  /** 分区包含的功能卡片列表 */
  cards: FeatureCardConfig[];
  /** 可选：分区自定义 class */
  className?: string;
}

/** 多语言全量内容配置映射 */
export const sectionsContentMap: Record<SupportedLang, SectionConfig[]> = {
  en: [
    {
      id: "future",
      title: "Beginner-Friendly ",
      description: "Terminal without the steep learning curve.",
      cards: [
        {
          id: "free-cur",
          title: "Freely move the cursor",
          desc: "Edit as naturally as in a text editor.",
          video: VideoFreeCur,
          style: "left",
          alt: "move the cursor",
        },
      ],
    },

    {
      id: "projects",
      title: "Work Around Projects",
      description:
        "Get your work done without leaving the terminal workspace — CLI, Agents, Files, and Git.",
      cards: [
        {
          id: "agent",
          title: "Parallel AI agents",
          desc: "Tabs, Panes, multiple agents working together",
          image: agentImg,
          style: "left",
          alt: "Multiple AI agents working in Qjiao panes",
        },
        {
          id: "project",
          title: "Project",
          desc: "Icons, names, and descriptions with themes to clearly distinguish projects",
          image: projectImg,
          style: "left",
          alt: "Qjiao project overview and project icon picker",
        },
        {
          id: "files",
          title: "Files",
          desc: "Full-featured file management without leaving the terminal — icons, sizes, keyboard navigation, image previews, Spacebar Quick Look, and more.",
          image: filesImg,
          style: "left",
          alt: "Qjiao file manager",
        },
        {
          id: "scripts-tasks",
          title: "Scripts & Tasks",
          desc: "NPM Scripts, Gradle Tasks, Cargo, CMake, and more visualize your commands and run them with one click",
          image: scriptsImg,
          style: "right",
          alt: "Visual task and script runner",
        },
        {
          id: "git",
          title: "Git",
          desc: "Visualize common Git operations and generate commit messages with one click — powered by your Agent CLI, NO API key required.",
          image: gitImg,
          style: "left",
          alt: "Qjiao Git changes and commit interface",
        },
        {
          id: "launchers",
          title: "Launchers",
          desc: "Start working in seconds.\nlaunch apps, docs, and terminals instantly.",
          image: launchersImg,
          style: "left",
          alt: "Qjiao launcher interface",
        },
      ],
    },
    {
      id: "web-dev",
      title: "Web Dev Friendly",
      description: "Building web? You’ll love this.",
      cards: [
        {
          id: "package-manager",
          title: "Package manager support",
          desc: "Quickly edit package versions, detect NPM Scripts, discover dev server ports, and more.",
          image: packageManagerImg,
          style: "left",
          alt: "Package version and dependency management in Qjiao",
        },
        {
          id: "dev-server",
          title: "Detect Dev Server",
          desc: "Always know where your services are running\nports and links at a glance",
          image: devServerImg,
          style: "bottom",
          alt: "Detected development server ports",
        },
        {
          id: "code-formatting",
          title: "Code Formatting",
          desc: "Built-in editor support for oxfmt and Prettier",
          image: codeFormattingImg,
          style: "bottom",
          alt: "Formatting with oxfmt and Prettier",
        },
        {
          id: "script-runner",
          title: "Script Runner",
          desc: "Run TS, JS, Python, Go, and Rust files with one click.",
          image: runnerImg,
          style: "left",
          alt: "run tsx script",
        },
        {
          id: "image-viewer",
          title: "Powerful Image Viewer",
          desc: "built-in full-featured image viewer with metadata, rulers, pixel inspection, comparison mode, and more.",
          image: imageViewerImg,
          style: "left",
          alt: "Qjiao image viewer with rulers and metadata",
        },
        {
          id: "image-build",
          title: "Image Build",
          desc: "Image compression, resizing, and format conversion\nwith design-tool-grade export controls.",
          image: imageBuildImg,
          style: "left",
          alt: "Qjiao image export and compression controls",
        },
      ],
    },
  ],
  "zh-Hans": [
    {
      id: "future",
      title: "新手友好",
      description: "零陡峭学习曲线的终端工作区。",
      cards: [
        {
          id: "free-cur",
          title: "光标自由移动",
          desc: "像在文本编辑器中一样自然地移动与编辑。",
          video: VideoFreeCur,
          style: "left",
          alt: "光标自由移动",
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
          image: agentImg,
          style: "left",
          alt: "Qjiao 分屏中运行的多个 AI Agent",
        },
        {
          id: "project",
          title: "项目识别",
          desc: "自定义图标、项目名称与描述，配合色彩主题清晰区分多项目",
          image: projectImg,
          style: "left",
          alt: "Qjiao 项目概览与图标选择器",
        },
        {
          id: "files",
          title: "文件管理",
          desc: "在终端旁直接管理文件，本应如此 \n类型图标、文件大小、键盘导航、图片预览及空格键快速预览。",
          image: filesImg,
          style: "left",
          alt: "Qjiao 文件管理器",
        },
        {
          id: "scripts-tasks",
          title: "脚本与任务",
          desc: "可视化运行 NPM Scripts、Gradle Tasks、Cargo、CMake \n一键快速执行",
          image: scriptsImg,
          style: "right",
          alt: "可视化任务与脚本运行器",
        },
        {
          id: "git",
          title: "Git",
          desc: "可视化常用 Git 操作，一键生成 Commit 提交信息\n由本地 Agent CLI 驱动，无需配置 API Key。",
          image: gitImg,
          style: "left",
          alt: "Qjiao Git 变更与提交界面",
        },
        {
          id: "launchers",
          title: "快捷启动器",
          desc: "快速开启项目所需各种工具\n一键启动应用、文档、终端、打开文件夹。",
          image: launchersImg,
          style: "left",
          alt: "Qjiao 启动器界面",
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
          image: packageManagerImg,
          style: "left",
          alt: "Qjiao 中的包版本与依赖管理",
        },
        {
          id: "dev-server",
          title: "开发服务器端口识别",
          desc: "随时掌握服务运行状态\n端口与预览链接一目了然",
          image: devServerImg,
          style: "bottom",
          alt: "自动识别的开发服务器端口",
        },
        {
          id: "code-formatting",
          title: "代码格式化",
          desc: "内置对 oxfmt 与 Prettier 代码格式化的支持",
          image: codeFormattingImg,
          style: "bottom",
          alt: "使用 oxfmt 与 Prettier 格式化代码",
        },
        {
          id: "script-runner",
          title: "代码运行器",
          desc: "一键运行 TS、JS、Python、Go 和 Rust 代码文件。",
          image: runnerImg,
          style: "left",
          alt: "一键运行 TSX 脚本",
        },
        {
          id: "image-viewer",
          title: "强大图片查看器",
          desc: "内置全功能图片查看器，支持元数据、标尺、像素预览与对比模式等。",
          image: imageViewerImg,
          style: "left",
          alt: "带有标尺与元数据的 Qjiao 图片查看器",
        },
        {
          id: "image-build",
          title: "Image Build",
          desc: "图片压缩、调整尺寸与格式转换\n设计工具级别的导出控制。",
          image: imageBuildImg,
          style: "left",
          alt: "Qjiao 图片导出与压缩控制",
        },
      ],
    },
  ],
  ja: [
    {
      id: "future",
      title: "初心者にも易しい",
      description: "急な学習曲線のないターミナルワークスペース。",
      cards: [
        {
          id: "free-cur",
          title: "カーソルの自由な移動",
          desc: "テキストエディタのように自然に編集できます。",
          video: VideoFreeCur,
          style: "left",
          alt: "カーソルの移動",
        },
      ],
    },
    {
      id: "projects",
      title: "プロジェクト中心の効率的なワークフロー",
      description:
        "ターミナルワークスペースから離れることなく作業を完了 — CLI、AI Agent、ファイル管理、Git連携。",
      cards: [
        {
          id: "agent",
          title: "AIエージェントの並列処理",
          desc: "タブやペインを活用し、複数のAIエージェントが連携して作業",
          image: agentImg,
          style: "left",
          alt: "Qjiaoペインで並列稼働するAIエージェント",
        },
        {
          id: "project",
          title: "直感的なプロジェクト識別",
          desc: "アイコン、名称、説明文、テーマカラーでプロジェクトを明確に区別",
          image: projectImg,
          style: "left",
          alt: "Qjiaoのプロジェクト概要とアイコン選択",
        },
        {
          id: "files",
          title: "高機能ファイル管理",
          desc: "ターミナル内で完結するファイル操作 — アイコン、サイズ表示、キーボード操作、画像プレビュー、スペースキーのQuick Lookに対応。",
          image: filesImg,
          style: "left",
          alt: "Qjiaoのファイルマネージャー",
        },
        {
          id: "scripts-tasks",
          title: "スクリプト＆タスク",
          desc: "NPM Scripts、Gradle Tasks、Cargo、CMakeなどのコマンドを可視化し、ワンクリックで実行",
          image: scriptsImg,
          style: "right",
          alt: "ビジュアルタスク＆スクリプトランナー",
        },
        {
          id: "git",
          title: "Git操作の可視化",
          desc: "一般的なGit操作をビジュアル化し、ワンクリックでコミットメッセージを生成 — Agent CLI搭載でAPIキー不要。",
          image: gitImg,
          style: "left",
          alt: "QjiaoのGit変更点とコミット画面",
        },
        {
          id: "launchers",
          title: "クイックランチャー",
          desc: "数秒で作業を開始\nアプリ、ドキュメント、ターミナルを即座に起動。",
          image: launchersImg,
          style: "left",
          alt: "Qjiaoのランチャー画面",
        },
      ],
    },
    {
      id: "web-dev",
      title: "Web開発者に嬉しい機能",
      description: "Webアプリの開発ですか？気に入っていただける機能が満載です。",
      cards: [
        {
          id: "package-manager",
          title: "パッケージマネージャーサポート",
          desc: "依存関係のバージョン編集、NPM Scriptsの検出、開発サーバーポートの確認などがスムーズ。",
          image: packageManagerImg,
          style: "left",
          alt: "Qjiaoでのパッケージバージョンと依存関係管理",
        },
        {
          id: "dev-server",
          title: "開発サーバーの自動検出",
          desc: "サービスがどこで稼働しているかを常時把握\nポートとリンクを一覧表示",
          image: devServerImg,
          style: "bottom",
          alt: "検出された開発サーバーのポート",
        },
        {
          id: "code-formatting",
          title: "コードフォーマット",
          desc: "oxfmtおよびPrettierによるコード整形を標準サポート",
          image: codeFormattingImg,
          style: "bottom",
          alt: "oxfmtとPrettierによるコード整形",
        },
        {
          id: "script-runner",
          title: "スクリプトランナー",
          desc: "TS、JS、Python、Go、Rustファイルをワンクリックで実行。",
          image: runnerImg,
          style: "left",
          alt: "TSXスクリプトのワンクリック実行",
        },
        {
          id: "image-viewer",
          title: "多機能画像ビューア",
          desc: "メタデータ表示、ルーラー、ピクセル検査、比較モードを備えたフル機能の画像ビューアを内蔵。",
          image: imageViewerImg,
          style: "left",
          alt: "ルーラーとメタデータを備えた画像ビューア",
        },
        {
          id: "image-build",
          title: "画像ビルド＆エクスポート",
          desc: "デザインツール級のエクスポートコントロールで\n画像の圧縮、リサイズ、フォーマット変換を実行。",
          image: imageBuildImg,
          style: "left",
          alt: "Qjiaoの画像エクスポート＆圧縮コントロール",
        },
      ],
    },
  ],
};

/** 根据语言获取对应 Section 数组 */
export function getSectionsContent(lang: SupportedLang): SectionConfig[] {
  return sectionsContentMap[lang] || sectionsContentMap.en;
}
