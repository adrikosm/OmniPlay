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
        .package(path: "../GameDetection"),
        .package(path: "../GameStore"),
        .package(path: "../OverlayVFS"),
        .package(path: "../LocalGameServer"),
    ],
    targets: [
        // Ogg Vorbis decoding for the web runtime. The symbols come from libvorbisfile, which the app links for mkxp-z;
        // the headers under xiph/ are that build's (libogg, libvorbis; BSD).
        .target(name: "COggVorbis", cSettings: [.headerSearchPath("xiph")]),
        .target(
            name: "RuntimeCore",
            dependencies: [
                "COggVorbis",
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                .product(name: "InputKit", package: "InputKit"),
                .product(name: "SaveKit", package: "SaveKit"),
                .product(name: "GameDetection", package: "GameDetection"),
                .product(name: "GameStore", package: "GameStore"),
                .product(name: "OverlayVFS", package: "OverlayVFS"),
                .product(name: "LocalGameServer", package: "LocalGameServer"),
            ],
            resources: [.copy("WebRuntimeAssets")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
