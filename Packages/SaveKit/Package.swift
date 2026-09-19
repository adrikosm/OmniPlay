// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SaveKit",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "SaveKit", targets: ["SaveKit"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(
            name: "SaveKit",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
            ]
        ),
        .testTarget(name: "SaveKitTests", dependencies: ["SaveKit", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
