import SwiftUI

struct SettingsView: View {
    @AppStorage(FontPrefs.listFamily) private var listFamily = ""
    @AppStorage(FontPrefs.listSize) private var listSize = FontPrefs.defaultListSize
    @AppStorage(FontPrefs.diffFamily) private var diffFamily = ""
    @AppStorage(FontPrefs.diffSize) private var diffSize = FontPrefs.defaultDiffSize
    @AppStorage("diffMonospacedOnly") private var monospacedOnly = true
    @AppStorage(FontPrefs.tabWidth) private var tabWidth = FontPrefs.defaultTabWidth
    @AppStorage(FontPrefs.lineHeight) private var lineHeight = FontPrefs.defaultLineHeight
    @AppStorage("syntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    @AppStorage(ThemePrefs.lightKey) private var lightTheme = ThemeStore.defaultLight
    @AppStorage(ThemePrefs.darkKey) private var darkTheme = ThemeStore.defaultDark
    @StateObject private var themeNames = Box<[String]>(ThemeStore.shared.names())

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { appearance.apply() }
            }

            Section("File List") {
                FamilyPicker(selection: $listFamily, families: FontPrefs.allFamilies, systemLabel: "System")
                SizeStepper(size: $listSize)
                Text("Sources/JustReview/Views.swift")
                    .font(Font(FontPrefs.listFont(family: listFamily, size: listSize) as CTFont))
                    .foregroundStyle(.secondary)
            }

            Section("Diff View") {
                FamilyPicker(selection: $diffFamily,
                             families: monospacedOnly ? FontPrefs.monospacedFamilies : FontPrefs.allFamilies,
                             systemLabel: "System Monospaced")
                Toggle("Show monospaced fonts only", isOn: $monospacedOnly)
                SizeStepper(size: $diffSize)
                Stepper(value: $lineHeight, in: 1.0...2.0, step: 0.05) {
                    Text("Line height: \(lineHeight, format: .number.precision(.fractionLength(2)))×")
                }
                Toggle("Syntax highlighting", isOn: $syntaxHighlighting)
                Picker("Tab width", selection: $tabWidth) {
                    ForEach([2, 3, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
                }
                Text("func greet() -> String { \"hello\" }")
                    .font(Font(FontPrefs.diffFont(family: diffFamily, size: diffSize) as CTFont))
                    .foregroundStyle(.secondary)
            }

            Section("Syntax Theme") {
                Picker("Light mode", selection: $lightTheme) {
                    ForEach(themeNames.value, id: \.self) { Text($0).tag($0) }
                }
                ThemePreview(themeName: lightTheme, dark: false)
                Picker("Dark mode", selection: $darkTheme) {
                    ForEach(themeNames.value, id: \.self) { Text($0).tag($0) }
                }
                ThemePreview(themeName: darkTheme, dark: true)
                HStack {
                    Text("Helix themes; add your own to the themes folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Themes Folder") {
                        let dir = ThemeStore.shared.userDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    Button("Reload") {
                        ThemeStore.shared.reload()
                        themeNames.value = ThemeStore.shared.names()
                    }
                }
                .controlSize(.small)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        appearance = .system
                        listFamily = ""
                        listSize = FontPrefs.defaultListSize
                        diffFamily = ""
                        diffSize = FontPrefs.defaultDiffSize
                        tabWidth = FontPrefs.defaultTabWidth
                        lineHeight = FontPrefs.defaultLineHeight
                        syntaxHighlighting = true
                        lightTheme = ThemeStore.defaultLight
                        darkTheme = ThemeStore.defaultDark
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
