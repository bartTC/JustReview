// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GitDiff",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "GitDiff",
            path: "Sources/GitDiff",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
