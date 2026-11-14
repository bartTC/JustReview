import AppKit
import SwiftUI

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
        .help("Click to edit")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation on \(annotation.location)")
        .accessibilityAction(named: "Edit", onEdit)
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
        .accessibilityLabel("Delete annotation")
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
                Text("Double-click a line in the diff, or click it and start typing, to annotate it.")
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
