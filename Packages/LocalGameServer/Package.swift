// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalGameServer",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "LocalGameServer", targets: ["LocalGameServer"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(path: "../OverlayVFS"),
    ],
    targets: [
        .target(
            name: "LocalGameServer",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "OverlayVFS", package: "OverlayVFS"),
            ]
        ),
        .testTarget(name: "LocalGameServerTests", dependencies: ["LocalGameServer", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
