# Terminal App Icons

终端前台进程图标：当 Tab 里的 shell 正在运行某个可识别程序时，标签图标切换为对应应用图标。

## 配置

- **内置**：`apps.json` + `icons/*`（随应用打包，支持 `.png` / `.svg` 等）
- **用户覆盖**（可选，重启后生效）：
  - `~/.config/qjiao/terminal-app-icons.json`（Debug 构建为 `qjiao-dev`）
  - `~/.config/qjiao/terminal-app-icons/*`（自定义图标文件）

用户配置中的条目按 `match` / `matchPrefix` **优先**于内置；同名图标文件用户侧优先。

### `apps.json` 条目

```json
{
  "label": "Agy",
  "match": ["agy"],
  "matchPrefix": ["agy-"],
  "icon": "antigravity-color.png"
}
```

```json
{
  "label": "Rsbuild",
  "match": ["rsbuild", "@rsbuild"],
  "icon": "rsbuild.svg"
}
```

```json
{
  "label": "Node.js",
  "match": ["node", "nodejs"],
  "material": "nodejs"
}
```

字段说明：

| 字段 | 说明 |
|------|------|
| `match` | 进程可执行文件名（basename）精确匹配，大小写不敏感 |
| `matchPrefix` | 前缀匹配（如 `python3.` 匹配 `python3.12`，`grok-` 匹配版本化二进制） |
| `icon` | **推荐**。`icons/` 下的文件名，如 `antigravity-color.png`、`rsbuild.svg` |
| `svg` | 兼容旧字段，等同于 `icon` |
| `iconify` | Iconify 名，`prefix:name`（如 `bxl:openai`），解析为 `icons/{prefix}-{name}.svg` |
| `material` | Material Icon Theme 逻辑名（见 `MaterialIcons/`） |
| `label` | 仅文档/调试用，不参与匹配 |

图标来源优先级：`icon` / `svg` > `iconify` > `material`。

文件名勿与 `MaterialIcons/icons/` 重名（打包后会摊平到 Resources）；自定义文件可用前缀如 `app-vitest.svg`。

另：真实路径常为版本化名（如 `grok-0.2.112-macos-aarch64`）。匹配时会自动取 `-` 前第一段（`grok`）再查 `match` 表。

Node/Python 等解释器会读取 argv，并枚举前台**进程组**内全部 PID：例如 `npm run dev` → 子进程 `node …/rsbuild` 会按 `rsbuild` 匹配。

## 添加自定义图标

1. 把 `my-app.png`（或 `.svg`）放进 `kero/TerminalAppIcons/icons/`
2. 在 `apps.json` 增加：

```json
{
  "label": "My App",
  "match": ["my-app", "myapp"],
  "icon": "my-app.png"
}
```

3. 重新编译运行

用户目录同样可以只放 JSON + 图标文件，无需改代码。

## 更新 Iconify 资源

```bash
bun run vendor:terminal-app-icons
# 或
bun run scripts/vendor-terminal-app-icons.ts --icons bxl:docker,bxl:github
```

Boxicons Brands 集合前缀为 `bxl`：https://icon-sets.iconify.design/bxl/

## 性能

- 仅在终端前台存在子进程时解析
- 按进程组枚举成员（`KERN_PROC_PGRP`），读取 argv 提取 CLI 名
- 强命中（具体 CLI）缓存约 2s；仅 node 等弱命中约 0.25s 重试
- 图标 NSImage 按「路径 + 点尺寸」缓存
- Tab 条沿用已有 0.3s `TimelineView`，无额外全局轮询
