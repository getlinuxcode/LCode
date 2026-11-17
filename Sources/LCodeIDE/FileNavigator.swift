import CAdw
import Foundation
import LCodeKit

/// Project navigator: collapsible tree, per-type icons, context menu (new file from template, new folder,
/// rename, move to trash, show in file manager).
final class FileNavigator {
    let root: URL
    let widget: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private weak var window: ProjectWindow?
    private var expanded: Set<String> = []
    private var nodes: [(url: URL, isDirectory: Bool, depth: Int)] = []
    var onOpen: (URL) -> Void = { _ in }

    /// Hidden build and tool folders.
    static let hidden: Set<String> = [".build", ".lcode", "xtool", ".swiftpm", "Packages", ".git", ".bsp", ".DS_Store"]

    init(root: URL, window: ProjectWindow) {
        self.root = root
        self.window = window
        list = gtk_list_box_new()!
        gtk_widget_add_css_class(list, "navigation-sidebar")
        widget = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(raw(widget)), list)
        gtk_widget_set_vexpand(widget, 1)
        // Source folders start expanded.
        expanded.insert(root.appendingPathComponent("Sources").path)
        if let subs = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources").path) {
            for s in subs { expanded.insert(root.appendingPathComponent("Sources/\(s)").path) }
        }
        connectArg(raw(list), "row-activated") { [weak self] row in
            guard let self, let row else { return }
            self.activate(Int(gtk_list_box_row_get_index(cast(row))))
        }
        installContextMenu()
        reload()
    }

    // MARK: - Contents

    func reload() {
        while let child = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(raw(list)), child) }
        nodes = []
        add(directory: root, depth: 0)
    }

    private func add(directory: URL, depth: Int) {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !Self.hidden.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
            .map { url -> (URL, Bool) in
                let dir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                // Asset catalogs open in their editor instead of expanding like folders.
                return (url, dir && url.pathExtension != "xcassets")
            }
            .sorted { a, b in a.1 != b.1 ? a.1 && !b.1 : a.0.lastPathComponent.localizedStandardCompare(b.0.lastPathComponent) == .orderedAscending }
        for (url, isDir) in entries {
            appendRow(url: url, isDirectory: isDir, depth: depth)
            if isDir, expanded.contains(url.path) { add(directory: url, depth: depth + 1) }
        }
    }

    private func icon(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return expanded.contains(url.path) ? "folder-open-symbolic" : "folder-symbolic" }
        switch url.pathExtension.lowercased() {
        case "swift": return "text-x-script-symbolic"
        case "xcassets": return "image-x-generic-symbolic"
        case "png", "jpg", "jpeg", "heic", "svg", "pdf": return "image-x-generic-symbolic"
        case "json", "yml", "yaml", "plist": return "text-x-generic-symbolic"
        default: return "text-x-generic-symbolic"
        }
    }

    private func appendRow(url: URL, isDirectory: Bool, depth: Int) {
        let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_widget_set_margin_start(box, Int32(depth * 14))
        let arrow = gtk_image_new_from_icon_name(isDirectory ? (expanded.contains(url.path) ? "pan-down-symbolic" : "pan-end-symbolic") : nil)!
        gtk_widget_set_size_request(arrow, 16, -1)
        gtk_box_append(cast(raw(box)), arrow)
        gtk_box_append(cast(raw(box)), gtk_image_new_from_icon_name(icon(for: url, isDirectory: isDirectory)))
        let label = gtk_label_new(url.lastPathComponent)!
        gtk_label_set_ellipsize(cast(raw(label)), PANGO_ELLIPSIZE_MIDDLE)
        gtk_box_append(cast(raw(box)), label)
        gtk_list_box_append(cast(raw(list)), box)
        nodes.append((url, isDirectory, depth))
    }

    private func activate(_ index: Int) {
        guard index >= 0, index < nodes.count else { return }
        let node = nodes[index]
        if node.isDirectory {
            if expanded.contains(node.url.path) { expanded.remove(node.url.path) } else { expanded.insert(node.url.path) }
            reload()
        } else {
            onOpen(node.url)
        }
    }

    /// Selects a file, expanding its parents.
    func reveal(_ url: URL) {
        var dir = url.deletingLastPathComponent()
        var changed = false
        while dir.path.hasPrefix(root.path), dir.path != root.path {
            if !expanded.contains(dir.path) { expanded.insert(dir.path); changed = true }
            dir = dir.deletingLastPathComponent()
        }
        if changed { reload() }
        if let i = nodes.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            gtk_list_box_select_row(cast(raw(list)), gtk_list_box_get_row_at_index(cast(raw(list)), Int32(i)))
        }
    }

    // MARK: - Context menu

    private var contextTarget: (url: URL, isDirectory: Bool)?

    private func installContextMenu() {
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(gesture, 3)
        final class Box { weak var nav: FileNavigator?; init(_ n: FileNavigator) { nav = n } }
        let box = Unmanaged.passRetained(Box(self)).toOpaque()
        let callback: @convention(c) (OpaquePointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, x, y, data in
            Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().nav?.showMenu(x: x, y: y)
        }
        _ = lcode_connect(raw(gesture), "pressed", unsafeBitCast(callback, to: GCallback.self), box)
        gtk_widget_add_controller(list, gesture)
    }

    private func showMenu(x: Double, y: Double) {
        let row = gtk_list_box_get_row_at_y(cast(raw(list)), Int32(y))
        let index = row.map { Int(gtk_list_box_row_get_index($0)) } ?? -1
        contextTarget = index >= 0 && index < nodes.count ? (nodes[index].url, nodes[index].isDirectory) : (root, true)
        if let row { gtk_list_box_select_row(cast(raw(list)), row) }

        let popover = gtk_popover_new()!
        let menu = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        func item(_ label: String, _ action: @escaping () -> Void) {
            let button = gtk_button_new_with_label(label)!
            gtk_widget_add_css_class(button, "flat")
            if let child = gtk_widget_get_first_child(button) { gtk_label_set_xalign(cast(raw(child)), 0) }
            connect(raw(button), "clicked") { gtk_popover_popdown(cast(raw(popover))); action() }
            gtk_box_append(cast(raw(menu)), button)
        }
        item(tr("New File…")) { [weak self] in self?.newFile() }
        item(tr("New Folder…")) { [weak self] in self?.newFolder() }
        if index >= 0 {
            gtk_box_append(cast(raw(menu)), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
            item(tr("Rename…")) { [weak self] in self?.rename() }
            item(tr("Show in File Manager")) { [weak self] in self?.showInFiles() }
            gtk_box_append(cast(raw(menu)), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
            item(tr("Move to Trash")) { [weak self] in self?.delete() }
        }
        gtk_popover_set_child(cast(raw(popover)), menu)
        gtk_widget_set_parent(popover, list)
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(cast(raw(popover)), &rect)
        gtk_popover_set_has_arrow(cast(raw(popover)), 0)
        gtk_widget_set_halign(popover, GTK_ALIGN_START)
        connect(raw(popover), "closed") { after(10) { gtk_widget_unparent(popover) } }
        gtk_popover_popup(cast(raw(popover)))
    }

    /// Folder for new items: the clicked folder, or the clicked file's folder.
    private var targetFolder: URL {
        guard let t = contextTarget else { return root }
        return t.isDirectory ? t.url : t.url.deletingLastPathComponent()
    }

    // MARK: - Operations

    /// New file from a template.
    func newFile(in folder: URL? = nil) {
        guard let parent = window?.window else { return }
        let folder = folder ?? targetFolder
        let dialog = adw_alert_dialog_new(tr("New File"), tr("In %@", folder.lastPathComponent))!
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        let kinds = Templates.FileKind.allCases
        let group = gtk_list_box_new()!
        gtk_widget_add_css_class(group, "boxed-list")
        var checks: [UnsafeMutablePointer<GtkWidget>] = []
        for (i, kind) in kinds.enumerated() {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(cast(raw(row)), kind.title)
            adw_action_row_set_subtitle(cast(raw(row)), kind.subtitle)
            adw_action_row_add_prefix(cast(raw(row)), gtk_image_new_from_icon_name(kind.icon))
            let check = gtk_check_button_new()!
            if let first = checks.first { gtk_check_button_set_group(cast(raw(check)), cast(raw(first))) }
            if i == 0 { gtk_check_button_set_active(cast(raw(check)), 1) }
            adw_action_row_add_suffix(cast(raw(row)), check)
            adw_action_row_set_activatable_widget(cast(raw(row)), check)
            checks.append(check)
            gtk_list_box_append(cast(raw(group)), row)
        }
        gtk_box_append(cast(raw(content)), group)
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(cast(raw(entry)), tr("Name (e.g. ProfileView)"))
        gtk_entry_set_activates_default(cast(raw(entry)), 1)
        gtk_box_append(cast(raw(content)), entry)
        adw_alert_dialog_set_extra_child(cast(raw(dialog)), content)
        adw_alert_dialog_add_response(cast(raw(dialog)), "cancel", tr("Cancel"))
        adw_alert_dialog_add_response(cast(raw(dialog)), "ok", tr("Create"))
        adw_alert_dialog_set_response_appearance(cast(raw(dialog)), "ok", ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_default_response(cast(raw(dialog)), "ok")
        adw_alert_dialog_set_close_response(cast(raw(dialog)), "cancel")
        connectArg(raw(dialog), "response") { [weak self] response in
            guard let self, response.map({ String(cString: $0.assumingMemoryBound(to: CChar.self)) }) == "ok" else { return }
            var name = String(cString: gtk_editable_get_text(OpaquePointer(entry))).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let kind = kinds[checks.firstIndex { gtk_check_button_get_active(cast(raw($0))) != 0 } ?? 0]
            if name.hasSuffix(".swift") { name.removeLast(6) }
            let typeName = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
            let url = folder.appendingPathComponent(name + (kind == .empty && name.contains(".") ? "" : ".swift"))
            guard !FileManager.default.fileExists(atPath: url.path) else {
                Dialogs.message(parent, title: tr("File Already Exists"), message: tr("%@ already exists.", url.lastPathComponent))
                return
            }
            do {
                try Templates.file(kind, named: typeName).write(to: url, atomically: true, encoding: .utf8)
                self.expanded.insert(folder.path)
                self.reload()
                self.onOpen(url)
                self.reveal(url)
            } catch {
                Dialogs.message(parent, title: tr("Couldn’t Create Item"), message: "\(error)")
            }
        }
        adw_dialog_present(cast(raw(dialog)), parent)
        gtk_widget_grab_focus(entry)
    }

    func newFolder() {
        guard let parent = window?.window else { return }
        let folder = targetFolder
        Dialogs.prompt(parent, title: tr("New Folder"), message: tr("In %@", folder.lastPathComponent), placeholder: "Views") { [weak self] name in
            guard let self, let name else { return }
            do {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: false)
                self.expanded.insert(folder.path)
                self.expanded.insert(folder.appendingPathComponent(name).path)
                self.reload()
            } catch {
                Dialogs.message(parent, title: tr("Couldn’t Create Item"), message: "\(error)")
            }
        }
    }

    private func rename() {
        guard let parent = window?.window, let target = contextTarget else { return }
        Dialogs.prompt(parent, title: tr("Rename"), initial: target.url.lastPathComponent, confirm: tr("Rename")) { [weak self] name in
            guard let self, let name, name != target.url.lastPathComponent else { return }
            let destination = target.url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: target.url, to: destination)
                self.window?.fileMoved(from: target.url, to: destination)
                self.reload()
            } catch {
                Dialogs.message(parent, title: tr("Couldn’t Rename"), message: "\(error)")
            }
        }
    }

    private func delete() {
        guard let parent = window?.window, let target = contextTarget else { return }
        Dialogs.confirm(parent, title: tr("Move “%@” to the Trash?", target.url.lastPathComponent),
                        message: tr("You can restore it from the trash."), action: tr("Move to Trash")) { [weak self] ok in
            guard let self, ok else { return }
            let file = g_file_new_for_path(target.url.path)
            var error: UnsafeMutablePointer<GError>?
            if g_file_trash(file, nil, &error) == 0 {
                let message = error.map { String(cString: $0.pointee.message) } ?? tr("Unknown error")
                if let error { g_error_free(error) }
                Dialogs.message(parent, title: tr("Couldn’t Move to Trash"), message: message)
            }
            g_object_unref(UnsafeMutableRawPointer(file))
            self.window?.fileDeleted(target.url)
            self.reload()
        }
    }

    private func showInFiles() {
        guard let target = contextTarget, let parent = window?.window else { return }
        let file = g_file_new_for_path(target.url.path)
        let launcher = gtk_file_launcher_new(file)
        gtk_file_launcher_open_containing_folder(launcher, cast(raw(parent)), nil, nil, nil)
    }
}
