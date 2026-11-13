import AppKit
import SwiftUI

// MARK: - Model

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

    /// Whether the note is about this line (one of the lines of a range note).
    func covers(_ other: LineKey) -> Bool {
        guard let key else { return false }
        guard let endLine else { return key == other }
        return other.isOldSide == key.isOldSide && (key.line...endLine).contains(other.line)
    }

    /// Whether the note is shown under this line (a range note: under its last line).
    func ends(at other: LineKey) -> Bool {
        guard let key else { return false }
        guard let endLine else { return key == other }
        return other.isOldSide == key.isOldSide && other.line == endLine
    }

    var markdown: String { "## \(location)\n\(text)" }
}

/// Which line is being annotated, and in which column the popover should anchor
/// (0 = stacked, 1 = left half, 2 = right half of side-by-side; -1 = the file header).
struct EditTarget: Equatable {
    let path: String
    let key: LineKey?
    let rowID: Int
    let column: Int
    /// Last line of a range (marked lines); the popover then sits at that line's row (`rowID`).
    var endLine: Int? = nil

    /// Same row and column: where the popover is anchored.
    func sameAnchor(_ other: EditTarget) -> Bool {
        path == other.path && rowID == other.rowID && column == other.column
    }
}

/// Lines marked by clicking or dragging: from the line where the mouse went down to `end`.
struct LineMark: Equatable {
    let anchor: EditTarget
    var end: EditTarget
}

/// A line row in the diff: its row and column (0 stacked; 1, 2 the halves of side by side).
struct LineSlot: Hashable {
    let rowID: Int
    let column: Int
}

/// Where a line row is on screen (in the diff's content coordinates), and what it shows.
struct LineFrame: Equatable {
    let frame: CGRect
    let target: EditTarget
}

extension LineKey {
    /// Removed lines are numbered in the old file; added and unchanged lines in the new one.
    var isOldSide: Bool { side == .removed }
}

struct ScrollRequest: Equatable {
    let path: String
    let key: LineKey?
    let nonce = UUID()
}

extension RepoModel {
    /// Note for the whole file being edited from the file header.
    static func fileTarget(path: String) -> EditTarget {
        EditTarget(path: path, key: nil, rowID: -1, column: -1)
    }

    func annotation(path: String, key: LineKey?, endLine: Int? = nil) -> Annotation? {
        annotations.first { $0.path == path && $0.key == key && $0.endLine == endLine }
    }

    /// Notes shown under this line: its own note and range notes ending here.
    func notesEnding(path: String, key: LineKey) -> [Annotation] {
        annotations.filter { $0.path == path && $0.ends(at: key) }
    }

    /// Whether the line belongs to a range note, or to the range being annotated right now.
    func isInRange(path: String, key: LineKey) -> Bool {
        if let editing, editing.path == path, editing.endLine != nil,
           Annotation(path: path, key: editing.key, text: "", endLine: editing.endLine).covers(key) {
            return true
        }
        return annotations.contains { $0.path == path && $0.endLine != nil && $0.covers(key) }
    }

    /// Text of a line in the shown diff: removed lines by old number, others by new number.
    private func lineText(_ line: Int, oldSide: Bool, in texts: [LineKey: String]) -> String? {
        oldSide ? texts[LineKey(side: .removed, line: line)]
            : texts[LineKey(side: .added, line: line)] ?? texts[LineKey(side: .context, line: line)]
    }

    /// A range from one line to another (same file, column and side, every line in between
    /// shown in the diff), or nil when the lines can't form one.
    func rangeTarget(from anchor: EditTarget?, to target: EditTarget) -> EditTarget? {
        guard let anchor, let a = anchor.key, let b = target.key, anchor.path == target.path,
              anchor.column == target.column, a.isOldSide == b.isOldSide, a.line != b.line,
              let texts = rendered?.changeID == target.path ? rendered?.lineTexts : nil else { return nil }
        let (first, last) = a.line < b.line ? (anchor, target) : (target, anchor)
        let range = first.key!.line...last.key!.line
        guard range.allSatisfy({ lineText($0, oldSide: a.isOldSide, in: texts) != nil }) else { return nil }
        return EditTarget(path: target.path, key: first.key, rowID: last.rowID, column: last.column,
                          endLine: last.key!.line)
    }

    // MARK: Marked lines

    /// The marked lines as something to annotate: one line, or a range.
    var markedTarget: EditTarget? {
        guard let mark else { return nil }
        if mark.anchor.sameAnchor(mark.end) { return mark.anchor }
        return rangeTarget(from: mark.anchor, to: mark.end)
    }

    func isMarked(_ target: EditTarget) -> Bool {
        guard let marked = markedTarget, marked.path == target.path, marked.column == target.column,
              let key = target.key else { return false }
        return Annotation(path: marked.path, key: marked.key, text: "", endLine: marked.endLine).covers(key)
    }

    /// Code of the marked lines, without line numbers or +/- markers.
    var markedCode: String? {
        guard let marked = markedTarget, let key = marked.key,
              let texts = rendered?.changeID == marked.path ? rendered?.lineTexts : nil else { return nil }
        return (key.line...(marked.endLine ?? key.line))
            .compactMap { lineText($0, oldSide: key.isOldSide, in: texts) }
            .joined(separator: "\n")
    }

    func copyMarkedCode() {
        guard let code = markedCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    /// Mouse down on a line: marks it, or (second click) opens the annotation editor.
    func lineMouseDown(_ target: EditTarget) {
        let now = Date()
        if let down = lineDown, down.target.sameAnchor(target),
           now.timeIntervalSince(down.time) < NSEvent.doubleClickInterval {
            lineDown = nil
            annotate(at: target)
            return
        }
        lineDown = (target, now)
        // A click inside the marked lines keeps them (it may be the first click of a double-click).
        if !isMarked(target) { mark = LineMark(anchor: target, end: target) }
    }

    /// Dragging from the line the mouse went down on: marks every line up to the one under the
    /// pointer (lines that can't share a note with the first one are skipped).
    func lineDragged(to location: CGPoint) {
        guard let origin = lineDown?.target else { return }
        lineDown?.time = .distantPast // a drag is not the first click of a double-click
        guard let hit = lineFrames.first(where: { slot, line in
            slot.column == origin.column && line.target.path == origin.path
                && line.frame.minY <= location.y && location.y < line.frame.maxY
        })?.value.target else { return }
        if hit.sameAnchor(origin) || rangeTarget(from: origin, to: hit) != nil {
            let marked = LineMark(anchor: origin, end: hit)
            if mark != marked { mark = marked }
        } else if mark?.anchor != origin {
            mark = LineMark(anchor: origin, end: origin)
        }
    }

    /// Annotates the marked lines when the line is one of them, otherwise just the line.
    func annotate(at target: EditTarget) {
        if isMarked(target), let marked = markedTarget {
            editing = marked
        } else {
            mark = LineMark(anchor: target, end: target)
            editing = target
        }
    }

    /// A new note as it would be saved: the line's text, or for a range every line's text and
    /// whether the lines are all added/removed (for the `(+)`/`(-)` in its location).
    func draft(path: String, key: LineKey?, endLine: Int?, text: String) -> Annotation {
        let texts = rendered?.changeID == path ? rendered?.lineTexts : nil
        var note = Annotation(path: path, key: key, text: text, lineText: key.flatMap { texts?[$0] })
        guard let key, let endLine, let texts else { return note }
        note.endLine = endLine
        note.lineTexts = (key.line...endLine).compactMap { lineText($0, oldSide: key.isOldSide, in: texts) }
        let sides = Set((key.line...endLine).map { line -> RowKind in
            if key.isOldSide { return .removed }
            return texts[LineKey(side: .added, line: line)] != nil ? .added : .context
        })
        note.rangeSide = sides.count == 1 ? sides.first : .context
        return note
    }

    func setAnnotation(path: String, key: LineKey?, endLine: Int? = nil, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = annotations
        if let i = list.firstIndex(where: { $0.path == path && $0.key == key && $0.endLine == endLine }) {
            if trimmed.isEmpty { list.remove(at: i) } else { list[i].text = trimmed }
        } else if !trimmed.isEmpty {
            list.append(draft(path: path, key: key, endLine: endLine, text: trimmed))
        }
        annotations = Self.sorted(list)
        if key != nil { mark = nil } // the marked lines have their note now
    }

    /// Re-anchor annotations after the working tree changed:
    /// - line still has the same text → keep
    /// - same text now appears exactly once on the same side → follow it (code above moved)
    /// - otherwise → drop it; the line was changed, presumably addressing the note.
    func validateAnnotations(changes: [FileChange], root: URL) async {
        let checked = annotations.filter { $0.lineText != nil }
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
                guard let raw = try? Git.diff(for: change, in: root) else { continue } // git hiccup: keep notes
                maps[path] = DiffParser.lineTexts(DiffParser.parse(raw))
            }
            return maps
        }.value
        guard root == self.root else { return }

        var drop = Set<UUID>()
        var move: [UUID: LineKey] = [:]
        var moveEnd: [UUID: Int] = [:]
        for a in checked {
            guard let lines = lineMaps[a.path], let key = a.key, let expected = a.lineText else { continue }
            // Range note: every line must still match where it is, or the whole block must
            // appear exactly once elsewhere on the same side (moved); otherwise it's dropped.
            if let endLine = a.endLine, let texts = a.lineTexts, !texts.isEmpty {
                func matches(at start: Int) -> Bool {
                    texts.indices.allSatisfy { lineText(start + $0, oldSide: key.isOldSide, in: lines) == texts[$0] }
                }
                if matches(at: key.line) { continue }
                let starts = lines.keys.filter { $0.isOldSide == key.isOldSide && lines[$0] == texts[0] }
                    .map(\.line).filter(matches(at:))
                if starts.count == 1, let start = starts.first,
                   let startKey = lines.keys.first(where: { $0.isOldSide == key.isOldSide && $0.line == start }) {
                    move[a.id] = startKey
                    moveEnd[a.id] = start + (endLine - key.line)
                } else {
                    drop.insert(a.id)
                }
                continue
            }
            if lines[key] == expected { continue }
            let matches = lines.filter { $0.key.side == key.side && $0.value == expected }
            if matches.count == 1, let target = matches.first?.key,
               annotation(path: a.path, key: target) == nil {
                move[a.id] = target
            } else {
                drop.insert(a.id)
            }
        }
        guard !drop.isEmpty || !move.isEmpty else { return }

        // Close the editor if its note was just dropped.
        if let editing, checked.contains(where: {
            drop.contains($0.id) && $0.path == editing.path && $0.key == editing.key && $0.endLine == editing.endLine
        }) {
            self.editing = nil
        }
        // Apply to the current list (the user may have edited notes while git ran).
        annotations = Self.sorted(annotations.compactMap { a in
            if drop.contains(a.id) { return nil }
            var a = a
            if let key = move[a.id] { a.key = key }
            if let end = moveEnd[a.id] { a.endLine = end }
            return a
        })
    }

    private static func sorted(_ list: [Annotation]) -> [Annotation] {
        list.sorted {
            $0.path != $1.path
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : ($0.key?.line ?? 0) < ($1.key?.line ?? 0)   // file notes first
        }
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

    func removeAnnotation(_ annotation: Annotation) {
        annotations.removeAll { $0.id == annotation.id }
    }

    var annotationsMarkdown: String {
        annotations.map(\.markdown).joined(separator: "\n\n") + "\n"
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

    /// Popover shown at this row/column while it (or a range ending there) is being annotated.
    func editingBinding(_ target: EditTarget) -> Binding<Bool> {
        Binding(
            get: { self.editing?.sameAnchor(target) ?? false },
            set: { if !$0, self.editing?.sameAnchor(target) == true { self.editing = nil } }
        )
    }
}

/// Local view state. (`@State` is a macro in this SDK whose plugin ships only with full Xcode,
/// so views keep small bits of state in one of these via `@StateObject` instead.)
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Popover editor

/// Puts the keyboard focus into the popover's text editor as soon as the popover is on screen.
/// (`@FocusState` set in `onAppear` is often lost: the popover's window isn't key yet.)
private struct FocusTextViewOnAppear: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Now and once the popover has finished animating in: focusing during the animation
            // leaves the caret undrawn until the first keystroke.
            for delay in [0.0, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.focus() }
            }
        }

        private func focus() {
            guard let window, let content = window.contentView,
                  let textView = Self.firstTextView(in: content) else { return }
            window.makeKey()
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
                // Caret at the end of an existing note.
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
            textView.updateInsertionPointStateAndRestartTimer(true)
            textView.needsDisplay = true
        }

        private static func firstTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView, textView.isEditable { return textView }
            for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
            return nil
        }
    }
}

struct AnnotationEditor: View {
    @ObservedObject var model: RepoModel
    let target: EditTarget
    @StateObject private var text = Box("")
    @FocusState private var focused: Bool

    private var existing: Annotation? { model.annotation(path: target.path, key: target.key, endLine: target.endLine) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(existing?.location ?? model.draft(path: target.path, key: target.key,
                                                  endLine: target.endLine, text: "").location)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            TextEditor(text: $text.value)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(width: 360, height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .background(FocusTextViewOnAppear())
            HStack {
                if existing != nil {
                    Button("Delete", role: .destructive) {
                        model.setAnnotation(path: target.path, key: target.key, endLine: target.endLine, text: "")
                        model.editing = nil
                    }
                }
                Spacer()
                Button("Cancel") { model.editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setAnnotation(path: target.path, key: target.key, endLine: target.endLine, text: text.value)
                    model.editing = nil
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘↩")
            }
        }
        .padding(12)
        .onAppear {
            text.value = existing?.text ?? ""
            focused = true
        }
    }
}

// MARK: - Inline note under an annotated line

struct AnnotationNoteView: View {
    let annotation: Annotation
    let indent: CGFloat
    let onEdit: () -> Void
    let onDelete: () -> Void
    @StateObject private var hovered = Box(false)

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(.orange)
            Text(annotation.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            TrashButton(action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(hovered.value ? 0.22 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.orange.opacity(hovered.value ? 0.6 : 0.35)))
        .onHover { hovered.value = $0 }
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }
}

// MARK: - Shared bits

/// Plain trash icon; turns red on hover.
struct TrashButton: View {
    let action: () -> Void
    @StateObject private var hovered = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .foregroundStyle(hovered.value ? Color.red : Color.secondary)
        }
        .buttonStyle(.borderless)
        .onHover { hovered.value = $0 }
        .help("Delete annotation")
    }
}

// MARK: - Bottom pane

private struct AnnotationPaneRow: View {
    let annotation: Annotation
    let onReveal: () -> Void
    let onDelete: () -> Void
    @StateObject private var hovered = Box(false)

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("## " + annotation.location)
                    .font(.callout.monospaced().bold())
                Text(annotation.text)
                    .font(.callout.monospaced())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TrashButton(action: onDelete)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovered.value ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .onTapGesture(perform: onReveal)
        .contextMenu {
            Button("Show in Diff", action: onReveal)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .help("Click to show in diff")
    }
}

struct AnnotationsPane: View {
    @ObservedObject var model: RepoModel
    @StateObject private var dragStart = Box<Double?>(nil)
    @AppStorage("annotationsPaneHeight") private var height = 160.0
    @AppStorage("annotationsCollapsed") private var collapsed = false

    private static let headerHeight = 32.0

    var body: some View {
        VStack(spacing: 0) {
            if collapsed { Divider() } else { resizeHandle }
            HStack(spacing: 8) {
                Button {
                    collapsed.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
                .help(collapsed ? "Show annotations (⌥⌘A)" : "Fold away annotations (⌥⌘A)")
                Text("Annotations").font(.headline)
                Text("\(model.annotations.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                Button {
                    model.copyAnnotations()
                } label: {
                    // Fixed icon slot and width so swapping "Copy" ↔ "Copied" doesn't shift anything.
                    HStack(spacing: 4) {
                        Image(systemName: model.justCopied ? "checkmark" : "doc.on.doc")
                            .frame(width: 14, height: 14)
                        Text(model.justCopied ? "Copied" : "Copy")
                    }
                    .frame(width: 64)
                }
                .help("Copy all annotations as Markdown (⌘C)")
                .disabled(model.annotations.isEmpty)

                Button("Clear All…", role: .destructive) { model.confirmClearAnnotations() }
                    .help("Delete all annotations (⌘R)")
                    .disabled(model.annotations.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: Self.headerHeight)

            if !collapsed {
                Divider()
                content
            }
        }
        .frame(height: collapsed ? Self.headerHeight + 1 : height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
            if model.annotations.isEmpty {
                Text("Click a line in the diff to annotate it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.annotations) { a in
                        AnnotationPaneRow(annotation: a,
                                          onReveal: { model.reveal(a) },
                                          onDelete: { model.removeAnnotation(a) })
                    }
                }
                .listStyle(.plain)
            }
    }

    /// Top border doubling as a drag handle to resize the pane.
    private var resizeHandle: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(height: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart.value ?? height
                                dragStart.value = start
                                height = min(max(start - value.translation.height, 90), 700)
                            }
                            .onEnded { _ in dragStart.value = nil }
                    )
            )
    }
}
