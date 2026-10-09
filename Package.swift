// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Framelet",
    platforms: [.macOS(.v15)],
    products: [.library(name: "FrameletCore", targets: ["FrameletCore"])],
    targets: [
        .target(name: "FrameletCore"),
        .testTarget(name: "FrameletCoreTests", dependencies: ["FrameletCore"]),
    ],
    swiftLanguageModes: [.v5]
)
