import Foundation

// `#Preview` support: Apple's macro does not exist on Linux. Each block is rewritten as a plain function
// ON THE SAME LINES (so compiler errors point at the real file's lines), and an entry point picks the preview.

public struct PreviewInfo: Equatable, Sendable {
    /// 1-based line of the `#Preview`.
    public let line: Int
    public let name: String?
    /// Generated type holding the preview body (`__LSimPreview_N.body()`).
    public let symbol: String
}

public enum PreviewTransform {
    /// Rewrites `#Preview { … }` as `enum __LSimPreview_N { … static func body() -> some View { … } }` and blanks
    /// `@main` if asked (previews have their own entry point). Line and column numbers are preserved.
    public static func transform(_ text: String, removeMain: Bool, firstIndex: Int) -> (text: String, previews: [PreviewInfo]) {
        let c = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var previews: [PreviewInfo] = []
        var i = 0
        var line = 1
        // Brace depths at which a preview body ends.
        var depth = 0
        var closeAt: [Int] = []

        func starts(with word: String, at index: Int) -> Bool {
            let w = Array(word.unicodeScalars)
            guard index + w.count <= c.count else { return false }
            for k in 0..<w.count where c[index + k] != w[k] { return false }
            if index + w.count < c.count, c[index + w.count].properties.isAlphabetic || c[index + w.count] == "_" { return false }
            return true
        }
        func emit(_ s: Unicode.Scalar) {
            out.append(s)
            if s == "\n" { line += 1 }
        }

        while i < c.count {
            let ch = c[i]
            // Comments and strings are copied verbatim.
            if ch == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, c[i] != "\n" { emit(c[i]); i += 1 }
                continue
            }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                var d = 0
                while i < c.count {
                    if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" { d += 1; emit(c[i]); emit(c[i + 1]); i += 2; continue }
                    if c[i] == "*", i + 1 < c.count, c[i + 1] == "/" { d -= 1; emit(c[i]); emit(c[i + 1]); i += 2; if d == 0 { break }; continue }
                    emit(c[i]); i += 1
                }
                continue
            }
            if ch == "\"" {
                let multiline = i + 2 < c.count && c[i + 1] == "\"" && c[i + 2] == "\""
                let open = multiline ? 3 : 1
                for _ in 0..<open { emit(c[i]); i += 1 }
                while i < c.count {
                    if c[i] == "\\", i + 1 < c.count { emit(c[i]); emit(c[i + 1]); i += 2; continue }
                    if multiline, c[i] == "\"", i + 2 < c.count, c[i + 1] == "\"", c[i + 2] == "\"" {
                        emit(c[i]); emit(c[i + 1]); emit(c[i + 2]); i += 3; break
                    }
                    if !multiline, c[i] == "\"" || c[i] == "\n" { emit(c[i]); i += 1; break }
                    emit(c[i]); i += 1
                }
                continue
            }
            if removeMain, ch == "@", starts(with: "main", at: i + 1) {
                for _ in 0..<5 { emit(" ") }
                i += 5
                continue
            }
            if ch == "@", starts(with: "Previewable", at: i + 1) {
                // `@Previewable` only exists inside the macro: blanked out.
                for _ in 0..<12 { emit(" ") }
                i += 12
                continue
            }
            if ch == "#", starts(with: "Preview", at: i + 1) {
                // Header: #Preview, optional arguments, then the body's opening brace.
                let headerLine = line
                var j = i + 8
                var name: String?
                var newlines = 0
                while j < c.count, c[j] == " " || c[j] == "\t" || c[j] == "\n" { if c[j] == "\n" { newlines += 1 }; j += 1 }
                if j < c.count, c[j] == "(" {
                    var d = 0
                    let argStart = j
                    while j < c.count {
                        if c[j] == "\n" { newlines += 1 }
                        if c[j] == "(" { d += 1 }
                        if c[j] == ")" { d -= 1; if d == 0 { j += 1; break } }
                        j += 1
                    }
                    let args = String(String.UnicodeScalarView(c[argStart..<j]))
                    if let range = args.range(of: #""([^"]*)""#, options: .regularExpression) {
                        name = String(args[range].dropFirst().dropLast())
                    }
                    while j < c.count, c[j] == " " || c[j] == "\t" || c[j] == "\n" { if c[j] == "\n" { newlines += 1 }; j += 1 }
                }
                guard j < c.count, c[j] == "{" else { emit(ch); i += 1; continue }
                let symbol = "__LSimPreview_\(firstIndex + previews.count)"
                previews.append(PreviewInfo(line: headerLine, name: name, symbol: symbol))
                for s in "enum \(symbol) { @ViewBuilder static func body() -> some View {".unicodeScalars { out.append(s) }
                for _ in 0..<newlines { emit("\n") }
                i = j + 1
                depth += 1
                closeAt.append(depth)
                continue
            }
            if ch == "{" { depth += 1 }
            if ch == "}" {
                if let last = closeAt.last, last == depth {
                    closeAt.removeLast()
                    for s in "} }".unicodeScalars { out.append(s) }
                    depth -= 1
                    i += 1
                    continue
                }
                depth -= 1
            }
            emit(ch)
            i += 1
        }
        return (String(out), previews)
    }
}

/// Mirrors a source folder: Swift files are rewritten (previews, `@main`), others symlinked.
/// Only changed files are rewritten, to keep builds incremental.
enum SourceMirror {
    static func mirror(from source: URL, to destination: URL, removeMain: Bool, firstIndex: Int,
                       overrides: [String: String] = [:]) throws -> [(file: URL, previews: [PreviewInfo])] {
        let fm = FileManager.default
        // Older versions used a symlink here: replace it with a real folder.
        if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var found: [(URL, [PreviewInfo])] = []
        var index = firstIndex
        var kept = Set<String>()
        let files = (fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey])?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .sorted { $0.path < $1.path }
        for file in files {
            let relative = String(file.path.dropFirst(source.path.count + 1))
            kept.insert(relative)
            let target = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.pathExtension == "swift" {
                let text = overrides[file.standardizedFileURL.path] ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let result = PreviewTransform.transform(text, removeMain: removeMain, firstIndex: index)
                index += result.previews.count
                found.append((file, result.previews))
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { try fm.removeItem(at: target) }
                if (try? String(contentsOf: target, encoding: .utf8)) != result.text {
                    try result.text.write(to: target, atomically: true, encoding: .utf8)
                }
            } else if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != file.path {
                try? fm.removeItem(at: target)
                try fm.createSymbolicLink(at: target, withDestinationURL: file)
            }
        }
        // Drop files deleted from the project.
        let existing = (fm.enumerator(at: destination, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        for file in existing where (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            let relative = String(file.path.dropFirst(destination.path.count + 1))
            if !kept.contains(relative), relative != "LSimPreview.swift", relative != "main.swift" || !removeMain {
                try? fm.removeItem(at: file)
            }
        }
        return found
    }
}

/// Preview package (<project>/.lcode/preview): the app without its `@main`, plus an entry point that runs the
/// preview named by `LSIM_PREVIEW_ID`.
public struct PreviewBuild {
    public let project: XtoolProject
    public let lcodeRoot: URL
    public var directory: URL { project.root.appendingPathComponent(".lcode/preview") }

    public init(project: XtoolProject, lcodeRoot: URL) {
        self.project = project
        self.lcodeRoot = lcodeRoot
    }

    public struct Entry {
        public let file: URL
        public let preview: PreviewInfo
    }

    /// Prepares the package (with the unsaved text of open files); returns the previews.
    public func prepare(overrides: [URL: String] = [:]) throws -> [Entry] {
        let fm = FileManager.default
        let targetsDir = directory.appendingPathComponent("Targets")
        try fm.createDirectory(at: targetsDir, withIntermediateDirectories: true)
        let texts = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.standardizedFileURL.path, $0.value) })
        var entries: [Entry] = []
        var index = 0
        for t in project.targets {
            let isApp = t.name == project.appTarget
            let found = try SourceMirror.mirror(from: t.path, to: targetsDir.appendingPathComponent(t.name),
                                                removeMain: isApp, firstIndex: index, overrides: texts)
            for (file, previews) in found {
                index += previews.count
                // Library previews cannot be launched from the app (internal types).
                if isApp { entries += previews.map { Entry(file: file, preview: $0) } }
            }
        }
        var cases = entries.map { "case \"\($0.preview.symbol)\": _LSimPreview.run { \($0.preview.symbol).body() }" }
        cases.append("default: _LSimPreview.run { Text(\"\(tr("No Preview"))\") }")
        let main = """
        // Generated by LCode: runs the requested preview (LSIM_PREVIEW_ID).
        import SwiftUI

        switch ProcessInfo.processInfo.environment["LSIM_PREVIEW_ID"] ?? "" {
        \(cases.joined(separator: "\n"))
        }

        """
        let mainURL = targetsDir.appendingPathComponent(project.appTarget).appendingPathComponent("main.swift")
        if (try? String(contentsOf: mainURL, encoding: .utf8)) != main { try main.write(to: mainURL, atomically: true, encoding: .utf8) }
        try writeManifest()
        return entries
    }

    private func writeManifest() throws {
        let lcodeName = lcodeRoot.lastPathComponent
        let packages = try PackageOverlay(project: project, lcodeRoot: lcodeRoot).dependencyDeclarations()
        var targets: [String] = []
        for t in project.targets {
            let deps = t.localDependencies.map { "\"\($0)\"" } + t.externalProducts.map(\.declaration)
                + PackageOverlay.lsimModules.map { ".product(name: \"\($0)\", package: \"\(lcodeName)\")" }
            let kind = t.name == project.appTarget ? "executableTarget" : "target"
            targets.append("""
                    .\(kind)(
                        name: "\(t.name)",
                        dependencies: [\(deps.joined(separator: ", "))],
                        path: "Targets/\(t.name)",
                        swiftSettings: [.swiftLanguageMode(.v5)]
                    ),
            """)
        }
        let manifest = """
        // swift-tools-version: 6.0
        // Generated by LCode for previews — do not edit.
        import PackageDescription

        let package = Package(
            name: "\(project.name)Preview",
            dependencies: [
                .package(path: "\(lcodeRoot.path)"),
        \(packages.map { "        " + $0 + "," }.joined(separator: "\n"))
            ],
            targets: [
        \(targets.joined(separator: "\n"))
            ]
        )

        """
        let url = directory.appendingPathComponent("Package.swift")
        if (try? String(contentsOf: url, encoding: .utf8)) != manifest { try manifest.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Original file → its copy in the preview package (for the language server).
    public func copyURL(for original: URL) -> URL? {
        let path = original.standardizedFileURL.path
        for t in project.targets where path.hasPrefix(t.path.standardizedFileURL.path + "/") {
            let relative = path.dropFirst(t.path.standardizedFileURL.path.count + 1)
            return directory.appendingPathComponent("Targets/\(t.name)/\(relative)")
        }
        return nil
    }

    /// Whether the file belongs to the app target (whose copy loses its `@main`).
    public func isAppFile(_ url: URL) -> Bool {
        guard let app = project.targets.first(where: { $0.name == project.appTarget }) else { return false }
        return url.standardizedFileURL.path.hasPrefix(app.path.standardizedFileURL.path + "/")
    }

    /// Maps a mirrored file path back to the original (for compiler errors).
    public func originalPath(for copyPath: String) -> String {
        for t in project.targets {
            let prefix = directory.appendingPathComponent("Targets/\(t.name)").path + "/"
            if copyPath.hasPrefix(prefix) { return t.path.path + "/" + copyPath.dropFirst(prefix.count) }
        }
        return copyPath
    }
}
