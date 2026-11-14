import AppKit
import SwiftUI

/// Scene value of a repository window: the repository, the file to show first, and whether the
/// window shows just that file's diff ("Open in New Window"). `id` keeps windows distinct.
struct RepoTab: Codable, Hashable {
    var root: String
    var file: String?
    /// Opened on its own to show just the diff (no file list, no annotations pane).
    var standalone = false
    var id = UUID()
}

/// One per window: what repo it shows and how to reach it.
@MainActor
final class WindowHandle: ObservableObject {
    /// Repository root shown by the window (nil = empty window).
    var path: String?
    /// Whether the window shows the file list and annotations pane (false: just one file's diff).
    @Published var showsChrome = true
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
    /// Repository of the repository window that was last active (Settings shows its settings).
    private(set) var lastActiveRepository: String?

    /// Repositories shown in windows, in the order they were opened.
    var openRepositories: [String] {
        var seen = Set<String>()
        return handles.compactMap(\.path).filter { seen.insert($0).inserted }
    }

    func windowBecameKey(_ handle: WindowHandle) {
        if let path = handle.path { lastActiveRepository = path }
    }
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
        if let existing = handles.first(where: { $0.path == root && $0.showsChrome })
            ?? handles.first(where: { $0.path == root }) {
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

    /// Opens one file's diff in a window of its own (⌘-click, Open in New Window).
    func openFileWindow(root: URL, file: String) {
        openWindow?(value: RepoTab(root: root.path, file: file, standalone: true))
    }

    /// Called once a window shows a repository: the repository's main window gets its last
    /// size and position back (file windows open at the default size).
    func windowOpened(_ window: NSWindow, tab: RepoTab) {
        window.tabbingMode = .disallowed
        if !tab.standalone,
           !handles.contains(where: { $0.path == tab.root && $0.showsChrome && $0.window != nil && $0.window !== window }) {
            restoreFrame(window, root: tab.root)
        }
    }

    // MARK: Window frames (remembered per repository)

    private static func frameKey(_ root: String) -> String { "windowFrame:" + root }

    /// Remembers the window's size and position for its repository. Only full repository
    /// windows count (not diff-only windows), and not in full screen.
    func saveFrame(of handle: WindowHandle) {
        guard let window = handle.window, let path = handle.path, handle.showsChrome, window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey(path))
    }

    private func restoreFrame(_ window: NSWindow, root: String) {
        guard let string = UserDefaults.standard.string(forKey: Self.frameKey(root)) else { return }
        let frame = NSRectFromString(string)
        // Skip frames that are no longer on any screen (e.g. a disconnected display).
        guard frame.width >= 400, frame.height >= 300,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: true)
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
    private func saveFrame(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === handle.window else { return }
        WindowRouter.shared.saveFrame(of: handle)
    }

    @Binding var tab: RepoTab?
    @StateObject private var model = RepoModel()
    @StateObject private var handle = WindowHandle()
    @StateObject private var tabbedFor = Box<String?>(nil)   // repo the window was set up for
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model, handle: handle, showsChrome: handle.showsChrome)
            .frame(minWidth: 800, minHeight: 500)
            .background(WindowReader { window in
                handle.window = window
                if let window, let tab, tabbedFor.value != tab.root {
                    tabbedFor.value = tab.root
                    WindowRouter.shared.windowOpened(window, tab: tab)
                }
            })
            .focusedSceneObject(model)
            .focusedSceneObject(handle)
            .backForwardGestures(model: model, handle: handle)
            .annotationEditorEvents(model: model, handle: handle)
            .onAppear {
                handle.path = tab?.root
                handle.showsChrome = !(tab?.standalone ?? false)
                handle.adopt = { tab = RepoTab(root: $0) }
                WindowRouter.shared.register(handle, openWindow: openWindow)
            }
            .onDisappear { WindowRouter.shared.unregister(handle) }
            .onChange(of: tab) { handle.path = tab?.root }
            // Remember the main window's size and position for its repository.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { saveFrame($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { saveFrame($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { saveFrame($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let window = note.object as? NSWindow, window === handle.window {
                    WindowRouter.shared.windowBecameKey(handle)
                }
            }
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
