// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameStore",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "GameStore", targets: ["GameStore"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(
            name: "GameStore",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
            ]
        ),
        .testTarget(name: "GameStoreTests", dependencies: ["GameStore"]),
    ],
    swiftLanguageModes: [.v6]
)
