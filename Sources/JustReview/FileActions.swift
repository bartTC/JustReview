import AppKit
import SwiftUI

/// Opening a reviewed file outside JustReview: in its default app, a chosen app, or Finder.
enum FileActions {
    static func url(_ path: String, in root: URL) -> URL { root.appendingPathComponent(path) }

    /// The file exists on disk (not for deleted files).
    static func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(path, in: root).path)
    }

    static func openInDefaultApp(_ path: String, in root: URL) {
        NSWorkspace.shared.open(url(path, in: root))
    }

    static func revealInFinder(_ path: String, in root: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url(path, in: root)])
    }

    /// Apps that can open the file, default app first.
    static func apps(for path: String, in root: URL) -> [URL] {
        let file = url(path, in: root)
        let all = NSWorkspace.shared.urlsForApplications(toOpen: file)
        guard let main = NSWorkspace.shared.urlForApplication(toOpen: file) else { return all }
        return [main] + all.filter { $0 != main }
    }

    static func open(_ path: String, in root: URL, with app: URL) {
        NSWorkspace.shared.open([url(path, in: root)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// "Open in Default App / Open With / Reveal in Finder" menu items for a file.
struct FileOpenMenuItems: View {
    let root: URL?
    let path: String

    var body: some View {
        if let root, FileActions.exists(path, in: root) {
            Button("Open in Default App") { FileActions.openInDefaultApp(path, in: root) }
            Menu("Open With") {
                let apps = FileActions.apps(for: path, in: root)
                ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                    Button(FileActions.appName(app) + (index == 0 ? " (default)" : "")) {
                        FileActions.open(path, in: root, with: app)
                    }
                    if index == 0 && apps.count > 1 { Divider() }
                }
            }
            Button("Reveal in Finder") { FileActions.revealInFinder(path, in: root) }
        }
    }
}
