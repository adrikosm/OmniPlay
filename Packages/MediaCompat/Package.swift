// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaCompat",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [.library(name: "MediaCompat", targets: ["MediaCompat"])],
    targets: [.target(name: "MediaCompat")],
    swiftLanguageModes: [.v6]
)
