import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RepoModel
    @AppStorage("diffMode") private var mode: DiffMode = .unified

    var body: some View {
        NavigationSplitView {
            FileListView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 500)
        } detail: {
            DiffDetailView(model: model, mode: mode)
        }
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

                Button { model.chooseRepository() } label: {
                    Label("Open Repository", systemImage: "folder")
                }
                .help("Open Repository (⌘O)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.open(url, reportErrors: true) }
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
        .task { await model.openInitial() }
    }
}

// MARK: - File list

struct FileListView: View {
    @ObservedObject var model: RepoModel
    @AppStorage(FontPrefs.listFamily) private var family = ""
    @AppStorage(FontPrefs.listSize) private var size = FontPrefs.defaultListSize

    var body: some View {
        let font = Font(FontPrefs.listFont(family: family, size: size) as CTFont)
        List(model.changes, selection: $model.selection) { change in
            FileRow(change: change, font: font).tag(change.id)
        }
        .overlay {
            if model.root == nil {
                ContentUnavailableView {
                    Label("No Repository", systemImage: "folder")
                } description: {
                    Text("Open a git repository or drop a folder here.")
                } actions: {
                    Button("Open Repository…") { model.chooseRepository() }
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

    var body: some View {
        HStack(spacing: 6) {
            Text(change.statusLabel)
                .font(font.monospaced().bold())
                .foregroundStyle(statusColor)
                .frame(minWidth: 14)
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

    private var statusColor: Color {
        switch change.status {
        case "A", "?": return .green
        case "D", "U": return .red
        case "R", "C": return .blue
        case "T": return .purple
        default: return .orange
        }
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
            if let d = model.rendered, d.changeID == change.id, !d.isBinary {
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
        } else if diff.unified.isEmpty {
            ContentUnavailableView("No Content Changes", systemImage: "doc",
                                   description: Text(diff.notes.isEmpty ? "The diff is empty." : diff.notes.joined(separator: "\n")))
        } else {
            let nsFont = FontPrefs.diffFont(family: family, size: size)
            let digits = max(String(diff.maxLineNumber).count, 2)
            let gutter = CGFloat(digits) * FontPrefs.digitWidth(nsFont) + 12
            let font = Font(nsFont as CTFont)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !diff.notes.isEmpty {
                        Text(diff.notes.joined(separator: "\n"))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    switch mode {
                    case .unified:
                        ForEach(diff.unified) { UnifiedRowView(row: $0, gutter: gutter) }
                    case .split:
                        ForEach(diff.split) { SplitRowView(row: $0, gutter: gutter) }
                    }
                }
                .font(font)
            }
            .id("\(change.id)|\(mode.rawValue)") // reset scroll position on file/mode change
            .background(Color(nsColor: .textBackgroundColor))
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

struct UnifiedRowView: View {
    let row: UnifiedRow
    let gutter: CGFloat

    var body: some View {
        if let header = row.header {
            HunkHeaderView(text: header)
        } else {
            HStack(alignment: .top, spacing: 0) {
                LineNumber(number: row.oldNo, width: gutter)
                LineNumber(number: row.newNo, width: gutter)
                Text(DiffStyle.marker(row.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(row.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DiffStyle.background(row.kind))
        }
    }
}

struct SplitRowView: View {
    let row: SplitRow
    let gutter: CGFloat

    var body: some View {
        if let header = row.header {
            HunkHeaderView(text: header)
        } else {
            HStack(spacing: 0) {
                SideCellView(cell: row.left, gutter: gutter)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                SideCellView(cell: row.right, gutter: gutter)
            }
            .fixedSize(horizontal: false, vertical: true) // both halves take the taller height
        }
    }
}

private struct SideCellView: View {
    let cell: SideCell?
    let gutter: CGFloat

    var body: some View {
        Group {
            if let cell {
                HStack(alignment: .top, spacing: 0) {
                    LineNumber(number: cell.number, width: gutter)
                    Text(DiffStyle.marker(cell.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(cell.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cell.map { DiffStyle.background($0.kind) } ?? DiffStyle.fillerBG)
    }
}
