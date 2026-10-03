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
        // Optional on-device neural TTS (Kokoro-82M via sherpa-onnx). A
        // separate product so hosts that never import it do not link the
        // engine: SwiftPM only fetches and builds a dependency for the
        // products a host actually uses.
        .library(
            name: "AgentKokoro",
            targets: ["AgentKokoro"]
        ),
    ],
    dependencies: [
        // On-device Whisper transcription for the `.whisper` dictation
        // backend. Model weights are fetched from Hugging Face on first
        // use, not bundled.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "153.0.0"),
        // Kokoro-82M inference for the optional `AgentKokoro` product
        // (ONNX Runtime + the sherpa-onnx text frontend). Model weights are
        // downloaded on first use, not bundled. Minor-pinned because the
        // Swift wrapper ships in the same package as the C API it wraps.
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git", .upToNextMinor(from: "1.13.8")),
    ],
    targets: [
        .target(
            name: "AgentClient",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ],
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
        .target(
            name: "AgentKokoro",
            dependencies: [
                "AgentClient",
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
            ],
            path: "Sources/AgentKokoro"
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
        .testTarget(
            name: "AgentKokoroTests",
            dependencies: ["AgentKokoro"],
            path: "Tests/AgentKokoroTests"
        ),
    ]
)

