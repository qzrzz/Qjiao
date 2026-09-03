# Changelog

All notable changes to Qjiao. This file is the **source of truth for the release
notes shown in the in-app updater**: [`scripts/release.ts`](scripts/release.ts)
extracts the section whose heading matches the version being released
(`MARKETING_VERSION`) and publishes it next to the update, so Sparkle shows it in
the update prompt.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.


## [1.1.67]

### Added

- Add a Diagnostics window, opened from Help → Diagnostics…: it shows live metrics (open file descriptors vs. the soft/hard rlimit, active Git / Project / subprocess operations with their elapsed time and warning threshold), a timeline of recorded events, and the past JSON reports, which can be regenerated, copied to the clipboard or revealed in Finder. A low-overhead background monitor samples file descriptors and tracks subprocess lifecycles and Git / Project refresh phases; when the FD count crosses its threshold (300 in Debug, 1500 in release) or keeps growing across samples, a subprocess times out or fails to launch, or a refresh stalls past its warning window, it captures a sanitized JSON snapshot to `~/.config/qjiao/diagnostics` (`qjiao-dev` in Debug), with automatic reports throttled and only the latest 20 kept. The diagnostics path spawns no extra processes and never records command arguments, environment variables or file contents.

### Changed

- Bound every process wait so a wedged repository or volume can no longer stall the UI indefinitely: a subprocess that survives SIGTERM and even SIGKILL on uninterruptible kernel I/O (bad network volumes) is given a finite grace period and reaped by its termination handler instead of an unbounded `waitUntilExit`, and its exit code is only read once the process has truly exited; the `pgrep` helper used to kill process trees is itself time-limited; Git's recovery path no longer re-runs a command that launched successfully but timed out — the `git -C` + fresh-IO fallback only fires when the process failed to launch — and the fsmonitor daemon stop/start repair gets its own short timeout instead of consuming the whole scan budget, with the recovery scan timeout shortened accordingly.
- The Project panel's manual refresh is guarded by a 15-second watchdog: if reading package scripts or processes blocks (e.g. on an unreachable network volume), the refresh state is reset so the refresh button recovers and the user can retry or switch projects.

### Fixed

- Fix a file-descriptor leak when the LocalAI helper process fails to launch: all stdin/stdout/stderr pipe handles (read and write ends) are now closed on launch failure.

## [1.1.66]

### Changed

- Increase the corner radii of Liquid Glass surfaces to a unified, larger set (continuous rounding): main content tabs, the selected sidebar project row, the right sidebar's top panel tab bar (and the active-segment fill inside it), the code editor / AI tool open buttons, the empty-state "New Session" button and the tab rename chrome now share one corner-radius palette (10pt items, 12pt bar, 8pt nested fill, 14pt prominent button), so glass buttons and selected items look softer and consistent across the UI.

## [1.1.65]

### Changed

- Detect AI tools and CLIs in the background: desktop apps are resolved synchronously from bundle IDs, while the login-shell PATH scan and executable lookups run off the main thread and publish their results when ready, so opening the Project panel never blocks on slow shells (`zsh -lc` with nvm, per-command `which` fallbacks); stale background scan results are discarded in favor of newer refreshes, and batch scans no longer spawn a `which` process for every not-installed command.

### Fixed

- Fix occasional crashes when opening the Project panel: CLI probing and process waits no longer pump the runloop on the main thread during SwiftUI layout (which aborted on nested AttributeGraph updates) — the shell-PATH cache serves its last-known result on the main thread instead of re-spawning the login shell, and child-process reaping waits on a background thread.

## [1.1.64]

### Changed

- Use macOS 27 Liquid Glass for the selected state of main content tabs, the selected project row in the left sidebar, the right sidebar's top panel tabs, the empty-state "New Session" button and the code editor / AI tool open buttons: the tint adapts to light/dark mode (white / black at 6%), interactive glass adds click and hover feedback, and the sidebar project row gets a soft drop shadow.
- The selected tab's glass is now drawn outside the tab strip's clipping mask so it can't be cut off, and the dragged tab preview keeps its own glass layer; the dragged-tab chrome no longer paints a translucent fill behind the glass.
- Right sidebar top panel tabs now share a single glass surface with a clean fill for the active segment, and clicking a tab animates the selection highlight immediately while the (potentially heavy) panel content sync follows ~80ms later, so clicks always give instant feedback; stale rapid clicks are discarded in favor of the last selection.
- Right sidebar top tabs auto-truncate their titles in narrow sidebars when the full title (icon, badge and padding) can't fit its segment, so equal-width segments no longer squeeze every title.
- Animate the left sidebar project selection highlight (0.12s) before the content area follows, matching the main tab selection transition.

## [1.1.63]

### Changed

- In the "Wrap" tabs layout, keep the right-side action buttons (sidebar toggle, dropdown, new tab, zoom) in the header toolbar while the tabs fit on a single row; they only move into a vertical column next to the tab strip when the tabs actually wrap onto multiple rows, so a single-row wrap no longer reserves the taller header.

## [1.1.62]

### Added

- Add a "Trim Transparent Pixels" action to the project icon picker: it detects and crops the transparent margins around an imported image, then reports the trimmed size or a specific error (completely transparent image, no transparent margins, etc.).

### Fixed

- Fix the empty state (no session / no project) painting an opaque background that duplicated the global theme: the redundant solid background is removed so the frosted-glass backdrop shows through, and the empty state now displays correctly when no tab is active.

## [1.1.61]

### Added

- Add a "Delete Project" action to the sidebar project context menu and the command palette: it permanently removes the project from the list and deletes its local configuration and notes, after a confirmation dialog (hold ⌘ to skip the confirmation).

### Changed

- "Close Project" no longer deletes the project: it now only closes all of the project's tabs and terminal sessions and keeps the project in the list, while the new "Delete Project" action handles permanent removal; the close confirmation dialog text is updated accordingly.
- Remove the last-run duration label from idle task cells in the Tasks panel.

### Removed

- Remove the "Open in Terminal" item from the sidebar project context menu.

## [1.1.59]

### Changed

- Selecting a project in the sidebar is now instant: the row highlights immediately, while the content area, theme and right sidebar follow a beat later, so terminal mounting no longer stalls the click feedback; rapid clicks apply only the last selection.

## [1.1.58]

### Changed

- Projects without an explicit group (including legacy projects created before groups existed) now default to the "Personal" group.
- Restrict the "Current" group tab to projects actually in use: it now lists only unarchived projects that still have open tabs.
- Show project-count badges only on the active group tab, and fall back to showing just the active tab's title sooner in narrow sidebars so all titles don't squeeze together.

## [1.1.57]

### Added

- Add project groups to the left sidebar: the archived collapse area becomes a group tab bar (Personal / Work / Current / Archived); create, rename and delete custom groups, move a project onto a group by dragging it onto the group's tab or via the right-click "Move to Group" menu, and projects created while a user group tab is selected join that group; the Archived tab has a search filter.
- Task grid cells in the Tasks panel now show the last run duration and a restart button while a task is running; double-click runs an idle task.

### Changed

- Replace the ad-hoc PATH lookups with a single executable locator that scans the user's login-shell PATH and common package-manager global bin directories (npm, pnpm, yarn, bun, nvm, fnm, volta, asdf, mise), backed by a short-lived cache; AI CLI detection, editor formatter lookup and subprocess PATH augmentation all share it, so CLIs installed through a shell are found even when Qjiao is launched from Finder.
- On relaunch, close terminals that can't be restored — their working directory is gone, or they would only show an empty shell — instead of dropping them into the home directory or keeping them around as dead "Process exited" tabs (split panes collapse, empty tabs are dropped); tabs that were never used and have no replayable history no longer write a session snapshot.

### Fixed

- Fix restored terminals leaving dead "Process exited. Press any key to close" tabs behind when the restored command exits or fails to launch: the surface now closes as soon as the child process exits (wait-after-command disabled, `GHOSTTY_ACTION_SHOW_CHILD_EXITED` handled).

## [1.1.56]

### Changed

- Update the embedded Ghostty engine from the locked `35e1a016` commit to upstream tip `b69f612` (2026-08-26): upstream now fixes the TempDir export fd leak, so the local `0011-fix-tempdir-fd-leak.patch` is dropped, and clipboard callbacks are rebased onto the new `ghostty_clipboard_complete_s` / `ghostty_surface_deny_clipboard_request` API.

## [1.1.55]

### Changed

- Compact single-row tab strips (scroll and elastic layouts) from 30pt to 26pt tab items with tighter vertical padding, while wrap-layout rows keep their 30pt height; the window-drag band below the tabs now matches each layout's height.
- Remove the Tasks panel's floating refresh button — tasks keep refreshing automatically.

### Fixed

- Fix UI stutter after long-running sessions: the display-cycle layout protection no longer symbolizes the call stack on every window layout pass, batches same-frame layout requests per window, and falls back to nesting-depth detection when the private observer API is unavailable; the file-tree drag-end mouse monitor is now installed once at launch instead of once per window.
- Skip the periodic git-root re-parse tick while the right sidebar panel is hidden, avoiding needless git subprocess runs.

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
