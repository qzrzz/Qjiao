# 🫑 Qjiao

围绕项目文件夹的终端工具。

基于 Kero 的二次开发以适配自己使用习惯和喜欢。

> [https://kero.sh](https://kero.sh) A native terminal workspace for macOS.


## FAQ

- Q: 为什么比 Kero 体积大
  A: 内置了中文等宽字体在内的许多字体（ SourceHanSansCN-VF-Mono1200.ttf, InterVariable.ttf），还内置了 cwebp, oxipng, cjxl 等图片处理工具


## 增加功能

相对上游 [Kero](https://github.com/egoist/kero) 的二次开发增量。按能力域归纳；细节以源码为准，此处只写**用户意图**。

### 项目与工作区

- 以项目文件夹为中心：侧栏管理多项目，支持描述、自定义图标（预置 / Emoji / SF Symbols / 本地文件）、归档与搜索。
- 新建项目走系统文件夹选择器（可新建目录）；支持 Finder 拖入、侧栏拖入、空状态拖入、Finder 服务「Open in Qjiao」、以及 `qjiao [path]` CLI。
- 项目配置落在 `~/.config/qjiao/projects/{id}/`（Debug 为 `qjiao-dev`），会话快照在 `session.json`，与 Dev/正式版互不覆盖；关闭项目清理对应目录。
- 左侧：窗口置顶、侧栏开关（⌘B）、一键打开文件夹、批量 AI 整理 / 归档 / 清理空项目。
- 「使用自动标题」为独立开关，可与自定义项目名并存。
- 命令面板可搜索并打开当前项目文件（遵守 Git ignore / 常见构建产物忽略）。

### 终端与分屏

- 递归分屏树：任意方向嵌套；标签可拖入内容区边缘分屏；任务「重新运行」优先在原 pane 替换会话，不打散分屏布局。
- 标签布局可选弹性压缩（默认）或横向滚动；Ctrl+1–9 切标签；Ctrl-Tab 预览（可选 MRU）。
- 终端默认点击移动光标、OSC 133 语义提示符；闲时标签标题可配置；可开关 Option-as-Alt、Vim 帮助条、字体加粗。
- 粘贴安全确认（OSC 52 / 可疑内容）；Finder 文件粘贴为 shell 路径；`TERM_PROGRAM=ghostty`，不强制注入 `LANG`。
- 兼容用户安装的 ghost-complete 等 PTY 补全代理；前台进程驱动 Tab 应用图标（含深浅色变体）。
- 多 Tab 惰性启动 Shell，后台 Tab 降低 GPU 占用。

### Git

- **操作逻辑可配置（简单 vs 传统）**：设置中新增 Git 分类与操作逻辑切换，默认使用简单模式（GitHub Desktop 风格，统一 CHANGES 单列表 + 复选框提交，点击提交按钮批量打包暂存并 commit；传统模式保持 VS Code 已暂存/变更分立列表）。
- 事件驱动刷新（仓库元数据 + 工作区监听）加低频心跳兜底，替代固定短间隔轮询；切换仓库时保留旧内容直至新结果就绪，减少闪烁。
- **操作中切换项目立刻跟新**：root 变化时脱离旧 commit/stage 的 `isBusy`，高优先级扫描新仓库，Git 面板不再等旧操作跑完才切换。
- **Commit Staged 加速**：操作前 HEAD/branch 校验改为轻量 `rev-parse`（不再全量 `git status`）；mutation 后先快路径更新变更列表（跳过 log/stash 等详情，空闲再补全）；全量扫描详情命令并行。
- **对齐 VS Code 的乐观更新与刷新策略**：
  - Stage / Unstage / Stage All / Unstage All / Commit：git 子进程跑之前先改 UI 列表（失败回滚快照），列表几乎瞬时响应；后台再轻量 `status` 纠偏。
  - 文件事件：操作中 / 失焦 / 大仓库（status 上限）跳过自动扫；1s 防抖合并；mutation 后 5s 冷却避免 index 自触发扫。
  - Stage 类操作跳过 HEAD 稳定校验（与 VS Code 一样只跑 `git add`/`restore`）。
- 大仓库友好：变更上限、未跟踪目录折叠展示、列表惰性渲染；可指定项目级 Git 仓库路径。
- stage / commit / discard、历史提交编辑（Reword / Amend / Drop 等）、大 Diff 虚拟化渲染；右侧 Git 标签显示变更数角标。
- 扫描失败可强制刷新并自愈 fsmonitor；子进程统一超时与回收，避免句柄泄漏导致状态卡死。
- Files 树可选 Git 状态装饰（默认关）。

### 文件、编辑与图片

- Files / CWD：Material 图标、多选、拖拽移动、复制粘贴（与 Finder 互通）、排序、按需算目录体积、右键「在终端打开」等。
- 全局文本搜索（内置 ripgrep，可降级 Swift 扫描）：大小写 / 全字 / 正则、包含排除、替换。
- 源码编辑器：语法高亮、查找、底部状态栏与 oxfmt/prettier 格式化；编辑器可独立 Light/Dark 主题；复制/粘贴强制纯文本，语法高亮只叠加渲染色不污染文本存储，避免异常样式影响输入与复制。
- 二进制 Hex 编辑器：Hex/ASCII 编辑、通配查找替换、跳转偏移、外部变更冲突处理。
- 单文件 Script Runner（Run / Run with…）与底栏运行/停止分屏。
- 图片查看器：缩放平移、标尺参考线、双图对比、背景模式；SVG 上下分屏代码+预览。
- **Image Build**：缩放与转 PNG / JPG / WebP / JXL（内置 oxipng、cwebp、cjxl 等）；支持 Suffix（添加后缀）与 File Name（重命名）两种导出命名模式，预置 10 种尺寸全套 macOS Icon 图标模板。
- 内置浏览器 Tab/分屏（WKWebView）：地址栏、前进后退、快照恢复标题与 favicon。

### 右侧栏

- 上半：Project / Files / CWD / Git / Info；下半：System / Note（可收起，分割比例可调）。
- **Project**：路径、Launchers（终端 / 应用 / Finder / 网页 / Agent CLI）、npm scripts 与 Gradle / Just / Cargo / CMake / Makefile 任务、PACKAGE（版本与常用包管理命令）、进程与端口；包管理器可自动识别。
- **Info**：当前会话 CWD 下的同类信息；跟随 Agent worktree。
- **System**：CPU / 内存 / 磁盘 / 网络 / 代理 / 可达性等（原生 API 为主，降低 CLI 轮询开销）；Note 按项目自动保存。
- 空脚本/任务分组自动隐藏；侧栏字号统一可调；窄宽度自适应布局。

### AI 与 Agent

- 统一 LocalAI：本地 CLI（grok / codex / claude / agy / opencode / pi）或云端 API（OpenAI / DeepSeek / Anthropic / Gemini / OpenRouter / xAI / 兼容端点）；Key 存 Keychain。
- 能力：AI 选图标、AI 生成名称/描述/图标、AI Commit Message（语言与 Gitmoji 可配；上下文优先 staged）。
- AgentWatcher：识别常见 Coding Agent 的 working / blocked / done，Tab 绿点、未读蓝点与项目角标；可配完成/阻塞音效。
- Project / Info 可一键用已安装的 AI 桌面应用或 CLI 打开当前目录。

### 外观与国际化

- 跟随系统语言，支持 English / 简体中文 / 日本語；界面文案走 L10n。
- Ghostty 全局与项目级 Light/Dark 配色；自定义主题（背景 / 文本 / 强调 + 终端 palette）。
- 窗口与终端背景透明度、侧栏与文件树字体、短路径 `~`（默认开）、等宽中文字体回退。
- 音效：任务成功/失败、Agent 完成/阻塞（系统 / WinXP / Win7 方案可选）。

### 工程与发布

- 独立产品标识与 Sparkle 自动更新；本机 Developer ID 签名、公证、DMG/ZIP、delta 与 GitHub Releases 发布脚本。
- 产品官网 `web/`（Vite + React）：中/英/日、功能介绍与响应式布局。

## 上游移植记录

- 移植上游 Kero `main` commit [`e08729b`](https://github.com/egoist/kero/commit/e08729bb19dd54d9355f269851209e96f7c0905f)（Files 面板 Git 状态装饰，v0.1.35 之后 unrelease）：适配 Qjiao 的 `GitStatusModel`（`Character` 状态位）、`FileTreeRow` 定制与 `L10n` 三语词表，并按要求默认关闭、在 `Settings → Files` 新增 `files.git-decorations` 开关。
- 移植上游 Kero `main` commit [`2163068`](https://github.com/egoist/kero/commit/216306845d24484600f3ac8e57c8191eb4f01bde)（Ctrl+1–9 切换标签）：主 Tab 快捷键由 `Ctrl+Shift+1–9` 改为 `Ctrl+1–9`；上游官网快捷键文案因 Qjiao 官网组件化重构无对应文案表，未跟随。
- 移植上游 Kero commit [`285fb66`](https://github.com/egoist/kero/commit/285fb6655b4d1284af62bb0b647b94c83849aeff)（Refine terminal workspace behavior，v0.1.35）：递归 split 树布局重构，覆盖 `Panes.swift`、`PaneLayoutView.swift`、`SessionStore.swift`、`TabSwitcher.swift`、`TerminalManager.swift` 与 `Project.swift`；保留本地定制（`materialFileName`、`isTaskRunning` / `taskHasError`、`showPaneHeaders` 开关、`onClosePane`、`TerminalHelpBar`、`Theme.cursor` 焦点色），会话快照兼容旧 column 与单内容格式并自动迁移。
- 本轮比对基线更新为 Kero `main` `2163068`（2026-07-31，含 `v0.1.35` 及两个 unrelease 提交）。未移植：`6b37b26`（Alacritty 渲染器修复，本地不包含该后端）；`2b9cd95` / `6dda01f` / `07f5589`（侧边栏行稳定与 Grok CLI 标题识别，本地 `SidebarView` 已重构且按要求不移植）。
- 最近完成比对与选择性移植的上游基线：Kero `main`（`058694c1e280237545f1cf4d6b14145b81e5b3cb`，包含 `v0.1.33`，2026-07-29）。
- 移植上游 commit [`fe9f622b6b55c087d5d6f449b0159d3f1e227766`](https://github.com/egoist/kero/commit/fe9f622b6b55c087d5d6f449b0159d3f1e227766)：“Add Open in Kero to Finder's folder context menu”，添加 Finder 右键文件夹服务菜单功能，在 Qjiao 中重命名为 “Open in Qjiao” 并适配项目生命周期与窗口接管。
- 移植上游 commit [`7bb18e6390ed4f883d15e6711460f88c36ea7d95`](https://github.com/egoist/kero/commit/7bb18e6390ed4f883d15e6711460f88c36ea7d95)、[`8c01a817d5fa085c9579f9569d9783ba38629bda`](https://github.com/egoist/kero/commit/8c01a817d5fa085c9579f9569d9783ba38629bda)、[`c79789b767e30901035471f8ef334b07a1666abf`](https://github.com/egoist/kero/commit/c79789b767e30901035471f8ef334b07a1666abf) 与 [`4d882462e840f4d1f5a0db1791d4165b1ebccbb5`](https://github.com/egoist/kero/commit/4d882462e840f4d1f5a0db1791d4165b1ebccbb5)：保持选中 Tab 可见、修复命令面板指针与 Escape 交互、在命令面板搜索项目文件，以及停止向终端注入 `LANG`；文件索引和文案已适配 Qjiao 的项目目录、忽略策略与 `L10n`。
- 移植上游 Kero `v0.1.32` commit [`46977b25d777c7fe98d32af016efd0274f6828c1`](https://github.com/egoist/kero/commit/46977b25d777c7fe98d32af016efd0274f6828c1)、[`c210d551c9d99dc085c5876c677845848f030d8f`](https://github.com/egoist/kero/commit/c210d551c9d99dc085c5876c677845848f030d8f) 与 [`d9d759c17a37a6d307cf9727d034bbd70053a5d8`](https://github.com/egoist/kero/commit/d9d759c17a37a6d307cf9727d034bbd70053a5d8) 的原生浏览器功能；最新比对基线仍为 Kero `main` `058694c1e280237545f1cf4d6b14145b81e5b3cb`（包含 `v0.1.33`，2026-07-29）。已适配 Qjiao 的 Pane、动态标题、URL 快照、主题、L10n、Ctrl-Tab 预览与 Ghostty 右键菜单，并明确排除所有 Alacritty 后端、bridge 与 Rust 代码。
- 本轮移植 Option/Meta 设置、隐藏渲染目标内存优化、外部图片变更刷新、侧栏字号和事件驱动 Git 刷新；不移植可选 Alacritty 后端。
- 已采用上游 `v0.1.24` 的兼容策略，将新建终端的 `TERM_PROGRAM` 设置为 `ghostty`。







