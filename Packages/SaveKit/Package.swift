// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SaveKit",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "SaveKit", targets: ["SaveKit"])],
    dependencies: [
        .package(path: "../GameCore"),
    ],
    targets: [
        .target(
            name: "SaveKit",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
            ]
        ),
        .testTarget(name: "SaveKitTests", dependencies: ["SaveKit"]),
    ],
    swiftLanguageModes: [.v6]
)
