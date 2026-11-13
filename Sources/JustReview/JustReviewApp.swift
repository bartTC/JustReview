import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        migrateOldDefaults()
        AppAppearance.current.apply()
        // No window tabs: one window per repository, files open in their own windows.
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.removeObject(forKey: "AppleWindowTabbingMode") // set by older versions
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Carries settings, annotations and window positions over once from earlier bundle ids:
    /// local.justreview (development builds) and local.gitdiff (when the app was called GitDiff).
    private func migrateOldDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedOldDefaults") else { return }
        for domain in ["local.justreview", "local.gitdiff"] {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedOldDefaults")
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
        .defaultSize(width: 900, height: 700)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

/// Menu commands act on the focused window's repository.
struct AppCommands: Commands {
    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSText }
    private var selectedFileExists: Bool {
        guard let model, let root = model.root, let path = model.selection else { return false }
        return FileActions.exists(path, in: root)
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    @FocusedObject private var model: RepoModel?
    @FocusedObject private var handle: WindowHandle?
    @AppStorage("diffMode") private var mode: DiffMode = .unified
    @AppStorage("wrapLines") private var wrapLines = true
    @AppStorage("annotationsCollapsed") private var annotationsCollapsed = false

    /// Switches the sidebar to a tab (⌃⌘1/2/3); a checkmark shows the current one.
    private func sidebarTabButton(_ tab: SidebarTab, key: KeyEquivalent) -> some View {
        Toggle(tab.title, isOn: Binding(get: { model?.sidebarTab == tab },
                                        set: { if $0 { model?.sidebarTab = tab } }))
            .keyboardShortcut(key, modifiers: [.control, .command])
            .disabled(model == nil || handle?.showsChrome == false)
    }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Install Command Line Tool…") { CLIInstaller.install() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") { WindowRouter.shared.chooseRepository(preferring: handle) }
                .keyboardShortcut("o")
            Divider()
            Button("Open File in Default App") {
                if let model, let root = model.root, let path = model.selection {
                    FileActions.openInDefaultApp(path, in: root)
                }
            }
            .keyboardShortcut("o", modifiers: [.option, .command])
            .disabled(!selectedFileExists)
            Button("Reveal File in Finder") {
                if let model, let root = model.root, let path = model.selection {
                    FileActions.revealInFinder(path, in: root)
                }
            }
            .disabled(!selectedFileExists)
        }
        // The file list can't be hidden: drop "Show/Hide Sidebar".
        CommandGroup(replacing: .sidebar) {}
        // Read-only viewer: no save/revert, just Close.
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
            sidebarTabButton(.changes, key: "1")
            sidebarTabButton(.files, key: "2")
            sidebarTabButton(.history, key: "3")
            Toggle("Show Annotations", isOn: Binding(get: { !annotationsCollapsed },
                                                     set: { annotationsCollapsed = !$0 }))
                .keyboardShortcut("a", modifiers: [.command, .option])
            Divider()
            Button("Refresh") { Task { await model?.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.root == nil)
            Divider()
        }
        CommandMenu("Navigate") {
            let inHistory = model?.sidebarTab == .history
            Button("Next Change") { model?.changeJump = ChangeJump(forward: true) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(inHistory)
            Button("Previous Change") { model?.changeJump = ChangeJump(forward: false) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(inHistory)
            Divider()
            Button("Next File") { model?.selectAdjacentFile(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                .disabled(handle?.showsChrome == false || inHistory)
            Button("Previous File") { model?.selectAdjacentFile(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                .disabled(handle?.showsChrome == false || inHistory)
        }
        // ⌘C copies the marked lines' code, or else all annotations — except while editing text
        // (e.g. an annotation), where Cut/Copy/Paste/Select All behave as usual.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { send(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x")
            Button("Copy") {
                if isEditingText {
                    send(#selector(NSText.copy(_:)))
                } else if model?.mark != nil {
                    model?.copyMarkedCode()
                } else {
                    model?.copyAnnotations()
                }
            }
            .keyboardShortcut("c")
            Button("Copy Annotations") { model?.copyAnnotations() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model?.annotations.isEmpty ?? true)
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
