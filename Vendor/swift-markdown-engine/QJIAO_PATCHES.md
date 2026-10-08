# Why Qjiao vendors swift-markdown-engine

This directory is a **copy of upstream [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) tag `0.14.0`**, with one local feature patch. It is wired into the app as a local Swift package (`XCLocalSwiftPackageReference "Vendor/swift-markdown-engine"` in `Qjiao.xcodeproj`), not as a remote SPM dependency. Only `Sources/`, `Tests/` and the package's own docs are vendored; upstream `Demo/` and `media/` are omitted.

We vendor it for one reason: **to add a feature that upstream has no seam for.** The engine hides Markdown syntax by shrinking markers to a near-zero font (plus a compensating negative kern) whenever the caret is not inside the node, and there is no configuration flag to disable that. SPM has no patch/overlay mechanism for a remote package, so shipping the change means checking the source into the repo and pointing the project at the local copy. Once the feature lands upstream (or upstream grows a "show markers" option), we can delete this directory and go back to a pinned remote dependency.

## The patch

### `revealMarkers` — always show Markdown syntax

Adds `MarkdownEditorConfiguration.revealMarkers: Bool` (default `false`, so upstream behavior is untouched). When `true`, Qjiao keeps the rendered styling (heading sizes, bold/italic, inline code, code blocks, tables, images) but never collapses source markers:

- **`Configuration/MarkdownEditorConfiguration.swift`** — new stored property + init parameter `revealMarkers` (default `false`).
- **`Styling/MarkdownASTStyler.swift`**
  - `shrink(_:)` appends `mutedText` instead of the tiny kerned font, so every marker routed through it (emphasis `**`, link brackets, wiki links, escapes, image markers) stays full size.
  - Heading markers are skipped in `shrinkInactiveMarkers`, so the `#` keep the heading-marker color from the block pass.
  - The link-target hide in `shrinkInlineMarkers` is replaced by a `mutedText` run, so `[text](url)` keeps its `(url)`.
  - Inline-code backticks (`case .code`) use the code font instead of the hidden font.
  - Blockquote `>` markers stay visible (muted) instead of `.clear`.
  - Code-block ```` ``` ```` fences stay visible (muted, code font), as do extension fences.
  - Thematic breaks show the raw `---` / `***` / `___` instead of the drawn rule.
  - `styleListItem`: bullets keep `-` (no `•`), ordered items keep `1.` (no overlay number), task items keep `- [ ]` (no drawn checkbox). The renderer only draws those decorations from the `.bulletMarker` / `.orderedMarker` / `.taskCheckbox` / `.thematicBreak` attributes, so not setting them removes the decoration with the source visible.
  - `Styling/MarkdownStyler+Images.swift`: `![alt](url)` and `![[…]]` images keep their source visible — the token is always treated as active, so the standalone block uses `.visibleSource` (raw line + image below) instead of `.collapsedSource`.

Not changed by design: GFM tables still render as a unit (their source would double up with the rendered block), and LaTeX already shows its source when no renderer is supplied.

### `linksRequireModifierClick` — ⌘/⌃-click to follow a link

Adds `MarkdownEditorConfiguration.linksRequireModifierClick: Bool` (default `false`). When `true`, a plain click on a `[text](url)` label places the caret there (so the link source edits like ordinary text) and only a ⌘- or ⌃-click navigates. The upstream "outer 30 % edge" edit zone is skipped in this mode.

- **`TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift`** — `clickedOnLink` early-returns after placing the caret at the click point when the flag is set and no ⌘/⌃ is held; the edit-zone block is gated on `!linksRequireModifierClick` so a ⌘-click at a link's edge still navigates.

### Front matter renders as a YAML/JSON code block

A leading `---` … `---` front-matter block used to fall apart: the closing `---` after a value line was a paragraph boundary, and `# comment` lines inside it became H1 headings.

- **`Parser/BlockParser.swift`** — when the document's first line is exactly `---` and a later `---` line closes the run before any blank line, the whole region becomes one `.fencedCode` block (`frontMatterCloseIndex(from:)`). The `computeBlocks(_:registry:isDocumentStart:)` default keeps the full-parse path at document start; `incrementalParse` passes `winStart == 0` so a reparse window never claims a mid-document `---` run.
- **`Styling/MarkdownASTStyler.swift`** — `codeBlockParts` now derives the fence character from the block's first non-space char instead of hard-coding backticks, so `---` fences split like ```` ``` ````. A dash fence yields language `json` when the body opens with `{`/`[`, else `yaml`, which routes through the existing `SyntaxHighlighter` for per-token colors on top of the code-block font/background.

`Tests/MarkdownEngineTests/FrontMatterTests.swift` covers recognition, the blank-line guard, the window guard, and the lone-`---` case.
