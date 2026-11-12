// swift-tools-version:6.0
import PackageDescription

/// Grammars whose upstream Package.swift drops scanner.c under current SwiftPM (it checks
/// `FileManager.fileExists` relative to the working directory) are vendored in Vendor/Grammars.
func vendoredGrammar(_ name: String) -> Target {
    .target(
        name: name,
        path: "Vendor/Grammars/\(name)",
        exclude: ["LICENSE"],
        sources: ["src/parser.c", "src/scanner.c"],
        publicHeadersPath: "include",
        cSettings: [.headerSearchPath("src")]
    )
}

let package = Package(
    name: "JustReview",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.4"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", exact: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "JustReview",
            dependencies: ["Syntax"],
            path: "Sources/JustReview",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        /// Tree-sitter based syntax highlighting (UI-independent).
        .target(
            name: "Syntax",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                "TreeSitterPython", "TreeSitterJavaScript", "TreeSitterCSS", "TreeSitterYAML",
            ],
            path: "Sources/Syntax",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        /// Dev tool: `swift run syntax-check` compiles every grammar's highlight query.
        .executableTarget(
            name: "syntax-check",
            dependencies: ["Syntax"],
            path: "Sources/SyntaxCheck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        vendoredGrammar("TreeSitterPython"),
        vendoredGrammar("TreeSitterJavaScript"),
        vendoredGrammar("TreeSitterCSS"),
        vendoredGrammar("TreeSitterYAML"),
    ]
)
