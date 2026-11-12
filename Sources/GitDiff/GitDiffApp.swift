import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GitDiffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RepoModel()
    @AppStorage("diffMode") private var mode: DiffMode = .unified

    var body: some Scene {
        Window("Git Diff", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Install Command Line Tool…") { CLIInstaller.install() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { model.chooseRepository() }
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
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Divider()
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Annotations") { model.copyAnnotations() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.annotations.isEmpty)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
