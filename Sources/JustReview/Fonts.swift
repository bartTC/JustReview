import AppKit
import SwiftUI

/// Font preferences, stored in UserDefaults. An empty family means "system default".
enum FontPrefs {
    static let listFamily = "listFontFamily"
    static let listSize = "listFontSize"
    static let diffFamily = "diffFontFamily"
    static let diffSize = "diffFontSize"

    static let lineHeight = "diffLineHeight"
    static let defaultLineHeight = 1.0

    static let tabWidth = "tabWidth"
    static let defaultTabWidth = 4

    static var currentTabWidth: Int {
        let w = UserDefaults.standard.integer(forKey: tabWidth)
        return w > 0 ? w : defaultTabWidth
    }

    static let defaultListSize = 13.0
    static let defaultDiffSize = 12.0

    static func listFont(family: String, size: Double) -> NSFont {
        resolve(family: family, size: size) ?? .systemFont(ofSize: size)
    }

    static func diffFont(family: String, size: Double) -> NSFont {
        resolve(family: family, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func resolve(family: String, size: Double) -> NSFont? {
        guard !family.isEmpty else { return nil }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    /// Width of a digit, used to size the line-number gutter.
    static func digitWidth(_ font: NSFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    static let allFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    static let monospacedFamilies: [String] = allFamilies.filter {
        NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 12)?.isFixedPitch ?? false
    }
}
