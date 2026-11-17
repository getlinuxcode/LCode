import Foundation

/// Paquet « simulateur » généré à côté d'un projet xtool : les MÊMES sources (liens symboliques),
/// compilées pour Linux contre LSimUI, exposé sous le nom de module `SwiftUI`.
public struct SimulatorBuild {
    public let project: XtoolProject
    /// Racine du dépôt LCode (qui fournit LSimUI, LSimHost et le module SwiftUI).
    public let lcodeRoot: URL
    /// Dossier du paquet généré : <projet>/.lcode/simulateur
    public var directory: URL { project.root.appendingPathComponent(".lcode/simulateur") }

    public init(project: XtoolProject, lcodeRoot: URL) {
        self.project = project
        self.lcodeRoot = lcodeRoot
    }

    /// Avertissements sur ce que le simulateur ne sait pas (encore) reproduire.
    public var warnings: [String] {
        var w: [String] = []
        for t in project.targets {
            if !t.externalProducts.isEmpty {
                w.append("La cible \(t.name) dépend de paquets externes (\(t.externalProducts.joined(separator: ", "))) : non pris en charge par le simulateur pour l'instant.")
            }
            if t.hasResources {
                w.append("La cible \(t.name) a des ressources : elles ne sont pas encore copiées dans le simulateur.")
            }
        }
        return w
    }

    /// Écrit le paquet simulateur (idempotent : seuls les fichiers modifiés changent).
    public func generate() throws {
        let fm = FileManager.default
        let targetsDir = directory.appendingPathComponent("Cibles")
        try fm.createDirectory(at: targetsDir, withIntermediateDirectories: true)

        // Copie des sources (les blocs `#Preview` réécrits en fonctions ordinaires, sur les mêmes lignes),
        // réécrite seulement si elle change : modifier le projet modifie le simulateur.
        var index = 0
        for t in project.targets {
            let found = try SourceMirror.mirror(from: t.path, to: targetsDir.appendingPathComponent(t.name),
                                                removeMain: false, firstIndex: index)
            index += found.reduce(0) { $0 + $1.previews.count }
        }

        let lcodeName = lcodeRoot.lastPathComponent
        var targets: [String] = []
        for t in project.targets {
            let deps = t.localDependencies.map { "\"\($0)\"" } + [".product(name: \"SwiftUI\", package: \"\(lcodeName)\")"]
            let kind = t.name == project.appTarget ? "executableTarget" : "target"
            targets.append("""
                    .\(kind)(
                        name: "\(t.name)",
                        dependencies: [\(deps.joined(separator: ", "))],
                        path: "Cibles/\(t.name)",
                        // Mode Swift 5 : LSimUI n'annote pas encore toute sa concurrence.
                        swiftSettings: [.swiftLanguageMode(.v5)]
                    ),
            """)
        }

        let manifest = """
        // swift-tools-version: 6.0
        // Généré par LCode — ne pas modifier : régénéré à chaque `lcode run`.
        // Les sources sont des liens vers le projet \(project.name) ; `import SwiftUI` y désigne LSimUI.
        import PackageDescription

        let package = Package(
            name: "\(project.name)Simulateur",
            dependencies: [
                .package(path: "\(lcodeRoot.path)"),
            ],
            targets: [
        \(targets.joined(separator: "\n"))
            ]
        )

        """
        let manifestURL = directory.appendingPathComponent("Package.swift")
        if (try? String(contentsOf: manifestURL, encoding: .utf8)) != manifest {
            try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        }
    }

    /// Compile l'app pour le simulateur ; renvoie le chemin de l'exécutable.
    public func build() throws -> URL {
        try generate()
        let status = try Shell.run(["swift", "build", "--package-path", directory.path, "--product", project.appTarget])
        guard status == 0 else {
            throw LCodeError("La compilation pour le simulateur a échoué (voir les erreurs ci-dessus).")
        }
        let binPath = try Shell.capture(["swift", "build", "--package-path", directory.path, "--show-bin-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: binPath).appendingPathComponent(project.appTarget)
    }
}

/// Options de lancement dans le simulateur (variables LSIM_* de LSimHost).
public struct SimulatorOptions {
    public var device = "iphone17promax"
    public var dark = false
    public var screenshot: String?
    public var taps: String?

    public init() {}

    var environment: [String: String] {
        var env = ["LSIM_DEVICE": device]
        if dark { env["LSIM_DARK"] = "1" }
        if let screenshot { env["LSIM_SCREENSHOT"] = screenshot }
        if let taps { env["LSIM_TAPS"] = taps }
        return env
    }
}

extension SimulatorBuild {
    /// Compile puis lance l'app dans le simulateur (fenêtre, ou capture si `screenshot`).
    public func run(_ options: SimulatorOptions) throws -> Int32 {
        let binary = try build()
        return try Shell.run([binary.path], environment: options.environment)
    }
}
