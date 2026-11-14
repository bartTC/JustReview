import AppKit
import Combine
import SwiftUI
import Syntax

enum DiffMode: String, CaseIterable {
    case split, unified
}

/// A "next/previous change" request (each request is distinct, so repeats trigger again).
struct ChangeJump: Equatable {
    enum Anchor { case first, last }
    let forward: Bool
    let nonce = UUID()
}

/// What the sidebar lists: changed files, all files, or the commit history.
enum SidebarTab: String, CaseIterable {
    case changes, files, history

    var title: String {
        switch self {
        case .changes: "Changes"
        case .files: "Files"
        case .history: "History"
        }
    }

    /// The tab new windows start with: the last one picked (earlier versions had a
    /// "Show All Files" toggle instead of the Files tab).
    static var initial: SidebarTab {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "sidebarTab"), let tab = SidebarTab(rawValue: raw) { return tab }
        return defaults.bool(forKey: "showAllFiles") ? .files : .changes
    }
}

/// One file of a commit, rendered for display.
struct CommitFile: Identifiable {
    let change: FileChange
    let diff: RenderedDiff
    var id: String { change.id }
}

/// A commit shown in the diff area: its message and every file it changed.
struct RenderedCommit {
    let hash: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let subject: String
    let body: String
    let files: [CommitFile]
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor
final class RepoModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var branch = ""
    @Published private(set) var changes: [FileChange] = []
    /// Unchanged files, populated only while "Show All Files" is on.
    @Published private(set) var unchanged: [FileChange] = []
    @Published private(set) var rendered: RenderedDiff? {
        didSet { updateBlameRows() }
    }
    /// Blame of the shown file's HEAD version (while "Show Blame" is on).
    private var blame: FileBlame? {
        didSet { updateBlameRows() }
    }
    /// The blame column's content for the shown diff, by row.
    @Published private(set) var blameRows: BlameRows?
    let blameHover = BlameHover()
    private var blameCache: [String: [Int: BlameLine]] = [:]
    private var blameGeneration = 0
    @Published var error: String?
    /// The note (line, range or file) whose inline editor is open; one at a time.
    @Published var editing: EditSession?
    /// The open editor's text.
    let editorDraft = EditorDraft()
    /// Lines marked by clicking or dragging (to annotate together or copy).
    @Published var mark: LineMark?
    /// Frames of the line rows currently on screen, for finding the line under a drag.
    var lineFrames: [LineSlot: LineFrame] = [:]
    /// Mouse-down on a line: where a drag started, and when (for double-click detection).
    var lineDown: (target: LineTarget, time: Date)?
    @Published var scrollRequest: ScrollRequest?
    /// Keyboard navigation between changes (⌥⌘↓/↑); handled by the diff view.
    @Published var changeJump: ChangeJump?
    /// Where to land when navigation moves on to another file (first or last change).
    var pendingChangeAnchor: ChangeJump.Anchor?
    /// Briefly true after copying annotations (drives the "Copied" button state).
    @Published var justCopied = false
    var copiedResetTask: Task<Void, Never>?
    /// Annotations, shared by all windows of this repository (see `AnnotationStore`).
    var annotations: [Annotation] {
        get { annotationStore?.annotations ?? [] }
        set { annotationStore?.annotations = newValue }
    }
    private(set) var annotationStore: AnnotationStore?
    private var annotationSubscription: AnyCancellable?
    /// The file shown in the diff area (main window: the active tab).
    @Published var selection: String? {
        didSet {
            guard oldValue != selection else { return }
            // An editor left open in the file shown before is saved, like by a click elsewhere.
            if let open = editing?.note, open.path != selection { saveEditing() }
            mark = nil
            loadDiff()
            noteLocationChange()
        }
    }

    private var didInitialSelection = false

    // MARK: Sidebar tabs and history

    /// Changes, Files (every file, unchanged ones too) or History.
    @Published var sidebarTab = SidebarTab.initial {
        didSet {
            guard oldValue != sidebarTab else { return }
            UserDefaults.standard.set(sidebarTab.rawValue, forKey: "sidebarTab")
            mark = nil
            // Unchanged files are only listed (and kept up to date) on the Files tab.
            if oldValue == .files || sidebarTab == .files { Task { await refresh() } }
            noteLocationChange()
        }
    }
    /// The newest commits, loaded once the History tab is first shown.
    @Published private(set) var commits: [Commit] = []
    @Published private(set) var historyLoaded = false
    private var historyLimit = 500
    var historyHasMore: Bool { commits.count >= historyLimit }
    /// The commit shown in the diff area on the History tab.
    @Published var selectedCommit: String? {
        didSet {
            guard oldValue != selectedCommit else { return }
            loadCommit()
            noteLocationChange()
        }
    }
    @Published private(set) var renderedCommit: RenderedCommit?

    // MARK: All changes on one page

    static let showAllChangesKey = "showAllChanges"
    /// The Changes tab is to show every changed file's diff on one page instead of the selected
    /// file's (View → Show All Changes). The window says so, see `ContentView`: it's off on
    /// the other tabs and in a file's own window.
    @Published private(set) var wantsAllChanges = false
    /// The change is too large for one page (see `loadAllChanges`): one file at a time is shown
    /// until it's smaller again.
    @Published private(set) var tooManyChanges = false
    /// Every changed file's diff is shown on one page.
    var showsAllChanges: Bool { wantsAllChanges && !tooManyChanges }
    /// Every changed file's diff, in list order, while they're shown on one page; nil until
    /// loaded.
    @Published private(set) var allChanges: [CommitFile]?
    private var allChangesGeneration = 0
    /// The blame column of each file shown on one page, by file (while "Show Blame" is on).
    @Published private(set) var allBlameRows: [String: BlameRows] = [:]
    private var allBlameGeneration = 0
    @Published private(set) var commitError: String?
    private var commitGeneration = 0

    // MARK: Back/forward history

    /// Places shown in the diff area, oldest first (see `goBack()`).
    @Published private(set) var backForward: [NavLocation] = []
    /// The entry of `backForward` currently shown.
    @Published private(set) var backForwardIndex = -1
    fileprivate var locationRecordScheduled = false

    func loadHistory() async {
        guard let root else { return }
        let limit = historyLimit
        let commits = (try? await Task.detached { try Git.log(in: root, limit: limit) }.value) ?? []
        guard root == self.root else { return }
        if self.commits != commits { self.commits = commits }
        historyLoaded = true
        if selectedCommit == nil { selectedCommit = commits.first?.id }
    }

    func loadMoreHistory() async {
        historyLimit += 500
        await loadHistory()
    }

    private var diffGeneration = 0
    private var isRefreshing = false
    private var refreshPending = false
    private var watcher: FileWatcher?

    var repoName: String { root?.lastPathComponent ?? "JustReview" }

    // MARK: Navigation

    /// Shows the next/previous changed file (in list order) and lands on its first or last change.
    func selectAdjacentFile(forward: Bool, landOn anchor: ChangeJump.Anchor = .first) {
        let files = changes.map(\.path)
        let target: String?
        if let selection, let i = files.firstIndex(of: selection) {
            target = forward ? files[safe: i + 1] : files[safe: i - 1]
        } else if let selection {   // an unchanged file (Show All Files): the nearest change
            target = forward ? files.first { Git.treeOrder(selection, $0) }
                             : files.last { Git.treeOrder($0, selection) }
        } else {
            target = forward ? files.first : files.last
        }
        guard let target else { NSSound.beep(); return }
        pendingChangeAnchor = anchor
        selection = target
    }

    var selectedChange: FileChange? {
        guard let selection else { return nil }
        // A file opened in its own window that isn't changed (any more) is shown as an unchanged file.
        return changes.first { $0.id == selection } ?? unchanged.first { $0.id == selection }
            ?? FileChange(status: " ", path: selection, oldPath: nil)
    }

    // MARK: Opening

    /// - Parameter select: file to show first (otherwise the first change).
    @discardableResult
    func open(_ url: URL, reportErrors: Bool, select: String? = nil) async -> Bool {
        do {
            let top = try await Task.detached { try Git.toplevel(for: url) }.value
            root = top
            error = nil
            backForward = []
            backForwardIndex = -1
            editing = nil
            mark = nil
            changes = []
            rendered = nil
            allChanges = nil
            didInitialSelection = false
            selection = select
            commits = []
            historyLoaded = false
            historyLimit = 500
            selectedCommit = nil
            let store = AnnotationStore.shared(for: top)
            annotationStore = store
            annotationSubscription = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            watcher = FileWatcher(root: top) { [weak self] in
                Task { await self?.refresh() }
            }
            await refresh()
            return true
        } catch {
            if reportErrors { self.error = error.localizedDescription }
            return false
        }
    }

    // MARK: Refresh

    func refresh() async {
        guard root != nil else { return }
        // Coalesce: if a refresh is running, run exactly one more after it.
        if isRefreshing { refreshPending = true; return }
        isRefreshing = true
        repeat {
            refreshPending = false
            await refreshOnce()
        } while refreshPending
        isRefreshing = false
    }

    private func refreshOnce() async {
        guard let root else { return }
        do {
            let showAll = sidebarTab == .files
            let (changes, unchanged, branch) = try await Task.detached {
                let changes = try Git.changes(in: root)
                var unchanged: [FileChange] = []
                if showAll {
                    let changed = Set(changes.map(\.path))
                    unchanged = try Git.allFiles(in: root)
                        .filter { !changed.contains($0) }
                        .map { FileChange(status: " ", path: $0, oldPath: nil) }
                }
                return (changes, unchanged, Git.branch(in: root))
            }.value
            guard root == self.root else { return } // repo switched meanwhile
            if self.branch != branch { self.branch = branch }
            if self.changes != changes { self.changes = changes }
            if self.unchanged != unchanged { self.unchanged = unchanged }

            // The shown file is gone (no longer changed and not on disk): show the first change.
            let known = Set(changes.map(\.path) + unchanged.map(\.path))
            if let selection, !known.contains(selection),
               !FileManager.default.fileExists(atPath: root.appendingPathComponent(selection).path) {
                self.selection = changes.first?.id
            }
            // Show the first change when the repo is opened.
            if !didInitialSelection {
                didInitialSelection = true
                if selection == nil { selection = changes.first?.id }
            }
            loadDiff() // the shown file may have changed on disk
            loadAllChanges()
            if historyLoaded { await loadHistory() } // new commits, checkouts
            await validateAnnotations(changes: changes, root: root)
        } catch {
            // Transient failures (e.g. mid-rebase) are ignored; the next file event retries.
        }
    }

    /// Renders again after a display setting changed (theme, tab width, highlighting).
    func reloadDiff() {
        loadDiff()
        loadAllChanges()
        if selectedCommit != nil { loadCommit() }
    }

    /// Highlights both whole file versions (so multi-line strings/comments are right even when a
    /// hunk starts inside one); diff lines then pick their colors by line number.
    nonisolated private static func syntax(for change: FileChange, in root: URL,
                                           styledScopes: Set<String>) -> DiffRenderer.Syntax {
        syntax(path: change.path, styledScopes: styledScopes,
               old: {
                   guard !change.isUntracked, !change.isUnchanged, change.status != "A" else { return nil }
                   return Git.show(change.oldPath ?? change.path, in: root)
               },
               new: {
                   guard change.status != "D" else { return nil }
                   return FileManager.default.contents(atPath: root.appendingPathComponent(change.path).path)
                       .map { String(decoding: $0, as: UTF8.self) }
               })
    }

    /// Syntax tokens of a file's old and new version (each nil when that version doesn't exist).
    nonisolated private static func syntax(path: String, styledScopes: Set<String>,
                                           old: () -> String?, new: () -> String?) -> DiffRenderer.Syntax {
        guard let language = SyntaxLanguage.detect(path: path) else { return .none }
        let isStyled = { (scope: String) -> Bool in
            var key = Substring(scope)
            while true {
                if styledScopes.contains(String(key)) { return true }
                guard let dot = key.lastIndex(of: ".") else { return false }
                key = key[..<dot]
            }
        }
        var result = DiffRenderer.Syntax()
        if let new = new() {
            result.new = syntaxHighlighter.lineTokens(for: new, language: language, isStyled: isStyled)
        }
        if let old = old() {
            result.old = syntaxHighlighter.lineTokens(for: old, language: language, isStyled: isStyled)
        }
        return result
    }

    private func loadDiff() {
        loadBlame()
        diffGeneration += 1
        let generation = diffGeneration
        guard let root, let change = selectedChange else {
            rendered = nil
            return
        }
        let previous = rendered
        let tabWidth = FontPrefs.currentTabWidth
        let syntaxEnabled = UserDefaults.standard.object(forKey: "syntaxHighlighting") as? Bool ?? true
        let context = DiffContext.current
        // Theme for the current appearance; scopes styled by either theme are kept when
        // highlighting (so switching appearance only needs a re-render).
        let isDark = ThemePrefs.systemIsDark
        let theme = ThemeStore.shared.theme(named: ThemePrefs.name(dark: isDark))
        let styledScopes = ThemeStore.shared.theme(named: ThemePrefs.name(dark: false)).syntaxScopes
            .union(ThemeStore.shared.theme(named: ThemePrefs.name(dark: true)).syntaxScopes)
        Task {
            let result = await Task.detached { () -> RenderedDiff? in
                let raw = (try? Git.diff(for: change, in: root, context: context)) ?? ""
                // Unchanged since last time: keep the current rows (cheap refresh-on-focus).
                if previous?.changeID == change.id, previous?.rawText == raw,
                   previous?.tabWidth == tabWidth, previous?.syntaxEnabled == syntaxEnabled,
                   previous?.themeName == theme.name { return nil }
                let syntax = syntaxEnabled ? Self.syntax(for: change, in: root, styledScopes: styledScopes) : .none
                return DiffRenderer.render(raw, changeID: change.id, tabWidth: tabWidth,
                                           showHunkHeaders: !change.isUnchanged && context != DiffContext.wholeFile,
                                           syntax: syntax, syntaxEnabled: syntaxEnabled,
                                           styler: ThemeStyler(theme: theme), dark: isDark)
            }.value
            guard generation == diffGeneration, let result else { return }
            rendered = result
        }
    }
}

extension RepoModel {
    /// Commits with more files than this are shown without syntax highlighting (each file
    /// needs both versions read from git).
    nonisolated private static let highlightFileLimit = 100

    /// Turns the one-page view of all changes on or off. An open editor is saved: its line
    /// may not be shown in the other view.
    func setShowsAllChanges(_ on: Bool) {
        guard on != wantsAllChanges else { return }
        saveEditing()
        mark = nil
        wantsAllChanges = on
        tooManyChanges = false
        allChanges = nil
        allChangesGeneration += 1
        if on { loadAllChanges() } else { loadAllBlame() }
    }

    /// One page is for an overview of a small change. More files or diff lines than this are
    /// shown one file at a time: every refresh would run git and highlight for each file.
    nonisolated static let allChangesFileLimit = 100
    nonisolated static let allChangesLineLimit = 20_000

    /// The change became too large for one page, or small enough again.
    private func setTooManyChanges(_ tooMany: Bool) {
        guard tooMany != tooManyChanges else { return }
        saveEditing() // its line may not be shown in the other view
        mark = nil
        tooManyChanges = tooMany
        if tooMany {
            allChanges = nil
            loadAllBlame()
        }
    }

    /// Renders every changed file for the one-page view. Files whose diff is the same as last
    /// time keep their rows, and nothing is published when no file changed (cheap refreshes).
    fileprivate func loadAllChanges() {
        guard wantsAllChanges, let root else { return }
        allChangesGeneration += 1
        let generation = allChangesGeneration
        let changes = self.changes
        guard changes.count <= Self.allChangesFileLimit else {
            setTooManyChanges(true)
            return
        }
        let previous = allChanges ?? []
        let tabWidth = FontPrefs.currentTabWidth
        let syntaxEnabled = UserDefaults.standard.object(forKey: "syntaxHighlighting") as? Bool ?? true
        let context = DiffContext.current
        let isDark = ThemePrefs.systemIsDark
        let theme = ThemeStore.shared.theme(named: ThemePrefs.name(dark: isDark))
        let styledScopes = ThemeStore.shared.theme(named: ThemePrefs.name(dark: false)).syntaxScopes
            .union(ThemeStore.shared.theme(named: ThemePrefs.name(dark: true)).syntaxScopes)
        Task {
            let result = await Task.detached { () -> Result<[CommitFile]?, TooManyChanges> in
                let highlight = syntaxEnabled
                let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                var changed = previous.map(\.change) != changes
                // The diffs first: too many lines are not rendered at all.
                var lines = 0
                var raws: [String] = []
                for change in changes {
                    let raw = (try? Git.diff(for: change, in: root, context: context)) ?? ""
                    lines += raw.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
                    guard lines <= Self.allChangesLineLimit else { return .failure(TooManyChanges()) }
                    raws.append(raw)
                }
                let files = zip(changes, raws).map { change, raw -> CommitFile in
                    if let was = old[change.id], was.change == change, was.diff.rawText == raw,
                       was.diff.tabWidth == tabWidth, was.diff.syntaxEnabled == highlight,
                       was.diff.themeName == theme.name { return was }
                    changed = true
                    let syntax = highlight ? Self.syntax(for: change, in: root, styledScopes: styledScopes) : .none
                    let diff = DiffRenderer.render(raw, changeID: change.id, tabWidth: tabWidth,
                                                   showHunkHeaders: context != DiffContext.wholeFile,
                                                   syntax: syntax, syntaxEnabled: highlight,
                                                   styler: ThemeStyler(theme: theme), dark: isDark)
                    return CommitFile(change: change, diff: diff)
                }
                return .success(changed ? files : nil)
            }.value
            guard generation == allChangesGeneration, wantsAllChanges else { return }
            switch result {
            case .failure:
                setTooManyChanges(true)
            case .success(let files):
                setTooManyChanges(false)
                if let files { allChanges = files } else if allChanges == nil { allChanges = previous }
                loadAllBlame()
            }
        }
    }

    private struct TooManyChanges: Error {}

    fileprivate func loadCommit() {
        commitGeneration += 1
        let generation = commitGeneration
        commitError = nil
        guard let root, let hash = selectedCommit else {
            renderedCommit = nil
            return
        }
        let tabWidth = FontPrefs.currentTabWidth
        let syntaxEnabled = UserDefaults.standard.object(forKey: "syntaxHighlighting") as? Bool ?? true
        let context = DiffContext.current
        let isDark = ThemePrefs.systemIsDark
        let theme = ThemeStore.shared.theme(named: ThemePrefs.name(dark: isDark))
        let styledScopes = ThemeStore.shared.theme(named: ThemePrefs.name(dark: false)).syntaxScopes
            .union(ThemeStore.shared.theme(named: ThemePrefs.name(dark: true)).syntaxScopes)
        Task {
            let result = await Task.detached { () -> Result<RenderedCommit, Error> in
                Result {
                    let details = try Git.commitDetails(hash, in: root, context: context)
                    let parent = details.parents.first
                    let highlight = syntaxEnabled && details.files.count <= Self.highlightFileLimit
                    let files = details.files.map { file -> CommitFile in
                        let change = file.change
                        let syntax = !highlight ? .none : Self.syntax(
                            path: change.path, styledScopes: styledScopes,
                            old: {
                                guard change.status != "A", let parent else { return nil }
                                return Git.show(change.oldPath ?? change.path, at: parent, in: root)
                            },
                            new: { change.status == "D" ? nil : Git.show(change.path, at: hash, in: root) })
                        let diff = DiffRenderer.render(file.patch, changeID: change.id, tabWidth: tabWidth,
                                                       showHunkHeaders: context != DiffContext.wholeFile,
                                                       syntax: syntax, syntaxEnabled: highlight,
                                                       styler: ThemeStyler(theme: theme), dark: isDark)
                        return CommitFile(change: change, diff: diff)
                    }
                    return RenderedCommit(hash: details.hash, parents: details.parents, author: details.author,
                                          email: details.email, date: details.date, subject: details.subject,
                                          body: details.body, files: files)
                }
            }.value
            guard generation == commitGeneration else { return }
            switch result {
            case .success(let commit): renderedCommit = commit
            case .failure(let error): commitError = error.localizedDescription
            }
        }
    }
}

// MARK: - Blame

/// Blame of one file's HEAD version, by HEAD line number.
struct FileBlame {
    let changeID: String
    let lines: [Int: BlameLine]
}

/// One row's entry in the blame column; the name is shown at the first line of a run of lines
/// from the same commit.
struct BlameCell: Equatable {
    let line: BlameLine
    /// The run this line belongs to.
    let run: BlameRun
    let startsRun: Bool
    /// A run starting right below another one (gets a separator line).
    let followsRun: Bool
}

/// A run of lines from the same commit: its file and the row id of its first line.
struct BlameRun: Hashable {
    let file: String
    let row: Int
}

/// The blame run under the pointer. Kept apart from `RepoModel` so hovering only redraws the
/// rows, not everything observing the model.
@MainActor
final class BlameHover: ObservableObject {
    @Published private(set) var run: BlameRun?

    /// The pointer entered (or left) a blame cell of `run`.
    func hover(_ run: BlameRun?, inside: Bool) {
        if inside, let run {
            if self.run != run { self.run = run }
        } else if self.run != nil, self.run == run || run == nil {
            self.run = nil
        }
    }
}

/// The blame column for a rendered diff, by row id, for each layout.
struct BlameRows: Equatable {
    let changeID: String
    let unified: [Int: BlameCell]
    let split: [Int: BlameCell]
}

extension FileChange {
    /// The file existed at HEAD, so its lines there can be blamed.
    var hasBase: Bool { !isUntracked && status != "A" }
}

extension RepoModel {
    static let showBlameKey = "showBlame"

    /// Loads blame for the shown file (HEAD version), from the cache when HEAD hasn't moved.
    func loadBlame() {
        loadAllBlame()
        blameGeneration += 1
        let generation = blameGeneration
        guard UserDefaults.standard.bool(forKey: Self.showBlameKey), let root, let change = selectedChange,
              change.hasBase else {
            blame = nil
            return
        }
        let path = change.oldPath ?? change.path
        if blame?.changeID != change.id { blame = nil }
        Task {
            guard let head = await Task.detached(operation: { Git.headHash(in: root) }).value else { return }
            let key = head + ":" + path
            var lines = blameCache[key]
            if lines == nil {
                let result = await Task.detached { Git.blame(path, at: head, in: root) }.value
                if blameCache.count > 100 { blameCache.removeAll() }
                blameCache[key] = result
                lines = result
            }
            guard generation == blameGeneration, root == self.root, let lines else { return }
            blame = FileBlame(changeID: change.id, lines: lines)
        }
    }

    /// Shows a commit on the History tab (clicking a name in the blame column).
    func showCommit(_ hash: String) {
        blameHover.hover(nil, inside: false) // the column goes away without a hover-exit
        sidebarTab = .history
        selectedCommit = hash
    }

    /// Matches the blame to the rendered diff's rows: context and removed lines by their HEAD
    /// line number; added lines and hunk headers have none and end a run.
    fileprivate func updateBlameRows() {
        blameHover.hover(nil, inside: false) // rows were replaced; run ids may now mean other lines
        guard let rendered, let blame, rendered.changeID == blame.changeID else {
            if blameRows != nil { blameRows = nil }
            return
        }
        blameRows = Self.blameRows(for: rendered, lines: blame.lines)
    }

    /// The blame column for a diff's rows, from the blame of the file's HEAD version.
    nonisolated private static func blameRows(for diff: RenderedDiff, lines: [Int: BlameLine]) -> BlameRows {
        func cells(_ rows: [(id: Int, oldLine: Int?)]) -> [Int: BlameCell] {
            var result: [Int: BlameCell] = [:]
            var previous: String?
            var run = BlameRun(file: diff.changeID, row: 0)
            for row in rows {
                guard let number = row.oldLine, let line = lines[number] else {
                    previous = nil
                    continue
                }
                let starts = line.commit != previous
                if starts { run = BlameRun(file: diff.changeID, row: row.id) }
                result[row.id] = BlameCell(line: line, run: run, startsRun: starts,
                                           followsRun: starts && previous != nil)
                previous = line.commit
            }
            return result
        }
        return BlameRows(
            changeID: diff.changeID,
            unified: cells(diff.unified.map { ($0.id, $0.header == nil ? $0.oldNo : nil) }),
            split: cells(diff.split.map { ($0.id, $0.header == nil ? $0.left?.number : nil) }))
    }

    /// Blame for every file shown on one page (those that exist at HEAD), from the cache where
    /// HEAD hasn't moved.
    func loadAllBlame() {
        allBlameGeneration += 1
        let generation = allBlameGeneration
        guard showsAllChanges, UserDefaults.standard.bool(forKey: Self.showBlameKey), let root,
              let files = allChanges?.filter({ $0.change.hasBase }), !files.isEmpty else {
            if !allBlameRows.isEmpty { allBlameRows = [:] }
            return
        }
        Task {
            guard let head = await Task.detached(operation: { Git.headHash(in: root) }).value else { return }
            func key(_ file: CommitFile) -> String { head + ":" + (file.change.oldPath ?? file.change.path) }
            let missing = files.filter { blameCache[key($0)] == nil }.map { $0.change.oldPath ?? $0.change.path }
            let loaded = await Task.detached { missing.map { ($0, Git.blame($0, at: head, in: root)) } }.value
            if blameCache.count + loaded.count > 300 {
                blameCache = blameCache.filter { entry in files.contains { key($0) == entry.key } }
            }
            for (path, lines) in loaded { blameCache[head + ":" + path] = lines }
            guard generation == allBlameGeneration, root == self.root else { return }
            var rows: [String: BlameRows] = [:]
            for file in files {
                if let lines = blameCache[key(file)] { rows[file.id] = Self.blameRows(for: file.diff, lines: lines) }
            }
            guard rows != allBlameRows else { return }
            blameHover.hover(nil, inside: false) // rows were replaced; runs may now mean other lines
            allBlameRows = rows
        }
    }
}

// MARK: - Back/forward

/// A place in the back/forward history: a file or a commit, and the sidebar tab it was shown on.
struct NavLocation: Equatable {
    enum Target: Equatable {
        case file(String)
        case commit(String)
    }

    var tab: SidebarTab
    var target: Target
}

extension RepoModel {
    private static let backForwardLimit = 200

    /// What the diff area shows now (nil while nothing is picked).
    var currentLocation: NavLocation? {
        if sidebarTab == .history {
            return selectedCommit.map { NavLocation(tab: .history, target: .commit($0)) }
        }
        return selection.map { NavLocation(tab: sidebarTab, target: .file($0)) }
    }

    var canGoBack: Bool { backForwardIndex > 0 }
    var canGoForward: Bool { backForwardIndex < backForward.count - 1 }

    /// Shows the previous place (⌘[), skipping files that no longer exist.
    func goBack() {
        step(by: -1)
    }

    /// Shows the next place (⌘]) after going back.
    func goForward() {
        step(by: 1)
    }

    private func step(by delta: Int) {
        var index = backForwardIndex + delta
        while let location = backForward[safe: index] {
            if isAvailable(location) {
                backForwardIndex = index
                show(location)
                return
            }
            index += delta
        }
        NSSound.beep()
    }

    private func show(_ location: NavLocation) {
        sidebarTab = location.tab
        switch location.target {
        case .file(let path): selection = path
        case .commit(let hash): selectedCommit = hash
        }
    }

    /// A file that's neither changed (deleted files count) nor on disk can't be shown any more.
    private func isAvailable(_ location: NavLocation) -> Bool {
        guard case .file(let path) = location.target, let root else { return true }
        return changes.contains { $0.path == path } || unchanged.contains { $0.path == path }
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    /// Records the shown place once the current action is done, so a jump that sets the tab and
    /// then the commit (a blame click) is one step, not two.
    fileprivate func noteLocationChange() {
        guard !locationRecordScheduled else { return }
        locationRecordScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            locationRecordScheduled = false
            recordLocation()
        }
    }

    private func recordLocation() {
        guard let location = currentLocation else { return }
        if let current = backForward[safe: backForwardIndex], current.target == location.target {
            // Same file on the other file tab (Changes/Files): not a step of its own.
            if current.tab != location.tab { backForward[backForwardIndex] = location }
            return
        }
        backForward.removeSubrange((backForwardIndex + 1)...)
        backForward.append(location)
        if backForward.count > Self.backForwardLimit {
            backForward.removeFirst(backForward.count - Self.backForwardLimit)
        }
        backForwardIndex = backForward.count - 1
    }
}
