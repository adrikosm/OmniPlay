// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InputKit",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "InputKit", targets: ["InputKit"])],
    dependencies: [
    ],
    targets: [
        .target(
            name: "InputKit",
            dependencies: [
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
