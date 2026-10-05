// swift-tools-version: 6.0
import PackageDescription

/// Media preparation over FFmpeg (Scripts/native/build-ffmpeg.sh). The FFmpeg libraries are static archives the app
/// links; this package compiles against their headers only (`ffmpeg` is a link to Native/prebuilt/ffmpeg/include),
/// so it builds for the app and is never linked into a Mac test.
let package = Package(
    name: "MediaTranscode",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "MediaTranscode", targets: ["MediaTranscode"])],
    dependencies: [.package(path: "../MediaCompat"), .package(path: "../GameCore")],
    targets: [
        .target(name: "CTranscode", cSettings: [.headerSearchPath("ffmpeg")]),
        .target(
            name: "MediaTranscode",
            dependencies: [
                "CTranscode",
                .product(name: "MediaCompat", package: "MediaCompat"),
                .product(name: "GameCore", package: "GameCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
