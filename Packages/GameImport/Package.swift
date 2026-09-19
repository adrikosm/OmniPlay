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
        // Static libarchive 3.8.9 + liblzma + libzstd, built by Scripts/build-libarchive.sh (gitignored output).
        .binaryTarget(name: "CLibArchive", path: "Native/libarchive.xcframework"),
        .target(
            name: "GameImport",
            dependencies: [
                .product(name: "GameCore", package: "GameCore"),
                .product(name: "Diagnostics", package: "Diagnostics"),
                "CLibArchive",
            ],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv")]
        ),
        .testTarget(name: "GameImportTests", dependencies: ["GameImport", .product(name: "TestSupport", package: "GameCore")]),
    ],
    swiftLanguageModes: [.v6]
)
