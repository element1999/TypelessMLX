// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessMLX",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.31.3"),
        .package(url: "https://github.com/genericgroup/sherpa-onnx-spm", exact: "1.0.4"),
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
            ],
            path: "TypelessMLX/Sources",
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
