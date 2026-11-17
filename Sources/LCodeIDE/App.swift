import CAdw
import Foundation
import LCodeKit

/// Application windows: welcome and open projects.
final class App {
    static let shared = App()
    private var welcome: WelcomeWindow?
    private var projects: [ProjectWindow] = []

    func showWelcome() {
        if let welcome { gtk_window_present(cast(raw(welcome.window))); return }
        welcome = WelcomeWindow()
    }

    func welcomeClosed() { welcome = nil }

    func openProject(_ url: URL) {
        if let open = projects.first(where: { $0.project.root.standardizedFileURL == url.standardizedFileURL }) {
            gtk_window_present(cast(raw(open.window)))
            return
        }
        do {
            let project = try XtoolProject.load(at: url)
            Settings.shared.noteOpened(url)
            projects.append(ProjectWindow(project: project))
            if let welcome {
                gtk_window_destroy(cast(raw(welcome.window)))
                self.welcome = nil
            }
        } catch {
            let parent = welcome?.window ?? projects.first?.window
            if let parent {
                Dialogs.message(parent, title: tr("Couldn’t Open Project"), message: "\(error)")
            } else {
                FileHandle.standardError.write(Data("lcode-ide: \(error)\n".utf8))
                showWelcome()
            }
        }
    }

    func projectClosed(_ window: ProjectWindow) {
        projects.removeAll { $0 === window }
        if projects.isEmpty, welcome == nil { showWelcome() }
    }

    /// Asks for a name, bundle ID and folder, creates the project and opens it.
    func newProject(from parent: UnsafeMutablePointer<GtkWidget>) {
        Dialogs.prompt(parent, title: tr("New Project"), message: tr("App name (letters and digits, no spaces)."),
                       placeholder: "MyApp", confirm: tr("Next")) { name in
            guard let name else { return }
            Dialogs.prompt(parent, title: tr("Bundle Identifier"), message: tr("Used to sign and install the app on iPhone."),
                           initial: "com.example.\(name)", confirm: tr("Choose Folder…")) { bundle in
                guard let bundle else { return }
                Dialogs.chooseFolder(parent, title: tr("Folder for “%@”", name)) { folder in
                    guard let folder else { return }
                    do {
                        let root = try Templates.createProject(name: name, bundleID: bundle, in: folder)
                        self.openProject(root)
                    } catch {
                        Dialogs.message(parent, title: tr("Couldn’t Create Project"), message: "\(error)")
                    }
                }
            }
        }
    }

    func openProjectDialog(from parent: UnsafeMutablePointer<GtkWidget>) {
        Dialogs.chooseFolder(parent, title: tr("Open Project (folder containing Package.swift)")) { folder in
            if let folder { self.openProject(folder) }
        }
    }
}

/// Welcome window: create, open, recent projects (like "Welcome to Xcode").
final class WelcomeWindow {
    let window: UnsafeMutablePointer<GtkWidget>

    init() {
        window = adw_application_window_new(cast(raw(application)))
        gtk_window_set_title(cast(raw(window)), tr("Welcome to LCode"))
        gtk_window_set_default_size(cast(raw(window)), 860, 520)

        let left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        gtk_widget_set_size_request(left, 360, -1)
        gtk_widget_set_valign(left, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_start(left, 40)
        gtk_widget_set_margin_end(left, 40)
        let iconPath = lcodeRoot.appendingPathComponent("Resources/lcode.svg").path
        let icon = FileManager.default.fileExists(atPath: iconPath)
            ? gtk_image_new_from_file(iconPath)! : gtk_image_new_from_icon_name("applications-development-symbolic")!
        gtk_image_set_pixel_size(cast(raw(icon)), 96)
        gtk_box_append(cast(raw(left)), icon)
        let title = gtk_label_new("LCode")!
        gtk_widget_add_css_class(title, "title-1")
        gtk_box_append(cast(raw(left)), title)
        let version = gtk_label_new(tr("SwiftUI iOS apps, on Linux"))!
        gtk_widget_add_css_class(version, "dim-label")
        gtk_box_append(cast(raw(left)), version)
        let actions = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_margin_top(actions, 24)
        func action(_ label: String, _ icon: String, _ handler: @escaping () -> Void) {
            let button = gtk_button_new()!
            let content = adw_button_content_new()!
            adw_button_content_set_label(cast(raw(content)), label)
            adw_button_content_set_icon_name(cast(raw(content)), icon)
            gtk_widget_set_halign(content, GTK_ALIGN_START)
            gtk_button_set_child(cast(raw(button)), content)
            gtk_widget_add_css_class(button, "pill")
            connect(raw(button), "clicked", handler)
            gtk_box_append(cast(raw(actions)), button)
        }
        let win = window
        action(tr("Create New Project…"), "document-new-symbolic") { App.shared.newProject(from: win) }
        action(tr("Open Existing Project…"), "folder-open-symbolic") { App.shared.openProjectDialog(from: win) }
        gtk_box_append(cast(raw(left)), actions)

        let list = gtk_list_box_new()!
        gtk_widget_add_css_class(list, "boxed-list")
        gtk_list_box_set_selection_mode(cast(raw(list)), GTK_SELECTION_NONE)
        let recents = Settings.shared.recents
        for url in recents {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(cast(raw(row)), url.lastPathComponent)
            adw_action_row_set_subtitle(cast(raw(row)), url.deletingLastPathComponent().path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
            let image = gtk_image_new_from_icon_name("folder-symbolic")!
            adw_action_row_add_prefix(cast(raw(row)), image)
            gtk_list_box_row_set_activatable(cast(raw(row)), 1)
            connect(raw(row), "activated") { App.shared.openProject(url) }
            gtk_list_box_append(cast(raw(list)), row)
        }
        let right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        gtk_widget_set_margin_top(right, 24)
        gtk_widget_set_margin_bottom(right, 24)
        gtk_widget_set_margin_end(right, 24)
        gtk_widget_set_hexpand(right, 1)
        let heading = gtk_label_new(recents.isEmpty ? tr("No Recent Projects") : tr("Recent Projects"))!
        gtk_widget_set_halign(heading, GTK_ALIGN_START)
        gtk_widget_add_css_class(heading, "heading")
        gtk_box_append(cast(raw(right)), heading)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(raw(scroller)), list)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(cast(raw(right)), scroller)

        let body = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_box_append(cast(raw(body)), left)
        gtk_box_append(cast(raw(body)), gtk_separator_new(GTK_ORIENTATION_VERTICAL))
        gtk_box_append(cast(raw(body)), right)

        let header = adw_header_bar_new()!
        adw_header_bar_set_show_title(cast(raw(header)), 0)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(raw(toolbar)), header)
        adw_toolbar_view_set_content(cast(raw(toolbar)), body)
        adw_application_window_set_content(cast(raw(window)), toolbar)
        connectReturningFalse(raw(window), "close-request") { App.shared.welcomeClosed() }
        gtk_window_present(cast(raw(window)))
    }
}
