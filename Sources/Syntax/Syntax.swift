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

// MARK: - Tokens

/// Highlight categories; the app maps them to colors.
public enum SyntaxToken: UInt8, Sendable {
    case none = 0
    case keyword, string, comment, number, type, function, constant, builtin
    case attribute, tag, property, escape, heading, link

    /// Maps a tree-sitter capture name ("keyword.function", "string.special.key", …) to a token.
    /// Returns nil for captures that shouldn't color anything (punctuation, variables, …).
    static func from(captureName parts: [String]) -> SyntaxToken? {
        guard let first = parts.first, !first.hasPrefix("_") else { return nil }
        let second = parts.count > 1 ? parts[1] : ""
        switch first {
        case "comment": return .comment
        case "string":
            switch second {
            case "escape", "regex", "regexp": return .escape
            case "special": return parts.contains("key") ? .property : .escape
            default: return .string
            }
        case "character": return .string
        case "escape": return .escape
        case "number", "float": return .number
        case "boolean": return .builtin
        case "constant":
            switch second {
            case "builtin": return .builtin
            case "numeric": return .number
            default: return .constant
            }
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass": return .keyword
        case "type", "module", "namespace": return .type
        case "constructor", "function", "method": return .function
        case "variable": return second == "builtin" ? .builtin : nil
        case "property", "field": return .property
        case "attribute", "decorator", "label": return .attribute
        case "tag": return .tag
        // Markdown
        case "text", "markup":
            switch second {
            case "title", "heading": return .heading
            case "literal", "raw": return .string
            case "uri", "reference", "link": return .link
            default: return nil
            }
        case "none": return SyntaxToken.none
        default: return nil
        }
    }
}

/// A colored span within one line, in Character offsets of that line.
public struct TokenRun: Sendable, Equatable {
    public let range: Range<Int>
    public let token: SyntaxToken
}

// MARK: - Highlighter

public final class SyntaxHighlighter: @unchecked Sendable {
    /// Files larger than this are shown without highlighting.
    public static let maxBytes = 1_000_000

    private let queriesDirectory: URL
    private let lock = NSLock()
    private var queries: [SyntaxLanguage: Query] = [:]
    private var failed: Set<SyntaxLanguage> = []

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
    public func lineTokens(for text: String, language: SyntaxLanguage) -> [[TokenRun]]? {
        guard text.utf8.count <= Self.maxBytes,
              let query = try? query(for: language) else { return nil }
        // Normalise CRLF so "\r\n" (one Character in Swift) splits like "\n".
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")

        let parser = Parser()
        guard (try? parser.setLanguage(language.language)) != nil,
              let tree = parser.parse(text) else { return nil }

        // Collect captures; apply wider ranges first so nested (more specific) ones win,
        // and for identical ranges let the earlier pattern win (tree-sitter convention).
        struct Capture { let range: NSRange; let pattern: Int; let token: SyntaxToken }
        var captures: [Capture] = []
        let matches = query.execute(in: tree).resolve(with: .init(string: text))
        for match in matches {
            for capture in match.captures {
                guard let token = SyntaxToken.from(captureName: capture.nameComponents) else { continue }
                captures.append(Capture(range: capture.node.range, pattern: match.patternIndex, token: token))
            }
        }
        captures.sort {
            $0.range.length != $1.range.length ? $0.range.length > $1.range.length : $0.pattern > $1.pattern
        }

        // One token per UTF-16 unit (tree-sitter ranges are UTF-16 here).
        let length = text.utf16.count
        var units = [UInt8](repeating: 0, count: length)
        for c in captures {
            let lo = max(0, c.range.location), hi = min(length, c.range.location + c.range.length)
            if lo < hi { for i in lo..<hi { units[i] = c.token.rawValue } }
        }

        // Split into lines and convert to Character offsets.
        var lines: [[TokenRun]] = []
        var lineStart = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var runs: [TokenRun] = []
            var unit = lineStart, index = 0, start = 0
            var current = SyntaxToken.none
            for ch in line {
                let token = unit < length ? SyntaxToken(rawValue: units[unit]) ?? .none : .none
                if token != current {
                    if current != .none { runs.append(TokenRun(range: start..<index, token: current)) }
                    current = token
                    start = index
                }
                unit += ch.utf16.count
                index += 1
            }
            if current != .none { runs.append(TokenRun(range: start..<index, token: current)) }
            lines.append(runs)
            lineStart += line.utf16.count + 1
        }
        return lines
    }
}
