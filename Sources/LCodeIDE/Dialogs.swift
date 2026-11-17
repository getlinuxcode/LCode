import CAdw
import Foundation

/// Boîtes de dialogue libadwaita : saisie, confirmation, choix de dossier ou de fichier.
enum Dialogs {
    /// Demande du texte (nom de fichier, de dossier…). `completion` reçoit nil si l'utilisateur annule.
    static func prompt(_ parent: UnsafeMutablePointer<GtkWidget>, title: String, message: String = "", placeholder: String = "",
                       initial: String = "", confirm: String = "Créer", completion: @escaping (String?) -> Void) {
        let dialog = adw_alert_dialog_new(title, message.isEmpty ? nil : message)!
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(cast(raw(entry)), placeholder)
        gtk_editable_set_text(OpaquePointer(entry), initial)
        gtk_entry_set_activates_default(cast(raw(entry)), 1)
        adw_alert_dialog_set_extra_child(cast(raw(dialog)), entry)
        adw_alert_dialog_add_response(cast(raw(dialog)), "cancel", "Annuler")
        adw_alert_dialog_add_response(cast(raw(dialog)), "ok", confirm)
        adw_alert_dialog_set_response_appearance(cast(raw(dialog)), "ok", ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_default_response(cast(raw(dialog)), "ok")
        adw_alert_dialog_set_close_response(cast(raw(dialog)), "cancel")
        connectArg(raw(dialog), "response") { response in
            let id = response.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "cancel"
            let text = String(cString: gtk_editable_get_text(OpaquePointer(entry)))
            completion(id == "ok" && !text.trimmingCharacters(in: .whitespaces).isEmpty ? text : nil)
        }
        adw_dialog_present(cast(raw(dialog)), parent)
        gtk_widget_grab_focus(entry)
    }

    /// Confirmation (action destructive en rouge).
    static func confirm(_ parent: UnsafeMutablePointer<GtkWidget>, title: String, message: String, action: String,
                        destructive: Bool = true, completion: @escaping (Bool) -> Void) {
        let dialog = adw_alert_dialog_new(title, message)!
        adw_alert_dialog_add_response(cast(raw(dialog)), "cancel", "Annuler")
        adw_alert_dialog_add_response(cast(raw(dialog)), "ok", action)
        adw_alert_dialog_set_response_appearance(cast(raw(dialog)), "ok", destructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_close_response(cast(raw(dialog)), "cancel")
        connectArg(raw(dialog), "response") { response in
            completion(response.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } == "ok")
        }
        adw_dialog_present(cast(raw(dialog)), parent)
    }

    static func message(_ parent: UnsafeMutablePointer<GtkWidget>, title: String, message: String) {
        let dialog = adw_alert_dialog_new(title, message)!
        adw_alert_dialog_add_response(cast(raw(dialog)), "ok", "OK")
        adw_dialog_present(cast(raw(dialog)), parent)
    }

    /// Choix d'un dossier (sélecteur natif de GTK).
    static func chooseFolder(_ parent: UnsafeMutablePointer<GtkWidget>, title: String, completion: @escaping (URL?) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        let box = Unmanaged.passRetained(CompletionBox(completion)).toOpaque()
        let callback: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { source, result, data in
            let box = Unmanaged<CompletionBox>.fromOpaque(data!).takeRetainedValue()
            var error: UnsafeMutablePointer<GError>?
            let file = gtk_file_dialog_select_folder_finish(OpaquePointer(source), result, &error)
            if let error { g_error_free(error) }
            box.completion(file.flatMap { g_file_get_path($0) }.map { p in defer { g_free(p) }; return URL(fileURLWithPath: String(cString: p)) })
        }
        gtk_file_dialog_select_folder(dialog, cast(raw(parent)), nil, callback, box)
    }

    /// Choix d'un fichier (image pour les assets…).
    static func chooseFile(_ parent: UnsafeMutablePointer<GtkWidget>, title: String, completion: @escaping (URL?) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        let box = Unmanaged.passRetained(CompletionBox(completion)).toOpaque()
        let callback: @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { source, result, data in
            let box = Unmanaged<CompletionBox>.fromOpaque(data!).takeRetainedValue()
            var error: UnsafeMutablePointer<GError>?
            let file = gtk_file_dialog_open_finish(OpaquePointer(source), result, &error)
            if let error { g_error_free(error) }
            box.completion(file.flatMap { g_file_get_path($0) }.map { p in defer { g_free(p) }; return URL(fileURLWithPath: String(cString: p)) })
        }
        gtk_file_dialog_open(dialog, cast(raw(parent)), nil, callback, box)
    }

    private final class CompletionBox {
        let completion: (URL?) -> Void
        init(_ c: @escaping (URL?) -> Void) { completion = c }
    }
}
