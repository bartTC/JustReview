# Git Diff

A small, read-only macOS diff viewer for reviewing changes in a git repo.
Lists every file that differs from `HEAD` (staged, unstaged and untracked alike)
and shows the diff stacked or side by side. It never writes to the repository.

## Build

    ./build.sh            # -> build/GitDiff.app

Requires macOS 14+ and the Xcode Command Line Tools.

## Run

    ./gitdiff [path]      # opens the repo at path (default: current dir)

Symlink `gitdiff` onto your PATH to use it from anywhere. You can also open a repo
with ⌘O or by dropping a folder on the window.

## Use

- ⌘1 stacked, ⌘2 side by side, ⌘R refresh (rarely needed: the repo is watched and reloads automatically)
- ⌘, Settings: font family/size for the file list and diff view, tab width
- Double-click a diff line (or right-click → Add Annotation…) to annotate it; ⌘↩ saves.
  All annotations are listed in the bottom pane; Copy (⇧⌘C) puts them on the clipboard as Markdown:

      ## src/utils/mcp-oauth/permissions.test.ts:6 (+)
      test

  `(+)` = added line, `(-)` = removed line, no suffix = unchanged line. Annotations are kept per
  repository in the app's preferences (never written into the repo).
