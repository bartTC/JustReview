# Changelog

All notable changes to JustReview. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [1.3.0] - 2026-11-14

### Added

- Show All Changes (⇧⌘A, View menu or the toolbar): the Changes tab shows the changes of every
  file on one page, one after another, instead of one file at a time. For an overview of a
  small change that touches several files. Lines and files are annotated as usual; picking a
  file in the list scrolls to it, a click on a file's header folds it away, and ⌥⌘↓/↑ step
  through the changes from file to file. Show Blame works there too. Off by default. A change
  of more than 100 files or 20,000 diff lines is shown one file at a time, with a note saying
  so.

### Fixed

- The app icon is no longer shown smaller on a light tile in the Dock and Finder on macOS 26
  and later.

## [1.2.0] - 2026-11-14

### Added

- Back and Forward (⌘[ / ⌘], or the arrows in the toolbar) step through the files and commits
  you looked at, so after clicking a name in the blame column you can return to the file.
- Hovering a name in the blame column highlights every line from that commit.
- Instructions for copied annotations (Settings → Annotations), one text per repository: put
  in front of the annotations when you copy them, e.g. "Below are my changes. Apply them and
  commit automatically."
- Annotations are kept in files, one folder per repository in
  ~/Library/Application Support/JustReview/repositories (shown in Settings → Annotations), for
  your own workflows: annotations.md is what Copy puts on the clipboard, annotations.json the
  annotations themselves, with a copy of the instructions. Changes to the annotations in
  annotations.json show up in the app; deleting it clears them. Annotations kept in the app's preferences by earlier versions move there.
- Swipe between pages on the trackpad, or a mouse's back and forward buttons, go back and
  forward too.

### Changed

- Annotations are written in an editor that opens right under the line instead of a popover.
  Return or a click anywhere else saves it (so: click a line, type, click the next line,
  type…), Esc cancels; ⇧Return starts a new line, and the text box grows as you write. The
  text is kept while you scroll away, and saved when you show another file. The keys are
  spelled out next to the buttons, and Save is off until there is something to save.
- Typing with lines marked starts an annotation on them; no need to double-click.

### Fixed

- With Context Lines set above 3, an annotation on an unchanged line far from any change was
  dropped the next time the files changed.
- An annotation being written follows its line when the code above it changes meanwhile,
  instead of ending up on whatever line has its number by then. When the line itself is
  rewritten, the editor stays open on it with what you typed.
- A note deleted in another window while its editor was open is no longer brought back by
  closing the editor.
- VoiceOver names the annotation editor, the notes under the lines and their delete buttons.

## [1.1.0] - 2026-11-13

### Added

- History tab: lists the commits; picking one shows its message and the changes of every file
  it touched, one after another (read-only, no annotations). Click a file's header to fold it.
- Show Blame (⌥⌘B): who last changed each line and when, in a column next to the line
  numbers, for every line that was already committed. Click a name to see its commit on the
  History tab.
- Context Lines (View menu): 3, 5, 10 or 25 unchanged lines around each change, or the
  whole file with the changes in it.

### Changed

- Sections of a diff are set apart by a gap and a quieter band showing the enclosing
  function, instead of git's raw "@@" line.
- The sidebar has three tabs: Changes, Files and History (⌃⌘1/2/3). The Files tab replaces the
  Show All Files toggle (⇧⌘A).

### Fixed

- Switching between changed and all files could leave an old row drawn over another one in
  the file list.
- A selected unchanged file's name stays readable (white) instead of dimmed grey on the
  selection color.

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

[Unreleased]: https://github.com/bartTC/JustReview/compare/v1.2.0...HEAD
[1.3.0]: https://github.com/bartTC/JustReview/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/bartTC/JustReview/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/bartTC/JustReview/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/bartTC/JustReview/releases/tag/v1.0.0
