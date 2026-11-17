import CAdw
import Foundation
import LCodeKit

/// Erreur ou avertissement du compilateur, rattaché au fichier d'origine.
struct Diagnostic {
    let file: URL
    let line: Int
    let column: Int
    let isError: Bool
    let message: String

    /// Lignes « chemin:ligne:colonne: error|warning: message » d'une sortie de swift build.
    static func parse(_ output: String, mapPath: (String) -> String) -> [Diagnostic] {
        var seen = Set<String>()
        var result: [Diagnostic] = []
        // Codes de couleur du terminal retirés avant l'analyse.
        let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
        let plain = ansi.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "")
        for line in plain.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0].hasPrefix("/"), let l = Int(parts[1]), let c = Int(parts[2]) else { continue }
            let kind = parts[3].trimmingCharacters(in: .whitespaces)
            guard kind == "error" || kind == "warning" else { continue }
            let message = parts[4].trimmingCharacters(in: .whitespaces)
            let key = "\(parts[0]):\(l):\(c):\(message)"
            guard seen.insert(key).inserted else { continue }
            result.append(Diagnostic(file: URL(fileURLWithPath: mapPath(String(parts[0]))), line: l, column: c,
                                     isError: kind == "error", message: message))
        }
        return result
    }
}

/// Aperçu intégré (comme les « Previews » d'Xcode) : le `#Preview` du fichier ouvert tourne dans LSim,
/// affiché ici et interactif ; il se recompile et se recharge à chaque modification du texte.
final class PreviewPane {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let project: XtoolProject
    let build: PreviewBuild
    private let picture: UnsafeMutablePointer<GtkWidget>
    private let status: UnsafeMutablePointer<GtkWidget>
    private let spinner: UnsafeMutablePointer<GtkWidget>
    private let banner: UnsafeMutablePointer<GtkWidget>
    private let bannerLabel: UnsafeMutablePointer<GtkWidget>
    private let placeholder: UnsafeMutablePointer<GtkWidget>
    private let selector: UnsafeMutablePointer<GtkWidget>
    private let darkToggle: UnsafeMutablePointer<GtkWidget>
    private var selectorModel: OpaquePointer

    private var currentFile: URL?
    private var entries: [PreviewBuild.Entry] = []
    private var server: Process?
    private var serverInput: FileHandle?
    private var building = false
    private var pending = false
    private var generation = 0
    private let framePath: String
    private var frameSize = CGSize(width: 440, height: 956)
    /// Texte non enregistré des fichiers ouverts, et appareil à simuler.
    var overrides: () -> [URL: String] = { [:] }
    var device: () -> String = { "iphone17promax" }
    var onDiagnostics: ([Diagnostic]) -> Void = { _ in }

    init(project: XtoolProject) {
        self.project = project
        build = PreviewBuild(project: project, lcodeRoot: lcodeRoot)
        framePath = FileManager.default.temporaryDirectory.appendingPathComponent("lcode-apercu-\(getpid())-\(UUID().uuidString.prefix(6)).raw").path

        // Barre : choix de l'aperçu, clair/sombre, actualiser, état.
        selectorModel = gtk_string_list_new(nil)!
        selector = gtk_drop_down_new(cast(raw(selectorModel)), nil)!
        gtk_widget_set_tooltip_text(selector, "Aperçu (#Preview) du fichier")
        darkToggle = gtk_toggle_button_new()!
        gtk_button_set_icon_name(cast(raw(darkToggle)), "weather-clear-night-symbolic")
        gtk_widget_set_tooltip_text(darkToggle, "Aperçu en mode sombre")
        let refresh = gtk_button_new_from_icon_name("view-refresh-symbolic")!
        gtk_widget_set_tooltip_text(refresh, "Recharger l'aperçu")
        spinner = gtk_spinner_new()!
        status = gtk_label_new("")!
        gtk_widget_add_css_class(status, "dim-label")
        gtk_label_set_ellipsize(cast(raw(status)), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(status, 1)
        gtk_label_set_xalign(cast(raw(status)), 0)
        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_widget_set_margin_start(bar, 8); gtk_widget_set_margin_end(bar, 8)
        gtk_widget_set_margin_top(bar, 6); gtk_widget_set_margin_bottom(bar, 6)
        let titleLabel = gtk_label_new("Aperçu")!
        gtk_widget_add_css_class(titleLabel, "heading")
        gtk_box_append(cast(raw(bar)), titleLabel)
        gtk_box_append(cast(raw(bar)), selector)
        gtk_box_append(cast(raw(bar)), spinner)
        gtk_box_append(cast(raw(bar)), status)
        gtk_box_append(cast(raw(bar)), darkToggle)
        gtk_box_append(cast(raw(bar)), refresh)

        // Image de l'écran, bandeau d'erreurs, message sans aperçu.
        picture = gtk_picture_new()!
        gtk_picture_set_content_fit(cast(raw(picture)), GTK_CONTENT_FIT_CONTAIN)
        gtk_picture_set_can_shrink(cast(raw(picture)), 1)
        gtk_widget_set_vexpand(picture, 1)
        gtk_widget_set_hexpand(picture, 1)
        gtk_widget_set_margin_start(picture, 16); gtk_widget_set_margin_end(picture, 16)
        gtk_widget_set_margin_bottom(picture, 16)
        placeholder = gtk_label_new("Ouvrez un fichier qui contient un #Preview.")!
        gtk_widget_add_css_class(placeholder, "dim-label")
        gtk_label_set_wrap(cast(raw(placeholder)), 1)
        gtk_label_set_justify(cast(raw(placeholder)), GTK_JUSTIFY_CENTER)
        bannerLabel = gtk_label_new("")!
        gtk_label_set_wrap(cast(raw(bannerLabel)), 1)
        gtk_label_set_xalign(cast(raw(bannerLabel)), 0)
        gtk_label_set_selectable(cast(raw(bannerLabel)), 1)
        banner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_widget_add_css_class(banner, "lcode-error-banner")
        gtk_box_append(cast(raw(banner)), gtk_image_new_from_icon_name("dialog-error-symbolic"))
        gtk_box_append(cast(raw(banner)), bannerLabel)
        gtk_widget_set_margin_start(banner, 12); gtk_widget_set_margin_end(banner, 12)
        gtk_widget_set_valign(banner, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(banner, 28)
        gtk_widget_set_visible(banner, 0)
        let overlay = gtk_overlay_new()!
        let stack = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(cast(raw(stack)), picture)
        gtk_overlay_set_child(cast(raw(overlay)), stack)
        gtk_overlay_add_overlay(cast(raw(overlay)), banner)
        gtk_widget_set_halign(placeholder, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(placeholder, GTK_ALIGN_CENTER)
        gtk_overlay_add_overlay(cast(raw(overlay)), placeholder)
        gtk_widget_set_vexpand(overlay, 1)

        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_add_css_class(widget, "lcode-preview")
        gtk_widget_set_size_request(widget, 340, -1)
        gtk_box_append(cast(raw(widget)), bar)
        gtk_box_append(cast(raw(widget)), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        gtk_box_append(cast(raw(widget)), overlay)

        connect(raw(refresh), "clicked") { [weak self] in self?.refresh() }
        connect(raw(darkToggle), "toggled") { [weak self] in
            guard let self else { return }
            self.send("scheme \(gtk_toggle_button_get_active(cast(raw(self.darkToggle))) != 0 ? "dark" : "light")")
        }
        connectArg(raw(selector), "notify::selected") { [weak self] _ in self?.restartServer() }
        installGestures()
    }

    // MARK: - Fichier suivi

    /// Le fichier affiché dans l'éditeur a changé : on prévisualise ses `#Preview`.
    func show(_ url: URL?) {
        guard url != currentFile else { return }
        currentFile = url
        refresh()
    }

    /// Le texte a changé : nouvel aperçu après un court délai (une seule compilation par rafale).
    func textChanged() {
        generation += 1
        let g = generation
        after(700) { [weak self] in
            guard let self, g == self.generation else { return }
            self.refresh()
        }
    }

    func refresh() {
        guard let file = currentFile, file.pathExtension == "swift" else {
            stopServer()
            setPlaceholder("Ouvrez un fichier qui contient un #Preview.")
            return
        }
        if building { pending = true; return }
        do {
            entries = try build.prepare(overrides: overrides()).filter { $0.file.standardizedFileURL == file.standardizedFileURL }
        } catch {
            showErrors("Préparation de l'aperçu impossible : \(error)")
            return
        }
        guard !entries.isEmpty else {
            stopServer()
            setPlaceholder("Ce fichier n'a pas de #Preview.\nAjoutez par exemple :\n\n#Preview {\n    MaVue()\n}")
            onDiagnostics([])
            return
        }
        updateSelector()
        compile()
    }

    private func updateSelector() {
        let titles = entries.enumerated().map { i, e in e.preview.name ?? (entries.count > 1 ? "Aperçu \(i + 1)" : "Aperçu") }
        let current = Int(gtk_drop_down_get_selected(cast(raw(selector))))
        let n = Int(g_list_model_get_n_items(selectorModel))
        var same = n == titles.count
        if same { for i in 0..<n where String(cString: gtk_string_list_get_string(cast(raw(selectorModel)), guint(i))) != titles[i] { same = false } }
        guard !same else { return }
        var cStrings = titles.map { UnsafePointer(strdup($0)) as UnsafePointer<CChar>? }
        cStrings.append(nil)
        cStrings.withUnsafeBufferPointer { gtk_string_list_splice(cast(raw(selectorModel)), 0, guint(n), $0.baseAddress) }
        gtk_drop_down_set_selected(cast(raw(selector)), guint(min(max(current, 0), titles.count - 1)))
        gtk_widget_set_visible(selector, titles.count > 1 ? 1 : 0)
    }

    // MARK: - Compilation

    private func compile() {
        building = true
        gtk_spinner_start(cast(raw(spinner)))
        gtk_label_set_text(cast(raw(status)), "Compilation…")
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "--package-path", build.directory.path, "--product", project.appTarget]
        process.environment = Runner.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] p in
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            onMain {
                guard let self else { return }
                self.building = false
                gtk_spinner_stop(cast(raw(self.spinner)))
                let diagnostics = Diagnostic.parse(output, mapPath: self.build.originalPath)
                self.onDiagnostics(diagnostics)
                if p.terminationStatus != 0 {
                    let errors = diagnostics.filter(\.isError)
                    let text = errors.isEmpty ? "La compilation a échoué." : errors.prefix(4).map {
                        "\($0.file.lastPathComponent):\($0.line) — \($0.message)"
                    }.joined(separator: "\n")
                    self.showErrors(text)
                    gtk_label_set_text(cast(raw(self.status)), "\(errors.count) erreur\(errors.count > 1 ? "s" : "")")
                } else {
                    gtk_widget_set_visible(self.banner, 0)
                    gtk_label_set_text(cast(raw(self.status)), String(format: "À jour (%.1f s)", Date().timeIntervalSince(started)))
                    self.restartServer()
                }
                if self.pending { self.pending = false; self.refresh() }
            }
        }
        do { try process.run() } catch {
            building = false
            showErrors("swift build introuvable : \(error)")
        }
    }

    private func showErrors(_ text: String) {
        gtk_label_set_text(cast(raw(bannerLabel)), text)
        gtk_widget_set_visible(banner, 1)
        gtk_widget_set_visible(placeholder, 0)
        gtk_widget_set_opacity(picture, 0.45)
    }

    private func setPlaceholder(_ text: String) {
        gtk_label_set_text(cast(raw(placeholder)), text)
        gtk_widget_set_visible(placeholder, 1)
        gtk_widget_set_visible(banner, 0)
        gtk_picture_set_paintable(cast(raw(picture)), nil)
        gtk_label_set_text(cast(raw(status)), "")
    }

    // MARK: - Serveur d'aperçu

    private var binary: URL {
        let bin = (try? Shell.capture(["swift", "build", "--package-path", build.directory.path, "--show-bin-path"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? build.directory.appendingPathComponent(".build/debug").path
        return URL(fileURLWithPath: bin).appendingPathComponent(project.appTarget)
    }

    private func restartServer() {
        guard !entries.isEmpty, !building else { return }
        stopServer()
        let index = min(Int(gtk_drop_down_get_selected(cast(raw(selector)))), entries.count - 1)
        let entry = entries[max(0, index)]
        let process = Process()
        process.executableURL = binary
        var env = Runner.environment
        env["LSIM_PREVIEW_ID"] = entry.preview.symbol
        env["LSIM_PREVIEW_FRAME"] = framePath
        env["LSIM_DEVICE"] = device()
        env.merge(project.simulatorEnvironment) { _, n in n }
        if gtk_toggle_button_get_active(cast(raw(darkToggle))) != 0 { env["LSIM_DARK"] = "1" }
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                let parts = line.split(separator: " ").compactMap { Int($0) }
                if line.hasPrefix("frame"), parts.count == 3 {
                    onMain { self?.loadFrame(width: parts[0], height: parts[1], stride: parts[2]) }
                }
            }
        }
        do {
            try process.run()
            server = process
            serverInput = input.fileHandleForWriting
            gtk_widget_set_visible(placeholder, 0)
        } catch {
            showErrors("Lancement de l'aperçu impossible : \(error)")
        }
    }

    func stopServer() {
        serverInput?.write(Data("quit\n".utf8))
        server?.terminate()
        server = nil
        serverInput = nil
    }

    private func send(_ command: String) {
        serverInput?.write(Data((command + "\n").utf8))
    }

    private func loadFrame(width: Int, height: Int, stride: Int) {
        guard let data = FileManager.default.contents(atPath: framePath), data.count >= stride * height else { return }
        let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize(data.count)) }
        let texture = gdk_memory_texture_new(Int32(width), Int32(height), GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, gsize(stride))
        gtk_picture_set_paintable(cast(raw(picture)), texture)
        g_object_unref(UnsafeMutableRawPointer(texture))
        g_bytes_unref(bytes)
        gtk_widget_set_opacity(picture, 1)
        frameSize = CGSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
    }

    // MARK: - Gestes → app

    /// Point de l'écran simulé (en points) sous un point du widget image.
    private func screenPoint(_ x: Double, _ y: Double) -> (Double, Double)? {
        let w = Double(gtk_widget_get_width(picture)), h = Double(gtk_widget_get_height(picture))
        let fw = Double(frameSize.width), fh = Double(frameSize.height)
        guard w > 0, h > 0 else { return nil }
        let s = min(w / fw, h / fh)
        let ox = (w - fw * s) / 2, oy = (h - fh * s) / 2
        let px = (x - ox) / s, py = (y - oy) / s
        guard px >= 0, py >= 0, px <= fw, py <= fh else { return nil }
        return (px, py)
    }

    private var dragStart: (Double, Double)?
    private var scale: Double {
        let w = Double(gtk_widget_get_width(picture)), h = Double(gtk_widget_get_height(picture))
        return max(0.01, min(w / Double(frameSize.width), h / Double(frameSize.height)))
    }

    private func installGestures() {
        let drag = gtk_gesture_drag_new()!
        final class Box { weak var pane: PreviewPane?; init(_ p: PreviewPane) { pane = p } }
        let box = Unmanaged.passRetained(Box(self)).toOpaque()
        let begin: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, x, y, data in
            guard let pane = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().pane, let p = pane.screenPoint(x, y) else { return }
            pane.dragStart = p
            pane.send("press \(p.0) \(p.1)")
        }
        let update: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, dx, dy, data in
            guard let pane = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().pane, pane.dragStart != nil else { return }
            pane.send("move \(dx / pane.scale) \(dy / pane.scale)")
        }
        let end: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, dx, dy, data in
            guard let pane = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().pane, let s = pane.dragStart else { return }
            pane.send("release \(s.0 + dx / pane.scale) \(s.1 + dy / pane.scale)")
            pane.dragStart = nil
        }
        _ = lcode_connect(raw(drag), "drag-begin", unsafeBitCast(begin, to: GCallback.self), box)
        _ = lcode_connect(raw(drag), "drag-update", unsafeBitCast(update, to: GCallback.self), box)
        _ = lcode_connect(raw(drag), "drag-end", unsafeBitCast(end, to: GCallback.self), box)
        gtk_widget_add_controller(picture, drag)

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        let onScroll: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> gboolean = { _, _, dy, data in
            guard let pane = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().pane else { return 0 }
            pane.send("scroll \(pane.frameSize.width / 2) \(pane.frameSize.height / 2) \(dy * 40)")
            return 1
        }
        _ = lcode_connect(raw(scroll), "scroll", unsafeBitCast(onScroll, to: GCallback.self), box)
        gtk_widget_add_controller(picture, scroll)
    }
}
