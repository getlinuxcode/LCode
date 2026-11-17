import Foundation

/// Modèles de projets et de fichiers (comme les assistants d'Xcode).
public enum Templates {
    // MARK: - Projet

    /// Crée un projet d'app iOS xtool prêt à compiler (simulateur LSim et iPhone) :
    /// Package.swift (avec la version de SDK pour Liquid Glass), xtool.yml, l'app, une vue avec son aperçu,
    /// un catalogue d'assets (icône, couleur d'accent).
    public static func createProject(name: String, bundleID: String, in parent: URL) throws -> URL {
        let fm = FileManager.default
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !safe.isEmpty else { throw LCodeError("Nom de projet invalide.") }
        let root = parent.appendingPathComponent(safe)
        guard !fm.fileExists(atPath: root.path) else { throw LCodeError("Le dossier \(root.path) existe déjà.") }
        let sources = root.appendingPathComponent("Sources/\(safe)")
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0

        import PackageDescription

        let package = Package(
            name: "\(safe)",
            platforms: [
                .iOS(.v17),
                .macOS(.v14),
            ],
            products: [
                // Un projet xtool contient exactement une bibliothèque : l'app.
                .library(
                    name: "\(safe)",
                    targets: ["\(safe)"]
                ),
            ],
            targets: [
                .target(
                    name: "\(safe)",
                    resources: [.process("Resources")],
                    linkerSettings: [
                        // Déclare le SDK réellement utilisé : sans cela, iOS affiche l'app en mode compatibilité
                        // (sans Liquid Glass).
                        .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "27.3"]),
                    ]
                ),
            ]
        )

        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try """
        version: 1
        bundleID: \(bundleID)

        """.write(to: root.appendingPathComponent("xtool.yml"), atomically: true, encoding: .utf8)

        try """
        .DS_Store
        /.build
        /.lcode
        /xtool
        /Packages
        .swiftpm/

        """.write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        try """
        import SwiftUI

        @main
        struct \(safe)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }

        """.write(to: sources.appendingPathComponent("\(safe)App.swift"), atomically: true, encoding: .utf8)

        try swiftUIView(named: "ContentView").write(to: sources.appendingPathComponent("ContentView.swift"),
                                                    atomically: true, encoding: .utf8)
        try createAssetCatalog(in: sources.appendingPathComponent("Resources"))
        return root
    }

    // MARK: - Fichiers

    public enum FileKind: String, CaseIterable, Sendable {
        case swiftUIView, swiftFile, observableModel, list, empty

        public var title: String {
            switch self {
            case .swiftUIView: return "Vue SwiftUI"
            case .swiftFile: return "Fichier Swift"
            case .observableModel: return "Modèle @Observable"
            case .list: return "Liste avec navigation"
            case .empty: return "Fichier vide"
            }
        }

        public var subtitle: String {
            switch self {
            case .swiftUIView: return "Une vue avec son aperçu #Preview"
            case .swiftFile: return "Un fichier Swift vide (import Foundation)"
            case .observableModel: return "Une classe de données observée par les vues"
            case .list: return "Une liste qui ouvre un détail, avec aperçu"
            case .empty: return "Aucun contenu"
            }
        }

        public var icon: String {
            switch self {
            case .swiftUIView: return "view-paged-symbolic"
            case .swiftFile: return "text-x-script-symbolic"
            case .observableModel: return "drive-multidisk-symbolic"
            case .list: return "view-list-symbolic"
            case .empty: return "text-x-generic-symbolic"
            }
        }
    }

    /// Contenu d'un nouveau fichier ; `name` est le nom du type (sans « .swift »).
    public static func file(_ kind: FileKind, named name: String) -> String {
        switch kind {
        case .swiftUIView: return swiftUIView(named: name)
        case .swiftFile:
            return """
            import Foundation

            """
        case .observableModel:
            return """
            import Foundation
            import Observation

            @Observable
            final class \(name) {
                var items: [String] = []

                func add(_ item: String) {
                    items.append(item)
                }
            }

            """
        case .list:
            return """
            import SwiftUI

            struct \(name): View {
                let items = ["Un", "Deux", "Trois"]

                var body: some View {
                    NavigationStack {
                        List(items, id: \\.self) { item in
                            NavigationLink(item) {
                                Text(item)
                                    .font(.largeTitle)
                                    .navigationTitle(item)
                            }
                        }
                        .navigationTitle("\(name)")
                    }
                }
            }

            #Preview {
                \(name)()
            }

            """
        case .empty:
            return ""
        }
    }

    static func swiftUIView(named name: String) -> String {
        """
        import SwiftUI

        struct \(name): View {
            var body: some View {
                VStack(spacing: 16) {
                    Image(systemName: "globe")
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                    Text("Bonjour !")
                }
                .padding()
            }
        }

        #Preview {
            \(name)()
        }

        """
    }

    // MARK: - Assets

    /// Catalogue d'assets minimal : icône d'app et couleur d'accent (format Xcode).
    public static func createAssetCatalog(in folder: URL) throws {
        let fm = FileManager.default
        let catalog = folder.appendingPathComponent("Assets.xcassets")
        try fm.createDirectory(at: catalog.appendingPathComponent("AppIcon.appiconset"), withIntermediateDirectories: true)
        try fm.createDirectory(at: catalog.appendingPathComponent("AccentColor.colorset"), withIntermediateDirectories: true)
        let info = #"{ "info" : { "author" : "xcode", "version" : 1 } }"#
        try (info + "\n").write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        try """
        {
          "images" : [ { "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
          "info" : { "author" : "xcode", "version" : 1 }
        }

        """.write(to: catalog.appendingPathComponent("AppIcon.appiconset/Contents.json"), atomically: true, encoding: .utf8)
        try """
        {
          "colors" : [ { "idiom" : "universal" } ],
          "info" : { "author" : "xcode", "version" : 1 }
        }

        """.write(to: catalog.appendingPathComponent("AccentColor.colorset/Contents.json"), atomically: true, encoding: .utf8)
    }
}
