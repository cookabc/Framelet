// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Framelet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Framelet", targets: ["Framelet"])],
    targets: [
        .target(name: "FrameletCore"),
        .executableTarget(name: "Framelet", dependencies: ["FrameletCore"]),
        .testTarget(name: "FrameletCoreTests", dependencies: ["FrameletCore"]),
        .testTarget(name: "FrameletInteractionTests", dependencies: ["Framelet", "FrameletCore"]),
    ],
    swiftLanguageModes: [.v5]
)
