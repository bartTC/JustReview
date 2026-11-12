import SwiftUI

struct SettingsView: View {
    @AppStorage(FontPrefs.listFamily) private var listFamily = ""
    @AppStorage(FontPrefs.listSize) private var listSize = FontPrefs.defaultListSize
    @AppStorage(FontPrefs.diffFamily) private var diffFamily = ""
    @AppStorage(FontPrefs.diffSize) private var diffSize = FontPrefs.defaultDiffSize
    @AppStorage("diffMonospacedOnly") private var monospacedOnly = true
    @AppStorage(FontPrefs.tabWidth) private var tabWidth = FontPrefs.defaultTabWidth
    @AppStorage(FontPrefs.lineHeight) private var lineHeight = FontPrefs.defaultLineHeight

    var body: some View {
        Form {
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
                Stepper(value: $lineHeight, in: 1.0...2.0, step: 0.1) {
                    Text("Line height: \(lineHeight, format: .number.precision(.fractionLength(1)))×")
                }
                Picker("Tab width", selection: $tabWidth) {
                    ForEach([2, 3, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
                }
                Text("func greet() -> String { \"hello\" }")
                    .font(Font(FontPrefs.diffFont(family: diffFamily, size: diffSize) as CTFont))
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        listFamily = ""
                        listSize = FontPrefs.defaultListSize
                        diffFamily = ""
                        diffSize = FontPrefs.defaultDiffSize
                        tabWidth = FontPrefs.defaultTabWidth
                        lineHeight = FontPrefs.defaultLineHeight
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
