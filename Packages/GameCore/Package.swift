// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameCore",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [
        .library(name: "GameCore", targets: ["GameCore"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "GameCore",
            dependencies: [
            ]
        ),
        .target(name: "TestSupport", dependencies: ["GameCore"]),
    ],
    swiftLanguageModes: [.v6]
)
