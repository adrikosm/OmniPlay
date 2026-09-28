// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GodotRuntime",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "GodotRuntime", targets: ["GodotRuntime"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(path: "../InputKit"),
        .package(path: "../OverlayVFS"),
        .package(path: "../SaveKit"),
        .package(path: "../RuntimeCore"),
    ],
    targets: [
        // Godot is an embedded framework the app opens at run time (Native/godot/modules/omniplay/op_godot.h); nothing here
        // links it, so the package builds and type-checks on the Mac as well.
        .target(
            name: "GodotRuntime",
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
