import CAdw
import Foundation

/// Éditeur de catalogue d'assets (Assets.xcassets, format Xcode) : images, couleurs, icône de l'app.
final class AssetEditor {
    let catalog: URL
    let widget: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private weak var window: ProjectWindow?

    init(catalog: URL, window: ProjectWindow) {
        self.catalog = catalog
        self.window = window
        widget = gtk_scrolled_window_new()!
        list = gtk_list_box_new()!
        gtk_widget_add_css_class(list, "boxed-list")
        gtk_list_box_set_selection_mode(cast(raw(list)), GTK_SELECTION_NONE)

        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        func button(_ label: String, _ icon: String, _ action: @escaping () -> Void) {
            let b = gtk_button_new()!
            let content = adw_button_content_new()!
            adw_button_content_set_label(cast(raw(content)), label)
            adw_button_content_set_icon_name(cast(raw(content)), icon)
            gtk_button_set_child(cast(raw(b)), content)
            connect(raw(b), "clicked", action)
            gtk_box_append(cast(raw(bar)), b)
        }
        let title = gtk_label_new(catalog.lastPathComponent)!
        gtk_widget_add_css_class(title, "title-3")
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_xalign(cast(raw(title)), 0)
        gtk_box_append(cast(raw(bar)), title)
        button("Image…", "image-x-generic-symbolic") { [weak self] in self?.addImage() }
        button("Couleur…", "applications-graphics-symbolic") { [weak self] in self?.addColor() }
        button("Icône de l'app…", "starred-symbolic") { [weak self] in self?.setAppIcon() }

        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16)!
        gtk_widget_set_margin_start(content, 24); gtk_widget_set_margin_end(content, 24)
        gtk_widget_set_margin_top(content, 20); gtk_widget_set_margin_bottom(content, 20)
        gtk_box_append(cast(raw(content)), bar)
        gtk_box_append(cast(raw(content)), list)
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(cast(raw(clamp)), 760)
        adw_clamp_set_child(cast(raw(clamp)), content)
        gtk_scrolled_window_set_child(cast(raw(widget)), clamp)
        gtk_widget_set_vexpand(widget, 1)
        reload()
    }

    // MARK: - Contenu

    func reload() {
        while let child = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(raw(list)), child) }
        let fm = FileManager.default
        let sets = ((try? fm.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["imageset", "colorset", "appiconset"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for set in sets {
            let row = adw_action_row_new()!
            let name = set.deletingPathExtension().lastPathComponent
            adw_preferences_row_set_title(cast(raw(row)), name)
            let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: set.appendingPathComponent("Contents.json")))) as? [String: Any]
            switch set.pathExtension {
            case "imageset", "appiconset":
                let images = (json?["images"] as? [[String: Any]]) ?? []
                let file = images.compactMap { $0["filename"] as? String }.first
                adw_action_row_set_subtitle(cast(raw(row)), set.pathExtension == "appiconset"
                    ? (file == nil ? "Icône de l'app — aucune image (1024 × 1024 attendue)" : "Icône de l'app — \(file!)")
                    : "Image — \(file ?? "aucun fichier")")
                if let file {
                    let image = gtk_picture_new_for_filename(set.appendingPathComponent(file).path)!
                    gtk_picture_set_content_fit(cast(raw(image)), GTK_CONTENT_FIT_CONTAIN)
                    gtk_widget_set_size_request(image, 48, 48)
                    adw_action_row_add_prefix(cast(raw(row)), image)
                } else {
                    adw_action_row_add_prefix(cast(raw(row)), gtk_image_new_from_icon_name("image-missing-symbolic"))
                }
            default:
                let swatch = gtk_drawing_area_new()!
                gtk_widget_set_size_request(swatch, 48, 32)
                let (r, g, b, a) = Self.color(json)
                adw_action_row_set_subtitle(cast(raw(row)), r == nil ? "Couleur — système (non définie)"
                    : String(format: "Couleur — #%02X%02X%02X, opacité %.0f %%", Int(r! * 255), Int(g * 255), Int(b * 255), a * 100))
                let css = r == nil ? "background: linear-gradient(135deg, #888, #ccc);"
                    : String(format: "background: rgba(%d,%d,%d,%.2f);", Int(r! * 255), Int(g * 255), Int(b * 255), a)
                let provider = gtk_css_provider_new()!
                gtk_css_provider_load_from_string(provider, "drawingarea { \(css) border-radius: 6px; }")
                gtk_style_context_add_provider(gtk_widget_get_style_context(swatch), OpaquePointer(provider), 800)
                adw_action_row_add_prefix(cast(raw(row)), swatch)
            }
            let remove = gtk_button_new_from_icon_name("user-trash-symbolic")!
            gtk_widget_add_css_class(remove, "flat")
            gtk_widget_set_valign(remove, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(remove, "Mettre à la corbeille")
            connect(raw(remove), "clicked") { [weak self] in self?.remove(set) }
            adw_action_row_add_suffix(cast(raw(row)), remove)
            gtk_list_box_append(cast(raw(list)), row)
        }
    }

    private static func color(_ json: [String: Any]?) -> (Double?, Double, Double, Double) {
        guard let colors = json?["colors"] as? [[String: Any]], let c = colors.first?["color"] as? [String: Any],
              let comps = c["components"] as? [String: String] else { return (nil, 0, 0, 1) }
        func v(_ k: String) -> Double {
            let s = comps[k] ?? "0"
            if s.hasPrefix("0x") { return Double(Int(s.dropFirst(2), radix: 16) ?? 0) / 255 }
            let d = Double(s) ?? 0
            return d > 1 ? d / 255 : d
        }
        return (v("red"), v("green"), v("blue"), Double(comps["alpha"] ?? "1") ?? 1)
    }

    // MARK: - Ajouts

    private func addImage() {
        guard let parent = window?.window else { return }
        Dialogs.chooseFile(parent, title: "Image à ajouter (PNG, JPEG, SVG, PDF)") { [weak self] file in
            guard let self, let file else { return }
            let defaultName = file.deletingPathExtension().lastPathComponent
            Dialogs.prompt(parent, title: "Nom de l'image", message: "Utilisé dans le code : Image(\"nom\")",
                           initial: defaultName, confirm: "Ajouter") { name in
                guard let name else { return }
                let set = self.catalog.appendingPathComponent("\(name).imageset")
                do {
                    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file, to: set.appendingPathComponent(file.lastPathComponent))
                    let contents: [String: Any] = [
                        "images": [["idiom": "universal", "filename": file.lastPathComponent]],
                        "info": ["author": "xcode", "version": 1],
                    ]
                    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
                        .write(to: set.appendingPathComponent("Contents.json"))
                    self.reload()
                } catch {
                    Dialogs.message(parent, title: "Ajout impossible", message: "\(error)")
                }
            }
        }
    }

    private func addColor() {
        guard let parent = window?.window else { return }
        let dialog = adw_alert_dialog_new("Nouvelle couleur", "Utilisée dans le code : Color(\"nom\")")!
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(cast(raw(entry)), "Nom (ex. : Marque)")
        let colorButton = gtk_color_dialog_button_new(gtk_color_dialog_new())!
        gtk_box_append(cast(raw(box)), entry)
        gtk_box_append(cast(raw(box)), colorButton)
        adw_alert_dialog_set_extra_child(cast(raw(dialog)), box)
        adw_alert_dialog_add_response(cast(raw(dialog)), "cancel", "Annuler")
        adw_alert_dialog_add_response(cast(raw(dialog)), "ok", "Ajouter")
        adw_alert_dialog_set_response_appearance(cast(raw(dialog)), "ok", ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_close_response(cast(raw(dialog)), "cancel")
        connectArg(raw(dialog), "response") { [weak self] response in
            guard let self, response.map({ String(cString: $0.assumingMemoryBound(to: CChar.self)) }) == "ok" else { return }
            let name = String(cString: gtk_editable_get_text(OpaquePointer(entry))).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let rgba = gtk_color_dialog_button_get_rgba(cast(raw(colorButton))) else { return }
            let set = self.catalog.appendingPathComponent("\(name).colorset")
            let components = ["red": String(format: "%.3f", rgba.pointee.red), "green": String(format: "%.3f", rgba.pointee.green),
                              "blue": String(format: "%.3f", rgba.pointee.blue), "alpha": String(format: "%.3f", rgba.pointee.alpha)]
            let contents: [String: Any] = [
                "colors": [["idiom": "universal", "color": ["color-space": "srgb", "components": components]]],
                "info": ["author": "xcode", "version": 1],
            ]
            do {
                try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
                    .write(to: set.appendingPathComponent("Contents.json"))
                self.reload()
            } catch {
                Dialogs.message(parent, title: "Ajout impossible", message: "\(error)")
            }
        }
        adw_dialog_present(cast(raw(dialog)), parent)
    }

    private func setAppIcon() {
        guard let parent = window?.window else { return }
        Dialogs.chooseFile(parent, title: "Icône de l'app (PNG 1024 × 1024)") { [weak self] file in
            guard let self, let file else { return }
            let set = self.catalog.appendingPathComponent("AppIcon.appiconset")
            do {
                try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
                let target = set.appendingPathComponent("AppIcon-1024.png")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: file, to: target)
                let contents: [String: Any] = [
                    "images": [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "AppIcon-1024.png"]],
                    "info": ["author": "xcode", "version": 1],
                ]
                try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
                    .write(to: set.appendingPathComponent("Contents.json"))
                self.reload()
            } catch {
                Dialogs.message(parent, title: "Icône impossible à définir", message: "\(error)")
            }
        }
    }

    private func remove(_ set: URL) {
        guard let parent = window?.window else { return }
        Dialogs.confirm(parent, title: "Mettre « \(set.deletingPathExtension().lastPathComponent) » à la corbeille ?",
                        message: "L'asset et ses fichiers iront à la corbeille.", action: "Mettre à la corbeille") { [weak self] ok in
            guard ok else { return }
            let file = g_file_new_for_path(set.path)
            g_file_trash(file, nil, nil)
            g_object_unref(UnsafeMutableRawPointer(file))
            self?.reload()
        }
    }
}
