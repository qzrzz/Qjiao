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

每个 Release 包含四项资产：

- `qjiao-<version>.dmg`：用户下载和拖入 Applications。
- `qjiao-<version>.zip`：Sparkle 安装的完整更新。
- `qjiao-<version>.md`：应用内更新说明。
- `appcast.xml`：保留历史项目的 Sparkle 更新源。

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
7. 下载上一版 `appcast.xml` 并追加当前版本。
8. 自动创建并推送 `v<MARKETING_VERSION>` Git 标签。
9. 使用本机 `gh` 创建 GitHub Release 并上传四项资产。

Apple 返回 `Invalid` 时，脚本会立即调用 `notarytool log` 输出具体
文件和原因，并停止执行，不会继续 staple。

如果同名本地标签已经指向当前提交，脚本会直接复用并推送；如果标签
指向其他提交，则立即终止，不会移动或覆盖已有标签。

发布完成后检查：

- `https://github.com/qzrzz/Qjiao/releases/latest` 有四项资产。
- DMG 能通过 Gatekeeper 并正常启动。
- 使用旧版 Qjiao 执行 **Check for Updates…** 能看到新版本。

## 本地试打包

只生成签名、公证后的资产，不创建 GitHub Release：

```sh
PUBLISH=0 bun run release
```

产物位于 `build/`。此模式不需要 `git` 或 `gh`，不会创建标签，也
不会读取或修改 GitHub。

## 复用已有构建重试

如果编译和导出已经成功，只是在后续签名、公证、Sparkle 或上传阶段
失败，可复用 `build/export/Qjiao.app`，避免再次执行 Xcode archive：

```sh
REUSE_BUILD=1 bun run release
```

脚本仍会重新签署 App 内所有可执行代码、重建并签署 DMG、重新公证，
不会复用失败的 DMG。已有 Universal App 会在此阶段裁成纯 arm64。
只有确认现有导出 App 对应当前发布源码和版本时才能使用此选项。

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
| `PUBLISH=0`                   | —                          | 只生成本地产物         |
| `FORCE=0`                     | `1`                        | 禁止覆盖同版本发布     |
| `NO_HISTORY=1`                | —                          | 不继承旧 appcast       |
| `REUSE_BUILD=1`               | —                          | 复用已导出的 Qjiao.app |

默认允许用当前提交重复发布相同版本：

```sh
REUSE_BUILD=1 bun run release
```

脚本会将同名本地和远端标签移动到当前提交，并覆盖该 GitHub Release
的四项资产与版本说明；不会删除其他标签或 Release。需要临时禁止
覆盖时执行：

```sh
FORCE=0 bun run release
```
