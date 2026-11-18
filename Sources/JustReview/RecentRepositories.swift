import AppKit
import SwiftUI

/// The repositories opened recently (File → Open Recent). The system keeps the list, like any
/// app's recent documents, so they're also in the Dock icon's menu and the number kept follows
/// System Settings.
@MainActor
final class RecentRepositories: ObservableObject {
    static let shared = RecentRepositories()

    /// Newest first; folders that are gone are left out.
    @Published private(set) var urls: [URL] = []

    private init() {
        urls = NSDocumentController.shared.recentDocumentURLs.filter(Self.exists)
    }

    /// A repository was opened in a window: it moves to the top of the list.
    func note(_ root: URL) {
        let root = root.standardizedFileURL
        NSDocumentController.shared.noteNewRecentDocumentURL(root)
        // The system's list is updated a moment later; keep ours in step by hand.
        let limit = max(NSDocumentController.shared.maximumRecentDocumentCount, 1)
        urls = Array(([root] + urls.filter { $0.standardizedFileURL != root }).filter(Self.exists).prefix(limit))
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
    }

    private static func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// "Open Recent": the recently opened repositories, newest first, and Clear Menu.
struct RecentRepositoriesMenu: View {
    @ObservedObject private var recents = RecentRepositories.shared
    /// The window the menu was used in; an empty one takes the repository.
    let handle: WindowHandle?

    var body: some View {
        Menu("Open Recent") {
            ForEach(recents.urls, id: \.self) { url in
                Button(title(url)) { WindowRouter.shared.open(url, preferring: handle) }
            }
            if !recents.urls.isEmpty { Divider() }
            Button("Clear Menu") { recents.clear() }
                .disabled(recents.urls.isEmpty)
        }
    }

    /// The whole path ("~/Workspace/project"): worktrees and checkouts often share a folder name.
    private func title(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
