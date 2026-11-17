// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Fruits",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "Fruits",
            targets: ["Fruits"]
        ),
    ],
    targets: [
        .target(
            name: "Fruits",
            linkerSettings: [
                // Declare the SDK actually used (iOS 27.3): otherwise lld writes "sdk 17.0" and iOS
                // runs the app in compatibility mode, without the Liquid Glass design.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "27.3"]),
            ]
        ),
    ]
)
