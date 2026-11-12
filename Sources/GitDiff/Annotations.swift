import AppKit
import SwiftUI

// MARK: - Model

struct Annotation: Identifiable, Codable, Hashable {
    var id = UUID()
    let path: String
    var key: LineKey
    var text: String
    /// The annotated line's content when the note was written. When the line no longer
    /// matches, the note is considered addressed and is dropped (see `validateAnnotations`).
    var lineText: String?

    /// `path:6 (+)` — (+) added line, (-) removed line, nothing for an unchanged line.
    var location: String {
        switch key.side {
        case .added: return "\(path):\(key.line) (+)"
        case .removed: return "\(path):\(key.line) (-)"
        case .context: return "\(path):\(key.line)"
        }
    }

    var markdown: String { "## \(location)\n\(text)" }
}

/// Which line is being annotated, and in which column the popover should anchor
/// (0 = stacked, 1 = left half, 2 = right half of side-by-side).
struct EditTarget: Equatable {
    let path: String
    let key: LineKey
    let rowID: Int
    let column: Int
}

struct ScrollRequest: Equatable {
    let path: String
    let key: LineKey
    let nonce = UUID()
}

extension RepoModel {
    func annotation(path: String, key: LineKey) -> Annotation? {
        annotations.first { $0.path == path && $0.key == key }
    }

    func setAnnotation(path: String, key: LineKey, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = annotations
        if let i = list.firstIndex(where: { $0.path == path && $0.key == key }) {
            if trimmed.isEmpty { list.remove(at: i) } else { list[i].text = trimmed }
        } else if !trimmed.isEmpty {
            let lineText = rendered?.changeID == path ? rendered?.lineTexts[key] : nil
            list.append(Annotation(path: path, key: key, text: trimmed, lineText: lineText))
        }
        annotations = Self.sorted(list)
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
                guard let change = byPath[path] else { maps[path] = [:]; continue } // file no longer changed
                guard let raw = try? Git.diff(for: change, in: root) else { continue } // git hiccup: keep notes
                maps[path] = DiffParser.lineTexts(DiffParser.parse(raw))
            }
            return maps
        }.value
        guard root == self.root else { return }

        var drop = Set<UUID>()
        var move: [UUID: LineKey] = [:]
        for a in checked {
            guard let lines = lineMaps[a.path], let expected = a.lineText else { continue }
            if lines[a.key] == expected { continue }
            let matches = lines.filter { $0.key.side == a.key.side && $0.value == expected }
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
            drop.contains($0.id) && $0.path == editing.path && $0.key == editing.key
        }) {
            self.editing = nil
        }
        // Apply to the current list (the user may have edited notes while git ran).
        annotations = Self.sorted(annotations.compactMap { a in
            if drop.contains(a.id) { return nil }
            var a = a
            if let key = move[a.id] { a.key = key }
            return a
        })
    }

    private static func sorted(_ list: [Annotation]) -> [Annotation] {
        list.sorted {
            $0.path != $1.path
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : $0.key.line < $1.key.line
        }
    }

    func removeAnnotation(_ annotation: Annotation) {
        annotations.removeAll { $0.id == annotation.id }
    }

    var annotationsMarkdown: String {
        annotations.map(\.markdown).joined(separator: "\n\n") + "\n"
    }

    func copyAnnotations() {
        guard !annotations.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(annotationsMarkdown, forType: .string)
    }

    func reveal(_ annotation: Annotation) {
        selection = annotation.path
        scrollRequest = ScrollRequest(path: annotation.path, key: annotation.key)
    }

    func editingBinding(_ target: EditTarget) -> Binding<Bool> {
        Binding(
            get: { self.editing == target },
            set: { if !$0, self.editing == target { self.editing = nil } }
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

struct AnnotationEditor: View {
    @ObservedObject var model: RepoModel
    let target: EditTarget
    @StateObject private var text = Box("")
    @FocusState private var focused: Bool

    private var existing: Annotation? { model.annotation(path: target.path, key: target.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Annotation(path: target.path, key: target.key, text: "").location)
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
            HStack {
                if existing != nil {
                    Button("Delete", role: .destructive) {
                        model.setAnnotation(path: target.path, key: target.key, text: "")
                        model.editing = nil
                    }
                }
                Spacer()
                Button("Cancel") { model.editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setAnnotation(path: target.path, key: target.key, text: text.value)
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
        .onTapGesture(count: 2, perform: onEdit)
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
    @StateObject private var copied = Box(false)
    @StateObject private var confirmClear = Box(false)
    @StateObject private var dragStart = Box<Double?>(nil)
    @AppStorage("annotationsPaneHeight") private var height = 160.0

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            HStack(spacing: 8) {
                Text("Annotations").font(.headline)
                Text("\(model.annotations.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                Button {
                    model.copyAnnotations()
                    copied.value = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied.value = false
                    }
                } label: {
                    Label(copied.value ? "Copied" : "Copy", systemImage: copied.value ? "checkmark" : "doc.on.doc")
                }
                .help("Copy all annotations as Markdown (⇧⌘C)")
                .disabled(model.annotations.isEmpty)

                Button("Clear All", role: .destructive) { confirmClear.value = true }
                    .disabled(model.annotations.isEmpty)
                    .confirmationDialog("Delete all \(model.annotations.count) annotations?",
                                        isPresented: $confirmClear.value) {
                        Button("Delete All", role: .destructive) { model.annotations = [] }
                    }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if model.annotations.isEmpty {
                Text("Double-click a line in the diff to annotate it.")
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
        .frame(height: height)
        .background(Color(nsColor: .windowBackgroundColor))
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
