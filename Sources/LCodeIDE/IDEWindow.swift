import CAdw
import Foundation
import LCodeKit

/// Fenêtre de l'IDE : barre d'en-tête (exécuter, arrêter, appareil, thème), navigateur des fichiers,
/// éditeur Swift coloré, console. L'app tourne dans le simulateur LSim et redémarre à chaque enregistrement.
final class IDEWindow {
    let project: XtoolProject
    let runner: Runner
    let window: UnsafeMutablePointer<GtkWidget>

    private var titleWidget: UnsafeMutablePointer<GtkWidget>!
    private var runButton: UnsafeMutablePointer<GtkWidget>!
    private var stopButton: UnsafeMutablePointer<GtkWidget>!
    private var deviceDropDown: UnsafeMutablePointer<GtkWidget>!
    private var darkToggle: UnsafeMutablePointer<GtkWidget>!
    private var fileList: UnsafeMutablePointer<GtkWidget>!
    private var editor: UnsafeMutablePointer<GtkWidget>!
    private var buffer: UnsafeMutablePointer<GtkTextBuffer>!
    private var console: UnsafeMutablePointer<GtkWidget>!
    private var consoleBuffer: UnsafeMutablePointer<GtkTextBuffer>!
    private var status: UnsafeMutablePointer<GtkWidget>!

    /// Fichiers listés dans le navigateur (nil : ligne d'en-tête de cible).
    private var rows: [URL?] = []
    private var currentFile: URL?
    private var dirty = false
    private var loading = false
    private var highlightGeneration = 0
    private let dark: Bool

    static let devices: [(id: String, name: String)] = [
        ("iphone17promax", "iPhone 17 Pro Max"), ("iphone16pro", "iPhone 16 Pro"), ("iphonese", "iPhone SE"),
    ]

    init(application: UnsafeMutablePointer<AdwApplication>, project: XtoolProject, lcodeRoot: URL) {
        self.project = project
        runner = Runner(project: project, lcodeRoot: lcodeRoot)
        dark = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        window = adw_application_window_new(cast(raw(application)))
        gtk_window_set_default_size(cast(raw(window)), 1400, 900)
        buildUI()
        runner.onOutput = { [weak self] text in self?.appendConsole(text) }
        runner.onState = { [weak self] state in self?.update(state) }
        loadFileList()
        if let first = rows.compactMap({ $0 }).first(where: { $0.lastPathComponent.hasSuffix("App.swift") })
            ?? rows.compactMap({ $0 }).first {
            open(first)
        }
        gtk_window_present(cast(raw(window)))
    }

    // MARK: - Interface

    private func buildUI() {
        lcode_css("""
        .lcode-editor { font-family: "Noto Sans Mono", "DejaVu Sans Mono", monospace; font-size: 11.5pt; font-style: normal; font-weight: 400; }
        .lcode-console { font-family: "Noto Sans Mono", "DejaVu Sans Mono", monospace; font-size: 10pt; font-style: normal; font-weight: 400; }
        .lcode-sidebar row { padding: 3px 8px; }
        .lcode-section { font-weight: bold; opacity: 0.6; font-size: 9pt; padding-top: 8px; }
        """)

        // Barre d'en-tête façon Xcode.
        let header = adw_header_bar_new()!
        titleWidget = adw_window_title_new(project.name, "")
        adw_header_bar_set_title_widget(cast(raw(header)), titleWidget)

        runButton = gtk_button_new_from_icon_name("media-playback-start-symbolic")
        gtk_widget_set_tooltip_text(runButton, "Exécuter dans le simulateur (Ctrl+R)")
        connect(raw(runButton), "clicked") { [weak self] in self?.run() }
        stopButton = gtk_button_new_from_icon_name("media-playback-stop-symbolic")
        gtk_widget_set_tooltip_text(stopButton, "Arrêter (Ctrl+.)")
        gtk_widget_set_sensitive(stopButton, 0)
        connect(raw(stopButton), "clicked") { [weak self] in self?.runner.stop() }

        var names: [UnsafePointer<CChar>?] = Self.devices.map { UnsafePointer(strdup($0.name)) }
        names.append(nil)
        deviceDropDown = names.withUnsafeBufferPointer { lcode_dropdown($0.baseAddress) }
        gtk_widget_set_tooltip_text(deviceDropDown, "Appareil simulé")
        darkToggle = gtk_toggle_button_new()
        gtk_button_set_icon_name(cast(raw(darkToggle)), "weather-clear-night-symbolic")
        gtk_widget_set_tooltip_text(darkToggle, "Mode sombre dans le simulateur")

        adw_header_bar_pack_start(cast(raw(header)), runButton)
        adw_header_bar_pack_start(cast(raw(header)), stopButton)
        adw_header_bar_pack_start(cast(raw(header)), deviceDropDown)
        adw_header_bar_pack_end(cast(raw(header)), darkToggle)

        // Navigateur des fichiers.
        fileList = gtk_list_box_new()
        gtk_widget_add_css_class(fileList, "navigation-sidebar")
        gtk_widget_add_css_class(fileList, "lcode-sidebar")
        connectArg(raw(fileList), "row-activated") { [weak self] row in
            guard let self, let row else { return }
            let index = Int(gtk_list_box_row_get_index(cast(row)))
            if index >= 0, index < self.rows.count, let url = self.rows[index] { self.open(url) }
        }
        let sidebar = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(raw(sidebar)), fileList)
        gtk_widget_set_size_request(sidebar, 230, -1)

        // Éditeur.
        editor = gtk_text_view_new()
        gtk_widget_add_css_class(editor, "lcode-editor")
        gtk_text_view_set_monospace(cast(raw(editor)), 1)
        gtk_text_view_set_left_margin(cast(raw(editor)), 14)
        gtk_text_view_set_top_margin(cast(raw(editor)), 10)
        gtk_text_view_set_wrap_mode(cast(raw(editor)), GTK_WRAP_NONE)
        buffer = gtk_text_view_get_buffer(cast(raw(editor)))
        for kind in SwiftHighlighter.Kind.allCases {
            let style = SwiftHighlighter.color(kind, dark: dark)
            _ = lcode_tag(buffer, kind.rawValue, style.color, style.bold ? 1 : 0, style.italic ? 1 : 0)
        }
        connect(raw(buffer), "changed") { [weak self] in self?.textChanged() }
        let editorScroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(raw(editorScroll)), editor)
        gtk_widget_set_vexpand(editorScroll, 1)

        // Console.
        console = gtk_text_view_new()
        gtk_widget_add_css_class(console, "lcode-console")
        gtk_text_view_set_editable(cast(raw(console)), 0)
        gtk_text_view_set_monospace(cast(raw(console)), 1)
        gtk_text_view_set_left_margin(cast(raw(console)), 10)
        consoleBuffer = gtk_text_view_get_buffer(cast(raw(console)))
        let consoleScroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(raw(consoleScroll)), console)
        status = gtk_label_new("Prêt")
        gtk_widget_set_halign(status, GTK_ALIGN_START)
        gtk_widget_set_margin_start(status, 10)
        gtk_widget_add_css_class(status, "dim-label")
        let consoleBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
        gtk_box_append(cast(raw(consoleBox)), status)
        gtk_box_append(cast(raw(consoleBox)), consoleScroll)
        gtk_widget_set_vexpand(consoleScroll, 1)

        let editorPane = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_paned_set_start_child(cast(raw(editorPane)), editorScroll)
        gtk_paned_set_end_child(cast(raw(editorPane)), consoleBox)
        gtk_paned_set_position(cast(raw(editorPane)), 640)

        let main = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(cast(raw(main)), sidebar)
        gtk_paned_set_end_child(cast(raw(main)), editorPane)
        gtk_paned_set_position(cast(raw(main)), 250)
        gtk_paned_set_shrink_start_child(cast(raw(main)), 0)

        let toolbarView = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(raw(toolbarView)), header)
        adw_toolbar_view_set_content(cast(raw(toolbarView)), main)
        adw_application_window_set_content(cast(raw(window)), toolbarView)

        addAction(window, "save", accel: "<Control>s") { [weak self] in self?.save() }
        addAction(window, "run", accel: "<Control>r") { [weak self] in self?.run() }
        addAction(window, "stop", accel: "<Control>period") { [weak self] in self?.runner.stop() }
        connectReturningFalse(raw(window), "close-request") { [weak self] in self?.runner.stop() }
    }

    // MARK: - Fichiers

    private func loadFileList() {
        let fm = FileManager.default
        func add(_ label: String, url: URL?, section: Bool = false) {
            let widget = gtk_label_new(label)!
            gtk_widget_set_halign(widget, GTK_ALIGN_START)
            if section { gtk_widget_add_css_class(widget, "lcode-section") }
            gtk_list_box_append(cast(raw(fileList)), widget)
            let row = gtk_list_box_get_row_at_index(cast(raw(fileList)), Int32(rows.count))
            if section { gtk_list_box_row_set_activatable(row, 0); gtk_list_box_row_set_selectable(row, 0) }
            rows.append(url)
        }
        add(project.name.uppercased(), url: nil, section: true)
        add("Package.swift", url: project.root.appendingPathComponent("Package.swift"))
        for target in project.targets {
            add(target.name.uppercased(), url: nil, section: true)
            let files = (fm.enumerator(at: target.path, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension == "swift" }
                .sorted { $0.path < $1.path }
            for file in files {
                let relative = file.path.replacingOccurrences(of: target.path.path + "/", with: "")
                add(relative, url: file)
            }
        }
    }

    private func open(_ url: URL) {
        if dirty { save() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            appendConsole("✗ Lecture impossible : \(url.path)\n")
            return
        }
        loading = true
        gtk_text_buffer_set_text(buffer, text, -1)
        loading = false
        currentFile = url
        dirty = false
        updateTitle()
        highlight()
        if let index = rows.firstIndex(of: url) {
            gtk_list_box_select_row(cast(raw(fileList)), gtk_list_box_get_row_at_index(cast(raw(fileList)), Int32(index)))
        }
    }

    private var text: String {
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let cString = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
        defer { g_free(cString) }
        return String(cString: cString)
    }

    private func textChanged() {
        guard !loading else { return }
        if !dirty { dirty = true; updateTitle() }
        // Coloration différée : une seule passe après une rafale de frappes.
        highlightGeneration += 1
        let generation = highlightGeneration
        after(120) { [weak self] in
            guard let self, generation == self.highlightGeneration else { return }
            self.highlight()
        }
    }

    private func highlight() {
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        gtk_text_buffer_remove_all_tags(buffer, &start, &end)
        for token in SwiftHighlighter.tokens(text) {
            var a = GtkTextIter(), b = GtkTextIter()
            gtk_text_buffer_get_iter_at_offset(buffer, &a, Int32(token.start))
            gtk_text_buffer_get_iter_at_offset(buffer, &b, Int32(token.end))
            gtk_text_buffer_apply_tag_by_name(buffer, token.kind.rawValue, &a, &b)
        }
    }

    private func save() {
        guard let url = currentFile, dirty else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
            updateTitle()
            // Enregistrer relance l'app si elle tourne : on voit le changement tout de suite.
            if runner.isRunning || runner.state == .building {
                appendConsole("▸ Enregistré : relance du simulateur.\n")
                run()
            }
        } catch {
            appendConsole("✗ Enregistrement impossible : \(error)\n")
        }
    }

    private func updateTitle() {
        let name = currentFile?.lastPathComponent ?? ""
        adw_window_title_set_subtitle(cast(raw(titleWidget)), dirty ? "● " + name : name)
    }

    // MARK: - Exécution

    private func run() {
        save()
        let index = Int(gtk_drop_down_get_selected(cast(raw(deviceDropDown))))
        let device = Self.devices[min(max(index, 0), Self.devices.count - 1)].id
        let darkMode = gtk_toggle_button_get_active(cast(raw(darkToggle))) != 0
        clearConsole()
        runner.run(device: device, dark: darkMode)
    }

    private func update(_ state: Runner.State) {
        gtk_widget_set_sensitive(stopButton, state == .building || state == .running ? 1 : 0)
        let label: String
        switch state {
        case .idle: label = "Prêt"
        case .building: label = "Compilation…"
        case .running: label = "En cours d'exécution dans le simulateur"
        case .failed: label = "Échec"
        }
        gtk_label_set_text(cast(raw(status)), label)
    }

    private func clearConsole() {
        gtk_text_buffer_set_text(consoleBuffer, "", -1)
    }

    private func appendConsole(_ text: String) {
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(consoleBuffer, &end)
        gtk_text_buffer_insert(consoleBuffer, &end, text, -1)
        // Défile jusqu'en bas.
        gtk_text_buffer_get_end_iter(consoleBuffer, &end)
        let mark = gtk_text_buffer_create_mark(consoleBuffer, nil, &end, 0)
        gtk_text_view_scroll_mark_onscreen(cast(raw(console)), mark)
        gtk_text_buffer_delete_mark(consoleBuffer, mark)
    }
}
