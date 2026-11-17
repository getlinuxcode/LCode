import CAdw
import Foundation
import LCodeKit

/// Paquets du projet (comme « Package Dependencies » d'Xcode) : liste, ajout par URL (dernière version par
/// défaut), retrait. Le Package.swift est modifié par SwiftPM ; le simulateur et les aperçus suivent.
final class PackagesDialog {
    private weak var window: ProjectWindow?
    private let dialog: UnsafeMutablePointer<AdwDialog>
    private let list: UnsafeMutablePointer<GtkWidget>
    private let urlEntry: UnsafeMutablePointer<GtkWidget>
    private let versionEntry: UnsafeMutablePointer<GtkWidget>
    private let addButton: UnsafeMutablePointer<GtkWidget>
    private let spinner: UnsafeMutablePointer<GtkWidget>
    private let status: UnsafeMutablePointer<GtkWidget>
    private static var open: PackagesDialog?

    static func present(for window: ProjectWindow) {
        let d = PackagesDialog(window: window)
        open = d
        adw_dialog_present(d.dialog, window.window)
    }

    private init(window: ProjectWindow) {
        self.window = window
        dialog = cast(raw(adw_dialog_new()!))
        adw_dialog_set_title(dialog, "Paquets")
        adw_dialog_set_content_width(dialog, 560)
        adw_dialog_set_content_height(dialog, 520)

        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14)!
        gtk_widget_set_margin_start(content, 20); gtk_widget_set_margin_end(content, 20)
        gtk_widget_set_margin_top(content, 12); gtk_widget_set_margin_bottom(content, 20)

        let current = gtk_label_new("Dépendances du projet")!
        gtk_widget_add_css_class(current, "heading")
        gtk_label_set_xalign(cast(raw(current)), 0)
        list = gtk_list_box_new()!
        gtk_widget_add_css_class(list, "boxed-list")
        gtk_list_box_set_selection_mode(cast(raw(list)), GTK_SELECTION_NONE)

        let addTitle = gtk_label_new("Ajouter un paquet")!
        gtk_widget_add_css_class(addTitle, "heading")
        gtk_label_set_xalign(cast(raw(addTitle)), 0)
        urlEntry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(cast(raw(urlEntry)), "URL du dépôt (ex. : https://github.com/apple/swift-algorithms)")
        versionEntry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(cast(raw(versionEntry)), "Version minimale (vide : la dernière)")
        gtk_widget_set_hexpand(versionEntry, 1)
        addButton = gtk_button_new_with_label("Ajouter")!
        gtk_widget_add_css_class(addButton, "suggested-action")
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(cast(raw(row)), versionEntry)
        gtk_box_append(cast(raw(row)), addButton)
        spinner = gtk_spinner_new()!
        status = gtk_label_new("")!
        gtk_widget_add_css_class(status, "dim-label")
        gtk_label_set_wrap(cast(raw(status)), 1)
        gtk_label_set_xalign(cast(raw(status)), 0)
        gtk_widget_set_hexpand(status, 1)
        let statusRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(cast(raw(statusRow)), spinner)
        gtk_box_append(cast(raw(statusRow)), status)
        let note = gtk_label_new("Dans le simulateur, les paquets en Swift pur sont repris tels quels ; ceux qui importent SwiftUI utilisent l'API de LSim. Ceux qui dépendent d'UIKit ne sont pas encore pris en charge.")!
        gtk_widget_add_css_class(note, "dim-label")
        gtk_widget_add_css_class(note, "caption")
        gtk_label_set_wrap(cast(raw(note)), 1)
        gtk_label_set_xalign(cast(raw(note)), 0)

        for w in [current, list, addTitle, urlEntry, row, statusRow, note] { gtk_box_append(cast(raw(content)), w) }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(raw(scroller)), content)
        gtk_widget_set_vexpand(scroller, 1)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(raw(toolbar)), adw_header_bar_new())
        adw_toolbar_view_set_content(cast(raw(toolbar)), scroller)
        adw_dialog_set_child(dialog, toolbar)

        connect(raw(addButton), "clicked") { [weak self] in self?.add() }
        connect(raw(urlEntry), "activate") { [weak self] in self?.add() }
        connect(raw(dialog), "closed") { PackagesDialog.open = nil }
        reloadList()
    }

    // MARK: - Liste

    private func reloadList() {
        while let child = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(raw(list)), child) }
        guard let project = window?.project else { return }
        if project.dependencies.isEmpty {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(cast(raw(row)), "Aucun paquet")
            gtk_list_box_append(cast(raw(list)), row)
        }
        let products = project.targets.flatMap(\.externalProducts)
        for dep in project.dependencies {
            let row = adw_action_row_new()!
            // Texte brut : les versions contiennent « ..< », que le balisage Pango refuserait.
            adw_preferences_row_set_use_markup(cast(raw(row)), 0)
            adw_preferences_row_set_title(cast(raw(row)), dep.identity)
            let used = products.filter { ($0.package ?? "").lowercased() == dep.identity }.map(\.name)
            var subtitle: String
            switch dep.source {
            case let .local(path): subtitle = "Local — \(path)"
            case let .remote(url, requirement):
                switch requirement {
                case let .range(lower, upper): subtitle = "\(url) — \(lower) ..< \(upper)"
                case let .exact(v): subtitle = "\(url) — \(v)"
                case let .branch(b): subtitle = "\(url) — branche \(b)"
                case let .revision(r): subtitle = "\(url) — révision \(r.prefix(8))"
                }
            }
            if !used.isEmpty { subtitle += "\nProduits : " + used.joined(separator: ", ") }
            adw_action_row_set_subtitle(cast(raw(row)), subtitle)
            let remove = gtk_button_new_from_icon_name("user-trash-symbolic")!
            gtk_widget_add_css_class(remove, "flat")
            gtk_widget_set_valign(remove, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(remove, "Retirer du projet")
            let identity = dep.identity
            connect(raw(remove), "clicked") { [weak self] in self?.remove(identity) }
            adw_action_row_add_suffix(cast(raw(row)), remove)
            gtk_list_box_append(cast(raw(list)), row)
        }
    }

    // MARK: - Actions (en arrière-plan : réseau, SwiftPM)

    private func busy(_ text: String?) {
        gtk_label_set_text(cast(raw(status)), text ?? "")
        if text != nil { gtk_spinner_start(cast(raw(spinner))) } else { gtk_spinner_stop(cast(raw(spinner))) }
        gtk_widget_set_sensitive(addButton, text == nil ? 1 : 0)
    }

    private func add() {
        guard let window else { return }
        let url = String(cString: gtk_editable_get_text(OpaquePointer(urlEntry))).trimmingCharacters(in: .whitespaces)
        var version = String(cString: gtk_editable_get_text(OpaquePointer(versionEntry))).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let root = window.project.root, target = window.project.appTarget
        busy(version.isEmpty ? "Recherche de la dernière version…" : "Ajout de \(url)…")
        Thread.detachNewThread { [weak self] in
            do {
                if version.isEmpty {
                    guard let latest = try PackageManager.latestVersion(of: url) else {
                        throw LCodeError("Aucune version publiée (étiquette x.y.z) dans ce dépôt : indiquez-en une.")
                    }
                    version = latest
                }
                onMain { self?.busy("Ajout de \(PackageManager.identity(of: url)) \(version) et résolution…") }
                let products = try PackageManager.addDependency(url: url, from: version, to: root)
                onMain {
                    self?.chooseProduct(products, package: PackageManager.identity(of: url)) { product in
                        guard let product else { self?.finished("Paquet ajouté, sans produit utilisé par l'app."); return }
                        Thread.detachNewThread {
                            do {
                                try PackageManager.addProduct(product, package: PackageManager.identity(of: url), target: target, root: root)
                                onMain { self?.finished("\(product) \(version) ajouté : « import \(product) » dans votre code.") }
                            } catch {
                                onMain { self?.failed(error) }
                            }
                        }
                    }
                }
            } catch {
                onMain { self?.failed(error) }
            }
        }
    }

    /// Produit à utiliser : le seul, ou au choix s'il y en a plusieurs.
    private func chooseProduct(_ products: [String], package: String, _ completion: @escaping (String?) -> Void) {
        guard products.count > 1, let window else { completion(products.first); return }
        let choice = adw_alert_dialog_new("Produit à utiliser", "Le paquet \(package) fournit plusieurs bibliothèques.")!
        for p in products.prefix(6) { adw_alert_dialog_add_response(cast(raw(choice)), p, p) }
        adw_alert_dialog_add_response(cast(raw(choice)), "__aucun", "Aucun")
        adw_alert_dialog_set_close_response(cast(raw(choice)), "__aucun")
        connectArg(raw(choice), "response") { response in
            let id = response.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "__aucun"
            completion(id == "__aucun" ? nil : id)
        }
        adw_dialog_present(cast(raw(choice)), window.window)
    }

    private func remove(_ identity: String) {
        guard let window else { return }
        Dialogs.confirm(window.window, title: "Retirer « \(identity) » ?",
                        message: "Sa déclaration et ses produits seront retirés de Package.swift.", action: "Retirer") { [weak self] ok in
            guard ok, let self, let window = self.window else { return }
            do {
                try PackageManager.removeDependency(identity: identity, root: window.project.root)
                self.finished("\(identity) retiré.")
            } catch {
                self.failed(error)
            }
        }
    }

    private func finished(_ message: String) {
        gtk_editable_set_text(OpaquePointer(urlEntry), "")
        gtk_editable_set_text(OpaquePointer(versionEntry), "")
        busy("Rechargement du projet…")
        window?.reloadProject { [weak self] in
            guard let self else { return }
            self.busy(nil)
            gtk_label_set_text(cast(raw(self.status)), message)
            self.reloadList()
        }
    }

    private func failed(_ error: Error) {
        busy(nil)
        gtk_label_set_text(cast(raw(status)), "✗ \(error)")
    }
}
