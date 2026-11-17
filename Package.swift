// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "LCode",
    products: [
        // Réimplémentation de l'API SwiftUI (sans dépendance graphique).
        .library(name: "LSimUI", targets: ["LSimUI"]),
        // Module que le code utilisateur importe sous le nom `SwiftUI` pour le simulateur.
        .library(name: "SwiftUI", targets: ["SwiftUI"]),
    ],
    targets: [
        .target(name: "LSimUI", resources: [.process("Profiles")], swiftSettings: v5),
        .systemLibrary(
            name: "CGtk",
            pkgConfig: "gtk4",
            providers: [.apt(["libgtk-4-dev"])]
        ),
        // Optimisé même en debug : le rendu du verre et du flou se calcule pixel par pixel.
        .target(name: "LSimHost", dependencies: ["LSimUI", "CGtk"], swiftSettings: v5 + [.unsafeFlags(["-O"])]),
        .target(name: "SwiftUI", dependencies: ["LSimUI", "LSimHost"], swiftSettings: v5),
        // Cœur de l'IDE : projets xtool, génération et lancement du simulateur.
        .target(name: "LCodeKit", swiftSettings: v5),
        .executableTarget(name: "lcode", dependencies: ["LCodeKit"], swiftSettings: v5),
        .systemLibrary(
            name: "CAdw",
            pkgConfig: "libadwaita-1",
            providers: [.apt(["libadwaita-1-dev"])]
        ),
        // L'IDE : fenêtre GTK4/libadwaita façon Xcode (navigateur, éditeur, console, simulateur).
        .executableTarget(name: "lcode-ide", dependencies: ["LCodeKit", "CAdw"], path: "Sources/LCodeIDE", swiftSettings: v5),
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
    ]
)
