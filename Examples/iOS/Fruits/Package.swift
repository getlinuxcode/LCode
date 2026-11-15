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
                // Déclare le SDK réellement utilisé (iOS 27.3) : sans cela, lld inscrit « sdk 17.0 »
                // et iOS affiche l'app en mode compatibilité, sans le design Liquid Glass.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "27.3"]),
            ]
        ),
    ]
)
