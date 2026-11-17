import Foundation
import LCodeKit

// lcode — outil en ligne de commande de LCode.
//
//   lcode run [<projet>] [--device] [--appareil <nom>] [--sombre] [--capture <fichier.png>]
//
// Sans --device, l'app est compilée pour Linux et lancée dans le simulateur LSim.
// Avec --device, elle est compilée, signée et installée sur l'iPhone branché (xtool).

let usage = """
Usage :
  lcode new <Nom> [--bundle <id>] [--dans <dossier>]   crée un projet d'app iOS
  lcode open [<projet>]              ouvre le projet dans l'IDE LCode
  lcode preview [<projet>] [--numero <n>] [--capture <png>] [--sombre]   lance un #Preview
  lcode run [<projet>] [options]     lance un projet xtool (dossier courant par défaut)

Options :
  --device                 compile et installe sur l'iPhone branché (xtool)
  --appareil <nom>         appareil simulé : iphone17promax (défaut), iphone16pro, iphonese
  --sombre                 démarre en mode sombre
  --capture <fichier.png>  rend une capture sans ouvrir de fenêtre, puis quitte
  --touchers "x,y;x,y"     touchers simulés avant la capture
"""

/// Racine du dépôt LCode (ce fichier est dans Sources/lcode/).
let lcodeRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lcode : \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
// lcode open [<projet>] : ouvre l'IDE (exécutable lcode-ide, à côté de lcode).
if args.first == "open" {
    let ide = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("lcode-ide")
    let project = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
    let process = Process()
    process.executableURL = ide
    process.arguments = [project]
    do { try process.run() } catch { fail("impossible d'ouvrir l'IDE (\(ide.path)) : \(error)") }
    exit(0)
}
// lcode new <Nom> [--bundle <id>] [--dans <dossier>] : nouveau projet d'app iOS.
if args.first == "new" {
    guard args.count >= 2 else { fail("nom du projet manquant\n\n\(usage)") }
    let name = args[1]
    var bundle = "com.example.\(name)"
    var parent = FileManager.default.currentDirectoryPath
    var k = 2
    while k < args.count {
        if args[k] == "--bundle", k + 1 < args.count { bundle = args[k + 1]; k += 2; continue }
        if args[k] == "--dans", k + 1 < args.count { parent = args[k + 1]; k += 2; continue }
        fail("option inconnue : \(args[k])")
    }
    do {
        let root = try Templates.createProject(name: name, bundleID: bundle, in: URL(fileURLWithPath: parent))
        print("▸ Projet créé : \(root.path)")
        exit(0)
    } catch { fail("\(error)") }
}

// lcode preview [<projet>] [--numero <n>] [--capture <fichier.png>] [--sombre] : lance un #Preview.
if args.first == "preview" {
    var path = FileManager.default.currentDirectoryPath
    var number = 0
    var capture: String?
    var dark = false
    var k = 1
    while k < args.count {
        switch args[k] {
        case "--numero" where k + 1 < args.count: number = Int(args[k + 1]) ?? 0; k += 2
        case "--capture" where k + 1 < args.count: capture = args[k + 1]; k += 2
        case "--sombre": dark = true; k += 1
        default: path = args[k]; k += 1
        }
    }
    do {
        let project = try XtoolProject.load(at: URL(fileURLWithPath: path).standardizedFileURL)
        let preview = PreviewBuild(project: project, lcodeRoot: lcodeRoot)
        let entries = try preview.prepare()
        guard !entries.isEmpty else { fail("aucun #Preview dans l'app \(project.appTarget)") }
        for (n, e) in entries.enumerated() {
            print("\(n == number ? "▸" : " ") \(n) : \(e.file.lastPathComponent):\(e.preview.line)\(e.preview.name.map { " « \($0) »" } ?? "")")
        }
        let entry = entries[min(number, entries.count - 1)]
        let status = try Shell.run(["swift", "build", "--package-path", preview.directory.path, "--product", project.appTarget])
        guard status == 0 else { exit(status) }
        let bin = try Shell.capture(["swift", "build", "--package-path", preview.directory.path, "--show-bin-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var env = ["LSIM_PREVIEW_ID": entry.preview.symbol, "LSIM_DEVICE": "iphone17promax"].merging(project.simulatorEnvironment) { a, _ in a }
        if dark { env["LSIM_DARK"] = "1" }
        if let capture { env["LSIM_SCREENSHOT"] = capture; env["LSIM_SCREEN_ONLY"] = "1" }
        exit(try Shell.run([bin + "/" + project.appTarget], environment: env))
    } catch { fail("\(error)") }
}

guard args.first == "run" else { print(usage); exit(args.isEmpty || args.first == "--help" ? 0 : 1) }
args.removeFirst()

var options = SimulatorOptions()
var onDevice = false
var projectPath = FileManager.default.currentDirectoryPath
var i = 0
while i < args.count {
    let a = args[i]
    func value() -> String {
        i += 1
        guard i < args.count else { fail("valeur manquante après \(a)") }
        return args[i]
    }
    switch a {
    case "--device": onDevice = true
    case "--appareil": options.device = value()
    case "--sombre": options.dark = true
    case "--capture": options.screenshot = URL(fileURLWithPath: value()).path
    case "--touchers": options.taps = value()
    case "--help", "-h": print(usage); exit(0)
    default:
        if a.hasPrefix("-") { fail("option inconnue : \(a)\n\n\(usage)") }
        projectPath = a
    }
    i += 1
}

do {
    let root = URL(fileURLWithPath: projectPath).standardizedFileURL
    let project = try XtoolProject.load(at: root)
    print("▸ Projet \(project.name) — app : \(project.appTarget)\(project.bundleID.map { " (\($0))" } ?? "")")

    if onDevice {
        if !project.hasSDKVersionFix {
            print("""
            ⚠︎ Le Package.swift ne déclare pas la version du SDK à l'éditeur de liens : iOS affichera l'app en mode
              compatibilité (sans Liquid Glass). Ajoutez à la cible de l'app :
                linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios",
                                               "-Xlinker", "17.0", "-Xlinker", "27.3"])]
            """)
        }
        let connection = DeviceConnection.environment()
        print("▸ Compilation, signature et installation sur l'iPhone (xtool, \(connection.isEmpty ? "USB" : "USB ou Wi-Fi"))…")
        let transport = DeviceConnection.transportFlag(connection)
        print("  (\(transport == "--usb" ? "USB" : "Wi-Fi"))")
        exit(try Shell.run(["xtool", "dev", "run", transport], cwd: project.root, environment: connection))
    }

    let build = SimulatorBuild(project: project, lcodeRoot: lcodeRoot)
    build.warnings.forEach { print("⚠︎ \($0)") }
    print("▸ Compilation pour le simulateur (\(build.directory.path))…")
    let status = try build.run(options)
    exit(status)
} catch {
    fail("\(error)")
}
