// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameDetection",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "GameDetection", targets: ["GameDetection"])],
    dependencies: [
        .package(path: "../GameCore"),
    ],
    targets: [
        .target(
            name: "GameDetection",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
            ]
        ),
        .testTarget(name: "GameDetectionTests", dependencies: ["GameDetection"]),
    ],
    swiftLanguageModes: [.v6]
)
