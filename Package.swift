// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AgentFrontend",
    platforms: [
        .iOS(.v16),
        // macOS 14: ONNX Runtime's Swift package (AgentKokoro) declares
        // macOS 14, and SwiftPM platforms are package-wide.
        .macOS(.v14)
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
        // Optional on-device neural TTS (Kokoro-82M on ONNX Runtime). A
        // separate product so hosts that never import it do not link the
        // engine.
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
        // Microsoft ONNX Runtime (MIT), full build, for the optional
        // `AgentKokoro` product: runs the Kokoro model and our G2P model.
        // Exact pin: the binary xcframework and its licence inventory
        // (README, "On-device neural voice") are checked per version.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
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
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
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
            path: "Tests/AgentKokoroTests",
            // kokoro/v1 golden vectors, manifest and small JSON files
            // (Apache-2.0, from tools/kokoro-assets).
            resources: [.copy("Resources/kokoro-v1")]
        ),
    ]
)

