import AppKit
import SwiftUI

// MARK: - Model

struct Annotation: Identifiable, Codable, Hashable {
    var id = UUID()
    let path: String
    let key: LineKey
    var text: String

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
            list.append(Annotation(path: path, key: key, text: trimmed))
        }
        annotations = list.sorted {
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

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(.orange)
            Text(annotation.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.orange.opacity(0.35)))
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }
}

// MARK: - Bottom pane

struct AnnotationsPane: View {
    @ObservedObject var model: RepoModel
    @StateObject private var copied = Box(false)
    @StateObject private var confirmClear = Box(false)

    var body: some View {
        VStack(spacing: 0) {
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("## " + a.location)
                                .font(.callout.monospaced().bold())
                            Text(a.text)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { model.reveal(a) }
                        .contextMenu {
                            Button("Show in Diff") { model.reveal(a) }
                            Button("Delete", role: .destructive) { model.removeAnnotation(a) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minHeight: 90, idealHeight: 160, maxHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
