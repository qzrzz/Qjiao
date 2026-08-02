# Changelog

All notable changes to Qjiao. This file is the **source of truth for the release
notes shown in the in-app updater**: [`scripts/release.ts`](scripts/release.ts)
extracts the section whose heading matches the version being released
(`MARKETING_VERSION`) and publishes it next to the update, so Sparkle shows it in
the update prompt.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.

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
