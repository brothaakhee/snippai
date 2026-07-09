// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnippAI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        // Local on-device ASR (Parakeet on the Neural Engine) — voice input spike.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
    ],
    targets: [
        // Shared engine: iTerm wire client, generated protobuf, adapters, capture, panel models.
        .target(
            name: "SnippAIKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "FluidAudio", package: "FluidAudio"),
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
        // De-risking spike: local speech-to-text via FluidAudio (model download,
        // load time, transcription accuracy + latency) for voice-first input.
        .executableTarget(
            name: "fluid-spike",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
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
