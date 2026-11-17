import Foundation

/// External package product used by a target (`.product(name:package:)`).
public struct ProductReference: Hashable, Sendable {
    public let name: String
    /// Identity (or name) of the providing package.
    public let package: String?

    public var declaration: String {
        package.map { ".product(name: \"\(name)\", package: \"\($0)\")" } ?? "\"\(name)\""
    }
}

/// A package dependency (`.package(url:…)` or `.package(path:)`), read from `swift package dump-package`.
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

    /// Declaration for a generated manifest.
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

/// The project's packages for the simulator: pure Swift packages are used as is; those importing SwiftUI
/// (or another framework LSim recreates) are copied to `.lcode/packages/` and their manifest is patched so the
/// import resolves to LSim's module. Versions follow the project's Package.resolved.
public struct PackageOverlay {
    public let project: XtoolProject
    public let lcodeRoot: URL
    public var directory: URL { project.root.appendingPathComponent(".lcode/packages") }
    private var resolution: URL { directory.appendingPathComponent(".resolution") }

    public init(project: XtoolProject, lcodeRoot: URL) {
        self.project = project
        self.lcodeRoot = lcodeRoot
    }

    /// Dependency declarations for the simulator or preview package (empty without dependencies).
    /// Resolution (network) only reruns when the dependencies or Package.resolved change.
    public func dependencyDeclarations() throws -> [String] {
        guard !project.dependencies.isEmpty else { return [] }
        let fm = FileManager.default
        let resolvedURL = project.root.appendingPathComponent("Package.resolved")
        let resolved = (try? String(contentsOf: resolvedURL, encoding: .utf8)) ?? ""
        let key = (project.dependencies.map(\.declaration) + [resolved, lcodeRoot.path, "v2:" + Self.lsimModules.joined(separator: ",")]).joined(separator: "\n")
        let stateURL = directory.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           state["key"] as? String == key, let lines = state["declarations"] as? [String] {
            return lines
        }

        // 1. Separate resolution (same versions as the project) to get the package sources.
        try fm.createDirectory(at: resolution, withIntermediateDirectories: true)
        let manifest = """
        // swift-tools-version: 5.9
        // Generated by LCode: resolves the project's packages for the simulator.
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

        // 2. Packages (direct or transitive) importing a framework LSim recreates: copied and patched.
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

        // 3. Patched copies replace the originals (same identity); others keep their declaration.
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

    /// Packages copied and patched for LSim during the last resolution.
    public var patchedPackages: [String] {
        let stateURL = directory.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return state["copies"] as? [String] ?? []
    }

    /// Apple frameworks LCode recreates for the simulator (one product of the LCode package each).
    public static let lsimModules = ["SwiftUI", "Combine", "CoreMedia", "CoreVideo", "AVFoundation", "AVKit"]

    /// Whether a package source (excluding tests and examples) imports a framework LSim recreates.
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

    /// Appends to the copied manifest a dependency on LCode's modules for every target (the manifest is Swift,
    /// so it mutates the `package` object after its creation).
    private func patchManifest(in copy: URL) throws {
        let fm = FileManager.default
        // Remove `Package@swift-x.swift` variants so the patched manifest is the one used.
        for name in (try? fm.contentsOfDirectory(atPath: copy.path)) ?? [] where name.hasPrefix("Package@swift") {
            try? fm.removeItem(at: copy.appendingPathComponent(name))
        }
        let url = copy.appendingPathComponent("Package.swift")
        var manifest = try String(contentsOf: url, encoding: .utf8)
        let tools = manifest.split(separator: "\n").first.flatMap { line -> Double? in
            guard let r = line.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return nil }
            return Double(line[r])
        } ?? 5.0
        // Swift 5 mode (LSimUI is not fully concurrency-annotated yet); the setting needs tools 6.
        let languageMode = tools >= 6 ? "\n    target.swiftSettings = (target.swiftSettings ?? []) + [.swiftLanguageMode(.v5)]" : ""
        manifest += """


        // Added by LCode: in the simulator, Apple frameworks (SwiftUI, Combine…) come from LSim.
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

/// Package management (like Xcode's "Add Package Dependencies…"): SwiftPM itself edits the project's
/// Package.swift (`swift package add-dependency`, `add-target-dependency`).
public enum PackageManager {
    /// SwiftPM identity of a remote package: last URL component, without `.git`, lowercased.
    public static func identity(of url: String) -> String {
        var last = url.split(separator: "/").last.map(String.init) ?? url
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last.lowercased()
    }

    /// Latest release (highest semver tag) of a git repository.
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

    /// Adds the dependency (from `version`), resolves, and returns the package's library products.
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

    /// Makes a package product available to the target.
    public static func addProduct(_ product: String, package: String, target: String, root: URL) throws {
        try Shell.capture(["swift", "package", "--package-path", root.path, "add-target-dependency", product, target,
                           "--package", package])
    }

    /// Removes a package's declaration and its products from the manifest.
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
