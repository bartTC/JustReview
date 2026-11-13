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
    @Published private(set) var rendered: RenderedDiff?
    @Published var error: String?
    /// The line (or range) whose annotation popover is open.
    @Published var editing: EditTarget?
    /// Lines marked by clicking or dragging (to annotate together or copy).
    @Published var mark: LineMark?
    /// Frames of the line rows currently on screen, for finding the line under a drag.
    var lineFrames: [LineSlot: LineFrame] = [:]
    /// Mouse-down on a line: where a drag started, and when (for double-click detection).
    var lineDown: (target: EditTarget, time: Date)?
    @Published var scrollRequest: ScrollRequest?
    /// Keyboard navigation between changes (⌥⌘↓/↑); handled by the diff view.
    @Published var changeJump: ChangeJump?
    /// Where to land when navigation moves on to another file (first or last change).
    var pendingChangeAnchor: ChangeJump.Anchor?
    /// Briefly true after copying annotations (drives the "Copied" button state).
    @Published var justCopied = false
    var copiedResetTask: Task<Void, Never>?
    /// Review notes, shared by all windows of this repository (see `AnnotationStore`).
    var annotations: [Annotation] {
        get { annotationStore?.annotations ?? [] }
        set { annotationStore?.annotations = newValue }
    }
    private var annotationStore: AnnotationStore?
    private var annotationSubscription: AnyCancellable?
    /// The file shown in the diff area (main window: the active tab).
    @Published var selection: String? {
        didSet {
            guard oldValue != selection else { return }
            mark = nil
            loadDiff()
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
        }
    }
    /// The newest commits, loaded once the History tab is first shown.
    @Published private(set) var commits: [Commit] = []
    @Published private(set) var historyLoaded = false
    private var historyLimit = 500
    var historyHasMore: Bool { commits.count >= historyLimit }
    /// The commit shown in the diff area on the History tab.
    @Published var selectedCommit: String? {
        didSet { if oldValue != selectedCommit { loadCommit() } }
    }
    @Published private(set) var renderedCommit: RenderedCommit?
    @Published private(set) var commitError: String?
    private var commitGeneration = 0

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
            changes = []
            rendered = nil
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
            if historyLoaded { await loadHistory() } // new commits, checkouts
            await validateAnnotations(changes: changes, root: root)
        } catch {
            // Transient failures (e.g. mid-rebase) are ignored; the next file event retries.
        }
    }

    /// Renders again after a display setting changed (theme, tab width, highlighting).
    func reloadDiff() {
        loadDiff()
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
        diffGeneration += 1
        let generation = diffGeneration
        guard let root, let change = selectedChange else {
            rendered = nil
            return
        }
        let previous = rendered
        let tabWidth = FontPrefs.currentTabWidth
        let syntaxEnabled = UserDefaults.standard.object(forKey: "syntaxHighlighting") as? Bool ?? true
        // Theme for the current appearance; scopes styled by either theme are kept when
        // highlighting (so switching appearance only needs a re-render).
        let isDark = ThemePrefs.systemIsDark
        let theme = ThemeStore.shared.theme(named: ThemePrefs.name(dark: isDark))
        let styledScopes = ThemeStore.shared.theme(named: ThemePrefs.name(dark: false)).syntaxScopes
            .union(ThemeStore.shared.theme(named: ThemePrefs.name(dark: true)).syntaxScopes)
        Task {
            let result = await Task.detached { () -> RenderedDiff? in
                let raw = (try? Git.diff(for: change, in: root)) ?? ""
                // Unchanged since last time: keep the current rows (cheap refresh-on-focus).
                if previous?.changeID == change.id, previous?.rawText == raw,
                   previous?.tabWidth == tabWidth, previous?.syntaxEnabled == syntaxEnabled,
                   previous?.themeName == theme.name { return nil }
                let syntax = syntaxEnabled ? Self.syntax(for: change, in: root, styledScopes: styledScopes) : .none
                return DiffRenderer.render(raw, changeID: change.id, tabWidth: tabWidth,
                                           showHunkHeaders: !change.isUnchanged,
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
        let isDark = ThemePrefs.systemIsDark
        let theme = ThemeStore.shared.theme(named: ThemePrefs.name(dark: isDark))
        let styledScopes = ThemeStore.shared.theme(named: ThemePrefs.name(dark: false)).syntaxScopes
            .union(ThemeStore.shared.theme(named: ThemePrefs.name(dark: true)).syntaxScopes)
        Task {
            let result = await Task.detached { () -> Result<RenderedCommit, Error> in
                Result {
                    let details = try Git.commitDetails(hash, in: root)
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

/// Annotations of one repository, shared by every window showing it (main window and standalone
/// file windows). Kept in the app's preferences — never written into the repository.
@MainActor
final class AnnotationStore: ObservableObject {
    private static var stores: [String: AnnotationStore] = [:]

    static func shared(for root: URL) -> AnnotationStore {
        if let store = stores[root.path] { return store }
        let store = AnnotationStore(root: root)
        stores[root.path] = store
        return store
    }

    @Published var annotations: [Annotation] {
        didSet { save() }
    }

    private let key: String

    private init(root: URL) {
        key = "annotations:" + root.path
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Annotation].self, from: data) {
            annotations = list
        } else {
            annotations = []
        }
    }

    private func save() {
        if annotations.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(annotations) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
