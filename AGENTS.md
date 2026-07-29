## 重要的事

- 我是中文用户
- [**readme.md**](./readme.md) - 项目的说明文档，文件结构、技术架构、包管理工具、构建工具等在此文档中有详细说明）。
- `~/agent/code-style.md` - 代码风格和质量规范。编写代码需要遵守这些规范。
- 这是一个 monorepo 项目，使用 `bun` 作为包管理工具，
- TypeScript 是主要语言，注意使用的是 TypeScript 6。

- 这是一个 Fork From Kero (v0.1.19) 的二次开发项目，如果有改动要添加到 readme.md 的 「## 增加功能」中
- Kero 的原仓库是：https://github.com/egoist/kero.git 本项目是独立仓库，移植功能时不移植上游 git 记录。
- 如果进行来自上游的功能移植，记录上游最后的版本，以便下次移植时知道从哪来开始

- 当前环境使用的是 Xcode 是 beta 版， Xcode-beta.app
- 界面中的数字要注意使用 monospacedDigit 字体

## I18n

- 用户可见文案必须走 `L10n.t("English source")`；带参数用 `L10n.format("… %@ …", arg)`
- **英文为 key**（源语言/默认）；中文补在 `kero/L10n/zh-Hans.swift`，缺 key 回退英文
- 新增语言：`AppLanguage` case + `kero/L10n/<locale>.swift` 词表 + `L10n.t` 的 `switch`
- 需要随语言切换刷新的 View：观察 `L10n.shared`（读 `l10n.language`）
- 主题名、品牌名、预览样本文案可不译

- 术语不翻译：
  - Image Build
  - 
