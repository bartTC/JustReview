import AppKit
import SwiftUI

/// A line as shown in the diff: its row and column (0 = stacked, 1 = left half, 2 = right half
/// of side-by-side). With `endLine`, the range of lines from `key` to it.
struct LineTarget: Equatable {
    let path: String
    let key: LineKey
    let rowID: Int
    let column: Int
    /// Last line of a range (marked lines); `rowID` is then that line's row.
    var endLine: Int? = nil

    /// The note on this line (or range).
    var anchor: NoteAnchor { NoteAnchor(path: path, key: key, endLine: endLine) }

    /// Same row and column.
    func sameLine(_ other: LineTarget) -> Bool {
        path == other.path && rowID == other.rowID && column == other.column
    }
}

/// Lines marked by clicking or dragging: from the line where the mouse went down to `end`.
struct LineMark: Equatable {
    let anchor: LineTarget
    var end: LineTarget
}

/// A line row in the diff: its file, row and column (0 stacked; 1, 2 the halves of side by
/// side).
struct LineSlot: Hashable {
    let path: String
    let rowID: Int
    let column: Int
}

/// Where a line row is on screen (in the diff's content coordinates), and what it shows.
struct LineFrame: Equatable {
    let frame: CGRect
    let target: LineTarget
}

extension RepoModel {
    /// A range from one line to another (same file, column and side, every line in between
    /// shown in the diff), or nil when the lines can't form one.
    func rangeTarget(from anchor: LineTarget?, to target: LineTarget) -> LineTarget? {
        guard let anchor, anchor.path == target.path, anchor.column == target.column,
              anchor.key.isOldSide == target.key.isOldSide, anchor.key.line != target.key.line,
              let texts = shownLineTexts(of: target.path) else { return nil }
        let (first, last) = anchor.key.line < target.key.line ? (anchor, target) : (target, anchor)
        let range = first.key.line...last.key.line
        guard range.allSatisfy({ texts.text(line: $0, oldSide: first.key.isOldSide) != nil }) else { return nil }
        return LineTarget(path: target.path, key: first.key, rowID: last.rowID, column: last.column,
                          endLine: last.key.line)
    }

    /// The marked lines as something to annotate: one line, or a range.
    var markedTarget: LineTarget? {
        guard let mark else { return nil }
        if mark.anchor.sameLine(mark.end) { return mark.anchor }
        return rangeTarget(from: mark.anchor, to: mark.end)
    }

    func isMarked(_ target: LineTarget) -> Bool {
        guard let marked = markedTarget, marked.path == target.path, marked.column == target.column
        else { return false }
        return marked.anchor.covers(target.key)
    }

    /// Code of the marked lines, without line numbers or +/- markers.
    var markedCode: String? {
        guard let marked = markedTarget, let texts = shownLineTexts(of: marked.path) else { return nil }
        return (marked.key.line...max(marked.key.line, marked.endLine ?? marked.key.line))
            .compactMap { texts.text(line: $0, oldSide: marked.key.isOldSide) }
            .joined(separator: "\n")
    }

    func copyMarkedCode() {
        guard let code = markedCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    /// Mouse down on a line: marks it, or (second click) opens the annotation editor.
    func lineMouseDown(_ target: LineTarget) {
        let now = Date()
        if let down = lineDown, down.target.sameLine(target),
           now.timeIntervalSince(down.time) < NSEvent.doubleClickInterval {
            lineDown = nil
            annotate(at: target)
            return
        }
        lineDown = (target, now)
        // A click inside the marked lines keeps them (it may be the first click of a double-click).
        if !isMarked(target) { mark = LineMark(anchor: target, end: target) }
    }

    /// Dragging from the line the mouse went down on: marks every line up to the one under the
    /// pointer (lines that can't share a note with the first one are skipped).
    func lineDragged(to location: CGPoint) {
        guard let origin = lineDown?.target else { return }
        lineDown?.time = .distantPast // a drag is not the first click of a double-click
        guard let hit = lineFrames.first(where: { slot, line in
            slot.column == origin.column && slot.path == origin.path
                && line.frame.minY <= location.y && location.y < line.frame.maxY
        })?.value.target else { return }
        if hit.sameLine(origin) || rangeTarget(from: origin, to: hit) != nil {
            let marked = LineMark(anchor: origin, end: hit)
            if mark != marked { mark = marked }
        } else if mark?.anchor != origin {
            mark = LineMark(anchor: origin, end: origin)
        }
    }

    /// Annotates the marked lines when the line is one of them, otherwise just the line.
    func annotate(at target: LineTarget) {
        if isMarked(target), let marked = markedTarget {
            beginEditing(marked.anchor)
        } else {
            mark = LineMark(anchor: target, end: target)
            beginEditing(target.anchor)
        }
    }
}
