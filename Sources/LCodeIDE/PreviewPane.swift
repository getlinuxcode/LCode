import CAdw
import Foundation
import LCodeKit

/// Compiler error or warning, mapped back to the original file.
struct Diagnostic {
    let file: URL
    let line: Int
    let column: Int
    let isError: Bool
    let message: String

    /// Parses `path:line:column: error|warning: message` lines from swift build output.
    static func parse(_ output: String, mapPath: (String) -> String) -> [Diagnostic] {
        var seen = Set<String>()
        var result: [Diagnostic] = []
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

/// Embedded canvas (like Xcode Previews): the open file's `#Preview` runs in LSim, interactive, and rebuilds
/// as the text changes.
final class PreviewPane {
    let widget: UnsafeMutablePointer<GtkWidget>
    private(set) var project: XtoolProject
    private(set) var build: PreviewBuild
    private let screen = SimulatorScreen(name: "preview")
    private var picture: UnsafeMutablePointer<GtkWidget> { screen.picture }
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
    private var framePath: String { screen.framePath }
    /// Unsaved text of open files, and the device to simulate.
    var overrides: () -> [URL: String] = { [:] }
    var device: () -> String = { "iphone17promax" }
    var onDiagnostics: ([Diagnostic]) -> Void = { _ in }

    init(project: XtoolProject) {
        self.project = project
        build = PreviewBuild(project: project, lcodeRoot: lcodeRoot)

        selectorModel = gtk_string_list_new(nil)!
        selector = gtk_drop_down_new(cast(raw(selectorModel)), nil)!
        gtk_widget_set_tooltip_text(selector, tr("Preview (#Preview) in This File"))
        darkToggle = gtk_toggle_button_new()!
        gtk_button_set_icon_name(cast(raw(darkToggle)), "weather-clear-night-symbolic")
        gtk_widget_set_tooltip_text(darkToggle, tr("Preview in Dark Mode"))
        let refresh = gtk_button_new_from_icon_name("view-refresh-symbolic")!
        gtk_widget_set_tooltip_text(refresh, tr("Refresh Preview"))
        spinner = gtk_spinner_new()!
        status = gtk_label_new("")!
        gtk_widget_add_css_class(status, "dim-label")
        gtk_label_set_ellipsize(cast(raw(status)), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(status, 1)
        gtk_label_set_xalign(cast(raw(status)), 0)
        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_widget_set_margin_start(bar, 8); gtk_widget_set_margin_end(bar, 8)
        gtk_widget_set_margin_top(bar, 6); gtk_widget_set_margin_bottom(bar, 6)
        let titleLabel = gtk_label_new(tr("Preview"))!
        gtk_widget_add_css_class(titleLabel, "heading")
        gtk_box_append(cast(raw(bar)), titleLabel)
        gtk_box_append(cast(raw(bar)), selector)
        gtk_box_append(cast(raw(bar)), spinner)
        gtk_box_append(cast(raw(bar)), status)
        gtk_box_append(cast(raw(bar)), darkToggle)
        gtk_box_append(cast(raw(bar)), refresh)

        placeholder = gtk_label_new(tr("Open a file that contains a #Preview."))!
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
        gtk_box_append(cast(raw(stack)), screen.picture)
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
        screen.send = { [weak self] in self?.send($0) }
    }

    /// The project changed (packages added…): rebuild the preview.
    func reload(project: XtoolProject) {
        self.project = project
        build = PreviewBuild(project: project, lcodeRoot: lcodeRoot)
        refresh()
    }

    // MARK: - Current file

    func show(_ url: URL?) {
        guard url != currentFile else { return }
        currentFile = url
        refresh()
    }

    /// Debounced: one rebuild per burst of edits.
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
            setPlaceholder(tr("Open a file that contains a #Preview."))
            return
        }
        if building { pending = true; return }
        do {
            entries = try build.prepare(overrides: overrides()).filter { $0.file.standardizedFileURL == file.standardizedFileURL }
        } catch {
            showErrors(tr("Couldn’t prepare the preview: %@", "\(error)"))
            return
        }
        guard !entries.isEmpty else {
            stopServer()
            setPlaceholder(tr("This file has no #Preview.\nAdd one, for example:\n\n#Preview {\n    MyView()\n}"))
            onDiagnostics([])
            return
        }
        updateSelector()
        compile()
    }

    private func updateSelector() {
        let titles = entries.enumerated().map { i, e in e.preview.name ?? (entries.count > 1 ? tr("Preview %d", i + 1) : tr("Preview")) }
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

    // MARK: - Build

    private func compile() {
        building = true
        gtk_spinner_start(cast(raw(spinner)))
        gtk_label_set_text(cast(raw(status)), tr("Building…"))
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
                    let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
                    let text = errors.isEmpty ? tr("Build failed.") + (tail.isEmpty ? "" : "\n" + tail) : errors.prefix(4).map {
                        "\($0.file.lastPathComponent):\($0.line) — \($0.message)"
                    }.joined(separator: "\n")
                    self.showErrors(text)
                    gtk_label_set_text(cast(raw(self.status)), errors.count == 1 ? tr("1 error") : tr("%d errors", errors.count))
                } else {
                    gtk_widget_set_visible(self.banner, 0)
                    gtk_label_set_text(cast(raw(self.status)), tr("Up to date (%.1f s)", Date().timeIntervalSince(started)))
                    self.restartServer()
                }
                if self.pending { self.pending = false; self.refresh() }
            }
        }
        do { try process.run() } catch {
            building = false
            showErrors(tr("swift build not found: %@", "\(error)"))
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

    // MARK: - Preview server

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
        env["LSIM_FRAME_SCALE"] = String(screen.scaleForNewProcess())
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
                if let frame = SimulatorScreen.parseFrame(line) {
                    onMain { self?.screen.load(frame) }
                }
            }
        }
        do {
            try process.run()
            server = process
            serverInput = input.fileHandleForWriting
            gtk_widget_set_visible(placeholder, 0)
        } catch {
            showErrors(tr("Couldn’t launch the preview: %@", "\(error)"))
        }
    }

    func stopServer() {
        try? serverInput?.write(contentsOf: Data("quit\n".utf8))
        server?.terminate()
        server = nil
        serverInput = nil
    }

    private func send(_ command: String) {
        try? serverInput?.write(contentsOf: Data((command + "\n").utf8))
    }
}
