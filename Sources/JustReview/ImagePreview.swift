import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A binary file in the diff area: images (anything NSImage can open) are shown, the HEAD and
/// working-tree versions next to each other when both exist; other binary files get a short note.
struct BinaryPreview: View {
    let root: URL?
    let change: FileChange

    private struct Version: Identifiable {
        let id: String       // label
        let image: NSImage
        let pixelSize: CGSize
        let bytes: Int
    }

    @StateObject private var versions = Box<[Version]?>(nil)   // nil = loading / not an image

    var body: some View {
        Group {
            if let list = versions.value, !list.isEmpty {
                // Each version gets an equal share of the pane and is scaled to fit it.
                HStack(spacing: 24) {
                    ForEach(list) { version(_: $0, labeled: list.count > 1) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if versions.value != nil || !Self.isImage(change.path) {
                ContentUnavailableView("Binary File", systemImage: "doc.zipper",
                                       description: Text("Binary files can’t be shown as text."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: "\(change.id)|\(change.status)") { await load() }
        // The file watcher refreshes the diff when the image changes on disk; reload then too.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await load() }
        }
    }

    private func version(_ v: Version, labeled: Bool) -> some View {
        VStack(spacing: 8) {
            if labeled {
                Text(v.id).font(.headline).foregroundStyle(.secondary)
            }
            Image(nsImage: v.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("\(Int(v.pixelSize.width)) × \(Int(v.pixelSize.height)) px · "
                 + ByteCountFormatter.string(fromByteCount: Int64(v.bytes), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func isImage(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    private func load() async {
        guard let root, Self.isImage(change.path) else { versions.value = []; return }
        let change = self.change
        let loaded = await Task.detached { () -> [Version] in
            func make(_ label: String, _ data: Data?) -> Version? {
                guard let data, let image = NSImage(data: data) else { return nil }
                let rep = image.representations.first
                let pixels = rep.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
                // Vector formats (PDF) report 0 pixels; use the point size then.
                let size = pixels.width > 0 ? pixels : image.size
                return Version(id: label, image: image, pixelSize: size, bytes: data.count)
            }
            let hasOld = !change.isUntracked && !change.isUnchanged && change.status != "A"
            let old = hasOld ? make("HEAD", Git.showData(change.oldPath ?? change.path, in: root)) : nil
            let new = change.status == "D" ? nil
                : make("Working Copy", FileManager.default.contents(atPath: root.appendingPathComponent(change.path).path))
            return [old, new].compactMap { $0 }
        }.value
        versions.value = loaded
    }
}
