# Terminal App Icons

终端前台进程图标：当 Tab 里的 shell 正在运行某个可识别程序时，标签图标切换为对应应用图标。

## 配置

- **内置**：`apps.json` + `icons/*.svg`（随应用打包）
- **用户覆盖**（可选，重启后生效）：
  - `~/.config/qjiao/terminal-app-icons.json`（Debug 构建为 `qjiao-dev`）
  - `~/.config/qjiao/terminal-app-icons/*.svg`

用户配置中的条目按 `match` / `matchPrefix` **优先**于内置；同名 `svg` 文件用户侧优先。

### `apps.json` 条目

```json
{
  "label": "Codex",
  "match": ["codex"],
  "matchPrefix": ["codex-"],
  "material": "claude",
  "iconify": "bxl:openai",
  "svg": "my-app.svg"
}
```

字段说明：

| 字段 | 说明 |
|------|------|
| `match` | 进程可执行文件名（basename）精确匹配，大小写不敏感 |
| `matchPrefix` | 前缀匹配（如 `python3.` 匹配 `python3.12`，`grok-` 匹配版本化二进制） |

另：真实路径常为版本化名（如 `grok-0.2.112-macos-aarch64`）。匹配时会自动取 `-` 前第一段（`grok`）再查 `match` 表，无需为每个版本单独配置。
| `material` | Material Icon Theme 逻辑名（见 `MaterialIcons/`） |
| `iconify` | Iconify 名，`prefix:name`（如 `bxl:openai`），解析为 `icons/{prefix}-{name}.svg` |
| `svg` | `icons/` 下的自定义 SVG 文件名 |
| `label` | 仅文档/调试用，不参与匹配 |

图标来源三选一，优先级：`svg` > `iconify` > `material`。

## 更新 Iconify 资源

```bash
bun run scripts/vendor-terminal-app-icons.ts
```

脚本读取 `apps.json` 中的 `iconify` 字段，从 [Iconify API](https://api.iconify.design/) 下载 SVG 到 `icons/`。

也可手动指定：

```bash
bun run scripts/vendor-terminal-app-icons.ts --icons bxl:docker,bxl:github
```

Boxicons Brands 集合前缀为 `bxl`：https://icon-sets.iconify.design/bxl/

## 性能

- 仅在终端前台存在子进程时解析 PID
- 同一 `foregroundPid` 缓存进程名与图标结果，切换进程才重新 `proc_pidpath`
- 图标 NSImage 按「来源 + 点尺寸」缓存，与文件树 Material 图标策略一致
- Tab 条沿用已有 0.3s `TimelineView`，不额外起全局轮询
