# Changelog

All notable changes to Qjiao. This file is the **source of truth for the release
notes shown in the in-app updater**: [`scripts/release.ts`](scripts/release.ts)
extracts the section whose heading matches the version being released
(`MARKETING_VERSION`) and publishes it next to the update, so Sparkle shows it in
the update prompt.

Format follows [Keep a Changelog](https://keepachangelog.com). Add a new
`## [<version>]` section at the top for each release, matching the version you
set in the Xcode project.

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
