// swift-tools-version: 6.3
import PackageDescription

// Separate package so LCode itself (a dependency of every simulator build) stays dependency-free.
let package = Package(
    name: "AssetCompiler",
    platforms: [.macOS(.v13)],
    dependencies: [
        // AssetKit 1.0.0 opens on iOS but its renditions aren't found ("No image named … found in asset catalog").
        // This revision stacks xtool-org/AssetKit#2, #3 (actool 26.5 key structure) and #6 (BOM, padding, alpha), as
        // used on device by gulian/xtool's testflight-linux branch. Back to an AssetKit release once they're merged.
        .package(url: "https://github.com/gulian/AssetKit", revision: "e077f8146abcec600de1f3df2eb4bf26927f24c2"),
    ],
    targets: [
        .executableTarget(name: "lcode-assets", dependencies: [.product(name: "AssetKit", package: "AssetKit")]),
    ]
)
