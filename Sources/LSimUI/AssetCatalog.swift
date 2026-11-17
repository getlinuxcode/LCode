import Foundation

/// The app's asset catalog (Assets.xcassets): named images and colors. Catalog paths come from
/// `LSIM_ASSETS` (colon-separated). Dark appearances and 1x/2x/3x scales are handled as on iOS.
public final class AssetCatalog: @unchecked Sendable {
    public static let shared = AssetCatalog(paths: (ProcessInfo.processInfo.environment["LSIM_ASSETS"] ?? "")
        .split(separator: ":").map { URL(fileURLWithPath: String($0)) })

    /// Image file: path and scale (pixels per point).
    public struct ImageFile: Equatable, Sendable {
        public let path: String
        public let scale: Double
    }

    struct ImageSet {
        var light: ImageFile?
        var dark: ImageFile?
    }

    private let catalogs: [URL]
    private var colors: [String: Color?] = [:]
    private var images: [String: ImageSet?] = [:]
    private var warned = Set<String>()
    private let lock = NSLock()

    public init(paths: [URL]) {
        catalogs = paths
    }

    // MARK: - Colors

    /// `name.colorset` color (nil if missing).
    public func color(_ name: String) -> Color? {
        lock.lock(); defer { lock.unlock() }
        if let cached = colors[name] { return cached }
        let c = loadColor(name)
        colors[name] = c
        return c
    }

    private func loadColor(_ name: String) -> Color? {
        guard let json = contents(of: "\(name).colorset"), let entries = json["colors"] as? [[String: Any]] else { return nil }
        var light: RGBA?, dark: RGBA?
        for entry in entries {
            guard let rgba = Self.rgba(entry["color"] as? [String: Any]) else { continue }
            if Self.isDark(entry) { dark = rgba } else if Self.isAppearanceVariant(entry) == false { light = rgba }
        }
        guard let l = light ?? dark else { return nil }
        return Color(light: l, dark: dark ?? l)
    }

    /// Xcode components: 0…1, 0…255, or hex "0xFF"; srgb / display-p3 / gray color spaces.
    static func rgba(_ color: [String: Any]?) -> RGBA? {
        guard let comps = color?["components"] as? [String: Any] else {
            // Named system color ("systemBlueColor"): not resolved here, left to the caller.
            return nil
        }
        func value(_ key: String) -> Double? {
            guard let v = comps[key] else { return nil }
            let s = "\(v)".trimmingCharacters(in: .whitespaces)
            if s.lowercased().hasPrefix("0x") { return Double(Int(s.dropFirst(2), radix: 16) ?? 0) / 255 }
            guard let d = Double(s) else { return nil }
            // "255" or "128": 0…255 scale; "1.000": 0…1.
            return (s.contains(".") || d <= 1) ? d : d / 255
        }
        let alpha = value("alpha") ?? 1
        if let white = value("white") { return RGBA(white, white, white, alpha) }
        guard let r = value("red"), let g = value("green"), let b = value("blue") else { return nil }
        return RGBA(r, g, b, alpha)
    }

    private static func appearance(_ entry: [String: Any]) -> [[String: Any]] {
        (entry["appearances"] as? [[String: Any]]) ?? []
    }

    static func isDark(_ entry: [String: Any]) -> Bool {
        appearance(entry).contains { ($0["appearance"] as? String) == "luminosity" && ($0["value"] as? String) == "dark" }
    }

    /// Any variant other than the default light one (dark, high contrast…).
    static func isAppearanceVariant(_ entry: [String: Any]) -> Bool {
        !appearance(entry).isEmpty
    }

    // MARK: - Images

    /// File to use for `name.imageset` in an appearance (nil if missing).
    public func image(_ name: String, scheme: ColorScheme, displayScale: Double = 3) -> ImageFile? {
        lock.lock(); defer { lock.unlock() }
        if images[name] == nil { images[name] = .some(loadImage(name, displayScale: displayScale)) }
        guard let set = images[name] ?? nil else { return nil }
        return scheme == .dark ? (set.dark ?? set.light) : (set.light ?? set.dark)
    }

    private func loadImage(_ name: String, displayScale: Double) -> ImageSet? {
        for catalog in catalogs {
            guard let folder = find("\(name).imageset", in: catalog),
                  let json = Self.json(folder.appendingPathComponent("Contents.json")),
                  let entries = json["images"] as? [[String: Any]] else { continue }
            // File closest to the screen scale (3x on iPhone), per appearance.
            func best(_ dark: Bool) -> ImageFile? {
                let candidates: [ImageFile] = entries.compactMap { entry in
                    guard Self.isDark(entry) == dark, dark || !Self.isAppearanceVariant(entry),
                          let file = entry["filename"] as? String else { return nil }
                    let idiom = entry["idiom"] as? String ?? "universal"
                    guard ["universal", "iphone"].contains(idiom) else { return nil }
                    let scale = Double((entry["scale"] as? String)?.dropLast() ?? "1") ?? 1
                    return ImageFile(path: folder.appendingPathComponent(file).path, scale: scale)
                }
                return candidates.min { a, b in
                    let da = abs(a.scale - displayScale), db = abs(b.scale - displayScale)
                    return da != db ? da < db : a.scale > b.scale
                }
            }
            let set = ImageSet(light: best(false), dark: best(true))
            if set.light != nil || set.dark != nil { return set }
        }
        return nil
    }

    // MARK: - Files

    private func contents(of setName: String) -> [String: Any]? {
        for catalog in catalogs {
            if let folder = find(setName, in: catalog), let json = Self.json(folder.appendingPathComponent("Contents.json")) {
                return json
            }
        }
        return nil
    }

    /// Finds a set in the catalog, including subfolders (Xcode groups).
    private func find(_ setName: String, in catalog: URL) -> URL? {
        let direct = catalog.appendingPathComponent(setName)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let walker = FileManager.default.enumerator(at: catalog, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == setName { return url }
        return nil
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Reports a missing asset once (like Xcode's console).
    func warnMissing(_ kind: String, _ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard warned.insert(kind + name).inserted else { return }
        FileHandle.standardError.write(Data("No \(kind) named '\(name)' found in asset catalog\n".utf8))
    }
}
