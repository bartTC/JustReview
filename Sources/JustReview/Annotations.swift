import AppKit
import SwiftUI

// MARK: - Model

/// Where a note is: a file, and in it one line, a range of lines, or (no line) the whole file.
struct NoteAnchor: Hashable {
    let path: String
    /// The line, or the first line of a range; nil for a note on the whole file.
    var key: LineKey? = nil
    /// Last line of a range; same side as `key`.
    var endLine: Int? = nil

    /// Whether the note is about this line (one of the lines of a range).
    func covers(_ other: LineKey) -> Bool {
        guard let key else { return false }
        guard let endLine else { return key == other }
        return other.isOldSide == key.isOldSide && (key.line...max(key.line, endLine)).contains(other.line)
    }

    /// Whether the note is shown under this line (a range note: under its last line).
    func ends(at other: LineKey) -> Bool {
        guard let key else { return false }
        guard let endLine else { return key == other }
        return other.isOldSide == key.isOldSide && other.line == endLine
    }
}

struct Annotation: Identifiable, Codable, Hashable {
    var id = UUID()
    let path: String
    /// The annotated line; nil for a note on the whole file.
    var key: LineKey?
    var text: String
    /// The annotated line's content when the note was written. When the line no longer
    /// matches, the note is considered addressed and is dropped (see `validateAnnotations`).
    var lineText: String?
    /// Last line of a note on a range of lines (`key` is the first); same side as `key`.
    var endLine: Int? = nil
    /// Content of every line of a range note, checked like `lineText`.
    var lineTexts: [String]? = nil
    /// .added / .removed when every line of the range is one; .context for a mix.
    var rangeSide: RowKind? = nil

    var anchor: NoteAnchor { NoteAnchor(path: path, key: key, endLine: endLine) }

    /// `path:6 (+)` — (+) added line, (-) removed line, nothing for an unchanged line;
    /// `path:12-18 (+)` for a range; just `path` for a note on the whole file.
    var location: String {
        guard let key else { return path }
        let lines = endLine.map { "\(key.line)-\($0)" } ?? "\(key.line)"
        switch endLine == nil ? key.side : (rangeSide ?? .context) {
        case .added: return "\(path):\(lines) (+)"
        case .removed: return "\(path):\(lines) (-)"
        case .context: return "\(path):\(lines)"
        }
    }

    var markdown: String { "## \(location)\n\(text)" }

    /// A new, empty note at `anchor`, tied to the text its lines have in `texts` (a diff's
    /// lines): the line's text, or for a range every line's text and whether the lines are all
    /// added/removed (for the `(+)`/`(-)` in its location). Nil when one of the lines isn't
    /// there, so there's nothing to tie it to. A note on the whole file needs no lines.
    static func new(at anchor: NoteAnchor, in texts: [LineKey: String]?) -> Annotation? {
        guard let key = anchor.key else { return Annotation(path: anchor.path, key: nil, text: "") }
        guard let texts, let first = texts[key] else { return nil }
        var note = Annotation(path: anchor.path, key: key, text: "", lineText: first)
        guard let endLine = anchor.endLine else { return note }
        guard endLine >= key.line else { return nil }
        let lines = (key.line...endLine).compactMap { texts.text(line: $0, oldSide: key.isOldSide) }
        guard lines.count == endLine - key.line + 1 else { return nil }
        note.endLine = endLine
        note.lineTexts = lines
        let sides = Set((key.line...endLine).map { line -> RowKind in
            if key.isOldSide { return .removed }
            return texts[LineKey(side: .added, line: line)] != nil ? .added : .context
        })
        note.rangeSide = sides.count == 1 ? sides.first : .context
        return note
    }
}

extension LineKey {
    /// Removed lines are numbered in the old file; added and unchanged lines in the new one.
    var isOldSide: Bool { side == .removed }
}

extension Dictionary where Key == LineKey, Value == String {
    /// Text of a line of a diff: removed lines by old number, others by new number.
    func text(line: Int, oldSide: Bool) -> String? {
        oldSide ? self[LineKey(side: .removed, line: line)]
            : self[LineKey(side: .added, line: line)] ?? self[LineKey(side: .context, line: line)]
    }

    /// The line with this number on a side, whichever kind it is now (added or unchanged).
    func key(line: Int, oldSide: Bool) -> LineKey? {
        [RowKind.removed, .added, .context]
            .map { LineKey(side: $0, line: line) }
            .first { $0.isOldSide == oldSide && self[$0] != nil }
    }
}

struct ScrollRequest: Equatable {
    let path: String
    let key: LineKey?
    let nonce = UUID()
}

// MARK: - The repository's annotations

extension RepoModel {
    func annotation(at anchor: NoteAnchor) -> Annotation? {
        annotations.first { $0.anchor == anchor }
    }

    func annotation(path: String, key: LineKey?, endLine: Int? = nil) -> Annotation? {
        annotation(at: NoteAnchor(path: path, key: key, endLine: endLine))
    }

    /// Notes shown under this line: its own note and range notes ending here.
    func notesEnding(path: String, key: LineKey) -> [Annotation] {
        annotations.filter { $0.path == path && $0.anchor.ends(at: key) }
    }

    /// Whether the line belongs to a range note, or to the range being annotated right now.
    func isInRange(path: String, key: LineKey) -> Bool {
        if let open = editing?.note.anchor, open.path == path, open.endLine != nil, open.covers(key) {
            return true
        }
        return annotations.contains { $0.path == path && $0.endLine != nil && $0.anchor.covers(key) }
    }

    /// The lines of the shown diff, when it's this file's (or one of the files, with all
    /// changes on one page).
    func shownLineTexts(of path: String) -> [LineKey: String]? {
        if showsAllChanges { return allChanges?.first { $0.change.path == path }?.diff.lineTexts }
        return rendered?.changeID == path ? rendered?.lineTexts : nil
    }

    func removeAnnotation(_ annotation: Annotation) {
        annotations.removeAll { $0.id == annotation.id }
    }

    /// Asks before deleting every annotation of this repository (Clear All button, ⌘R).
    func confirmClearAnnotations() {
        guard !annotations.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Delete all \(annotations.count) annotations?"
        alert.informativeText = "This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { annotations = [] }
    }

    /// What Copy puts on the clipboard (see `AnnotationStore.markdown`).
    var annotationsMarkdown: String {
        annotationStore?.markdown ?? ""
    }

    /// Copies all annotations (Copy button or ⌘C) and flashes "Copied" on the button.
    func copyAnnotations() {
        guard !annotations.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(annotationsMarkdown, forType: .string)
        justCopied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { justCopied = false }
        }
    }

    func reveal(_ annotation: Annotation) {
        if sidebarTab == .history { sidebarTab = .changes }
        selection = annotation.path
        scrollRequest = ScrollRequest(path: annotation.path, key: annotation.key)
    }

    static func sorted(_ list: [Annotation]) -> [Annotation] {
        list.sorted {
            $0.path != $1.path
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : ($0.key?.line ?? 0) < ($1.key?.line ?? 0)   // file notes first
        }
    }

    // MARK: Following the code

    /// Re-anchor annotations after the working tree changed:
    /// - line still has the same text → keep
    /// - same text now appears exactly once on the same side → follow it (code above moved)
    /// - otherwise → drop it; the line was changed, presumably addressing the note.
    ///
    /// The note in the open editor is checked too, saved or not, so the editor follows its
    /// line (see `reanchorEditor`).
    func validateAnnotations(changes: [FileChange], root: URL) async {
        var checked = annotations.filter { $0.lineText != nil }
        if let open = editing?.note, open.lineText != nil, !checked.contains(where: { $0.id == open.id }) {
            checked.append(open)
        }
        guard !checked.isEmpty else { return }
        let byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let paths = Set(checked.map(\.path))

        let lineMaps = await Task.detached { () -> [String: [LineKey: String]] in
            var maps: [String: [LineKey: String]] = [:]
            for path in paths {
                // Not changed any more: compare against the file as it is (notes on unchanged
                // lines survive; notes on added/removed lines no longer match and are dropped).
                let onDisk = FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
                guard let change = byPath[path] ?? (onDisk ? FileChange(status: " ", path: path, oldPath: nil) : nil)
                else { maps[path] = [:]; continue }
                // The whole file, so every line that can carry a note is there, whatever the
                // Context Lines setting shows.
                guard let raw = try? Git.diff(for: change, in: root, context: DiffContext.wholeFile)
                else { continue } // git hiccup: keep notes
                maps[path] = DiffParser.lineTexts(DiffParser.parse(raw))
            }
            return maps
        }.value
        guard root == self.root else { return }

        var drop = Set<UUID>()
        var move: [UUID: NoteAnchor] = [:]
        for a in checked {
            guard let lines = lineMaps[a.path], let key = a.key, let expected = a.lineText else { continue }
            // Range note: every line must still match where it is, or the whole block must
            // appear exactly once elsewhere on the same side (moved); otherwise it's dropped.
            if let endLine = a.endLine, let texts = a.lineTexts, !texts.isEmpty {
                func matches(at start: Int) -> Bool {
                    texts.indices.allSatisfy { lines.text(line: start + $0, oldSide: key.isOldSide) == texts[$0] }
                }
                if matches(at: key.line) { continue }
                let starts = lines.keys.filter { $0.isOldSide == key.isOldSide && lines[$0] == texts[0] }
                    .map(\.line).filter(matches(at:))
                if starts.count == 1, let start = starts.first,
                   let startKey = lines.key(line: start, oldSide: key.isOldSide) {
                    move[a.id] = NoteAnchor(path: a.path, key: startKey, endLine: start + (endLine - key.line))
                } else {
                    drop.insert(a.id)
                }
                continue
            }
            if lines[key] == expected { continue }
            let matches = lines.filter { $0.key.side == key.side && $0.value == expected }
            if matches.count == 1, let target = matches.first?.key,
               annotation(path: a.path, key: target) == nil {
                move[a.id] = NoteAnchor(path: a.path, key: target)
            } else {
                drop.insert(a.id)
            }
        }
        guard !drop.isEmpty || !move.isEmpty else { return }

        func moved(_ note: Annotation) -> Annotation {
            guard let to = move[note.id] else { return note }
            var note = note
            note.key = to.key
            note.endLine = to.endLine
            return note
        }
        // The editor may have been opened, closed or saved while git ran: this is about the one
        // open now.
        if let open = editing?.note {
            reanchorEditor(dropped: drop.contains(open.id), to: moved(open), lines: lineMaps[open.path])
        }
        // Apply to the current list (the user may have edited notes while git ran).
        let list = annotations.filter { !drop.contains($0.id) }.map(moved)
        if list != annotations { annotations = Self.sorted(list) }
    }
}

/// Local view state. (`@State` is a macro in this SDK whose plugin ships only with full Xcode,
/// so views keep small bits of state in one of these via `@StateObject` instead.)
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}
