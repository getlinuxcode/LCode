import CAdw
import Foundation
import LCodeKit

/// Signing & Capabilities tab: account and team, bundle ID (`xtool.yml`), last signing problems, capabilities
/// (entitlements file at `entitlementsPath`) and usage descriptions (Info.plist at `infoPath`).
final class SigningEditor {
    let widget: UnsafeMutablePointer<GtkWidget>
    private weak var window: ProjectWindow?
    private var signing: ProjectSigning
    private var groups: [UnsafeMutablePointer<GtkWidget>] = []
    private var account: AppleAccount?
    private var team: AppleAccount.Team?
    private var accountLoaded = false
    /// Problems from the last iPhone install.
    var issues: [SigningIssue] = [] { didSet { rebuild() } }

    init(window: ProjectWindow) {
        self.window = window
        signing = ProjectSigning(root: window.project.root, name: window.project.appTarget)
        widget = adw_preferences_page_new()!
        gtk_widget_set_vexpand(widget, 1)
        rebuild()
        refreshAccount()
    }

    func projectChanged() {
        guard let window else { return }
        signing = ProjectSigning(root: window.project.root, name: window.project.appTarget)
        rebuild()
    }

    /// Rereads the account in the background (xtool may query Apple for teams).
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

    // MARK: - Building the page

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

    /// Entry row with an apply (✓) button.
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
        let g = group(tr("Signing"), tr("Automatic signing by xtool: the App ID, development certificate and profile are created as needed."))

        let accountRow: UnsafeMutablePointer<GtkWidget>
        switch (accountLoaded, account) {
        case (false, _):
            accountRow = actionRow(tr("Apple Account"), tr("Reading status…"), icon: "avatar-default-symbolic")
        case (true, nil):
            accountRow = actionRow(tr("Apple Account"), tr("Not signed in — required to install on an iPhone"), icon: "dialog-warning-symbolic")
        case let (true, account?):
            accountRow = actionRow(tr("Apple Account"), account.mode == .apiKey
                ? tr("App Store Connect API key %@", account.keyID ?? "") : (account.appleID ?? "Apple ID"), icon: "avatar-default-symbolic")
        }
        suffixButton(accountRow, account == nil ? tr("Sign In…") : tr("Manage…")) { [weak self] in self?.showAccount() }
        adw_preferences_group_add(cast(raw(g)), accountRow)

        let teamText: String
        switch account?.mode {
        case .apiKey?: teamText = tr("API key team — Apple Developer Program")
        case .appleID?:
            if let team { teamText = "\(team.name) (\(team.id))" + (team.isFree ? tr(" — Personal Team, free") : " — " + (team.memberships.first ?? tr("paid"))) }
            else { teamText = account?.teamID ?? "—" }
        case nil: teamText = tr("No Team")
        }
        let teamRow = actionRow(tr("Team"), teamText, icon: "system-users-symbolic")
        if account?.mode == .appleID {
            suffixButton(teamRow, tr("Change…")) { [weak self] in self?.showAccount() }
        }
        adw_preferences_group_add(cast(raw(g)), teamRow)

        let bundle = entryRow("Bundle Identifier", signing.bundleID ?? "") { [weak self] text in self?.applyBundleID(text) }
        adw_preferences_group_add(cast(raw(g)), bundle)
        if signing.bundleID == nil, let org = signing.orgID {
            adw_preferences_group_add(cast(raw(g)), actionRow(tr("Organization Prefix (orgID)"), tr("%@ — xtool uses %@", org, "\(org).\(window?.project.appTarget ?? "App")")))
        }

        let entitlements = actionRow(tr("Entitlements File"), signing.entitlementsPath ?? tr("None — created when a capability is enabled"),
                                     icon: "text-x-generic-symbolic")
        if let path = signing.entitlementsPath {
            suffixButton(entitlements, tr("Open")) { [weak self] in
                guard let self else { return }
                self.window?.open(self.signing.root.appendingPathComponent(path))
            }
        }
        adw_preferences_group_add(cast(raw(g)), entitlements)
        let info = actionRow("Info.plist", signing.infoPath ?? tr("Generated by xtool — created with the first usage description"),
                             icon: "text-x-generic-symbolic")
        if let path = signing.infoPath {
            suffixButton(info, tr("Open")) { [weak self] in
                guard let self else { return }
                self.window?.open(self.signing.root.appendingPathComponent(path))
            }
        }
        adw_preferences_group_add(cast(raw(g)), info)
    }

    private func buildIssues() {
        let g = group(tr("Last iPhone Install"))
        if issues.isEmpty {
            adw_preferences_group_add(cast(raw(g)), actionRow(tr("No Signing Issues"),
                tr("Account, profile or capability errors from “xtool dev run” will appear here."), icon: "emblem-ok-symbolic"))
            return
        }
        for issue in issues {
            let r = actionRow(tr(issue.message), issue.detail, icon: "dialog-error-symbolic")
            adw_action_row_set_subtitle_selectable(cast(raw(r)), 1)
            adw_action_row_set_title_lines(cast(raw(r)), 0)
            adw_action_row_set_subtitle_lines(cast(raw(r)), 0)
            gtk_widget_add_css_class(r, "error")
            adw_preferences_group_add(cast(raw(g)), r)
        }
    }

    private func buildCapabilities() {
        let g = group("Capabilities", isFreeTeam
            ? tr("Free team: when signing, xtool drops capabilities that require the paid program.")
            : tr("Enabling a capability writes the entitlement (or Info.plist key); xtool enables it on the App ID at the next install."))
        for cap in Capability.all {
            let row = adw_expander_row_new()!
            adw_preferences_row_set_use_markup(cast(raw(row)), 0)
            adw_preferences_row_set_title(cast(raw(row)), cap.title)
            var subtitle = tr(cap.summary)
            switch cap.support {
            case .xtool: break
            case .infoPlist: subtitle += "\n" + tr("Info.plist key, nothing to set up on Apple’s side.")
            case let .partial(note): subtitle += "\n⚠ " + tr(note)
            case let .unsupported(note): subtitle += "\n⚠ " + tr(note)
            }
            if cap.requiresPaidAccount { subtitle += "\n" + (isFreeTeam ? tr("✗ Requires the paid program: ignored with your team.") : tr("Requires the paid program.")) }
            adw_expander_row_set_subtitle(cast(raw(row)), subtitle)
            adw_expander_row_set_show_enable_switch(cast(raw(row)), 1)
            let enabled = signing.isEnabled(cap)
            adw_expander_row_set_enable_expansion(cast(raw(row)), enabled ? 1 : 0)
            adw_expander_row_set_expanded(cast(raw(row)), 0)

            let keyRow = actionRow(cap.storage == .infoPlist(cap.key) ? tr("Info.plist Key") : "Entitlement", cap.key)
            adw_action_row_set_subtitle_selectable(cast(raw(keyRow)), 1)
            adw_expander_row_add_row(cast(raw(row)), keyRow)
            if case .list = cap.value {
                let values = entryRow(cap.listHint.map { tr($0) } ?? tr("Values, comma-separated"), signing.values(cap).joined(separator: ", ")) { [weak self] text in
                    self?.perform { try $0.setValues(cap, text.split(separator: ",").map(String.init)) }
                }
                adw_expander_row_add_row(cast(raw(row)), values)
            } else if case .string = cap.value, enabled, let v = signing.entitlements()[cap.key] as? String {
                adw_expander_row_add_row(cast(raw(row)), actionRow(tr("Value"), v))
            }
            for usage in cap.usageKeys {
                adw_expander_row_add_row(cast(raw(row)), usageRow(usage.key, tr(usage.label)))
            }

            connectArg(raw(row), "notify::enable-expansion") { [weak self] _ in
                let on = adw_expander_row_get_enable_expansion(cast(raw(row))) != 0
                guard let self, on != self.signing.isEnabled(cap) else { return }
                // Rebuild to show the default values and the new entitlements file.
                self.perform(rebuild: true) { try $0.setEnabled(cap, on) }
            }
            adw_preferences_group_add(cast(raw(g)), row)
        }
    }

    private func usageRow(_ key: String, _ label: String) -> UnsafeMutablePointer<GtkWidget> {
        let r = entryRow(signing.usage(key) == nil ? tr("%@ — description required by iOS", label) : label, signing.usage(key) ?? "") { [weak self] text in
            self?.perform { try $0.setUsage(key, text) }
        }
        gtk_widget_set_tooltip_text(r, key)
        return r
    }

    private func buildPrivacy() {
        let g = group(tr("Privacy (Info.plist)"),
                      tr("Message iOS shows when the app asks for access. Leave empty to remove the key."))
        for (key, label) in Capability.privacyKeys {
            adw_preferences_group_add(cast(raw(g)), usageRow(key, tr(label)))
        }
    }

    // MARK: - Actions

    /// Applies a change; `rebuild` redraws the page afterwards, outside the current signal handler.
    private func perform(rebuild: Bool = false, _ change: (ProjectSigning) throws -> Void) {
        do {
            try change(signing)
            if rebuild { after(0) { [weak self] in self?.rebuild() } }
        } catch {
            if let parent = window?.window { Dialogs.message(parent, title: tr("Couldn’t Apply Change"), message: "\(error)") }
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
