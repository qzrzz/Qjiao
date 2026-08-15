# Qjiao 本地发布流程

Qjiao 完全在本机编译、签名、公证和打包。GitHub 只用于托管 Release
资产，不运行 GitHub Actions：

```text
本机 Xcode-beta
  → arm64 Release 构建与 Developer ID 签名
  → Apple 公证并装订票据
  → 生成 DMG、Sparkle ZIP 与 appcast
  → 本机 gh 上传 GitHub Release
```

新用户从 GitHub Release 下载公证后的 DMG。已安装用户通过 Sparkle
读取以下稳定地址：

```text
https://github.com/qzrzz/Qjiao/releases/latest/download/appcast.xml
```

每个 Release 至少包含四项基础资产：

- `qjiao-<version>.dmg`：用户下载和拖入 Applications。
- `qjiao-<version>.zip`：Sparkle 安装的完整更新。
- `qjiao-<version>.md`：应用内更新说明。
- `appcast.xml`：保留历史项目的 Sparkle 更新源。
- `qjiao-<version>_from_<build>.delta`：从缓存旧版本升级时使用的
  Sparkle 差分更新；有可用基线时才生成。

## 一次性本机配置

### 1. 安装本地工具

```sh
brew install bun gh create-dmg
gh auth login
gh auth status
```

发布脚本默认使用：

```text
/Applications/Xcode-beta.app/Contents/Developer
```

如需临时指定其他 Xcode，可设置 `DEVELOPER_DIR`。

### 2. 配置 Developer ID 签名

在 Xcode 或“钥匙串访问”中确认本机登录钥匙串已经安装带私钥的
`Developer ID Application` 证书：

```sh
security find-identity -v -p codesigning
```

将 Apple Developer 的 10 位 Team ID 写入
`scripts/ExportOptions.plist`：

```xml
<key>teamID</key>
<string>YOUR_TEAM_ID</string>
```

把 `YOUR_TEAM_ID` 替换为真实值。也可以不修改文件，在发布时设置
`APPLE_TEAM_ID` 环境变量。

### 3. 配置本地 Apple 公证

如果本机已经设置以下环境变量，发布脚本可以直接使用：

```sh
export APPLE_ID="your@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="<Apple 专用密码>"
export APPLE_TEAM_ID="<TEAM_ID>"
```

环境变量未设置时，则在本机钥匙串创建名为 `NOTARY` 的公证 profile：

```sh
xcrun notarytool store-credentials NOTARY \
  --apple-id "your@example.com" \
  --team-id "YOUR_TEAM_ID"
```

命令会提示输入 Apple 专用密码。使用 profile 时，凭据只保存在本机
钥匙串，不进入仓库或 GitHub。

如果希望使用 App Store Connect API Key，也可在发布时设置：

```text
APPLE_API_KEY_PATH
APPLE_API_KEY_ID
APPLE_API_ISSUER
```

三项同时存在时，脚本会优先使用 API Key。

### 4. 生成 Qjiao 的 Sparkle 密钥

先构建一次项目，让 Xcode 下载 Sparkle 工具。工具通常位于：

```text
~/Library/Developer/Xcode/DerivedData/
  Qjiao-*/SourcePackages/artifacts/sparkle/Sparkle/bin/
```

执行其中的 `generate_keys`：

```sh
SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/\
Qjiao-ctsuftcvzozzlkgyjknjbvamfnsl/SourcePackages/\
artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_keys" --account qjiao
```

该命令会把私钥保存在本机登录钥匙串，并输出公钥。把输出的公钥替换
到 `kero/Info.plist`：

```xml
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_QJIAO_SPARKLE_PUBLIC_KEY</string>
```

可用下面的命令确认占位符已经替换：

```sh
plutil -extract SUPublicEDKey raw kero/Info.plist
```

发布脚本会在开始 Xcode archive 之前检查公钥，未配置时立即退出。

务必备份私钥：

```sh
"$SPARKLE_BIN/generate_keys" \
  --account qjiao \
  -x qjiao-sparkle-private-key
```

备份文件不可提交。丢失私钥后，已经安装的 Qjiao 将无法验证更新。

发布脚本默认直接从登录钥匙串读取私钥。仅在需要使用备份文件时设置：

```sh
SPARKLE_PRIVATE_KEY_FILE="/path/to/qjiao-sparkle-private-key"
```

## 发布一个版本

### 1. 更新版本与说明

在 Qjiao target 的 Debug 与 Release 配置中同步更新：

- `MARKETING_VERSION`：用户看到的版本，例如 `0.2.0`。
- `CURRENT_PROJECT_VERSION`：严格递增的构建号。

然后在 `CHANGELOG.md` 顶部新增匹配的版本说明：

```md
## [0.2.0]

- 本次更新内容
```

### 2. 提交并推送代码

```sh
git add \
  Qjiao.xcodeproj/project.pbxproj \
  CHANGELOG.md
git commit -m "chore(release): 发布 0.2.0"
git push origin main
```

发布时工作区必须保持干净，确保标签准确指向已经提交的发布源码。

### 3. 在本机编译并上传

```sh
bun run release
```

一个命令会依次完成：

1. 使用 Qjiao Release Scheme 创建纯 arm64 archive。
2. 导出 Developer ID 签名的 `Qjiao.app`。
3. 删除 Sparkle 和内置工具中残留的 Intel 切片，给全部 Mach-O
   补充 Hardened Runtime、secure timestamp 和 Developer ID
   签名，再按由内到外的顺序签名并验证 App。
4. 生成、签名并验证 `qjiao-<version>.dmg`。
5. 提交 Apple 公证，并给 DMG 和 App 装订票据。
6. 生成 Sparkle ZIP 与版本更新说明。
7. 从本机 `release/` 读取最多三个旧版 ZIP，生成并签名 Sparkle
   delta，再追加当前版本到本地 appcast。
8. 自动创建并推送 `v<MARKETING_VERSION>` Git 标签。
9. 使用本机 `gh` 创建 GitHub Release，上传基础资产和 delta。
10. 正式发布验证成功后，将当前 ZIP、appcast 和 SHA-256 清单原子保存
    到 `release/`，并淘汰最旧缓存。
11. 写入 `web/download.json` 与 `docs/download.json`（并同步旧版
    `docs/latest.json`），包含应用名、版本号、构建号、发布时间、DMG/ZIP 直链及文件大小与 SHA-256 校验和，提交并推送供官网直链最新安装包。

Apple 返回 `Invalid` 时，脚本会立即调用 `notarytool log` 输出具体
文件和原因，并停止执行，不会继续 staple。

如果同名标签已指向当前提交，脚本会直接复用；默认允许重复发布同一
版本并把本地、远端标签移动到当前提交，`FORCE=0` 可以禁止覆盖。

发布完成后检查：

- `https://github.com/qzrzz/Qjiao/releases/latest` 有四项基础资产，
  有旧版本基线时还包含 `.delta`。
- `web/download.json` 与 `docs/download.json` 的 `dmg.url` 指向当前版本公证 DMG，且包含对应的 SHA-256 与字节大小。
- DMG 能通过 Gatekeeper 并正常启动。
- 使用旧版 Qjiao 执行 **Check for Updates…** 能看到新版本。

## 本地试打包

只生成签名、公证后的资产，不创建 GitHub Release：

```sh
PUBLISH=0 bun run release
```

产物位于 `build/`。此模式不需要 `git` 或 `gh`，不会创建标签，也
不会读取或修改 GitHub，也不会写入 `docs/download.json`；未正式发布
的 ZIP 不会进入 `release/` 缓存。

## 中断后继续发布

脚本默认把成功步骤写入 `build/release-state.json`。再次执行
`bun run release` 时，会核对以下发布身份：

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`
- Release configuration
- `kero/` 与 `Qjiao.xcodeproj` 的 Git tree 指纹
- `CHANGELOG.md` 内容指纹
- 当前 Git commit

版本、构建号或 Release configuration 改变时完整重建。App 源码指纹
改变时从 archive 重建；CHANGELOG 改变时只重新生成更新产物；仅 Web、
文档或其他不参与 App 构建的 commit 改变时，保留 App、DMG 和公证
结果，只刷新 Git 标签与 GitHub Release。

脚本仍会重新验证对应文件的版本、arm64 架构、代码签名、公证票据或
远端资产，验证通过才跳过。可恢复的步骤包括：

1. Xcode archive。
2. Developer ID App export。
3. arm64 架构裁切与嵌套代码签名。
4. DMG 创建。
5. DMG secure timestamp 签名。
6. Apple 公证与票据装订。
7. Sparkle ZIP、版本说明与 appcast。
8. Git 标签和 GitHub Release。

例如公证连接超时后，直接重新执行：

```sh
bun run release
```

脚本会复用已经验证的 App 和 DMG，从 Apple 公证继续。状态只在整个
步骤成功并通过验证后写入，因此失败中的步骤一定会重新执行。

如果 DMG 已创建，但 Apple timestamp 服务不可用，下一次执行只会
验证并复用该 DMG，然后重新请求 secure timestamp，不会重新创建
磁盘映像。单次执行默认会对 Xcode 归档中的瞬时 CodeSign 失败和 DMG
timestamp 签名各重试 3 次；归档重试会保留 DerivedData，复用已经完成的编译。
GitHub Release 的基础资产及差分包会逐个上传，日志显示当前文件、
大小、序号和等待时长。GitHub CLI 本身不提供准确的字节上传百分比。
全部上传完成后，脚本会显式退出 Draft 状态，并在写入发布断点前复验
正式发布状态。

生成 Sparkle 更新时，脚本只读取本机 `release/`，不从 GitHub 下载
旧 appcast 或 ZIP。缓存保留最近三个成功发布版本，以 build、文件大小
和 SHA-256 校验；`generate_appcast` 最多生成三个 delta，并将它们与
完整 ZIP 一起上传。发布成功后才更新缓存，缓存损坏、丢失或没有对应
旧版本时，Sparkle 会安全回退下载完整 ZIP。

由于 GitHub 按 tag 分目录托管 Release 资产，脚本只让
`generate_appcast` 新增当前 build，并在生成前按缓存清单复原历史
版本的 ZIP URL；历史条目不会被改写到当前 tag。产物复验只要求当前
tag 新生成的 delta 位于 `build/updates`，历史 delta 继续使用原 Release。

已成功发布的 `CURRENT_PROJECT_VERSION` 是不可变 delta 基线。即使只是
重新签名或覆盖同一营销版本，也必须先递增 build；脚本检测到
当前 build 不大于本地缓存最大 build 时会在任何编译、生成和
上传前终止；build 必须是正整数。

```text
release/
├── appcast.xml
├── manifest.json
└── archives/
    ├── qjiao-1.0.3.zip
    ├── qjiao-1.0.4.zip
    └── qjiao-1.0.5.zip
```

`release/` 已由 `.gitignore` 排除。换机或清空此目录后不会自动联网
恢复历史，需要重新积累成功发布的版本。

升级到断点脚本前没有状态文件时，脚本允许接管版本号和构建号完全
匹配、App 签名有效且磁盘映像完整的现有产物。后续运行同时要求 Git
tree 指纹一致；普通 Web 或文档 commit 不会触发 App 重编译。

需要忽略全部断点并完整重建时：

```sh
RESET_RELEASE=1 bun run release
```

`REUSE_BUILD=1` 仍可显式要求复用已有的 `build/export/Qjiao.app`；
脚本会重新裁切和签名该 App，不会在验证失败时回退到 Xcode archive。

## 发布选项

| 环境变量                      | 默认值                     | 用途                   |
| ----------------------------- | -------------------------- | ---------------------- |
| `APPLE_TEAM_ID`               | `ExportOptions.plist`      | 临时覆盖 Team ID       |
| `NOTARY_PROFILE`              | `NOTARY`                   | 本机公证凭据名称       |
| `SIGN_IDENTITY`               | `Developer ID Application` | 签名证书               |
| `MACOS_SIGNING_IDENTITY`      | `Developer ID Application` | 签名证书兼容变量名     |
| `APPLE_ID`                    | —                          | Apple 公证账号         |
| `APPLE_APP_SPECIFIC_PASSWORD` | —                          | Apple 公证专用密码     |
| `SPARKLE_PRIVATE_KEY_FILE`    | 登录钥匙串                 | Sparkle 私钥备份       |
| `SPARKLE_ACCOUNT`             | `qjiao`                    | Sparkle 钥匙串账户     |
| `GITHUB_REPOSITORY`           | `qzrzz/Qjiao`              | 上传目标仓库           |
| `RELEASE_CACHE_DIR`           | `release`                  | 本地 Sparkle 历史目录  |
| `PUBLISH=0`                   | —                          | 只生成本地产物         |
| `FORCE=0`                     | `1`                        | 禁止覆盖同版本发布     |
| `NO_HISTORY=1`                | —                          | 不读取本地更新历史     |
| `REUSE_BUILD=1`               | —                          | 复用已导出的 Qjiao.app |
| `RESET_RELEASE=1`             | —                          | 清除断点并完整重建     |
| `ARCHIVE_RETRIES`             | `3`                        | 归档签名失败尝试次数   |
| `TIMESTAMP_RETRIES`           | `3`                        | 时间戳签名尝试次数     |

默认允许用当前提交重复发布相同版本：

```sh
REUSE_BUILD=1 bun run release
```

脚本会将同名本地和远端标签移动到当前提交，并覆盖该 GitHub Release
的基础资产、差分包与版本说明；不会删除其他标签或 Release。需要临时禁止
覆盖时执行：

```sh
FORCE=0 bun run release
```
