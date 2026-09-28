// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RGSSRuntime",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "RGSSRuntime", targets: ["RGSSRuntime"])],
    dependencies: [
        .package(path: "../GameCore"),
        .package(path: "../Diagnostics"),
        .package(path: "../InputKit"),
        .package(path: "../OverlayVFS"),
        .package(path: "../SaveKit"),
        .package(path: "../RuntimeCore"),
    ],
    targets: [
        // C interface of the mkxp-z engine (Native/mkxp-z/src/app_bridge.h, symlinked) plus the host-side
        // engine boot. The engine objects themselves are linked by the app target from Native/prebuilt/mkxp-z;
        // this target only exposes the declarations.
        .target(name: "CMkxpBridge", path: "Sources/CMkxpBridge"),
        .target(
            name: "RGSSRuntime",
            dependencies: [
                "CMkxpBridge",
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "InputKit", package: "InputKit"),
                .product(name: "OverlayVFS", package: "OverlayVFS"),
                .product(name: "SaveKit", package: "SaveKit"),
                .product(name: "RuntimeCore", package: "RuntimeCore"),
            ],
            resources: [.copy("Ruby")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
