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

    /// Asset catalogs SwiftPM would hand to Apple's actool on an iPhone build (which fails on Linux): those
    /// not listed in an `exclude:`. Paths relative to their target, e.g. `Resources/Assets.xcassets`.
    public var assetCatalogsBlockingDeviceBuild: [String] {
        var found: [String] = []
        for t in targets {
            guard let walker = FileManager.default.enumerator(at: t.path, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "xcassets" {
                walker.skipDescendants()
                let relative = String(url.path.dropFirst(t.path.path.count + 1))
                if !manifest.contains("\"\(relative)\"") { found.append(relative) }
            }
        }
        return found
    }

    /// Message explaining how to unblock an iPhone build that would compile asset catalogs.
    public static func assetCatalogAdvice(_ catalogs: [String]) -> String {
        """
        SwiftPM can't compile asset catalogs on Linux (Apple's actool only runs on macOS): LCode compiles them \
        itself. Exclude them from SwiftPM in Package.swift, next to `resources:`:
            exclude: [\(catalogs.map { "\"\($0)\"" }.joined(separator: ", "))],
        """
    }

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

/// iPhone builds of apps with an asset catalog. SwiftPM would hand the catalog to Apple's actool (macOS only),
/// so the catalog is excluded from SwiftPM and compiled into the built app by `lcode-assets` (AssetKit, in
/// Tools/AssetCompiler) before xtool signs and installs it.
public enum DeviceBuild {
    /// The app target's asset catalog, if any.
    public static func assetCatalog(of project: XtoolProject) -> URL? {
        guard let target = project.targets.first(where: { $0.name == project.appTarget }),
              let walker = FileManager.default.enumerator(at: target.path, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.pathExtension == "xcassets" { return url }
        return nil
    }

    public static func tool(lcodeRoot: URL) -> URL {
        lcodeRoot.appendingPathComponent("Tools/AssetCompiler/.build/release/lcode-assets")
    }

    /// iOS deployment target declared in Package.swift (`.iOS(.v17)` → "17.0").
    static func deploymentTarget(_ manifest: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\.iOS\(\.v(\d+)(?:_(\d+))?\)"#),
              let m = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)),
              let major = Range(m.range(at: 1), in: manifest).map({ String(manifest[$0]) }) else { return "17.0" }
        let minor = Range(m.range(at: 2), in: manifest).map { String(manifest[$0]) } ?? "0"
        return "\(major).\(minor)"
    }

    /// Shell script: build with xtool, compile the catalog into the app, then sign and install it.
    /// `transport` is `--usb` or `--network`; `udid` picks the device (nil: xtool chooses).
    public static func script(project: XtoolProject, catalog: URL, lcodeRoot: URL, udid: String?, transport: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let tool = tool(lcodeRoot: lcodeRoot)
        let package = lcodeRoot.appendingPathComponent("Tools/AssetCompiler")
        let device = (udid.map { "--udid \(q($0)) " } ?? "") + transport
        return """
        set -e
        cd \(q(project.root.path))
        if [ ! -x \(q(tool.path)) ]; then
          echo "▸ Building the asset catalog compiler (first time only)…"
          swift build -c release --package-path \(q(package.path)) 2>&1 | grep -E "error|Fetching|Build complete" || true
          [ -x \(q(tool.path)) ] || { echo "✗ Couldn't build lcode-assets."; exit 1; }
        fi
        xtool dev build
        app=$(ls -td xtool/*.app | head -1)
        \(q(tool.path)) \(q(catalog.path)) "$app" --deployment-target \(deploymentTarget(project.manifest))
        echo "▸ Signing and installing $(basename "$app")…"
        xtool install \(device) "$app"
        """
    }
}
