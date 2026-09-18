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
    ],
    targets: [
        .target(
            name: "RuntimeCore",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "InputKit", package: "InputKit"),
                .product(name: "SaveKit", package: "SaveKit"),
            ]
        ),
        .testTarget(name: "RuntimeCoreTests", dependencies: ["RuntimeCore"]),
    ],
    swiftLanguageModes: [.v6]
)
