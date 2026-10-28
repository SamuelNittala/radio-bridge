// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RadioBridge",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that can be tested without Music.app or a window.
        .target(name: "RadioCore"),
        .testTarget(name: "RadioCoreTests", dependencies: ["RadioCore"]),
    ],
    swiftLanguageModes: [.v5]
)
