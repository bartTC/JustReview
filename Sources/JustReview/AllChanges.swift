import SwiftUI

/// Identifies a row of one of the files shown on one page: rows are numbered per file, so the
/// file is part of it (for scrolling to the row).
private struct PageRowID: Hashable {
    let path: String
    let row: Int
}

private struct PageRow<Row: Identifiable>: Identifiable where Row.ID == Int {
    let path: String
    let row: Row
    var id: PageRowID { PageRowID(path: path, row: row.id) }
}

/// Every changed file's diff on one page (View → Show All Changes), for an overview of a
/// change that touches several files. Like a commit on the History tab, but lines and files
/// can be annotated; picking a file in the list scrolls to it.
struct AllChangesView: View {
    @ObservedObject var model: RepoModel
    let mode: DiffMode
    @AppStorage(FontPrefs.diffFamily) private var family = ""
    @AppStorage(FontPrefs.diffSize) private var size = FontPrefs.defaultDiffSize
    @AppStorage(FontPrefs.tabWidth) private var tabWidth = FontPrefs.defaultTabWidth
    @AppStorage(FontPrefs.lineHeight) private var lineHeight = FontPrefs.defaultLineHeight
    @AppStorage("syntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage("wrapLines") private var wrapLines = true
    @AppStorage(RepoModel.showBlameKey) private var showBlame = false
    @AppStorage(DiffContext.key) private var contextLines = DiffContext.standard
    @AppStorage(ThemePrefs.lightKey) private var lightTheme = ThemeStore.defaultLight
    @AppStorage(ThemePrefs.darkKey) private var darkTheme = ThemeStore.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    /// Files folded away by clicking their header.
    @StateObject private var collapsed = Box<Set<String>>([])
    /// How far the content is scrolled sideways (unwrapped lines); headers move along.
    @StateObject private var scrollX = Box<CGFloat>(0)
    /// Where ⌥⌘↓/↑ continue from: the change last jumped to, or the file last scrolled to.
    @StateObject private var cursor = Box<Cursor?>(nil)
    /// The file of the annotation just scrolled to: picking it in the pane also selects its
    /// file, which must not scroll to the file's top instead.
    @StateObject private var revealed = Box<String?>(nil)

    private enum Cursor {
        case change(PageRowID)
        case file(String)
    }

    private var theme: SyntaxTheme {
        ThemeStore.shared.theme(named: colorScheme == .dark ? darkTheme : lightTheme)
    }

    private var codeBackground: Color { Color(nsColor: theme.background ?? .textBackgroundColor) }

    var body: some View {
        detail
            .onChange(of: tabWidth) { model.reloadDiff() }
            .onChange(of: syntaxHighlighting) { model.reloadDiff() }
            .onChange(of: lightTheme) { model.reloadDiff() }
            .onChange(of: darkTheme) { model.reloadDiff() }
            .onChange(of: colorScheme) { model.reloadDiff() }
            .onChange(of: contextLines) { model.reloadDiff() }
            .onChange(of: showBlame) { model.loadBlame() }
    }

    @ViewBuilder
    private var detail: some View {
        if let files = model.allChanges {
            if files.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                       description: Text("Nothing differs from HEAD."))
            } else {
                content(files)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(codeBackground)
        }
    }

    private func content(_ files: [CommitFile]) -> some View {
        let nsFont = FontPrefs.diffFont(family: family, size: size)
        let column = FontPrefs.digitWidth(nsFont)
        // One gutter width for every file, so the code lines up from file to file.
        let maxLine = files.map(\.diff.maxLineNumber).max() ?? 0
        let gutter = CGFloat(max(String(maxLine).count, 2)) * column + 12
        let lineMode: DiffLineMode = wrapLines ? .wrap : (mode == .split ? .truncate : .scroll)
        let maxColumns = files.map(\.diff.maxColumns).max() ?? 0
        // Blame column: for every file, so the code lines up (empty for files not at HEAD).
        let blameWidth: CGFloat? = showBlame ? (size * 15).rounded() : nil
        let contentWidth = (blameWidth ?? 0) + gutter * 2 + 16 + column + CGFloat(maxColumns) * column + 16
        let scrollsSideways = lineMode == .scroll

        // The divider keeps the scroll view off the window's top edge; touching it, AppKit lets
        // the content scroll under the (transparent) toolbar.
        return VStack(spacing: 0) {
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView(scrollsSideways ? [.vertical, .horizontal] : .vertical) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(files) { file in
                                Section {
                                    fileNote(file)
                                        .stayInView(scrollsSideways, scrollX: scrollX.value,
                                                    viewportWidth: viewport.size.width)
                                    if !collapsed.value.contains(file.id) {
                                        fileContent(file, gutter: gutter)
                                    }
                                } header: {
                                    header(file)
                                        .stayInView(scrollsSideways, scrollX: scrollX.value,
                                                    viewportWidth: viewport.size.width)
                                }
                            }
                        }
                        .coordinateSpace(.named(DiffLines.space))
                        .diffRowsStyle(font: Font(nsFont as CTFont), size: size, lineHeight: lineHeight,
                                       column: column, theme: theme, lineMode: lineMode)
                        .environment(\.diffBlameWidth, blameWidth)
                        .frame(width: scrollsSideways ? max(viewport.size.width, contentWidth) : nil,
                               alignment: .topLeading)
                    }
                    .defaultScrollAnchor(.topLeading)
                    // Only the horizontal offset: vertical scrolling shouldn't redraw anything.
                    .onScrollGeometryChange(for: CGFloat.self) { $0.visibleRect.minX } action: { _, x in
                        if scrollsSideways { scrollX.value = x }
                    }
                    .background {
                        // Esc unmarks the marked lines (an open editor's Cancel takes Esc first).
                        if model.mark != nil && model.editing == nil {
                            Button("") { model.mark = nil }
                                .keyboardShortcut(.cancelAction)
                                .opacity(0)
                                .frame(width: 0, height: 0)
                        }
                    }
                    .id("\(mode.rawValue)|\(wrapLines)") // back to the top on mode/wrap change
                    .background(codeBackground)
                    .onAppear { scrollIfRequested(proxy, files: files) }
                    .onChange(of: model.scrollRequest) { scrollIfRequested(proxy, files: files) }
                    .onChange(of: model.selection) { showSelectedFile(proxy, files: files) }
                    .onChange(of: model.changeJump) { jump(proxy, files: files) }
                }
            }
        }
    }

    private func header(_ file: CommitFile) -> some View {
        let anchor = NoteAnchor(path: file.change.path)
        return DiffFileHeader(file: file, collapsed: collapsed.value.contains(file.id),
                              toggle: { toggle(file.id) },
                              annotation: (model.annotation(at: anchor) != nil, { model.beginEditing(anchor) }))
            .contextMenu { FileOpenMenuItems(root: model.root, path: file.change.path) }
    }

    private func toggle(_ file: String) {
        if collapsed.value.contains(file) {
            collapsed.value.remove(file)
        } else {
            collapsed.value.insert(file)
        }
    }

    /// The note on the whole file (or its open editor), under the file's header; it stays when
    /// the file is folded away.
    @ViewBuilder
    private func fileNote(_ file: CommitFile) -> some View {
        let anchor = NoteAnchor(path: file.change.path)
        if model.editing?.note.anchor == anchor {
            InlineAnnotationEditor(model: model, indent: 12)
        } else if let note = model.annotation(at: anchor) {
            AnnotationNoteView(annotation: note, indent: 8,
                               onEdit: { model.beginEditing(anchor) },
                               onDelete: { model.removeAnnotation(note) })
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func fileContent(_ file: CommitFile, gutter: CGFloat) -> some View {
        let path = file.change.path
        let blame = model.allBlameRows[file.id]
        if file.diff.isBinary {
            note("Binary file, not shown.")
        } else if file.diff.unified.isEmpty {
            note(DiffDetailView.summary(file.diff.notes, change: file.change))
        } else {
            switch mode {
            case .unified:
                ForEach(file.diff.unified.map { PageRow(path: path, row: $0) }) {
                    UnifiedRowView(model: model, path: path, row: $0.row, gutter: gutter, blame: blame?.unified[$0.row.id])
                }
            case .split:
                ForEach(file.diff.split.map { PageRow(path: path, row: $0) }) {
                    SplitRowView(model: model, path: path, row: $0.row, gutter: gutter, blame: blame?.split[$0.row.id])
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    // MARK: Scrolling

    private func scroll(_ proxy: ScrollViewProxy, to id: some Hashable, anchor: UnitPoint) {
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: anchor) }
        }
    }

    /// A file picked in the list (or ⌥⌘→/←): its header goes to the top.
    private func showSelectedFile(_ proxy: ScrollViewProxy, files: [CommitFile]) {
        model.pendingChangeAnchor = nil
        // An annotation picked in the pane scrolls to its line instead (before or after this).
        let wasRevealed = revealed.value
        revealed.value = nil
        guard model.scrollRequest == nil, let path = model.selection, path != wasRevealed,
              files.contains(where: { $0.id == path }) else { return }
        cursor.value = .file(path)
        scroll(proxy, to: path, anchor: .top)
    }

    /// Jump to an annotated line (or file) when one is picked in the annotations pane.
    private func scrollIfRequested(_ proxy: ScrollViewProxy, files: [CommitFile]) {
        guard let request = model.scrollRequest else { return }
        model.scrollRequest = nil
        guard let file = files.first(where: { $0.change.path == request.path }) else { return }
        revealed.value = file.id
        cursor.value = .file(file.id)
        guard let key = request.key else {
            scroll(proxy, to: file.id, anchor: .top)
            return
        }
        let row: Int? = switch mode {
        case .unified: file.diff.unified.first { $0.key == key }?.id
        case .split: file.diff.split.first { $0.left?.key == key || $0.right?.key == key }?.id
        }
        guard let row else { return }
        collapsed.value.remove(file.id)
        scroll(proxy, to: PageRowID(path: file.id, row: row), anchor: .center)
    }

    /// ⌥⌘↓/↑: the next/previous run of changed lines, from file to file.
    private func jump(_ proxy: ScrollViewProxy, files: [CommitFile]) {
        guard let request = model.changeJump else { return }
        model.changeJump = nil
        let shown = files.filter { !collapsed.value.contains($0.id) && !$0.diff.isBinary }
        let starts = shown.flatMap { file in
            DiffDetailView.changeStarts(file.diff, layout: mode).map { PageRowID(path: file.id, row: $0) }
        }
        let index: Int
        switch cursor.value {
        case .change(let id) where starts.contains(id):
            index = starts.firstIndex(of: id)! + (request.forward ? 1 : -1)
        case .file(let path) where shown.contains(where: { $0.id == path }):
            // From a file's header: into that file, or back into the one before it.
            let first = starts.firstIndex { $0.path == path }
                ?? starts.firstIndex { id in
                    shown.firstIndex { $0.id == id.path }! > shown.firstIndex { $0.id == path }!
                } ?? starts.count
            index = request.forward ? first : first - 1
        default:
            index = request.forward ? 0 : starts.count - 1
        }
        guard starts.indices.contains(index) else { NSSound.beep(); return }
        cursor.value = .change(starts[index])
        scroll(proxy, to: starts[index], anchor: UnitPoint(x: 0, y: 0.2))
    }
}
