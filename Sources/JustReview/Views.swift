import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle
    /// File list + annotations pane; off for a tab dragged out on its own (just the diff).
    var showsChrome = true
    @AppStorage("diffMode") private var mode: DiffMode = .unified
    @AppStorage("wrapLines") private var wrapLines = true

    /// The diff with its toolbar items. They're declared on the detail column itself so they
    /// (and the spacer pushing the buttons right) land in the detail part of the toolbar.
    private var diffView: some View {
        DiffDetailView(model: model, mode: mode)
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
                        FileListView(model: model, handle: handle)
                            .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 500)
                            .toolbar(removing: .sidebarToggle)
                    } detail: {
                        diffView
                    }
                    AnnotationsPane(model: model)
                }
            } else {
                diffView
            }
        }
        // The toolbar's tinted detail section doesn't line up with the split view's divider
        // on recent macOS; hiding the toolbar background removes the misaligned edge.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The window title names the file (it labels the native tab) but isn't drawn in the
        // toolbar; the toolbar shows the repository and its branch instead.
        .navigationTitle(model.selection.map { ($0 as NSString).lastPathComponent } ?? model.repoName)
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

// MARK: - File list

struct FileListView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle
    @AppStorage(FontPrefs.listFamily) private var family = ""
    @AppStorage(FontPrefs.listSize) private var size = FontPrefs.defaultListSize
    @AppStorage("showAllFiles") private var showAll = false
    @Environment(\.openWindow) private var openWindow

    /// A new native tab of this repository showing `path` (drag the tab out for its own window).
    private func openInNewTab(_ path: String) {
        guard let root = model.root else { return }
        WindowRouter.shared.openTab(root: root, file: path, from: handle)
    }

    /// Folders the user expanded/collapsed by hand; others use the default (see `isExpanded`).
    @StateObject private var expansion = Box<[String: Bool]>([:])

    var body: some View {
        let font = Font(FontPrefs.listFont(family: family, size: size) as CTFont)
        let tree = FileTree.build(model.changes + (showAll ? model.unchanged : []))
        ScrollViewReader { proxy in
        List(selection: listSelection) {
            FileTreeRows(nodes: tree, font: font, size: size, isExpanded: isExpanded)
        }
        // Reveal this tab's file when the tab/window becomes active or shows another file
        // (and once the list has loaded, for a new tab whose file wasn't listed yet).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === handle.window { reveal(model.selection, in: tree, proxy: proxy) }
        }
        .onChange(of: model.selection) { reveal(model.selection, in: tree, proxy: proxy) }
        .onChange(of: tree.count + model.changes.count + model.unchanged.count) {
            if pendingReveal.value { reveal(model.selection, in: tree, proxy: proxy) }
        }
        // Double-click (or Return) opens the file in a new native tab.
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first {
                Button("Open in New Tab") { openInNewTab(path) }
                Button("Open in New Window") {
                    if let root = model.root { openWindow(value: RepoTab(root: root.path, file: path, standalone: true)) }
                }
            }
        } primaryAction: { paths in
            paths.forEach(openInNewTab)
        }
        .onChange(of: showAll) { Task { await model.refresh() } }
        // File-list controls live in the sidebar's part of the toolbar (right-aligned).
        .toolbar {
            ToolbarItemGroup {
                Spacer()
                Toggle(isOn: $showAll) {
                    Label("Show All Files", systemImage: "list.bullet.indent")
                }
                .toggleStyle(.button)
                .help("Show all files, not just changed ones (⇧⌘A)")

                Button { WindowRouter.shared.chooseRepository(preferring: handle) } label: {
                    Label("Open Repository", systemImage: "folder")
                }
                .help("Open Repository (⌘O)")
            }
        }
        }
        .overlay {
            if model.root == nil {
                ContentUnavailableView {
                    Label("No Repository", systemImage: "folder")
                } description: {
                    Text("Open a git repository, drop a folder here, or run “jrev” in a repository.")
                } actions: {
                    Button("Open Repository…") { WindowRouter.shared.chooseRepository(preferring: handle) }
                }
            } else if model.changes.isEmpty && !showAll {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                       description: Text("Nothing differs from HEAD."))
            }
        }
    }

    @StateObject private var pendingReveal = Box(false)

    /// Clicking a file another tab already shows switches to that tab instead of duplicating it.
    private var listSelection: Binding<String?> {
        Binding(
            get: { model.selection },
            set: { path in
                if let path, let root = model.root,
                   let other = WindowRouter.shared.existingTab(root: root, file: path, excluding: handle) {
                    WindowRouter.shared.show(other)
                    model.objectWillChange.send()   // snap this list back to its own file
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
    let isExpanded: (FileTreeNode) -> Binding<Bool>

    var body: some View {
        ForEach(nodes) { node in
            if let change = node.change {
                FileRow(change: change, font: font, size: size).tag(change.id)
            } else {
                DisclosureGroup(isExpanded: isExpanded(node)) {
                    FileTreeRows(nodes: node.children, font: font, size: size, isExpanded: isExpanded)
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

    var body: some View {
        HStack(spacing: 7) {
            Text(change.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(change.isUnchanged ? .secondary : .primary)
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
        } else {
            ContentUnavailableView("No File Selected", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func header(_ change: FileChange) -> some View {
        HStack(spacing: 8) {
            if let old = change.oldPath {
                Text(old).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
            }
            Text(change.path).fontWeight(.semibold)
            Text(change.statusDescription)
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
            if let d = model.rendered, d.changeID == change.id, !d.isBinary, d.added + d.removed > 0 {
                Text("+\(d.added)").foregroundStyle(.green)
                Text("−\(d.removed)").foregroundStyle(.red)
            }
            let target = RepoModel.fileTarget(path: change.path)
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
            ContentUnavailableView("Binary File", systemImage: "doc.zipper",
                                   description: Text("Binary files can’t be shown as text."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            let contentWidth = gutter * (change.isUnchanged ? 1 : 2) + 16 + codeWidth

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
                    .font(font)
                    // Line height: extra space split above/below each row, and between wrapped lines.
                    .lineSpacing((lineHeight - 1) * size)
                    .environment(\.diffLinePadding, (lineHeight - 1) * size / 2)
                    .environment(\.diffLineNumberColor, theme.lineNumber.map { Color(nsColor: $0) })
                    .foregroundStyle(theme.text.map { Color(nsColor: $0) } ?? Color.primary)
                    .environment(\.diffLineMode, lineMode)
                    .frame(width: lineMode == .scroll ? max(viewport.size.width, contentWidth) : nil,
                           alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
                .id("\(change.id)|\(layout.rawValue)|\(wrapLines)") // reset scroll on file/mode/wrap change
                .background(codeBackground)
                .onAppear { scrollIfRequested(proxy, diff: diff, path: change.path, layout: layout) }
                .onChange(of: model.scrollRequest) {
                    scrollIfRequested(proxy, diff: diff, path: change.path, layout: layout)
                }
            }
            }
        }
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

private struct DiffLineNumberColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

/// How long diff lines are shown.
enum DiffLineMode {
    case wrap       // wrap onto following lines
    case scroll     // one line, the view scrolls sideways
    case truncate   // one line, cut off with "…" (side by side without wrapping)
}

private struct DiffLineModeKey: EnvironmentKey {
    static let defaultValue = DiffLineMode.wrap
}

extension View {
    /// Applies the current line mode to a line of diff text.
    func diffLine(_ mode: DiffLineMode) -> some View {
        lineLimit(mode == .wrap ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: mode == .scroll, vertical: false)
    }
}

extension EnvironmentValues {
    /// Vertical padding above and below each diff line (from the line height setting).
    var diffLinePadding: CGFloat {
        get { self[DiffLinePaddingKey.self] }
        set { self[DiffLinePaddingKey.self] = newValue }
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

private struct LineNumber: View {
    let number: Int?
    let width: CGFloat
    @Environment(\.diffLineNumberColor) private var color
    var body: some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

/// Click (or right-click → Annotate) opens the annotation popover for a line.
private struct AnnotatableLine: ViewModifier {
    @ObservedObject var model: RepoModel
    let target: EditTarget
    let text: AttributedString
    @StateObject private var hovered = Box(false)

    func body(content: Content) -> some View {
        content
            .overlay(Color.primary.opacity(hovered.value ? 0.06 : 0).allowsHitTesting(false))
            .onHover { hovered.value = $0 }
            .contentShape(Rectangle())
            .onTapGesture { model.editing = target }
            .contextMenu {
                Button(model.annotation(path: target.path, key: target.key) == nil
                       ? "Add Annotation…" : "Edit Annotation…") { model.editing = target }
                Button("Copy Line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(text.characters), forType: .string)
                }
            }
            .popover(isPresented: model.editingBinding(target), arrowEdge: .bottom) {
                AnnotationEditor(model: model, target: target)
            }
    }
}

struct UnifiedRowView: View {
    @ObservedObject var model: RepoModel
    @Environment(\.diffLinePadding) private var linePadding
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
                HStack(alignment: .top, spacing: 0) {
                    if !singleNumber { LineNumber(number: row.oldNo, width: gutter) }
                    LineNumber(number: row.newNo, width: gutter)
                    Text(DiffStyle.marker(row.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(row.text)
                        .diffLine(lineMode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, linePadding)
                .background(DiffStyle.background(row.kind))
                .modifier(AnnotatableLine(model: model, target: target, text: row.text))

                if let note = model.annotation(path: path, key: key) {
                    AnnotationNoteView(annotation: note, indent: gutter * (singleNumber ? 1 : 2) + 24,
                                       onEdit: { model.editing = target },
                                       onDelete: { model.removeAnnotation(note) })
                }
            }
        }
    }
}

struct SplitRowView: View {
    @ObservedObject var model: RepoModel
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

                notes
            }
        }
    }

    /// Notes sit under the half they belong to; an unchanged line's note spans both.
    @ViewBuilder
    private var notes: some View {
        let left = row.left.flatMap { model.annotation(path: path, key: $0.key) }
        let right = row.right.flatMap { model.annotation(path: path, key: $0.key) }
        if let left, left == right {
            note(left, column: 1)
        } else if left != nil || right != nil {
            HStack(alignment: .top, spacing: 0) {
                Group {
                    if let left { note(left, column: 1) } else { Color.clear.frame(height: 0) }
                }
                .frame(maxWidth: .infinity)
                Group {
                    if let right { note(right, column: 2) } else { Color.clear.frame(height: 0) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func note(_ a: Annotation, column: Int) -> some View {
        AnnotationNoteView(annotation: a, indent: gutter + 22,
                           onEdit: { model.editing = EditTarget(path: path, key: a.key, rowID: row.id, column: column) },
                           onDelete: { model.removeAnnotation(a) })
    }
}

private struct SideCellView: View {
    @ObservedObject var model: RepoModel
    @Environment(\.diffLinePadding) private var linePadding
    @Environment(\.diffLineMode) private var lineMode
    let path: String
    let rowID: Int
    let column: Int
    let cell: SideCell?
    let gutter: CGFloat

    var body: some View {
        if let cell {
            HStack(alignment: .top, spacing: 0) {
                LineNumber(number: cell.number, width: gutter)
                Text(DiffStyle.marker(cell.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(cell.text)
                    .diffLine(lineMode)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, linePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DiffStyle.background(cell.kind))
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
