import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        migrateDefaultsFromGitDiff()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Dev convenience: `swift run JustReview <path>`. (`jrev` hands folders over as open events.)
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                Task { @MainActor in WindowRouter.shared.open(URL(fileURLWithPath: arg)) }
            }
        }
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
        WindowGroup("JustReview", id: "repo", for: String.self) { $path in
            RepoWindow(path: $path)
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
    @FocusedObject private var model: RepoModel?
    @FocusedObject private var handle: WindowHandle?
    @AppStorage("diffMode") private var mode: DiffMode = .unified

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Install Command Line Tool…") { CLIInstaller.install() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") { WindowRouter.shared.chooseRepository(preferring: handle) }
                .keyboardShortcut("o")
        }
        // Read-only viewer: drop the save/revert/print items.
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(before: .toolbar) {
            Button("Stacked") { mode = .unified }
                .keyboardShortcut("1")
            Button("Side by Side") { mode = .split }
                .keyboardShortcut("2")
            Divider()
            Button("Refresh") { Task { await model?.refresh() } }
                .keyboardShortcut("r")
                .disabled(model?.root == nil)
            Divider()
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Annotations") { model?.copyAnnotations() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model?.annotations.isEmpty ?? true)
        }
    }
}
