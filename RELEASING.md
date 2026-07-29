# Qjiao 本地发布流程

Qjiao 完全在本机编译、签名、公证和打包。GitHub 只用于托管 Release
资产，不运行 GitHub Actions：

```text
本机 Xcode-beta
  → Developer ID 签名
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

在本机钥匙串创建名为 `NOTARY` 的公证 profile：

```sh
xcrun notarytool store-credentials NOTARY \
  --apple-id "your@example.com" \
  --team-id "YOUR_TEAM_ID"
```

命令会提示输入 Apple 专用密码。凭据只保存在本机钥匙串，不进入
仓库或 GitHub。

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
SPARKLE_BIN="/path/to/Sparkle/bin"
"$SPARKLE_BIN/generate_keys"
```

该命令会把私钥保存在本机登录钥匙串，并输出公钥。把输出的公钥替换
到 `kero/Info.plist`：

```xml
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_QJIAO_SPARKLE_PUBLIC_KEY</string>
```

务必备份私钥：

```sh
"$SPARKLE_BIN/generate_keys" \
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

### 2. 提交并推送版本标签

```sh
git add \
  Qjiao.xcodeproj/project.pbxproj \
  CHANGELOG.md
git commit -m "chore(release): 发布 0.2.0"
git tag v0.2.0
git push origin main v0.2.0
```

标签必须严格等于 `v<MARKETING_VERSION>`。发布脚本调用
`gh release create --verify-tag`，不会为不存在的远程标签创建 Release。

### 3. 在本机编译并上传

```sh
bun run release
```

一个命令会依次完成：

1. 使用 Qjiao Release Scheme 创建 archive。
2. 导出 Developer ID 签名的 `Qjiao.app`。
3. 生成并签名 `qjiao-<version>.dmg`。
4. 提交 Apple 公证，并给 DMG 和 App 装订票据。
5. 生成 Sparkle ZIP 与版本更新说明。
6. 下载上一版 `appcast.xml` 并追加当前版本。
7. 使用本机 `gh` 创建 GitHub Release 并上传四项资产。

发布完成后检查：

- `https://github.com/qzrzz/Qjiao/releases/latest` 有四项资产。
- DMG 能通过 Gatekeeper 并正常启动。
- 使用旧版 Qjiao 执行 **Check for Updates…** 能看到新版本。

## 本地试打包

只生成签名、公证后的资产，不创建 GitHub Release：

```sh
PUBLISH=0 bun run release
```

产物位于 `build/`。此模式不需要 `gh`，也不会读取或修改 GitHub。

## 发布选项

| 环境变量                   | 默认值                     | 用途                    |
| -------------------------- | -------------------------- | ----------------------- |
| `APPLE_TEAM_ID`            | `ExportOptions.plist`      | 临时覆盖 Team ID        |
| `NOTARY_PROFILE`           | `NOTARY`                   | 本机公证凭据名称        |
| `SIGN_IDENTITY`            | `Developer ID Application` | 签名证书                |
| `SPARKLE_PRIVATE_KEY_FILE` | 登录钥匙串                 | Sparkle 私钥备份        |
| `GITHUB_REPOSITORY`        | `qzrzz/Qjiao`              | 上传目标仓库            |
| `PUBLISH=0`                | —                          | 只生成本地产物          |
| `FORCE=1`                  | —                          | 覆盖同标签 Release 资产 |
| `NO_HISTORY=1`             | —                          | 不继承旧 appcast        |

默认禁止覆盖同名 Release。`FORCE=1` 只替换该 Release 的四项资产；
不会删除标签或其他 Release。
