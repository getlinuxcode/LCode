import Foundation

/// LCodeKit error with a user-facing message.
public struct LCodeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// An xtool project: a SwiftPM package whose single library product is the app.
public struct XtoolProject {
    public struct Target {
        public let name: String
        /// Absolute source folder.
        public let path: URL
        public let localDependencies: [String]
        public let externalProducts: [ProductReference]
        public let hasResources: Bool
    }

    public let root: URL
    public let name: String
    public let bundleID: String?
    /// Target of the library product.
    public let appTarget: String
    /// Local targets the app needs (app included), dependencies first.
    public let targets: [Target]
    public let manifest: String
    /// Package dependencies, re-declared by the simulator and preview builds.
    public let dependencies: [PackageDependency]

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

    /// Environment that gives the simulator the project's resources.
    public var simulatorEnvironment: [String: String] {
        let catalogs = assetCatalogs
        return catalogs.isEmpty ? [:] : ["LSIM_ASSETS": catalogs.map(\.path).joined(separator: ":")]
    }

    /// Whether the iOS binary declares the right SDK (otherwise iOS runs the app in compatibility mode).
    public var hasSDKVersionFix: Bool { manifest.contains("platform_version") }

    /// Build caches from LCode versions with French folder names, now unused.
    static func removeLegacyBuildFolders(in root: URL) {
        for name in ["simulateur", "apercu", "paquets"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".lcode/\(name)"))
        }
    }

    public static func load(at root: URL) throws -> XtoolProject {
        let manifestURL = root.appendingPathComponent("Package.swift")
        guard let manifest = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw LCodeError("No Package.swift in \(root.path): not an xtool project.")
        }
        removeLegacyBuildFolders(in: root)
        let dump = try Shell.capture(["swift", "package", "dump-package", "--package-path", root.path])
        guard let json = try JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any] else {
            throw LCodeError("Unreadable package description.")
        }
        let name = json["name"] as? String ?? root.lastPathComponent
        let products = json["products"] as? [[String: Any]] ?? []
        let libraries = products.filter { ($0["type"] as? [String: Any])?["library"] != nil }
        guard let app = libraries.first, let appTarget = (app["targets"] as? [String])?.first else {
            throw LCodeError("The project must declare a library product (xtool convention).")
        }

        var all: [String: Target] = [:]
        for t in json["targets"] as? [[String: Any]] ?? [] {
            guard let tname = t["name"] as? String, (t["type"] as? String) == "regular" else { continue }
            let relative = t["path"] as? String ?? "Sources/\(tname)"
            var local: [String] = []
            var external: [ProductReference] = []
            for dep in t["dependencies"] as? [[String: Any]] ?? [] {
                if let byName = dep["byName"] as? [Any], let n = byName.first as? String { local.append(n) }
                if let target = dep["target"] as? [Any], let n = target.first as? String { local.append(n) }
                if let product = dep["product"] as? [Any], let n = product.first as? String {
                    external.append(ProductReference(name: n, package: product.count > 1 ? product[1] as? String : nil))
                }
            }
            let resources = (t["resources"] as? [Any])?.isEmpty == false
            all[tname] = Target(name: tname, path: root.appendingPathComponent(relative),
                                localDependencies: local, externalProducts: external, hasResources: resources)
        }

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

        let dependencies = (json["dependencies"] as? [[String: Any]] ?? []).compactMap(PackageDependency.init(dump:))
        return XtoolProject(root: root, name: name, bundleID: bundleID, appTarget: appTarget,
                            targets: ordered, manifest: manifest, dependencies: dependencies)
    }
}
