// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameCore",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "GameCore", targets: ["GameCore"])],
    dependencies: [
    ],
    targets: [
        .target(
            name: "GameCore",
            dependencies: [
            ]
        ),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"]),
    ],
    swiftLanguageModes: [.v6]
)
