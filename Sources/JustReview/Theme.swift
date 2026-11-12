import AppKit
import SwiftUI
import Syntax

// MARK: - Theme model

/// Style for one scope, as in Helix themes.
struct ThemeStyle {
    var fg: NSColor?
    var bg: NSColor?
    var bold = false
    var italic = false
}

/// A Helix-format syntax theme (https://docs.helix-editor.com/themes.html).
struct SyntaxTheme {
    let name: String
    let styles: [String: ThemeStyle]

    /// Most specific style for a scope: "keyword.control.import" → "keyword.control" → "keyword".
    func style(for scope: String) -> ThemeStyle? {
        var key = Substring(scope)
        while true {
            if let style = styles[String(key)] { return style }
            guard let dot = key.lastIndex(of: ".") else { return nil }
            key = key[..<dot]
        }
    }

    var background: NSColor? { styles["ui.background"]?.bg }
    var text: NSColor? { styles["ui.text"]?.fg }
    var lineNumber: NSColor? { styles["ui.linenr"]?.fg }

    /// Scopes this theme styles (excluding editor UI), for `SyntaxHighlighter.lineTokens(isStyled:)`.
    var syntaxScopes: Set<String> { Set(styles.keys.filter { !$0.hasPrefix("ui.") }) }
}

// MARK: - Theme store

/// Finds themes in the app bundle (Resources/themes) and in
/// ~/Library/Application Support/JustReview/themes, loads them with `inherits` and palettes resolved.
final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()

    static let defaultLight = "Xcode Light"
    static let defaultDark = "Xcode Dark"

    private let lock = NSLock()
    private var cache: [String: SyntaxTheme] = [:]

    var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JustReview/themes")
    }

    private var bundledDirectory: URL {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("themes"),
           FileManager.default.fileExists(atPath: url.path) { return url }
        return URL(fileURLWithPath: #filePath)               // running from the source tree
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/themes")
    }

    /// Built-in themes first, then all theme files (user themes override bundled ones by name).
    func names() -> [String] {
        let files = [bundledDirectory, userDirectory].flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".toml") }
                .map { String($0.dropLast(5)) }
        }
        return [Self.defaultLight, Self.defaultDark]
            + Set(files).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func theme(named name: String) -> SyntaxTheme {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let theme: SyntaxTheme
        switch name {
        case Self.defaultLight: theme = BuiltinThemes.xcodeLight
        case Self.defaultDark: theme = BuiltinThemes.xcodeDark
        default:
            var visited: Set<String> = []
            if let raw = rawTheme(named: name, visited: &visited) {
                theme = SyntaxTheme(name: name, styles: Self.resolve(raw))
            } else {
                theme = BuiltinThemes.xcodeLight
            }
        }
        cache[name] = theme
        return theme
    }

    /// Clears cached themes (e.g. after the user edited theme files).
    func reload() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: Loading

    private struct RawTheme {
        var entries: [String: TOML.Value] = [:]
        var palette: [String: String] = [:]
    }

    private func rawTheme(named name: String, visited: inout Set<String>) -> RawTheme? {
        guard !visited.contains(name) else { return nil }        // inheritance cycle
        visited.insert(name)
        let file = [userDirectory, bundledDirectory]
            .map { $0.appendingPathComponent("\(name).toml") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let doc = TOML.parse(text)

        var raw = RawTheme()
        if case .string(let parent)? = doc[""]?["inherits"],
           let base = rawTheme(named: parent, visited: &visited) {
            raw = base
        }
        for (key, value) in doc[""] ?? [:] where key != "inherits" { raw.entries[key] = value }
        for (key, value) in doc["palette"] ?? [:] {
            if case .string(let color) = value { raw.palette[key] = color }
        }
        return raw
    }

    private static func resolve(_ raw: RawTheme) -> [String: ThemeStyle] {
        func color(_ value: String) -> NSColor? {
            if let c = NSColor(hexString: value) { return c }
            if let p = raw.palette[value], let c = NSColor(hexString: p) { return c }
            return ansiColors[value]
        }
        var styles: [String: ThemeStyle] = [:]
        for (scope, value) in raw.entries {
            var style = ThemeStyle()
            switch value {
            case .string(let fg):
                style.fg = color(fg)
            case .table(let table):
                if case .string(let fg)? = table["fg"] { style.fg = color(fg) }
                if case .string(let bg)? = table["bg"] { style.bg = color(bg) }
                if case .array(let mods)? = table["modifiers"] {
                    for case .string(let m) in mods {
                        if m == "bold" { style.bold = true }
                        if m == "italic" { style.italic = true }
                    }
                }
            default:
                continue
            }
            styles[scope] = style
        }
        return styles
    }

    /// Helix's named terminal colors.
    private static let ansiColors: [String: NSColor] = [
        "black": "#000000", "red": "#cd3131", "green": "#0dbc79", "yellow": "#e5e510",
        "blue": "#2472c8", "magenta": "#bc3fbc", "cyan": "#11a8cd", "gray": "#808080",
        "light-red": "#f14c4c", "light-green": "#23d18b", "light-yellow": "#f5f543",
        "light-blue": "#3b8eea", "light-magenta": "#d670d6", "light-cyan": "#29b8db",
        "light-gray": "#c0c0c0", "white": "#ffffff",
    ].compactMapValues { NSColor(hexString: $0) }
}

// MARK: - Built-in themes

/// The original Xcode-like palette, expressed as Helix scopes.
enum BuiltinThemes {
    static let xcodeLight = make(ThemeStore.defaultLight, [
        "keyword": 0x9B2393, "string": 0xC41A16, "comment": 0x5D6C79, "constant.numeric": 0x1C00CF,
        "type": 0x0B4F79, "namespace": 0x0B4F79, "function": 0x326D74, "constructor": 0x326D74,
        "constant": 0x6C36A9, "variable.builtin": 0x6C36A9, "attribute": 0x815F03, "tag": 0x0B4F79,
        "variable.other.member": 0x0F68A0, "constant.character.escape": 0xA45C00,
        "string.regexp": 0xA45C00, "markup.heading": 0x0B4F79, "markup.link": 0x0E0EFF, "markup.raw": 0xC41A16,
    ])

    static let xcodeDark = make(ThemeStore.defaultDark, [
        "keyword": 0xFC5FA3, "string": 0xFC6A5D, "comment": 0x7F8C98, "constant.numeric": 0xD0BF69,
        "type": 0x5DD8FF, "namespace": 0x5DD8FF, "function": 0x67B7A4, "constructor": 0x67B7A4,
        "constant": 0xA167E6, "variable.builtin": 0xA167E6, "attribute": 0xBF8555, "tag": 0x5DD8FF,
        "variable.other.member": 0x41A1C0, "constant.character.escape": 0xFD8F3F,
        "string.regexp": 0xFD8F3F, "markup.heading": 0x5DD8FF, "markup.link": 0x5482FF, "markup.raw": 0xFC6A5D,
    ])

    private static func make(_ name: String, _ colors: [String: UInt32]) -> SyntaxTheme {
        SyntaxTheme(name: name, styles: colors.mapValues { ThemeStyle(fg: NSColor(hex: $0)) })
    }
}

// MARK: - Applying a theme to diff text

/// Resolves highlighter scope ids to the active theme's styles (cached per render).
final class ThemeStyler {
    let theme: SyntaxTheme
    private var cache: [UInt16: ThemeStyle?] = [:]

    init(theme: SyntaxTheme) { self.theme = theme }

    func style(for scope: UInt16) -> ThemeStyle? {
        if let cached = cache[scope] { return cached }
        let style = theme.style(for: syntaxHighlighter.scopeName(scope))
        cache[scope] = style
        return style
    }
}

/// Shared highlighter. Queries ship in the app bundle (Contents/Resources/queries); when running
/// from the source tree (`swift run`) they're read from Resources/queries in the checkout.
let syntaxHighlighter: SyntaxHighlighter = {
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("queries")
    if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
        return SyntaxHighlighter(queriesDirectory: bundled)
    }
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/queries")
    return SyntaxHighlighter(queriesDirectory: source)
}()

/// The theme names chosen in Settings for each appearance.
enum ThemePrefs {
    static let lightKey = "lightTheme"
    static let darkKey = "darkTheme"

    static func name(dark: Bool) -> String {
        UserDefaults.standard.string(forKey: dark ? darkKey : lightKey)
            ?? (dark ? ThemeStore.defaultDark : ThemeStore.defaultLight)
    }

    @MainActor static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Colors

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// "#rgb", "#rrggbb" or "#rrggbbaa".
    convenience init?(hexString: String) {
        guard hexString.hasPrefix("#") else { return nil }
        var digits = String(hexString.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let rgb = digits.count == 8 ? value >> 8 : value
        let alpha = digits.count == 8 ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Minimal TOML reader

/// Reads the TOML subset Helix themes use: `[sections]`, bare/quoted keys (dotted bare keys are
/// kept flat, e.g. `attention.fg`), strings, arrays and inline tables (which may span lines).
enum TOML {
    indirect enum Value {
        case string(String)
        case array([Value])
        case table([String: Value])
        case other
    }

    /// Section name ("" for top level) → key → value.
    static func parse(_ text: String) -> [String: [String: Value]] {
        var parser = Parser(chars: Array(text))
        return parser.document()
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        mutating func document() -> [String: [String: Value]] {
            var result: [String: [String: Value]] = ["": [:]]
            var section = ""
            while true {
                skip(newlines: true)
                guard i < chars.count else { break }
                if chars[i] == "[" {
                    i += 1
                    section = readUntil("]").trimmingCharacters(in: .whitespaces)
                    i += 1
                    result[section, default: [:]] = result[section] ?? [:]
                    skipLine()
                    continue
                }
                guard let path = keyPath() else { skipLine(); continue }
                skip(newlines: false)
                guard i < chars.count, chars[i] == "=" else { skipLine(); continue }
                i += 1
                let v = value()
                // `"comment".fg = "x"` sets one property of the "comment" style; any other
                // dotted key is kept flat ("ui.background", palette "attention.fg").
                if section.isEmpty, path.count > 1, let last = path.last, Self.styleProperties.contains(last) {
                    let scope = path.dropLast().joined(separator: ".")
                    var table: [String: Value] = [:]
                    if case .table(let existing)? = result[section]?[scope] { table = existing }
                    table[last] = v
                    result[section, default: [:]][scope] = .table(table)
                } else {
                    result[section, default: [:]][path.joined(separator: ".")] = v
                }
                skipLine()
            }
            return result
        }

        static let styleProperties: Set<String> = ["fg", "bg", "modifiers", "underline"]

        /// A key made of quoted and/or bare segments separated by dots.
        mutating func keyPath() -> [String]? {
            var parts: [String] = []
            while true {
                skip(newlines: false)
                guard i < chars.count else { break }
                if chars[i] == "\"" || chars[i] == "'" {
                    parts.append(string())
                } else {
                    var bare = ""
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_-".contains(chars[i]) {
                        bare.append(chars[i])
                        i += 1
                    }
                    guard !bare.isEmpty else { break }
                    parts.append(bare)
                }
                skip(newlines: false)
                if i < chars.count, chars[i] == "." { i += 1 } else { break }
            }
            return parts.isEmpty ? nil : parts
        }

        mutating func key() -> String? {
            skip(newlines: false)
            guard i < chars.count else { return nil }
            if chars[i] == "\"" || chars[i] == "'" { return string() }
            var key = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_-.".contains(chars[i]) {
                key.append(chars[i])
                i += 1
            }
            return key.isEmpty ? nil : key
        }

        mutating func value() -> Value {
            skip(newlines: true)
            guard i < chars.count else { return .other }
            switch chars[i] {
            case "\"", "'":
                return .string(string())
            case "[":
                i += 1
                var items: [Value] = []
                while true {
                    skip(newlines: true)
                    guard i < chars.count else { break }
                    if chars[i] == "]" { i += 1; break }
                    if chars[i] == "," { i += 1; continue }
                    items.append(value())
                }
                return .array(items)
            case "{":
                i += 1
                var table: [String: Value] = [:]
                while true {
                    skip(newlines: true)
                    guard i < chars.count else { break }
                    if chars[i] == "}" { i += 1; break }
                    if chars[i] == "," { i += 1; continue }
                    guard let k = key() else { i += 1; continue }
                    skip(newlines: true)
                    if i < chars.count, chars[i] == "=" { i += 1 }
                    table[k] = value()
                }
                return .table(table)
            default:
                // Number, boolean, …: not needed for themes.
                while i < chars.count, !",]}\n#".contains(chars[i]) { i += 1 }
                return .other
            }
        }

        mutating func string() -> String {
            let quote = chars[i]
            i += 1
            var s = ""
            while i < chars.count, chars[i] != quote {
                if quote == "\"", chars[i] == "\\", i + 1 < chars.count {
                    i += 1
                    switch chars[i] {
                    case "n": s.append("\n")
                    case "t": s.append("\t")
                    default: s.append(chars[i])
                    }
                } else {
                    s.append(chars[i])
                }
                i += 1
            }
            i += 1
            return s
        }

        mutating func readUntil(_ end: Character) -> String {
            var s = ""
            while i < chars.count, chars[i] != end, chars[i] != "\n" { s.append(chars[i]); i += 1 }
            return s
        }

        /// Skips spaces and comments (and newlines when allowed).
        mutating func skip(newlines: Bool) {
            while i < chars.count {
                let c = chars[i]
                if c == "#" { while i < chars.count, chars[i] != "\n" { i += 1 } }
                else if c == " " || c == "\t" || c == "\r" || (newlines && c == "\n") { i += 1 }
                else { break }
            }
        }

        mutating func skipLine() {
            while i < chars.count, chars[i] != "\n" { i += 1 }
        }
    }
}

// MARK: - Settings preview

/// A few highlighted lines of Python in a given theme, for the Settings pickers.
struct ThemePreview: View {
    let themeName: String
    /// Which appearance the theme is for; fallbacks (no ui.background/ui.text in the theme)
    /// use that appearance's system colors, not the current one.
    let dark: Bool
    @AppStorage(FontPrefs.diffFamily) private var family = ""

    private static let sample = """
    @dataclass
    class User:
        \"\"\"A user.\"\"\"
        def greet(self, name: str) -> str:
            return f"Hi {name}" + str(42)  # say hi
    """

    var body: some View {
        let theme = ThemeStore.shared.theme(named: themeName)
        let styler = ThemeStyler(theme: theme)
        let scopes = theme.syntaxScopes
        let lines = syntaxHighlighter.lineTokens(for: Self.sample, language: .python, isStyled: { scope in
            var key = Substring(scope)
            while true {
                if scopes.contains(String(key)) { return true }
                guard let dot = key.lastIndex(of: ".") else { return false }
                key = key[..<dot]
            }
        }) ?? []
        let text = Self.sample.components(separatedBy: "\n").enumerated().map { index, line -> AttributedString in
            let chars = Array(line)
            var result = AttributedString(line)
            for run in index < lines.count ? lines[index] : [] {
                guard let style = styler.style(for: run.scope), let fg = style.fg,
                      run.range.upperBound <= chars.count else { continue }
                let start = result.characters.index(result.startIndex, offsetBy: run.range.lowerBound)
                let end = result.characters.index(start, offsetBy: run.range.count)
                result[start..<end].foregroundColor = Color(nsColor: fg)
                if style.italic { result[start..<end].inlinePresentationIntent = .emphasized }
            }
            return result
        }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(text.indices, id: \.self) { Text(text[$0]) }
        }
        .font(Font(FontPrefs.diffFont(family: family, size: 11) as CTFont))
        .foregroundStyle(Color(nsColor: theme.text ?? resolved(.labelColor)))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: theme.background ?? resolved(.textBackgroundColor))))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    /// A system color as it looks in the preview's appearance.
    private func resolved(_ color: NSColor) -> NSColor {
        var result = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }
}
