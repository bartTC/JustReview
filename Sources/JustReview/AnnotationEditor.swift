import AppKit
import SwiftUI

// MARK: - Session

/// The note open in the inline editor: an existing one, or a new one that isn't in the list
/// until it's saved. The text being typed is in `EditorDraft`.
struct EditSession: Equatable {
    /// The note as it will be saved. A new one is tied to its lines' text when the editor
    /// opens, so saving it later doesn't depend on what the diff shows by then.
    var note: Annotation
    let isNew: Bool
}

/// Text of the open inline editor. Its own object so typing only redraws the editor, not every
/// row observing the model.
@MainActor
final class EditorDraft: ObservableObject {
    @Published var text = ""
    /// Bumped to put the keyboard focus into the editor (when it opens, or is opened again).
    @Published private(set) var focusRequest = 0
    /// The last request the editor acted on: an editor recreated after scrolling back into view
    /// doesn't grab the focus again.
    var handledFocus = 0
    /// The open editor's panel while it's on screen, to tell clicks inside it from clicks
    /// elsewhere (which save it).
    weak var panel: NSView?

    func requestFocus() { focusRequest += 1 }
}

extension RepoModel {
    /// Opens the inline editor for the note at `anchor` (new or existing) and puts the focus in
    /// it. Only one is open at a time: one open elsewhere is saved first.
    func beginEditing(_ anchor: NoteAnchor) {
        if editing?.note.anchor == anchor {
            editorDraft.requestFocus()
            return
        }
        saveEditing()
        let existing = annotation(at: anchor)
        // A new note on lines needs them in the shown diff, to tie it to their text.
        guard let note = existing ?? Annotation.new(at: anchor, in: shownLineTexts(of: anchor.path)) else { return }
        editing = EditSession(note: note, isNew: existing == nil)
        editorDraft.text = note.text
        editorDraft.requestFocus()
    }

    /// Saves the open editor's text and closes it (Return, Save, a click elsewhere, another
    /// file shown). Without text the note is deleted; a new one just isn't added.
    func saveEditing() {
        guard let session = editing else { return }
        editing = nil
        var note = session.note
        note.text = editorDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        unmark(note.anchor)
        var list = annotations
        if let i = list.firstIndex(where: { $0.id == note.id }) ?? list.firstIndex(where: { $0.anchor == note.anchor }) {
            if note.text.isEmpty { list.remove(at: i) } else { list[i].text = note.text }
        } else if !note.text.isEmpty, session.isNew || note.text != session.note.text {
            // (An existing note deleted meanwhile, e.g. in another window, isn't brought back
            // unless its text was changed here.)
            list.append(note)
        }
        if list != annotations { annotations = Self.sorted(list) }
    }

    /// Deletes the note being edited and closes the editor.
    func deleteEditing() {
        guard let session = editing else { return }
        editing = nil
        unmark(session.note.anchor)
        removeAnnotation(session.note)
    }

    /// Closes the editor (Cancel, Esc) without saving.
    func cancelEditing() {
        editing = nil
    }

    /// The marked lines have their note now: they're no longer marked. Other marked lines stay
    /// (they may be the next ones to annotate).
    private func unmark(_ anchor: NoteAnchor) {
        if anchor.key != nil, markedTarget?.anchor == anchor { mark = nil }
    }

    /// Typing with lines marked (and no text field focused) annotates them: their editor opens
    /// with the typed text, so there's no need to double-click. Keys typed before the editor has
    /// the focus go into it too. False when there's nothing to annotate.
    func typeIntoMarkedLines(_ text: String) -> Bool {
        guard let anchor = markedTarget?.anchor, anchor.path == selection || showsAllChanges else { return false }
        beginEditing(anchor)
        guard editing?.note.anchor == anchor else { return false }
        editorDraft.text += text
        return true
    }

    /// What goes under a line: its notes, with the open editor in place of the note it edits, or
    /// after them for a new note.
    func noteItems(path: String, key: LineKey) -> [NoteItem] {
        let open = editing?.note
        var items = notesEnding(path: path, key: key).map { $0.id == open?.id ? NoteItem.editor : .note($0) }
        if let open, open.path == path, open.anchor.ends(at: key), !items.contains(.editor) {
            items.append(.editor)
        }
        return items
    }

    /// The code changed under the open editor (see `validateAnnotations`). It follows its lines
    /// when they moved. When they're gone, an existing note was dropped as addressed and its
    /// editor closes; a note still being written stays on its line number while there is such a
    /// line, tied to what the line says now, so what was typed isn't lost.
    func reanchorEditor(dropped: Bool, to moved: Annotation, lines: [LineKey: String]?) {
        guard let session = editing else { return }
        let old = session.note
        guard dropped else {
            if moved != old { editing?.note = moved }
            return
        }
        if session.isNew, let key = old.key, let now = lines?.key(line: key.line, oldSide: key.isOldSide),
           var note = Annotation.new(at: NoteAnchor(path: old.path, key: now, endLine: old.endLine), in: lines) {
            note.id = old.id
            editing?.note = note
        } else {
            editing = nil
        }
    }
}

// MARK: - Inline editor

/// Window events for the annotation editor: typing with lines marked starts an annotation on
/// them (see `RepoModel.typeIntoMarkedLines`), and a click outside the open editor saves it.
private struct AnnotationEditorEvents: ViewModifier {
    @ObservedObject var model: RepoModel
    @ObservedObject var handle: WindowHandle
    @StateObject private var monitor = Box<Any?>(nil)

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor.value == nil else { return }
                monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
                    // Local monitors run on the main thread.
                    MainActor.assumeIsolated { perform(event) } ? nil : event
                }
            }
            .onDisappear {
                if let token = monitor.value { NSEvent.removeMonitor(token) }
                monitor.value = nil
            }
    }

    /// True when the event was used up (a key typed into an annotation).
    @MainActor
    private func perform(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === handle.window else { return false }
        if event.type == .leftMouseDown {
            saveOnClickOutside(event)
            return false // the click goes on as usual (marks a line, picks a file, …)
        }
        guard model.mark != nil,
              !(window.firstResponder is NSText), // typing in a text field or the editor
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              let text = event.characters, !text.isEmpty,
              // Printable only: no Return, Tab, Esc, Delete, arrows or function keys.
              text.unicodeScalars.allSatisfy({ !$0.properties.generalCategory.isControlOrPrivate })
        else { return false }
        return model.typeIntoMarkedLines(text)
    }

    /// A click anywhere but the open editor saves it (and closes it). An editor that isn't on
    /// screen (scrolled away, another file shown) is saved by any click.
    @MainActor
    private func saveOnClickOutside(_ event: NSEvent) {
        guard model.editing != nil else { return }
        if let panel = model.editorDraft.panel, panel.window === event.window,
           panel.bounds.contains(panel.convert(event.locationInWindow, from: nil)) { return }
        model.saveEditing()
    }
}

/// Sits behind the editor's panel, so the panel's frame is known in AppKit terms (see
/// `AnnotationEditorEvents.saveOnClickOutside`).
private struct EditorPanelFrame: NSViewRepresentable {
    let draft: EditorDraft

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        draft.panel = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        draft.panel = view
    }
}

extension Unicode.GeneralCategory {
    /// Control characters, and the private-use range AppKit reports arrow and function keys in.
    fileprivate var isControlOrPrivate: Bool {
        self == .control || self == .privateUse || self == .format
    }
}

extension View {
    func annotationEditorEvents(model: RepoModel, handle: WindowHandle) -> some View {
        modifier(AnnotationEditorEvents(model: model, handle: handle))
    }
}

/// A note or the open editor, as listed under a line.
enum NoteItem: Identifiable, Equatable {
    case note(Annotation)
    case editor

    var id: String {
        switch self {
        case .note(let note): note.id.uuidString
        case .editor: "editor"
        }
    }
}

/// The editor's text view: grows with its text (three lines at least), Return saves, ⇧Return
/// starts a new line, and it takes the focus once per request of the draft. (SwiftUI's
/// TextEditor neither sizes itself to its text nor lets Return do anything but break the line.)
private struct NoteTextView: NSViewRepresentable {
    @ObservedObject var draft: EditorDraft
    /// What VoiceOver calls the text view.
    let label: String
    let onSave: () -> Void
    let onCancel: () -> Void

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// The text sits this far in from the left edge (the text container's line fragment padding).
    static let inset: CGFloat = 5
    private static let minLines: CGFloat = 3

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.font = Self.font
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = Self.inset
        textView.textContainer?.widthTracksTextView = true
        textView.string = draft.text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(label)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        textView.setAccessibilityLabel(label)
        if textView.string != draft.text { textView.string = draft.text }
        guard draft.focusRequest != draft.handledFocus else { return }
        draft.handledFocus = draft.focusRequest
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
                // Caret at the end (of an existing note, or of what was typed to open it).
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
            textView.scrollToVisible(textView.bounds.insetBy(dx: 0, dy: -40)) // and the buttons below
        }
    }

    /// As tall as its text, at the width offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        let minHeight = Self.minLines * (textView.layoutManager?.defaultLineHeight(for: Self.font) ?? 16)
        guard let container = textView.textContainer, let layout = textView.layoutManager else {
            return CGSize(width: width, height: minHeight)
        }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        // The used rect leaves out the empty line after a trailing newline; the extra fragment has it.
        let used = layout.usedRect(for: container).union(layout.extraLineFragmentRect)
        return CGSize(width: width, height: max(minHeight, ceil(used.maxY)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        init(parent: NoteTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.draft.text = textView.string
        }

        /// Return saves; ⇧Return (and ⌥Return) break the line; Esc cancels (here too, not only
        /// as the Cancel button's shortcut, which is gone while the buttons are scrolled away).
        /// Not called while an input method is composing: Return and Esc are its own then.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:))
                    || selector == #selector(NSResponder.insertLineBreak(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil) // a plain "\n", not a line separator
            } else {
                parent.onSave()
            }
            return true
        }
    }
}

/// The note editor, opened under the annotated line(s) (or the file header). It stays open
/// until saved, cancelled or deleted; the text is kept in the model, so scrolling away doesn't
/// lose it.
struct InlineAnnotationEditor: View {
    @ObservedObject var model: RepoModel
    @ObservedObject var draft: EditorDraft
    let indent: CGFloat

    init(model: RepoModel, indent: CGFloat) {
        self.model = model
        self.draft = model.editorDraft
        self.indent = indent
    }

    var body: some View {
        if let session = model.editing {
            VStack(alignment: .leading, spacing: 6) {
                NoteTextView(draft: draft, label: "Annotation on \(session.note.location)",
                             onSave: { model.saveEditing() }, onCancel: { model.cancelEditing() })
                    .overlay(alignment: .topLeading) {
                        if draft.text.isEmpty {
                            // The text view has no placeholder; lined up with its text.
                            Text("Add an annotation…")
                                .font(Font(NoteTextView.font as CTFont))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, NoteTextView.inset)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                // The keys are spelled out where there's room (a half of side by side may be narrow).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        buttons(session)
                        Spacer(minLength: 16)
                        Text("Return saves  ·  ⇧Return starts a new line  ·  Esc cancels")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    HStack(spacing: 8) { buttons(session) }
                }
                .controlSize(.small)
            }
            .font(.body)
            .foregroundStyle(.primary) // not the syntax theme's text color
            // Not as wide as long unwrapped lines: the buttons stay in view.
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.leading, indent)
            .padding(.trailing, 12)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UnfoldedPanel())
            .background(EditorPanelFrame(draft: draft))
        }
    }

    @ViewBuilder
    private func buttons(_ session: EditSession) -> some View {
        Button("Save") { model.saveEditing() }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Return (⇧Return for a new line)")
            // Nothing to save yet. (An existing note saved without text is deleted.)
            .disabled(session.isNew && draft.text.allSatisfy(\.isWhitespace))
        Button("Cancel") { model.cancelEditing() }
            .keyboardShortcut(.cancelAction)
            .help("Esc")
        if !session.isNew {
            Button("Delete", role: .destructive) { model.deleteEditing() }
                .padding(.leading, 8)
                .help("Delete this annotation")
        }
    }
}

/// The editor's ground: the diff opened up between two lines — a slightly darker band, edge to
/// edge, with a soft inset shadow under the line above and a fainter one over the line below.
private struct UnfoldedPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Darker than the code in both appearances (a dark background needs more to show it).
        Color.black.opacity(colorScheme == .dark ? 0.2 : 0.045)
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.14), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 6)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.07)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 4)
            }
            .allowsHitTesting(false)
    }
}
