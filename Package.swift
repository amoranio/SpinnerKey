// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpinnerKey",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SpinnerKey", targets: ["SpinnerKey"]),
    ],
    targets: [
        // All rotation logic. No UI, no third-party dependencies.
        .target(name: "SpinnerKeyCore"),
        // The app: SwiftUI config panel, plus a headless `rotate` mode run by launchd.
        .executableTarget(name: "SpinnerKey", dependencies: ["SpinnerKeyCore"]),
        .testTarget(name: "SpinnerKeyCoreTests", dependencies: ["SpinnerKeyCore"]),
    ]
)
