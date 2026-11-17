import CAdw
import CSource
import Foundation

/// Fenêtre d'autocomplétion d'un éditeur, comme Xcode : s'ouvre sous le mot en cours dès qu'on tape un
/// identifiant ou un « . », se filtre à chaque frappe ; ↑ ↓ pour choisir, Entrée ou Tab pour insérer,
/// Échap pour fermer, Ctrl+Espace pour la demander.
final class CompletionController {
    /// Demande au serveur de langage : texte, ligne et colonne UTF-16 du curseur (à partir de 0).
    typealias Provider = (_ text: String, _ line: Int, _ character: Int, _ done: @escaping ([CompletionItem]) -> Void) -> Void

    private let view: UnsafeMutablePointer<GtkWidget>
    private let buffer: UnsafeMutablePointer<GtkTextBuffer>
    private let popover: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private let scroller: UnsafeMutablePointer<GtkWidget>
    var provider: Provider?

    /// Suggestions reçues pour la demande en cours, et celles affichées (filtrées par le mot tapé).
    private var received: [CompletionItem] = []
    private var shown: [CompletionItem] = []
    private var generation = 0
    private var scheduled = false
    /// Insertion en cours par la complétion elle-même : ne relance pas de demande.
    private var inserting = false
    private static let maxRows = 50

    init(view: UnsafeMutablePointer<GtkWidget>, buffer: UnsafeMutablePointer<GtkTextBuffer>) {
        self.view = view
        self.buffer = buffer
        Self.installStyle()
        popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, view)
        gtk_popover_set_autohide(cast(raw(popover)), 0)
        gtk_popover_set_has_arrow(cast(raw(popover)), 0)
        gtk_popover_set_position(cast(raw(popover)), GTK_POS_BOTTOM)
        gtk_widget_set_halign(popover, GTK_ALIGN_START)
        gtk_widget_add_css_class(popover, "lcode-completion")
        gtk_widget_set_can_focus(popover, 0)

        list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(cast(raw(list)), GTK_SELECTION_BROWSE)
        gtk_widget_set_can_focus(list, 0)
        scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(raw(scroller)), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(cast(raw(scroller)), 1)
        gtk_scrolled_window_set_max_content_height(cast(raw(scroller)), 270)
        gtk_scrolled_window_set_propagate_natural_width(cast(raw(scroller)), 1)
        gtk_widget_set_size_request(scroller, 480, -1)
        gtk_scrolled_window_set_child(cast(raw(scroller)), list)
        gtk_popover_set_child(cast(raw(popover)), scroller)

        // Clic (ou double clic) sur une suggestion : insertion.
        connectArg(raw(list), "row-activated") { [weak self] row in
            guard let self, let row else { return }
            let index = Int(gtk_list_box_row_get_index(row.assumingMemoryBound(to: GtkListBoxRow.self)))
            if index < self.shown.count { self.accept(self.shown[index]) }
        }
    }

    var isVisible: Bool { gtk_widget_get_visible(popover) != 0 }

    func hide() {
        generation += 1
        if isVisible { gtk_popover_popdown(cast(raw(popover))) }
    }

    // MARK: - Déclenchement

    /// Après une modification du texte : demande des suggestions si l'on tape un identifiant ou après un « . ».
    func textChanged() {
        guard !inserting, provider != nil else { return }
        let (word, cursor) = wordBeforeCursor()
        var it = cursor
        if inCommentOrString(&it) { hide(); return }
        let before = charBefore(cursor, skipping: word.utf16.count)
        if let first = word.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) {
            if isVisible { filter(word) }
            schedule()
        } else if word.isEmpty, before == "." {
            schedule()
        } else {
            hide()
        }
    }

    /// Ctrl+Espace : demande immédiate, même sans mot commencé.
    func trigger() {
        request()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        after(110) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.request()
        }
    }

    private func request() {
        guard let provider else { return }
        generation += 1
        let current = generation
        var cursor = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer))
        let line = Int(gtk_text_iter_get_line(&cursor))
        var lineStart = cursor
        gtk_text_iter_set_line_offset(&lineStart, 0)
        let character = slice(&lineStart, &cursor).utf16.count
        provider(fullText, line, character) { [weak self] items in
            guard let self, current == self.generation else { return }
            self.received = items
            self.filter(self.wordBeforeCursor().word)
        }
    }

    // MARK: - Affichage

    /// Garde les suggestions qui commencent par le mot tapé (sans tenir compte de la casse), puis celles qui le
    /// contiennent ; l'ordre de pertinence du serveur est conservé dans chaque groupe.
    private func filter(_ word: String) {
        let w = word.lowercased()
        var items = received
        if !w.isEmpty {
            let prefix = received.filter { $0.filterText.lowercased().hasPrefix(w) }
            let inner = received.filter { !$0.filterText.lowercased().hasPrefix(w) && $0.filterText.lowercased().contains(w) }
            items = prefix + inner
        }
        // Mot déjà complet et seule suggestion : rien à proposer.
        if items.count == 1, items[0].insertText == word { items = [] }
        shown = Array(items.prefix(Self.maxRows))
        guard !shown.isEmpty else { hide(); return }
        rebuildRows()
        place(wordLength: word.count)
        if !isVisible { gtk_popover_popup(cast(raw(popover))) }
    }

    private func rebuildRows() {
        while let child = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(raw(list)), child) }
        for item in shown {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            gtk_widget_set_margin_start(row, 4); gtk_widget_set_margin_end(row, 6)
            let (letter, style) = Self.badge(item.kind)
            let badge = gtk_label_new(letter)!
            gtk_widget_add_css_class(badge, "lcode-kind")
            gtk_widget_add_css_class(badge, style)
            gtk_widget_set_valign(badge, GTK_ALIGN_CENTER)
            let label = gtk_label_new(item.label)!
            gtk_widget_add_css_class(label, "lcode-completion-label")
            gtk_label_set_xalign(cast(raw(label)), 0)
            gtk_label_set_ellipsize(cast(raw(label)), PANGO_ELLIPSIZE_END)
            gtk_widget_set_hexpand(label, 1)
            gtk_label_set_width_chars(cast(raw(label)), 30)
            gtk_label_set_max_width_chars(cast(raw(label)), 56)
            let detail = gtk_label_new(item.detail)!
            gtk_widget_add_css_class(detail, "dim-label")
            gtk_widget_add_css_class(detail, "caption")
            gtk_label_set_ellipsize(cast(raw(detail)), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(cast(raw(detail)), 22)
            gtk_box_append(cast(raw(row)), badge)
            gtk_box_append(cast(raw(row)), label)
            gtk_box_append(cast(raw(row)), detail)
            gtk_list_box_append(cast(raw(list)), row)
        }
        select(0)
    }

    /// Place la fenêtre sous le début du mot en cours.
    private func place(wordLength: Int) {
        var cursor = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer))
        var start = cursor
        gtk_text_iter_backward_chars(&start, Int32(wordLength))
        var rect = GdkRectangle()
        gtk_text_view_get_iter_location(cast(raw(view)), &start, &rect)
        var x: Int32 = 0, y: Int32 = 0
        gtk_text_view_buffer_to_window_coords(cast(raw(view)), GTK_TEXT_WINDOW_WIDGET, rect.x, rect.y, &x, &y)
        var target = GdkRectangle(x: x - 30, y: y, width: 1, height: rect.height)
        gtk_popover_set_pointing_to(cast(raw(popover)), &target)
    }

    private var selectedIndex: Int {
        guard let row = gtk_list_box_get_selected_row(cast(raw(list))) else { return 0 }
        return Int(gtk_list_box_row_get_index(row))
    }

    private func select(_ index: Int) {
        guard !shown.isEmpty else { return }
        let i = max(0, min(shown.count - 1, index))
        guard let row = gtk_list_box_get_row_at_index(cast(raw(list)), Int32(i)) else { return }
        gtk_list_box_select_row(cast(raw(list)), row)
        // Garde la ligne choisie visible (lignes de hauteur égale).
        let adj = gtk_scrolled_window_get_vadjustment(cast(raw(scroller)))
        let h = Double(max(1, gtk_widget_get_height(UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkWidget.self))))
        let top = Double(i) * h, page = gtk_adjustment_get_page_size(adj), value = gtk_adjustment_get_value(adj)
        if top < value { gtk_adjustment_set_value(adj, top) } else if top + h > value + page { gtk_adjustment_set_value(adj, top + h - page) }
    }

    // MARK: - Clavier

    /// Touches traitées quand la fenêtre est ouverte ; renvoie vrai si la touche est consommée.
    func handleKey(_ keyval: guint, ctrl: Bool) -> Bool {
        if ctrl && Int32(keyval) == GDK_KEY_space { trigger(); return true }
        guard isVisible else { return false }
        switch Int32(keyval) {
        case GDK_KEY_Down: select(selectedIndex + 1); return true
        case GDK_KEY_Up: select(selectedIndex - 1); return true
        case GDK_KEY_Page_Down: select(selectedIndex + 8); return true
        case GDK_KEY_Page_Up: select(selectedIndex - 8); return true
        case GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_Tab:
            let i = selectedIndex
            if i < shown.count { accept(shown[i]) }
            return true
        case GDK_KEY_Escape: hide(); return true
        case GDK_KEY_Left, GDK_KEY_Right, GDK_KEY_Home, GDK_KEY_End: hide(); return false
        default: return false
        }
    }

    // MARK: - Insertion

    /// Remplace le mot en cours par la suggestion ; pour un appel avec arguments, le curseur va entre les parenthèses.
    private func accept(_ item: CompletionItem) {
        hide()
        let (word, cursor) = wordBeforeCursor()
        var end = cursor, start = cursor
        gtk_text_iter_backward_chars(&start, Int32(word.count))
        inserting = true
        gtk_text_buffer_begin_user_action(buffer)
        gtk_text_buffer_delete(buffer, &start, &end)
        gtk_text_buffer_insert(buffer, &start, item.insertText, -1)
        gtk_text_buffer_end_user_action(buffer)
        inserting = false
        if item.insertText.hasSuffix("()"), let open = item.label.firstIndex(of: "("),
           item.label[item.label.index(after: open)...].first != ")" {
            var inside = GtkTextIter()
            gtk_text_buffer_get_iter_at_mark(buffer, &inside, gtk_text_buffer_get_insert(buffer))
            gtk_text_iter_backward_char(&inside)
            gtk_text_buffer_place_cursor(buffer, &inside)
        }
    }

    // MARK: - Texte

    private var fullText: String {
        var a = GtkTextIter(), z = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &a, &z)
        return slice(&a, &z)
    }

    private func slice(_ a: inout GtkTextIter, _ z: inout GtkTextIter) -> String {
        let c = gtk_text_buffer_get_text(buffer, &a, &z, 0)!
        defer { g_free(c) }
        return String(cString: c)
    }

    /// Identifiant juste avant le curseur (lettres, chiffres, _).
    private func wordBeforeCursor() -> (word: String, cursor: GtkTextIter) {
        var cursor = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer))
        var lineStart = cursor
        gtk_text_iter_set_line_offset(&lineStart, 0)
        let line = slice(&lineStart, &cursor)
        let word = line.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return (String(word.reversed()), cursor)
    }

    private func charBefore(_ cursor: GtkTextIter, skipping count: Int) -> Character? {
        var it = cursor
        gtk_text_iter_backward_chars(&it, Int32(count))
        guard gtk_text_iter_backward_char(&it) != 0 else { return nil }
        return Unicode.Scalar(gtk_text_iter_get_char(&it)).map(Character.init)
    }

    private func inCommentOrString(_ iter: inout GtkTextIter) -> Bool {
        var it = iter
        _ = gtk_text_iter_backward_char(&it)
        let source: UnsafeMutablePointer<GtkSourceBuffer> = cast(raw(buffer))
        return gtk_source_buffer_iter_has_context_class(source, &it, "comment") != 0
            || gtk_source_buffer_iter_has_context_class(source, &it, "string") != 0
    }

    // MARK: - Style

    private static func badge(_ kind: CompletionItem.Kind) -> (String, String) {
        switch kind {
        case .type: return ("T", "lcode-kind-type")
        case .function: return ("M", "lcode-kind-function")
        case .property: return ("P", "lcode-kind-property")
        case .variable: return ("V", "lcode-kind-variable")
        case .keyword: return ("K", "lcode-kind-keyword")
        case .other: return ("•", "lcode-kind-other")
        }
    }

    private static var styled = false
    private static func installStyle() {
        guard !styled else { return }
        styled = true
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, """
        popover.lcode-completion > contents { padding: 4px; }
        popover.lcode-completion list { background: transparent; }
        popover.lcode-completion row { padding: 2px 4px; border-radius: 6px; min-height: 24px; }
        .lcode-completion-label { font-family: "Noto Sans Mono", monospace; font-size: 10.5pt; }
        .lcode-kind { min-width: 18px; min-height: 18px; border-radius: 4px; font-weight: bold;
                      font-size: 8.5pt; color: white; }
        .lcode-kind-type { background: #8e5bd0; }
        .lcode-kind-function { background: #3a7bd5; }
        .lcode-kind-property { background: #2f9e8f; }
        .lcode-kind-variable { background: #c07a2c; }
        .lcode-kind-keyword { background: #c2417a; }
        .lcode-kind-other { background: #7a7a80; }
        """)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider), 800)
    }
}
