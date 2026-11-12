import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        migrateDefaultsFromGitDiff()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

    }

    /// The "+" button in a native tab bar: a new tab of the focused repository.
    @objc func newWindowForTab(_ sender: Any?) {
        Task { @MainActor in WindowRouter.shared.openTabForKeyWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The app used to be called GitDiff (bundle id local.gitdiff): carry over settings and annotations once.
    private func migrateDefaultsFromGitDiff() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromGitDiff") else { return }
        if let old = defaults.persistentDomain(forName: "local.gitdiff") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromGitDiff")
    }
}

@main
struct JustReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window per repository; the window's value is the repo root path.
        WindowGroup("JustReview", id: "repo", for: RepoTab.self) { $tab in
            RepoWindow(tab: $tab)
        }
        // Don't bring back old (often empty) windows on launch; jrev decides what to show.
        .restorationBehavior(.disabled)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

/// Menu commands act on the focused window's repository.
struct AppCommands: Commands {
    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    @FocusedObject private var model: RepoModel?
    @FocusedObject private var handle: WindowHandle?
    @AppStorage("diffMode") private var mode: DiffMode = .unified
    @AppStorage("showAllFiles") private var showAll = false
    @AppStorage("wrapLines") private var wrapLines = true
    @AppStorage("annotationsCollapsed") private var annotationsCollapsed = false

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Install Command Line Tool…") { CLIInstaller.install() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                if let model, let root = model.root {
                    WindowRouter.shared.openTab(root: root, file: model.selection, from: handle)
                }
            }
            .keyboardShortcut("t")
            .disabled(model?.root == nil)
            Button("Open Repository…") { WindowRouter.shared.chooseRepository(preferring: handle) }
                .keyboardShortcut("o")
        }
        // The file list can't be hidden: drop "Show/Hide Sidebar".
        CommandGroup(replacing: .sidebar) {}
        // Read-only viewer: no save/revert, just Close (⌘W closes the tab or window).
        CommandGroup(replacing: .saveItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(before: .toolbar) {
            Button("Stacked") { mode = .unified }
                .keyboardShortcut("1")
            Button("Side by Side") { mode = .split }
                .keyboardShortcut("2")
            Toggle("Wrap Lines", isOn: $wrapLines)
                .keyboardShortcut("z", modifiers: .option)
            Divider()
            Toggle("Show All Files", isOn: $showAll)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Toggle("Show Annotations", isOn: Binding(get: { !annotationsCollapsed },
                                                     set: { annotationsCollapsed = !$0 }))
                .keyboardShortcut("a", modifiers: [.command, .option])
            Divider()
            Button("Refresh") { Task { await model?.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.root == nil)
            Divider()
        }
        // ⌘C copies all annotations — except while editing text (e.g. an annotation), where
        // Cut/Copy/Paste/Select All behave as usual.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { send(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x")
            Button("Copy") {
                if isEditingText { send(#selector(NSText.copy(_:))) } else { model?.copyAnnotations() }
            }
            .keyboardShortcut("c")
            Button("Paste") { send(#selector(NSText.paste(_:))) }
                .keyboardShortcut("v")
            Button("Select All") { send(#selector(NSText.selectAll(_:))) }
                .keyboardShortcut("a")
            Divider()
            Button("Clear Annotations…") { model?.confirmClearAnnotations() }
                .keyboardShortcut("r")
                .disabled(model?.annotations.isEmpty ?? true)
        }
    }
}
