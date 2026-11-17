import CAdw
import Foundation
import LCodeKit

/// Compte Apple utilisé pour signer (comme Réglages › Comptes d'Xcode), via `xtool auth`.
///
/// LCode ne demande ni ne stocke jamais de mot de passe : la connexion par Apple ID s'ouvre dans un terminal
/// où l'utilisateur tape lui-même mot de passe et code de validation ; la connexion par clé API App Store
/// Connect transmet à xtool l'identifiant de la clé, l'émetteur et le chemin du fichier .p8, qu'xtool lit seul.
final class AccountDialog {
    private let dialog: UnsafeMutablePointer<AdwDialog>
    private let statusGroup: UnsafeMutablePointer<GtkWidget>
    private var statusRows: [UnsafeMutablePointer<GtkWidget>] = []
    private let keyID: UnsafeMutablePointer<GtkWidget>
    private let issuerID: UnsafeMutablePointer<GtkWidget>
    private let keyFileRow: UnsafeMutablePointer<GtkWidget>
    private var keyFile: URL?
    private let keyLogin: UnsafeMutablePointer<GtkWidget>
    private let passwordLogin: UnsafeMutablePointer<GtkWidget>
    private let logout: UnsafeMutablePointer<GtkWidget>
    private let spinner: UnsafeMutablePointer<GtkWidget>
    private let message: UnsafeMutablePointer<GtkWidget>
    private let onChange: () -> Void
    private var account: AppleAccount?
    private static var open: AccountDialog?

    /// `onChange` : appelé après chaque connexion ou déconnexion (pour rafraîchir la page de signature).
    static func present(from parent: UnsafeMutablePointer<GtkWidget>, onChange: @escaping () -> Void = {}) {
        let d = AccountDialog(onChange: onChange)
        open = d
        adw_dialog_present(d.dialog, parent)
    }

    private init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        dialog = cast(raw(adw_dialog_new()!))
        adw_dialog_set_title(dialog, "Compte Apple")
        adw_dialog_set_content_width(dialog, 580)
        adw_dialog_set_content_height(dialog, 680)

        let page = adw_preferences_page_new()!

        statusGroup = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(raw(statusGroup)), "Compte")
        adw_preferences_group_set_description(cast(raw(statusGroup)),
            "xtool signe et installe les apps avec ce compte. Les identifiants restent dans le trousseau d'xtool.")
        spinner = gtk_spinner_new()!
        adw_preferences_group_set_header_suffix(cast(raw(statusGroup)), spinner)
        adw_preferences_page_add(cast(raw(page)), cast(raw(statusGroup)))

        // Clé API App Store Connect (programme payant).
        let keyGroup = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(raw(keyGroup)), "Connexion par clé API App Store Connect")
        adw_preferences_group_set_description(cast(raw(keyGroup)),
            "Recommandée avec un compte payant. Créez la clé dans App Store Connect › Utilisateurs et accès › Intégrations ; "
            + "xtool lit le fichier .p8 lui-même, LCode n'en copie ni n'en affiche le contenu.")
        keyFileRow = adw_action_row_new()!
        adw_preferences_row_set_title(cast(raw(keyFileRow)), "Fichier de clé (.p8)")
        adw_action_row_set_subtitle(cast(raw(keyFileRow)), "Aucun fichier choisi")
        let choose = gtk_button_new_with_label("Choisir…")!
        gtk_widget_set_valign(choose, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(cast(raw(keyFileRow)), choose)
        keyID = adw_entry_row_new()!
        adw_preferences_row_set_title(cast(raw(keyID)), "Identifiant de la clé (Key ID)")
        issuerID = adw_entry_row_new()!
        adw_preferences_row_set_title(cast(raw(issuerID)), "Identifiant de l'émetteur (Issuer ID)")
        for row in [keyFileRow, keyID, issuerID] { adw_preferences_group_add(cast(raw(keyGroup)), row) }
        keyLogin = gtk_button_new_with_label("Se connecter avec la clé")!
        gtk_widget_add_css_class(keyLogin, "suggested-action")
        gtk_widget_set_halign(keyLogin, GTK_ALIGN_END)
        gtk_widget_set_margin_top(keyLogin, 10)
        adw_preferences_group_add(cast(raw(keyGroup)), keyLogin)
        adw_preferences_page_add(cast(raw(page)), cast(raw(keyGroup)))

        // Apple ID (tout compte, gratuit compris) : dans un terminal.
        let passwordGroup = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(raw(passwordGroup)), "Connexion par Apple ID")
        adw_preferences_group_set_description(cast(raw(passwordGroup)),
            "Fonctionne avec un compte gratuit (apps valables 7 jours). xtool s'ouvre dans un terminal : "
            + "tapez-y votre Apple ID, votre mot de passe et le code de validation, puis choisissez l'équipe. "
            + "Pour changer d'équipe, reconnectez-vous de la même façon.")
        passwordLogin = gtk_button_new_with_label("Se connecter dans un terminal…")!
        gtk_widget_set_halign(passwordLogin, GTK_ALIGN_END)
        adw_preferences_group_add(cast(raw(passwordGroup)), passwordLogin)
        adw_preferences_page_add(cast(raw(page)), cast(raw(passwordGroup)))

        let bottom = adw_preferences_group_new()!
        message = gtk_label_new("")!
        gtk_label_set_wrap(cast(raw(message)), 1)
        gtk_label_set_xalign(cast(raw(message)), 0)
        gtk_label_set_selectable(cast(raw(message)), 1)
        gtk_widget_add_css_class(message, "dim-label")
        adw_preferences_group_add(cast(raw(bottom)), message)
        logout = gtk_button_new_with_label("Se déconnecter")!
        gtk_widget_add_css_class(logout, "destructive-action")
        gtk_widget_set_halign(logout, GTK_ALIGN_START)
        gtk_widget_set_margin_top(logout, 8)
        adw_preferences_group_add(cast(raw(bottom)), logout)
        adw_preferences_page_add(cast(raw(page)), cast(raw(bottom)))

        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        let refreshButton = gtk_button_new_from_icon_name("view-refresh-symbolic")!
        gtk_widget_set_tooltip_text(refreshButton, "Actualiser l'état")
        adw_header_bar_pack_start(cast(raw(header)), refreshButton)
        adw_toolbar_view_add_top_bar(cast(raw(toolbar)), header)
        adw_toolbar_view_set_content(cast(raw(toolbar)), page)
        adw_dialog_set_child(dialog, toolbar)

        connect(raw(choose), "clicked") { [weak self] in self?.chooseKey() }
        connect(raw(keyLogin), "clicked") { [weak self] in self?.logInWithKey() }
        connect(raw(passwordLogin), "clicked") { [weak self] in self?.logInInTerminal() }
        connect(raw(logout), "clicked") { [weak self] in self?.confirmLogout() }
        connect(raw(refreshButton), "clicked") { [weak self] in self?.refresh() }
        connect(raw(dialog), "closed") { AccountDialog.open = nil }
        refresh()
    }

    // MARK: - État

    private func busy(_ text: String?) {
        if text != nil { gtk_spinner_start(cast(raw(spinner))) } else { gtk_spinner_stop(cast(raw(spinner))) }
        if let text { gtk_label_set_text(cast(raw(message)), text) }
        for b in [keyLogin, passwordLogin, logout] { gtk_widget_set_sensitive(b, text == nil ? 1 : 0) }
    }

    private func refresh() {
        busy("Lecture de l'état d'xtool…")
        Thread.detachNewThread { [weak self] in
            let account = AppleAccount.current()
            let teams = account?.mode == .appleID ? AppleAccount.teams() : []
            onMain {
                guard let self else { return }
                self.busy(nil)
                gtk_label_set_text(cast(raw(self.message)), "")
                self.show(account, teams: teams)
            }
        }
    }

    private func show(_ account: AppleAccount?, teams: [AppleAccount.Team]) {
        self.account = account
        for r in statusRows { adw_preferences_group_remove(cast(raw(statusGroup)), r) }
        statusRows = []
        func row(_ title: String, _ value: String, icon: String? = nil) {
            let r = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(raw(r)), 0)
            adw_preferences_row_set_title(cast(raw(r)), title)
            adw_action_row_set_subtitle(cast(raw(r)), value)
            adw_action_row_set_subtitle_selectable(cast(raw(r)), 1)
            if let icon { adw_action_row_add_prefix(cast(raw(r)), gtk_image_new_from_icon_name(icon)) }
            adw_preferences_group_add(cast(raw(statusGroup)), r)
            statusRows.append(r)
        }
        guard let account else {
            row("État", "Non connecté : connectez-vous ci-dessous pour installer sur un iPhone.", icon: "dialog-warning-symbolic")
            gtk_widget_set_visible(logout, 0)
            return
        }
        gtk_widget_set_visible(logout, 1)
        switch account.mode {
        case .apiKey:
            row("État", "Connecté avec une clé API App Store Connect", icon: "emblem-ok-symbolic")
            row("Clé", account.keyID ?? "—")
            row("Émetteur", account.issuerID ?? "—")
            row("Type de compte", "Apple Developer Program (payant)")
            row("Équipe", "Celle de la clé API (fixée par App Store Connect)")
        case .appleID:
            row("État", "Connecté avec un Apple ID", icon: "emblem-ok-symbolic")
            row("Apple ID", account.appleID ?? "—")
            let team = teams.first { $0.id == account.teamID }
            row("Équipe", team.map { "\($0.name) (\($0.id))" } ?? account.teamID ?? "—")
            row("Type de compte", team.map { $0.isFree ? "Gratuit (Personal Team) — apps valables 7 jours" :
                    ($0.memberships.first ?? "Apple Developer Program") } ?? "Inconnu (équipes injoignables)")
            if teams.count > 1 {
                row("Autres équipes", teams.filter { $0.id != account.teamID }.map { "\($0.name) (\($0.id))" }.joined(separator: "\n"))
            }
            if let expiry = account.expiry { row("Session valable jusqu'au", expiry) }
        }
    }

    // MARK: - Clé API

    private func chooseKey() {
        guard let parent = gtk_widget_get_root(cast(raw(dialog))) else { return }
        Dialogs.chooseFile(cast(raw(parent)), title: "Clé API App Store Connect (.p8)") { [weak self] url in
            guard let self, let url else { return }
            guard url.pathExtension == "p8" else {
                gtk_label_set_text(cast(raw(self.message)), "Choisissez un fichier .p8 téléchargé depuis App Store Connect.")
                return
            }
            self.keyFile = url
            adw_action_row_set_subtitle(cast(raw(self.keyFileRow)), url.lastPathComponent)
            // App Store Connect nomme la clé AuthKey_<Key ID>.p8 : on pré-remplit l'identifiant.
            if let id = AppleAccount.keyID(fromFileName: url.lastPathComponent),
               String(cString: gtk_editable_get_text(OpaquePointer(self.keyID))).isEmpty {
                gtk_editable_set_text(OpaquePointer(self.keyID), id)
            }
        }
    }

    private func logInWithKey() {
        let id = String(cString: gtk_editable_get_text(OpaquePointer(keyID))).trimmingCharacters(in: .whitespaces)
        let issuer = String(cString: gtk_editable_get_text(OpaquePointer(issuerID))).trimmingCharacters(in: .whitespaces)
        guard let file = keyFile, !id.isEmpty, !issuer.isEmpty else {
            gtk_label_set_text(cast(raw(message)), "Choisissez le fichier .p8 et indiquez Key ID et Issuer ID.")
            return
        }
        busy("Connexion avec la clé \(id)…")
        Thread.detachNewThread { [weak self] in
            let result = Result { try AppleAccount.logIn(keyID: id, issuerID: issuer, keyFile: file) }
            onMain {
                guard let self else { return }
                self.busy(nil)
                if case let .failure(error) = result {
                    gtk_label_set_text(cast(raw(self.message)), "Connexion refusée par xtool :\n\(error)")
                } else {
                    self.onChange()
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Apple ID (terminal)

    private func logInInTerminal() {
        guard let command = Terminal.command(for: AppleAccount.passwordLoginCommand, title: "Connexion à Apple — xtool") else {
            gtk_label_set_text(cast(raw(message)), "Aucun terminal trouvé (gnome-terminal, konsole ou xterm). "
                + "Lancez vous-même : xtool auth login --mode password")
            return
        }
        busy("Terminez la connexion dans le terminal qui vient de s'ouvrir…")
        Thread.detachNewThread { [weak self] in
            _ = try? Shell.run(command)
            onMain {
                guard let self else { return }
                self.busy(nil)
                self.onChange()
                self.refresh()
            }
        }
    }

    // MARK: - Déconnexion

    private func confirmLogout() {
        guard let parent = gtk_widget_get_root(cast(raw(dialog))) else { return }
        Dialogs.confirm(cast(raw(parent)), title: "Se déconnecter du compte Apple ?",
                        message: "xtool oubliera les identifiants enregistrés. Il faudra se reconnecter pour installer sur un iPhone.",
                        action: "Se déconnecter") { [weak self] ok in
            guard ok, let self else { return }
            self.busy("Déconnexion…")
            Thread.detachNewThread { [weak self] in
                let result = Result { try AppleAccount.logOut() }
                onMain {
                    guard let self else { return }
                    self.busy(nil)
                    if case let .failure(error) = result { gtk_label_set_text(cast(raw(self.message)), "\(error)") }
                    self.onChange()
                    self.refresh()
                }
            }
        }
    }
}

/// Ouverture d'une commande interactive dans un terminal du système (l'utilisateur y tape ses secrets).
enum Terminal {
    /// Commande qui ouvre le terminal et attend sa fermeture ; nil si aucun terminal connu n'est installé.
    static func command(for arguments: [String], title: String) -> [String]? {
        let xtool = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/xtool").path
        var args = arguments
        if args.first == "xtool", FileManager.default.isExecutableFile(atPath: xtool) { args[0] = xtool }
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let script = "\(quoted); echo; read -rp 'Appuyez sur Entrée pour fermer… '"
        func installed(_ name: String) -> Bool {
            (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin").split(separator: ":")
                .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
        }
        if installed("gnome-terminal") { return ["gnome-terminal", "--wait", "--title", title, "--", "bash", "-c", script] }
        if installed("konsole") { return ["konsole", "--nofork", "-p", "tabtitle=\(title)", "-e", "bash", "-c", script] }
        if installed("xterm") { return ["xterm", "-T", title, "-e", "bash", "-c", script] }
        return nil
    }
}
