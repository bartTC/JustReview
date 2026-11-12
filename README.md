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
- ⌘1 stacked, ⌘2 side by side, ⌥Z toggle line wrap (on by default; without it stacked view
  scrolls sideways and side by side cuts long lines off), ⇧⌘R refresh (rarely needed: the repo
  is watched)
- ⌘, Settings: font family/size for the file list and the diff view, line height (0.05 steps), tab width,
  syntax highlighting on/off, and a syntax theme for light mode and one for dark mode
- Click a diff line (or right-click → Add Annotation…) to annotate it; ⌘↩ saves.
  All annotations are listed in the bottom pane (fold it away with its chevron or ⌥⌘A).
  ⌘C copies them all to the clipboard as Markdown; ⌘R clears them (after confirming):

      ## src/utils/mcp-oauth/permissions.test.ts:6 (+)
      test

  `(+)` = added line, `(-)` = removed line, no suffix = unchanged line.
- To annotate a whole file, use the speech-bubble button in the file header; it is listed as
  `## path/to/file` (no line number).
- Annotations are kept per repository in the app's preferences (never written into the repo).
  They are anchored to the line's content: when files change, a note follows its line if the line
  just moved; if the line itself was changed (or is no longer in the diff) the note is dropped, on
  the assumption that it has been addressed.

## Syntax highlighting

Highlighting uses [Tree-sitter](https://tree-sitter.github.io) via
[SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter). Both versions of a file (HEAD and
working tree) are parsed in full, so multi-line strings and comments are colored correctly even
when a hunk starts inside one.

Supported: Python, JavaScript/JSX, TypeScript, TSX, JSON, CSS, HTML, Bash, Go, Rust, Swift, YAML,
Markdown, TOML.

- Grammars come in as Swift packages (pinned in `Package.swift`). Python, JavaScript, CSS and YAML
  are vendored in `Vendor/Grammars` because their upstream `Package.swift` drops the external
  scanner under current SwiftPM.
- Highlight queries live in `Resources/queries/<language>.scm` and are copied into the app bundle.
- `swift run syntax-check` verifies every grammar loads and its query compiles.

### Themes

Syntax themes use the [Helix theme format](https://docs.helix-editor.com/themes.html). All themes
from Helix 25.07.1 are bundled (`Resources/themes`, MPL-2.0 / their own licenses), plus the built-in
Xcode Light and Xcode Dark. Pick one for light and one for dark mode in Settings; a theme sets the
code colors (incl. bold/italic), the diff background, text and line-number colors. Drop your own
`.toml` themes into `~/Library/Application Support/JustReview/themes` (Settings → Open Themes
Folder, then Reload); `inherits` and `[palette]` work as in Helix.

To add a language: add the grammar package (or vendor it), its `highlights.scm` as
`Resources/queries/<name>.scm`, and a case in `SyntaxLanguage` (`Sources/Syntax/Syntax.swift`).

## License

MIT — see [LICENSE](LICENSE). Vendored grammars and highlight queries are MIT licensed by their
respective authors (license files are kept alongside them).
