// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OverlayVFS",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "OverlayVFS", targets: ["OverlayVFS"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "OverlayVFS",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "OverlayVFSTests", dependencies: ["OverlayVFS", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
