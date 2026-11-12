import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

// MARK: - Languages

public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case python, javascript, typescript, tsx, json, css, html, bash, go, rust, swift, yaml, markdown, toml

    /// Picks the grammar from a file name; nil means "no highlighting".
    public static func detect(path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "py", "pyi": return .python
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "mts", "cts": return .typescript
        case "tsx": return .tsx
        case "json": return .json
        case "css": return .css
        case "html", "htm": return .html
        case "sh", "bash", "zsh": return .bash
        case "go": return .go
        case "rs": return .rust
        case "swift": return .swift
        case "yml", "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "toml": return .toml
        default:
            return [".bashrc", ".zshrc", ".bash_profile", ".profile"].contains(name) ? .bash : nil
        }
    }

    fileprivate var language: Language {
        let pointer: OpaquePointer = switch self {
        case .python: tree_sitter_python()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .json: tree_sitter_json()
        case .css: tree_sitter_css()
        case .html: tree_sitter_html()
        case .bash: tree_sitter_bash()
        case .go: tree_sitter_go()
        case .rust: tree_sitter_rust()
        case .swift: tree_sitter_swift()
        case .yaml: tree_sitter_yaml()
        case .markdown: tree_sitter_markdown()
        case .toml: tree_sitter_toml()
        }
        return Language(pointer)
    }
}

// MARK: - Scopes

/// Highlight scopes use Helix theme names ("keyword.control.import", "constant.numeric", …).
/// Upstream tree-sitter queries use slightly different capture names; these are translated.
public enum SyntaxScope {
    private static let aliases: [String: String] = [
        "number": "constant.numeric",
        "float": "constant.numeric.float",
        "boolean": "constant.builtin.boolean",
        "character": "constant.character",
        "escape": "constant.character.escape",
        "string.escape": "constant.character.escape",
        "string.regex": "string.regexp",
        "string.special.key": "variable.other.member",
        "property": "variable.other.member",
        "field": "variable.other.member",
        "variable.member": "variable.other.member",
        "parameter": "variable.parameter",
        "method": "function.method",
        "method.call": "function.method",
        "function.call": "function",
        "module": "namespace",
        "include": "keyword.control.import",
        "conditional": "keyword.control.conditional",
        "repeat": "keyword.control.repeat",
        "exception": "keyword.control.exception",
        "keyword.return": "keyword.control.return",
        "storageclass": "keyword.storage",
        "decorator": "attribute",
        "tag.attribute": "attribute",
        "text.title": "markup.heading",
        "text.literal": "markup.raw",
        "text.uri": "markup.link.url",
        "text.reference": "markup.link.text",
        "text.emphasis": "markup.italic",
        "text.strong": "markup.bold",
    ]

    /// Helix scope for a capture name, or nil for captures that never carry a style.
    public static func helixScope(forCapture name: String) -> String? {
        if name.hasPrefix("_") || ["spell", "nospell", "conceal", "none"].contains(name) { return nil }
        let parts = name.split(separator: ".").map(String.init)
        for i in stride(from: parts.count, through: 1, by: -1) {
            if let alias = aliases[parts[0..<i].joined(separator: ".")] {
                return ([alias] + parts[i...]).joined(separator: ".")
            }
        }
        return name
    }
}

/// A styled span within one line, in Character offsets of that line. `scope` is an id from
/// `SyntaxHighlighter.scopeName(_:)`.
public struct TokenRun: Sendable, Equatable {
    public let range: Range<Int>
    public let scope: UInt16
}

// MARK: - Highlighter

public final class SyntaxHighlighter: @unchecked Sendable {
    /// Files larger than this are shown without highlighting.
    public static let maxBytes = 1_000_000

    private let queriesDirectory: URL
    private let lock = NSLock()
    private var queries: [SyntaxLanguage: Query] = [:]
    private var failed: Set<SyntaxLanguage> = []
    private var scopeNames: [String] = [""]          // id 0 = no scope
    private var scopeIDs: [String: UInt16] = [:]

    /// The Helix scope name for an id in `TokenRun.scope`.
    public func scopeName(_ id: UInt16) -> String {
        lock.lock()
        defer { lock.unlock() }
        return Int(id) < scopeNames.count ? scopeNames[Int(id)] : ""
    }

    private func scopeID(_ name: String) -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if let id = scopeIDs[name] { return id }
        let id = UInt16(scopeNames.count)
        scopeNames.append(name)
        scopeIDs[name] = id
        return id
    }

    /// - Parameter queriesDirectory: folder with `<language>.scm` highlight queries.
    public init(queriesDirectory: URL) {
        self.queriesDirectory = queriesDirectory
    }

    /// Compiles the highlight query for a language (cached). Throws if it doesn't load.
    public func query(for language: SyntaxLanguage) throws -> Query {
        lock.lock()
        defer { lock.unlock() }
        if let q = queries[language] { return q }
        let url = queriesDirectory.appendingPathComponent("\(language.rawValue).scm")
        do {
            let q = try Query(language: language.language, data: Data(contentsOf: url))
            queries[language] = q
            return q
        } catch {
            failed.insert(language)
            throw error
        }
    }

    /// Token runs for every line of `text` (index = line number - 1), or nil if the file
    /// can't be highlighted (unknown grammar, too big, query failed to load).
    ///
    /// - Parameter isStyled: whether a scope has a style in the theme(s) in use. Unstyled captures
    ///   are skipped so they don't mask an enclosing styled one (e.g. a variable inside a string).
    public func lineTokens(for text: String, language: SyntaxLanguage,
                           isStyled: (String) -> Bool = { _ in true }) -> [[TokenRun]]? {
        guard text.utf8.count <= Self.maxBytes,
              let query = try? query(for: language) else { return nil }
        // Normalise CRLF so "\r\n" (one Character in Swift) splits like "\n".
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")

        let parser = Parser()
        guard (try? parser.setLanguage(language.language)) != nil,
              let tree = parser.parse(text) else { return nil }

        // Collect captures; apply wider ranges first so nested (more specific) ones win,
        // and for identical ranges let the earlier pattern win (tree-sitter convention).
        struct Capture { let range: NSRange; let pattern: Int; let scope: UInt16 }
        var captures: [Capture] = []
        var styled: [String: UInt16?] = [:]               // capture name → scope id (nil = unstyled)
        let matches = query.execute(in: tree).resolve(with: .init(string: text))
        for match in matches {
            for capture in match.captures {
                let name = capture.nameComponents.joined(separator: ".")
                let id: UInt16?
                if let cached = styled[name] {
                    id = cached
                } else {
                    let scope = SyntaxScope.helixScope(forCapture: name)
                    id = scope.flatMap { isStyled($0) ? scopeID($0) : nil }
                    styled[name] = id
                }
                guard let id else { continue }
                captures.append(Capture(range: capture.node.range, pattern: match.patternIndex, scope: id))
            }
        }
        captures.sort {
            $0.range.length != $1.range.length ? $0.range.length > $1.range.length : $0.pattern > $1.pattern
        }

        // One scope per UTF-16 unit (tree-sitter ranges are UTF-16 here).
        let length = text.utf16.count
        var units = [UInt16](repeating: 0, count: length)
        for c in captures {
            let lo = max(0, c.range.location), hi = min(length, c.range.location + c.range.length)
            if lo < hi { for i in lo..<hi { units[i] = c.scope } }
        }

        // Split into lines and convert to Character offsets.
        var lines: [[TokenRun]] = []
        var lineStart = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var runs: [TokenRun] = []
            var unit = lineStart, index = 0, start = 0
            var current: UInt16 = 0
            for ch in line {
                let scope = unit < length ? units[unit] : 0
                if scope != current {
                    if current != 0 { runs.append(TokenRun(range: start..<index, scope: current)) }
                    current = scope
                    start = index
                }
                unit += ch.utf16.count
                index += 1
            }
            if current != 0 { runs.append(TokenRun(range: start..<index, scope: current)) }
            lines.append(runs)
            lineStart += line.utf16.count + 1
        }
        return lines
    }
}
