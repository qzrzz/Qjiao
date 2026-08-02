# 🫑 Qjiao

围绕项目文件夹的终端工具。

基于 Kero 的二次开发以适配自己使用习惯和喜欢。

> [https://kero.sh](https://kero.sh) A native terminal workspace for macOS.


## FAQ

- Q: 为什么比 Kero 体积大
  A: 内置了中文等宽字体在内的许多字体（ SourceHanSansCN-VF-Mono1200.ttf, InterVariable.ttf），还内置了 cwebp, oxipng, cjxl 等图片处理工具


## 增加功能

- **内容视图 Tabs 拖拽分屏**：主标签条拖拽在原有**排序**之外支持**拖入内容区分屏**——与终端内 Pane 拖拽分屏同一套四象限落点（上/下/左/右半屏高亮）。拖到其它 Tab 上仍即时改序；拖到当前内容区某个 pane 边缘松手后，将源 Tab 整棵布局树（含其已有分屏）并入目标 Tab 形成分屏，源 Tab 关闭且会话/文件/浏览器保持挂载。约束：**当前内容 Tab 不能拖到自己的终端里分屏**（禁止光标）；目标已分屏时按具体 pane 命中；diff 独占单 pane 的 Tab 不可作为源或落点。

- **音效支持（命令运行结束 / 失败、Agent 完成 / 待处理，可在设置中关闭）**：新增 `kero/SoundEffects.swift` 音效播放服务，内置支持 macOS 系统音效以及 WindowsXP / Windows7 自定义音效（存储于项目 `kero/Sounds/` 目录）：
  - **命令运行结束 / 失败**：与终端 Tab 角标判定完全对齐——仅由 UI 侧显式发起的 Task 任务（启动器 Launcher / 项目脚本 / 右侧栏命令）在执行结束、Tab 角标停止转圈显示成功 `✓` 勾号或失败 `!` 叹号的那一刻按结果播报音效；用户普通的交互式终端命令行不触发音效也不弹 Tab 角标，保持打字干扰为零。
  - **Agent 完成 / 待处理**：`AgentWatcher` 检测到 Agent 由 `working` 转为 `done` 时默认播放 macOS/Tink；转为 `blocked`（待用户交互/权限确认）时默认播放 macOS/Blow（无论终端是否可见）。
  - **设置开关与 2 级选择菜单**：`Settings → General` 新增「Sound Effects」分区——总开关 + 四个事件独立开关（Command succeeded / Command failed / Agent completed / Agent blocked）与 **2 级音效选择菜单 (`Menu`)**（第一级分类：macOS / WindowsXP / Windows7；第二级为对应音效列表），各事件可在 2 级菜单中自由挑选并实时点击喇叭按钮预览；配置写入 `config.toml` 的 `ui.sound-effects` 及各音效标识。同一事件 0.4s 防抖，避免大量命令同时结束时音效叠爆。

- **修复 macOS ViewBridge 崩溃（Hex 工具条输入框改用 SwiftUI TextField）**：修复 Hex 编辑器查找 / 替换输入框聚焦后再显示应用内 borderless NSPanel（工具栏提示气泡 / 文件预览悬浮）时偶发崩溃 `NSInternalInconsistencyException: -[NSRemoteView containingWindowWillOrderOnScreen:] ... expected (null)`。根因是 macOS（26+）对 AppKit 文本控件（原实现为 `NSTextField` roundedBezel + 自定义 cell）注入表单自动填充（ViewBridge 远程视图 `com.apple.SafariPlatformSupport.Helper SPCompletionListServiceViewController`），该视图残留后 NSPanel 显示时 ViewBridge 状态机断言失败（网易有道翻译等第三方 App 同款崩溃，为系统级 bug）。修复：Hex 工具条查找 / 替换输入框由 AppKit 控件改为 **SwiftUI 普通 `TextField`**（矩形圆角描边、聚焦高亮、左侧图标、等宽字体、回车提交、⌘F 聚焦全选均保留），系统不再对 SwiftUI 输入框注入自动填充远程视图，从源头消灭崩溃。
- **Git 面板 Retry 从头刷新（fsmonitor daemon 自愈）**：Git 面板「Git Status Unavailable」错误页的 Retry 按钮从「仅重新扫描」升级为「从头刷新」——先修复失效的 Git fsmonitor daemon（`git fsmonitor--daemon stop` → 删除残留的 `.git/fsmonitor--daemon.ipc` IPC socket → 重新 `start`，仅对启用了内建 fsmonitor 的仓库执行），再全量重扫仓库状态。用于「Bad file descriptor」这类 daemon 崩溃 / git 版本切换后 socket 残留导致的错误，无需重启应用即可手动恢复。
- **自定义 Git 仓库路径解析、持久化与 Pipe 读写鲁棒性修复**：修复指定自定义 Git 仓库路径（`customGitPath`）后 Git 面板频发错误以及重启应用后配置失效的问题：① **存盘/恢复持久化**：修复 `TerminalManager.makeWindowSnapshot` 在保存会话快照时漏填 `customGitPath` 导致每次退出或自动保存存盘时把磁盘 `config.json` 擦除为 `nil` 的致命 Bug，同时补齐了从快照与磁盘同步加载时的属性恢复；② **路径校验解绑**：解除了 `isValidCustomGitPath` 原先要求路径必须位于 `projectDirectory` 子文件夹内的过严限制，改为校验非空且磁盘目录存在，避免因目录结构差异导致重启后 `gitRoot()` 误判丢弃自定义路径；③ **Symlink 路径规范化**：在 `Project.swift` 与 `GitScanner.swift` 中为仓库路径处理添加 `resolvingSymlinksInPath()` 规范化，解决 macOS 上由于路径符号链接（如 `/var` 与 `/private/var`）导致 `GitScanner.resolveRepositoryRoot` 与预期路径比对不一致引起的校验失败；④ **POSIX Pipe 安全读取**：在 `GitScanner`、`GitCommitEditor` 及 `DiffViewerView` 中将过期的 Foundation `readDataToEndOfFile()`（进程结束或管道关闭时在 macOS 上抛出 `NSFileHandleOperationException: Bad file descriptor`）替换为 `try? readToEnd()`，避免管道读取异常中断程序执行。

- **Files 十六进制编辑器（Hex Editor）**：Files 面板支持对二进制文件进行 Hex 编辑。打开方式：① 双击 / 打开二进制文件（非 UTF-8 或超过 5 MiB 的文本）时自动以十六进制编辑器打开（上限 64 MiB）；② 文件树右键菜单新增「Open in Hex Editor」可对任意文件（含文本、图片）强制以十六进制模式打开，与文本模式互不干扰（同路径另开标签页）。编辑器为 Offset / Hex / ASCII 三列布局（等宽字体，第 8 字节分组间隙，列标题栏）：点击/拖选/⇧ 点击选择字节，双击选中单字节，Tab 切换 Hex / ASCII 编辑区域，直接键入 0-9、A-F（Hex 区）或可打印字符（ASCII 区）覆盖当前字节，Backspace / Delete 清零，方向键 / Home / End / PageUp / PageDown 移动光标（⇧ 扩展选区），悬停高亮。剪贴板：⌘C 按当前编辑区复制（Hex 区为 `DE AD BE EF`，ASCII 区为文本），⌘X 剪切（清零），⌘V 粘贴自动识别十六进制串（支持 `0x` 前缀、逗号/空格分隔）与 UTF-8 文本，右键菜单另提供 Copy as Hex / ASCII / C String；⌘Z / ⇧⌘Z 撤销重做（撤销栈随标签页生命周期、工具条替换与键入共用，连续键入合并为一步撤销，与文本编辑器同策略避免悬垂撤销记录）。外部文件变动检测复用文本编辑器的事件监听逻辑（DispatchSource 监听文件与所在目录 + 应用激活检查）：本地无修改时静默重载并刷新视图、丢弃撤销历史，有未保存修改时显示冲突提示条（Reload / Keep Local）；⌘S 原子写回磁盘。光标偏移 / 选区字节数与滚动位置随会话快照持久化，重启后恢复。底部状态栏展示保存状态、文件大小与 `0x00000000` 偏移摘要（等宽数字）。
  - **Hex 工具条（查找 / 替换）与跳转对话框**：编辑器顶部工具条默认单行显示查找，点击行尾展开按钮（chevron，带展开动画）显示第二行替换功能；组件遵循 macOS 规范——输入框为矩形圆角 SwiftUI `TextField`（聚焦高亮描边、内置左侧图标），TEXT / HEX 模式用分段控件切换，背景为系统材质并带 hairline 分隔线，图标 / 文字按钮带 hover 反馈与 Tooltip：
    - **查找**：输入即搜（后台计算，64 MiB 文件毫秒级），支持 **TEXT**（UTF-8 字节，可开关「Aa」区分大小写）与 **HEX**（`DE AD BE EF` / `0x12, 0x34` 等格式，支持 `??` 整字节与 `4?` / `?F` nibble 通配符）两种模式，编辑器内全部匹配高亮、当前匹配以光标色突出；↑↓ 按钮与 n/N 计数切换匹配（无匹配红色 0/0）；⌘F 聚焦查找框，⌘G / ⇧⌘G（或查找框 / 编辑器内 ↩ / ⇧↩）下一个 / 上一个匹配，⌘E 把选中字节作为十六进制查找内容；解析失败（如奇数位 hex）红标提示。
    - **替换**（第二行，展开后显示）：同样支持 TEXT / HEX 模式，替换当前匹配（替换框内 ↩）或全部替换（确认对话框，⌘Z 一步撤销全部）；替换支持任意长度变化（含空替换即删除），替换后自动重新搜索；替换全部从后往前执行保证匹配位置稳定；⌘⌥F 自动展开替换行并聚焦替换框。
    - **跳转**：底部状态栏右侧新增定位图标按钮，点击弹出原生对话框（NSAlert + 输入框 + DEC / HEX 分段选择），输入偏移确认后编辑器滚动到目标字节；输入记忆保留，聚焦自动全选便于覆盖。

- **兼容系统安装的 ghost-complete（PTY 补全代理）**：用户通过 Homebrew / cargo 等自行安装 [ghost-complete](https://github.com/StanMarek/ghost-complete) 并 `ghost-complete install` 后，Qjiao 内终端可与其共存。修复点：① zsh 启动代理在 source 用户 `~/.zshrc` 期间**保持** `ZDOTDIR` 为 Qjiao 集成目录，使 mid-rc 的 `exec ghost-complete` 拉起的内层 shell 仍走 Qjiao bootstrap（否则会丢失 OSC 133 click-to-move、`qjiao-prompt-ready`、pending 命令与闲时标题）；② 集成脚本将真实登录 shell 的 `$$` 回写 `shell.pid`（`QJIAO_SHELL_PID_FILE`），宿主侧亦将 proxy PID 解析为内层 zsh；③ libghostty 的 `tcgetpgrp` 在代理下恒为 proxy，前台作业/Agent 识别/进程图标/前台 CWD 改为扫描登录 shell 子孙进程，不再误判为「永远空闲」或「永远忙碌」。
- **Tabs 创建时异常尺寸/位置动画修复**：修复新建 Tab 时 Tab 自身出现尺寸变化与位置变化的异常动画。根因有二：① 新建 Tab 后 shell 初始化期间标题会多次变化（目录名→提示符→稳定标题），弹性模式下标题驱动 `recomputeElasticSlots` 重算，激活 Tab 宽度（=标题自然宽）随之 150→220→150 来回跳动，条带也反复滚动；现对**标题驱动的弹性重算加 400ms 防抖**，标题稳定后再重算一次，创建期间宽度保持稳定。② 溢出渐隐动画作用域过大——`.animation(value: overflow)` 挂在 ScrollView 上，溢出翻转时会把 Tab 插入/弹性重排/滚入视口一起包进 0.15s 插值；现已把动画收窄到两侧渐隐条（`LinearGradient`）本身。另外新建 Tab 的标题稳定窗口（0.8s）内不做宽度过渡动画，直接落到目标宽。

- **无会话 / 无项目中心界面与 Tab 栏拖拽优化**：
  - **Tab 栏拖动窗口**：在无 open tabs（如无打开会话）时，Tabs 顶栏不再渲染空 `ScrollView`，标签栏全域自动转为可拖拽热区（`HeaderWindowDragBand`），支持鼠标点按拖动移动窗口。
  - **大尺寸主按钮与「新建项目」次要按钮**：优化中心空白提示区（`EmptyStatePromptView`），放大图标与文字排版，将「新建会话 ⌘T」调整为高亮加大主按钮，并新增「新建项目 ⌘N」次要按钮（`manager.newProject()`）。
  - **拖入文件夹打开项目**：中心区域支持 Finder 文件夹拖入（`.onDrop`），拖入时高亮虚线框与卡片反馈，松开后自动解析目标路径并在应用中打开/创建对应项目。
- **内容视图 Tabs 非激活终端图标颜色优化**：将内容视图标签页（`TabStripIconView` 与 `TerminalAppIconView`）中默认终端图标在非激活模式下的颜色由过暗的 `.tertiary` / `Color.secondary` 优化为主题感知次要色 `Theme.secondaryColor`，使其与非激活状态下的标签页标题文字及周围 UI 元素在深浅外观下保持视觉对比度协调一致。

- **AgentWatcher（Agent 状态检测）**：新增 `kero/AgentWatcher`，参考 [herdr](https://github.com/herdrdev/herdr) 的 screen manifest 思路，从终端**前台进程名**识别 Coding Agent，再结合 **OSC 标题**与**屏幕尾部文本**规则判定 `working` / `blocked` / `done`。内置 herdr 同源 TOML 规则（claude、codex、agy、pi、opencode、grok 及 cursor、gemini、kimi 等）。**性能优先**：仅对识别到的 Agent 终端做读屏；进程轮询约 2s，读屏最短间隔约 3s；非 Agent 终端不扫屏。Info 面板展示 Agent 状态（`● agent · Working`）。**Tab Agent State 角标**：当 Agent 为 `working` 时，主标签与 Tab Switcher 图标右下角显示呼吸闪烁的小绿点（优先于 Task 状态角标）。**未读提醒**：`working → done` 时若终端不可见（非当前 Tab、非当前项目、或窗口/应用未激活），标记未读；对应 Tab 显示小蓝点；切换到该 Tab / 应用重新激活且终端已在当前视图时自动清除；左侧**项目列表**显示蓝色数字角标，表示该项目下未读条目数（等宽数字）。
- **启动器（Launcher）新增 Agent CLI 任务类型与空分组体验优化**：
  - **新增 Agent CLI 启动器类型**：启动器任务类型新增 **Agent CLI**（`ProjectLaunchCommandType.agentCLI`），支持从系统中已检测到或预置的本地 AI CLI 工具（如 `agy`、`claude`、`codex`、`opencode`、`ollama` 等）中选择，并可配置预置提示词（Prompt）。点击运行或一键全部运行时，自动在项目终端窗口/分栏中拉起该 AI CLI 并带入格式化好的预置提示词执行。
  - **启动器分组体验优化**：在 Project 面板中，若当前项目未配置任何启动器，Launcher 分组默认初始化为收起状态；同时修复了空状态下 Header 添加按钮被误禁用的问题，使得 `+`（添加启动器）按钮在空状态下始终可用，点击即自动展开分组并新建启动器。
- **Project 面板无 NPM Script 自动隐藏分组**：在 Project 面板与 Info 面板中，若未检测到 `package.json` 或 `package.json` 中无任何 scripts 脚本，自动隐藏 `NPM SCRIPTS` 分组，避免展示无意义的空行。
- **标签切换先反馈 UI 再切内容**：点击 / 快捷键 / Tab Switcher 切换主标签时，顶栏选中态（`chromeSelectedTabID`）立即更新；终端挂载、侧栏跟随等重活推迟到下一 runloop 再应用 `selectedTabID`，避免点击后顶栏长时间无响应。新建、关闭、恢复会话仍同步切换内容。
- **主内容 Tabs 布局模式（滚动 / 弹性）**：Settings → General → Appearance 新增 **Tabs Layout**（`ui.tabs-layout`，默认 `elastic`）。
  - **弹性（Elastic）**（默认）：左对齐；空间不足时**先从最左侧**连续压缩激活 Tab 左侧的非激活标签，仍不够再从最右侧压缩激活 Tab 右侧；宽度连续变短，低于阈值后变为**仅图标**（显示该 Tab 自身图标，保留 Task/dirty 状态指示，无关闭按钮）；激活 Tab 保持可读全宽（仍受 max 限制）。极端情况下（全压到仅图标仍溢出）保留横向 ScrollView。
  - **滚动（Scroll）**：标签挤满后统一压宽并横向滚动，选中项自动滚入视口。
- **CLI 图标智能对比度自适应（低可视度自动重绘剪影）**：Project 面板打开按钮、标签页与 Info 面板的 CLI 工具图标（`TerminalAppIconView`）现在会智能判断图标在当前浅色/深色外观下与背景的对比度——先按外观解析最佳变体（Material 图标浅色外观优先使用 `_light` 深色描边变体，与 Files 面板行为一致；本地图标继续使用 `iconDark` 变体），若解析后图标平均亮度仍与背景过于接近（如浅色外观下的白色/米色品牌图标、深色外观下的纯黑图标），则自动以 alpha 通道为轮廓重绘为剪影（模板图）并用主题强调色重新填充，保证任何图标在两种外观下都清晰可辨。对比度判定按图标实际渲染文件的感知亮度均值与覆盖率缓存计算（每图标一次），全出血品牌位图不做剪影处理避免变色块；剪影与原色图分开缓存，互不污染。
- **macOS 27 菜单图标兼容处理**：Project 面板中 AI 工具与代码编辑器的原生下拉菜单，在 macOS 27 及更高版本显式设置 `NSMenuItem.preferredImageVisibility = .visible`，避免 AppKit 新默认策略隐藏菜单项图标；旧系统继续保持原有行为。
- **项目指定 Git 路径与 Git 无参考体验优化**：
  - **项目指定 Git 路径**：在项目配置中支持指定自定义 Git 仓库路径（`customGitPath`，存储在项目配置 `config.json` 中），路径必须位于项目根目录的子文件夹或项目目录本身中。当未指定时继续走默认判定逻辑。
  - **Git 菜单项增补**：在 Git 面板顶部菜单（`ellipsis`）以及系统顶栏 `Git` 菜单中添加「指定 Git 仓库路径…」功能；若当前项目已指定 Git 路径，还会添加「清除指定 Git 仓库设置」选项，便于随时恢复默认逻辑。
  - **Git 无参考体验优化**：在未初始化或未检测到 Git 仓库的无参考界面中，将「初始化仓库」按钮扩大为标准突出样式，并新增「指定 Git 仓库文件夹…」按钮，点击弹出文件夹选择框（默认初始路径为项目目录），方便快速指定并跟踪子仓库或微服务仓库。
- **文本编辑 ⌘Z 撤销崩溃修复（悬垂撤销记录）**：修复 Note 笔记与 Git 提交信息编辑器在 ⌘Z 撤销时偶发崩溃（`-[_NSUndoStack popAndInvoke]` 中 `objc_msgSend` 命中已释放对象的悬垂指针，SIGSEGV / PAC failure）。两个 `NSTextView` 编辑器此前沿响应链复用窗口共享的 `NSUndoManager`，编辑器随项目切换 / 面板开关 / 提交完成频繁销毁重建后，共享撤销栈仍残留指向已销毁编辑器的记录，下一次 ⌘Z 即触发；现改为每个编辑器实例独享 `UndoManager`（与 STTextView 文件编辑器同策略），随视图一起销毁，杜绝悬垂记录。同时输入法组合（marked text）期间不再整段写回外部文本，避免打断组合与输入上下文撤销登记。
- **Project 打开按钮与预置 CLI 图标深色/浅色自适应**：
  - **打开按钮 CLI 图标自动关联**：Project 面板快捷打开按钮（Project Launchers）对于终端类命令（如 `pi`、`bun`、`npm`、`cargo`、`claude` 等），自动从命令行匹配对应的 CLI 工具图标（`TerminalAppIconView`），无需手动选择。
  - **深色/浅色外观动态响应**：`TerminalAppIconCatalog` 新增 `bundledFileToDarkPath` 映射与 `isDarkMode` 参数，预置图标与打开按钮 CLI 图标均能响应系统 / 应用的 `@Environment(\.colorScheme)`，在深色外观下自动加载 `iconDark` 变体（如 `pi-logo-dark.svg`），浅色外观下恢复浅色变体，即时无缝刷新。
- **终端应用图标支持深色/浅色双变体**：`apps.json` 条目新增可选 `iconDark` 字段（`icons/` 下的深色模式变体文件名，与 `icon` 配对）；应用处于深色外观时自动使用深色变体，浅色外观用回 `icon`（如 pi 图标 `pi-logo-light.svg` / `pi-logo-dark.svg`），外观切换即时刷新，图标缓存按实际路径区分。用户侧 `terminal-app-icons.json` 同样支持。
- **Project 面板脚本运行的命令注入与端口绑定修复**：修复点击运行 NPM / Gradle / Cargo 等脚本时偶发「命令填入终端但不执行、需手动回车」的问题。旧逻辑在启动 shim 写入 `shell.pid` 后固定等 0.1s 就向 PTY 注入命令，遇到 zsh 慢启动（插件 / compinit 等）时字节落在登录 shell 初始化窗口内，被回显但不执行；现在**改为让 shell 自身执行命令**：应用把命令写入该 session launch 目录的 `pending_command` 文件（`QJIAO_PENDING_COMMAND_FILE` 环境变量），zsh 集成在**首个提示符**的 `_qjiao_precmd` 中读取并 `eval` 执行（视觉上先回显命令文本，等价于用户输入后回车），同时发出 OSC 133 C/D 保持命令完成状态跟踪；首个提示符还会发一次性 OSC 2 哨兵 `qjiao-prompt-ready`（不显示为标签标题），应用据此确认 shell 就绪并作为脚本状态判定基准；8s 兜底：集成失效（哨兵迟迟不来）时移除 pending 文件并按旧启发式注入，避免命令永远不执行或重复执行。同时修复运行后端口/浏览器按钮不即时出现的问题：① 脚本运行后等新 session 的 shell pid 就绪即发通知（`.qjiaoSidebarShellDidAttach`）触发侧栏立即重扫，进程/端口采集马上包含新 shell，不再等 2s 轮询或切换标签；② `checkPackageScriptStatus` 的完成判定改为以**命令实际注入时刻**（`lastCommandInjectedAt`）而非任务创建时刻为基准，避免 shell 启动慢时记录被过早标记 idle 导致端口永不绑定；③ 修复 `ProjectPanelModel.refreshProcesses` 采集任务被取消时 `isRefreshingProcesses` 卡在 true、后续轮询被永久跳过的问题。
- **Files 面板目录内容缓存与后台扫描（大量文件不再卡顿）**：`FileTreeModel` 由「每次展开/折叠全量重扫磁盘」改为「目录内容缓存 + 指纹校验 + 后台扫描」：每个目录扫描结果（含 contentModificationDate 指纹）缓存于内存，展开/折叠只扫变化的目录，折叠再展开缓存命中不重扫；目录指纹在主线程一次轻量 stat 校验，外部新增/删除文件（终端 mkdir/touch/rm 等）触发对应目录自动重扫；失效目录的 readdir + stat 全部移出主线程（`Task.detached(priority: .utility)`），扫描期间显示行内 loading 占位行；扫描改为一次 `contentsOfDirectory` 预取属性（每文件 1 次 stat，替代旧的 fileExists + attributesOfItem 两次 stat），路径统一字符串拼接避免 `/var` → `/private/var` realpath 不一致导致展开失效；排序在主线程展平时进行（size 排序依赖目录体积缓存，排序切换无需失效缓存）；root 切换整体清缓存并按 generation 丢弃在飞扫描结果。
- **Git 面板未跟踪目录改为 VS Code `mixed` 折叠逻辑**：Git 状态扫描从 `--untracked-files=all`（未跟踪目录逐文件展开）改为 `--untracked-files=normal`（与 VS Code `git.untrackedFiles: mixed` 一致）——完全未跟踪目录折叠为单个目录条目（`? dir/`，文件夹图标，点击打开目录，Stage / Discard 作用于整目录），已跟踪目录内的未跟踪文件仍逐文件显示；嵌套未跟踪目录不再递归展开，数万未跟踪文件场景条目数从 2 万降到 1 条级，扫描 / 解析 / 渲染全链路量级下降。目录条目在 Files 面板的装饰按无斜杠 key 精确命中（修复尾斜杠导致目录聚合丢失的问题）；AI Commit Message 上下文（`-uall`）与命令面板（`ls-files --others`）保持文件级明细不受影响。
- **Git 扫描与变更列表性能优化（大量变更文件不再冻结）**：修复 Git 面板在数万条变更（尤其大量未跟踪 / 被忽略文件）时界面冻结的问题——变更行此前被包在非懒加载的 `VStack` 中，外层 `LazyVStack` 无法惰性化，所有行一次性创建并布局（含每个文件的 Material 图标解码）；现在行直接作为 `LazyVStack` 子视图按需渲染，并在单次 body 求值内缓存过滤结果。扫描侧：`git status` 的 `--ignored=matching` 改为仅在「Files 面板 Git 状态装饰」开启时使用（默认关闭时 `--ignored=no`），消除 `*.log` 等 pattern 类忽略规则下每 2 秒全量枚举数十万被忽略文件的输出与解析开销；刷新合并补扫增加 800ms 防抖，避免大仓库扫描耗时超过 2s 轮询间隔时 git 子进程无间隙连续轮询占满 CPU / IO。文件树目录的 Git 装饰改为状态载入时预计算目录聚合（渲染期 O(1) 查询），移除每个目录行对全量字典的扫描。新增 `kero/GitScanner.swift`：整条扫描流水线（7 个 git 子进程、porcelain v2 解析、结果切分与装饰构建）迁移到独立 `GitScanner` actor（`Task.detached(priority: .utility)` 调度），串行执行避免并发 git 进程争抢，全部 O(n) 计算不再占用主线程——主线程的 `apply` 只剩 COW 数组赋值与 SwiftUI diff；操作执行（stage / commit 等）保持独立的 `userInitiated` 后台任务即时响应，不排队等扫描。
- **System 面板原生 API 采集（消除 CLI 高 CPU）**：System 面板的 CPU / 内存 / 网络速率 / 磁盘容量 / Swap / 系统代理 / 本机 IP 由「每 2s spawn 10+ 子进程解析 CLI 输出」改为直接调用原生 Darwin / SystemConfiguration API（`host_statistics`、`host_statistics64`、`sysctlbyname`、`statfs`、`NET_RT_IFLIST2`、`NET_RT_DUMP`、`getifaddrs`、`SCDynamicStoreCopyProxies`），不创建子进程、开销低 2–3 个数量级。原先每 2s 一拍的 `top -l 2`（单次约 0.75s CPU、约占单核 37%）已移除，CPU 占用率改为 host_statistics 累计 tick 差分（与活动监视器同口径）；网络计数改用 `NET_RT_IFLIST2` 64 位计数，规避 `getifaddrs` 的 `if_data` 计数超过 2^32 后被截断的问题（与 `netstat -ib` 完全一致）；系统代理直接读 `SCDynamicStoreCopyProxies`；本机 IP 读路由表 `NET_RT_DUMP`（`SCDynamicStoreCopyPrimaryInterface` 已从新版 SDK 移除）。仅保留 `iostat -Id`（磁盘写入量，30s 一拍）与 `curl`（出口 IP、可达性探测）两个低频命令，SSH 命令表复用能力保留。新增 `kero/SystemNative.swift`。
- **AI headless provider 新增 pi（`pi -p`）支持**：`LocalAI` 统一模块新增 `pi` 提供器，通过 `pi -p` / `--print` 非交互模式调用 pi 编码助手；安装探测覆盖 npm 全局安装（`~/.npm-global/bin`、`~/.bun/bin` 等）与 curl 安装脚本（无系统 node 时自带独立 node 于 `~/.local/share/pi-node/current/bin`，已并入 PATH 增强）；默认带 `--no-session` 不落盘会话，`disableTools` 映射为 `--no-tools`，`model` 透传 `--model`，`autoApprove` 映射为 `--approve`（信任项目本地 AGENTS.md / CLAUDE.md 等资源）；AI 工具列表（Agent 交接用 `AIToolRegistry`）同步加入 `pi` CLI 项。
- **终端 zsh 集成 idle title 报错修复**：修复 `_qjiao_get_idle_title_pattern` 误将 `cat` 当作 zsh 内建命令调用（`builtin cat`），导致终端每次出现提示符时输出 `no such builtin: cat` 的问题；改为通过 `command cat` 读取 `~/.config/qjiao/idle_title`，可正常绕过用户自定义的别名与函数。

- **Files 面板 Git 状态装饰（可开关）**：当项目位于 Git 仓库内时，Files / CWD 文件树为变更文件显示彩色文件名与状态徽章（M / A / U / D / R / C / ! / I），目录按子项最高优先级聚合显示，Git 忽略文件变暗展示；可通过 `Settings → Files → File Tree` 中「Show Git Status Decorations」开关控制（默认关闭，配置写入 `files.git-decorations`）。

- **Ctrl+1–9 直接切换标签**：主标签页快捷键由 `Ctrl+Shift+1–9` 简化为 `Ctrl+1–9`，与 `Cmd+1–9` 切换项目区分，无需再按 Shift。

- **递归分屏布局重构（Refine Terminal Workspace）**：分屏布局由旧的「列 + 行」column 模型重构为递归 split 树（`PaneNode` / `PaneSplit` / `layout.geometry`）：任意方向的拆分只分割聚焦 Pane 自身矩形、保留相邻 Pane 尺寸，支持上下左右任意嵌套组合；分屏拖动分隔条、Pane 拖拽移动、键盘方向键聚焦（几何最近原则）、键盘等分 / 缩放 / 调整分隔条均按新布局树工作；会话快照改为递归 `LayoutSnapshot` 持久化，并自动迁移旧 column 快照与更早的单内容快照。

- **左边栏底部更多菜单与项目批量操作**：在左边栏下方「新建项目」按钮旁新增「更多」按钮（`ellipsis`），提供快捷操作菜单：
  - **打开文件夹**（Open Folder…）：选择文件夹新建或激活对应的项目。
  - **AI 整理全部**（AI Organize All）：为所有非归档项目批量触发 AI 自动生成项目名称、描述与图标。
  - **归档全部**（Archive All）：将当前项目列表中所有未归档的项目进行归档。
  - **清理空项目**（Clean Empty Projects）：查找没有任何终端会话且未设置自定义项目名称的项目，弹出确认对话框提示符合条件的项目数并完成清理。

- **AppKit Display Cycle 崩溃防护 (DisplayCycleLayoutProtection)**：拦截并防范在 macOS AppKit `NSDisplayCycleFlush` / hit-testing 期间由 SwiftUI（如 `ScrollViewCommitMutation`）触发 `setNeedsLayout:` -> `_postWindowNeedsLayout` 时抛出 `NSException` 导致 SIGABRT 崩溃的问题。当检测到处于 Display Cycle 或 hitTest 刷帧流程中时，自动将窗口布局请求安全延迟至下一个 RunLoop 循环执行，确保界面与 ScrollView 交互的稳定性。

- **上游功能移植 (Baseline: v0.1.35)**：已同步上游 `egoist/kero` 自 v0.1.19 至 v0.1.35 的核心功能与修复：
  - **分屏实时标题与控制按钮 (Live Pane Headers & Split Controls)**：支持在分屏布局中为每个 Pane 提供实时标题栏与独立分屏/关闭控制按钮（可在 `Settings → Terminal → Features` 中通过「分屏显示标题栏」开启/关闭，默认关闭）。
  - **Ctrl-Tab 按最近使用排序 (MRU Tab Switcher)**：Ctrl-Tab 切换卡片支持按最近使用时间 (MRU) 排序并优先选中上一个使用的标签页（可在 `Settings → Terminal → Features` 中通过「Tab Switcher Sort by Recently」开启/关闭，默认关闭）。
  - **Agent Worktree 自动跟进**：当终端内的 AI Coding Agent（如 Claude Code）切换至其独立的 Git Worktree / 子仓库时，右侧栏 Files、Git 和 Info 面板会自动解析前台 Job 进程目录并跟随定位至 Worktree 根目录。
  - **Finder 右键菜单 “Open in Qjiao”**：在 macOS Finder 文件夹右键菜单中集成 “Open in Qjiao” 快捷服务入口。
  - **`qjiao` CLI 命令行服务**：支持在终端中通过 `qjiao [path]` 快捷打开项目或文件，以及通过 `qjiao +themes` 浏览全局主题。
  - **终端 `umask` 继承污染修复**：将 `umask 077` 限制在写 PID 的子 Shell 中，修复终端新建文件/目录权限被误设为私有 `rw-------` 的 Bug。
  - **CJK 双宽等宽字体探测修复**：在 `TerminalFont` 中增加 `isTerminalMonospaced` CTFont 实际 Advance 测算，修复 CoreText 误判导致字体选择器漏选 CJK 等宽字体的问题。
  - **Settings Thicken Font Preview 渲染**：设置预览框采用 AppKit 原生 `FontThickenPreview` 配合 `setShouldSmoothFonts` 渲染，真实逼真地呈现 Ghostty 字体加粗效果。

- **Files Tree 右键菜单与代码编辑器底栏 Script Runner 功能**：在 Files 面板及 CWD 文件目录树中右键单选受支持的代码文件（`.js`, `.mjs`, `.ts`, `.tsx`, `.py`, `.go`, `.rs`）时，可直接使用「Run」或「Run with...」（Run with time / --inspect / --inspect-brk / --prof）运行当前文件；编辑代码文件时，底栏状态栏自动添加「运行 (Run)」/「停止 (Stop)」按钮，点击后自动在当前标签页中上下分屏调起终端，脚本运行中按钮切换为红色「停止」按钮可随时终止执行，再次运行复用/新建上下分屏；内置分层架构（Runtime Detector、Command Builder、Run Modifier 与 Terminal Executor），智能检测项目根目录及 Runtime 可执行文件，防范 Node.js 错误直接运行 TS、未含 `Cargo.toml` 运行单 Rust 文件等异常；复用现有 Terminal 与 Session 进程管理能力；并在 Settings → Files → Script Runner 中提供各语言 Runtime 的持久化设置。

- **本地应用发布流程**：Release 构建统一使用 Qjiao 的项目名、Scheme、`com.qzrzz.qjiao` Bundle ID、纯 arm64 架构与独立 Sparkle 签名密钥；在本机通过 Xcode-beta 完成嵌套代码裁切、Developer ID 签名、Apple 公证、DMG/ZIP 打包和 Sparkle appcast 生成；使用已被 `.gitignore` 排除的 `release/` 持久保存最近三个成功发布版本的完整 ZIP、appcast 与 SHA-256 清单，不再从线上下载旧包，生成更新时最多创建三个 Sparkle delta 并与完整包一起发布，缓存丢失或损坏时安全回退完整更新；已发布 build 作为不可变 delta 基线，重新编译、签名或覆盖发布必须递增 `CURRENT_PROJECT_VERSION`，脚本在生成上传前拒绝重用已缓存 build；zsh 启动代理按终端会话复制到临时可写目录，Shell 历史不再污染已签名 App Bundle，发布校验也会拒绝夹带 `.zsh_history` 的产物；应用退出时在保存会话后同步终止所有 PTY 进程组，避免旧 Shell 跨过 Sparkle 替换继续改写新版本，保证 delta 基线运行后仍然不变；appcast 在生成前后统一校正并复验每个历史 ZIP 所属的 GitHub Release tag，避免旧资产 URL 被改写到当前版本；成功后自动创建并推送版本标签，再由本机登录的 GitHub CLI 将全部下载与自动更新资产逐个上传到 `qzrzz/Qjiao` GitHub Releases，并显示文件名、大小、序号与等待时长，全部上传后显式退出 Draft 状态并复验正式发布状态；按版本、构建号、Release configuration、App 源码 Git tree、CHANGELOG 和 Git commit 分层保存经过产物复验的本地发布断点，网络失败或进程中断后可从未完成步骤继续，Web/文档提交不再触发 App 重编译，DMG 创建与 secure timestamp 签名也可分别恢复，Xcode 资源 bundle 的瞬时 CodeSign 失败会保留 DerivedData 并增量重试；默认覆盖同版本标签、资产和说明，不使用 GitHub Actions，并移除 Cloudflare R2、rclone 与 `releases.kero.sh` 依赖。
- 新增 `web/` 产品官网：基于 Figma 的黑绿视觉实现 Qjiao 长页介绍，使用 Vite、React、TypeScript 6 与 Base UI；首屏及 AI Agent、项目、文件、脚本任务、Git、启动器、包管理、开发服务器、代码格式化、图片查看与图片构建均拆分为独立 Feature 组件，每个组件的 Figma 切图保存在自身 `assets/` 目录；功能截图遇到 Figma 组件或组件实例时直接导出顶层节点，每个功能组只保留一张带 Alpha 的 2× 组合切图，不再拆解其内部图层；网站内置 Pally 与 General Sans 可变字体，并按 `Group 2` 的整组 Mask 裁切层级、`multiply` 色彩叠加模式还原应用图标关键帧动画，Logo 动画采用 4 秒单程的往复播放并支持减少动态效果偏好；生产构建通过 Sharp 将 PNG、JPG、SVG（包括 `public/` 静态资源）无损转换为 WebP 并重写引用，`dist` 只发布 WebP 图片；Bun 管理依赖并支持独立的本地开发、预览与构建；修正 Detect Dev Server 与 Code Formatting 功能组信息块的垂直定位。
- **Web 官网系统语言自动匹配与默认语言选择**：产品官网新增根据当前用户浏览器系统首选语言（`navigator.languages` / `navigator.language`）自动匹配并选择默认语言功能；访问根路径时自动识别中文（`zh-Hans`）、日文（`ja`）或英文（`en`），若为非英文系统且未手动指定，自动重定向至对应语言的静态子页面；通过 `localStorage` 记忆用户的手动语言切换偏好，在后续访问时优先遵从用户的自定义选择。
- 官网功能组统一桌面端 `180px`、移动端 `72px` 的垂直间距节奏，Web Dev 分区上间距收敛为 `180px`，末尾 Image Build 不再额外保留底部间距。
- 官网新增响应式 Footer：提供 Qjiao 品牌、项目 GitHub 源码与 X（@qzrz256）入口，以及开源版权信息。
- 官网新增 80px 顶部栏，展示与上游 `egoist/kero` 的关系并提供其 GitHub 仓库入口。
- **I18n 界面多语言**：默认**跟随系统**（匹配系统首选语言，非支持语言时自动回退为英文），可在设置中切换语言；目前支持 **Follow System / 跟随系统**、**English**、**简体中文** 与 **日本語**。
- **浏览器工具条样式优化**：`BrowserView` 工具条按钮支持 Hover 浅底与图标高亮（`Theme.primaryColor` 过渡），全面适配项目统一的原生毛玻璃浮层 `.macTooltip` 提示框，并提供 `⌘R` 快捷键 Badge。
- **主 Tabs 标签页视觉与尺寸优化**：主标签页整体高宽增加 2pt（单 Tab 最小/最大宽限调增 2pt，上下内边距增加 2pt），标签图标统一提升至 16pt；同时通过 AppKit 事件隔绝阻止窗口拖拽抢占 Tab 拖拽排序，提升可读性与交互体验。
  - **设置**：Settings → General → **Language** / **界面语言**。
  - **配置**：写入 `~/.config/qjiao/config.toml` 的 `ui.language`（`system` 默认不写回；`en` 为 English；`zh-Hans` 为简体中文；`ja` 为日本語）。
  - **实现**：`kero/L10n/`（`L10n.swift` 核心 + 各语言表如 `zh-Hans.swift`、`ja.swift`）；以英文源字符串为 key，运行时切换无需重启；菜单、设置、左右侧栏、Git/Files/Project/System/Note、命令面板、图标选择器、图片查看器、终端剪贴板确认与常用对话框等已接入简体中文与日本語，主题名称与代码预览样本保持原文。
- 新增 AI 统一模块 `kero/LocalAI`：应用侧只依赖 `LocalAI.prompt` 统一接口，可在本地 AI CLI 与云端 AI API 两种后端之间切换，现有 AI Select Icon、AI Name & Desc & Icon、AI Git Commit Message 等功能无需修改调用点。
  - **支持 Provider**：`grok`（`grok --single`）、`codex`（`codex exec`）、`claude`（`claude -p` / `--print`）、`agy`（`agy --print`）、`opencode`（`opencode run`）、`pi`（`pi -p` / `--print`），以及 **Disabled**。
  - **独立设置分类**：原 Settings → General → AI 已提升为 Settings → **AI**；可选择 **Local CLI** 或 **AI API** 后端。AI 表单采用紧凑单行对齐，不重复显示字段标签，仅保留必要的隐私与密钥状态；API Key 操作按钮保持固有宽度，窄宽度下不会显示为空白按钮。CLI 模式列出全部支持的 CLI，未安装项显示 “Not installed” 且不可选，可 Refresh 重新探测 PATH / 常见安装目录。
  - **AI API**：内置 OpenAI、DeepSeek、Anthropic、Google Gemini、OpenRouter、xAI 与自定义 OpenAI-compatible 提供方；支持编辑模型 ID 与 API 根地址，分别适配 OpenAI Chat Completions、Anthropic Messages 和 Gemini GenerateContent 协议；API Key 按提供方独立保存到 macOS Keychain，不写入 `config.toml`，并且只在进入 API 设置页或实际发起 AI 请求时按需读取，应用启动阶段不访问钥匙串。HTTP 请求与响应会在日志中打印供调试，认证头与 URL 中的密钥参数始终脱敏；同时输出 DNS、TCP/TLS、上传、TTFB 与下载阶段耗时，用于定位慢请求。
  - **配置**：写入 `~/.config/qjiao/config.toml` 的 `ai.headless-provider`（默认 disabled，不写回）。
  - **能力**：单轮 prompt、可选工作目录 / model / 超时 / autoApprove；`LocalAIRegistry` 负责安装探测与当前选择。
  - **提示词约定（唯一来源）**：全部可调教正文集中在 `kero/LocalAI/prompts/*Prompt.swift`（见 `LocalAIPrompts.swift` 索引）；业务 `*Suggest` 只做上下文采集与组装，禁止旁路 `.md` / 功能文件内大段模板副本。
    - `GitCommitPrompt` → AI Git Commit Message（遵循 **Writing language**）
    - `IconSuggestPrompt` → AI Select Icon（**不**涉及写作语言）
    - `ProjectMetaPrompt` → AI Name & Desc & Icon（**name / description** 遵循 Writing language；icon 除外）
  - **AI Select Icon**：基于项目 name / description / 路径末级、`package.json` name·description、`README.md` 前 20 行，以及 **Material Icon Theme** 逻辑名列表（不含 Brands），用 LocalAI 按「Material icon → SF Symbol → Emoji」优先级返回 JSON 并应用；入口为项目列表右键 **AI Select Icon** 与图标选择器 **AI Select**（未启用 provider 时禁用）。
  - **AI Name & Desc & Icon**：独立模块 `LocalAIProjectMetaSuggest` + `LocalAIProjectMetaTaskStore`；一次请求生成项目 **显示名称**、**描述** 与 **图标** 并写入配置；上下文与 Material 列表复用图标功能；入口为项目列表右键 **AI Name & Desc & Icon**（与纯选图标互斥、可取消、行内转圈）。
  - **AI Git Commit Message**：独立模块 `LocalAIGitCommitSuggest` + `LocalAIGitCommitTaskStore`；根据已暂存 (Staged，仅已暂存存在时) 或工作区已变更 (Unstaged 与未跟踪文件，仅已暂存为空时) 的上下文，按 Conventional Commit 规范生成提交说明并填入 Git 面板 Message 输入框。
    - **入口**：Git 面板 Message 输入框右侧 **sparkles.2** 按钮；Commit 选项菜单中的 **AI 完成变更提交**（自动暂存全部变更、生成 Commit Message 并完成提交）；Recent Commits 行右键 **AI Commit Message**（生成中可取消）。
    - **设置**（Settings → AI → Writing）：**Writing language**（`ai.writing-language`，默认 English，支持英语、简体中文、繁体中文、日语、韩语、法语、德语、西班牙语、葡萄牙语、俄语、意大利语等常用语言；项目可在 `config.json` 的 `aiWritingLanguage` 覆盖）与 **Git Commit Message Emoji**（`ai.git-commit-emoji`，默认开启 Gitmoji）。
- 左边栏开关（`sidebar.left`，⌘B）：展开时显示在左侧边栏顶栏右侧；收起后移到 Tabs 顶栏左侧（开关左右边距加大：左 16pt / 右 12pt）。
- **项目使用自动标题优化**：项目右键菜单中的「使用自动标题」改为独立布尔值开关（Toggle）；开启时项目显示终端动态标题，且不影响/清空项目已设置的自定义名称，关闭后可恢复自定义项目名称。
- 左侧边栏项目归档功能：支持归档与解除归档；归档项目默认收起居于左侧边栏底部，点击可展开查看列表；解除归档后自动回到上方正常项目列表；已归档栏展开后第一行常驻显示搜索输入框，按项目名与描述实时筛选。
- 左侧边栏顶栏在侧栏开关左侧增加窗口置顶按钮（`pin` / `pin.fill`）：切换当前窗口 `NSWindow.level` 为 floating / normal，激活时 tint。
- 增加窗口拖拽区域。
  - 顶部、右侧边栏添加可拖拽区域。
- 右面板文本颜色提升可读性。
- 等宽中文字体来显示终端和代码，可以对齐含有中文的表格、注释了。
  - 默认使用内置 `Source Han Sans CN VF Mono1200` 作为中文等宽回退字体，并可在设置中关闭。
- **拖拽文件夹打开项目**（仅左侧边栏）：
  - 从 Finder 将文件夹拖到**左侧项目栏** → 若列表中已有同路径项目则激活（归档中则先解除归档），否则新建项目并在该目录启动终端。
  - 拖到终端区域仍为插入 Shell 路径（与文件一致），不再整窗拦截创建项目，避免覆盖终端 drop。
  - 排除软件内部 Files / CWD 文件树拖拽，避免误触发。
- **Files Tree 拖拽移动与确认对话框**：文件树支持将文件和文件夹拖拽移动到目标文件夹或根目录，在移动前弹出 macOS 原生确认对话框（显示具体源文件名/项目数量与目标位置，防止误触）；确认后安全移动磁盘文件，自动展开目标目录并联动更新打开的主编辑器标签页路径。
- **Files Tree 回车键就地重命名**：符合 macOS Finder 原生使用习惯，在文件树中选中单个文件或文件夹时，直接按下 `Return` / `Enter` 键即可立即调起就地重命名输入框，按 `Enter` 确认提交或 `Esc` 取消，流畅无缝。
- 项目支持自定义图标（预置 / Emoji / SF Symbols / Select File）；图标选择器独立为 `ProjectIconPicker.swift`：
  - **预置**：列出本应用内置 Brands（`TerminalAppIcons`）与 Material Icon Theme 图标，可搜索选择。
  - **SF Symbols**：左侧分类浏览（Suggested / Coding / Arrows…）、分类内搜索防抖、多词过滤。
  - **Select File**：从磁盘选择图片（支持拖放）；复制到 `~/.config/qjiao/projects/{id}/icon.*` 托管，重启后仍可用。
  - 类型切换使用 SwiftUI 原生传统 segmented Picker（中号、居中显示）。
  - 选择器内容区固定高度，切换类型不抖动；预置图标异步惰性加载 + 缩略图缓存，网格仅渲染可见项。
  - 数量徽章、当前图标预览与 Clear。
- 增加 Tabs 选择菜单；顶栏新建标签紧挨标签条，标签总览下拉固定在右侧侧栏按钮旁；左侧栏开关 / 新建 / 下拉 / 右侧栏 / Zoom 共用 `HeaderIconButton`（26pt 热区、caption 图标不变；仅 hover 浅底，按下/激活无底色，激活仅 tint）。右侧工具用 ZStack 固定叠层 + 左侧 padding 硬预留宽度，标签再多也不会挤占下拉/侧栏。
- 顶栏当前 Tab 在窗口 / 侧栏改变可视宽度、标签增删 / 排序或动态标题改变宽度后仍会自动保持完整可见。
- 命令面板支持搜索并快速打开当前项目文件：Git 仓库遵守 tracked / untracked 与 ignore 规则，普通目录自动跳过隐藏目录、依赖和构建产物；文件名匹配优先于父目录匹配，结果支持模糊排序与命中高亮。筛选结果重排不再被静止鼠标误选，Escape 首次清空搜索词、再次关闭面板。
- 终端默认启用直接点击移动光标，可在设置中关闭；通过完整转发用户 Zsh 启动文件并在主题加载后注入 OSC 133 Prompt 标记，由 libghostty 原生计算目标位置和发送方向键，兼容用户自定义 `ZDOTDIR`。
- **自定义闲时标签页名**：在「设置 -> 终端 -> 功能」与标签页右键菜单「Zsh Idle title」中新增闲时标签页名设置（$ZSH_THEME_TERM_TITLE_IDLE），提供默认（不修改）、文件夹名在前（%1~ — %n@%m）、2 层文件夹名在前（%2~ — %n@%m）、简短（%1~ — %n）、极简（%1~）等可选项。由 Zsh Prompt 原生控制与无声转义输出，不污染终端 PTY 输入。
- 在 `kero/FilesFind` 中实现以 VS Code 为目标的全局文件与文本搜索模块：
  - **Files 面板深度集成**：在 Files 面板顶栏支持模式切换（文件树 / 文本搜索），按 `⇧⌘F` 或菜单项一键无缝唤起全局文本搜索模式。
  - **高效搜索引擎驱动**：内置开箱即用的原生 macOS `ripgrep` 可执行二进制（`kero/VendorBin/rg`），优先通过内置 `rg --json` 进行毫秒级流式文本检索；无 `rg` 环境下亦可自动无缝降级至 Swift 多线程并发扫描引擎（`TaskGroup`），智能剔除忽略项（`node_modules`、`.git`、`dist` 等）。
  - **完整的 VS Code 搜索控制**：支持搜索与替换框、区分大小写 (`Aa`)、全字匹配 (`\b`)、正则表达式 (`.*`)，以及精准的包含文件与排除文件过滤规则 (`files to include/exclude`)。
  - **精细的结果展示与交互**：按文件树/平铺归类展示匹配结果，高亮显示文本上下文与匹配关键字，支持单条替换与项目一键全替换；点击搜索结果（文件头或具体匹配行）直接打开对应文件；若文件已经打开，会自动切换当前 Tab 并将光标精确定位且尽可能平滑滚动至屏幕/视口垂直中心。
- **文件树右键菜单在终端打开**：文件目录树（Files / CWD 面板）及侧边栏项目右键菜单新增「在终端打开」（Open in Terminal）功能；选择文件或目录右键即可在对应目录创建并切换至新的终端会话标签页。
- 项目支持添加描述，并显示在项目列表中。
- 项目右键菜单支持在 Finder 中打开项目目录和配置文件夹。
- 项目名称、图标和描述改为保存在配置文件夹的独立项目配置文件中。
- 项目配置数据集中到 `~/.config/qjiao/projects/{projectId}/`（Debug 为 `qjiao-dev`）：`config.json`（名称 / 图标 / 描述 / 主题 / 目录 / Launchers / 归档）、`icon.*`（自定义图标）、`note.txt`（笔记）；会话与窗口快照存储到 `~/.config/qjiao/session.json`（Debug 为 `qjiao-dev`，解决了正式版与 Dev 版因 Bundle ID 相同在 UserDefaults 中互相覆盖 `sessionSnapshot` 导致项目列表丢失的问题）；关闭项目时删除整个项目配置目录；首次读写自动从旧路径（`projects/{id}.json`、`projects/icons/`、`notes/` 及 UserDefaults）无缝迁移。
- 项目关闭按钮支持普通点击确认和 ⌘ 点击直接关闭。
- 右侧面板区分项目目录 Files 和终端当前目录 CWD，相同时自动隐藏 CWD。
- 分栏终端的右键菜单支持直接关闭当前面板。
- 关于页面：作者图标更新为 `Qzrzz-logo-mono-green_512.png` 品牌图标，并支持在关于链接行保留图片原配色展示。

- 终端未设置标题时默认显示启动工作目录的最后一级名称。
- 右侧栏 **Project** / **Info** 语义与采集：
  - **Project**：项目根路径 + 根 `package.json` scripts；进程/端口为项目下**全部 session** shell 子孙的并集（一次 `ps` + 一次 `lsof`）。
  - **Info**：当前终端 CWD + 该 cwd 下 `package.json` scripts；进程/端口仅当前 session；shell 名 / pid。
  - npm script 在对应路径新开终端运行（Settings 包管理器）；右键 time / `--inspect` / `--prof`；采集逻辑集中于 `SidebarProbe`。
- **包管理器设置选项优化**：Settings → Project → 包管理器新增「自动识别」（Auto Detect）选项，根据项目的 `packageManager` 字段及 lockfile（`bun.lock`/`pnpm-lock.yaml`/`yarn.lock`/`package-lock.json`）智能选取包管理器；显示文案去掉 `run` 后缀（如 `自动识别`、`npm`、`bun`、`pnpm`、`yarn` 等）。
  - 展开分组有左边距；数量徽章紧跟标题；空分组自动收起。
- 从右侧栏启动 npm scripts、项目任务、Start 终端命令等命令时，标签图标显示转圈动画；手动在终端输入命令不再触发转圈，已匹配到的终端应用图标仍优先显示。
- 右侧 Start 面板可保存、排序并一键启动项目的终端命令、应用程序、Finder 文件夹和网页。
  - 终端启动项可指定新标签标题，并与手动 Tab 重命名共用。
- 终端启动项可指定新标签或上、下、左、右分屏，并支持一键按顺序启动全部项目命令。
- 终端通过 OSC 52 读取系统剪贴板时需要确认，并对可能执行命令的粘贴内容显示安全警告。
- 终端粘贴增强：Finder 复制的文件粘贴为 shell 安全绝对路径；纯图片剪贴板通过原生 Ctrl-V 交给支持图片的 TUI 读取。
- 新建终端声明 `TERM_PROGRAM=ghostty`，让支持 Ghostty 的 CLI/TUI 自动启用图片等扩展能力。
- 新建终端不再注入 `LANG` / `LC_*`，完整保留用户 Shell 自己的区域设置。
- 终端进入 Vi / Vim / Neovim 等编辑器时自动显示上下文帮助栏，支持一键保存退出、放弃更改退出，以及切换 Insert / Normal 模式；可在 Settings → Terminal 中关闭。
- 为终端内 CLI 增加麦克风输入权限声明，支持语音输入类命令行工具。
- 升级 PierreDiffsSwift，修复 Git Diff 中中文等非 ASCII 字符的显示问题。
- Git Diff 升级为虚拟化渲染，仅绘制可见行并在后台高亮，大文件不再阻塞窗口；Diff 字体同步终端字体设置。
- 记住左右侧栏的显示状态和右侧面板选项，重启后自动恢复。
- Tab 支持手动重命名；Start 新标签标题与手动名称使用同一机制，可恢复自动标题。
- 修复 Vim、htop 等全屏终端程序的背景延伸和底部提示行间距。
- 增加终端字体笔画加粗开关，默认关闭。
- **图片查看器分屏与浏览器右键菜单**：图片查看器右键菜单新增分屏操作（向右/向左/向上/向下分屏）及新建浏览器标签页/窗格菜单，与终端及文本编辑器的右键菜单体验保持一致。
- **SVG 文件查看器上下分屏预览**：打开 `.svg` 文件时自动启用上下分屏布局，上方为带语法高亮的 SVG 代码编辑器，下方为 SVG 实时预览区；编辑代码即时同步渲染；分割条可自由拖拽调节比例（`AppStorage` 持久化）；预览区支持背景模式切换（透明棋盘格 / 纯白 / 纯黑 / 主题默认）、滚轮缩放、拖拽平移、双击重置；输入不完整 SVG 时保留上一次有效渲染并显示黄色语法警告。
- 外观设置支持分别调整窗口背景与终端背景不透明度。
- 支持 Ghostty 配色主题，亮色和暗色主题可分别设置并应用到整个窗口。
- 项目右键菜单支持项目级配色：与全局 Appearance 一样分 **Light colors / Dark colors** 两套独立覆盖（也可整项「跟随全局」）；只改当前项目在亮/暗环境下的 Ghostty 配色，**不**强制窗口亮暗（亮暗仍由全局 System/Light/Dark 决定）。各侧含精选 / Cool / Warm 与完整目录；菜单项带配色预览图标。旧版「单选并强制亮或暗」配置会迁成对应侧覆盖。
  - 当活动项目覆盖了全局配色时，**Settings → Appearance** 显示一行提示（项目名与生效 Dark/Light 主题）。
- **用户自定义主题**（Settings → General → Appearance → **Custom Themes**）：
  - 新建主题时指定 **背景色 / 文本色 / 强调色**：背景与侧栏、文本（侧栏/标签/面板主次文字）、强调色（激活与光标）驱动窗口 chrome；分割线等由三色推导。
  - 为每个自定义主题指定搭配的 **Ghostty 终端主题**（完整 ANSI palette），并标记为 **Dark** 或 **Light**；可选 **跟随背景色**，让终端背景使用自定义背景色（palette 仍用 Ghostty）。
  - 自定义主题出现在全局 Dark/Light colors 选择器与项目右键 Theme 菜单的 **Custom** 分组及「全部…」列表中。
  - 文件保存在 `~/.config/qjiao/themes/{uuid}.json`（Debug 为 `qjiao-dev`）；`config.toml` 的 `theme-dark` / `theme-light` 写入主题显示名。
- 左侧面板底部增加主题菜单，可快速切换 System、Light、Dark 外观。
- Default Dark 主题的左侧项目面板改用更深的 `underWindowBackground` 材质，避免系统侧栏材质提亮背景。
- 修复开启终端不透明度时切换 Tab 后未选中的 Git Diff 对比器透出显示的问题，并将终端背景不透明度设置应用于 Git Diff 对比器。
- 终端 Tab 宽度展示：未挤满时最小 150、最大 220；标签条已满（需要横向滚动）时最小 130、最大 140，空间足够再恢复；标题变长立即扩张，变短延迟收缩并带过渡动画，减少抖动。
- 优化文件查看器（FileViewer）工具栏：提取可复用原生 macOS 风格 Tooltip 系统 ([MacTooltip.swift](kero/MacTooltip.swift))，支持极速悬停弹出、快捷键 Badge 格式与自适应多方位 (.top / .bottom 等) 定位；移除工具栏按钮悬停放大动画，恢复沉稳平整的原生 macOS 操作手感，并增强图像旋转、镜像翻转与双图对比视图。
- 设置面板采用**左侧分类导航 + 右侧表单**布局（General / Terminal / Editor / Files / Project / About）；更新设置归入 General，并在 About 中展示项目和上游 Kero 信息。
- 设置 Editor 分组支持分别选择 Light / Dark 编辑器配色；两种外观都可独立跟随全局与当前项目主题或设置专用主题，不改变终端和窗口主题；编辑器专用主题内置 VS Code 风格的 Dark+、Light+、GitHub Dark、GitHub Light、One Dark、One Light、Monokai Pro、Xcode、Ayu、Solarized，并直接使用其语法 token 配色即时重绘。
- 源码文本编辑器增加可开关的英文底部状态栏：显示保存状态、当前文件大小、选区行数/字符数、文件格式，以及项目本地 `oxfmt`（优先）或 `prettier` 的格式化入口；格式化会先保存并以 `--write` 改写当前文件后重新载入。
- 设置 Files 分组：Display File Size 默认开启，可在右侧 Files / CWD 文件树中显示文件大小（目录不在刷新时自动计算）；关闭时写入 `files.display-file-size = false`。
- Files / CWD 目录树：hover 文件夹时右侧显示 Size 按钮，点击后在后台按需统计该文件夹逻辑体积（不阻塞 UI、不跟随符号链接、可取消与缓存；完成后显示大小，再点可重算）；多选时 Size 作用于全部选中目录（按钮显示数量，队列限流并发 2），右键菜单亦支持 Calculate Size。
- 设置 Files 分组可配置文件树字体族与字号（默认内置 Inter Variable / 13pt，资源 `kero/Fonts/InterVariable.ttf`），写入 `files.font-family` / `files.font-size`，行高与图标随字号缩放。
- Files / CWD 目录树支持选中态：单击选择、双击打开文件（目录为展开/折叠）；⌘ 点击切换多选、⇧ 点击按可见范围多选；⌘A 全选；右键菜单与废纸篓支持批量操作；箭头单独切换展开。
- Files / CWD 支持复制/粘贴文件与文件夹（右键 Copy / Paste，快捷键 ⌘C / ⌘V；剪贴板为 fileURL，可与 Finder 互通）；粘贴目标为选中文件夹内或文件父目录；同名冲突整批只询问一次，可选 New Name（`… copy`）或 Overwrite，应用于本批全部冲突项；Cancel 取消整批粘贴。
- Files / CWD 与 Note 的本地快捷键按真实键盘焦点隔离：未获焦的可见侧栏不参与窗口的 key-equivalent 处理；终端、编辑器或文本输入控件获焦时不再被侧栏残留点击状态、鼠标悬停或可见的 Note 抢占，方向键及文件操作键仅作用于当前焦点区域。Files 的 `⌘F` 按焦点形成三态操作：文件树打开 Filter、Filter 输入框切换至 Search、Search 主输入框关闭 Search 并返回文件树；该循环不作用于 CWD 或其他区域。
- 统一 chrome 字号体系（`SidebarTypography`）：左侧项目栏、右侧边栏 Start / Files / CWD / Git / Info 与顶栏 Tabs 共用 title / body / secondary / caption 等角色；列表与标签主文字统一为 13，正文字号不低于 11 以提高可读性。
- Start 面板「Add Launcher」按钮加大（顶栏 + 与空状态主按钮）。
- 右侧面板上下分区框架：上半保留 Start/Files/Git 等；中间可拖分割（默认 70/30，双击恢复）；下半区顶部为 System / Note tabs（最小宽 75、宽度随内容），可收起到仅显示 tabs（单击 tab 切换收起/展开，或双击底栏切换）。
- System 面板通过命令行采集主机信息（CPU%、内存、磁盘可用/总量、磁盘传输量、网络上下行、本机局域网 IP、系统代理、Google/Baidu/Cloudflare/GitHub 可达性）；不显示温度；并行 CLI 轮询、超时杀进程、手动刷新；预留 CLI runner 以便日后 SSH 远程。
- System 内存指标与活动监视器对齐：用 `vm_stat` 计算 Used = App + Wired + Compressed（不含文件缓存）；tooltip 展示 App / Wired / Compressed / Cached / Free；`top` PhysMem 仅作回退。
- Note 面板：按项目的纯文本草稿编辑器（自动换行、⌘F 查找）；内容防抖保存到 `~/.config/qjiao/projects/{projectId}/note.txt`（Debug 为 `qjiao-dev`），切换项目 / 收起面板 / 隐藏侧栏时立即落盘。
- System 面板可视化：CPU/内存/磁盘紧凑单行 + 一行高历史折线；磁盘写入每 30s 用 `iostat -Id` 采样，记录最近 1 分钟量（折线）、会话累计量（行内 W）与累计时长；Net / IP / Proxy 紧凑行（IP 为默认路由网卡 IPv4 可复制；Proxy 复制 `export https_proxy=…`）；Reachability 可配置站点/间隔/GET·HEAD，柱状延迟历史，右键编辑与立即检测，探测走系统代理。
- System Reachability 探测间隔默认 30s，下拉菜单显示勾选态与 `30s (Default)` 标注；间隔写入 `~/.config/qjiao/config.toml`（`system.reachability-interval`），重启后保留。
- System Reachability 保留每个站点最近一次探测错误；hover 提示展示 Last error，右键菜单提供 Copy error（无错误时 disabled）。
- System Reachability 支持按站点配置 GET/HEAD：添加/编辑表单分段选择、右键菜单勾选切换并立即重测；curl 探测隔离用户 curl 配置、仅允许 HTTP(S)、按系统 HTTP/HTTPS/SOCKS 代理及绕过规则访问，PAC/WPAD 会明确提示暂不支持；配置随站点持久化。
- System 面板数字与 IP/代理地址统一 `monospacedDigit`；自定义 Tooltip 单行等宽数字、多行等宽字体以对齐 Mem/Disk 等指标详情。
- 右侧 Files / CWD / Git 文件列表按文件名与扩展名显示 Material Icon Theme 彩色图标（[vscode-material-icon-theme](https://github.com/material-extensions/vscode-material-icon-theme)）；目录名匹配专用文件夹图标，展开/收起使用 open 变体；可用 `bun run scripts/vendor-material-icons.ts` 更新图标资源。
- 顶栏 Tabs（含 Tab 总览、重命名与分栏拖拽缩略图）对打开的文件 / Diff 使用与文件树相同的 Material Icon；终端 Tab 默认使用 SF Symbol，仅右侧栏发起的命令显示转圈，匹配到终端应用时仍优先显示应用图标。
- 终端应用图标识别：检测前台进程（如 `agy` / `grok` / `codex` / `claude` / `rsbuild` / `node` 等）并切换 Tab 图标；图标来源为 Material Icon Theme 与本地文件（`icon` 字段指定 `icons/` 下的 `.png` / `.svg` 等文件名，如 `antigravity-color.png`）。配置见 `kero/TerminalAppIcons/apps.json`，用户可在 `~/.config/qjiao/terminal-app-icons.json` 覆盖；`bun run vendor:terminal-app-icons` 可同步 Iconify 资源。枚举前台进程组内全部 PID 并解析 argv（支持 `npm run dev` → `node …/rsbuild`）。
- 左侧面板底部 Theme 按钮支持左键点击立即切换主题（Light ↔ Dark，System 模式按系统实际外观反转），右键菜单提供主题选择、分割线及 Appearance Settings 快捷入口。
- 右侧面板下半区底部 Tabs（System/Note 选项卡栏）的最小高度调整为 36，并优化展开逻辑（若之前拖拽将高度缩至最小，点击 tab 展开/双击底栏时自动恢复至默认 70/30 高度）。
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
  - 顶栏与底栏 Tabs 按实际文案测宽自适应：空间足够时全部显示完整标题，稍紧时仅选中项保留标题，极窄时退回全图标；间距随可用宽度在 4pt / 2pt 间收紧。移除阻断鼠标手势的 ScrollView，完全恢复顶部 `WindowDragArea` 的窗口拖拽与双击动作体验。
  - System 面板 IP 行引入 `ViewThatFits` 自适应机制，宽屏单行展示，窄屏自动切为双行分层，彻底解决内网/公网 IP 宽度溢出导致界面错位的问题。
- **Git 面板按钮交互**：Header 筛选 / 刷新 / 更多、Commit / Sync 主按钮、AI 生成 Message、提交选项菜单、变更行 Stage/Unstage/Discard、分组标题批量操作等统一增加 hover 浅底高亮，并接入 `macTooltip` 极速 Tooltip（Commit 显示 `⌘↩` 快捷键角标）。
- Project Tab 的 Launchers 分组空状态（No launchers）增加内容左边距，保持与其他分组及条目垂直对齐。
- 新增 Project 面板 `PACKAGE` 信息与操作分组：
  - 自动解析根目录 `package.json` 中的 `name`、`version` 与 `repository` 仓库链接。
  - 支持包名与 SemVer 版本号文本选择 (`textSelection`)，并在包名后新增一键复制包名按钮 (`doc.on.doc`)。
  - `PACKAGE` 分组 Header 右侧新增更多操作菜单 (`ellipsis`)，包含 `Open package.json`、`<pm> install`、`<pm> publish`、`<pm> update` 及 `Update Deps (npx taze)`。
  - 接入智能包管理器 (Package Manager) 识别机制（优先级：`package.json` 中的 `"packageManager"` > `bun.lock`/`pnpm-lock.yaml`/`yarn.lock`/`package-lock.json` > 全局配置 > `npm` 默认），点击菜单在独立终端 Tab 中开 Shell 执行。
  - System 面板指标折线图、站点延迟柱状图及 Detail 文字改用弹性 Width 与布局优先级，并在侧栏外层施加 `.clipped()` 剪裁保护，保障任何窄宽度下的精致排版与稳定性。
  - 路径区操作按钮（Finder / VS Code / Copy）限制单行显示（`.lineLimit(1)`）与自适应字号缩放（`.minimumScaleFactor(0.7)`），防止在极窄边栏下按钮文字折行撑高。
- 移除右侧边栏顶栏 Start tab，并将项目启动项（Project launchers）整合为 Project 面板中的 `LAUNCHERS` 分组：
  - Header 右侧右对齐集成一键运行全部启动项（`play.fill`）与快捷新增（`+`）操作按钮。
  - 启动项行重构为紧凑整洁的面板对齐样式，精简高度并保留拖拽重排抓手、类型图标、按需展开编辑与独立运行控制。
  - 展开后的行头与编辑区使用完整覆盖条目的单层轻量圆角背景（与 hover 同色且不重复叠加）；编辑区向下自然展开并保持原行头位置，Launcher 条目之间不显示分割线。
  - 移除不再使用的独立 Start 面板实现，共用 Launcher 组件集中于 `LauncherViews.swift`。
- 优化右侧边栏面板滚动条显示逻辑：精确为 `Note`、`Files`、`CWD` 与 `Git` 面板开启滚动条指示，方便长列表浏览；为 `Project` 与 `System` 面板保持隐藏滚动条，保持界面简洁精致。
- 优化 `NPM SCRIPTS` 列表交互与 Shell 状态追踪机制：
  - 保持与 `package.json` 源代码中 `scripts` 的物理定义顺序一致，不再强制按字母字典序重排，准确呈现开发者的脚本声明顺序。
  - 条目整行接入应用统一的原生毛玻璃 `macTooltip` 提示框，悬停时即时展示 `package.json` 中配置的具体命令内容（`script.command`）；整行单击设为选中高亮，仅待运行（`idle`）状态下双击触发运行脚本；正在运行状态下禁用双击，防止误操作重复触发。
  - 引入「待运行 (`idle`)」、「正在运行 (`running`)」与「正在停止 (`stopping`)」状态流转机制，自动绑定与监听后台 Shell / Session 的前台进程（`isForegroundCommandRunning`）及生命周期。
  - 当脚本子进程在 Shell 中执行完毕（命令结束恢复至 prompt 提示符）时，状态立刻自动恢复为「待运行」，并精确计算与刷新上一次运行耗时。
  - 处于「正在运行」时，图标转换为红色停止按钮（`stop.fill`，单击停止），且右侧动态呈现「重新运行」按键（`arrow.clockwise`）；
  - 处于「待运行」状态时，自动在条目右侧格式化展示上一次运行耗时（如 `4.2s`、`522.4ms`、`1m12.5s`，精准保留 1 位小数，整数时无多余 `.0`，配合 `monospacedDigit` 等宽数字字体显示）。
  - 自动读取 Settings 中配置的包管理器（`bun` / `pnpm` / `yarn` / `npm`），为启动的新终端 Tab 动态命名为 `<scriptName> (<pmCommand> run)` 格式（例如 `dev (npm run)`、`build (bun run)`）。
  - 抽象解耦出通用项目脚本执行引擎模块 `ProjectScriptEngine`：定义 `ProjectScriptCategory`、`UniversalProjectScript` 与 `ProjectScriptProvider` 探针协议，统一管理跨平台/多语言任务的构建、调度、生命周期监测与端口绑定，为后续扩展 Gradle、`tool.uv.scripts`、PDM、Rust alias 及 Makefile 等方案奠定架构基础。
- 优化右侧边栏 Project 与 Info 面板 Header 与顶部布局：以 Project 面板为统一模板对齐 Info 面板 Header 样式；Info 面板顶部图标动态响应当前终端 Tab 的前台应用图标（如 Node/Python/Cargo/Antigravity）与运行状态；移除冗余的 CWD/PROJECT 分组，在 Header 标题下方集成单行无边框只读路径输入框（支持放置光标平移浏览，右侧添加 20pt 渐隐遮罩提示内容超出隐藏）与 Finder / Copy 操作按钮，并在内容区顶部统一设立 VS Code 打开项目的专属区域。
- 新增 AI 工具打开按钮与动态选择注册表：通过 `AIToolRegistry` 动态检测系统已安装的 AI 桌面 GUI 应用（Codex、Claude Code、Claude Desktop、OpenCode、Antigravity 等）与 CLI 命令行工具（`codex`、`agy`、`claude`、`opencode`、`grok` 等）；在 Project 与 Info 面板顶部形成「编辑器 + AI 工具」双核并列组合栏。桌面应用通过 `NSWorkspace` 激活打开目录，CLI 工具自动在新终端 Session 中携带目标路径启动；图标自动匹配 Material / App 真实图标，右侧 `[⌄]` 原生菜单支持一键切换并持久化至 `config.toml` (`ai.preferred-tool`)。
- 优化右侧栏 Project 面板 Header：Project 图标变为带 hover 浅底高亮可点击按钮，点击弹窗设置项目图标；Project 名称与 Project 描述均升级为就地编辑输入框，常规状态无背景无描边，获取焦点后高亮显示描边与背景色并即时保存。
- 终端 Tab 惰性加载机制（Lazy Allocation）：启动时反序列化快照仅为当前活跃选中的 Tab 实例化 LibGhostty 引擎与 Shell 进程，所有后台 Tab 保持惰性装载；在首次切换到目标 Tab 时低于 10ms 瞬间无感激活，将包含数十个历史 Tab 时的 App 启动内存占用从 ~1.0GB 降低至 ~60MB。
- 已初始化但位于后台的终端停止 GPU surface 合成，回到前台时自动恢复，降低多 Tab / 多分栏的 GPU 显存占用。
- 优化 Ctrl-Tab / Ctrl-Shift-Tab 标签切换器：按住 Control 预选、松开确认、Esc 取消；采用与上游一致的自适应预览卡片网格，展示终端、文件、图片与 Diff 缩略内容；复用顶部终端 Tab 的动态图标，可显示当前前台应用；并且只截取已经初始化的终端，打开切换器不会启动后台惰性 Shell。
- **原生内置浏览器**：基于 `WKWebView` 提供浏览器 Tab 与分屏 Pane，地址栏兼具 URL 输入和 Google 搜索，支持前进、后退、刷新、停止加载、复制地址及在默认浏览器中打开；浏览器 URL 随窗口快照保存和恢复，网页标题与 favicon 会同步到顶部标签、标签总览和 Ctrl-Tab 预览；网页链接右键可在新浏览器 Tab / Pane 中打开，并可从命令面板、应用菜单、终端与编辑器右键菜单创建浏览器；浏览器地址栏、网页内容与命令面板之间会按 Pane 选择恢复焦点。本功能仅接入 Ghostty，不包含 Alacritty 后端、bridge 或 Rust 代码。
- Project / Info 的 Processes 列表过滤已经退出且等待回收的僵尸进程。
- 优化右侧栏 Tabs 与 Project 等面板空白区域拖拽逻辑：为右侧 Tabs 顶栏、Project / Info / Files / Git 面板 Header 及 Project 面板空白背景配置 `WindowDragArea`，允许用户拖拽空白区域直接移动窗口。
- 右侧栏 Project 面板增加 PACKAGE 分组：双行紧凑布局（首行包名与右侧独占仓库跳转图标按钮，次行版本号与 SemVer `[+]` 递增按钮及 `MAJOR` / `MINOR` / `PATCH` / `Git tag` 下拉菜单）；点击快速递增并改写 `package.json` 中的 `version` 字段或生成 Git 标签；若未检测到 `package.json` 或无有效字段则自动隐藏该分组。
- 重构右侧栏代码结构：`RightSidebarView` 只保留侧栏框架与面板调度，Files、Git、Project、Info 及公共视图按职责拆分；Gradle / Just / Cargo / CMake / Makefile 任务分组统一复用同一组件与交互逻辑。
- 优化 Project / Info 信息刷新机制：共用脚本目录采集器并并行解析各类任务；项目配置改为文件事件监听，面板每次显示、切换到对应标签或手动点击刷新时强制重新载入，不再通过 2 秒轮询读取文件（定时器仅刷新进程与端口）；切换项目、CWD 或 Session 时立即清理旧列表并取消过期任务；`ps` / `lsof` 支持取消与 3 秒超时。脚本状态使用「项目 + 工具 + 目录 + 名称」唯一键，端口按所属 Shell 精确绑定并在采集完成后即时更新；刷新按钮支持 hover 高亮，刷新期间图标旋转并禁止重复点击。修复 Info 端口按钮不更新、`Cargo.toml` 修改后任务列表不刷新，以及 Project 刷新时版本输入框旧草稿覆盖并阻止重新加载 `package.json` 版本号的问题；版本输入框仅在内容实际改变后于 Enter 或失焦时写盘。
- 优化 Git 面板：展开收起的分组控件（MERGE CHANGES、STAGED CHANGES、CHANGES、RECENT COMMITS），展开内容添加与 Project 面板一致的左边距（`SidebarPanelMetrics.expandedContentLeading`）；Header 按钮统一添加 Hover 悬浮底色高亮，刷新按钮使用与 Project/Info 面板一致的 `SidebarRefreshButton` 带来平滑 360° 转圈动画；统一分组 Header (`SidebarSectionHeader`) 与文件变更行 (`GitEntryRow`) 右侧操作按钮 (`↰` 撤销 / `+` 暂存) 的 18x18 尺寸、4pt 间距与 8pt 右边距，实现两条操作按钮列点对点的精准垂直对齐。
- **右侧栏 Git Tab 变更数角标**：在右侧边栏 Git 标签页右侧新增自定义角标，使用 `monospacedDigit` 字体显示当前仓库未提交变更总数（包含冲突、暂存与未暂存变更）；右侧边栏展开时持续保持 Git 状态更新，即使处于 Project/Files/CWD/Info 等其他标签页也能即时感知与查看变更状态；角标无变更时自动隐藏，超过 99 时显示 `99+`。
- 优化 Git Commit 编辑功能：核心实现封装于独立文件 `GitCommitEditor.swift`，支持编辑任意历史 Commit Message (Reword)、修改作者/邮箱 (Author)、修补合并暂存改动 (Fixup/Amend) 以及丢弃提交 (Drop)；可在 Git 面板 Recent Commits 的右键菜单与极简编辑弹窗中直接交互并自动刷新状态；`Recent Commits` 行增加 Hover 悬浮圆角背景高亮，并开启 `.textSelection(.enabled)` 允许选中文本。
- 优化 FilesTree 面板：
  - 顶栏图标按钮（Filter / Sort / Reveal in Finder）采用统一的 `SidebarIconButton` 与 `SidebarMenuIconButton` 视图（标准 22x22 尺寸、5pt 圆角、平滑 hover 悬浮高亮与 active 激活态），保持整个右侧边栏 Header 按钮语言高度统一。
  - 新增文件排序功能：顶栏增加排序按钮（`arrow.up.arrow.down`），支持按文件名 (`File Name`)、修改时间 (`Modification Date`) 及文件大小 (`Size`) 排序，并支持切换升序 (`Ascending`) / 降序 (`Descending`)，目录始终保持顶部排列，排序设置持久化保存。
  - 文件夹 Hover 增强：悬停文件夹行时，右侧除了 `Size` 按钮外，新增新建文件夹（`+`）按钮，点击后自动展开该目录并进入内联新建文件夹草稿行。
  - 文件快速预览器：采用无边框透明 `NSPanel`（`.borderless` / `.nonactivatingPanel`）替代 `NSPopover`，完全去除默认箭头与外边距瑕疵，右边缘紧贴文件目录树左界（留 6pt 缝隙）且垂直中心精确对齐选中行；显示内容极简紧凑（无文件名/尺寸栏与黑边），根据图片真实宽高比自适应充满卡片；动画设置为 `animates = false` 实现零延迟秒开秒切。多选、切换标签或选中非媒体文件时自动隐藏。
- 新增独立图片处理功能模块 `kero/ImageBuild/`（Image Build）：
  - **尺寸调整**：保持原尺寸 / 百分比 / 指定宽高（可锁定比例）/ 最长边限制；Core Graphics 高质量缩放。
  - **格式转换**（目标四格式）：
    - **PNG** → ImageIO 写出 + `oxipng`（可选 `pngquant`）
    - **JPG** → `cjpegli`（失败回退 ImageIO）
    - **WebP** → `VendorBin/cwebp`（自包含）；同目录另有 `dwebp` / `img2webp` / `webpinfo` / `webp_quality`
    - **JXL** → `VendorBin/cjxl` / `djxl` / `jxlinfo`（从 [libjxl](https://github.com/libjxl/libjxl) `v0.12.0` 静态编译，仅链系统库；`scripts/vendor-jxl.sh` 可复现构建；macOS ImageIO 不能写 JXL）
  - 工具定位：`VendorBin` Bundle → 源码 `kero/VendorBin` → Homebrew → `which`。
  - 图片查看器顶栏 / 右键 **Image Build…**（资源图标 `ImageBuild`）打开处理面板；Files 树多选图片右键亦可进入。
- 优化 Project 面板 Header 与路径栏：Project Name 与 Project Description 输入框根据当前内容文本/占位符长度自适应调节宽度，聚焦/hover 背景与边框高亮框不再充满整行；路径右侧操作按钮统一使用 `SidebarIconButton`，支持 hover 态高亮与 Tooltip 提示，并在 Finder / Copy Path 左侧新增「在终端中打开」按钮（`terminal`），点击即可在当前项目/路径下建立并切换至新终端 Session。
- 设置 Terminal → Features 新增 **Use Option as Alt/Meta** 开关：默认保留 macOS 文本输入行为，按需将 Option 组合键发送为终端 Meta 快捷键；配置写入 `terminal.macos-option-as-alt`。
- 后台终端在停止 GPU surface 合成的基础上进一步压缩隐藏渲染目标，回到前台时自动恢复，降低多 Tab / 多分栏的 GPU 内存占用；内置 `libghostty-spm` 更新至 `1.3.3`。
- 图片查看器会监听已打开图片的磁盘变更；图片被外部工具覆盖或重新生成后，预览自动刷新，无需关闭标签重新打开。
- 设置 General → Appearance 新增 **Sidebar font size**：按统一层级同比缩放左、右侧栏及顶栏 Tabs 的文字、图标和行高，并适配当前 `SidebarTypography` 架构；配置写入 `sidebar.font-size`。
- 优化设置窗口为系统设置风格的左侧分类布局与一体化标题栏；窗口外框和 SwiftUI 根视图使用同一固定尺寸，消除右侧内容区底部多出的标题栏高度空白；左侧底部增加应用信息卡片，版本号可点击检查更新，地球按钮可打开 Qjiao GitHub。
- Git 面板改为事件驱动刷新：终端命令结束、应用重新激活、切换项目 / CWD / Session、Git 操作完成或手动刷新时更新状态；常规定时器不再每 2 秒执行 Git 命令，并合并刷新期间的重复请求。
- 优化 Project 面板 Launchers 启动器：
  - **Finder 启动项**：路径解析支持相对路径（如 `./`、`.` 或相对子目录）、波浪号路径（`~/`）与绝对路径，运行或选择文件夹弹窗（Choose…）时默认以项目根目录为基准定位。
  - **Webpage 启动项**：支持实时响应 URL 文本修改，在输入框地址变更时智能清理旧图标并即时重新获取加载新网址的 Favicon；当默认 `/favicon.ico` 不存在时，自动拉取网页 HTML 前 300 字符解析 `<link rel="shortcut icon"` 或 `<link rel="icon"` 标签的 `href` 路径并二次请求。
- **macOS 访达右键服务 (Finder Context Menu)**：在 `Info.plist` 中注册系统级 `NSServices`，并在 `FinderService.swift` 中响应 `openInQjiao` 服务请求；在 Finder 中选中一个或多个文件夹右键点击“服务 -> Open in Qjiao”（在 Qjiao 中打开），即可自动拉起应用并将所选文件夹批量建立为新项目、启动对应目录的终端 Session。
- **优化 AI 生成 Commit Message 功能**：通过 `git status --porcelain=v1` 严谨隔离 Git 变更上下文。已暂存 (Staged) 存在时，仅提取已暂存变更；已暂存为空时，才提取工作区已变更 (Unstaged diff) 与未跟踪文件 (Untracked paths)，确保生成的 Commit Message 准确反映本次提交的目标上下文。
- **Files 面板空白区域右键菜单与手动完全刷新**：文件树（Files / CWD）**顶部根文件夹名/路径 Header 与文件树空白区域**右键共用同一套菜单，提供「刷新（Refresh）」「新建文件… / 新建文件夹…」（在项目根创建）、「全选」「粘贴」（剪贴板含文件 URL 时显示）及「在 Finder 中显示 / 在终端中打开」；文件/文件夹行内右键仍保持原有的文件操作菜单（打开、重命名、废纸篓、Run、Image Build 等）。刷新执行 `forceReload`：清空全部目录内容缓存并丢弃在飞扫描，强制所有已展开目录重新后台扫描——覆盖目录 mtime 指纹只能感知「子项增删」、已有文件大小/日期变化不触发自动重扫的缓存盲区，手动一键回到全量新鲜状态，扫描期间各目录显示行内 loading 占位。

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
