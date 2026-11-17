// swift-tools-version: 6.3
import PackageDescription

// Separate package so LCode itself (a dependency of every simulator build) stays dependency-free.
let package = Package(
    name: "AssetCompiler",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/xtool-org/AssetKit", .upToNextMinor(from: "1.0.0")),
    ],
    targets: [
        .executableTarget(name: "lcode-assets", dependencies: [.product(name: "AssetKit", package: "AssetKit")]),
    ]
)
