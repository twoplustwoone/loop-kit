// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LoopKit",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .library(name: "LoopKitEngine", targets: ["LoopKitEngine"]),
        .library(name: "LoopKitIPC", targets: ["LoopKitIPC"]),
        .library(name: "LoopKitAudioCore", targets: ["LoopKitAudioCore"]),
        .library(name: "LoopKitDaemonCore", targets: ["LoopKitDaemonCore"]),
        .library(name: "LoopKitUI", targets: ["LoopKitUI"]),
        .library(name: "LoopKitOffline", targets: ["LoopKitOffline"]),
        .executable(name: "loopkit_offline_dsp", targets: ["loopkit_offline_dsp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LoopKitEngine",
            path: "engine",
            exclude: ["tests", "CMakeLists.txt"],
            sources: ["src"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "LoopKitIPC",
            path: "macos/Shared/Sources"
        ),
        .target(
            name: "LoopKitAudioCore",
            dependencies: ["LoopKitEngine"],
            path: "macos/AudioCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "LoopKitDaemonCore",
            dependencies: [
                "LoopKitIPC",
                "LoopKitAudioCore",
                "LoopKitEngine"
            ],
            path: "macos/DaemonCore",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .target(
            name: "LoopKitUI",
            path: "macos/LoopKitUI"
        ),
        .target(
            name: "LoopKitOffline",
            dependencies: ["LoopKitEngine"],
            path: "tools/loopkit_offline_dsp/Sources/LoopKitOffline",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .executableTarget(
            name: "loopkit_offline_dsp",
            dependencies: ["LoopKitOffline"],
            path: "tools/loopkit_offline_dsp/Sources/CLI",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        .testTarget(
            name: "LoopKitTests",
            dependencies: [
                "LoopKitDaemonCore",
                "LoopKitIPC",
                "LoopKitAudioCore",
                "LoopKitEngine",
                "LoopKitOffline"
            ],
            path: "Tests/LoopKitTests",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
