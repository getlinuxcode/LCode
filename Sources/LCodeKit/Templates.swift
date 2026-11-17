import Foundation

/// Project and file templates (like Xcode's templates).
public enum Templates {
    // MARK: - Project

    /// Creates an xtool iOS app project that builds for the LSim simulator and iPhone: Package.swift (with the SDK
    /// version needed for Liquid Glass), xtool.yml, the app, a view with its preview, and an asset catalog.
    public static func createProject(name: String, bundleID: String, in parent: URL) throws -> URL {
        let fm = FileManager.default
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !safe.isEmpty else { throw LCodeError("Invalid project name.") }
        let root = parent.appendingPathComponent(safe)
        guard !fm.fileExists(atPath: root.path) else { throw LCodeError("The folder \(root.path) already exists.") }
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
                // An xtool project has exactly one library: the app.
                .library(
                    name: "\(safe)",
                    targets: ["\(safe)"]
                ),
            ],
            targets: [
                .target(
                    name: "\(safe)",
                    // Asset catalogs need Apple's actool (macOS only): the simulator reads the catalog
                    // directly, iPhone builds leave it out until xtool compiles catalogs.
                    exclude: ["Resources/Assets.xcassets"],
                    resources: [.process("Resources")],
                    linkerSettings: [
                        // Declares the SDK actually used; without it, iOS runs the app in compatibility mode
                        // (no Liquid Glass).
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

    // MARK: - Files

    public enum FileKind: String, CaseIterable, Sendable {
        case swiftUIView, swiftFile, observableModel, list, empty

        public var title: String {
            switch self {
            case .swiftUIView: return tr("SwiftUI View")
            case .swiftFile: return tr("Swift File")
            case .observableModel: return tr("@Observable Model")
            case .list: return tr("List with Navigation")
            case .empty: return tr("Empty File")
            }
        }

        public var subtitle: String {
            switch self {
            case .swiftUIView: return tr("A view with its #Preview")
            case .swiftFile: return tr("An empty Swift file (import Foundation)")
            case .observableModel: return tr("A data class observed by views")
            case .list: return tr("A list that opens a detail view, with a preview")
            case .empty: return tr("No content")
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

    /// Contents of a new file; `name` is the type name (without `.swift`).
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
                let items = ["One", "Two", "Three"]

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
                    Text("Hello, world!")
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

    /// Minimal asset catalog: app icon and accent color (Xcode format).
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
