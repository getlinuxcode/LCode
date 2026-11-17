import Foundation

/// Erreurs de LCodeKit, avec un message destiné à l'utilisateur.
public struct LCodeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Un projet xtool : un paquet SwiftPM dont l'unique produit bibliothèque est l'app.
public struct XtoolProject {
    public struct Target {
        public let name: String
        /// Dossier des sources (absolu).
        public let path: URL
        /// Cibles locales dont elle dépend.
        public let localDependencies: [String]
        /// Produits de paquets externes dont elle dépend (non pris en charge dans le simulateur).
        public let externalProducts: [String]
        public let hasResources: Bool
    }

    public let root: URL
    public let name: String
    public let bundleID: String?
    /// Cible de l'app (celle du produit bibliothèque).
    public let appTarget: String
    /// Cibles locales nécessaires à l'app (l'app comprise), dans l'ordre de dépendance.
    public let targets: [Target]
    public let manifest: String

    /// Catalogues d'assets (`*.xcassets`) des cibles de l'app.
    public var assetCatalogs: [URL] {
        targets.flatMap { t -> [URL] in
            guard let walker = FileManager.default.enumerator(at: t.path, includingPropertiesForKeys: nil) else { return [] }
            var found: [URL] = []
            for case let url as URL in walker where url.pathExtension == "xcassets" {
                found.append(url)
                walker.skipDescendants()
            }
            return found
        }
    }

    /// Variables d'environnement qui donnent au simulateur les ressources du projet.
    public var simulatorEnvironment: [String: String] {
        let catalogs = assetCatalogs
        return catalogs.isEmpty ? [:] : ["LSIM_ASSETS": catalogs.map(\.path).joined(separator: ":")]
    }

    /// Le binaire iOS déclarera-t-il le bon SDK (sinon iOS affiche l'app en mode compatibilité) ?
    public var hasSDKVersionFix: Bool { manifest.contains("platform_version") }

    public static func load(at root: URL) throws -> XtoolProject {
        let manifestURL = root.appendingPathComponent("Package.swift")
        guard let manifest = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw LCodeError("Aucun Package.swift dans \(root.path) : ce n'est pas un projet xtool.")
        }
        let dump = try Shell.capture(["swift", "package", "dump-package", "--package-path", root.path])
        guard let json = try JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any] else {
            throw LCodeError("Description du paquet illisible.")
        }
        let name = json["name"] as? String ?? root.lastPathComponent
        let products = json["products"] as? [[String: Any]] ?? []
        let libraries = products.filter { ($0["type"] as? [String: Any])?["library"] != nil }
        guard let app = libraries.first, let appTarget = (app["targets"] as? [String])?.first else {
            throw LCodeError("Le projet doit déclarer un produit bibliothèque (convention xtool).")
        }

        var all: [String: Target] = [:]
        for t in json["targets"] as? [[String: Any]] ?? [] {
            guard let tname = t["name"] as? String, (t["type"] as? String) == "regular" else { continue }
            let relative = t["path"] as? String ?? "Sources/\(tname)"
            var local: [String] = []
            var external: [String] = []
            for dep in t["dependencies"] as? [[String: Any]] ?? [] {
                if let byName = dep["byName"] as? [Any], let n = byName.first as? String { local.append(n) }
                if let target = dep["target"] as? [Any], let n = target.first as? String { local.append(n) }
                if let product = dep["product"] as? [Any], let n = product.first as? String { external.append(n) }
            }
            let resources = (t["resources"] as? [Any])?.isEmpty == false
            all[tname] = Target(name: tname, path: root.appendingPathComponent(relative),
                                localDependencies: local, externalProducts: external, hasResources: resources)
        }

        // Cibles nécessaires à l'app, dépendances d'abord.
        var ordered: [Target] = []
        var seen = Set<String>()
        func visit(_ n: String) {
            guard !seen.contains(n), let t = all[n] else { return }
            seen.insert(n)
            t.localDependencies.forEach(visit)
            ordered.append(t)
        }
        visit(appTarget)

        let bundleID = (try? String(contentsOf: root.appendingPathComponent("xtool.yml"), encoding: .utf8))?
            .split(separator: "\n")
            .first { $0.hasPrefix("bundleID:") }
            .map { $0.dropFirst("bundleID:".count).trimmingCharacters(in: .whitespaces) }

        return XtoolProject(root: root, name: name, bundleID: bundleID, appTarget: appTarget,
                            targets: ordered, manifest: manifest)
    }
}
