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
- 标签布局可选弹性压缩（默认）或横向滚动；Ctrl+1–9 切标签；Ctrl-Tab 预览（可选 MRU）；溢出滚动时选中 Tab 自动避让边缘渐隐，不被遮挡；右键可「关闭全部文件 / 关闭全部 Diff」。
- 终端默认点击移动光标、OSC 133 语义提示符；闲时标签标题可配置；可开关 Option-as-Alt、Vim 帮助条、字体加粗。
- 粘贴安全确认（OSC 52 / 可疑内容）；Finder 文件粘贴为 shell 路径；`TERM_PROGRAM=ghostty`，不强制注入 `LANG`。
- 终端桌面通知带声音；点击通知自动激活窗口并跳转到发出通知的会话。
- 兼容用户安装的 ghost-complete 等 PTY 补全代理；前台进程驱动 Tab 应用图标（含深浅色变体）。
- 终端本地文件链接：⌘-点击链接时本地文件在 Finder 中显示、URL 走浏览器；⌘-右键文件链接可在 Qjiao 中新建文件标签/分屏打开（路径按 pane 工作目录解析，支持 `~`、`file:` 与 `:行:列` 后缀）。
- 多 Tab 惰性启动 Shell，后台 Tab 降低 GPU 占用；访问过的项目其 Diff 视图保持挂载，切换项目不重建 WebKit（提速），恢复会话时保留文件/Diff 标签的上下文终端指向。

### Git

- **操作逻辑可配置（简单 vs 传统）**：设置中新增 Git 分类与操作逻辑切换，默认使用简单模式（GitHub Desktop 风格，统一 CHANGES 单列表 + 复选框提交，点击提交按钮批量打包暂存并 commit；传统模式保持 VS Code 已暂存/变更分立列表）。
- 事件驱动刷新（仓库元数据 + 工作区监听）加低频心跳兜底，替代固定短间隔轮询；切换仓库时保留旧内容直至新结果就绪，减少闪烁；两仓库来回切换时立即恢复上次解析的内容（单槽快照），不再显示上一个仓库的旧状态。
- Git 操作进度反馈：更多操作菜单（Fetch/Pull/Push/Stash 等）、分支切换、提交选项菜单、初始化仓库按钮均有进行中指示；发起新操作自动折叠上一条操作输出。
- **操作中切换项目立刻跟新**：root 变化时脱离旧 commit/stage 的 `isBusy`，高优先级扫描新仓库，Git 面板不再等旧操作跑完才切换。
- **Commit Staged 加速**：操作前 HEAD/branch 校验改为轻量 `rev-parse`（不再全量 `git status`）；mutation 后先快路径更新变更列表（跳过 log/stash 等详情，空闲再补全）；全量扫描详情命令并行。
- **对齐 VS Code 的乐观更新与刷新策略**：
  - Stage / Unstage / Stage All / Unstage All / Commit：git 子进程跑之前先改 UI 列表（失败回滚快照），列表几乎瞬时响应；后台再轻量 `status` 纠偏。
  - 文件事件：操作中 / 失焦 / 大仓库（status 上限）跳过自动扫；1s 防抖合并；mutation 后 5s 冷却避免 index 自触发扫。
  - Stage 类操作跳过 HEAD 稳定校验（与 VS Code 一样只跑 `git add`/`restore`）。
- 大仓库友好：变更上限、未跟踪目录折叠展示、列表惰性渲染；可指定项目级 Git 仓库路径。
- 提交历史：可展开查看每次提交改动的文件列表（点击打开父→提交的历史 diff），支持分页加载更多；提交图（垂直线 + 圆点）、引用徽章（HEAD/main/tag）、滚动接近底部自动加载更多。
- stage / commit / discard、历史提交编辑（Reword / Amend / Drop 等）、大 Diff 虚拟化渲染；右侧 Git 标签显示变更数角标。
- 多语言（L10n）完整覆盖 Git 操作完成提示（Commit/Push/Pull/Fetch/Stage/Discard/Stash 等状态与输出消息），支持中文与日文实时切换。
- 扫描失败可强制刷新并自愈 fsmonitor；子进程统一超时与回收，彻底治理 Process / Pipe 文件描述符 (FD) 泄漏（显式关闭 stdin/stdout/stderr 读写句柄，Diff 视图统一下放 SubprocessRunner），解决长时间运行后因 FD 耗尽引发 `Bad file descriptor` (`NSPOSIXErrorDomain` code 9) 导致子进程创建失败的问题。
- 修复 Ghostty 屏幕导出的目录 fd 泄漏：终端预览 / Agent 读屏改为 `ghostty_surface_read_text` 直接读 surface；Vendor 构建链增加 `0011-fix-tempdir-fd-leak.patch`，修复锁定的 Ghostty `35e1a016…` 在成功 `write_screen_file` 导出后未释放 TempDir 及其父目录句柄的问题；FD 巡检监控扩展到 release，rlimit 软上限最多提升至 65536。
- Files 树可选 Git 状态装饰（默认关）。

### 文件、编辑与图片

- Files / CWD：Material 图标、多选、拖拽移动、复制粘贴（与 Finder 互通）、排序、按需算目录体积、右键「在终端打开」等。
- 全局文本搜索（内置 ripgrep，可降级 Swift 扫描）：大小写 / 全字 / 正则、包含排除、替换。
- 源码编辑器：语法高亮、查找、底部状态栏与 oxfmt/prettier 格式化；编辑器可独立 Light/Dark 主题；复制/粘贴强制纯文本，语法高亮只叠加渲染色不污染文本存储，避免异常样式影响输入与复制。
- 二进制 Hex 编辑器：Hex/ASCII 编辑、通配查找替换、跳转偏移、外部变更冲突处理。
- 单文件 Script Runner（Run / Run with…）与底栏运行/停止分屏。
- 图片查看器：缩放平移、标尺参考线、双图对比、背景模式；SVG 上下分屏代码+预览。
- **Image Build**：缩放与转 PNG / JPG / WebP / JXL（内置 oxipng、cwebp、cjxl 等）；支持 Suffix（添加后缀）与 File Name（重命名）两种导出命名模式，预置 10 种尺寸全套 macOS Icon 图标模板。
- 内置浏览器 Tab/分屏（WKWebView）：地址栏、前进后退、快照恢复标题与 favicon；使用新版 Safari User-Agent，修复 B 站等站点识别为旧浏览器的问题。

### 右侧栏

- 上半：Project / Files / CWD / Git / Info；下半：System / Note（可收起，分割比例可调）。
- **Project**：路径、Launchers（终端 / 应用 / Finder / 网页 / Agent CLI）、npm scripts 与 Gradle / Just / Cargo / CMake / Makefile 任务、PACKAGE（版本与常用包管理命令）、进程与端口；包管理器可自动识别。
- **Info**：当前会话 CWD 下的同类信息；跟随 Agent worktree。
- **System**：CPU / 内存 / 磁盘 / 网络 / 代理 / 可达性等（原生 API 为主，降低 CLI 轮询开销）；Note 按项目自动保存。
- 空脚本/任务分组自动隐藏；侧栏字号统一可调；窄宽度自适应布局。

### AI 与 Agent

- 统一 LocalAI：本地 CLI（grok / codex / claude / agy / opencode / pi）或云端 API（OpenAI / DeepSeek / Anthropic / Gemini / OpenRouter / xAI / 兼容端点）；Key 存 Keychain。
- **AI API 配置独立记录机制**：每个供应商各自的 Model、Base URL 与 API Key 独立保存与复用，切换供应商时自动恢复上一次的自定义参数，无需重复输入。
- 能力：AI 选图标、AI 生成名称/描述/图标、AI Commit Message（语言与 Gitmoji 可配；上下文优先 staged；未跟踪文件仅提供文件路径，不读取正文）。
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

- 移植上游 Kero `main` `b83f338`（Support terminal links to local files，v0.1.43，2026-08-04）：新增 `TerminalLinkTarget`（url/file）分类与 `TerminalSession.terminalLinkTarget(for:)`/`existingFileURL` 路径解析（file: URL、~ 展开、相对路径按 pane 工作目录、剥离 `:行:列` 后缀）；`terminalDidRequestOpenURL` 本地文件改走 Finder 显示；⌘-右键菜单新增「New File Tab / New File Pane」（SplitMenuTarget 经 representedObject 传递路径），回调链 KeroTerminalView → TerminalHostView → PaneLayoutView → ContentView（manager.openFile / openFileToSide）；L10n 三语词条。适配：本地 KeroTerminalView 无上游 `events` 代理，改为 `resolveLinkTarget` 回调由 TerminalSession 注入；保留本地 `kind: TerminalOpenURLKind` 参数与历史导出 URL 定制；上游 FileViewer/SourceTextEditor 移除 onNewBrowserTab 属重构清理，未跟随。`e74f2b0`（OSC 22 鼠标指针，Alacritty）未移植。
- 补全上游 `212ea0a` Recent Commits 视图的剩余 UI 差距（SwiftUI 实现，保留本地 GitCommitRow 定制）：提交图（`CommitGraphColumn` 垂直线 + 圆点，展开放大，首行/续线规则与上游一致；`FileRailColumn` 文件行延续线）、引用徽章（`primaryReference` 同上游规则：优先带斜杠分支、其次 HEAD 指向，accent 胶囊白字）、滚动自动加载（`LazyVStack` 中 Load More 按钮 `.task(id: commits.count)` 进入视口即加载，连续加载至填满或没有更多）。未跟随：AppKit 绘制（保持 SwiftUI）。
- 移植上游 Kero `main` `db9a061` + `0a253ba`（v0.1.40–v0.1.41，2026-08-04）：`DiffViewPreferences` 从静态 enum 重构为 `@MainActor ObservableObject` 单例（`@Published diffStyle`/`prefersEditing` 落盘 UserDefaults，多标签/多窗口同步编辑与布局偏好；`DiffWebModel.isEditing` 改为 `canEdit`，编辑意图统一读偏好）；diff 外观跟随系统主题——`DiffWebHostingView`（NSHostingView 子类）在 `viewDidChangeEffectiveAppearance` 时经 `DiffWebModel.usesDarkAppearance` 驱动 WebKit 的 `colorScheme` 环境值，`DiffControlsNSView` 颜色改为 `effectiveAppearance.performAsCurrentDrawingAppearance` 内更新。
- 上游 `93b2b34`（Support dragging tabs into split panes，v0.1.42）**无需移植**：对比确认本地 `TabSplitDragController` + `Project.mergeTab` 已实现等价能力（拖标签到任意 pane 四象限分屏、保留源标签完整分屏树 `absorb`、diff 标签不可并入、不能拖到自身终端），且本地另有光标反馈与落点预览。唯一缺口：上游在 `moveTab` 中把源标签的 `contextSession` 迁移给目标标签（目标为空时），本地 `mergeTab` 未处理——已按上游语义补齐。
- 移植上游 Kero `main` `212ea0a`（Improve the Recent Commits view in git panel，2026-08-04）：提交历史支持展开显示文件变更列表（`--name-status -z` + `--decorate=short` 单命令解析，RecentCommit 增加 `parentHash`/`references`/`files`）、分页加载（每页 8 条、`loadMoreCommits`、按 root 记忆分页位置）、打开历史提交 diff（`openCommitDiff`：父→提交比较，DiffTab 增加 `commitHash`/`commitParentHash`/`commitStatus`，会话快照新增 `commitDiff` 兼容解码）。本地保留 SwiftUI `GitCommitRow`（含 Reword/Amend/Drop/AI Commit 定制）并叠加展开与分页，未跟随上游 AppKit `RecentCommitsView` 重写；未移植上游 `runGit` timeout 参数（本地已统一 SubprocessRunner 超时）。
- 移植上游 Kero `main` `17bb787` + `dd14529`（Enable direct editing for live worktree diffs，2026-08-04）：PierreDiffsSwift 1.4.1 → 1.5.0；DiffWebModel 增加 fileID/编辑状态/编辑回调，DiffTab 增加 `isEditable`/`isDirty`/`saveError` 编辑状态机（`save`/`updateEditedContent`/`completeEditing`/`setDiffStyle`/`setEditing`，符号链接与 staged diff 不可编辑），`DiffViewPreferences` 记忆布局与编辑偏好；controlBar 替换为 AppKit `DiffControlsBar`（Review/Edit + Unified/Split，L10n 适配，新增 Split Layout 专用词条避免与分屏语义冲突）；关闭未保存确认泛化为 PaneContent（支持 diff），Tab 标签显示 dirty 标记。未移植：上游 `runGit` 的 timeout 参数与 10s 全局 deadline（本地已统一走 SubprocessRunner 超时/回收）。
- 移植上游 Kero `main` `3f0cdd8`（add toolbar）的 GitStatusModel 增量（2026-08-04）：`defaultBranch` 采用优化实现——`for-each-ref --format="%(refname:short) %(symref)" refs/remotes` 单命令并行解析所有 remote 的 symbolic HEAD（origin 优先），非 clone 仓库按 main > master 惯例降级，均校验必须存在于本地分支列表；替代上游串行 `symbolic-ref` 实现。`cachedStatusByRoot` 未直接移植，改为单槽 root 快照优化本地 `isSwitchingRoot`：`apply` 时保存最近一次成功解析结果，`sync(root:)` 切回同一 root 时立即 `apply` 恢复正确内容（不锁交互、后台刷新纠偏），多 root 循环退化为原路径。未移植：`lineAdditions`/`lineDeletions`/numstat 行数统计与未跟踪行数计数（用户不需要）、底部工具栏 UI 与 `toolbarVisibility` 设置（与本地右侧栏 Git 面板重叠）、`defaultBranch` 目前无 UI 消费方。
- 移植上游 Kero `main` `dae03e9`（Improve Git operation progress and error feedback，2026-08-04）的增量部分：本地已有同构的 `GitActionTarget` + `beginGitAction` 机制（覆盖 stage/unstage/discard/commit/sync），本轮补充更多菜单、分支菜单、提交选项菜单与初始化仓库的 spinner 触发源，`beginGitAction` 发起新操作时折叠旧操作输出，主操作按钮 accessibility 进度标签（L10n 三语）；保留本地全状态操作横幅（running/succeeded/failed）与内联分支创建输入框，未跟随上游失败横幅与 NSAlert 改造。
- 本轮移植上游 Kero `main` `90cd6bf` 之前的 unrelease 提交（2026-08-04，`2163068` 之后）：
  - `90cd6bf` 选中 Tab 滚动避让边缘渐隐：适配本地弹性布局（保留无动画滚动策略与 chrome 抢先选中），新增 `StripGeometry.contentOffsetX` 与 fade-aware 滚动算法。
  - `1da3345` 访问过的项目 Diff 保持挂载（切换提速）：`webHostView` 改为可选并延迟 materialize、`retainedDiffProjectIDs` 保留集合、`TabSnapshot` 新增 `contextSessionIndex`（含旧快照兼容解码）与 `restoreTab` 返回 `PaneTab?`；上游新增的 AppKit 加载骨架 `DiffControlsSkeletonBar` 未移植（本地 controlBar 为 SwiftUI 轻量版，维持基线视觉）。
  - `9ea40a6` + `31d09ed` 通知点击跳转会话与通知声音：重写 `TerminalNotificationService`（settings 重构 + sound 升级授权 + userInfo 携带 sessionID），`TerminalManager` 新增静态 `revealSession(id:)`；保留本地 Qjiao 标题。
  - `567ab96` 浏览器 Safari User-Agent；`628dee2` 标签右键「关闭全部文件 / 关闭全部 Diff」（L10n 三语词条）。`8d4b0f2`（新终端优先钉住的项目目录）已回退：上游 `customDirectory` 默认 nil、仅显式钉住时非空，而 Qjiao 的 `projectDirectory` 在项目创建时自动填充（所有项目都有值），移植会改变所有项目的新终端默认目录，故恢复原有「跟随当前会话目录」行为。
  - 未移植：`01566f9`（QoS 修复针对上游 Thread 读取实现，本地已统一走 `SubprocessRunner`）、`ac4ca58` / `db0da69`（Alacritty 后端相关）。
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





