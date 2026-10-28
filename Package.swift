// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RadioBridge",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that can be tested without Music.app or a window.
        .target(
            name: "RadioCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "RadioCoreTests",
            dependencies: ["RadioCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
