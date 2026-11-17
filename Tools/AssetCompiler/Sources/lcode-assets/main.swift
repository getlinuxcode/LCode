import AssetKit
import Foundation

// lcode-assets <catalog.xcassets> <App.app> [--deployment-target 17.0]
//
// Compiles an asset catalog into the app bundle the way Xcode's actool does: Assets.car, the app icon's
// loose PNGs and Info.plist keys, and NSAccentColorName when the catalog has an AccentColor color set.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lcode-assets: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var deploymentTarget = "17.0"
if let i = args.firstIndex(of: "--deployment-target"), i + 1 < args.count {
    deploymentTarget = args[i + 1]
    args.removeSubrange(i...i + 1)
}
guard args.count == 2 else { fail("usage: lcode-assets <catalog.xcassets> <App.app> [--deployment-target <version>]") }
let catalog = URL(fileURLWithPath: args[0]), app = URL(fileURLWithPath: args[1])
let fm = FileManager.default
guard fm.fileExists(atPath: catalog.path) else { fail("no asset catalog at \(catalog.path)") }
let infoURL = app.appendingPathComponent("Info.plist")
guard fm.fileExists(atPath: infoURL.path) else { fail("no Info.plist in \(app.path)") }

/// Copy of the catalog without what Xcode accepts but AssetKit rejects: color entries with no value (the
/// AccentColor of Xcode's and LCode's templates); a color set left empty is dropped.
func sanitizedCopy(of catalog: URL) throws -> URL {
    let copy = fm.temporaryDirectory.appendingPathComponent("lcode-assets-\(getpid())").appendingPathComponent(catalog.lastPathComponent)
    try? fm.removeItem(at: copy.deletingLastPathComponent())
    try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: catalog, to: copy)
    guard let walker = fm.enumerator(at: copy, includingPropertiesForKeys: nil) else { return copy }
    for case let url as URL in walker where url.pathExtension == "appiconset" {
        try expandSingleSizeIcon(url)
    }
    guard let walker = fm.enumerator(at: copy, includingPropertiesForKeys: nil) else { return copy }
    for case let url as URL in walker where url.pathExtension == "colorset" {
        let contents = url.appendingPathComponent("Contents.json")
        guard let data = try? Data(contentsOf: contents),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let colors = json["colors"] as? [[String: Any]] else { continue }
        let kept = colors.filter { $0["color"] != nil }
        if kept.isEmpty { try fm.removeItem(at: url); continue }
        json["colors"] = kept
        try JSONSerialization.data(withJSONObject: json).write(to: contents)
    }
    return copy
}

/// Icon sets as AssetKit expects them: empty slots dropped, and Xcode's single-size icon (one 1024 px image,
/// no scale) expanded into the per-size iPhone entries, resized with ffmpeg.
func expandSingleSizeIcon(_ set: URL) throws {
    let contents = set.appendingPathComponent("Contents.json")
    guard let data = try? Data(contentsOf: contents),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let all = json["images"] as? [[String: Any]] else { return }
    // Empty slots (no file yet, as in a new project) are dropped; with nothing left, the app has no icon.
    let images = all.filter { ($0["filename"] as? String)?.isEmpty == false }
    if images.isEmpty { try fm.removeItem(at: set); return }
    guard let single = images.first(where: { $0["scale"] == nil }), let file = single["filename"] as? String else {
        var updated = json
        updated["images"] = images
        try JSONSerialization.data(withJSONObject: updated).write(to: contents)
        return
    }
    let source = set.appendingPathComponent(file)
    var entries: [[String: Any]] = [["idiom": "ios-marketing", "size": "1024x1024", "scale": "1x", "filename": file]]
    for points in [20, 29, 40, 60] {
        for scale in [2, 3] {
            let name = "icon-\(points)@\(scale)x.png"
            let px = points * scale
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["ffmpeg", "-loglevel", "error", "-y", "-i", source.path, "-vf", "scale=\(px):\(px):flags=lanczos",
                           set.appendingPathComponent(name).path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { fail("ffmpeg couldn't resize the app icon (sudo apt install ffmpeg)") }
            entries.append(["idiom": "iphone", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
    var updated = json
    updated["images"] = entries
    try JSONSerialization.data(withJSONObject: updated).write(to: contents)
}

let source: URL
let result: CompileResult
do {
    source = try sanitizedCopy(of: catalog)
    result = try await XCAssetCompiler(deploymentTarget: deploymentTarget).compile(catalog: source)
} catch {
    fail("couldn't compile \(catalog.lastPathComponent): \(error)")
}
defer { try? fm.removeItem(at: source.deletingLastPathComponent()) }

do {
    try result.carData.write(to: app.appendingPathComponent("Assets.car"))
    var format = PropertyListSerialization.PropertyListFormat.xml
    let data = try Data(contentsOf: infoURL)
    guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
        fail("unreadable Info.plist")
    }
    var notes: [String] = []
    if let icon = result.appIconBundle {
        for file in icon.looseFiles { try file.data.write(to: app.appendingPathComponent(file.name)) }
        for (key, value) in icon.infoPlistAdditions { info[key] = value }
        notes.append("app icon")
    }
    if fm.fileExists(atPath: source.appendingPathComponent("AccentColor.colorset").path), info["NSAccentColorName"] == nil {
        info["NSAccentColorName"] = "AccentColor"
        notes.append("accent color")
    }
    try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0).write(to: infoURL)
    let size = ByteCountFormatter.string(fromByteCount: Int64(result.carData.count), countStyle: .file)
    print("▸ Asset catalog compiled: Assets.car (\(size))" + (notes.isEmpty ? "" : ", " + notes.joined(separator: ", ")) + ".")
} catch {
    fail("couldn't write into \(app.lastPathComponent): \(error)")
}
