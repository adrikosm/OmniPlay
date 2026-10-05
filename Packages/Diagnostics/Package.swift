// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Diagnostics",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "Diagnostics", targets: ["Diagnostics"])],
    dependencies: [
        .package(path: "../GameCore"),
    ],
    targets: [
        .target(name: "CCrashGuard"),
        .target(
            name: "Diagnostics",
            dependencies: [
                "CCrashGuard",
                .product(name: "GameCore", package: "GameCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
