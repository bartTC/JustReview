# Changelog

All notable changes to JustReview. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-12

The first release.

### Added

- Review everything that changed against HEAD: staged, unstaged and untracked files in a tree,
  with stacked or side-by-side diffs, changed words highlighted and optional line wrapping.
- Show All Files (⇧⌘A) lists unchanged files too, so any file can be read and annotated.
- Image previews for changed images, old and new side by side, with pixel and file size.
- Annotations for your LLM: double-click a line or a file name to leave a note, or drag across
  several lines and leave one note for the range. Copy all notes as Markdown (⇧⌘C).
- Notes follow lines that move, and are dropped once their line changes.
- Marked lines copy without line numbers (⌘C).
- Syntax highlighting with Tree-sitter for Python, JavaScript, TypeScript, JSON, CSS, HTML,
  Bash, Go, Rust, Swift, YAML, Markdown and TOML.
- Every Helix theme, with separate picks for light and dark mode, and your own themes.
- Live updates as files change on disk.
- Keyboard navigation: ⌥⌘↓/↑ between changes across files, ⌥⌘→/← between files.
- One window per repository; ⌘-click opens a file's diff in its own window.
- Open files in their default app or another app, or reveal them in Finder.
- `jrev` command line tool to open a repository from the terminal.
- Settings for fonts, line height, tab width, themes and app appearance.
- Signed with a Developer ID and notarized by Apple.

[1.0.0]: https://github.com/bartTC/JustReview/releases/tag/v1.0.0
