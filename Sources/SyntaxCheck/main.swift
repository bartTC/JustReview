// Dev tool: checks that every grammar loads and its highlight query compiles.
// Usage: swift run syntax-check [queries-dir]   (default: Resources/queries)
import Foundation
import Syntax

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/queries")
let highlighter = SyntaxHighlighter(queriesDirectory: dir)

let samples: [SyntaxLanguage: String] = [
    .python: "def f(x):\n    return \"hi\"  # c\n",
    .javascript: "const x = 1; // c\nfunction f() { return 'a' }\n",
    .typescript: "let x: number = 1\ninterface A { b: string }\n",
    .tsx: "const A = () => <div className=\"a\">{1}</div>\n",
    .json: "{\"a\": [1, true, null]}\n",
    .css: ".a { color: red; }\n",
    .html: "<div class=\"a\">x</div>\n",
    .bash: "echo \"$HOME\" # c\n",
    .go: "package main\nfunc main() { _ = \"x\" }\n",
    .rust: "fn main() { let x = 1; }\n",
    .swift: "let x = \"a\" // c\nfunc f() {}\n",
    .yaml: "a: 1\nb: \"x\"\n",
    .markdown: "# Title\n\nText\n",
    .toml: "[a]\nb = 1\n",
]

var failures = 0
for language in SyntaxLanguage.allCases {
    do {
        _ = try highlighter.query(for: language)
        let lines = highlighter.lineTokens(for: samples[language] ?? "", language: language) ?? []
        let tokens = lines.flatMap { $0 }.count
        print("ok    \(language.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(tokens) colored spans")
    } catch {
        failures += 1
        print("FAIL  \(language.rawValue): \(error)")
    }
}
exit(failures == 0 ? 0 : 1)
