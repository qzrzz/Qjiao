# 🫑 Qjiao

围绕项目文件夹的终端工具。

基于 Kero 的二次开发以适配自己使用习惯和喜欢。

> [https://kero.sh](https://kero.sh) A native terminal workspace for macOS.

## 增加功能

> 相对于 Kero 原版的改动


- 增加窗口拖拽区域。
    - 顶部、右侧边栏添加可拖拽区域。
- 右面板文本颜色提升可读性。
- 等宽中文字体来显示终端和代码，可以对齐含有中文的表格、注释了。
  - 默认使用内置 `Source Han Sans CN VF Mono1200` 作为中文等宽回退字体，并可在设置中关闭。
- 拖拽文件夹自动以该文件夹创建项目并在其中启动终端。
- 项目支持自定义图标（Emoji 和 SF Symbols ）。
- 增加 Tabs 选择菜单。
- 终端可选启用直接点击移动光标。
- 项目支持添加描述，并显示在项目列表中。
- 项目右键菜单支持在 Finder 中打开项目目录和配置文件夹。
- 项目名称、图标和描述改为保存在配置文件夹的独立项目配置文件中。
- 项目关闭按钮支持普通点击确认和 ⌘ 点击直接关闭。
- 右侧面板区分项目目录 Files 和终端当前目录 CWD，相同时自动隐藏 CWD。
- 分栏终端的右键菜单支持直接关闭当前面板。
- 终端未设置标题时默认显示启动工作目录的最后一级名称。
- Info 面板读取项目根目录的 `package.json` 并显示 npm scripts，可选择包管理器后在新终端中运行。
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
- 终端 Tab 最小宽度调整为 136；标题变长时立即扩张，变短后延迟收缩并带有过渡动画，减少标签宽度抖动；自动与手动标签名的最大宽度均为 220。
- 增加全局“禁用 Zsh 自动标题名”开关；仅为 Qjiao 新建的 zsh 终端设置 `DISABLE_AUTO_TITLE=true`，并可在 Tab 右键菜单中切换。
- 设置面板改为顶部图标分类导航，按 General、Terminal、Editor、About 分组展示配置项；更新设置归入 General，并在 About 中展示项目和上游 Kero 信息。
- 统一 chrome 字号体系（`SidebarTypography`）：左侧项目栏、右侧边栏 Start / Files / CWD / Git / Info 与顶栏 Tabs 共用 title / body / secondary / caption 等角色；列表与标签主文字统一为 13，正文字号不低于 11 以提高可读性。
- Start 面板「Add Launcher」按钮加大（顶栏 + 与空状态主按钮）。
- 右侧面板上下分区框架：上半保留 Start/Files/Git 等；中间可拖分割（默认 70/30，双击恢复）；下半区顶部为 System / Note tabs（最小宽 75、宽度随内容），可收起到仅显示 tabs（双击底栏切换收起/展开）。
- System 面板通过命令行采集主机信息（CPU%、内存、磁盘可用/总量、磁盘传输量、网络上下行、系统代理、Google/Baidu/Cloudflare/GitHub 可达性）；不显示温度；并行 CLI 轮询、超时杀进程、手动刷新；预留 CLI runner 以便日后 SSH 远程。Note 仍为占位。
- System 面板可视化：CPU/内存/磁盘紧凑单行 + 一行高历史折线；磁盘写入每 30s 用 `iostat -Id` 采样，记录最近 1 分钟量（折线）、会话累计量（行内 W）与累计时长；Net/Proxy 紧凑行（Proxy 复制按钮复制终端 `export https_proxy=… http_proxy=… all_proxy=…`）；Reachability 可配置站点/间隔/GET·HEAD，柱状延迟历史，右键编辑与立即检测，探测走系统代理。
- System Reachability 探测间隔默认 30s，下拉菜单显示勾选态与 `30s (Default)` 标注；间隔写入 `~/.config/qjiao/config.toml`（`system.reachability-interval`），重启后保留。
- System Reachability 保留每个站点最近一次探测错误；hover 提示展示 Last error，右键菜单提供 Copy error（无错误时 disabled）。
- System Reachability 支持按站点配置 GET/HEAD：添加/编辑表单分段选择、右键菜单勾选切换并立即重测；curl 探测隔离用户 curl 配置、仅允许 HTTP(S)、按系统 HTTP/HTTPS/SOCKS 代理及绕过规则访问，PAC/WPAD 会明确提示暂不支持；配置随站点持久化。
