// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "LoopKitLoopbackTest",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "loopkit_loopback_test", targets: ["LoopKitLoopbackTest"])
  ],
  targets: [
    .executableTarget(
      name: "LoopKitLoopbackTest",
      path: "Sources/LoopKitLoopbackTest",
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("Foundation")
      ]
    )
  ]
)
