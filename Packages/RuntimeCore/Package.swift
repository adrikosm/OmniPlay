// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuntimeCore",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "RuntimeCore", targets: ["RuntimeCore"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(path: "../InputKit"),
        .package(path: "../SaveKit"),
        .package(path: "../GameDetection"),
        .package(path: "../GameStore"),
        .package(path: "../OverlayVFS"),
        .package(path: "../LocalGameServer"),
    ],
    targets: [
        .target(
            name: "RuntimeCore",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "InputKit", package: "InputKit"),
                .product(name: "SaveKit", package: "SaveKit"),
                .product(name: "GameDetection", package: "GameDetection"),
                .product(name: "GameStore", package: "GameStore"),
                .product(name: "OverlayVFS", package: "OverlayVFS"),
                .product(name: "LocalGameServer", package: "LocalGameServer"),
            ],
            resources: [.copy("WebRuntimeAssets")]
        ),
        .testTarget(name: "RuntimeCoreTests", dependencies: ["RuntimeCore", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
