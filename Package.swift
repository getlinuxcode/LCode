// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "LCode",
    products: [
        // SwiftUI API reimplementation (no graphics dependency).
        .library(name: "LSimUI", targets: ["LSimUI"]),
        // What user code imports as `SwiftUI` in simulator builds.
        .library(name: "SwiftUI", targets: ["SwiftUI"]),
        // Apple's Combine does not exist on Linux.
        .library(name: "Combine", targets: ["Combine"]),
        // Media playback through ffmpeg, shown by VideoPlayer (AVKit).
        .library(name: "CoreMedia", targets: ["CoreMedia"]),
        .library(name: "CoreVideo", targets: ["CoreVideo"]),
        .library(name: "AVFoundation", targets: ["AVFoundation"]),
        .library(name: "AVKit", targets: ["AVKit"]),
    ],
    targets: [
        .target(name: "Combine", swiftSettings: v5),
        .target(name: "CoreMedia", swiftSettings: v5),
        .target(name: "CoreVideo", swiftSettings: v5),
        .target(name: "AVFoundation", dependencies: ["CoreMedia", "CoreVideo", "Combine"], swiftSettings: v5),
        .target(name: "AVKit", dependencies: ["AVFoundation", "SwiftUI"], swiftSettings: v5),
        .target(name: "LSimUI", dependencies: ["Combine", "CoreVideo"], resources: [.process("Profiles")], swiftSettings: v5),
        .systemLibrary(
            name: "CGtk",
            pkgConfig: "gtk4",
            providers: [.apt(["libgtk-4-dev"])]
        ),
        // Optimized even in debug: glass and blur rendering is computed per pixel.
        .target(name: "LSimHost", dependencies: ["LSimUI", "CGtk"], swiftSettings: v5 + [.unsafeFlags(["-O"])]),
        .target(name: "SwiftUI", dependencies: ["LSimUI", "LSimHost"], swiftSettings: v5),
        .target(name: "LCodeKit", swiftSettings: v5),
        .executableTarget(name: "lcode", dependencies: ["LCodeKit"], swiftSettings: v5),
        .systemLibrary(
            name: "CAdw",
            pkgConfig: "libadwaita-1",
            providers: [.apt(["libadwaita-1-dev"])]
        ),
        .systemLibrary(
            name: "CSource",
            pkgConfig: "gtksourceview-5",
            providers: [.apt(["libgtksourceview-5-dev"])]
        ),
        .executableTarget(name: "lcode-ide", dependencies: ["LCodeKit", "CAdw", "CSource"], path: "Sources/LCodeIDE",
                          exclude: ["Styles"], swiftSettings: v5),
        .executableTarget(
            name: "CounterExample",
            dependencies: ["SwiftUI"],
            path: "Examples/Counter",
            swiftSettings: v5
        ),
        .executableTarget(
            name: "FruitsExample",
            dependencies: ["SwiftUI"],
            path: "Examples/Shared/Fruits",
            swiftSettings: v5
        ),
        .executableTarget(
            name: "CatalogExample",
            dependencies: ["SwiftUI"],
            path: "Examples/Shared/Catalog",
            swiftSettings: v5
        ),
        .testTarget(name: "LSimUITests", dependencies: ["LSimUI"], swiftSettings: v5),
        .testTarget(name: "LCodeKitTests", dependencies: ["LCodeKit"], swiftSettings: v5),
    ]
)
