import SwiftUI

// MARK: - History list

/// The History tab: the newest commits, the selected one shown in the diff area.
struct HistoryListView: View {
    @ObservedObject var model: RepoModel
    let handle: WindowHandle
    @AppStorage(FontPrefs.listFamily) private var family = ""
    @AppStorage(FontPrefs.listSize) private var size = FontPrefs.defaultListSize

    var body: some View {
        let font = Font(FontPrefs.listFont(family: family, size: size) as CTFont)
        ScrollViewReader { proxy in
            List(selection: $model.selectedCommit) {
                ForEach(model.commits) { CommitRow(commit: $0, font: font, size: size).tag($0.id) }
                if model.historyHasMore {
                    Button("Load Older Commits") { Task { await model.loadMoreHistory() } }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("Copy Commit Hash") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    }
                }
            }
            .onAppear {
                if let id = model.selectedCommit { proxy.scrollTo(id) }
            }
        }
        .task(id: model.root) {
            if !model.historyLoaded { await model.loadHistory() }
        }
        .toolbar {
            ToolbarItemGroup {
                Spacer()
                OpenRepositoryButton(handle: handle)
            }
        }
        .overlay {
            if model.root == nil {
                NoRepositoryView(handle: handle)
            } else if model.historyLoaded && model.commits.isEmpty {
                ContentUnavailableView("No Commits", systemImage: "clock",
                                       description: Text("This repository has no commits yet."))
            }
        }
    }
}

/// A commit in the list: subject, then branches/tags, short hash, author and age.
private struct CommitRow: View {
    let commit: Commit
    let font: Font
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                Text(commit.shortHash).monospaced().fixedSize()
                // Branches and tags in one pill that gives way first when space is short.
                if !refNames.isEmpty {
                    Text(refNames.joined(separator: ", "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .layoutPriority(-1)
                }
                Text(commit.author).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(commit.date, format: .relative(presentation: .named))
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: size * 0.82))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help("\(commit.subject)\n\(commit.author), \(commit.date.formatted(date: .long, time: .shortened))")
    }

    /// Branch and tag names, without git's "HEAD -> " and "tag: " prefixes.
    private var refNames: [String] {
        commit.refs.compactMap { ref in
            if ref == "HEAD" { return nil }
            if ref.hasPrefix("HEAD -> ") { return String(ref.dropFirst("HEAD -> ".count)) }
            if ref.hasPrefix("tag: ") { return String(ref.dropFirst("tag: ".count)) }
            return ref
        }
    }
}

// MARK: - Commit detail

/// A commit in the diff area: its message, then every file it changed, one after another.
/// Read-only: nothing here can be annotated.
struct CommitDetailView: View {
    @ObservedObject var model: RepoModel
    let mode: DiffMode
    @AppStorage(FontPrefs.diffFamily) private var family = ""
    @AppStorage(FontPrefs.diffSize) private var size = FontPrefs.defaultDiffSize
    @AppStorage(FontPrefs.tabWidth) private var tabWidth = FontPrefs.defaultTabWidth
    @AppStorage(FontPrefs.lineHeight) private var lineHeight = FontPrefs.defaultLineHeight
    @AppStorage("syntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage("wrapLines") private var wrapLines = true
    @AppStorage(DiffContext.key) private var contextLines = DiffContext.standard
    @AppStorage(ThemePrefs.lightKey) private var lightTheme = ThemeStore.defaultLight
    @AppStorage(ThemePrefs.darkKey) private var darkTheme = ThemeStore.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    /// Files folded away by clicking their header.
    @StateObject private var collapsed = Box<Set<String>>([])
    /// How far the content is scrolled sideways (unwrapped lines); headers move along.
    @StateObject private var scrollX = Box<CGFloat>(0)

    private var theme: SyntaxTheme {
        ThemeStore.shared.theme(named: colorScheme == .dark ? darkTheme : lightTheme)
    }

    private var codeBackground: Color { Color(nsColor: theme.background ?? .textBackgroundColor) }

    var body: some View {
        detail
            .onChange(of: model.selectedCommit) {
                collapsed.value = []
                scrollX.value = 0   // the new commit starts scrolled to the left edge
            }
            .onChange(of: tabWidth) { model.reloadDiff() }
            .onChange(of: syntaxHighlighting) { model.reloadDiff() }
            .onChange(of: lightTheme) { model.reloadDiff() }
            .onChange(of: darkTheme) { model.reloadDiff() }
            .onChange(of: colorScheme) { model.reloadDiff() }
            .onChange(of: contextLines) { model.reloadDiff() }
    }

    @ViewBuilder
    private var detail: some View {
        if let error = model.commitError {
            ContentUnavailableView("Can’t Show Commit", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if model.selectedCommit == nil {
            ContentUnavailableView("No Commit Selected", systemImage: "clock")
        } else if let commit = model.renderedCommit, commit.hash == model.selectedCommit {
            content(commit)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(codeBackground)
        }
    }

    private func content(_ commit: RenderedCommit) -> some View {
        let nsFont = FontPrefs.diffFont(family: family, size: size)
        let column = FontPrefs.digitWidth(nsFont)
        // One gutter width for every file, so the code lines up from file to file.
        let maxLine = commit.files.map(\.diff.maxLineNumber).max() ?? 0
        let gutter = CGFloat(max(String(maxLine).count, 2)) * column + 12
        let lineMode: DiffLineMode = wrapLines ? .wrap : (mode == .split ? .truncate : .scroll)
        let maxColumns = commit.files.map(\.diff.maxColumns).max() ?? 0
        let contentWidth = gutter * 2 + 16 + column + CGFloat(maxColumns) * column + 16

        let scrollsSideways = lineMode == .scroll

        // The divider keeps the scroll view off the window's top edge; touching it, AppKit lets
        // the content scroll under the (transparent) toolbar.
        return VStack(spacing: 0) {
            Divider()
            GeometryReader { viewport in
                ScrollView(scrollsSideways ? [.vertical, .horizontal] : .vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        CommitMessageView(commit: commit)
                            .stayInView(scrollsSideways, scrollX: scrollX.value, viewportWidth: viewport.size.width)
                        ForEach(commit.files) { file in
                            Section {
                                if !collapsed.value.contains(file.id) {
                                    fileContent(file, gutter: gutter, commit: commit)
                                }
                            } header: {
                                DiffFileHeader(file: file, collapsed: collapsed.value.contains(file.id)) {
                                    if collapsed.value.contains(file.id) {
                                        collapsed.value.remove(file.id)
                                    } else {
                                        collapsed.value.insert(file.id)
                                    }
                                }
                                .stayInView(scrollsSideways, scrollX: scrollX.value, viewportWidth: viewport.size.width)
                            }
                        }
                    }
                    .diffRowsStyle(font: Font(nsFont as CTFont), size: size, lineHeight: lineHeight,
                                   column: column, theme: theme, lineMode: lineMode)
                    .environment(\.diffAnnotatable, false)
                    .frame(width: scrollsSideways ? max(viewport.size.width, contentWidth) : nil,
                           alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
                // Where the content is scrolled to sideways (headers follow it); only tracked while
                // lines don't wrap, so vertical scrolling doesn't redraw anything.
                // Only the horizontal offset: vertical scrolling shouldn't redraw anything.
                .onScrollGeometryChange(for: CGFloat.self) { $0.visibleRect.minX } action: { _, x in
                    if scrollsSideways { scrollX.value = x }
                }
                .id("\(commit.hash)|\(mode.rawValue)|\(wrapLines)") // back to the top on commit/mode/wrap change
                .background(codeBackground)
            }
        }
    }

    @ViewBuilder
    private func fileContent(_ file: CommitFile, gutter: CGFloat, commit: RenderedCommit) -> some View {
        if file.diff.isBinary {
            BinaryPreview(root: model.root, change: file.change,
                          commit: (commit.hash, commit.parents.first), inline: true)
        } else if file.diff.unified.isEmpty {
            note(DiffDetailView.summary(file.diff.notes, change: file.change))
        } else {
            switch mode {
            case .unified:
                ForEach(file.diff.unified) {
                    UnifiedRowView(model: model, path: file.change.path, row: $0, gutter: gutter)
                }
            case .split:
                ForEach(file.diff.split) {
                    SplitRowView(model: model, path: file.change.path, row: $0, gutter: gutter)
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
}

/// Width taken by the vertical scroll bar: only when scroll bars are always shown (they
/// overlay the content otherwise).
private var visibleScrollerWidth: CGFloat {
    NSScroller.preferredScrollerStyle == .legacy
        ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
}

extension View {
    /// Headers in the commit view: as wide as the visible area. When the content scrolls
    /// sideways (unwrapped lines), they move along so they stay in view.
    @ViewBuilder
    func stayInView(_ scrollsSideways: Bool, scrollX: CGFloat, viewportWidth: CGFloat) -> some View {
        if scrollsSideways {
            frame(width: max(viewportWidth - visibleScrollerWidth, 0), alignment: .leading)
                .offset(x: scrollX)
        } else {
            frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Subject, body, author, date and hash at the top of a commit.
private struct CommitMessageView: View {
    let commit: RenderedCommit

    var body: some View {
        let added = commit.files.reduce(0) { $0 + $1.diff.added }
        let removed = commit.files.reduce(0) { $0 + $1.diff.removed }
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.subject)
                .font(.title3.weight(.semibold))
            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(.body)
            }
            HStack(spacing: 10) {
                Text(commit.author).help(commit.email)
                Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                Text(commit.hash.prefix(10)).monospaced().help(commit.hash)
                if commit.parents.count > 1 {
                    Text("Merge, compared with its first parent")
                }
                Spacer()
                Text("\(commit.files.count) \(commit.files.count == 1 ? "file" : "files")")
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .lineSpacing(2)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A file's header where several files' diffs follow one another (a commit, or all changes on
/// one page); stays pinned while its diff scrolls by. Click to fold it away.
struct DiffFileHeader: View {
    let file: CommitFile
    let collapsed: Bool
    let toggle: () -> Void
    /// Where files can be annotated: whether this one has a note, and what the button does.
    var annotation: (exists: Bool, begin: () -> Void)? = nil

    var body: some View {
        let change = file.change
        HStack(spacing: 8) {
            Image(systemName: "chevron.down")
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 12)
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
            if !file.diff.isBinary, file.diff.added + file.diff.removed > 0 {
                Text("+\(file.diff.added)").foregroundStyle(.green)
                Text("−\(file.diff.removed)").foregroundStyle(.red)
            }
            if let annotation {
                Button(action: annotation.begin) {
                    Image(systemName: annotation.exists ? "text.bubble.fill" : "text.bubble")
                }
                .buttonStyle(.borderless)
                .help("Annotate this file")
            }
        }
        .font(.body)
        .lineSpacing(0)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .help(collapsed ? "Click to show this file’s changes" : "Click to fold away this file’s changes")
    }
}
