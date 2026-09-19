// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaCompat",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "MediaCompat", targets: ["MediaCompat"])],
    dependencies: [
        .package(path: "../GameCore"),
    ],
    targets: [
        .target(
            name: "MediaCompat",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
            ]
        ),
        .testTarget(name: "MediaCompatTests", dependencies: ["MediaCompat", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
