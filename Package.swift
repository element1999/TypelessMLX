// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypelessMLX",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.31.3"),
        .package(url: "https://github.com/genericgroup/sherpa-onnx-spm", exact: "1.0.4"),
        .package(url: "https://github.com/soniqo/speech-swift", from: "0.0.21"),
    ],
    targets: [
        .target(
            name: "TypelessMLXAudioTapSupport",
            path: "TypelessMLX/AudioSupport",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .target(
            name: "TypelessMLXAudioInputSupport",
            path: "TypelessMLX/AudioInputSupport"
        ),
        .executableTarget(
            name: "TypelessMLX",
            dependencies: [
                "TypelessMLXAudioTapSupport",
                "TypelessMLXAudioInputSupport",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "CSherpaOnnx", package: "sherpa-onnx-spm"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
            ],
            path: "TypelessMLX/Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        ),
        .executableTarget(
            name: "TypelessMLXAudioTapFormatTests",
            dependencies: ["TypelessMLXAudioTapSupport"],
            path: "TypelessMLX/Tests/AudioTapFormat"
        ),
        .executableTarget(
            name: "TypelessMLXAudioInputAvailabilityTests",
            dependencies: ["TypelessMLXAudioInputSupport"],
            path: "TypelessMLX/Tests/AudioInputAvailability"
        )
    ]
)
