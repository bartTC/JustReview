// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitDiff",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GitDiff", path: "Sources/GitDiff")
    ]
)
