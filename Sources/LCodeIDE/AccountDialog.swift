import CAdw
import Foundation
import LCodeKit

/// Apple account used for signing (like Xcode's Settings › Accounts), through `xtool auth`.
///
/// LCode never asks for or stores a password: Apple ID sign-in opens in a terminal where the user types the
/// password and verification code; API key sign-in passes xtool the key ID, issuer and .p8 path, which xtool reads.
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

    /// `onChange` runs after each sign-in or sign-out (to refresh the signing tab).
    static func present(from parent: UnsafeMutablePointer<GtkWidget>, onChange: @escaping () -> Void = {}) {
        let d = AccountDialog(onChange: onChange)
        open = d
        adw_dialog_present(d.dialog, parent)
    }

    private init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        dialog = cast(raw(adw_dialog_new()!))
        adw_dialog_set_title(dialog, tr("Apple Account"))
        adw_dialog_set_content_width(dialog, 580)
        adw_dialog_set_content_height(dialog, 680)

        let page = adw_preferences_page_new()!

        statusGroup = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(raw(statusGroup)), tr("Account"))
        adw_preferences_group_set_description(cast(raw(statusGroup)),
            tr("xtool signs and installs apps with this account. Credentials stay in xtool’s keychain."))
        spinner = gtk_spinner_new()!
        adw_preferences_group_set_header_suffix(cast(raw(statusGroup)), spinner)
        adw_preferences_page_add(cast(raw(page)), cast(raw(statusGroup)))

        let keyGroup = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(raw(keyGroup)), tr("Sign In with an App Store Connect API Key"))
        adw_preferences_group_set_description(cast(raw(keyGroup)),
            tr("Recommended with a paid account. Create the key in App Store Connect › Users and Access › Integrations; "
               + "xtool reads the .p8 file itself, LCode never copies or shows its contents."))
        keyFileRow = adw_action_row_new()!
        adw_preferences_row_set_title(cast(raw(keyFileRow)), tr("Key File (.p8)"))
        adw_action_row_set_subtitle(cast(raw(keyFileRow)), tr("No file chosen"))
        let choose = gtk_button_new_with_label(tr("Choose…"))!
        gtk_widget_set_valign(choose, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(cast(raw(keyFileRow)), choose)
        keyID = adw_entry_row_new()!
        adw_preferences_row_set_title(cast(raw(keyID)), tr("Key ID"))
        issuerID = adw_entry_row_new()!
        adw_preferences_row_set_title(cast(raw(issuerID)), tr("Issuer ID"))
        for row in [keyFileRow, keyID, issuerID] { adw_preferences_group_add(cast(raw(keyGroup)), row) }
        keyLogin = gtk_button_new_with_label(tr("Sign In with Key"))!
        gtk_widget_add_css_class(keyLogin, "suggested-action")
        gtk_widget_set_halign(keyLogin, GTK_ALIGN_END)
        gtk_widget_set_margin_top(keyLogin, 10)
        adw_preferences_group_add(cast(raw(keyGroup)), keyLogin)
        adw_preferences_page_add(cast(raw(page)), cast(raw(keyGroup)))

        // Apple ID (any account, free included), in a terminal.
        let passwordGroup = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(raw(passwordGroup)), tr("Sign In with Apple ID"))
        adw_preferences_group_set_description(cast(raw(passwordGroup)),
            tr("Works with a free account (apps last 7 days). xtool opens in a terminal: "
               + "type your Apple ID, password and verification code there, then choose the team. "
               + "To switch teams, sign in again the same way."))
        passwordLogin = gtk_button_new_with_label(tr("Sign In in Terminal…"))!
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
        logout = gtk_button_new_with_label(tr("Sign Out"))!
        gtk_widget_add_css_class(logout, "destructive-action")
        gtk_widget_set_halign(logout, GTK_ALIGN_START)
        gtk_widget_set_margin_top(logout, 8)
        adw_preferences_group_add(cast(raw(bottom)), logout)
        adw_preferences_page_add(cast(raw(page)), cast(raw(bottom)))

        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        let refreshButton = gtk_button_new_from_icon_name("view-refresh-symbolic")!
        gtk_widget_set_tooltip_text(refreshButton, tr("Refresh Status"))
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

    // MARK: - Status

    private func busy(_ text: String?) {
        if text != nil { gtk_spinner_start(cast(raw(spinner))) } else { gtk_spinner_stop(cast(raw(spinner))) }
        if let text { gtk_label_set_text(cast(raw(message)), text) }
        for b in [keyLogin, passwordLogin, logout] { gtk_widget_set_sensitive(b, text == nil ? 1 : 0) }
    }

    private func refresh() {
        busy(tr("Reading xtool status…"))
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
            row(tr("Status"), tr("Not signed in: sign in below to install on an iPhone."), icon: "dialog-warning-symbolic")
            gtk_widget_set_visible(logout, 0)
            return
        }
        gtk_widget_set_visible(logout, 1)
        switch account.mode {
        case .apiKey:
            row(tr("Status"), tr("Signed in with an App Store Connect API key"), icon: "emblem-ok-symbolic")
            row(tr("Key"), account.keyID ?? "—")
            row(tr("Issuer"), account.issuerID ?? "—")
            row(tr("Account Type"), tr("Apple Developer Program (paid)"))
            row(tr("Team"), tr("The API key’s team (set by App Store Connect)"))
        case .appleID:
            row(tr("Status"), tr("Signed in with an Apple ID"), icon: "emblem-ok-symbolic")
            row("Apple ID", account.appleID ?? "—")
            let team = teams.first { $0.id == account.teamID }
            row(tr("Team"), team.map { "\($0.name) (\($0.id))" } ?? account.teamID ?? "—")
            row(tr("Account Type"), team.map { $0.isFree ? tr("Free (Personal Team) — apps last 7 days") :
                    ($0.memberships.first ?? "Apple Developer Program") } ?? tr("Unknown (teams unreachable)"))
            if teams.count > 1 {
                row(tr("Other Teams"), teams.filter { $0.id != account.teamID }.map { "\($0.name) (\($0.id))" }.joined(separator: "\n"))
            }
            if let expiry = account.expiry { row(tr("Session Valid Until"), expiry) }
        }
    }

    // MARK: - API key

    private func chooseKey() {
        guard let parent = gtk_widget_get_root(cast(raw(dialog))) else { return }
        Dialogs.chooseFile(cast(raw(parent)), title: tr("App Store Connect API Key (.p8)")) { [weak self] url in
            guard let self, let url else { return }
            guard url.pathExtension == "p8" else {
                gtk_label_set_text(cast(raw(self.message)), tr("Choose a .p8 file downloaded from App Store Connect."))
                return
            }
            self.keyFile = url
            adw_action_row_set_subtitle(cast(raw(self.keyFileRow)), url.lastPathComponent)
            // App Store Connect names the key AuthKey_<Key ID>.p8: prefill the ID.
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
            gtk_label_set_text(cast(raw(message)), tr("Choose the .p8 file and enter the Key ID and Issuer ID."))
            return
        }
        busy(tr("Signing in with key %@…", id))
        Thread.detachNewThread { [weak self] in
            let result = Result { try AppleAccount.logIn(keyID: id, issuerID: issuer, keyFile: file) }
            onMain {
                guard let self else { return }
                self.busy(nil)
                if case let .failure(error) = result {
                    gtk_label_set_text(cast(raw(self.message)), tr("xtool rejected the sign-in:") + "\n\(error)")
                } else {
                    self.onChange()
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Apple ID (terminal)

    private func logInInTerminal() {
        guard let command = Terminal.command(for: AppleAccount.passwordLoginCommand, title: tr("Apple Sign-In — xtool")) else {
            gtk_label_set_text(cast(raw(message)), tr("No terminal found (gnome-terminal, konsole or xterm). "
                + "Run it yourself: xtool auth login --mode password"))
            return
        }
        busy(tr("Finish signing in in the terminal that just opened…"))
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

    // MARK: - Sign out

    private func confirmLogout() {
        guard let parent = gtk_widget_get_root(cast(raw(dialog))) else { return }
        Dialogs.confirm(cast(raw(parent)), title: tr("Sign Out of Apple Account?"),
                        message: tr("xtool will forget the saved credentials. You’ll need to sign in again to install on an iPhone."),
                        action: tr("Sign Out")) { [weak self] ok in
            guard ok, let self else { return }
            self.busy(tr("Signing out…"))
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

/// Runs an interactive command in a system terminal (where the user types secrets).
enum Terminal {
    /// Command that opens the terminal and waits for it to close; nil if no known terminal is installed.
    static func command(for arguments: [String], title: String) -> [String]? {
        let xtool = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/xtool").path
        var args = arguments
        if args.first == "xtool", FileManager.default.isExecutableFile(atPath: xtool) { args[0] = xtool }
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let prompt = tr("Press Enter to close…").replacingOccurrences(of: "'", with: "'\\''")
        let script = "\(quoted); echo; read -rp '\(prompt) '"
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
