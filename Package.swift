// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnippAI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    targets: [
        // Shared engine: iTerm wire client, generated protobuf, adapters, capture, panel models.
        .target(
            name: "SnippAIKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        // De-risking spike + diagnostics CLI: enumerate / send / stream via the native client.
        .executableTarget(
            name: "iterm-spike",
            dependencies: ["SnippAIKit"]
        ),
        .executableTarget(
            name: "terminal-spike",
            dependencies: ["SnippAIKit"]
        ),
        // The menu-bar app.
        .executableTarget(
            name: "SnippAI",
            dependencies: ["SnippAIKit"]
        ),
        .testTarget(
            name: "SnippAIKitTests",
            dependencies: ["SnippAIKit"]
        ),
    ]
)
