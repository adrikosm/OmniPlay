// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RenPyRuntime",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "RenPyRuntime", targets: ["RenPyRuntime"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(path: "../InputKit"),
        .package(path: "../OverlayVFS"),
        .package(path: "../SaveKit"),
        .package(path: "../RuntimeCore"),
    ],
    targets: [
        // The engines are embedded frameworks the app opens at run time (Native/RenPy/op_renpy.h); nothing here
        // links them, so the package builds and type-checks on the Mac as well.
        .target(
            name: "RenPyRuntime",
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
