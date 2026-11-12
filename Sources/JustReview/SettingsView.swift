import SwiftUI

/// The settings window: a toolbar of panes (macOS HIG). Each pane is sized to its content, so
/// nothing scrolls; the window title follows the pane and the last pane is reopened.
struct SettingsView: View {
    enum Pane: String { case general, fonts, themes }

    @AppStorage("settingsPane") private var pane: Pane = .general

    var body: some View {
        TabView(selection: $pane) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general)
            FontSettings()
                .tabItem { Label("Fonts", systemImage: "textformat") }
                .tag(Pane.fonts)
            ThemeSettings()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
                .tag(Pane.themes)
        }
    }
}

/// Common layout of a settings pane: grouped form at a fixed width, as tall as its content,
/// with optional extra buttons and a "Restore Defaults" button (for just that pane) below it.
private struct SettingsPane<Content: View, Accessory: View>: View {
    let restoreDefaults: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder var accessory: Accessory

    init(restoreDefaults: @escaping () -> Void, @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.restoreDefaults = restoreDefaults
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
                .scrollDisabled(true)
            HStack {
                accessory
                Spacer()
                Button("Restore Defaults", action: restoreDefaults)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    @AppStorage("syntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage(FontPrefs.tabWidth) private var tabWidth = FontPrefs.defaultTabWidth

    var body: some View {
        SettingsPane {
            appearance = .system
            syntaxHighlighting = true
            tabWidth = FontPrefs.defaultTabWidth
        } content: {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { appearance.apply() }
            }
            Section {
                Toggle("Syntax highlighting", isOn: $syntaxHighlighting)
                Picker("Tab width", selection: $tabWidth) {
                    ForEach([2, 3, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
                }
            }
        }
    }
}

private struct FontSettings: View {
    @AppStorage(FontPrefs.listFamily) private var listFamily = ""
    @AppStorage(FontPrefs.listSize) private var listSize = FontPrefs.defaultListSize
    @AppStorage(FontPrefs.diffFamily) private var diffFamily = ""
    @AppStorage(FontPrefs.diffSize) private var diffSize = FontPrefs.defaultDiffSize
    @AppStorage("diffMonospacedOnly") private var monospacedOnly = true
    @AppStorage(FontPrefs.lineHeight) private var lineHeight = FontPrefs.defaultLineHeight

    var body: some View {
        SettingsPane {
            listFamily = ""
            listSize = FontPrefs.defaultListSize
            diffFamily = ""
            diffSize = FontPrefs.defaultDiffSize
            monospacedOnly = true
            lineHeight = FontPrefs.defaultLineHeight
        } content: {
            Section("File List") {
                FamilyPicker(selection: $listFamily, families: FontPrefs.allFamilies, systemLabel: "System")
                SizeStepper(size: $listSize)
                Text("Sources/JustReview/Views.swift")
                    .font(Font(FontPrefs.listFont(family: listFamily, size: listSize) as CTFont))
                    .foregroundStyle(.secondary)
            }
            Section("Diff") {
                FamilyPicker(selection: $diffFamily,
                             families: monospacedOnly ? FontPrefs.monospacedFamilies : FontPrefs.allFamilies,
                             systemLabel: "System Monospaced")
                Toggle("Show monospaced fonts only", isOn: $monospacedOnly)
                SizeStepper(size: $diffSize)
                Stepper(value: $lineHeight, in: 1.0...2.0, step: 0.05) {
                    Text("Line height: \(lineHeight, format: .number.precision(.fractionLength(2)))×")
                }
                Text("func greet() -> String { \"hello\" }")
                    .font(Font(FontPrefs.diffFont(family: diffFamily, size: diffSize) as CTFont))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ThemeSettings: View {
    @AppStorage(ThemePrefs.lightKey) private var lightTheme = ThemeStore.defaultLight
    @AppStorage(ThemePrefs.darkKey) private var darkTheme = ThemeStore.defaultDark
    @StateObject private var themeNames = Box<[String]>(ThemeStore.shared.names())

    var body: some View {
        SettingsPane {
            lightTheme = ThemeStore.defaultLight
            darkTheme = ThemeStore.defaultDark
        } content: {
            Section("Light Mode") {
                Picker("Theme", selection: $lightTheme) {
                    ForEach(themeNames.value, id: \.self) { Text($0).tag($0) }
                }
                ThemePreview(themeName: lightTheme, dark: false)
            }
            Section {
                Picker("Theme", selection: $darkTheme) {
                    ForEach(themeNames.value, id: \.self) { Text($0).tag($0) }
                }
                ThemePreview(themeName: darkTheme, dark: true)
            } header: {
                Text("Dark Mode")
            } footer: {
                Text("Helix themes. Add your own to the themes folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } accessory: {
            Button("Open Themes Folder") {
                let dir = ThemeStore.shared.userDirectory
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
            Button("Reload") {
                ThemeStore.shared.reload()
                themeNames.value = ThemeStore.shared.names()
            }
            .help("Reload themes from disk")
        }
    }
}

private struct FamilyPicker: View {
    @Binding var selection: String
    let families: [String]
    let systemLabel: String

    var body: some View {
        // Keep the current choice visible even if it's filtered out of the list.
        let options = (!selection.isEmpty && !families.contains(selection)) ? [selection] + families : families
        Picker("Font", selection: $selection) {
            Text(systemLabel).tag("")
            Divider()
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
    }
}

private struct SizeStepper: View {
    @Binding var size: Double

    var body: some View {
        Stepper(value: $size, in: 8...32, step: 1) {
            Text("Size: \(Int(size)) pt")
        }
    }
}
