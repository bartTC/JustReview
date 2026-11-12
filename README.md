# Git Diff

A small, read-only macOS diff viewer for reviewing changes in a git repo.
Lists every file that differs from `HEAD` (staged, unstaged and untracked alike)
and shows the diff stacked or side by side. It never writes to the repository.

## Build

    ./build.sh            # -> build/GitDiff.app

Requires macOS 15+ and the Xcode Command Line Tools.

## Run

    ./gitdiff [path]      # opens the repo at path (default: current dir)

To use it from anywhere, choose **Git Diff → Install Command Line Tool…** in the app; it links
`/usr/local/bin/gitdiff` to the launcher inside the app (asks for your password if needed). You can also open a repo
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
- Annotations are anchored to the line's content. When files change, a note follows its line if
  the line just moved; if the line itself was changed (or is no longer in the diff) the note is
  dropped, on the assumption that it has been addressed.
