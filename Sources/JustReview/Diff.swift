import AppKit
import SwiftUI
import Syntax

// MARK: - Parsed diff

struct DiffLine {
    enum Kind { case context, added, removed }
    let kind: Kind
    var text: String
    let oldNo: Int?
    let newNo: Int?
    var noNewlineAtEnd = false
}

struct Hunk {
    let header: String
    var lines: [DiffLine] = []
}

struct FileDiff {
    var hunks: [Hunk] = []
    var isBinary = false
    var notes: [String] = []
}

enum DiffParser {
    static func parse(_ text: String) -> FileDiff {
        var diff = FileDiff()
        var hunk: Hunk?
        var oldNo = 0, newNo = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }

            if line.hasPrefix("@@") {
                if let h = hunk { diff.hunks.append(h) }
                (oldNo, newNo) = parseHunkHeader(line)
                hunk = Hunk(header: line)
                continue
            }

            guard hunk != nil else {
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                    diff.isBinary = true
                } else if let note = metaNote(line) {
                    diff.notes.append(note)
                }
                continue
            }

            guard let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case " ":
                hunk!.lines.append(DiffLine(kind: .context, text: body, oldNo: oldNo, newNo: newNo))
                oldNo += 1; newNo += 1
            case "-":
                hunk!.lines.append(DiffLine(kind: .removed, text: body, oldNo: oldNo, newNo: nil))
                oldNo += 1
            case "+":
                hunk!.lines.append(DiffLine(kind: .added, text: body, oldNo: nil, newNo: newNo))
                newNo += 1
            case "\\":
                if !hunk!.lines.isEmpty { hunk!.lines[hunk!.lines.count - 1].noNewlineAtEnd = true }
            default:
                if line.hasPrefix("diff ") {
                    diff.hunks.append(hunk!)
                    hunk = nil
                }
            }
        }
        if let h = hunk { diff.hunks.append(h) }
        return diff
    }

    static func lineTexts(_ diff: FileDiff) -> [LineKey: String] {
        var map: [LineKey: String] = [:]
        for hunk in diff.hunks {
            for line in hunk.lines { map[DiffRenderer.key(line)] = line.text }
        }
        return map
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return (0, 0) }
        func start(_ s: Substring) -> Int {
            Int(s.dropFirst().split(separator: ",").first ?? "0") ?? 0
        }
        return (start(parts[1]), start(parts[2]))
    }

    private static func metaNote(_ line: String) -> String? {
        let prefixes = ["new file mode", "deleted file mode", "old mode", "new mode",
                        "similarity index", "rename from", "rename to", "copy from", "copy to"]
        return prefixes.contains(where: line.hasPrefix) ? line : nil
    }
}

// MARK: - Render model

enum RowKind: String { case context, added, removed }

/// Identifies a line within a file's diff: removed lines by old line number,
/// added and context lines by new line number.
struct LineKey: Hashable, Codable {
    let side: RowKind
    let line: Int
}

extension RowKind: Codable {}

/// A hunk header ("@@ -41,6 +42,13 @@ struct ContentView: View {"), parsed for display.
struct HunkInfo: Equatable {
    /// The enclosing function or type git found for the hunk (may be empty).
    let context: String
    /// Unchanged lines between the previous hunk (or the start of the file) and this one.
    let hiddenAbove: Int
    /// The first hunk of the file (no gap above it).
    let isFirst: Bool

    init(header: String, previousOldEnd: Int, isFirst: Bool) {
        // "@@ -a,b +c,d @@ context": the part after the second "@@".
        let parts = header.components(separatedBy: "@@")
        context = parts.count > 2 ? parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces) : ""
        let ranges = (parts.count > 1 ? parts[1] : "").split(separator: " ")
        let oldStart = ranges.first.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
        hiddenAbove = max(0, oldStart - 1 - previousOldEnd)
        self.isFirst = isFirst
    }

    /// Last old-file line covered by a hunk with this header.
    static func oldEnd(of header: String) -> Int {
        let parts = header.components(separatedBy: "@@")
        guard parts.count > 1, let old = parts[1].split(separator: " ").first else { return 0 }
        let numbers = old.dropFirst().split(separator: ",").compactMap { Int($0) }
        guard let start = numbers.first else { return 0 }
        let count = numbers.count > 1 ? numbers[1] : 1
        return start + count - 1
    }
}

struct UnifiedRow: Identifiable {
    let id: Int
    let header: String?
    let key: LineKey?
    let kind: RowKind
    let oldNo: Int?
    let newNo: Int?
    let text: AttributedString
    /// Set on hunk header rows.
    var hunk: HunkInfo? = nil
}

struct SideCell {
    let key: LineKey
    let kind: RowKind
    let number: Int?
    let text: AttributedString
}

struct SplitRow: Identifiable {
    let id: Int
    let header: String?
    let left: SideCell?
    let right: SideCell?
    /// Set on hunk header rows.
    var hunk: HunkInfo? = nil
}

struct RenderedDiff {
    let changeID: String
    let rawText: String
    let unified: [UnifiedRow]
    let split: [SplitRow]
    let tabWidth: Int
    let syntaxEnabled: Bool
    let themeName: String
    let maxLineNumber: Int
    /// Longest displayed line, in characters (sizes the content when lines don't wrap).
    let maxColumns: Int
    let added: Int
    let removed: Int
    let isBinary: Bool
    let notes: [String]
    /// Raw text of every line in the diff, used to anchor annotations to content.
    let lineTexts: [LineKey: String]
}

enum DiffStyle {
    /// Opaque colors of a changed line: code area, line-number column (stronger), changed-word
    /// highlight, and the text in the line-number column.
    struct Tint {
        let row: NSColor, gutter: NSColor, highlight: NSColor, gutterText: NSColor
    }

    static func tint(_ kind: RowKind, dark: Bool) -> Tint? {
        switch (kind, dark) {
        case (.added, false):
            Tint(row: NSColor(hex: 0xE5FDE5), gutter: NSColor(hex: 0x8FD48C),
                 highlight: NSColor(hex: 0xBDEDBE), gutterText: .white)
        case (.removed, false):
            Tint(row: NSColor(hex: 0xFADCD8), gutter: NSColor(hex: 0xEE9B93),
                 highlight: NSColor(hex: 0xF4BCB5), gutterText: .white)
        case (.added, true):
            Tint(row: NSColor(hex: 0x1F3A25), gutter: NSColor(hex: 0x2F6A3B),
                 highlight: NSColor(hex: 0x2E5A36), gutterText: NSColor(hex: 0xD5F2D8))
        case (.removed, true):
            Tint(row: NSColor(hex: 0x3D2325), gutter: NSColor(hex: 0x7A3836),
                 highlight: NSColor(hex: 0x5C2E30), gutterText: NSColor(hex: 0xF7D9D6))
        case (.context, _):
            nil
        }
    }

    /// A color that follows the view's light/dark appearance.
    private static func dynamic(_ kind: RowKind, _ pick: @escaping (Tint) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return tint(kind, dark: dark).map(pick) ?? .clear
        })
    }

    static let hunkBG = Color.accentColor.opacity(0.06)
    static let hunkEdge = Color.accentColor.opacity(0.14)
    static let fillerBG = Color.secondary.opacity(0.06)

    /// The color behind a changed span (the renderer knows the appearance it renders for).
    static func highlightBackground(_ kind: RowKind, dark: Bool) -> NSColor? {
        tint(kind, dark: dark)?.highlight
    }

    static func background(_ kind: RowKind) -> Color {
        kind == .context ? .clear : dynamic(kind, \.row)
    }

    static func gutterBackground(_ kind: RowKind) -> Color {
        kind == .context ? .clear : dynamic(kind, \.gutter)
    }

    /// Line-number/marker color on a changed line's gutter (nil = the usual line-number color).
    static func gutterText(_ kind: RowKind) -> Color? {
        kind == .context ? nil : dynamic(kind, \.gutterText)
    }

    static func marker(_ kind: RowKind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }
}

enum DiffRenderer {
    /// Per-line syntax tokens of the old (HEAD) and new (working tree) file versions.
    struct Syntax {
        var old: [[TokenRun]]?
        var new: [[TokenRun]]?
        static let none = Syntax()
    }

    static func render(_ raw: String, changeID: String, tabWidth: Int, showHunkHeaders: Bool = true,
                       syntax: Syntax = .none, syntaxEnabled: Bool = false,
                       styler: ThemeStyler? = nil, dark: Bool = false) -> RenderedDiff {
        let diff = DiffParser.parse(raw)
        let lineTexts = DiffParser.lineTexts(diff)

        /// Syntax runs for a diff line, looked up in the file version it belongs to.
        func tokens(_ line: DiffLine) -> [TokenRun] {
            let (lines, number) = line.kind == .removed ? (syntax.old, line.oldNo) : (syntax.new, line.newNo)
            guard let lines, let number, number >= 1, number <= lines.count else { return [] }
            return lines[number - 1]
        }
        func attributed(_ line: DiffLine, highlight: Range<Int>?, color: Color) -> AttributedString {
            DiffRenderer.attributed(line, highlight: highlight, color: color, tokens: tokens(line),
                                    styler: styler, tabWidth: tabWidth,
                                    highlightBackground: highlight == nil ? nil
                                        : DiffStyle.highlightBackground(line.kind == .added ? .added : .removed, dark: dark))
        }
        var unified: [UnifiedRow] = []
        var split: [SplitRow] = []
        var maxNo = 0, added = 0, removed = 0

        var previousOldEnd = 0
        for (index, hunk) in diff.hunks.enumerated() {
            if showHunkHeaders {
                let info = HunkInfo(header: hunk.header, previousOldEnd: previousOldEnd, isFirst: index == 0)
                unified.append(UnifiedRow(id: unified.count, header: hunk.header, key: nil, kind: .context,
                                          oldNo: nil, newNo: nil, text: AttributedString(), hunk: info))
                split.append(SplitRow(id: split.count, header: hunk.header, left: nil, right: nil, hunk: info))
            }
            previousOldEnd = HunkInfo.oldEnd(of: hunk.header)

            var rem: [DiffLine] = []
            var add: [DiffLine] = []

            // Emit a block of removals + additions, pairing them up for side-by-side
            // and highlighting the changed span within each paired line.
            func flush() {
                guard !rem.isEmpty || !add.isEmpty else { return }
                let removedHL = Color(nsColor: DiffStyle.highlightBackground(.removed, dark: dark) ?? .clear)
                let addedHL = Color(nsColor: DiffStyle.highlightBackground(.added, dark: dark) ?? .clear)
                var remText = rem.map { attributed($0, highlight: nil, color: removedHL) }
                var addText = add.map { attributed($0, highlight: nil, color: addedHL) }
                for i in 0..<min(rem.count, add.count) {
                    let (a, b) = changedRanges(rem[i].text, add[i].text)
                    remText[i] = attributed(rem[i], highlight: a, color: removedHL)
                    addText[i] = attributed(add[i], highlight: b, color: addedHL)
                }
                for (i, l) in rem.enumerated() {
                    unified.append(UnifiedRow(id: unified.count, header: nil, key: key(l), kind: .removed,
                                              oldNo: l.oldNo, newNo: nil, text: remText[i]))
                }
                for (i, l) in add.enumerated() {
                    unified.append(UnifiedRow(id: unified.count, header: nil, key: key(l), kind: .added,
                                              oldNo: nil, newNo: l.newNo, text: addText[i]))
                }
                for i in 0..<max(rem.count, add.count) {
                    let left = i < rem.count ? SideCell(key: key(rem[i]), kind: .removed, number: rem[i].oldNo, text: remText[i]) : nil
                    let right = i < add.count ? SideCell(key: key(add[i]), kind: .added, number: add[i].newNo, text: addText[i]) : nil
                    split.append(SplitRow(id: split.count, header: nil, left: left, right: right))
                }
                rem.removeAll()
                add.removeAll()
            }

            for line in hunk.lines {
                maxNo = max(maxNo, line.oldNo ?? 0, line.newNo ?? 0)
                switch line.kind {
                case .removed:
                    if !add.isEmpty { flush() }
                    rem.append(line)
                    removed += 1
                case .added:
                    add.append(line)
                    added += 1
                case .context:
                    flush()
                    let t = attributed(line, highlight: nil, color: .clear)
                    unified.append(UnifiedRow(id: unified.count, header: nil, key: key(line), kind: .context,
                                              oldNo: line.oldNo, newNo: line.newNo, text: t))
                    split.append(SplitRow(id: split.count, header: nil,
                                          left: SideCell(key: key(line), kind: .context, number: line.oldNo, text: t),
                                          right: SideCell(key: key(line), kind: .context, number: line.newNo, text: t)))
                }
            }
            flush()
        }

        return RenderedDiff(changeID: changeID, rawText: raw, unified: unified, split: split,
                            tabWidth: tabWidth, syntaxEnabled: syntaxEnabled,
                            themeName: styler?.theme.name ?? "", maxLineNumber: maxNo,
                            maxColumns: unified.map { $0.text.characters.count }.max() ?? 0,
                            added: added, removed: removed,
                            isBinary: diff.isBinary, notes: diff.notes, lineTexts: lineTexts)
    }

    static func key(_ line: DiffLine) -> LineKey {
        switch line.kind {
        case .removed: return LineKey(side: .removed, line: line.oldNo ?? 0)
        case .added: return LineKey(side: .added, line: line.newNo ?? 0)
        case .context: return LineKey(side: .context, line: line.newNo ?? 0)
        }
    }

    /// Common prefix/suffix trim: returns the differing character range in each line.
    private static func changedRanges(_ a: String, _ b: String) -> (Range<Int>?, Range<Int>?) {
        let ac = Array(a), bc = Array(b)
        var p = 0
        while p < ac.count, p < bc.count, ac[p] == bc[p] { p += 1 }
        var s = 0
        while s < ac.count - p, s < bc.count - p, ac[ac.count - 1 - s] == bc[bc.count - 1 - s] { s += 1 }
        // Nothing in common worth pointing out: leave the whole line plain.
        if p + s < 2 { return (nil, nil) }
        return (p..<(ac.count - s), p..<(bc.count - s))
    }

    /// Builds a display line: tabs expanded to tab stops, syntax colors, and the changed-span
    /// background. `highlight` and token ranges are Character offsets in the raw (unexpanded) line.
    fileprivate static func attributed(_ line: DiffLine, highlight: Range<Int>?, color: Color,
                                       tokens: [TokenRun], styler: ThemeStyler?, tabWidth: Int,
                                       highlightBackground: NSColor? = nil) -> AttributedString {
        // Expand tabs, remembering where each raw character lands.
        var text = ""
        var columns: [Int] = []
        columns.reserveCapacity(line.text.count + 1)
        var column = 0
        for ch in line.text {
            columns.append(column)
            if ch == "\t" {
                let n = tabWidth - column % tabWidth
                text += String(repeating: " ", count: n)
                column += n
            } else {
                text.append(ch)
                column += 1
            }
        }
        columns.append(column)

        var result = AttributedString(text)
        func span(_ r: Range<Int>) -> Range<AttributedString.Index>? {
            let lo = columns[min(max(r.lowerBound, 0), columns.count - 1)]
            let hi = columns[min(max(r.upperBound, 0), columns.count - 1)]
            guard lo < hi else { return nil }
            let start = result.characters.index(result.startIndex, offsetBy: lo)
            return start..<result.characters.index(start, offsetBy: hi - lo)
        }
        if let styler {
            for run in tokens {
                guard let style = styler.style(for: run.scope), let r = span(run.range) else { continue }
                if let fg = style.fg {
                    result[r].foregroundColor = Color(nsColor: fg)
                    // Dim colors (comments especially) wash out on the changed-span tint.
                    if let h = highlight, let bg = highlightBackground,
                       let ir = span(max(h.lowerBound, run.range.lowerBound)..<max(min(h.upperBound, run.range.upperBound), max(h.lowerBound, run.range.lowerBound))) {
                        result[ir].foregroundColor = Color(nsColor: fg.readable(on: bg))
                    }
                }
                if style.bold || style.italic {
                    var intent: InlinePresentationIntent = []
                    if style.bold { intent.insert(.stronglyEmphasized) }
                    if style.italic { intent.insert(.emphasized) }
                    result[r].inlinePresentationIntent = intent
                }
            }
        }
        if let h = highlight, let r = span(h) { result[r].backgroundColor = color }

        if line.noNewlineAtEnd {
            var note = AttributedString("  ⊘ no newline at end of file")
            note.foregroundColor = .secondary
            result += note
        }
        return result
    }
}
