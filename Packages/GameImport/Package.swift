// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameImport",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "GameImport", targets: ["GameImport"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(
            name: "GameImport",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
            ]
        ),
        .testTarget(name: "GameImportTests", dependencies: ["GameImport", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
