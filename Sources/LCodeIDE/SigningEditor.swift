import CAdw
import Foundation
import LCodeKit

/// Page « Signature et capabilities » (comme l'onglet Signing & Capabilities d'Xcode) : compte et équipe,
/// bundle ID (`xtool.yml`), problèmes de la dernière signature, capabilities (fichier d'entitlements référencé
/// par `entitlementsPath`) et descriptions d'usage (Info.plist référencé par `infoPath`).
final class SigningEditor {
    let widget: UnsafeMutablePointer<GtkWidget>
    private weak var window: ProjectWindow?
    private var signing: ProjectSigning
    private var groups: [UnsafeMutablePointer<GtkWidget>] = []
    private var account: AppleAccount?
    private var team: AppleAccount.Team?
    private var accountLoaded = false
    /// Problèmes relevés à la dernière installation sur iPhone.
    var issues: [SigningIssue] = [] { didSet { rebuild() } }

    init(window: ProjectWindow) {
        self.window = window
        signing = ProjectSigning(root: window.project.root, name: window.project.appTarget)
        widget = adw_preferences_page_new()!
        gtk_widget_set_vexpand(widget, 1)
        rebuild()
        refreshAccount()
    }

    /// Projet rechargé (bundle ID, fichiers) : la page suit.
    func projectChanged() {
        guard let window else { return }
        signing = ProjectSigning(root: window.project.root, name: window.project.appTarget)
        rebuild()
    }

    /// Relit l'état du compte (en arrière-plan : xtool peut interroger Apple pour les équipes).
    func refreshAccount() {
        Thread.detachNewThread { [weak self] in
            let account = AppleAccount.current()
            let team = account?.mode == .appleID ? AppleAccount.teams().first { $0.id == account?.teamID } : nil
            onMain {
                guard let self else { return }
                self.account = account
                self.team = team
                self.accountLoaded = true
                self.rebuild()
            }
        }
    }

    // MARK: - Construction

    private func group(_ title: String, _ description: String? = nil) -> UnsafeMutablePointer<GtkWidget> {
        let g = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(raw(g)), title)
        if let description { adw_preferences_group_set_description(cast(raw(g)), description) }
        adw_preferences_page_add(cast(raw(widget)), cast(raw(g)))
        groups.append(g)
        return g
    }

    private func actionRow(_ title: String, _ subtitle: String, icon: String? = nil) -> UnsafeMutablePointer<GtkWidget> {
        let r = adw_action_row_new()!
        adw_preferences_row_set_use_markup(cast(raw(r)), 0)
        adw_preferences_row_set_title(cast(raw(r)), title)
        adw_action_row_set_subtitle(cast(raw(r)), subtitle)
        if let icon { adw_action_row_add_prefix(cast(raw(r)), gtk_image_new_from_icon_name(icon)) }
        return r
    }

    private func suffixButton(_ row: UnsafeMutablePointer<GtkWidget>, _ label: String, _ action: @escaping () -> Void) {
        let b = gtk_button_new_with_label(label)!
        gtk_widget_set_valign(b, GTK_ALIGN_CENTER)
        connect(raw(b), "clicked", action)
        adw_action_row_add_suffix(cast(raw(row)), b)
    }

    /// Ligne de saisie avec bouton « appliquer » (✓) : `apply` reçoit le texte.
    private func entryRow(_ title: String, _ text: String, _ apply: @escaping (String) -> Void) -> UnsafeMutablePointer<GtkWidget> {
        let r = adw_entry_row_new()!
        adw_preferences_row_set_use_markup(cast(raw(r)), 0)
        adw_preferences_row_set_title(cast(raw(r)), title)
        gtk_editable_set_text(OpaquePointer(r), text)
        adw_entry_row_set_show_apply_button(cast(raw(r)), 1)
        connect(raw(r), "apply") { apply(String(cString: gtk_editable_get_text(OpaquePointer(r)))) }
        return r
    }

    private func rebuild() {
        for g in groups { adw_preferences_page_remove(cast(raw(widget)), cast(raw(g))) }
        groups = []
        buildSigning()
        buildIssues()
        buildCapabilities()
        buildPrivacy()
    }

    private var isFreeTeam: Bool { account?.mode == .appleID && team?.isFree != false }

    private func buildSigning() {
        let g = group("Signature", "Signature automatique par xtool : App ID, certificat et profil de développement sont créés au besoin.")

        let accountRow: UnsafeMutablePointer<GtkWidget>
        switch (accountLoaded, account) {
        case (false, _):
            accountRow = actionRow("Compte Apple", "Lecture de l'état…", icon: "avatar-default-symbolic")
        case (true, nil):
            accountRow = actionRow("Compte Apple", "Non connecté — nécessaire pour installer sur un iPhone", icon: "dialog-warning-symbolic")
        case let (true, account?):
            accountRow = actionRow("Compte Apple", account.mode == .apiKey
                ? "Clé API App Store Connect \(account.keyID ?? "")" : (account.appleID ?? "Apple ID"), icon: "avatar-default-symbolic")
        }
        suffixButton(accountRow, account == nil ? "Se connecter…" : "Gérer…") { [weak self] in self?.showAccount() }
        adw_preferences_group_add(cast(raw(g)), accountRow)

        let teamText: String
        switch account?.mode {
        case .apiKey?: teamText = "Équipe de la clé API — Apple Developer Program"
        case .appleID?:
            if let team { teamText = "\(team.name) (\(team.id))" + (team.isFree ? " — Personal Team, gratuite" : " — \(team.memberships.first ?? "payante")") }
            else { teamText = account?.teamID ?? "—" }
        case nil: teamText = "Aucune"
        }
        let teamRow = actionRow("Équipe", teamText, icon: "system-users-symbolic")
        if account?.mode == .appleID {
            suffixButton(teamRow, "Changer…") { [weak self] in self?.showAccount() }
        }
        adw_preferences_group_add(cast(raw(g)), teamRow)

        let bundle = entryRow("Bundle Identifier", signing.bundleID ?? "") { [weak self] text in self?.applyBundleID(text) }
        adw_preferences_group_add(cast(raw(g)), bundle)
        if signing.bundleID == nil, let org = signing.orgID {
            adw_preferences_group_add(cast(raw(g)), actionRow("Préfixe d'organisation (orgID)", "\(org) — xtool forme \(org).\(window?.project.appTarget ?? "App")"))
        }

        let entitlements = actionRow("Fichier d'entitlements", signing.entitlementsPath ?? "Aucun — créé à l'activation d'une capability",
                                     icon: "text-x-generic-symbolic")
        if let path = signing.entitlementsPath {
            suffixButton(entitlements, "Ouvrir") { [weak self] in
                guard let self else { return }
                self.window?.open(self.signing.root.appendingPathComponent(path))
            }
        }
        adw_preferences_group_add(cast(raw(g)), entitlements)
        let info = actionRow("Info.plist", signing.infoPath ?? "Généré par xtool — créé à la première description d'usage",
                             icon: "text-x-generic-symbolic")
        if let path = signing.infoPath {
            suffixButton(info, "Ouvrir") { [weak self] in
                guard let self else { return }
                self.window?.open(self.signing.root.appendingPathComponent(path))
            }
        }
        adw_preferences_group_add(cast(raw(g)), info)
    }

    private func buildIssues() {
        let g = group("Dernière installation sur iPhone")
        if issues.isEmpty {
            adw_preferences_group_add(cast(raw(g)), actionRow("Aucun problème de signature",
                "Les erreurs de compte, de profil ou de capability de « xtool dev run » s'afficheront ici.", icon: "emblem-ok-symbolic"))
            return
        }
        for issue in issues {
            let r = actionRow(issue.message, issue.detail, icon: "dialog-error-symbolic")
            adw_action_row_set_subtitle_selectable(cast(raw(r)), 1)
            adw_action_row_set_title_lines(cast(raw(r)), 0)
            adw_action_row_set_subtitle_lines(cast(raw(r)), 0)
            gtk_widget_add_css_class(r, "error")
            adw_preferences_group_add(cast(raw(g)), r)
        }
    }

    private func buildCapabilities() {
        let g = group("Capabilities", isFreeTeam
            ? "Équipe gratuite : xtool retire à la signature les capabilities réservées au programme payant."
            : "Activer une capability écrit l'entitlement (ou la clé d'Info.plist) ; xtool l'active sur l'App ID à la prochaine installation.")
        for cap in Capability.all {
            let row = adw_expander_row_new()!
            adw_preferences_row_set_use_markup(cast(raw(row)), 0)
            adw_preferences_row_set_title(cast(raw(row)), cap.title)
            var subtitle = cap.summary
            switch cap.support {
            case .xtool: break
            case .infoPlist: subtitle += "\nClé d'Info.plist, sans réglage côté Apple."
            case let .partial(note): subtitle += "\n⚠ \(note)"
            case let .unsupported(note): subtitle += "\n⚠ \(note)"
            }
            if cap.requiresPaidAccount { subtitle += isFreeTeam ? "\n✗ Programme payant requis : ignorée avec votre équipe." : "\nProgramme payant requis." }
            adw_expander_row_set_subtitle(cast(raw(row)), subtitle)
            adw_expander_row_set_show_enable_switch(cast(raw(row)), 1)
            let enabled = signing.isEnabled(cap)
            adw_expander_row_set_enable_expansion(cast(raw(row)), enabled ? 1 : 0)
            adw_expander_row_set_expanded(cast(raw(row)), 0)

            // Détails : clé, valeurs, descriptions d'usage.
            let keyRow = actionRow(cap.storage == .infoPlist(cap.key) ? "Clé d'Info.plist" : "Entitlement", cap.key)
            adw_action_row_set_subtitle_selectable(cast(raw(keyRow)), 1)
            adw_expander_row_add_row(cast(raw(row)), keyRow)
            if case .list = cap.value {
                let values = entryRow(cap.listHint ?? "Valeurs, séparées par des virgules", signing.values(cap).joined(separator: ", ")) { [weak self] text in
                    self?.perform { try $0.setValues(cap, text.split(separator: ",").map(String.init)) }
                }
                adw_expander_row_add_row(cast(raw(row)), values)
            } else if case .string = cap.value, enabled, let v = signing.entitlements()[cap.key] as? String {
                adw_expander_row_add_row(cast(raw(row)), actionRow("Valeur", v))
            }
            for usage in cap.usageKeys {
                adw_expander_row_add_row(cast(raw(row)), usageRow(usage.key, usage.label))
            }

            connectArg(raw(row), "notify::enable-expansion") { [weak self] _ in
                let on = adw_expander_row_get_enable_expansion(cast(raw(row))) != 0
                guard let self, on != self.signing.isEnabled(cap) else { return }
                // Les valeurs par défaut écrites et le fichier d'entitlements apparaissent ensuite.
                self.perform(rebuild: true) { try $0.setEnabled(cap, on) }
            }
            adw_preferences_group_add(cast(raw(g)), row)
        }
    }

    private func usageRow(_ key: String, _ label: String) -> UnsafeMutablePointer<GtkWidget> {
        let r = entryRow(label + (signing.usage(key) == nil ? " — description requise par iOS" : ""), signing.usage(key) ?? "") { [weak self] text in
            self?.perform { try $0.setUsage(key, text) }
        }
        gtk_widget_set_tooltip_text(r, key)
        return r
    }

    private func buildPrivacy() {
        let g = group("Confidentialité (Info.plist)",
                      "Message affiché par iOS quand l'app demande l'accès. Laisser vide retire la clé.")
        for (key, label) in Capability.privacyKeys {
            adw_preferences_group_add(cast(raw(g)), usageRow(key, label))
        }
    }

    // MARK: - Actions

    /// Applique une modification ; `rebuild` redessine la page ensuite (hors du signal en cours).
    private func perform(rebuild: Bool = false, _ change: (ProjectSigning) throws -> Void) {
        do {
            try change(signing)
            if rebuild { after(0) { [weak self] in self?.rebuild() } }
        } catch {
            if let parent = window?.window { Dialogs.message(parent, title: "Modification impossible", message: "\(error)") }
            after(0) { [weak self] in self?.rebuild() }
        }
    }

    private func applyBundleID(_ text: String) {
        let id = text.trimmingCharacters(in: .whitespaces)
        guard id != signing.bundleID else { return }
        perform(rebuild: true) { try $0.setBundleID(id) }
        window?.reloadProject()
    }

    private func showAccount() {
        guard let parent = window?.window else { return }
        AccountDialog.present(from: parent) { [weak self] in self?.refreshAccount() }
    }
}
