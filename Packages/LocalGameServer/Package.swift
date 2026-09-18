// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalGameServer",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "LocalGameServer", targets: ["LocalGameServer"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(
            name: "LocalGameServer",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
            ]
        ),
        .testTarget(name: "LocalGameServerTests", dependencies: ["LocalGameServer"]),
    ],
    swiftLanguageModes: [.v6]
)
