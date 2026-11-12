import AppKit
import SwiftUI

/// Scene value of a repository window. Each native tab is its own window; `id` lets several tabs
/// show the same repository, `file` is the file a new tab starts on.
struct RepoTab: Codable, Hashable {
    var root: String
    var file: String?
    /// Opened on its own to show just the diff ("Open in New Window").
    var standalone = false
    var id = UUID()
}

/// One per window: what repo it shows and how to reach it.
@MainActor
final class WindowHandle: ObservableObject {
    /// Repository root shown by the window (nil = empty window).
    var path: String?
    /// File shown in the window (its tab).
    var selection: String?
    /// Whether the window shows the file list and annotations pane. A tab dragged out of its
    /// group shows just the diff; the tabs left behind keep the full layout.
    @Published var showsChrome = true

    private var wasGrouped = false
    private var groupFrame = NSRect.zero

    /// Re-evaluates after tab-group changes (drag out/in, merge, Move Tab to New Window, close).
    /// Grouped tabs show the full layout. A tab that left its group decides once: if it moved
    /// away from where the group was, it was dragged out (just the diff); if it didn't move by
    /// the time the mouse is up, it is what's left of the group (full layout).
    func updateChrome() {
        guard let window else { return }
        if (window.tabbedWindows?.count ?? 1) > 1 {
            wasGrouped = true
            groupFrame = (window.tabGroup?.selectedWindow ?? window).frame
            setChrome(true)
        } else if wasGrouped {
            let moved = abs(window.frame.minX - groupFrame.minX) > 2 || abs(window.frame.maxY - groupFrame.maxY) > 2
            if moved {
                wasGrouped = false
                setChrome(false)
            } else if NSEvent.pressedMouseButtons == 0 {
                wasGrouped = false
                setChrome(true)
            }
        }
    }

    private func setChrome(_ shows: Bool) {
        if showsChrome != shows { showsChrome = shows }
    }
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

    // MARK: Native tabs

    /// Windows that new tabs should join, keyed by the new tab's id.
    private var tabParents: [UUID: NSWindow] = [:]

    /// Another tab/window of the repository that already shows `file`.
    func existingTab(root: URL, file: String, excluding handle: WindowHandle?) -> WindowHandle? {
        handles.first { $0 !== handle && $0.path == root.path && $0.selection == file && $0.window != nil }
    }

    /// Brings a window (or native tab) to the front.
    func show(_ handle: WindowHandle) { focus(handle) }

    /// Opens another native tab of the same repository (⌘T, "+", Open in New Tab) — or, if a tab
    /// already shows that file, switches to it instead.
    func openTab(root: URL, file: String?, from handle: WindowHandle?) {
        if let file, let existing = existingTab(root: root, file: file, excluding: handle) {
            focus(existing)
            return
        }
        let tab = RepoTab(root: root.path, file: file)
        if let window = handle?.window {
            tabParents[tab.id] = window
            // AppKit tabs a new window into the key window when their tabbing identifiers match
            // (the app's tabbing preference is "always", see AppDelegate). Repository windows
            // normally carry "repo:<root>", which a brand-new window doesn't; give the parent the
            // new window's default identifier for a moment so the tab appears in place — no
            // flash of a separate window. `configureTabbing` restores the identifier.
            if let defaultIdentifier { window.tabbingIdentifier = defaultIdentifier }
            window.makeKeyAndOrderFront(nil)
        }
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
    /// SwiftUI's tabbing identifier for new repository windows (learned from the first one).
    private var defaultIdentifier: String?

    func configureTabbing(_ window: NSWindow, tab: RepoTab) {
        if defaultIdentifier == nil { defaultIdentifier = window.tabbingIdentifier }
        let identifier = "repo:" + tab.root
        let parent = tabParents.removeValue(forKey: tab.id)
        // The repository's first window gets its last size and position back (tabs join their
        // group's frame; diff-only windows keep the default).
        if parent == nil, !tab.standalone,
           !handles.contains(where: { $0.path == tab.root && $0.window != nil && $0.window !== window }) {
            restoreFrame(window, root: tab.root)
        }
        if let parent, parent !== window {
            // Fallback if AppKit didn't tab it in by itself.
            if !(parent.tabbedWindows ?? []).contains(window) {
                parent.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
            for member in parent.tabbedWindows ?? [parent] { member.tabbingIdentifier = identifier }
        }
        // Per-repository identifier: new repositories / "Open in New Window" don't auto-tab
        // into it, and Merge All Windows only merges tabs of the same repository.
        window.tabbingIdentifier = identifier
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
    private func updateChrome() { handle.updateChrome() }

    private func saveFrame(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === handle.window else { return }
        WindowRouter.shared.saveFrame(of: handle)
    }

    @Binding var tab: RepoTab?
    @StateObject private var model = RepoModel()
    @StateObject private var handle = WindowHandle()
    @StateObject private var tabbedFor = Box<String?>(nil)   // repo the tabbing was set up for
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model, handle: handle, showsChrome: handle.showsChrome)
            .frame(minWidth: 800, minHeight: 500)
            .background(WindowReader { window in
                handle.window = window
                if let window, let tab, tabbedFor.value != tab.root {
                    tabbedFor.value = tab.root
                    WindowRouter.shared.configureTabbing(window, tab: tab)
                    updateChrome()
                }
            })
            .focusedSceneObject(model)
            .focusedSceneObject(handle)
            .onAppear {
                handle.path = tab?.root
                handle.showsChrome = !(tab?.standalone ?? false)
                handle.adopt = { tab = RepoTab(root: $0) }
                WindowRouter.shared.register(handle, openWindow: openWindow)
            }
            .onDisappear { WindowRouter.shared.unregister(handle) }
            .onChange(of: tab) {
                handle.path = tab?.root
                updateChrome()
            }
            // Tab groups change when tabs are dragged out/in, merged, closed: re-evaluate then.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in updateChrome() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { note in
                updateChrome()
                saveFrame(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
                saveFrame(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in updateChrome() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                saveFrame(note)
                DispatchQueue.main.async { updateChrome() }
            }
            .onChange(of: model.selection) { handle.selection = model.selection }
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
