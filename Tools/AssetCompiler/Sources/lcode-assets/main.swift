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

/// Copy of the catalog adjusted for what Xcode accepts but AssetKit rejects or encodes differently: empty
/// color and icon slots, single-size icons, bitmaps missing their 2x/3x renditions.
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
    for case let url as URL in walker where url.pathExtension == "imageset" {
        try completeBitmapScales(url)
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

/// Bitmap image sets as iOS finds them in an AssetKit catalog. Measured on an iPhone (iOS 27, 3x): a name whose only
/// rendition is 1x is listed by CoreUI but never resolved (Image("name") empty), while one with 1x, 2x and 3x is.
/// So every bitmap gets 1x, 2x and 3x renditions: a missing scale is upscaled from the largest one present, which is
/// what iOS does on screen with a lower-scale image anyway. Xcode's "Single Scale" images (no `scale`) count as 1x.
func completeBitmapScales(_ set: URL) throws {
    let contents = set.appendingPathComponent("Contents.json")
    guard let data = try? Data(contentsOf: contents),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let images = json["images"] as? [[String: Any]] else { return }
    func isBitmap(_ image: [String: Any]) -> Bool {
        guard let file = image["filename"] as? String else { return false }
        return ["png", "jpg", "jpeg"].contains((file as NSString).pathExtension.lowercased())
    }
    func scaleOf(_ image: [String: Any]) -> Int { Int(((image["scale"] as? String) ?? "1x").dropLast()) ?? 1 }
    // Variants (idiom, appearance…) are completed separately: everything but scale and filename identifies one.
    func variant(_ image: [String: Any]) -> String {
        var rest = image; rest["scale"] = nil; rest["filename"] = nil
        return (try? JSONSerialization.data(withJSONObject: rest, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    var output: [[String: Any]] = []
    var groups: [String: [[String: Any]]] = [:]
    var order: [String] = []
    for image in images {
        guard isBitmap(image) else {
            if image["filename"] != nil || images.allSatisfy({ !isBitmap($0) }) { output.append(image) }
            continue
        }
        var image = image
        if image["scale"] == nil { image["scale"] = "1x" }
        let key = variant(image)
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(image)
    }
    for key in order {
        let present = groups[key]!
        output += present
        guard let best = present.max(by: { scaleOf($0) < scaleOf($1) }), let file = best["filename"] as? String else { continue }
        let bestScale = scaleOf(best)
        for scale in [1, 2, 3] where !present.contains(where: { scaleOf($0) == scale }) && scale > bestScale {
            let source = set.appendingPathComponent(file)
            let name = "lcode-\((file as NSString).deletingPathExtension)@\(scale)x.png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["ffmpeg", "-loglevel", "error", "-y", "-i", source.path,
                           "-vf", "scale=iw*\(scale)/\(bestScale):ih*\(scale)/\(bestScale):flags=lanczos", set.appendingPathComponent(name).path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { fail("ffmpeg couldn't scale \(file) (sudo apt install ffmpeg)") }
            var extra = best
            extra["filename"] = name
            extra["scale"] = "\(scale)x"
            output.append(extra)
        }
    }
    json["images"] = output
    try JSONSerialization.data(withJSONObject: json).write(to: contents)
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
