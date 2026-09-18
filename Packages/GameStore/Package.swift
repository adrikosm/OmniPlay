// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameStore",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "GameStore", targets: ["GameStore"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "GameStore",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "GameStoreTests", dependencies: ["GameStore", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
