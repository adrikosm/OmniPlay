// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyRPGRuntime",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "EasyRPGRuntime", targets: ["EasyRPGRuntime"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(path: "../InputKit"),
        .package(path: "../OverlayVFS"),
        .package(path: "../SaveKit"),
        .package(path: "../RuntimeCore"),
    ],
    targets: [
        // The Player is an embedded framework the app opens at run time (Native/EasyRPG/op_easyrpg.h); nothing here
        // links it, so the package builds and type-checks on the Mac as well.
        .target(
            name: "EasyRPGRuntime",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "InputKit", package: "InputKit"),
                .product(name: "OverlayVFS", package: "OverlayVFS"),
                .product(name: "SaveKit", package: "SaveKit"),
                .product(name: "RuntimeCore", package: "RuntimeCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
