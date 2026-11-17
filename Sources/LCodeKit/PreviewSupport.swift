import Foundation

// Aperçus `#Preview` : la macro d'Apple n'existe pas sous Linux. Chaque bloc est réécrit en une fonction
// ordinaire, SUR LES MÊMES LIGNES (les erreurs du compilateur pointent donc sur les bonnes lignes du
// vrai fichier), et un point d'entrée choisit l'aperçu à lancer.

public struct PreviewInfo: Equatable, Sendable {
    /// Ligne (1 = première) du `#Preview` dans le fichier.
    public let line: Int
    public let name: String?
    /// Type généré qui porte le corps de l'aperçu (`__LSimPreview_N.body()`).
    public let symbol: String
}

public enum PreviewTransform {
    /// Réécrit `#Preview { … }` en `enum __LSimPreview_N { … static func body() -> some View { … } }`, et
    /// neutralise `@main` si demandé (l'aperçu a son propre point d'entrée). Les numéros de ligne et de
    /// colonne des autres lignes sont conservés.
    public static func transform(_ text: String, removeMain: Bool, firstIndex: Int) -> (text: String, previews: [PreviewInfo]) {
        let c = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var previews: [PreviewInfo] = []
        var i = 0
        var line = 1
        // Fermetures de corps d'aperçu à compléter (profondeur d'accolades où le corps se termine).
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
            // Commentaires et chaînes : recopiés tels quels.
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
                // `@Previewable` n'existe pas hors macro : retiré (remplacé par des espaces).
                for _ in 0..<12 { emit(" ") }
                i += 12
                continue
            }
            if ch == "#", starts(with: "Preview", at: i + 1) {
                // En-tête : #Preview, arguments facultatifs, puis l'accolade ouvrante du corps.
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

/// Reproduction d'un dossier de sources : fichiers Swift réécrits (aperçus, `@main`), autres fichiers
/// liés. Seuls les fichiers modifiés sont réécrits (compilation incrémentale).
enum SourceMirror {
    static func mirror(from source: URL, to destination: URL, removeMain: Bool, firstIndex: Int,
                       overrides: [String: String] = [:]) throws -> [(file: URL, previews: [PreviewInfo])] {
        let fm = FileManager.default
        // Ancien lien symbolique (versions précédentes) : remplacé par un vrai dossier.
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
        // Fichiers supprimés du projet : retirés de la copie.
        let existing = (fm.enumerator(at: destination, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        for file in existing where (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            let relative = String(file.path.dropFirst(destination.path.count + 1))
            if !kept.contains(relative), relative != "LSimApercu.swift", relative != "main.swift" || !removeMain {
                try? fm.removeItem(at: file)
            }
        }
        return found
    }
}

/// Paquet d'aperçu, à côté du projet (<projet>/.lcode/apercu) : l'app sans son `@main`, plus un point
/// d'entrée qui lance l'aperçu demandé par `LSIM_PREVIEW_ID`.
public struct PreviewBuild {
    public let project: XtoolProject
    public let lcodeRoot: URL
    public var directory: URL { project.root.appendingPathComponent(".lcode/apercu") }

    public init(project: XtoolProject, lcodeRoot: URL) {
        self.project = project
        self.lcodeRoot = lcodeRoot
    }

    /// Aperçus trouvés, par fichier source d'origine.
    public struct Entry {
        public let file: URL
        public let preview: PreviewInfo
    }

    /// Prépare le paquet (avec le texte non enregistré des fichiers ouverts) ; renvoie les aperçus.
    public func prepare(overrides: [URL: String] = [:]) throws -> [Entry] {
        let fm = FileManager.default
        let targetsDir = directory.appendingPathComponent("Cibles")
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
                // Les aperçus des bibliothèques ne sont pas lançables depuis l'app (types internes).
                if isApp { entries += previews.map { Entry(file: file, preview: $0) } }
            }
        }
        // Point d'entrée : lance l'aperçu choisi.
        var cases = entries.map { "case \"\($0.preview.symbol)\": _LSimPreview.run { \($0.preview.symbol).body() }" }
        cases.append("default: _LSimPreview.run { Text(\"Aucun aperçu\") }")
        let main = """
        // Généré par LCode : lance l'aperçu demandé (LSIM_PREVIEW_ID).
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
        var targets: [String] = []
        for t in project.targets {
            let deps = t.localDependencies.map { "\"\($0)\"" } + [".product(name: \"SwiftUI\", package: \"\(lcodeName)\")"]
            let kind = t.name == project.appTarget ? "executableTarget" : "target"
            targets.append("""
                    .\(kind)(
                        name: "\(t.name)",
                        dependencies: [\(deps.joined(separator: ", "))],
                        path: "Cibles/\(t.name)",
                        swiftSettings: [.swiftLanguageMode(.v5)]
                    ),
            """)
        }
        let manifest = """
        // swift-tools-version: 6.0
        // Généré par LCode pour les aperçus — ne pas modifier.
        import PackageDescription

        let package = Package(
            name: "\(project.name)Apercu",
            dependencies: [
                .package(path: "\(lcodeRoot.path)"),
            ],
            targets: [
        \(targets.joined(separator: "\n"))
            ]
        )

        """
        let url = directory.appendingPathComponent("Package.swift")
        if (try? String(contentsOf: url, encoding: .utf8)) != manifest { try manifest.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Fichier d'origine → sa copie dans le paquet d'aperçu (pour le serveur de langage).
    public func copyURL(for original: URL) -> URL? {
        let path = original.standardizedFileURL.path
        for t in project.targets where path.hasPrefix(t.path.standardizedFileURL.path + "/") {
            let relative = path.dropFirst(t.path.standardizedFileURL.path.count + 1)
            return directory.appendingPathComponent("Cibles/\(t.name)/\(relative)")
        }
        return nil
    }

    /// Le fichier appartient-il à la cible de l'app (dont la copie perd son `@main`) ?
    public func isAppFile(_ url: URL) -> Bool {
        guard let app = project.targets.first(where: { $0.name == project.appTarget }) else { return false }
        return url.standardizedFileURL.path.hasPrefix(app.path.standardizedFileURL.path + "/")
    }

    /// Chemin d'un fichier de la copie → fichier d'origine (pour les erreurs du compilateur).
    public func originalPath(for copyPath: String) -> String {
        for t in project.targets {
            let prefix = directory.appendingPathComponent("Cibles/\(t.name)").path + "/"
            if copyPath.hasPrefix(prefix) { return t.path.path + "/" + copyPath.dropFirst(prefix.count) }
        }
        return copyPath
    }
}
