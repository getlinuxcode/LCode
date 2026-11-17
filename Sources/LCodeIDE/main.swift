import CAdw
import CSource
import Foundation

import LCodeKit

// Un processus fils (aperçu, app, serveur de langage) qui meurt ne doit pas faire tomber l'IDE.
signal(SIGPIPE, SIG_IGN)

// lcode-ide [<projet>] — l'IDE LCode. Sans projet : fenêtre d'accueil (récents, créer, ouvrir).

/// Racine du dépôt LCode (ce fichier est dans Sources/LCodeIDE/).
let lcodeRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let application = adw_application_new("fr.lcode.ide", G_APPLICATION_NON_UNIQUE)!
connect(raw(application), "activate") {
    gtk_source_init()
    // Thèmes de couleurs Xcode, livrés avec LCode.
    gtk_source_style_scheme_manager_append_search_path(gtk_source_style_scheme_manager_get_default(),
                                                       lcodeRoot.appendingPathComponent("Sources/LCodeIDE/Styles").path)
    Settings.shared.applyAppearance()
    lcode_css("""
    .lcode-editor { font-family: "Noto Sans Mono", "DejaVu Sans Mono", monospace; font-size: 11pt; font-style: normal; }
    .lcode-console { font-family: "Noto Sans Mono", "DejaVu Sans Mono", monospace; font-size: 9.5pt; font-style: normal; }
    .lcode-section { font-weight: bold; opacity: 0.6; font-size: 9pt; }
    .lcode-preview { background: alpha(@window_fg_color, 0.04); }
    .lcode-error-banner { background: alpha(@error_color, 0.12); border-radius: 8px; padding: 8px; }
    """)
    if let path = CommandLine.arguments.dropFirst().first {
        App.shared.openProject(URL(fileURLWithPath: path).standardizedFileURL)
    } else {
        App.shared.showWelcome()
    }
}
exit(g_application_run(cast(raw(application)), 0, nil))
