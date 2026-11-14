import CryptoKit
import Foundation

/// Annotations of one repository, shared by every window showing it (main window and standalone
/// file windows). Kept in files in the app's folder — never in the repository — so other tools
/// can use them (see `directory(for:)`):
/// - `annotations.json`: the annotations, with a copy of the repository's instructions (set in
///   Settings; editing the copy changes nothing). The app picks up changes made to the
///   annotations from outside, and deleting the file clears them.
/// - `annotations.md`: what Copy puts on the clipboard (instructions, then the annotations),
///   written whenever they change; gone while there are none.
@MainActor
final class AnnotationStore: ObservableObject {
    private static var stores: [String: AnnotationStore] = [:]

    static func shared(for root: URL) -> AnnotationStore {
        if let store = stores[root.path] { return store }
        let store = AnnotationStore(root: root)
        stores[root.path] = store
        return store
    }

    // MARK: Files

    /// ~/Library/Application Support/JustReview/repositories
    nonisolated static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JustReview/repositories")
    }

    /// The repository's folder: its name and a short hash of its path (two checkouts with the
    /// same name don't share one).
    nonisolated static func directory(for root: String) -> URL {
        let hash = SHA256.hash(data: Data(root.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = (root as NSString).lastPathComponent
        return baseDirectory.appendingPathComponent("\(name)-\(hash)")
    }

    nonisolated static func jsonURL(for root: String) -> URL {
        directory(for: root).appendingPathComponent("annotations.json")
    }

    nonisolated static func markdownURL(for root: String) -> URL {
        directory(for: root).appendingPathComponent("annotations.md")
    }

    /// The JSON file's content.
    private struct File: Codable {
        var repository: String
        /// Copy of the instructions (left out when there are none).
        var instructions: String?
        var annotations: [Annotation]
    }

    // MARK: Store

    @Published var annotations: [Annotation] {
        didSet {
            if !isReloading { writeJSON() }
            writeMarkdown()
        }
    }

    let root: URL
    private var isReloading = false
    private var watcher: FileWatcher?

    private init(root: URL) {
        self.root = root
        annotations = []
        let directory = Self.directory(for: root.path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let list = readJSON() {
            isReloading = true
            annotations = list
            isReloading = false
        } else {
            migrateFromPreferences()
        }
        // Changes made by other tools (or another copy of the app).
        watcher = FileWatcher(root: directory) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Instructions, then a blank line, then the annotations as Markdown.
    var markdown: String {
        let notes = annotations.map(\.markdown).joined(separator: "\n\n") + "\n"
        let preamble = CopyPreamble.text(for: root.path)
        return preamble.isEmpty ? notes : preamble + "\n\n" + notes
    }

    /// The repository's instructions changed: annotations.md starts with them.
    static func instructionsChanged(for root: String) {
        stores[root]?.writeJSON()
        stores[root]?.writeMarkdown()
    }

    /// Annotations as last saved: nil when the file is missing or unreadable.
    private func readJSON() -> [Annotation]? {
        guard let data = try? Data(contentsOf: Self.jsonURL(for: root.path)) else { return nil }
        return (try? JSONDecoder().decode(File.self, from: data))?.annotations
    }

    /// The file changed on disk: take its annotations (none when it was deleted). A file that
    /// can't be read (half written, malformed) is ignored.
    private func reload() {
        let url = Self.jsonURL(for: root.path)
        let list: [Annotation]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let read = readJSON() else { return }
            list = read
        } else {
            list = []
        }
        guard list != annotations else { return } // our own write
        isReloading = true
        annotations = list
        isReloading = false
    }

    private func writeJSON() {
        let url = Self.jsonURL(for: root.path)
        guard !annotations.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let instructions = CopyPreamble.text(for: root.path)
        let file = File(repository: root.path, instructions: instructions.isEmpty ? nil : instructions,
                        annotations: annotations)
        guard let data = try? encoder.encode(file) else { return }
        write(data, to: url)
    }

    private func writeMarkdown() {
        let url = Self.markdownURL(for: root.path)
        guard !annotations.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        write(Data(markdown.utf8), to: url)
    }

    /// Writes only real changes, so tools watching the files aren't woken up for nothing.
    private func write(_ data: Data, to url: URL) {
        guard (try? Data(contentsOf: url)) != data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Earlier versions kept the annotations in the app's preferences.
    private func migrateFromPreferences() {
        let key = "annotations:" + root.path
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Annotation].self, from: data) else { return }
        annotations = list // writes the files
        if FileManager.default.fileExists(atPath: Self.jsonURL(for: root.path).path) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Copy instructions

/// Text put in front of the annotations when they're copied, e.g. instructions for the LLM.
/// Set in Settings, one per repository; kept in the app's preferences like the annotations.
enum CopyPreamble {
    private static let prefix = "copyPreamble:"

    private static func key(_ root: String) -> String { prefix + root }

    /// The repository's text, trimmed; empty when there is none.
    static func text(for root: String) -> String {
        (UserDefaults.standard.string(forKey: key(root)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text as typed (Settings edits this).
    static func raw(for root: String) -> String {
        UserDefaults.standard.string(forKey: key(root)) ?? ""
    }

    @MainActor
    static func set(_ text: String, for root: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key(root))
        } else {
            UserDefaults.standard.set(text, forKey: key(root))
        }
        AnnotationStore.instructionsChanged(for: root) // annotations.md starts with them
    }

    /// Repositories that have instructions saved.
    static var repositories: [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}
