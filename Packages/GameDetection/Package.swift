// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameDetection",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "GameDetection", targets: ["GameDetection"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(path: "../OverlayVFS"),
        .package(path: "../GameImport"),
        .package(path: "../MediaCompat"),
    ],
    targets: [
        .target(
            name: "GameDetection",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "OverlayVFS", package: "OverlayVFS"),
                .product(name: "GameImport", package: "GameImport"),
                .product(name: "MediaCompat", package: "MediaCompat"),
            ]
        ),
        .testTarget(name: "GameDetectionTests", dependencies: ["GameDetection", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
