import CAdw
import CSource
import Foundation

import LCodeKit

// A dying child process (preview, app, language server) must not take the IDE down.
signal(SIGPIPE, SIG_IGN)

// lcode-ide [<project>] — without a project, shows the welcome window.

/// Root of the LCode repository (this file is in Sources/LCodeIDE/).
let lcodeRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

Shell.sanitizeEnvironment()
Settings.shared.applyLanguage()

let application = adw_application_new("fr.lcode.ide", G_APPLICATION_NON_UNIQUE)!
connect(raw(application), "activate") {
    gtk_source_init()
    // Xcode color schemes shipped with LCode.
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
