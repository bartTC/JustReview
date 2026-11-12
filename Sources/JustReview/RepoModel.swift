import AppKit
import SwiftUI
import Syntax

enum DiffMode: String, CaseIterable {
    case split, unified
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
    @Published var editing: EditTarget?
    @Published var scrollRequest: ScrollRequest?
    /// Briefly true after copying annotations (drives the "Copied" button state).
    @Published var justCopied = false
    var copiedResetTask: Task<Void, Never>?
    /// Review notes. Kept in the app's preferences per repository — never written into the repo.
    @Published var annotations: [Annotation] = [] {
        didSet { saveAnnotations() }
    }
    @Published var selection: String? {
        didSet { if oldValue != selection { loadDiff() } }
    }

    private var diffGeneration = 0
    private var isRefreshing = false
    private var refreshPending = false
    private var watcher: FileWatcher?

    var repoName: String { root?.lastPathComponent ?? "JustReview" }

    var selectedChange: FileChange? {
        guard let selection else { return nil }
        return changes.first { $0.id == selection } ?? unchanged.first { $0.id == selection }
    }

    // MARK: Opening

    @discardableResult
    func open(_ url: URL, reportErrors: Bool) async -> Bool {
        do {
            let top = try await Task.detached { try Git.toplevel(for: url) }.value
            root = top
            error = nil
            changes = []
            rendered = nil
            selection = nil
            loadAnnotations()
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
            let showAll = UserDefaults.standard.bool(forKey: "showAllFiles")
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

            if let selection, changes.contains(where: { $0.id == selection })
                || unchanged.contains(where: { $0.id == selection }) {
                loadDiff() // the file may have changed on disk
            } else {
                selection = changes.first?.id
            }
            await validateAnnotations(changes: changes, root: root)
        } catch {
            // Transient failures (e.g. mid-rebase) are ignored; the next file event retries.
        }
    }

    func reloadDiff() { loadDiff() }

    /// Highlights both whole file versions (so multi-line strings/comments are right even when a
    /// hunk starts inside one); diff lines then pick their colors by line number.
    nonisolated private static func syntax(for change: FileChange, in root: URL,
                                           styledScopes: Set<String>) -> DiffRenderer.Syntax {
        guard let language = SyntaxLanguage.detect(path: change.path) else { return .none }
        let isStyled = { (scope: String) -> Bool in
            var key = Substring(scope)
            while true {
                if styledScopes.contains(String(key)) { return true }
                guard let dot = key.lastIndex(of: ".") else { return false }
                key = key[..<dot]
            }
        }
        var result = DiffRenderer.Syntax()
        if change.status != "D",
           let data = FileManager.default.contents(atPath: root.appendingPathComponent(change.path).path) {
            result.new = syntaxHighlighter.lineTokens(for: String(decoding: data, as: UTF8.self),
                                                      language: language, isStyled: isStyled)
        }
        if !change.isUntracked, !change.isUnchanged, change.status != "A",
           let old = Git.show(change.oldPath ?? change.path, in: root) {
            result.old = syntaxHighlighter.lineTokens(for: old, language: language, isStyled: isStyled)
        }
        return result
    }

    // MARK: Annotation persistence

    private var annotationsKey: String? { root.map { "annotations:" + $0.path } }

    private func loadAnnotations() {
        guard let key = annotationsKey,
              let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Annotation].self, from: data)
        else { annotations = []; return }
        annotations = list
    }

    private func saveAnnotations() {
        guard let key = annotationsKey else { return }
        if annotations.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(annotations) {
            UserDefaults.standard.set(data, forKey: key)
        }
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
                                           styler: ThemeStyler(theme: theme))
            }.value
            guard generation == diffGeneration, let result else { return }
            rendered = result
        }
    }
}
