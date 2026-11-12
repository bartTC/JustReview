import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle
    @AppStorage("diffMode") private var mode: DiffMode = .unified

    var body: some View {
        // Annotations pane sits below the split view and takes real space
        // (a safe-area inset would let the split view's columns scroll underneath it).
        VStack(spacing: 0) {
            NavigationSplitView {
                FileListView(model: model, handle: handle)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 500)
            } detail: {
                DiffDetailView(model: model, mode: mode)
            }
            AnnotationsPane(model: model)
        }
        // The toolbar's tinted detail section doesn't line up with the split view's divider
        // on recent macOS; hiding the toolbar background removes the misaligned edge.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(model.repoName)
        .navigationSubtitle(model.branch)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Layout", selection: $mode) {
                    Label("Stacked", systemImage: "rectangle.split.1x2").tag(DiffMode.unified)
                    Label("Side by Side", systemImage: "rectangle.split.2x1").tag(DiffMode.split)
                }
                .pickerStyle(.segmented)
                .help("Stacked (⌘1) / Side by side (⌘2)")

                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
                .disabled(model.root == nil)

                Button { WindowRouter.shared.chooseRepository(preferring: handle) } label: {
                    Label("Open Repository", systemImage: "folder")
                }
                .help("Open Repository (⌘O)")
            }
        }
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

// MARK: - File list

struct FileListView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle
    @AppStorage(FontPrefs.listFamily) private var family = ""
    @AppStorage(FontPrefs.listSize) private var size = FontPrefs.defaultListSize

    var body: some View {
        let font = Font(FontPrefs.listFont(family: family, size: size) as CTFont)
        List(model.changes, selection: $model.selection) { change in
            FileRow(change: change, font: font, size: size).tag(change.id)
        }
        .overlay {
            if model.root == nil {
                ContentUnavailableView {
                    Label("No Repository", systemImage: "folder")
                } description: {
                    Text("Open a git repository, drop a folder here, or run “jrev” in a repository.")
                } actions: {
                    Button("Open Repository…") { WindowRouter.shared.chooseRepository(preferring: handle) }
                    if let last = UserDefaults.standard.string(forKey: "lastRepo") {
                        Button("Open “\((last as NSString).lastPathComponent)”") {
                            WindowRouter.shared.open(URL(fileURLWithPath: last), preferring: handle)
                        }
                    }
                }
            } else if model.changes.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                       description: Text("Nothing differs from HEAD."))
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
            StatusBadge(label: change.statusLabel, size: size)
            Text(change.fileName)
                .lineLimit(1)
            if !change.directory.isEmpty {
                Text(change.directory)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
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
        let box = (size * 1.15).rounded()
        Text(label)
            .font(.system(size: size * 0.68, weight: .semibold, design: .rounded))
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

    var body: some View {
        detail.onChange(of: tabWidth) { model.reloadDiff() }
    }

    @ViewBuilder
    private var detail: some View {
        if let change = model.selectedChange {
            VStack(spacing: 0) {
                header(change)
                Divider()
                if let diff = model.rendered, diff.changeID == change.id {
                    content(diff, change: change)
                } else {
                    Color(nsColor: .textBackgroundColor)
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
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !diff.notes.isEmpty {
                            Text(diff.notes.joined(separator: "\n"))
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                        switch mode {
                        case .unified:
                            ForEach(diff.unified) {
                                UnifiedRowView(model: model, path: change.path, row: $0, gutter: gutter)
                            }
                        case .split:
                            ForEach(diff.split) {
                                SplitRowView(model: model, path: change.path, row: $0, gutter: gutter)
                            }
                        }
                    }
                    .font(font)
                }
                .id("\(change.id)|\(mode.rawValue)") // reset scroll position on file/mode change
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear { scrollIfRequested(proxy, diff: diff, path: change.path) }
                .onChange(of: model.scrollRequest) { scrollIfRequested(proxy, diff: diff, path: change.path) }
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
    private func scrollIfRequested(_ proxy: ScrollViewProxy, diff: RenderedDiff, path: String) {
        guard let req = model.scrollRequest, req.path == path else { return }
        let rowID: Int? = switch mode {
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

private struct LineNumber: View {
    let number: Int?
    let width: CGFloat
    var body: some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

/// Double-click (or right-click → Annotate) opens the annotation popover for a line.
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
            .onTapGesture(count: 2) { model.editing = target }
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
    let path: String
    let row: UnifiedRow
    let gutter: CGFloat

    var body: some View {
        if let header = row.header {
            HunkHeaderView(text: header)
        } else if let key = row.key {
            let target = EditTarget(path: path, key: key, rowID: row.id, column: 0)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    LineNumber(number: row.oldNo, width: gutter)
                    LineNumber(number: row.newNo, width: gutter)
                    Text(DiffStyle.marker(row.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(row.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DiffStyle.background(row.kind))
                .modifier(AnnotatableLine(model: model, target: target, text: row.text))

                if let note = model.annotation(path: path, key: key) {
                    AnnotationNoteView(annotation: note, indent: gutter * 2 + 24,
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
