// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AgentFrontend",
    platforms: [
        .iOS(.v16),
        // macOS 14: ONNX Runtime's Objective-C bindings (AgentKokoro)
        // declare macOS 14, and SwiftPM platforms are package-wide.
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
                "OnnxRuntimeBindings",
            ],
            path: "Sources/AgentKokoro"
        ),
        // Microsoft ONNX Runtime 1.24.2 (MIT), full build, for the optional
        // `AgentKokoro` product: runs the Kokoro model and our G2P model.
        // Kept here (ThirdParty/onnxruntime/README.md): Microsoft's
        // onnxruntime-swift-package-manager repository and its download
        // host went away on 2026-11-22. Its Objective-C bindings, unchanged,
        // and the same pod archive (identical bytes, so the same checksum)
        // on our own bucket. The licence inventory (README, "On-device
        // neural voice") is checked per version.
        .target(
            name: "OnnxRuntimeBindings",
            dependencies: ["onnxruntime"],
            path: "ThirdParty/onnxruntime/objectivec",
            cxxSettings: [
                .define("SPM_BUILD"),
            ]
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "https://storage.googleapis.com/flisk447-media/vendor/onnxruntime/pod-archive-onnxruntime-c-1.24.2.zip",
            checksum: "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
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
    ],
    // The ONNX Runtime bindings are C++17 (as in Microsoft's package); the
    // package's other targets are Swift.
    cxxLanguageStandard: .cxx17
)
