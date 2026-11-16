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
