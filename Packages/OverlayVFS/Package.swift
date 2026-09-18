// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OverlayVFS",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "OverlayVFS", targets: ["OverlayVFS"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(
            name: "OverlayVFS",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
            ]
        ),
        .testTarget(name: "OverlayVFSTests", dependencies: ["OverlayVFS"]),
    ],
    swiftLanguageModes: [.v6]
)
