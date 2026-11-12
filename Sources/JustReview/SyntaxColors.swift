import AppKit
import SwiftUI
import Syntax

/// Shared highlighter. Queries ship in the app bundle (Contents/Resources/queries); when running
/// from the source tree (`swift run`) they're read from Resources/queries in the checkout.
let syntaxHighlighter: SyntaxHighlighter = {
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("queries")
    if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
        return SyntaxHighlighter(queriesDirectory: bundled)
    }
    let source = URL(fileURLWithPath: #filePath)            // …/Sources/JustReview/SyntaxColors.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/queries")
    return SyntaxHighlighter(queriesDirectory: source)
}()

extension SyntaxToken {
    /// Xcode-like palette with light and dark variants.
    var color: Color? {
        switch self {
        case .none: return nil
        case .keyword: return Self.dynamic(0x9B2393, 0xFC5FA3)
        case .string: return Self.dynamic(0xC41A16, 0xFC6A5D)
        case .comment: return Self.dynamic(0x5D6C79, 0x7F8C98)
        case .number: return Self.dynamic(0x1C00CF, 0xD0BF69)
        case .type: return Self.dynamic(0x0B4F79, 0x5DD8FF)
        case .function: return Self.dynamic(0x326D74, 0x67B7A4)
        case .constant, .builtin: return Self.dynamic(0x6C36A9, 0xA167E6)
        case .attribute: return Self.dynamic(0x815F03, 0xBF8555)
        case .tag: return Self.dynamic(0x0B4F79, 0x5DD8FF)
        case .property: return Self.dynamic(0x0F68A0, 0x41A1C0)
        case .escape: return Self.dynamic(0xA45C00, 0xFD8F3F)
        case .heading: return Self.dynamic(0x0B4F79, 0x5DD8FF)
        case .link: return Self.dynamic(0x0E0EFF, 0x5482FF)
        }
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}
