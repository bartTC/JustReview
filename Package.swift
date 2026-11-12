// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JustReview",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "JustReview",
            path: "Sources/JustReview",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
