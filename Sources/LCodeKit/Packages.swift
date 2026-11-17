import Foundation

/// Produit d'un paquet externe utilisé par une cible (`.product(name:package:)`).
public struct ProductReference: Hashable, Sendable {
    public let name: String
    /// Identité (ou nom) du paquet qui le fournit.
    public let package: String?

    public var declaration: String {
        package.map { ".product(name: \"\(name)\", package: \"\($0)\")" } ?? "\"\(name)\""
    }
}

/// Dépendance d'un paquet (`.package(url:…)` ou `.package(path:)`), lue dans `swift package dump-package`.
public struct PackageDependency: Hashable, Sendable {
    public enum Requirement: Hashable, Sendable {
        case range(String, String)
        case exact(String)
        case branch(String)
        case revision(String)
    }

    public enum Source: Hashable, Sendable {
        case remote(url: String, Requirement)
        case local(path: String)
    }

    public let identity: String
    public let source: Source

    init?(dump: [String: Any]) {
        if let entry = (dump["sourceControl"] as? [[String: Any]])?.first {
            guard let identity = entry["identity"] as? String else { return nil }
            let location = entry["location"] as? [String: Any]
            let remote = location?["remote"] as? [Any]
            let url = (remote?.first as? [String: Any])?["urlString"] as? String ?? remote?.first as? String
            guard let url, let req = entry["requirement"] as? [String: Any] else { return nil }
            let requirement: Requirement
            if let range = (req["range"] as? [[String: Any]])?.first,
               let lower = range["lowerBound"] as? String, let upper = range["upperBound"] as? String {
                requirement = .range(lower, upper)
            } else if let v = (req["exact"] as? [String])?.first {
                requirement = .exact(v)
            } else if let v = (req["branch"] as? [String])?.first {
                requirement = .branch(v)
            } else if let v = (req["revision"] as? [String])?.first {
                requirement = .revision(v)
            } else {
                return nil
            }
            self.identity = identity
            source = .remote(url: url, requirement)
        } else if let entry = (dump["fileSystem"] as? [[String: Any]])?.first,
                  let identity = entry["identity"] as? String, let path = entry["path"] as? String {
            self.identity = identity
            source = .local(path: path)
        } else {
            return nil
        }
    }

    /// Déclaration pour un manifeste généré.
    public var declaration: String {
        switch source {
        case let .local(path):
            return ".package(path: \"\(path)\")"
        case let .remote(url, requirement):
            switch requirement {
            case let .range(lower, upper): return ".package(url: \"\(url)\", \"\(lower)\"..<\"\(upper)\")"
            case let .exact(v): return ".package(url: \"\(url)\", exact: \"\(v)\")"
            case let .branch(b): return ".package(url: \"\(url)\", branch: \"\(b)\")"
            case let .revision(r): return ".package(url: \"\(url)\", revision: \"\(r)\")"
            }
        }
    }
}

/// Paquets du projet pour le simulateur : ceux en Swift pur sont repris tels quels ; ceux qui importent
/// SwiftUI sont copiés dans `.lcode/paquets/` et leur manifeste est complété pour que ce `SwiftUI`
/// désigne l'API de LSim (le module SwiftUI de LCode). Les versions suivent le Package.resolved du projet.
public struct PackageOverlay {
    public let project: XtoolProject
    public let lcodeRoot: URL
    public var directory: URL { project.root.appendingPathComponent(".lcode/paquets") }
    private var resolution: URL { directory.appendingPathComponent(".resolution") }

    public init(project: XtoolProject, lcodeRoot: URL) {
        self.project = project
        self.lcodeRoot = lcodeRoot
    }

    /// Déclarations de dépendances pour le paquet du simulateur ou des aperçus (vide sans dépendance).
    /// La résolution (réseau) n'est refaite que si les dépendances ou le Package.resolved changent.
    public func dependencyDeclarations() throws -> [String] {
        guard !project.dependencies.isEmpty else { return [] }
        let fm = FileManager.default
        let resolvedURL = project.root.appendingPathComponent("Package.resolved")
        let resolved = (try? String(contentsOf: resolvedURL, encoding: .utf8)) ?? ""
        let key = (project.dependencies.map(\.declaration) + [resolved, lcodeRoot.path, "v2:" + Self.lsimModules.joined(separator: ",")]).joined(separator: "\n")
        let stateURL = directory.appendingPathComponent("etat.json")
        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           state["key"] as? String == key, let lines = state["declarations"] as? [String] {
            return lines
        }

        // 1. Résolution à part (mêmes versions que le projet), pour obtenir les sources des paquets.
        try fm.createDirectory(at: resolution, withIntermediateDirectories: true)
        let manifest = """
        // swift-tools-version: 5.9
        // Généré par LCode : résolution des paquets du projet pour le simulateur.
        import PackageDescription

        let package = Package(
            name: "LCodeResolution",
            dependencies: [
                \(project.dependencies.map(\.declaration).joined(separator: ",\n        "))
            ],
            targets: []
        )

        """
        try manifest.write(to: resolution.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let pinned = resolution.appendingPathComponent("Package.resolved")
        try? fm.removeItem(at: pinned)
        if !resolved.isEmpty { try? fm.copyItem(at: resolvedURL, to: pinned) }
        try Shell.capture(["swift", "package", "resolve", "--package-path", resolution.path])

        // 2. Paquets (directs ou transitifs) qui importent un framework Apple recréé par LSim : copiés et branchés.
        var candidates: [(identity: String, folder: URL)] = []
        let checkouts = resolution.appendingPathComponent(".build/checkouts")
        for name in (try? fm.contentsOfDirectory(atPath: checkouts.path)) ?? [] where !name.hasPrefix(".") {
            candidates.append((name.lowercased(), checkouts.appendingPathComponent(name)))
        }
        for dep in project.dependencies {
            if case let .local(path) = dep.source { candidates.append((dep.identity, URL(fileURLWithPath: path))) }
        }
        var patched: [String: URL] = [:]
        for c in candidates where Self.importsLSimModule(c.folder) {
            let copy = directory.appendingPathComponent(c.identity)
            try? fm.removeItem(at: copy)
            try Shell.capture(["cp", "-a", c.folder.path, copy.path])
            try? fm.removeItem(at: copy.appendingPathComponent(".git"))
            try? fm.removeItem(at: copy.appendingPathComponent(".build"))
            try patchManifest(in: copy)
            patched[c.identity] = copy
        }

        // 3. Déclarations : copies retouchées (qui remplacent les originaux, même identité), sinon d'origine.
        var lines = project.dependencies.map { dep in
            patched[dep.identity].map { ".package(path: \"\($0.path)\")" } ?? dep.declaration
        }
        let direct = Set(project.dependencies.map(\.identity))
        for (identity, copy) in patched.sorted(by: { $0.key < $1.key }) where !direct.contains(identity) {
            lines.append(".package(path: \"\(copy.path)\")")
        }
        let state: [String: Any] = ["key": key, "declarations": lines, "copies": patched.keys.sorted()]
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: stateURL)
        return lines
    }

    /// Paquets copiés et branchés sur LSim lors de la dernière résolution.
    public var patchedPackages: [String] {
        let stateURL = directory.appendingPathComponent("etat.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return state["copies"] as? [String] ?? []
    }

    /// Frameworks Apple recréés par LCode pour le simulateur (un produit du paquet LCode chacun).
    public static let lsimModules = ["SwiftUI", "Combine", "CoreMedia", "CoreVideo", "AVFoundation", "AVKit"]

    /// Une source du paquet (hors tests et exemples) importe-t-elle un framework recréé par LSim ?
    static func importsLSimModule(_ folder: URL) -> Bool {
        let sources = folder.appendingPathComponent("Sources")
        let root = FileManager.default.fileExists(atPath: sources.path) ? sources : folder
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        let pattern = try! NSRegularExpression(pattern: #"(?m)^\s*(@\w+\s+)*import\s+(struct\s+|class\s+|enum\s+|protocol\s+|func\s+|typealias\s+)?(\#(lsimModules.joined(separator: "|")))\b"#)
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if [".build", ".git", "Tests", "Examples", "Example", "Demo"].contains(name) { walker.skipDescendants(); continue }
            guard url.pathExtension == "swift", name != "Package.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        }
        return false
    }

    /// Complète le manifeste copié : dépendance au module SwiftUI de LCode pour chaque cible (le code du
    /// manifeste est du Swift, on agit sur l'objet `package` après sa création).
    private func patchManifest(in copy: URL) throws {
        let fm = FileManager.default
        // Variantes « Package@swift-x.swift » : retirées pour que le manifeste retouché soit celui utilisé.
        for name in (try? fm.contentsOfDirectory(atPath: copy.path)) ?? [] where name.hasPrefix("Package@swift") {
            try? fm.removeItem(at: copy.appendingPathComponent(name))
        }
        let url = copy.appendingPathComponent("Package.swift")
        var manifest = try String(contentsOf: url, encoding: .utf8)
        let tools = manifest.split(separator: "\n").first.flatMap { line -> Double? in
            guard let r = line.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return nil }
            return Double(line[r])
        } ?? 5.0
        // Mode Swift 5 (LSimUI n'annote pas encore toute sa concurrence) : réglage disponible depuis les outils 6.
        let languageMode = tools >= 6 ? "\n    target.swiftSettings = (target.swiftSettings ?? []) + [.swiftLanguageMode(.v5)]" : ""
        manifest += """


        // Ajouté par LCode : dans le simulateur, les frameworks Apple (SwiftUI, Combine…) sont ceux de LSim.
        package.dependencies.append(.package(path: "\(lcodeRoot.path)"))
        for target in package.targets where target.type == .regular || target.type == .executable {
            for module in [\(Self.lsimModules.map { "\"\($0)\"" }.joined(separator: ", "))] {
                target.dependencies.append(.product(name: module, package: "\(lcodeRoot.lastPathComponent)"))
            }\(languageMode)
        }

        """
        try manifest.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Gestion des paquets d'un projet (comme « Add Package Dependencies… » d'Xcode) : le Package.swift du
/// projet est modifié par SwiftPM lui-même (`swift package add-dependency`, `add-target-dependency`).
public enum PackageManager {
    /// Identité SwiftPM d'un paquet distant : dernier composant de l'URL, sans « .git », en minuscules.
    public static func identity(of url: String) -> String {
        var last = url.split(separator: "/").last.map(String.init) ?? url
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last.lowercased()
    }

    /// Dernière version publiée (étiquette semver la plus haute) d'un dépôt git.
    public static func latestVersion(of url: String) throws -> String? {
        let output = try Shell.capture(["git", "ls-remote", "--tags", "--refs", url])
        let versions: [[Int]] = output.split(separator: "\n").compactMap { line in
            guard let tag = line.split(separator: "/").last else { return nil }
            let clean = tag.hasPrefix("v") ? tag.dropFirst() : Substring(tag)
            let parts = clean.split(separator: ".").map { Int($0) }
            guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.map { $0! }
        }
        return versions.max { $0.lexicographicallyPrecedes($1) }.map { $0.map(String.init).joined(separator: ".") }
    }

    /// Ajoute la dépendance (à partir de `version`), résout, et renvoie les produits bibliothèque du paquet.
    public static func addDependency(url: String, from version: String, to root: URL) throws -> [String] {
        try Shell.capture(["swift", "package", "--package-path", root.path, "add-dependency", url, "--from", version])
        try Shell.capture(["swift", "package", "--package-path", root.path, "resolve"])
        let checkout = root.appendingPathComponent(".build/checkouts")
        let folder = ((try? FileManager.default.contentsOfDirectory(atPath: checkout.path)) ?? [])
            .first { $0.lowercased() == identity(of: url) }
            .map { checkout.appendingPathComponent($0) }
        guard let folder else { return [] }
        let dump = try Shell.capture(["swift", "package", "dump-package", "--package-path", folder.path])
        let json = try JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any]
        return ((json?["products"] as? [[String: Any]]) ?? [])
            .filter { ($0["type"] as? [String: Any])?["library"] != nil }
            .compactMap { $0["name"] as? String }
    }

    /// Rend un produit du paquet utilisable par la cible (`import Produit`).
    public static func addProduct(_ product: String, package: String, target: String, root: URL) throws {
        try Shell.capture(["swift", "package", "--package-path", root.path, "add-target-dependency", product, target,
                           "--package", package])
    }

    /// Retire un paquet du manifeste : sa déclaration et les produits qui en viennent.
    public static func removeDependency(identity: String, root: URL) throws {
        let url = root.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: url, encoding: .utf8)
        let lines = manifest.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(".package("), let r = t.range(of: #"(url|path):\s*"([^"]+)""#, options: .regularExpression) {
                let value = t[r].split(separator: "\"").dropFirst().first.map(String.init) ?? ""
                return Self.identity(of: value) != identity
            }
            if t.hasPrefix(".product("), t.lowercased().contains("package: \"\(identity)\"") { return false }
            return true
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
