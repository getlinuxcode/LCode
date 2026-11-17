import CAdw
import Foundation
import LCodeKit

// lcode-ide [<projet>] — l'IDE LCode (dossier courant par défaut).

/// Racine du dépôt LCode (ce fichier est dans Sources/LCodeIDE/).
let lcodeRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let projectPath = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL

let project: XtoolProject
do {
    project = try XtoolProject.load(at: projectURL)
} catch {
    FileHandle.standardError.write(Data("lcode-ide : \(error)\n".utf8))
    exit(1)
}

nonisolated(unsafe) var ideWindow: IDEWindow?
let application = adw_application_new("fr.lcode.ide", G_APPLICATION_NON_UNIQUE)!
connect(raw(application), "activate") {
    ideWindow = IDEWindow(application: application, project: project, lcodeRoot: lcodeRoot)
}
exit(g_application_run(cast(raw(application)), 0, nil))
