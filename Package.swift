// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AgentFrontend",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AgentClient",
            targets: ["AgentClient"]
        ),
        .library(
            name: "AgentFrontend",
            targets: ["AgentFrontend"]
        ),
    ],
    dependencies: [
        // On-device Whisper transcription for the `.whisper` dictation
        // backend. Model weights are fetched from Hugging Face on first
        // use, not bundled.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "AgentClient",
            dependencies: [],
            path: "Sources/AgentClient"
        ),
        .target(
            name: "AgentFrontend",
            dependencies: [
                "AgentClient",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/AgentFrontend"
        ),
        .testTarget(
            name: "AgentClientTests",
            dependencies: ["AgentClient"],
            path: "Tests/AgentClientTests"
        ),
        .testTarget(
            name: "AgentFrontendTests",
            dependencies: ["AgentFrontend"],
            path: "Tests/AgentFrontendTests"
        ),
    ]
)

