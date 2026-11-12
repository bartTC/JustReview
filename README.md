# JustReview

A small, read-only macOS app for reviewing the changes in a git repository.

It lists every file that differs from `HEAD` (staged, unstaged and untracked alike) and shows
the diff stacked or side by side. You can annotate lines and copy all annotations as Markdown —
handy for handing review notes to a person or an AI agent. JustReview never writes to the
repository: no staging, no editing, no committing.

## Build

    ./build.sh            # -> build/JustReview.app

Requires macOS 15+ and the Xcode Command Line Tools (full Xcode is not needed).

## Run

    jrev [path]           # review the repo at path (default: current directory)

Install the `jrev` command with **JustReview → Install Command Line Tool…**; it links
`/usr/local/bin/jrev` to the launcher inside the app (asks for your password if needed).
From the source checkout you can also run `./jrev`.

JustReview runs as a single app with one window per repository: `jrev` brings the window for
that repo to the front if it is already open, otherwise it opens one. You can also open a repo
with ⌘O or by dropping a folder on a window.

The list and the diff reload automatically when files in the repository change.

## Use

- The left pane shows the changed files as a tree. **Show All Files** (toolbar or ⇧⌘A) adds the
  unchanged files too (greyed out); selecting one shows its full content.
- ⌘1 stacked, ⌘2 side by side, ⇧⌘R refresh (rarely needed: the repo is watched)
- ⌘, Settings: font family/size for the file list and the diff view, line height, tab width
- Click a diff line (or right-click → Add Annotation…) to annotate it; ⌘↩ saves.
  All annotations are listed in the bottom pane (fold it away with its chevron or ⌥⌘A).
  ⌘C copies them all to the clipboard as Markdown; ⌘R clears them (after confirming):

      ## src/utils/mcp-oauth/permissions.test.ts:6 (+)
      test

  `(+)` = added line, `(-)` = removed line, no suffix = unchanged line.
- Annotations are kept per repository in the app's preferences (never written into the repo).
  They are anchored to the line's content: when files change, a note follows its line if the line
  just moved; if the line itself was changed (or is no longer in the diff) the note is dropped, on
  the assumption that it has been addressed.

## License

MIT — see [LICENSE](LICENSE).
