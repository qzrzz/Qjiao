# 🫑 Qjiao

围绕项目文件夹的终端工具。

基于 Kero 的二次开发以适配自己使用习惯和喜欢。

> [https://kero.sh](https://kero.sh) A native terminal workspace for macOS.

## 增加功能

> 相对于 Kero 原版的改动

- 左边栏开关（`sidebar.left`，⌘B）：展开时显示在左侧边栏顶栏右侧；收起后移到 Tabs 顶栏左侧（开关左右边距加大：左 16pt / 右 12pt）。
- 左侧边栏顶栏在侧栏开关左侧增加窗口置顶按钮（`pin` / `pin.fill`）：切换当前窗口 `NSWindow.level` 为 floating / normal，激活时 tint。
- 增加窗口拖拽区域。
  - 顶部、右侧边栏添加可拖拽区域。
- 右面板文本颜色提升可读性。
- 等宽中文字体来显示终端和代码，可以对齐含有中文的表格、注释了。
  - 默认使用内置 `Source Han Sans CN VF Mono1200` 作为中文等宽回退字体，并可在设置中关闭。
- 拖拽文件夹自动以该文件夹创建项目并在其中启动终端。
- 项目支持自定义图标（Emoji 和 SF Symbols ）；图标选择器独立为 `ProjectIconPicker.swift`，含常用推荐、搜索防抖、多词过滤与当前图标预览。
- 增加 Tabs 选择菜单；顶栏新建标签紧挨标签条，标签总览下拉固定在右侧侧栏按钮旁；左侧栏开关 / 新建 / 下拉 / 右侧栏 / Zoom 共用 `HeaderIconButton`（26pt 热区、caption 图标不变；仅 hover 浅底，按下/激活无底色，激活仅 tint）。右侧工具用 ZStack 固定叠层 + 左侧 padding 硬预留宽度，标签再多也不会挤占下拉/侧栏。
- 终端可选启用直接点击移动光标。
- 项目支持添加描述，并显示在项目列表中。
- 项目右键菜单支持在 Finder 中打开项目目录和配置文件夹。
- 项目名称、图标和描述改为保存在配置文件夹的独立项目配置文件中。
- 项目关闭按钮支持普通点击确认和 ⌘ 点击直接关闭。
- 右侧面板区分项目目录 Files 和终端当前目录 CWD，相同时自动隐藏 CWD。
- 分栏终端的右键菜单支持直接关闭当前面板。
- 终端未设置标题时默认显示启动工作目录的最后一级名称。
- 右侧栏 **Project** / **Info** 语义与采集：
  - **Project**：项目根路径 + 根 `package.json` scripts；进程/端口为项目下**全部 session** shell 子孙的并集（一次 `ps` + 一次 `lsof`）。
  - **Info**：当前终端 CWD + 该 cwd 下 `package.json` scripts；进程/端口仅当前 session；shell 名 / pid。
  - npm script 在对应路径新开终端运行（Settings 包管理器）；右键 time / `--inspect` / `--prof`；采集逻辑集中于 `SidebarProbe`。
  - 展开分组有左边距；数量徽章紧跟标题；空分组自动收起。
- 终端前台命令运行时，标签图标显示转圈动画。
- 右侧 Start 面板可保存、排序并一键启动项目的终端命令、应用程序、Finder 文件夹和网页。
  - 终端启动项可指定新标签标题，并与手动 Tab 重命名共用。
- 终端启动项可指定新标签或上、下、左、右分屏，并支持一键按顺序启动全部项目命令。
- 终端通过 OSC 52 读取系统剪贴板时需要确认，并对可能执行命令的粘贴内容显示安全警告。
- 升级 PierreDiffsSwift，修复 Git Diff 中中文等非 ASCII 字符的显示问题。
- 记住左右侧栏的显示状态和右侧面板选项，重启后自动恢复。
- Tab 支持手动重命名；Start 新标签标题与手动名称使用同一机制，可恢复自动标题。
- 修复 Vim、htop 等全屏终端程序的背景延伸和底部提示行间距。
- 增加终端字体笔画加粗开关，默认关闭。
- 外观设置支持分别调整窗口背景与终端背景不透明度。
- 支持 Ghostty 配色主题，亮色和暗色主题可分别设置并应用到整个窗口。
- 项目右键菜单支持项目级主题：遵循全局设置，或在 Light/Dark 精选、Cool、Warm 分隔项中选择具体 Ghostty 主题，并可从各自菜单内的“全部 Light 主题”“全部 Dark 主题”进入完整目录；主题菜单和全局主题选择器使用背景色、文本色及界面/文件夹强调色预览图标。
- 左侧面板底部增加主题菜单，可快速切换 System、Light、Dark 外观。
- Default Dark 主题的左侧项目面板改用更深的 `underWindowBackground` 材质，避免系统侧栏材质提亮背景。
- 修复开启终端不透明度时切换 Tab 后未选中的 Git Diff 对比器透出显示的问题，并将终端背景不透明度设置应用于 Git Diff 对比器。
- 终端 Tab 宽度展示：未挤满时最小 150、最大 220；标签条已满（需要横向滚动）时最小 130、最大 140，空间足够再恢复；标题变长立即扩张，变短延迟收缩并带过渡动画，减少抖动。
- 增加全局“禁用 Zsh 自动标题名”开关；仅为 Qjiao 新建的 zsh 终端设置 `DISABLE_AUTO_TITLE=true`，并可在 Tab 右键菜单中切换。
- 设置面板改为顶部图标分类导航，按 General、Terminal、Editor、Files、About 分组展示配置项；更新设置归入 General，并在 About 中展示项目和上游 Kero 信息。
- 设置 Editor 分组支持分别选择 Light / Dark 编辑器配色；两种外观都可独立跟随全局与当前项目主题或设置专用主题，不改变终端和窗口主题；编辑器专用主题内置 VS Code 风格的 Dark+、Light+、GitHub Dark、GitHub Light、One Dark、One Light、Monokai Pro、Xcode、Ayu、Solarized，并直接使用其语法 token 配色即时重绘。
- 源码文本编辑器增加可开关的英文底部状态栏：显示保存状态、当前文件大小、选区行数/字符数、文件格式，以及项目本地 `oxfmt`（优先）或 `prettier` 的格式化入口；格式化会先保存并以 `--write` 改写当前文件后重新载入。
- 设置 Files 分组：Display File Size 默认开启，可在右侧 Files / CWD 文件树中显示文件大小（目录不在刷新时自动计算）；关闭时写入 `files.display-file-size = false`。
- Files / CWD 目录树：hover 文件夹时右侧显示 Size 按钮，点击后在后台按需统计该文件夹逻辑体积（不阻塞 UI、不跟随符号链接、可取消与缓存；完成后显示大小，再点可重算）；多选时 Size 作用于全部选中目录（按钮显示数量，队列限流并发 2），右键菜单亦支持 Calculate Size。
- 设置 Files 分组可配置文件树字体族与字号（默认内置 Inter Variable / 13pt，资源 `kero/Fonts/InterVariable.ttf`），写入 `files.font-family` / `files.font-size`，行高与图标随字号缩放。
- Files / CWD 目录树支持选中态：单击选择、双击打开文件（目录为展开/折叠）；⌘ 点击切换多选、⇧ 点击按可见范围多选；⌘A 全选；右键菜单与废纸篓支持批量操作；箭头单独切换展开。
- Files / CWD 支持复制/粘贴文件与文件夹（右键 Copy / Paste，快捷键 ⌘C / ⌘V；剪贴板为 fileURL，可与 Finder 互通）；粘贴目标为选中文件夹内或文件父目录；同名冲突整批只询问一次，可选 New Name（`… copy`）或 Overwrite，应用于本批全部冲突项；Cancel 取消整批粘贴。
- 统一 chrome 字号体系（`SidebarTypography`）：左侧项目栏、右侧边栏 Start / Files / CWD / Git / Info 与顶栏 Tabs 共用 title / body / secondary / caption 等角色；列表与标签主文字统一为 13，正文字号不低于 11 以提高可读性。
- Start 面板「Add Launcher」按钮加大（顶栏 + 与空状态主按钮）。
- 右侧面板上下分区框架：上半保留 Start/Files/Git 等；中间可拖分割（默认 70/30，双击恢复）；下半区顶部为 System / Note tabs（最小宽 75、宽度随内容），可收起到仅显示 tabs（双击底栏切换收起/展开）。
- System 面板通过命令行采集主机信息（CPU%、内存、磁盘可用/总量、磁盘传输量、网络上下行、本机局域网 IP、系统代理、Google/Baidu/Cloudflare/GitHub 可达性）；不显示温度；并行 CLI 轮询、超时杀进程、手动刷新；预留 CLI runner 以便日后 SSH 远程。
- System 内存指标与活动监视器对齐：用 `vm_stat` 计算 Used = App + Wired + Compressed（不含文件缓存）；tooltip 展示 App / Wired / Compressed / Cached / Free；`top` PhysMem 仅作回退。
- Note 面板：按项目的纯文本草稿编辑器（自动换行、⌘F 查找）；内容防抖保存到 `~/.config/qjiao/notes/{projectId}.txt`（Debug 为 `qjiao-dev`），切换项目 / 收起面板 / 隐藏侧栏时立即落盘。
- System 面板可视化：CPU/内存/磁盘紧凑单行 + 一行高历史折线；磁盘写入每 30s 用 `iostat -Id` 采样，记录最近 1 分钟量（折线）、会话累计量（行内 W）与累计时长；Net / IP / Proxy 紧凑行（IP 为默认路由网卡 IPv4 可复制；Proxy 复制 `export https_proxy=…`）；Reachability 可配置站点/间隔/GET·HEAD，柱状延迟历史，右键编辑与立即检测，探测走系统代理。
- System Reachability 探测间隔默认 30s，下拉菜单显示勾选态与 `30s (Default)` 标注；间隔写入 `~/.config/qjiao/config.toml`（`system.reachability-interval`），重启后保留。
- System Reachability 保留每个站点最近一次探测错误；hover 提示展示 Last error，右键菜单提供 Copy error（无错误时 disabled）。
- System Reachability 支持按站点配置 GET/HEAD：添加/编辑表单分段选择、右键菜单勾选切换并立即重测；curl 探测隔离用户 curl 配置、仅允许 HTTP(S)、按系统 HTTP/HTTPS/SOCKS 代理及绕过规则访问，PAC/WPAD 会明确提示暂不支持；配置随站点持久化。
- System 面板数字与 IP/代理地址统一 `monospacedDigit`；自定义 Tooltip 单行等宽数字、多行等宽字体以对齐 Mem/Disk 等指标详情。
- 右侧 Files / CWD / Git 文件列表按文件名与扩展名显示 Material Icon Theme 彩色图标（[vscode-material-icon-theme](https://github.com/material-extensions/vscode-material-icon-theme)）；目录名匹配专用文件夹图标，展开/收起使用 open 变体；可用 `bun run scripts/vendor-material-icons.ts` 更新图标资源。
- 顶栏 Tabs（含 Tab 总览、重命名与分栏拖拽缩略图）对打开的文件 / Diff 使用与文件树相同的 Material Icon；终端 Tab 仍为 SF Symbol，运行中仍显示转圈。
- 终端应用图标识别：检测前台进程（如 `agy` / `grok` / `codex` / `claude` / `rsbuild` / `node` 等）并切换 Tab 图标；图标来源为 Material Icon Theme 与本地文件（`icon` 字段指定 `icons/` 下的 `.png` / `.svg` 等文件名，如 `antigravity-color.png`）。配置见 `kero/TerminalAppIcons/apps.json`，用户可在 `~/.config/qjiao/terminal-app-icons.json` 覆盖；`bun run vendor:terminal-app-icons` 可同步 Iconify 资源。枚举前台进程组内全部 PID 并解析 argv（支持 `npm run dev` → `node …/rsbuild`）。
- 左侧面板底部 Theme 按钮支持左键点击立即切换主题（Light ↔ Dark，System 模式按系统实际外观反转），右键菜单提供主题选择、分割线及 Appearance Settings 快捷入口。
- 右侧面板下半区底部 Tabs（System/Note 选项卡栏）的最小高度调整为 36，并优化展开逻辑（若之前拖拽将高度缩至最小，点击展开/双击 tabs 时自动恢复至默认 70/30 高度）。
- 图片查看器增强：
  - 放缩 > 100% 自动无缝切换像素插值模式（`.none`），≤ 100% 自动高质量插值（`.high`）。
  - 支持以鼠标指针位置为中心的视口滚轮放缩与 Cmd/Shift 快捷平移；支持原图与对比图左右双图叠加对比与竖线分界。
  - 内置专业级像素标尺与参考线系统：支持顶部/左侧标尺自适应像素刻度与指针指示；从标尺向内拖拽或双击标尺快速创建水平/垂直参考线；参考线支持悬停/拖动实时 `X: 320 px / Y: 180 px` 坐标提示气泡；参考线支持锁定防止误触；拖拽参考线至标尺内部或超出画布释放自动清除，并支持一键清除所有参考线；标尺数字支持中心精准对齐与 -90° 纵向排布；参考线支持靠近图片边缘与中心智能磁吸（Edge Snapping）。
  - 修复标尺在缩放时与图像错位：图像视口改为固定坐标系（中心 + offset），与 `originX/Y`、`pixelScale` 及参考线换算一致；多阶刻度改用整数索引 10 等分，避免浮点累加漏画主刻度；滚轮缩放中心按图像视口（不含工具栏）计算。
  - 增强画布右键上下文菜单（Context Menu）：快捷支持复制图片到剪贴板、复制文件路径、缩放适应/100% 重置、旋转 90°、切换背景模式（含 Light/Dark 棋盘格）、标尺/参考线开关控制、开启双图对比、拷贝元数据信息以及在 Finder 中高亮定位文件。
  - 支持背景模式跨标签与应用重启 `@AppStorage` 持久化记忆，并全新推出 Dark Checkerboard（深色棋盘格）背景模式。
  - 适配 Retina 高清屏 (High DPI Display)：自动响应 `screenBackingScale`，实现 1:1 绝对物理像素点对点精准对齐渲染。
- 优化 System 面板 IP 显示：请求 Cloudflare trace (`https://cloudflare.com/cdn-cgi/trace`) 获取出口 IP 与位置代码，并将 loc 转换为 Emoji 国旗图标（如 🇯🇵）；出口 IP 显示在内网 IP 后面（带有 gap 间隔与独立复制按钮）；支持仅点击 `[图标] IP` 标题区域触发刷新（刷新时 IP 图标平滑旋转转圈）；IP 值与 Net 网络速率值均支持鼠标文本选择。
- 优化右侧边栏窄宽度布局与防错位溢出：
  - 顶栏与底栏 Tabs 引入三阶响应式展缩机制（宽屏全文字、中屏仅选中项显示文字非选中项显示图标、极窄屏自动全图标排列），移除阻断鼠标手势的 ScrollView，完全恢复顶部 `WindowDragArea` 的窗口拖拽与双击动作体验。
  - System 面板 IP 行引入 `ViewThatFits` 自适应机制，宽屏单行展示，窄屏自动切为双行分层，彻底解决内网/公网 IP 宽度溢出导致界面错位的问题。
  - System 面板指标折线图、站点延迟柱状图及 Detail 文字改用弹性 Width 与布局优先级，并在侧栏外层施加 `.clipped()` 剪裁保护，保障任何窄宽度下的精致排版与稳定性。
  - 路径区操作按钮（Finder / VS Code / Copy）限制单行显示（`.lineLimit(1)`）与自适应字号缩放（`.minimumScaleFactor(0.7)`），防止在极窄边栏下按钮文字折行撑高。
- 移除右侧边栏顶栏 Start tab，并将项目启动项（Project launchers）整合为 Project 面板中的 `LAUNCHERS` 分组：
  - Header 右侧右对齐集成一键运行全部启动项（`play.fill`）与快捷新增（`+`）操作按钮。
  - 启动项行重构为紧凑整洁的面板对齐样式，精简高度并保留拖拽重排抓手、类型图标、按需展开编辑与独立运行控制。
- 优化右侧边栏面板滚动条显示逻辑：精确为 `Note`、`Files`、`CWD` 与 `Git` 面板开启滚动条指示，方便长列表浏览；为 `Project` 与 `System` 面板保持隐藏滚动条，保持界面简洁精致。
- 优化 `NPM SCRIPTS` 列表交互与 Shell 状态追踪机制：
  - 条目整行 Hover Tooltip 统一展示 `package.json` 中配置的具体命令内容（`script.command`）；整行单击设为选中高亮，仅待运行（`idle`）状态下双击触发运行脚本；正在运行状态下禁用双击，防止误操作重复触发。
  - 引入「待运行 (`idle`)」、「正在运行 (`running`)」与「正在停止 (`stopping`)」状态流转机制，自动绑定与监听后台 Shell / Session 的前台进程（`isForegroundCommandRunning`）及生命周期。
  - 当脚本子进程在 Shell 中执行完毕（命令结束恢复至 prompt 提示符）时，状态立刻自动恢复为「待运行」，并精确计算与刷新上一次运行耗时。
  - 处于「正在运行」时，图标转换为红色停止按钮（`stop.fill`，单击停止），且右侧动态呈现「重新运行」按键（`arrow.clockwise`）；
  - 处于「待运行」状态时，自动在条目右侧格式化展示上一次运行耗时（如 `4.2s`、`522.4ms`、`1m12.5s`，精准保留 1 位小数，整数时无多余 `.0`，配合 `monospacedDigit` 等宽数字字体显示）。
  - 自动读取 Settings 中配置的包管理器（`bun` / `pnpm` / `yarn` / `npm`），为启动的新终端 Tab 动态命名为 `<scriptName> (<pmCommand> run)` 格式（例如 `dev (npm run)`、`build (bun run)`）。
  - 抽象解耦出通用项目脚本执行引擎模块 `ProjectScriptEngine`：定义 `ProjectScriptCategory`、`UniversalProjectScript` 与 `ProjectScriptProvider` 探针协议，统一管理跨平台/多语言任务的构建、调度、生命周期监测与端口绑定，为后续扩展 Gradle、`tool.uv.scripts`、PDM、Rust alias 及 Makefile 等方案奠定架构基础。
- 优化右侧边栏 Project 与 Info 面板 Header 与顶部布局：以 Project 面板为统一模板对齐 Info 面板 Header 样式；Info 面板顶部图标动态响应当前终端 Tab 的前台应用图标（如 Node/Python/Cargo/Antigravity）与运行状态；移除冗余的 CWD/PROJECT 分组，在 Header 标题下方集成单行无边框只读路径输入框（支持放置光标平移浏览）与 Finder / Copy 操作按钮，并在内容区顶部统一设立 VS Code 打开项目的专属区域。
- 代码编辑器打开按钮支持多编辑器选择：Project / Info 面板顶部「在编辑器中打开」区域与路径栏编辑器按钮均通过 `CodeEditorRegistry` 动态检测系统已安装的代码编辑器（VS Code、VS Code Insiders、Cursor、Windsurf、Zed、Sublime Text、JetBrains 系列、Nova、Xcode 等）；默认以首选编辑器打开，安装多个时右侧 `[⌄]` 下拉菜单可切换默认编辑器（设置持久化到 `config.toml`：`editor.preferred-code-editor`）；无已安装编辑器时整体隐藏。
- 新增 AI 工具打开按钮与动态选择注册表：通过 `AIToolRegistry` 动态检测系统已安装的 AI 桌面 GUI 应用（Codex、Claude Code、Claude Desktop、OpenCode、Antigravity 等）与 CLI 命令行工具（`codex`、`agy`、`claude`、`opencode`、`grok` 等）；在 Project 与 Info 面板顶部形成「编辑器 + AI 工具」双核并列组合栏。桌面应用通过 `NSWorkspace` 激活打开目录，CLI 工具自动在新终端 Session 中携带目标路径启动；图标自动匹配 Material / App 真实图标，右侧 `[⌄]` 原生菜单支持一键切换并持久化至 `config.toml` (`ai.preferred-tool`)。
