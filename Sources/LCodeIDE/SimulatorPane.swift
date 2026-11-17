import CAdw
import Foundation

/// Simulateur intégré à la fenêtre (comme celui d'Xcode) : l'app lancée par Ctrl+R s'affiche ici, au doigt
/// (souris), molette et mode sombre ; sa sortie va dans la console « Sortie de l'app ».
final class SimulatorPane {
    let widget: UnsafeMutablePointer<GtkWidget>
    let screen = SimulatorScreen(name: "simulateur")
    private let title: UnsafeMutablePointer<GtkWidget>
    private let status: UnsafeMutablePointer<GtkWidget>
    private let spinner: UnsafeMutablePointer<GtkWidget>
    private let placeholder: UnsafeMutablePointer<GtkWidget>
    private let darkToggle: UnsafeMutablePointer<GtkWidget>
    private var syncing = false
    /// Commande envoyée à l'app (gestes, apparence).
    var send: (String) -> Void = { _ in } {
        didSet { screen.send = send }
    }

    init() {
        title = gtk_label_new("Simulateur")!
        gtk_widget_add_css_class(title, "heading")
        spinner = gtk_spinner_new()!
        status = gtk_label_new("")!
        gtk_widget_add_css_class(status, "dim-label")
        gtk_label_set_ellipsize(cast(raw(status)), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(cast(raw(status)), 0)
        gtk_widget_set_hexpand(status, 1)
        darkToggle = gtk_toggle_button_new()!
        gtk_button_set_icon_name(cast(raw(darkToggle)), "weather-clear-night-symbolic")
        gtk_widget_set_tooltip_text(darkToggle, "Mode sombre")
        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_widget_set_margin_start(bar, 8); gtk_widget_set_margin_end(bar, 8)
        gtk_widget_set_margin_top(bar, 6); gtk_widget_set_margin_bottom(bar, 6)
        gtk_box_append(cast(raw(bar)), title)
        gtk_box_append(cast(raw(bar)), spinner)
        gtk_box_append(cast(raw(bar)), status)
        gtk_box_append(cast(raw(bar)), darkToggle)

        placeholder = gtk_label_new("")!
        gtk_widget_add_css_class(placeholder, "dim-label")
        gtk_label_set_wrap(cast(raw(placeholder)), 1)
        gtk_label_set_justify(cast(raw(placeholder)), GTK_JUSTIFY_CENTER)
        gtk_widget_set_halign(placeholder, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(placeholder, GTK_ALIGN_CENTER)
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(cast(raw(overlay)), screen.picture)
        gtk_overlay_add_overlay(cast(raw(overlay)), placeholder)
        gtk_widget_set_vexpand(overlay, 1)

        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_add_css_class(widget, "lcode-preview")
        gtk_widget_set_size_request(widget, 340, -1)
        gtk_box_append(cast(raw(widget)), bar)
        gtk_box_append(cast(raw(widget)), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        gtk_box_append(cast(raw(widget)), overlay)

        connect(raw(darkToggle), "toggled") { [weak self] in
            guard let self, !self.syncing else { return }
            self.send("scheme \(gtk_toggle_button_get_active(cast(raw(self.darkToggle))) != 0 ? "dark" : "light")")
        }
    }

    /// Nouvel état de l'exécution.
    func update(_ state: Runner.State, device: String, dark: Bool) {
        gtk_label_set_text(cast(raw(status)), device)
        switch state {
        case .building:
            gtk_spinner_start(cast(raw(spinner)))
            gtk_widget_set_opacity(screen.picture, 0.45)
            if gtk_picture_get_paintable(cast(raw(screen.picture))) == nil { message("Compilation…") }
        case .running:
            gtk_spinner_stop(cast(raw(spinner)))
            gtk_widget_set_visible(placeholder, 0)
            // Apparence de départ de l'app (sans renvoyer de commande).
            syncing = true
            gtk_toggle_button_set_active(cast(raw(darkToggle)), dark ? 1 : 0)
            syncing = false
        case .failed:
            gtk_spinner_stop(cast(raw(spinner)))
            screen.clear()
            message("La compilation a échoué : voir l'onglet Problèmes.")
        case .idle:
            gtk_spinner_stop(cast(raw(spinner)))
            screen.clear()
            message("Lancez l'app avec ▶ ou Ctrl+R.")
        }
    }

    private func message(_ text: String) {
        gtk_label_set_text(cast(raw(placeholder)), text)
        gtk_widget_set_visible(placeholder, 1)
    }
}
