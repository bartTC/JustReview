import AppKit
import SwiftUI

/// Scene value of a repository window. Each native tab is its own window; `id` lets several tabs
/// show the same repository, `file` is the file a new tab starts on.
struct RepoTab: Codable, Hashable {
    var root: String
    var file: String?
    var id = UUID()
}

/// One per window: what repo it shows and how to reach it.
@MainActor
final class WindowHandle: ObservableObject {
    /// Repository root shown by the window (nil = empty window).
    var path: String?
    weak var window: NSWindow?
    /// Points the window at a repository (sets the window's scene value).
    var adopt: (String) -> Void = { _ in }
}

/// Routes "open this repository" requests (from `jrev`, Finder/Dock, ⌘O, drag & drop) to windows:
/// a window already showing the repo is brought to the front, otherwise an empty window takes it,
/// otherwise a new window opens. One window per repository.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private var handles: [WindowHandle] = []
    private var openWindow: OpenWindowAction?
    private var pending: [(URL, WindowHandle?)] = []

    // MARK: Window registration

    func register(_ handle: WindowHandle, openWindow: OpenWindowAction) {
        if !handles.contains(where: { $0 === handle }) { handles.append(handle) }
        self.openWindow = openWindow
        // Requests that arrived before any window existed (cold launch via `jrev`).
        let queued = pending
        pending = []
        for (url, preferred) in queued { open(url, preferring: preferred ?? handle) }
    }

    func unregister(_ handle: WindowHandle) {
        handles.removeAll { $0 === handle }
    }

    // MARK: Requests

    /// - Parameter preferring: the window the request came from; it is reused if it is empty.
    func open(_ url: URL, preferring: WindowHandle? = nil) {
        guard openWindow != nil else {
            pending.append((url, preferring))
            return
        }
        Task {
            let root: URL
            do {
                root = try await Task.detached { try Git.toplevel(for: url) }.value
            } catch {
                Self.alert("Can’t open repository", error.localizedDescription)
                return
            }
            route(root.path, preferring: preferring)
        }
    }

    func chooseRepository(preferring: WindowHandle? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repository"
        if panel.runModal() == .OK, let url = panel.url {
            open(url, preferring: preferring)
        }
    }

    private func route(_ root: String, preferring: WindowHandle?) {
        if let existing = handles.first(where: { $0.path == root }) {
            focus(existing)
        } else if let preferring, preferring.path == nil {
            preferring.adopt(root)
            focus(preferring)
        } else if let empty = handles.first(where: { $0.path == nil }) {
            empty.adopt(root)
            focus(empty)
        } else {
            openWindow?(value: RepoTab(root: root))
        }
    }

    // MARK: Native tabs

    /// Windows that new tabs should join, keyed by the new tab's id.
    private var tabParents: [UUID: NSWindow] = [:]

    /// Opens another native tab of the same repository (⌘T, "+", Open in New Tab).
    func openTab(root: URL, file: String?, from handle: WindowHandle?) {
        let tab = RepoTab(root: root.path, file: file)
        if let window = handle?.window { tabParents[tab.id] = window }
        openWindow?(value: tab)
    }

    /// "+" in the tab bar / New Tab with no repository window focused.
    func openTabForKeyWindow() {
        guard let handle = handles.first(where: { $0.window == NSApp.keyWindow }),
              let path = handle.path else { NSSound.beep(); return }
        openTab(root: URL(fileURLWithPath: path), file: nil, from: handle)
    }

    /// Called once a repository window exists: tags it for its repository's tab group and, if it
    /// was opened as a tab, adds it to the window it was opened from.
    func configureTabbing(_ window: NSWindow, tab: RepoTab) {
        window.tabbingIdentifier = "repo:" + tab.root
        window.tabbingMode = .preferred
        if let parent = tabParents.removeValue(forKey: tab.id), parent !== window,
           parent.tabbingIdentifier == window.tabbingIdentifier {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func focus(_ handle: WindowHandle) {
        guard let window = handle.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

/// Reports the NSWindow hosting a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}

/// A repository window: owns its model and keeps the router informed.
struct RepoWindow: View {
    @Binding var tab: RepoTab?
    @StateObject private var model = RepoModel()
    @StateObject private var handle = WindowHandle()
    @StateObject private var tabbedFor = Box<String?>(nil)   // repo the tabbing was set up for
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model, handle: handle)
            .frame(minWidth: 800, minHeight: 500)
            .background(WindowReader { window in
                handle.window = window
                if let window, let tab, tabbedFor.value != tab.root {
                    tabbedFor.value = tab.root
                    WindowRouter.shared.configureTabbing(window, tab: tab)
                }
            })
            .focusedSceneObject(model)
            .focusedSceneObject(handle)
            .onAppear {
                handle.path = tab?.root
                handle.adopt = { tab = RepoTab(root: $0) }
                WindowRouter.shared.register(handle, openWindow: openWindow)
            }
            .onDisappear { WindowRouter.shared.unregister(handle) }
            .onChange(of: tab) { handle.path = tab?.root }
            // Folders opened from outside (jrev → `open -a JustReview <dir>`, Finder, Dock) are
            // delivered to an existing window instead of spawning one; SwiftUI only creates a
            // window when none exists. The router then focuses/reuses/opens the right window.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onOpenURL { url in WindowRouter.shared.open(url, preferring: handle) }
            .task(id: tab?.root) {
                guard let tab else { return }
                await model.open(URL(fileURLWithPath: tab.root), reportErrors: true, select: tab.file)
            }
    }
}
