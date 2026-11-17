import CAdw
import CSource
import Foundation
import LCodeKit

/// Fenêtre d'un projet (comme celle d'Xcode) : navigateur à gauche, éditeur à onglets au centre, aperçu
/// à droite, journal en bas (compilation, problèmes, sortie de l'app, appareil). Barre : exécuter, arrêter,
/// destination (simulateurs et iPhone détectés en USB ou Wi-Fi), menu.
final class ProjectWindow {
    private(set) var project: XtoolProject
    let window: UnsafeMutablePointer<GtkWidget>
    private let runner: Runner
    private let monitor = DeviceMonitor()
    private var navigator: FileNavigator!
    private var preview: PreviewPane!
    /// Simulateur intégré (panneau de droite pendant l'exécution) et pile Aperçu / Simulateur.
    private let simulator = SimulatorPane()
    private var sideStack: UnsafeMutablePointer<GtkWidget>!
    /// Serveur de langage (sourcekit-lsp) pour l'autocomplétion, sur la copie d'aperçu du projet.
    private var language: LanguageServer!

    private var titleWidget: UnsafeMutablePointer<GtkWidget>!
    private var stopButton: UnsafeMutablePointer<GtkWidget>!
    private var destinationModel: OpaquePointer!
    private var destinationDropDown: UnsafeMutablePointer<GtkWidget>!
    private var destinations: [Destination] = Destination.simulators
    private var notebook: UnsafeMutablePointer<GtkWidget>!
    private var searchBar: UnsafeMutablePointer<GtkWidget>!
    private var searchEntry: UnsafeMutablePointer<GtkWidget>!
    private var previewRevealer: UnsafeMutablePointer<GtkWidget>!
    private var logNotebook: UnsafeMutablePointer<GtkWidget>!
    private var buildLog: UnsafeMutablePointer<GtkWidget>!
    private var appLog: UnsafeMutablePointer<GtkWidget>!
    private var deviceLog: UnsafeMutablePointer<GtkWidget>!
    private var problems: UnsafeMutablePointer<GtkWidget>!
    private var problemsLabel: UnsafeMutablePointer<GtkWidget>!
    private var status: UnsafeMutablePointer<GtkWidget>!

    /// Onglets ouverts, dans l'ordre du carnet.
    private enum Tab { case document(EditorDocument), assets(AssetEditor), signing(SigningEditor) }
    private var tabs: [(url: URL, tab: Tab, page: UnsafeMutablePointer<GtkWidget>)] = []
    private var diagnostics: [Diagnostic] = []
    /// Problèmes de signature de la dernière installation sur iPhone (page Signature et capabilities).
    private var signingIssues: [SigningIssue] = []
    /// Adresse fictive de l'onglet « Signature et capabilities » (les onglets sont repérés par URL).
    private var signingURL: URL { project.root.appendingPathComponent("Signature et capabilities") }

    init(project: XtoolProject) {
        self.project = project
        runner = Runner(project: project, lcodeRoot: lcodeRoot)
        window = adw_application_window_new(cast(raw(application)))
        gtk_window_set_default_size(cast(raw(window)), 1500, 940)
        gtk_window_set_title(cast(raw(window)), project.name)
        buildUI()
        runner.onOutput = { [weak self] in self?.append($0, to: self?.buildLog) }
        runner.onAppOutput = { [weak self] in self?.append($0, to: self?.appLog) }
        runner.onDeviceLog = { [weak self] in self?.append($0, to: self?.deviceLog) }
        runner.onState = { [weak self] in self?.update($0) }
        runner.onSigningIssues = { [weak self] in self?.signingIssuesFound($0) }
        runner.onBuildFinished = { [weak self] output in
            guard let self else { return }
            self.setDiagnostics(Diagnostic.parse(output) { SimulatorBuild(project: self.project, lcodeRoot: lcodeRoot).originalPath(for: $0) })
        }
        monitor.onChange = { [weak self] devices in self?.updateDestinations(devices) }
        monitor.start()
        // Fichier de départ : la première vue du projet, sinon l'app.
        let swiftFiles = project.targets.first { $0.name == project.appTarget }.map { target in
            (FileManager.default.enumerator(at: target.path, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        } ?? []
        if let first = swiftFiles.first(where: { $0.lastPathComponent == "ContentView.swift" })
            ?? swiftFiles.first(where: { !$0.lastPathComponent.hasSuffix("App.swift") }) ?? swiftFiles.first {
            open(first)
        }
        gtk_window_present(cast(raw(window)))
    }

    // MARK: - Interface

    private func buildUI() {
        // Barre d'en-tête.
        let header = adw_header_bar_new()!
        titleWidget = adw_window_title_new(project.name, "")
        adw_header_bar_set_title_widget(cast(raw(header)), titleWidget)
        let runButton = gtk_button_new_from_icon_name("media-playback-start-symbolic")!
        gtk_widget_set_tooltip_text(runButton, "Exécuter sur la destination (Ctrl+R)")
        connect(raw(runButton), "clicked") { [weak self] in self?.run() }
        stopButton = gtk_button_new_from_icon_name("media-playback-stop-symbolic")
        gtk_widget_set_tooltip_text(stopButton, "Arrêter (Ctrl+.)")
        gtk_widget_set_sensitive(stopButton, 0)
        connect(raw(stopButton), "clicked") { [weak self] in self?.stop() }
        destinationModel = gtk_string_list_new(nil)!
        destinationDropDown = gtk_drop_down_new(cast(raw(destinationModel)), nil)
        gtk_widget_set_tooltip_text(destinationDropDown, "Destination : simulateur ou iPhone (USB, Wi-Fi)")
        updateDestinations([])
        adw_header_bar_pack_start(cast(raw(header)), runButton)
        adw_header_bar_pack_start(cast(raw(header)), stopButton)
        adw_header_bar_pack_start(cast(raw(header)), destinationDropDown)

        let menuButton = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(raw(menuButton)), "open-menu-symbolic")
        gtk_menu_button_set_popover(cast(raw(menuButton)), mainMenu())
        let previewButton = gtk_toggle_button_new()!
        gtk_button_set_icon_name(cast(raw(previewButton)), "sidebar-show-right-symbolic")
        gtk_widget_set_tooltip_text(previewButton, "Aperçu (Ctrl+Alt+Entrée)")
        gtk_toggle_button_set_active(cast(raw(previewButton)), Settings.shared.previewVisible ? 1 : 0)
        let searchButton = gtk_button_new_from_icon_name("edit-find-symbolic")!
        gtk_widget_set_tooltip_text(searchButton, "Rechercher dans le fichier (Ctrl+F)")
        connect(raw(searchButton), "clicked") { [weak self] in self?.toggleSearch() }
        adw_header_bar_pack_end(cast(raw(header)), menuButton)
        adw_header_bar_pack_end(cast(raw(header)), previewButton)
        adw_header_bar_pack_end(cast(raw(header)), searchButton)

        // Navigateur.
        navigator = FileNavigator(root: project.root, window: self)
        navigator.onOpen = { [weak self] in self?.open($0) }
        let navBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        let navBar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        gtk_widget_set_margin_start(navBar, 8); gtk_widget_set_margin_end(navBar, 4)
        gtk_widget_set_margin_top(navBar, 4); gtk_widget_set_margin_bottom(navBar, 4)
        let navTitle = gtk_label_new(project.name)!
        gtk_widget_add_css_class(navTitle, "heading")
        gtk_widget_set_hexpand(navTitle, 1)
        gtk_label_set_xalign(cast(raw(navTitle)), 0)
        let addButton = gtk_button_new_from_icon_name("list-add-symbolic")!
        gtk_widget_add_css_class(addButton, "flat")
        gtk_widget_set_tooltip_text(addButton, "Nouveau fichier (Ctrl+N)")
        connect(raw(addButton), "clicked") { [weak self] in self?.newFile() }
        let signingButton = gtk_button_new_from_icon_name("security-high-symbolic")!
        gtk_widget_add_css_class(signingButton, "flat")
        gtk_widget_set_tooltip_text(signingButton, "Signature et capabilities")
        connect(raw(signingButton), "clicked") { [weak self] in self?.openSigning() }
        gtk_box_append(cast(raw(navBar)), navTitle)
        gtk_box_append(cast(raw(navBar)), signingButton)
        gtk_box_append(cast(raw(navBar)), addButton)
        gtk_box_append(cast(raw(navBox)), navBar)
        gtk_box_append(cast(raw(navBox)), navigator.widget)
        gtk_widget_set_size_request(navBox, 220, -1)

        // Éditeur : barre de recherche et onglets.
        searchEntry = gtk_search_entry_new()
        gtk_widget_set_size_request(searchEntry, 320, -1)
        searchBar = gtk_search_bar_new()
        gtk_search_bar_set_child(cast(raw(searchBar)), searchEntry)
        gtk_search_bar_connect_entry(cast(raw(searchBar)), OpaquePointer(searchEntry))
        gtk_search_bar_set_show_close_button(cast(raw(searchBar)), 1)
        connect(raw(searchEntry), "search-changed") { [weak self] in self?.search(forward: true) }
        connect(raw(searchEntry), "activate") { [weak self] in self?.search(forward: true) }
        connect(raw(searchEntry), "next-match") { [weak self] in self?.search(forward: true) }
        connect(raw(searchEntry), "previous-match") { [weak self] in self?.search(forward: false) }
        notebook = gtk_notebook_new()
        gtk_notebook_set_scrollable(cast(raw(notebook)), 1)
        gtk_widget_set_vexpand(notebook, 1)
        connectSwitchPage()
        let editorBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(cast(raw(editorBox)), searchBar)
        gtk_box_append(cast(raw(editorBox)), notebook)

        // Journal.
        buildLog = logView()
        appLog = logView()
        deviceLog = logView()
        problems = gtk_list_box_new()
        gtk_widget_add_css_class(problems, "navigation-sidebar")
        connectArg(raw(problems), "row-activated") { [weak self] row in
            guard let self, let row else { return }
            let i = Int(gtk_list_box_row_get_index(cast(row)))
            guard i >= 0, i < self.diagnostics.count else { return }
            let d = self.diagnostics[i]
            self.open(d.file)
            if case let .document(doc)? = self.tabs.first(where: { $0.url == d.file })?.tab { doc.goTo(line: d.line, column: d.column) }
        }
        logNotebook = gtk_notebook_new()
        problemsLabel = gtk_label_new("Problèmes")
        func page(_ child: UnsafeMutablePointer<GtkWidget>, _ title: String, label: UnsafeMutablePointer<GtkWidget>? = nil) {
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_child(cast(raw(scroller)), child)
            gtk_notebook_append_page(cast(raw(logNotebook)), scroller, label ?? gtk_label_new(title))
        }
        page(buildLog, "Compilation")
        page(problems, "", label: problemsLabel)
        page(appLog, "Sortie de l'app")
        page(deviceLog, "Appareil")
        let clear = gtk_button_new_from_icon_name("edit-clear-all-symbolic")!
        gtk_widget_add_css_class(clear, "flat")
        gtk_widget_set_tooltip_text(clear, "Effacer")
        connect(raw(clear), "clicked") { [weak self] in self?.clearCurrentLog() }
        status = gtk_label_new("Prêt")
        gtk_widget_add_css_class(status, "dim-label")
        gtk_widget_set_margin_end(status, 8)
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        gtk_box_append(cast(raw(actions)), status)
        gtk_box_append(cast(raw(actions)), clear)
        gtk_notebook_set_action_widget(cast(raw(logNotebook)), actions, GTK_PACK_END)

        let editorPane = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_paned_set_start_child(cast(raw(editorPane)), editorBox)
        gtk_paned_set_end_child(cast(raw(editorPane)), logNotebook)
        gtk_paned_set_position(cast(raw(editorPane)), 660)
        gtk_paned_set_shrink_end_child(cast(raw(editorPane)), 1)

        // Aperçu.
        preview = PreviewPane(project: project)
        preview.overrides = { [weak self] in
            var texts: [URL: String] = [:]
            for t in self?.tabs ?? [] { if case let .document(doc) = t.tab, doc.dirty { texts[doc.url] = doc.text } }
            return texts
        }
        preview.device = { [weak self] in self?.selectedDestination.simulatorID ?? "iphone17promax" }
        preview.onDiagnostics = { [weak self] in self?.setDiagnostics($0) }
        language = LanguageServer(build: preview.build)
        language.start()
        previewRevealer = gtk_revealer_new()
        gtk_revealer_set_transition_type(cast(raw(previewRevealer)), GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT)
        sideStack = gtk_stack_new()!
        gtk_stack_set_transition_type(cast(raw(sideStack)), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_add_named(cast(raw(sideStack)), preview.widget, "apercu")
        gtk_stack_add_named(cast(raw(sideStack)), simulator.widget, "simulateur")
        gtk_stack_set_visible_child_name(cast(raw(sideStack)), "apercu")
        runner.screen = simulator.screen
        simulator.send = { [weak self] in self?.runner.sendToApp($0) }
        gtk_revealer_set_child(cast(raw(previewRevealer)), sideStack)
        gtk_revealer_set_reveal_child(cast(raw(previewRevealer)), Settings.shared.previewVisible ? 1 : 0)
        connect(raw(previewButton), "toggled") { [weak self] in
            guard let self else { return }
            let on = gtk_toggle_button_get_active(cast(raw(previewButton))) != 0
            Settings.shared.previewVisible = on
            gtk_revealer_set_reveal_child(cast(raw(self.previewRevealer)), on ? 1 : 0)
            if on { self.preview.refresh() } else { self.preview.stopServer() }
        }

        let center = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(cast(raw(center)), editorPane)
        gtk_paned_set_end_child(cast(raw(center)), previewRevealer)
        gtk_paned_set_position(cast(raw(center)), 820)
        gtk_paned_set_resize_end_child(cast(raw(center)), 0)
        gtk_paned_set_shrink_end_child(cast(raw(center)), 0)

        let main = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(cast(raw(main)), navBox)
        gtk_paned_set_end_child(cast(raw(main)), center)
        gtk_paned_set_position(cast(raw(main)), 250)
        gtk_paned_set_shrink_start_child(cast(raw(main)), 0)
        gtk_paned_set_resize_start_child(cast(raw(main)), 0)

        let toolbarView = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(raw(toolbarView)), header)
        adw_toolbar_view_set_content(cast(raw(toolbarView)), main)
        adw_application_window_set_content(cast(raw(window)), toolbarView)

        addAction(window, "save", accel: "<Control>s") { [weak self] in self?.saveCurrent() }
        addAction(window, "save-all", accel: "<Control><Alt>s") { [weak self] in self?.saveAll() }
        addAction(window, "run", accel: "<Control>r") { [weak self] in self?.run() }
        addAction(window, "stop", accel: "<Control>period") { [weak self] in self?.stop() }
        addAction(window, "new-file", accel: "<Control>n") { [weak self] in self?.newFile() }
        addAction(window, "find", accel: "<Control>f") { [weak self] in self?.toggleSearch() }
        addAction(window, "close-tab", accel: "<Control>w") { [weak self] in self?.closeCurrentTab() }
        addAction(window, "preview", accel: "<Control><Alt>Return") {
            gtk_toggle_button_set_active(cast(raw(previewButton)), gtk_toggle_button_get_active(cast(raw(previewButton))) == 0 ? 1 : 0)
        }
        connectReturningFalse(raw(window), "close-request") { [weak self] in
            guard let self else { return }
            self.saveAll()
            self.runner.stop()
            self.runner.stopDeviceLog()
            self.preview.stopServer()
            self.language.stop()
            App.shared.projectClosed(self)
        }
        // Apparence : l'éditeur suit le thème clair ou sombre.
        connectArg(raw(adw_style_manager_get_default()), "notify::dark") { [weak self] _ in
            for t in self?.tabs ?? [] { if case let .document(doc) = t.tab { doc.applyScheme(); doc.overlayTypes() } }
        }
    }

    private func logView() -> UnsafeMutablePointer<GtkWidget> {
        let view = gtk_text_view_new()!
        gtk_widget_add_css_class(view, "lcode-console")
        gtk_text_view_set_editable(cast(raw(view)), 0)
        gtk_text_view_set_monospace(cast(raw(view)), 1)
        gtk_text_view_set_left_margin(cast(raw(view)), 10)
        gtk_text_view_set_top_margin(cast(raw(view)), 6)
        return view
    }

    /// Menu principal : fichiers, projets, apparence.
    private func mainMenu() -> UnsafeMutablePointer<GtkWidget> {
        let popover = gtk_popover_new()!
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        func item(_ label: String, _ action: @escaping () -> Void) {
            let b = gtk_button_new_with_label(label)!
            gtk_widget_add_css_class(b, "flat")
            if let child = gtk_widget_get_first_child(b) { gtk_label_set_xalign(cast(raw(child)), 0) }
            connect(raw(b), "clicked") { gtk_popover_popdown(cast(raw(popover))); action() }
            gtk_box_append(cast(raw(box)), b)
        }
        func separator() { gtk_box_append(cast(raw(box)), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)) }
        item("Nouveau fichier…  (Ctrl+N)") { [weak self] in self?.newFile() }
        item("Nouveau dossier…") { [weak self] in self?.navigator.newFolder() }
        item("Enregistrer tout  (Ctrl+Alt+S)") { [weak self] in self?.saveAll() }
        item("Paquets…") { [weak self] in if let self { PackagesDialog.present(for: self) } }
        item("Signature et capabilities") { [weak self] in self?.openSigning() }
        item("Compte Apple…") { [weak self] in self?.showAccount() }
        separator()
        let win = window
        item("Nouveau projet…") { App.shared.newProject(from: win) }
        item("Ouvrir un projet…") { App.shared.openProjectDialog(from: win) }
        item("Fenêtre d'accueil") { App.shared.showWelcome() }
        separator()
        let appearanceTitle = gtk_label_new("Apparence")!
        gtk_widget_add_css_class(appearanceTitle, "dim-label")
        gtk_label_set_xalign(cast(raw(appearanceTitle)), 0)
        gtk_widget_set_margin_start(appearanceTitle, 10)
        gtk_widget_set_margin_top(appearanceTitle, 6)
        gtk_box_append(cast(raw(box)), appearanceTitle)
        var first: UnsafeMutablePointer<GtkWidget>?
        for appearance in Settings.Appearance.allCases {
            let check = gtk_check_button_new_with_label(appearance.title)!
            gtk_widget_set_margin_start(check, 6)
            if let first { gtk_check_button_set_group(cast(raw(check)), cast(raw(first))) } else { first = check }
            gtk_check_button_set_active(cast(raw(check)), Settings.shared.appearance == appearance ? 1 : 0)
            connect(raw(check), "toggled") {
                if gtk_check_button_get_active(cast(raw(check))) != 0 { Settings.shared.appearance = appearance }
            }
            gtk_box_append(cast(raw(box)), check)
        }
        gtk_popover_set_child(cast(raw(popover)), box)
        return popover
    }

    // MARK: - Onglets

    func open(_ url: URL) {
        if let i = tabs.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            gtk_notebook_set_current_page(cast(raw(notebook)), Int32(i))
            return
        }
        let tab: Tab
        let page: UnsafeMutablePointer<GtkWidget>
        if url == signingURL {
            let editor = SigningEditor(window: self)
            editor.issues = signingIssues
            tab = .signing(editor)
            page = editor.widget
        } else if url.pathExtension == "xcassets" {
            let editor = AssetEditor(catalog: url, window: self)
            tab = .assets(editor)
            page = editor.widget
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                Dialogs.message(window, title: "Ouverture impossible", message: "\(url.lastPathComponent) n'est pas un fichier texte.")
                return
            }
            let doc = EditorDocument(url: url, text: text)
            doc.onDirty = { [weak self, weak doc] in if let doc { self?.updateTabTitle(doc) } }
            doc.onChange = { [weak self, weak doc] in
                guard let self, let doc else { return }
                self.overlayLater(doc)
                if self.currentURL == doc.url { self.preview.textChanged() }
            }
            if url.pathExtension == "swift" {
                doc.completion.provider = { [weak self, weak doc] text, line, character, done in
                    guard let self, let doc else { return }
                    self.language.complete(doc.url, text: text, line: line, character: character, completion: done)
                }
            }
            tab = .document(doc)
            page = doc.scroller
            for d in diagnostics where d.isError && d.file == url { doc.markError(line: d.line) }
        }
        // Étiquette : icône, nom, bouton de fermeture.
        let label = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let icon = url == signingURL ? "security-high-symbolic" : url.pathExtension == "xcassets" ? "image-x-generic-symbolic" : "text-x-script-symbolic"
        gtk_box_append(cast(raw(label)), gtk_image_new_from_icon_name(icon))
        let name = gtk_label_new(url.lastPathComponent)!
        gtk_box_append(cast(raw(label)), name)
        let close = gtk_button_new_from_icon_name("window-close-symbolic")!
        gtk_widget_add_css_class(close, "flat")
        gtk_widget_add_css_class(close, "circular")
        connect(raw(close), "clicked") { [weak self] in self?.closeTab(url) }
        gtk_box_append(cast(raw(label)), close)
        if case let .document(doc) = tab { doc.tabLabel = name }
        tabs.append((url, tab, page))
        let index = gtk_notebook_append_page(cast(raw(notebook)), page, label)
        gtk_notebook_set_tab_reorderable(cast(raw(notebook)), page, 0)
        gtk_notebook_set_current_page(cast(raw(notebook)), index)
        navigator.reveal(url)
    }

    private var overlayGeneration: [URL: Int] = [:]
    private func overlayLater(_ doc: EditorDocument) {
        let g = (overlayGeneration[doc.url] ?? 0) + 1
        overlayGeneration[doc.url] = g
        after(200) { [weak self, weak doc] in
            guard let self, let doc, self.overlayGeneration[doc.url] == g else { return }
            doc.overlayTypes()
        }
    }

    private var currentIndex: Int { Int(gtk_notebook_get_current_page(cast(raw(notebook)))) }
    private var currentURL: URL? { currentIndex >= 0 && currentIndex < tabs.count ? tabs[currentIndex].url : nil }
    private var currentDocument: EditorDocument? {
        guard currentIndex >= 0, currentIndex < tabs.count, case let .document(doc) = tabs[currentIndex].tab else { return nil }
        return doc
    }

    private func connectSwitchPage() {
        final class Box { weak var window: ProjectWindow?; init(_ w: ProjectWindow) { window = w } }
        let box = Unmanaged.passRetained(Box(self)).toOpaque()
        let callback: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, guint, UnsafeMutableRawPointer?) -> Void = { _, _, index, data in
            guard let w = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().window else { return }
            onMain { w.pageChanged(Int(index)) }
        }
        _ = lcode_connect(raw(notebook), "switch-page", unsafeBitCast(callback, to: GCallback.self), box)
    }

    private func pageChanged(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let url = tabs[index].url
        updateTitle()
        navigator.reveal(url)
        preview.show(url.pathExtension == "swift" ? url : nil)
    }

    private func updateTitle() {
        guard let url = currentURL else { adw_window_title_set_subtitle(cast(raw(titleWidget)), ""); return }
        let relative = url.path.replacingOccurrences(of: project.root.path + "/", with: "")
        let dirty = currentDocument?.dirty == true
        adw_window_title_set_subtitle(cast(raw(titleWidget)), (dirty ? "● " : "") + relative)
    }

    private func updateTabTitle(_ doc: EditorDocument) {
        gtk_label_set_text(cast(raw(doc.tabLabel)), (doc.dirty ? "● " : "") + doc.url.lastPathComponent)
        updateTitle()
    }

    private func closeTab(_ url: URL) {
        guard let i = tabs.firstIndex(where: { $0.url == url }) else { return }
        if case let .document(doc) = tabs[i].tab, doc.dirty { try? doc.save() }
        gtk_notebook_remove_page(cast(raw(notebook)), Int32(i))
        tabs.remove(at: i)
        if tabs.isEmpty { preview.show(nil); updateTitle() }
    }

    private func closeCurrentTab() {
        if let url = currentURL { closeTab(url) }
    }

    /// Fichier renommé ou déplacé depuis le navigateur : l'onglet suit.
    func fileMoved(from old: URL, to new: URL) {
        let affected = tabs.filter { $0.url.path == old.path || $0.url.path.hasPrefix(old.path + "/") }
        for t in affected {
            closeTab(t.url)
            open(URL(fileURLWithPath: new.path + t.url.path.dropFirst(old.path.count)))
        }
    }

    func fileDeleted(_ url: URL) {
        for t in tabs where t.url.path == url.path || t.url.path.hasPrefix(url.path + "/") {
            if case let .document(doc) = t.tab { doc.dirty = false }
            closeTab(t.url)
        }
    }

    // MARK: - Fichiers

    private func newFile() {
        let folder = currentURL?.deletingLastPathComponent()
            ?? project.targets.first { $0.name == project.appTarget }?.path ?? project.root
        navigator.newFile(in: folder)
    }

    private func saveCurrent() {
        guard let doc = currentDocument else { return }
        do {
            try doc.save()
            updateTabTitle(doc)
            // Enregistrer relance l'app si elle tourne (sur le simulateur).
            if runner.isRunning, selectedDestination.simulatorID != nil {
                append("▸ Enregistré : relance du simulateur.\n", to: buildLog)
                run()
            }
        } catch {
            Dialogs.message(window, title: "Enregistrement impossible", message: "\(error)")
        }
    }

    private func saveAll() {
        for t in tabs { if case let .document(doc) = t.tab, doc.dirty { try? doc.save(); updateTabTitle(doc) } }
    }

    // MARK: - Recherche

    private func toggleSearch() {
        let on = gtk_search_bar_get_search_mode(cast(raw(searchBar))) == 0
        gtk_search_bar_set_search_mode(cast(raw(searchBar)), on ? 1 : 0)
        if on { gtk_widget_grab_focus(searchEntry) } else { currentDocument?.search("") }
    }

    private func search(forward: Bool) {
        let text = String(cString: gtk_editable_get_text(OpaquePointer(searchEntry)))
        currentDocument?.search(text, forward: forward)
    }

    // MARK: - Exécution

    private var selectedDestination: Destination {
        let i = Int(gtk_drop_down_get_selected(cast(raw(destinationDropDown))))
        return i >= 0 && i < destinations.count ? destinations[i] : destinations[0]
    }

    private func updateDestinations(_ devices: [Destination]) {
        let previous = destinations.isEmpty ? nil : selectedDestination
        destinations = Destination.simulators + devices
        let n = Int(g_list_model_get_n_items(destinationModel))
        var titles = destinations.map { UnsafePointer(strdup($0.title)) as UnsafePointer<CChar>? }
        titles.append(nil)
        titles.withUnsafeBufferPointer { gtk_string_list_splice(cast(raw(destinationModel)), 0, guint(n), $0.baseAddress) }
        // Un iPhone qui apparaît devient la destination s'il n'y en avait pas ; sinon on garde le choix.
        if let previous, let i = destinations.firstIndex(of: previous) {
            gtk_drop_down_set_selected(cast(raw(destinationDropDown)), guint(i))
        } else if previous?.simulatorID != nil || previous == nil, let first = devices.first, let i = destinations.firstIndex(of: first),
                  previous == nil || previous == Destination.simulators[0] && n > 0 && devices.count > 0 && false {
            gtk_drop_down_set_selected(cast(raw(destinationDropDown)), guint(i))
        }
        if !devices.isEmpty, n > 0, n <= Destination.simulators.count {
            append("▸ iPhone détecté : \(devices.map(\.title).joined(separator: ", ")).\n", to: buildLog)
        }
    }

    private func run() {
        saveAll()
        clear(buildLog)
        gtk_notebook_set_current_page(cast(raw(logNotebook)), 0)
        switch selectedDestination.kind {
        case let .simulator(id):
            clear(appLog)
            runner.run(device: id, dark: Settings.isDark)
        case let .device(udid, network):
            clear(deviceLog)
            runner.runOnDevice(udid: udid, network: network)
        }
    }

    /// Pendant une exécution dans le simulateur, le panneau de droite montre l'app (l'aperçu se met en pause) ;
    /// à l'arrêt, l'aperçu revient.
    private var simulatorShown = false
    private func updateSidePanel(_ state: Runner.State) {
        guard selectedDestination.simulatorID != nil else { return }
        let device = selectedDestination.title.replacingOccurrences(of: " (simulateur)", with: "")
        simulator.update(state, device: device, dark: Settings.isDark)
        let show = state == .building || state == .running || (state == .failed && simulatorShown)
        if show && !simulatorShown {
            simulatorShown = true
            preview.stopServer()
            gtk_stack_set_visible_child_name(cast(raw(sideStack)), "simulateur")
            gtk_revealer_set_reveal_child(cast(raw(previewRevealer)), 1)
        } else if state == .idle && simulatorShown {
            simulatorShown = false
            gtk_stack_set_visible_child_name(cast(raw(sideStack)), "apercu")
            gtk_revealer_set_reveal_child(cast(raw(previewRevealer)), Settings.shared.previewVisible ? 1 : 0)
            if Settings.shared.previewVisible { preview.refresh() }
        }
    }

    /// Relit le projet (Package.swift modifié : paquets…) et met à jour l'exécution, l'aperçu, la complétion
    /// et l'onglet Package.swift s'il est ouvert.
    func reloadProject(_ done: @escaping () -> Void = {}) {
        let root = project.root
        Thread.detachNewThread { [weak self] in
            let loaded = try? XtoolProject.load(at: root)
            onMain {
                guard let self else { return }
                if let loaded {
                    self.project = loaded
                    self.runner.project = loaded
                    self.preview.reload(project: loaded)
                    self.language.stop()
                    self.language = LanguageServer(build: self.preview.build)
                    self.language.start()
                    for t in self.tabs {
                        if case let .document(doc) = t.tab, !doc.dirty { doc.reloadFromDisk() }
                        if case let .signing(editor) = t.tab { editor.projectChanged() }
                    }
                    self.append("▸ Projet rechargé (\(loaded.dependencies.count) paquet(s)).\n", to: self.buildLog)
                }
                done()
            }
        }
    }

    private func stop() {
        runner.stop()
        runner.stopDeviceLog()
    }

    private func update(_ state: Runner.State) {
        updateSidePanel(state)
        gtk_widget_set_sensitive(stopButton, state == .building || state == .running ? 1 : 0)
        let text: String
        switch state {
        case .idle: text = "Prêt"
        case .building: text = "Compilation…"
        case .running: text = "En cours d'exécution"
        case .failed: text = "Échec de la compilation"
        }
        gtk_label_set_text(cast(raw(status)), text)
        if state == .running { gtk_notebook_set_current_page(cast(raw(logNotebook)), 2) }
        if state == .failed, !diagnostics.filter(\.isError).isEmpty { gtk_notebook_set_current_page(cast(raw(logNotebook)), 1) }
    }

    // MARK: - Signature

    /// Ouvre (ou montre) l'onglet « Signature et capabilities ».
    func openSigning() { open(signingURL) }

    func showAccount() {
        AccountDialog.present(from: window) { [weak self] in
            for t in self?.tabs ?? [] { if case let .signing(editor) = t.tab { editor.refreshAccount() } }
        }
    }

    /// Fin d'une installation sur iPhone : les problèmes de signature vont au journal et à la page de signature.
    private func signingIssuesFound(_ issues: [SigningIssue]) {
        signingIssues = issues
        for t in tabs { if case let .signing(editor) = t.tab { editor.issues = issues } }
        guard !issues.isEmpty else { return }
        for issue in issues { append("✗ Signature : \(issue.message)\n", to: buildLog) }
        append("▸ Détails : menu › Signature et capabilities.\n", to: buildLog)
        // Pas de compte : on propose directement la connexion.
        if issues.contains(where: { $0.message.hasPrefix("Aucun compte Apple") }) { showAccount() }
    }

    // MARK: - Problèmes

    private func setDiagnostics(_ list: [Diagnostic]) {
        diagnostics = list.filter(\.isError) + list.filter { !$0.isError }
        while let child = gtk_widget_get_first_child(problems) { gtk_list_box_remove(cast(raw(problems)), child) }
        for d in diagnostics {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            gtk_box_append(cast(raw(row)), gtk_image_new_from_icon_name(d.isError ? "dialog-error-symbolic" : "dialog-warning-symbolic"))
            let text = gtk_label_new("\(d.file.lastPathComponent):\(d.line)  \(d.message)")!
            gtk_label_set_xalign(cast(raw(text)), 0)
            gtk_label_set_ellipsize(cast(raw(text)), PANGO_ELLIPSIZE_END)
            gtk_box_append(cast(raw(row)), text)
            gtk_list_box_append(cast(raw(problems)), row)
        }
        let errors = diagnostics.filter(\.isError).count, warnings = diagnostics.count - errors
        gtk_label_set_text(cast(raw(problemsLabel)), errors + warnings == 0 ? "Problèmes" : "Problèmes (\(errors) ✗, \(warnings) ⚠)")
        // Lignes en erreur soulignées dans les fichiers ouverts.
        for t in tabs {
            guard case let .document(doc) = t.tab else { continue }
            doc.clearErrors()
            for d in diagnostics where d.isError && d.file.standardizedFileURL == doc.url.standardizedFileURL { doc.markError(line: d.line) }
        }
    }

    // MARK: - Journal

    private func append(_ text: String, to view: UnsafeMutablePointer<GtkWidget>?) {
        guard let view else { return }
        let buffer = gtk_text_view_get_buffer(cast(raw(view)))
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_insert(buffer, &end, text, -1)
        gtk_text_buffer_get_end_iter(buffer, &end)
        let mark = gtk_text_buffer_create_mark(buffer, nil, &end, 0)
        gtk_text_view_scroll_mark_onscreen(cast(raw(view)), mark)
        gtk_text_buffer_delete_mark(buffer, mark)
    }

    private func clear(_ view: UnsafeMutablePointer<GtkWidget>) {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(cast(raw(view))), "", -1)
    }

    private func clearCurrentLog() {
        switch gtk_notebook_get_current_page(cast(raw(logNotebook))) {
        case 0: clear(buildLog)
        case 2: clear(appLog)
        case 3: clear(deviceLog)
        default: setDiagnostics([])
        }
    }
}
