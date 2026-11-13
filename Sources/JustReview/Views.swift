import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle
    /// File list + annotations pane; off for a file opened in its own window (just the diff).
    var showsChrome = true
    @AppStorage("diffMode") private var mode: DiffMode = .unified
    @AppStorage("wrapLines") private var wrapLines = true

    /// The diff with its toolbar items. They're declared on the detail column itself so they
    /// (and the spacer pushing the buttons right) land in the detail part of the toolbar.
    private var diffView: some View {
        Group {
            if showsChrome && model.sidebarTab == .history {
                CommitDetailView(model: model, mode: mode)
            } else {
                DiffDetailView(model: model, mode: mode, showsFileList: showsChrome)
            }
        }
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .navigation) { RepoTitle(model: model) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { RepoTitle(model: model) }
            }
            ToolbarItemGroup {
                // Without a drawn title nothing fills the middle; keep the buttons on the right.
                Spacer()
                Picker("Layout", selection: $mode) {
                    Label("Stacked", systemImage: "rectangle.split.1x2").tag(DiffMode.unified)
                    Label("Side by Side", systemImage: "rectangle.split.2x1").tag(DiffMode.split)
                }
                .pickerStyle(.segmented)
                .help("Stacked (⌘1) / Side by side (⌘2)")

                Toggle(isOn: $wrapLines) {
                    Label("Wrap Lines", systemImage: "arrow.turn.down.left")
                }
                .toggleStyle(.button)
                .help("Wrap long lines (⌥Z)")

                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⇧⌘R)")
                .disabled(model.root == nil)
            }
        }
    }

    var body: some View {
        // Annotations pane sits below the split view and takes real space
        // (a safe-area inset would let the split view's columns scroll underneath it).
        Group {
            if showsChrome {
                VStack(spacing: 0) {
                    // The file list is essential: always visible, no toggle, can't be collapsed.
                    NavigationSplitView(columnVisibility: .constant(.all)) {
                        SidebarView(model: model, handle: handle)
                            .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 500)
                            .toolbar(removing: .sidebarToggle)
                    } detail: {
                        diffView
                    }
                    // Commits in the history can't be annotated; the pane is for the working tree.
                    if model.sidebarTab != .history { AnnotationsPane(model: model) }
                }
            } else {
                diffView
            }
        }
        // The toolbar's tinted detail section doesn't line up with the split view's divider
        // on recent macOS; hiding the toolbar background removes the misaligned edge.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The window title names the file (Window menu, Mission Control) but isn't drawn in the
        // toolbar; the toolbar shows the repository and its branch instead.
        .navigationTitle(windowTitle)
        .toolbar(removing: .title)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            WindowRouter.shared.open(url, preferring: handle)
            return true
        }
        .alert("Can’t open repository", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

extension ContentView {
    /// The shown file's name, or the shown commit's subject on the History tab.
    fileprivate var windowTitle: String {
        if showsChrome && model.sidebarTab == .history {
            return model.commits.first { $0.id == model.selectedCommit }?.subject ?? model.repoName
        }
        return model.selection.map { ($0 as NSString).lastPathComponent } ?? model.repoName
    }
}

/// Toolbar title: repository folder name with the branch in a pill next to it.
private struct RepoTitle: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.repoName)
                .font(.headline)
            if !model.branch.isEmpty {
                Text(model.branch)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .fixedSize()
        .padding(.leading, 6)
        .help(model.root?.path ?? "")
    }
}

// MARK: - Sidebar

/// The sidebar: Changes | Files | History tabs above the list.
struct SidebarView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $model.sidebarTab) {
                ForEach(SidebarTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Changed files (⌃⌘1), all files (⌃⌘2), or the commit history (⌃⌘3)")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if model.sidebarTab == .history {
                HistoryListView(model: model, handle: handle)
            } else {
                FileListView(model: model, handle: handle, showAll: model.sidebarTab == .files)
            }
        }
    }
}

/// The sidebar's toolbar button for opening another repository.
struct OpenRepositoryButton: View {
    let handle: WindowHandle
    var body: some View {
        Button { WindowRouter.shared.chooseRepository(preferring: handle) } label: {
            Label("Open Repository", systemImage: "folder")
        }
        .help("Open Repository (⌘O)")
    }
}

/// The overlay for a window without a repository.
struct NoRepositoryView: View {
    let handle: WindowHandle
    var body: some View {
        ContentUnavailableView {
            Label("No Repository", systemImage: "folder")
        } description: {
            Text("Open a git repository, drop a folder here, or run “jrev” in a repository.")
        } actions: {
            Button("Open Repository…") { WindowRouter.shared.chooseRepository(preferring: handle) }
        }
    }
}

// MARK: - File list

struct FileListView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle
    /// Files tab: unchanged files are listed too.
    let showAll: Bool
    @AppStorage(FontPrefs.listFamily) private var family = ""
    @AppStorage(FontPrefs.listSize) private var size = FontPrefs.defaultListSize

    /// The file's diff in a window of its own (no file list, no annotations pane).
    private func openInNewWindow(_ path: String) {
        guard let root = model.root else { return }
        WindowRouter.shared.openFileWindow(root: root, file: path)
    }

    /// Folders the user expanded/collapsed by hand; others use the default (see `isExpanded`).
    @StateObject private var expansion = Box<[String: Bool]>([:])

    var body: some View {
        let font = Font(FontPrefs.listFont(family: family, size: size) as CTFont)
        let tree = FileTree.build(model.changes + (showAll ? model.unchanged : []))
        ScrollViewReader { proxy in
        List(selection: listSelection) {
            FileTreeRows(nodes: tree, font: font, size: size, selection: model.selection,
                         isExpanded: isExpanded)
        }
        // A fresh list for Changes and for Files: changing one list's rows wholesale leaves
        // stale rows (the old selection) drawn over others.
        .id(showAll)
        // Reveal this tab's file when the tab/window becomes active or shows another file
        // (and once the list has loaded, if the file wasn't listed yet, or on switching tabs).
        .onAppear { reveal(model.selection, in: tree, proxy: proxy) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === handle.window { reveal(model.selection, in: tree, proxy: proxy) }
        }
        .onChange(of: model.selection) { reveal(model.selection, in: tree, proxy: proxy) }
        .onChange(of: tree.count + model.changes.count + model.unchanged.count) {
            if pendingReveal.value { reveal(model.selection, in: tree, proxy: proxy) }
        }
        // Right-click (or ⌘-click, see listSelection): the file's diff in a window of its own.
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first {
                Button("Open in New Window") { openInNewWindow(path) }
                Divider()
                FileOpenMenuItems(root: model.root, path: path)
            }
        }
        // Sidebar controls live in the sidebar's part of the toolbar (right-aligned).
        .toolbar {
            ToolbarItemGroup {
                Spacer()
                OpenRepositoryButton(handle: handle)
            }
        }
        }
        .overlay {
            if model.root == nil {
                NoRepositoryView(handle: handle)
            } else if model.changes.isEmpty && !showAll {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                       description: Text("Nothing differs from HEAD."))
            }
        }
    }

    @StateObject private var pendingReveal = Box(false)

    /// The selected file; ⌘-click opens a file in its own window instead.
    private var listSelection: Binding<String?> {
        Binding(
            get: { model.selection },
            set: { path in
                // Only a ⌘-click: ⌘↑/⌘↓ also move the selection while ⌘ is held.
                let event = NSApp.currentEvent
                let isClick = event.map { [.leftMouseDown, .leftMouseUp].contains($0.type) } ?? false
                if isClick, NSEvent.modifierFlags.contains(.command) {
                    // ⌘-click opens the file in a window of its own; this window keeps its file.
                    if let path { openInNewWindow(path) }
                    model.objectWillChange.send()   // snap the list back to this window's file
                } else {
                    model.selection = path
                }
            }
        )
    }

    /// Expands the folders leading to `path` and scrolls its row into view.
    private func reveal(_ path: String?, in tree: [FileTreeNode], proxy: ScrollViewProxy) {
        guard let path else { return }
        let listed = model.changes.contains { $0.path == path } || model.unchanged.contains { $0.path == path }
        pendingReveal.value = !listed       // not in the list yet: try again once it loads
        guard listed else { return }
        for folder in FileTree.folders(containing: path, in: tree) { expansion.value[folder] = true }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(FileTreeNode.ID(path: path)) }
        }
    }

    /// Folders start expanded when they contain changes (always, unless showing all files).
    private func isExpanded(_ node: FileTreeNode) -> Binding<Bool> {
        Binding(
            get: { expansion.value[node.path] ?? (node.hasChanges || !showAll) },
            set: { expansion.value[node.path] = $0 }
        )
    }
}

// MARK: - File tree

struct FileTreeNode: Identifiable {
    /// Not a String, so folder rows don't take part in the List's (String) selection.
    struct ID: Hashable { let path: String }

    let path: String
    let name: String
    let change: FileChange?          // nil for folders
    var children: [FileTreeNode] = []
    var hasChanges = false

    var id: ID { ID(path: path) }
}

enum FileTree {
    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [FileChange] = []
    }

    /// Paths of the (possibly compacted) folder nodes on the way to a file.
    static func folders(containing path: String, in nodes: [FileTreeNode]) -> [String] {
        for node in nodes where node.change == nil && path.hasPrefix(node.path + "/") {
            return [node.path] + folders(containing: path, in: node.children)
        }
        return []
    }

    static func build(_ files: [FileChange]) -> [FileTreeNode] {
        let root = Folder()
        for file in files {
            var folder = root
            for part in file.path.split(separator: "/").dropLast().map(String.init) {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
            folder.files.append(file)
        }
        return nodes(root, prefix: "")
    }

    private static func nodes(_ folder: Folder, prefix: String) -> [FileTreeNode] {
        var result: [FileTreeNode] = []
        for name in folder.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var sub = folder.folders[name]!
            var label = name
            // Compact chains of single-child folders: "src/utils/mcp-oauth".
            while sub.files.isEmpty, sub.folders.count == 1, let (next, nextFolder) = sub.folders.first {
                label += "/" + next
                sub = nextFolder
            }
            let path = prefix + label
            let children = nodes(sub, prefix: path + "/")
            result.append(FileTreeNode(path: path, name: label, change: nil, children: children,
                                       hasChanges: children.contains { $0.hasChanges }))
        }
        for file in folder.files.sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }) {
            result.append(FileTreeNode(path: file.path, name: file.fileName, change: file,
                                       hasChanges: !file.isUnchanged))
        }
        return result
    }
}

private struct FileTreeRows: View {
    let nodes: [FileTreeNode]
    let font: Font
    let size: Double
    let selection: String?
    let isExpanded: (FileTreeNode) -> Binding<Bool>

    var body: some View {
        ForEach(nodes) { node in
            if let change = node.change {
                FileRow(change: change, font: font, size: size, isSelected: change.id == selection)
                    .tag(change.id)
            } else {
                DisclosureGroup(isExpanded: isExpanded(node)) {
                    FileTreeRows(nodes: node.children, font: font, size: size, selection: selection,
                                 isExpanded: isExpanded)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder")
                            .font(.system(size: size * 0.9))
                            .foregroundStyle(.secondary)
                            .frame(width: (size * 1.15).rounded())
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(node.hasChanges ? .primary : .secondary)
                    }
                    .font(font)
                    .contentShape(Rectangle())
                    .onTapGesture { isExpanded(node).wrappedValue.toggle() }
                }
            }
        }
    }
}

struct FileRow: View {
    let change: FileChange
    let font: Font
    let size: Double
    /// The selected row: text on the selection color.
    var isSelected = false

    var body: some View {
        HStack(spacing: 7) {
            // Unchanged files are dimmed, except when selected: there the text turns white.
            Text(change.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(change.isUnchanged && !isSelected ? .secondary : .primary)
            Spacer(minLength: 4)
            if !change.isUnchanged {
                StatusBadge(label: change.statusLabel, size: size)
            }
        }
        .font(font)
        .help("\(change.statusDescription): \(change.oldPath.map { "\($0) → " } ?? "")\(change.path)")
    }
}

/// Muted status letter (M, A, D, R, U…) in a small outlined box, scaled to the list font.
private struct StatusBadge: View {
    let label: String
    let size: Double

    var body: some View {
        let box = (size * 1.15).rounded() - 2
        Text(label)
            .font(.system(size: size * 0.68 - 1, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: box, height: box)
            .overlay(
                RoundedRectangle(cornerRadius: box * 0.22)
                    .strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
            )
    }
}

// MARK: - Diff detail

struct DiffDetailView: View {
    @ObservedObject var model: RepoModel
    let mode: DiffMode
    @AppStorage(FontPrefs.diffFamily) private var family = ""
    @AppStorage(FontPrefs.diffSize) private var size = FontPrefs.defaultDiffSize
    @AppStorage(FontPrefs.tabWidth) private var tabWidth = FontPrefs.defaultTabWidth
    @AppStorage(FontPrefs.lineHeight) private var lineHeight = FontPrefs.defaultLineHeight
    @AppStorage("syntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage("wrapLines") private var wrapLines = true
    @AppStorage(ThemePrefs.lightKey) private var lightTheme = ThemeStore.defaultLight
    @AppStorage(ThemePrefs.darkKey) private var darkTheme = ThemeStore.defaultDark
    @Environment(\.colorScheme) private var colorScheme

    /// Theme for the current appearance (light/dark chosen separately in Settings).
    private var theme: SyntaxTheme {
        ThemeStore.shared.theme(named: colorScheme == .dark ? darkTheme : lightTheme)
    }

    private var codeBackground: Color { Color(nsColor: theme.background ?? .textBackgroundColor) }

    /// The change last jumped to (per file), for ⌥⌘↓/↑.
    @StateObject private var changeCursor = Box<(file: String, index: Int)?>(nil)
    /// False in a file's own window: change navigation then stays within the file.
    var showsFileList = true

    var body: some View {
        detail
            .onChange(of: tabWidth) { model.reloadDiff() }
            .onChange(of: syntaxHighlighting) { model.reloadDiff() }
            .onChange(of: lightTheme) { model.reloadDiff() }
            .onChange(of: darkTheme) { model.reloadDiff() }
            .onChange(of: colorScheme) { model.reloadDiff() }
    }

    @ViewBuilder
    private var detail: some View {
        if let change = model.selectedChange {
            VStack(spacing: 0) {
                header(change)
                Divider()
                fileNote(change)
                if let diff = model.rendered, diff.changeID == change.id {
                    content(diff, change: change)
                } else {
                    codeBackground
                }
            }
            // Images, binary files and empty diffs have no changes to step through: go on to
            // the adjacent file. (Text diffs handle the jump in their scroll view.)
            .onChange(of: model.changeJump) {
                guard let request = model.changeJump, let diff = model.rendered, diff.changeID == change.id,
                      diff.isBinary || diff.unified.isEmpty else { return }
                model.changeJump = nil
                if showsFileList { model.selectAdjacentFile(forward: request.forward,
                                                            landOn: request.forward ? .first : .last) }
            }
        } else {
            ContentUnavailableView("No File Selected", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func header(_ change: FileChange) -> some View {
        let target = RepoModel.fileTarget(path: change.path)
        return HStack(spacing: 8) {
            // Double-clicking the name annotates the file, like the speech-bubble button.
            HStack(spacing: 8) {
                if let old = change.oldPath {
                    Text(old).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                }
                Text(change.path).fontWeight(.semibold)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.editing = target }
            .help("Double-click to annotate this file")
            .contextMenu { FileOpenMenuItems(root: model.root, path: change.path) }
            Text(change.statusDescription)
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
            if let d = model.rendered, d.changeID == change.id, !d.isBinary, d.added + d.removed > 0 {
                Text("+\(d.added)").foregroundStyle(.green)
                Text("−\(d.removed)").foregroundStyle(.red)
            }
            Button { model.editing = target } label: {
                Image(systemName: model.annotation(path: change.path, key: nil) == nil
                      ? "text.bubble" : "text.bubble.fill")
            }
            .buttonStyle(.borderless)
            .help("Annotate this file")
            .popover(isPresented: model.editingBinding(target), arrowEdge: .bottom) {
                AnnotationEditor(model: model, target: target)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The note on the whole file, shown under the file header.
    @ViewBuilder
    private func fileNote(_ change: FileChange) -> some View {
        if let note = model.annotation(path: change.path, key: nil) {
            AnnotationNoteView(annotation: note, indent: 8,
                               onEdit: { model.editing = RepoModel.fileTarget(path: change.path) },
                               onDelete: { model.removeAnnotation(note) })
                .padding(.vertical, 2)
            Divider()
        }
    }

    @ViewBuilder
    private func content(_ diff: RenderedDiff, change: FileChange) -> some View {
        if diff.isBinary {
            BinaryPreview(root: model.root, change: change)
        } else if diff.unified.isEmpty {
            ContentUnavailableView("No Content Changes", systemImage: "doc",
                                   description: Text(Self.summary(diff.notes, change: change)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let nsFont = FontPrefs.diffFont(family: family, size: size)
            let digits = max(String(diff.maxLineNumber).count, 2)
            let gutter = CGFloat(digits) * FontPrefs.digitWidth(nsFont) + 12
            let font = Font(nsFont as CTFont)
            // A file without a diff (Show All Files) has one line-number column and no sides.
            let layout: DiffMode = change.isUnchanged ? .unified : mode

            // Without wrapping: stacked content is as wide as the longest line and scrolls sideways;
            // side-by-side keeps both halves on screen and cuts long lines off with "…".
            let lineMode: DiffLineMode = wrapLines ? .wrap : (layout == .split ? .truncate : .scroll)
            let codeWidth = CGFloat(diff.maxColumns) * FontPrefs.digitWidth(nsFont) + 16
            let column = FontPrefs.digitWidth(nsFont)
            let contentWidth = gutter * (change.isUnchanged ? 1 : 2) + 16 + column + codeWidth

            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(lineMode == .scroll ? [.vertical, .horizontal] : .vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !diff.notes.isEmpty {
                            Text(diff.notes.joined(separator: "\n"))
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                        switch layout {
                        case .unified:
                            ForEach(diff.unified) {
                                UnifiedRowView(model: model, path: change.path, row: $0, gutter: gutter,
                                               singleNumber: change.isUnchanged)
                            }
                        case .split:
                            ForEach(diff.split) {
                                SplitRowView(model: model, path: change.path, row: $0, gutter: gutter)
                            }
                        }
                    }
                    .coordinateSpace(.named(DiffLines.space))
                    .diffRowsStyle(font: font, size: size, lineHeight: lineHeight, column: column,
                                   theme: theme, lineMode: lineMode)
                    .frame(width: lineMode == .scroll ? max(viewport.size.width, contentWidth) : nil,
                           alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
                .background {
                    // Esc unmarks the marked lines.
                    if model.mark != nil {
                        Button("") { model.mark = nil }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                    }
                }
                .id("\(change.id)|\(layout.rawValue)|\(wrapLines)") // reset scroll on file/mode/wrap change
                .background(codeBackground)
                .onAppear {
                    scrollIfRequested(proxy, diff: diff, path: change.path, layout: layout)
                    landOnPendingChange(proxy, diff: diff, change: change, layout: layout)
                }
                .onChange(of: model.scrollRequest) {
                    scrollIfRequested(proxy, diff: diff, path: change.path, layout: layout)
                }
                .onChange(of: model.changeJump) {
                    jump(proxy, diff: diff, change: change, layout: layout)
                }
            }
            }
        }
    }

    // MARK: Change navigation

    /// Rows where a run of changed lines starts, in the current layout.
    private static func changeStarts(_ diff: RenderedDiff, layout: DiffMode) -> [Int] {
        var starts: [Int] = []
        var inChange = false
        switch layout {
        case .unified:
            for row in diff.unified {
                let changed = row.header == nil && row.kind != .context
                if changed && !inChange { starts.append(row.id) }
                inChange = changed
            }
        case .split:
            for row in diff.split {
                let changed = row.header == nil
                    && !(row.left?.kind == .context && row.right?.kind == .context)
                if changed && !inChange { starts.append(row.id) }
                inChange = changed
            }
        }
        return starts
    }

    private func scroll(_ proxy: ScrollViewProxy, to rowID: Int) {
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(rowID, anchor: UnitPoint(x: 0, y: 0.2)) }
        }
    }

    /// ⌥⌘↓/↑: the next/previous run of changes; past the last/first one, the adjacent file.
    private func jump(_ proxy: ScrollViewProxy, diff: RenderedDiff, change: FileChange, layout: DiffMode) {
        guard let request = model.changeJump else { return }
        model.changeJump = nil
        let starts = Self.changeStarts(diff, layout: layout)
        let current = changeCursor.value?.file == change.id ? changeCursor.value?.index : nil
        let index = request.forward ? (current.map { $0 + 1 } ?? 0) : (current ?? starts.count) - 1
        guard starts.indices.contains(index) else {
            if showsFileList { model.selectAdjacentFile(forward: request.forward,
                                                        landOn: request.forward ? .first : .last) }
            else { NSSound.beep() }
            return
        }
        changeCursor.value = (change.id, index)
        scroll(proxy, to: starts[index])
    }

    /// After moving to another file: land on its first (or last) change.
    private func landOnPendingChange(_ proxy: ScrollViewProxy, diff: RenderedDiff, change: FileChange, layout: DiffMode) {
        guard let anchor = model.pendingChangeAnchor else { return }
        model.pendingChangeAnchor = nil
        let starts = Self.changeStarts(diff, layout: layout)
        guard let index = anchor == .first ? starts.indices.first : starts.indices.last else { return }
        changeCursor.value = (change.id, index)
        scroll(proxy, to: starts[index])
    }

    /// Plain-language description of a change that has no content diff (rename, mode change, empty file).
    static func summary(_ notes: [String], change: FileChange) -> String {
        func value(_ prefix: String) -> String? {
            notes.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        var lines: [String] = []
        if let old = change.oldPath {
            lines.append(change.status == "C" ? "Copied from \(old) without changes." : "Renamed from \(old) without changes.")
        }
        if let from = value("old mode"), let to = value("new mode") {
            lines.append("File mode changed from \(from) to \(to).")
        }
        if value("new file mode") != nil { lines.append("Empty file added.") }
        if value("deleted file mode") != nil { lines.append("Empty file deleted.") }
        return lines.isEmpty ? "The diff is empty." : lines.joined(separator: "\n")
    }

    /// Jump to an annotated line when one is picked in the annotations pane.
    private func scrollIfRequested(_ proxy: ScrollViewProxy, diff: RenderedDiff, path: String, layout: DiffMode) {
        guard let req = model.scrollRequest, req.path == path else { return }
        guard req.key != nil else { model.scrollRequest = nil; return }   // file note: no line
        let rowID: Int? = switch layout {
        case .unified: diff.unified.first { $0.key == req.key }?.id
        case .split: diff.split.first { $0.left?.key == req.key || $0.right?.key == req.key }?.id
        }
        model.scrollRequest = nil
        guard let rowID else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(rowID, anchor: .center) }
        }
    }
}

// MARK: - Rows

private struct HunkHeaderView: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiffStyle.hunkBG)
    }
}

private struct DiffLinePaddingKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct DiffColumnWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 8
}

private struct DiffLineNumberColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

/// How long diff lines are shown.
enum DiffLineMode {
    case wrap       // wrap onto following lines
    case scroll     // one line, the view scrolls sideways
    case truncate   // one line, cut off with "…" (side by side without wrapping)
}

private struct DiffAnnotatableKey: EnvironmentKey {
    static let defaultValue = true
}

private struct DiffLineModeKey: EnvironmentKey {
    static let defaultValue = DiffLineMode.wrap
}

extension View {
    /// Font, line height, theme colors and line mode for diff rows.
    func diffRowsStyle(font: Font, size: Double, lineHeight: Double, column: CGFloat,
                       theme: SyntaxTheme, lineMode: DiffLineMode) -> some View {
        self.font(font)
            // Line height: extra space split above/below each row, and between wrapped lines.
            .lineSpacing((lineHeight - 1) * size)
            .environment(\.diffLinePadding, (lineHeight - 1) * size / 2)
            .environment(\.diffColumnWidth, column)
            .environment(\.diffLineNumberColor, theme.lineNumber.map { Color(nsColor: $0) })
            .foregroundStyle(theme.text.map { Color(nsColor: $0) } ?? Color.primary)
            .environment(\.diffLineMode, lineMode)
    }

    /// Applies the current line mode to a line of diff text.
    func diffLine(_ mode: DiffLineMode) -> some View {
        lineLimit(mode == .wrap ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: mode == .scroll, vertical: false)
    }
}

extension EnvironmentValues {
    /// Width of one character column of the diff font: the gap between the +/− marker and the code.
    var diffColumnWidth: CGFloat {
        get { self[DiffColumnWidthKey.self] }
        set { self[DiffColumnWidthKey.self] = newValue }
    }

    /// Vertical padding above and below each diff line (from the line height setting).
    var diffLinePadding: CGFloat {
        get { self[DiffLinePaddingKey.self] }
        set { self[DiffLinePaddingKey.self] = newValue }
    }

    /// False for commits in the history: lines can't be marked or annotated, and the working
    /// tree's notes aren't shown on them.
    var diffAnnotatable: Bool {
        get { self[DiffAnnotatableKey.self] }
        set { self[DiffAnnotatableKey.self] = newValue }
    }

    /// How long diff lines are shown (wrap / scroll sideways / truncate).
    var diffLineMode: DiffLineMode {
        get { self[DiffLineModeKey.self] }
        set { self[DiffLineModeKey.self] = newValue }
    }

    /// Line number color from the syntax theme (nil = system tertiary).
    var diffLineNumberColor: Color? {
        get { self[DiffLineNumberColorKey.self] }
        set { self[DiffLineNumberColorKey.self] = newValue }
    }
}

/// A changed line's background: stronger tint behind the line numbers and marker, lighter
/// behind the code.
private struct GutterBackground: View {
    let kind: RowKind
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            DiffStyle.gutterBackground(kind).frame(width: width)
            DiffStyle.background(kind)
        }
    }
}

private struct LineNumber: View {
    let number: Int?
    let width: CGFloat
    /// Overrides the theme's line-number color (on a changed line's tinted gutter).
    var tint: Color? = nil
    @Environment(\.diffLineNumberColor) private var color
    var body: some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

/// Click marks a line, dragging marks several, double-click (or right-click → Annotate) opens
/// the annotation popover for the marked lines.
private struct AnnotatableLine: ViewModifier {
    @ObservedObject var model: RepoModel
    let target: EditTarget
    let text: AttributedString
    @StateObject private var hovered = Box(false)
    @StateObject private var pressed = Box(false)
    @Environment(\.diffAnnotatable) private var annotatable

    @ViewBuilder
    func body(content: Content) -> some View {
        if annotatable { annotatableBody(content) } else { content }
    }

    private func annotatableBody(_ content: Content) -> some View {
        let marked = model.isMarked(target)
        return content
            .overlay(Color.accentColor.opacity(marked ? 0.2 : 0).allowsHitTesting(false))
            // Marked lines: a solid bar down the left edge.
            .overlay(alignment: .leading) {
                if marked { Rectangle().fill(Color.accentColor).frame(width: 5).allowsHitTesting(false) }
            }
            .overlay(Color.primary.opacity(hovered.value ? 0.06 : 0).allowsHitTesting(false))
            .onHover { hovered.value = $0 }
            .contentShape(Rectangle())
            // Remember where the line is, to find the line under the pointer while dragging.
            .onGeometryChange(for: LineFrame.self) {
                LineFrame(frame: $0.frame(in: .named(DiffLines.space)), target: target)
            } action: {
                model.lineFrames[LineSlot(rowID: target.rowID, column: target.column)] = $0
            }
            .onDisappear { model.lineFrames[LineSlot(rowID: target.rowID, column: target.column)] = nil }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(DiffLines.space))
                    .onChanged { drag in
                        if !pressed.value {
                            pressed.value = true
                            model.lineMouseDown(target)
                        } else if abs(drag.translation.height) > 2 || abs(drag.translation.width) > 2 {
                            model.lineDragged(to: drag.location)
                        }
                    }
                    .onEnded { _ in pressed.value = false }
            )
            .contextMenu {
                let annotating = marked ? (model.markedTarget ?? target) : target
                Button(model.annotation(path: annotating.path, key: annotating.key,
                                        endLine: annotating.endLine) == nil
                       ? "Add Annotation…" : "Edit Annotation…") { model.annotate(at: target) }
                if marked, model.markedTarget?.endLine != nil {
                    Button("Copy Lines") { model.copyMarkedCode() }
                } else {
                    Button("Copy Line") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(text.characters), forType: .string)
                    }
                }
            }
            .popover(isPresented: model.editingBinding(target), arrowEdge: .bottom) {
                let editing = model.editing ?? target
                AnnotationEditor(model: model, target: editing)
                    .id("\(editing.key?.line ?? 0)-\(editing.endLine ?? 0)")
            }
    }
}

/// The diff's content coordinate space (line frames and drag locations).
enum DiffLines {
    static let space = "diffLines"
}

/// Orange bar at the left edge of a line that belongs to a range note.
private struct RangeMarker: View {
    let visible: Bool
    var body: some View {
        if visible { Rectangle().fill(Color.orange).frame(width: 3) }
    }
}

struct UnifiedRowView: View {
    @ObservedObject var model: RepoModel
    @Environment(\.diffAnnotatable) private var annotatable
    @Environment(\.diffLinePadding) private var linePadding
    @Environment(\.diffColumnWidth) private var columnWidth
    @Environment(\.diffLineMode) private var lineMode
    let path: String
    let row: UnifiedRow
    let gutter: CGFloat
    /// One line-number column (file shown without a diff) instead of old + new.
    var singleNumber = false

    var body: some View {
        if let header = row.header {
            HunkHeaderView(text: header)
        } else if let key = row.key {
            let target = EditTarget(path: path, key: key, rowID: row.id, column: 0)
            VStack(spacing: 0) {
                let numberTint = DiffStyle.gutterText(row.kind)
                HStack(alignment: .top, spacing: 0) {
                    if !singleNumber { LineNumber(number: row.oldNo, width: gutter, tint: numberTint) }
                    LineNumber(number: row.newNo, width: gutter, tint: numberTint)
                    Text(DiffStyle.marker(row.kind))
                        .foregroundStyle(numberTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    Text(row.text)
                        .diffLine(lineMode)
                        .padding(.leading, columnWidth)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, linePadding)
                .background(GutterBackground(kind: row.kind,
                                             width: (gutter + 4) * (singleNumber ? 1 : 2) + 16))
                .overlay(alignment: .leading) {
                    RangeMarker(visible: annotatable && model.isInRange(path: path, key: key))
                }
                .modifier(AnnotatableLine(model: model, target: target, text: row.text))

                ForEach(annotatable ? model.notesEnding(path: path, key: key) : []) { note in
                    AnnotationNoteView(annotation: note, indent: gutter * (singleNumber ? 1 : 2) + 24 + columnWidth,
                                       onEdit: { model.editing = EditTarget(path: path, key: note.key, rowID: row.id,
                                                                            column: 0, endLine: note.endLine) },
                                       onDelete: { model.removeAnnotation(note) })
                }
            }
        }
    }
}

struct SplitRowView: View {
    @ObservedObject var model: RepoModel
    @Environment(\.diffAnnotatable) private var annotatable
    @Environment(\.diffColumnWidth) private var columnWidth
    let path: String
    let row: SplitRow
    let gutter: CGFloat

    var body: some View {
        if let header = row.header {
            HunkHeaderView(text: header)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SideCellView(model: model, path: path, rowID: row.id, column: 1, cell: row.left, gutter: gutter)
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                    SideCellView(model: model, path: path, rowID: row.id, column: 2, cell: row.right, gutter: gutter)
                }
                .fixedSize(horizontal: false, vertical: true) // both halves take the taller height

                if annotatable { notes }
            }
        }
    }

    /// Notes sit under the half they belong to; an unchanged line's note spans both.
    @ViewBuilder
    private var notes: some View {
        let left = row.left.map { model.notesEnding(path: path, key: $0.key) } ?? []
        let right = row.right.map { model.notesEnding(path: path, key: $0.key) } ?? []
        if !left.isEmpty, left == right {
            ForEach(left) { note($0, column: 1) }
        } else if !left.isEmpty || !right.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) { ForEach(left) { note($0, column: 1) } }
                    .frame(maxWidth: .infinity)
                VStack(spacing: 0) { ForEach(right) { note($0, column: 2) } }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func note(_ a: Annotation, column: Int) -> some View {
        AnnotationNoteView(annotation: a, indent: gutter + 22 + columnWidth,
                           onEdit: { model.editing = EditTarget(path: path, key: a.key, rowID: row.id,
                                                                column: column, endLine: a.endLine) },
                           onDelete: { model.removeAnnotation(a) })
    }
}

private struct SideCellView: View {
    @ObservedObject var model: RepoModel
    @Environment(\.diffAnnotatable) private var annotatable
    @Environment(\.diffLinePadding) private var linePadding
    @Environment(\.diffColumnWidth) private var columnWidth
    @Environment(\.diffLineMode) private var lineMode
    let path: String
    let rowID: Int
    let column: Int
    let cell: SideCell?
    let gutter: CGFloat

    var body: some View {
        if let cell {
            let numberTint = DiffStyle.gutterText(cell.kind)
            HStack(alignment: .top, spacing: 0) {
                LineNumber(number: cell.number, width: gutter, tint: numberTint)
                Text(DiffStyle.marker(cell.kind))
                    .foregroundStyle(numberTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                    .frame(width: 14)
                Text(cell.text)
                    .diffLine(lineMode)
                    .padding(.leading, columnWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, linePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(GutterBackground(kind: cell.kind, width: gutter + 4 + 14))
            .overlay(alignment: .leading) {
                RangeMarker(visible: annotatable && model.isInRange(path: path, key: cell.key))
            }
            .modifier(AnnotatableLine(
                model: model,
                target: EditTarget(path: path, key: cell.key, rowID: rowID, column: column),
                text: cell.text))
        } else {
            DiffStyle.fillerBG
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
