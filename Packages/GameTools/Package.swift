// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameTools",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "GameTools", targets: ["GameTools"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(path: "../RuntimeCore"),
    ],
    targets: [
        .target(
            name: "GameTools",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "RuntimeCore", package: "RuntimeCore"),
            ]
        ),
        .testTarget(name: "GameToolsTests", dependencies: ["GameTools"]),
    ],
    swiftLanguageModes: [.v6]
)
