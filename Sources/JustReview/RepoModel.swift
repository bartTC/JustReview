import AppKit
import SwiftUI

enum DiffMode: String, CaseIterable {
    case split, unified
}

@MainActor
final class RepoModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var branch = ""
    @Published private(set) var changes: [FileChange] = []
    @Published private(set) var rendered: RenderedDiff?
    @Published var error: String?
    @Published var editing: EditTarget?
    @Published var scrollRequest: ScrollRequest?
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
        return changes.first { $0.id == selection }
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
            UserDefaults.standard.set(top.path, forKey: "lastRepo")
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
            let (changes, branch) = try await Task.detached {
                (try Git.changes(in: root), Git.branch(in: root))
            }.value
            guard root == self.root else { return } // repo switched meanwhile
            if self.branch != branch { self.branch = branch }
            if self.changes != changes { self.changes = changes }

            if let selection, changes.contains(where: { $0.id == selection }) {
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
        Task {
            let result = await Task.detached { () -> RenderedDiff? in
                let raw = (try? Git.diff(for: change, in: root)) ?? ""
                // Unchanged since last time: keep the current rows (cheap refresh-on-focus).
                if previous?.changeID == change.id, previous?.rawText == raw,
                   previous?.tabWidth == tabWidth { return nil }
                return DiffRenderer.render(raw, changeID: change.id, tabWidth: tabWidth)
            }.value
            guard generation == diffGeneration, let result else { return }
            rendered = result
        }
    }
}
