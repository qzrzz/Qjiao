# Changelog

All notable changes to Qjiao. This file is the **source of truth for the release
notes shown in the in-app updater**: [`scripts/release.ts`](scripts/release.ts)
extracts the section whose heading matches the version being released
(`MARKETING_VERSION`) and publishes it next to the update, so Sparkle shows it in
the update prompt.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.


## [1.1.54]

### Added

- Add a "Wrap" tabs layout mode: tabs keep their natural width and flow onto up to 3 rows (min 240pt, evenly filling the container), with vertical scrolling and edge fades when overflowing; switch layouts via right-click on the empty tab strip area.
- Add file auto-save (aligned with VS Code `files.autoSave`): off, after a delay, on editor focus change, or on window focus change, with a configurable delay (default 1000ms); configure in Settings → Editor or the File menu "Auto Save" toggle.
- Add a Tasks panel to the right sidebar bottom section for running npm scripts and Gradle / Just / Cargo / CMake / Makefile tasks from the project root, while browsing Files or Git panels.

### Changed

- Unify content-area tab item height to 30pt, matching the wrap layout row metrics.

## [1.1.53]

### Added

- Add a dedicated line-wrapping toggle for Markdown files in the editor status bar, independent of the global source-editor wrap setting (wraps by default).
- Reload files rewritten by external tools into the editor immediately, keeping the editor and Markdown preview in sync.

### Changed

- Always underline links in the Markdown preview, with a hover brightness effect.

### Fixed

- Fix editor and Hex editor scroll bars reverting to the legacy inset style on tab switches and SwiftUI relayouts, and overlay scroller knobs drifting off the trailing/bottom edges: keep the system-preferred overlay scroller style and re-pin knobs to the current bounds after tiling.
- Fix Markdown split panes not filling the available height.

## [1.1.52]

### Added

- Add Markdown image insertion: paste (⌘V) or drag image files into a Markdown editor to write them to a sibling `assets/` folder and insert `![](assets/…)`; sources already inside `./assets` are reused without copying.

### Fixed

- Fix Markdown preview failing to load images and links whose paths contain spaces or special characters: percent-encode each URL path segment, resolve relative paths safely, and support `<url>` / title syntax for images and links.

## [1.1.51]

### Added

- Add Markdown preview: toggle a live split next to the source from the editor status bar, drag the divider, and keep editor/preview scroll aligned by content block rather than pixels.

### Fixed

- Fix a crash when closing a window: SwiftUI could update window chrome while `NSWindow` was deallocating, and forming a weak reference to that window aborted the process.

## [1.1.50]

### Added

- Add "Pull (Rebase)" to the Git panel: when `git pull --ff-only` (including Sync) fails because local and remote branches have diverged, the operation banner offers a rebase pull (`git pull --rebase`), and the more-actions menu exposes it proactively.

## [1.1.49]

### Added

- Serve a direct link to the latest DMG on the official website, backed by a release manifest (`download.json`) that the release script regenerates after each GitHub release.

## [1.1.48]

### Added

- Add "Close Empty Tabs" to the tab context menu to close blank browser tabs and never-used terminal tabs in one go.
- Preserve file tree expansion state and scroll position across refreshes and Files ↔ CWD switches.
- Run npm scripts from the `package.json` context menu in the file tree.

### Fixed

- Fix agent status being misjudged as `done` when the screen capture is empty (e.g. split surface not ready yet): keep the last valid status and default to `working` for known agent processes without a matched rule.
- Fix syntax highlighting missing on first paint by re-rendering highlights once the viewport is ready and precompiling tree-sitter queries in the background, shared across editors.
- Fix the sidebar resize handle hotspot offset misalignment.

## [1.1.47]

### Added

- Add a local automation protocol with `qjiao +pane` / `qjiao +agent` CLI commands to query, split, read, and write terminal panes, launch agents, wait for their status, and send guarded prompts to running, unblocked agents.

### Changed

- Replace the spinning refresh icon with a ProgressView in sidebar refresh buttons.
- Align commit history timeline dots with guide lines, auto-fit branch/tag badge widths, and load package manager icons from the icon directory with template rendering preserved.

### Fixed

- Fix GitScanner infinite loop at the filesystem root and a MainActor isolation crash in tab switching.
- Refresh project and terminal icons when the appearance theme changes.

## [1.1.46]

### Fixed

- Fix first commit being wrongly rejected in repositories with no commits yet: read the branch name via `symbolic-ref --short HEAD` (aligned with porcelain `branch.head`) so the HEAD stability check no longer misreports "Branch or HEAD changed" on unborn branches.

## [1.1.44]

### Changed

- Increase the default file list font size from 13 to 14 for better readability.

## [1.1.43]

### Performance

- Tier Git refreshes by event source: file events, terminal command completion, cd, and tab switches now run a fast path (rev-parse + status only), while commit history, branches, remotes, and stash details are fetched on HEAD/refs changes, on-demand expansion of commit history, or the low-frequency heartbeat, keeping previous details on screen without flicker.
- Skip duplicate full scans between the 10s timer and the internal heartbeat when the repository root is unchanged, and omit detail commands from refreshes triggered while the Git panel isn't visible.

## [1.1.42]

### Added

- Press ⌘R to re-run the terminal spawned by a script or task (right sidebar tasks, npm scripts, Script Runner single-file scripts) in place, preserving the original pane and split layout.
- Use a single multi-line editor for commit messages: the first line is the subject, following lines form the body, with the history refreshed immediately after commit/amend.

### Changed

- Show the tab close button only when hovering the active tab, and keep split indicator spacing consistent.
- Right-align reference badges in the Git panel with a fixed slot width.

## [1.1.38]


### Fixed 

- Fix fd leaks.


### Added

- Significantly accelerate AI-generated Git commit messages.


## [1.1.36]

### Added

- Support terminal links to local files: ⌘-click to reveal in Finder, ⌘-right-click to open in a new file tab or split pane.
- Support expanding file changes in Git commit history with paginated loading.
- Add progress indicators for Git operations (fetch, pull, push, branch switch) and default branch auto-detection.
- Add multi-language (Chinese & Japanese) support for Git operation status and notifications.

### Fixed

- Fix process stdin pipe handle leaks and ensure PTY jobs are properly terminated upon session release.

## [1.1.33]

### Added

- Add GitHub Desktop-style simple Git operation mode with checkbox-based commit flow, toggleable in settings.
- Support generating AI commit suggestions for selected file paths (checking files in simple mode filters the diff).
- Save AI provider configurations independently per API vendor.
- Add Image Build export naming modes (`Suffix` / `File Name`) with a preset 10-size macOS icon template set.

## [1.1.31]

### Added

- Add event-driven Git file watcher (`GitFileWatcher`) with stale-while-revalidate status refresh.
- Preserve terminal split-pane layout when re-running project tasks.
- Support native directory creation in New Project dialog.

### Changed

- Adopt unified `SubprocessRunner` for process lifecycle management and leak prevention.
- Optimize Retina icon crispness in settings and empty state views.

### Fixed

- Fix Git fsmonitor socket crashes and `Bad file descriptor` errors.

## [1.1.25]

### Added

- Support dragging session tabs directly into content view pane edges to create split-pane layouts while preserving active session state.
- Add Windows 7 and Windows XP retro sound effect schemes, configurable in `Settings → General → Sound Effects`.

### Changed

- Restrict terminal completion sound alerts to UI-initiated background tasks and Agent status updates (`working` → `done`), removing audio notifications from standard interactive shell execution.
- Adjust Git panel primary action button and toolbar control dimensions to a uniform 28pt height for better visual alignment.

### Fixed

- Remove project directory path restrictions for custom Git executables and fix `customGitPath` state persistence during project configuration saves.
- Fix notification badge and sound trigger handling when Coding Agent transitions from `blocked` to `done` state.

## [1.1.21]

### Added

- Add native Hex Editor for binary files with dual Hex/ASCII editing modes, text and hex search/replace with wildcard support, offset jump dialog, session persistence, and file tree context menu integration.
- Add in-app sound effects service (`SoundEffects`) using native macOS system sounds for terminal command completion (success/failure exit code via OSC 133;D) and Coding Agent task completion (`working` → `done`), configurable in `Settings → General → Sound Effects`.

### Changed

- Enhance process tree scanning and zsh integration to support custom PTY completion proxies like `ghost-complete`, preserving `ZDOTDIR` and tracking real shell PIDs for background tasks and Agent status.

### Fixed

- Add Git fsmonitor daemon auto-recovery and IPC socket cleanup on Git status retry to resolve stale daemon connection errors.
- Fix potential macOS ViewBridge assertion crashes (`containingWindowWillOrderOnScreen`) by clearing focus on Settings window close and adopting SwiftUI text fields in Hex editor toolbar.

## [1.1.9]

### Added

- Support Coding Agent status monitoring (`working`, `blocked`, `done`) with active process inspection and terminal output detection, featuring unread notifications and badge indicators on tabs, sidebar, and Info panel.
- Add Agent CLI launcher type for configuring and running preset AI CLI prompts directly from Project Launchers.
- Support window dragging across the entire header when no session tabs are open, and Finder folder drop in empty workspace state to open or create projects.
- Display Agent blocked state indicators with priority status management in sidebar rows and session tab labels.

### Changed

- Refine inactive terminal icon colors in tab strips to `Theme.secondaryColor` for better visual contrast across dark and light modes.
- Automatically hide the `NPM SCRIPTS` panel section when `package.json` has no scripts configured.

### Fixed

- Fix tab dimension jitter and overflow animation scope during new tab creation.
- Fix sidebar section header action disabled states for empty script lists.
- Exclude `.zsh_history` from terminal integration directories to prevent corrupting app bundle signatures and release delta packages.

## [1.1.1]

### Added

- Support elastic and scroll layout options for top-bar tabs (`Settings` -> `Tabs Layout`).
- Support smart contrast adaptation for CLI icons by dynamically rendering low-contrast icons as silhouettes based on system theme and background brightness.

### Performance

- Optimize tab switching responsiveness with immediate active tab state updates and lazy-loaded panel contents.

## [1.1.0]

### Added

- Add cloud AI API provider support alongside local CLI AI, with API Key securely stored in macOS Keychain.
- Add network metrics logging for AI API requests to track connection stats and request duration.

### Changed

- Increase default timeout for Local AI Git commit suggestion to 90 seconds.

## [1.0.9]

### Added

- Support custom Git repository path mapping with automatic CLI icon association.

### Fixed

- Render theme previews according to Retina scaling (`backingScaleFactor`) to fix blurry previews on High-DPI displays.

## [1.0.8]

### Added

- Support dark and light variant icons for terminal applications.

### Changed

- Refine zsh shell integration for reliable pending command execution and PTY fallback.

### Performance

- Replace CLI sub-process execution with native Darwin APIs (`host_statistics`, `sysctl`) for system status collection, significantly reducing CPU overhead and pausing polling when backgrounded.
- Optimize Git status scanning and rendering for large repositories with lazy rendering (`LazyVStack`), cached filter results, and VS Code style mixed directory folding.

### Fixed

- Fix ⌘Z undo crash and IME marked text write-back issue in `NotePanel` and `GitCommitMessageEditor` by assigning independent `UndoManager` instances and pausing write-back during composition.

## [1.0.7]

### Added

- Add pi as ai provider.

### Fixed

- Fix startup crash possible.
- Fix zsh integration `builtin cat` error (`no such builtin: cat`) shown on every prompt when an idle title file exists.

## [1.0.5]

### Added

- Projects Add button and menu.
- AI completed change submission

## [1.0.4]

### Fixed

- Fix System Network index.

### Changed

- The source of the project list relies entirely on `~/.config/qjiao/projects/`.
