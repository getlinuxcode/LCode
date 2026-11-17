import CAdw
import CSource
import Foundation

/// An open file: GtkSourceView with Xcode-like smart indentation, dirty state and error marks.
final class EditorDocument {
    let url: URL
    let view: UnsafeMutablePointer<GtkWidget>
    let buffer: OpaquePointer            // GtkSourceBuffer
    let scroller: UnsafeMutablePointer<GtkWidget>
    var tabLabel: UnsafeMutablePointer<GtkWidget>!
    var dirty = false
    var loading = false
    var onChange: () -> Void = {}
    var onDirty: () -> Void = {}
    static let indent = "    "
    private(set) var completion: CompletionController!

    init(url: URL, text: String) {
        self.url = url
        let manager = gtk_source_language_manager_get_default()
        buffer = OpaquePointer(gtk_source_buffer_new(nil)!)
        if url.pathExtension == "swift", let swift = gtk_source_language_manager_get_language(manager, "swift") {
            gtk_source_buffer_set_language(cast(raw(buffer)), swift)
        } else if url.pathExtension == "json" || url.pathExtension == "yml" || url.pathExtension == "yaml" {
            let id = url.pathExtension == "json" ? "json" : "yaml"
            if let lang = gtk_source_language_manager_get_language(manager, id) { gtk_source_buffer_set_language(cast(raw(buffer)), lang) }
        }
        gtk_source_buffer_set_highlight_matching_brackets(cast(raw(buffer)), 1)
        view = gtk_source_view_new_with_buffer(cast(raw(buffer)))!
        scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(raw(scroller)), view)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_widget_set_hexpand(scroller, 1)
        let sv: OpaquePointer = cast(raw(view))
        gtk_source_view_set_show_line_numbers(cast(raw(sv)), 1)
        gtk_source_view_set_highlight_current_line(cast(raw(sv)), 1)
        gtk_source_view_set_auto_indent(cast(raw(sv)), 1)
        gtk_source_view_set_indent_on_tab(cast(raw(sv)), 1)
        gtk_source_view_set_insert_spaces_instead_of_tabs(cast(raw(sv)), 1)
        gtk_source_view_set_tab_width(cast(raw(sv)), 4)
        gtk_source_view_set_indent_width(cast(raw(sv)), 4)
        gtk_source_view_set_smart_backspace(cast(raw(sv)), 1)
        gtk_source_view_set_smart_home_end(cast(raw(sv)), GTK_SOURCE_SMART_HOME_END_BEFORE)
        gtk_text_view_set_monospace(cast(raw(view)), 1)
        gtk_text_view_set_left_margin(cast(raw(view)), 8)
        gtk_text_view_set_top_margin(cast(raw(view)), 6)
        gtk_widget_add_css_class(view, "lcode-editor")
        _ = lcode_error_tag(cast(raw(buffer)))
        _ = lcode_search_tag(cast(raw(buffer)))
        // Xcode colors for types and declared names, with light and dark tag sets so appearance switches instantly.
        for kind in [SwiftHighlighter.Kind.type, .declaration, .keyword] {
            for dark in [false, true] {
                let style = SwiftHighlighter.color(kind, dark: dark)
                _ = lcode_tag(cast(raw(buffer)), kind.rawValue + (dark ? "-d" : "-l"), style.color, style.bold ? 1 : 0, 0)
            }
        }
        applyScheme()
        completion = CompletionController(view: view, buffer: cast(raw(buffer)))

        loading = true
        gtk_text_buffer_begin_irreversible_action(cast(raw(buffer)))
        gtk_text_buffer_set_text(cast(raw(buffer)), text, -1)
        gtk_text_buffer_end_irreversible_action(cast(raw(buffer)))
        var start = GtkTextIter()
        gtk_text_buffer_get_start_iter(cast(raw(buffer)), &start)
        gtk_text_buffer_place_cursor(cast(raw(buffer)), &start)
        loading = false

        connect(raw(buffer), "changed") { [weak self] in
            guard let self, !self.loading else { return }
            if !self.dirty { self.dirty = true; self.onDirty() }
            self.onChange()
            self.completion.textChanged()
        }
        installSmartIndent()
        overlayTypes()
    }

    /// Reloads the file if it changed on disk (e.g. edited by SwiftPM).
    func reloadFromDisk() {
        guard let disk = try? String(contentsOf: url, encoding: .utf8), disk != text else { return }
        loading = true
        gtk_text_buffer_begin_irreversible_action(cast(raw(buffer)))
        gtk_text_buffer_set_text(cast(raw(buffer)), disk, -1)
        gtk_text_buffer_end_irreversible_action(cast(raw(buffer)))
        loading = false
        overlayTypes()
    }

    func applyScheme() {
        let manager = gtk_source_style_scheme_manager_get_default()
        let scheme = gtk_source_style_scheme_manager_get_scheme(manager, Settings.isDark ? "lcode-xcode-dark" : "lcode-xcode")
        gtk_source_buffer_set_style_scheme(cast(raw(buffer)), scheme)
    }

    var text: String {
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(cast(raw(buffer)), &start, &end)
        let cString = gtk_text_buffer_get_text(cast(raw(buffer)), &start, &end, 0)!
        defer { g_free(cString) }
        return String(cString: cString)
    }

    func save() throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        dirty = false
        onDirty()
    }

    /// Recolors types and declared names, which GtkSourceView's Swift grammar does not know.
    func overlayTypes() {
        var start = GtkTextIter(), end = GtkTextIter()
        let b: UnsafeMutablePointer<GtkTextBuffer> = cast(raw(buffer))
        gtk_text_buffer_get_bounds(b, &start, &end)
        for name in ["type-l", "type-d", "declaration-l", "declaration-d", "keyword-l", "keyword-d"] {
            gtk_text_buffer_remove_tag_by_name(b, name, &start, &end)
        }
        guard url.pathExtension == "swift" else { return }
        let suffix = Settings.isDark ? "-d" : "-l"
        // Keywords too: the grammar misses some (some, any, await…) and colors `import` differently.
        for token in SwiftHighlighter.tokens(text) where token.kind == .type || token.kind == .declaration || token.kind == .keyword {
            var a = GtkTextIter(), z = GtkTextIter()
            gtk_text_buffer_get_iter_at_offset(b, &a, Int32(token.start))
            gtk_text_buffer_get_iter_at_offset(b, &z, Int32(token.end))
            gtk_text_buffer_apply_tag_by_name(b, token.kind.rawValue + suffix, &a, &z)
        }
    }

    // MARK: - Errors

    func clearErrors() {
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(cast(raw(buffer)), &start, &end)
        gtk_text_buffer_remove_tag_by_name(cast(raw(buffer)), "lcode-error", &start, &end)
    }

    /// Underlines a 1-based line reported by the compiler.
    func markError(line: Int) {
        var start = GtkTextIter(), end = GtkTextIter()
        let b: UnsafeMutablePointer<GtkTextBuffer> = cast(raw(buffer))
        gtk_text_buffer_get_iter_at_line(b, &start, Int32(max(0, line - 1)))
        end = start
        if gtk_text_iter_ends_line(&end) == 0 { gtk_text_iter_forward_to_line_end(&end) }
        gtk_text_buffer_apply_tag_by_name(b, "lcode-error", &start, &end)
    }

    func goTo(line: Int, column: Int = 1) {
        var iter = GtkTextIter()
        let b: UnsafeMutablePointer<GtkTextBuffer> = cast(raw(buffer))
        gtk_text_buffer_get_iter_at_line_offset(b, &iter, Int32(max(0, line - 1)), Int32(max(0, column - 1)))
        gtk_text_buffer_place_cursor(b, &iter)
        let mark = gtk_text_buffer_get_insert(b)
        gtk_text_view_scroll_to_mark(cast(raw(view)), mark, 0.2, 1, 0, 0.4)
        gtk_widget_grab_focus(view)
    }

    // MARK: - Smart indentation (like Xcode)

    private func installSmartIndent() {
        let controller = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        final class Box { weak var doc: EditorDocument?; init(_ d: EditorDocument) { doc = d } }
        let box = Unmanaged.passRetained(Box(self)).toOpaque()
        let callback: @convention(c) (OpaquePointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, data in
            guard let doc = Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().doc else { return 0 }
            return doc.handleKey(keyval, state) ? 1 : 0
        }
        _ = lcode_connect(raw(controller), "key-pressed", unsafeBitCast(callback, to: GCallback.self), box)
        gtk_widget_add_controller(view, controller)
    }

    private var b: UnsafeMutablePointer<GtkTextBuffer> { cast(raw(buffer)) }

    /// Text of the cursor line before the cursor.
    private func lineBeforeCursor() -> (text: String, cursor: GtkTextIter) {
        var cursor = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(b, &cursor, gtk_text_buffer_get_insert(b))
        var start = cursor
        gtk_text_iter_set_line_offset(&start, 0)
        let c = gtk_text_buffer_get_text(b, &start, &cursor, 0)!
        defer { g_free(c) }
        return (String(cString: c), cursor)
    }

    private func leadingWhitespace(_ s: String) -> String { String(s.prefix { $0 == " " || $0 == "\t" }) }

    private func handleKey(_ keyval: guint, _ state: GdkModifierType) -> Bool {
        let ctrl = state.rawValue & GDK_CONTROL_MASK.rawValue != 0
        let shift = state.rawValue & GDK_SHIFT_MASK.rawValue != 0
        if completion.handleKey(keyval, ctrl: ctrl) { return true }
        switch Int32(keyval) {
        case GDK_KEY_Return, GDK_KEY_KP_Enter:
            guard !ctrl, !shift else { return false }
            return newLine()
        case GDK_KEY_braceright:
            return closeBrace()
        case GDK_KEY_ISO_Left_Tab:
            shiftSelection(by: -1)
            return true
        case GDK_KEY_Tab:
            // With a multi-line selection, indent the block.
            var a = GtkTextIter(), z = GtkTextIter()
            if gtk_text_buffer_get_selection_bounds(b, &a, &z) != 0, gtk_text_iter_get_line(&a) != gtk_text_iter_get_line(&z) {
                shiftSelection(by: shift ? -1 : 1)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Return keeps the indentation, adds a level after { ( [, and between a pair opens an indented line with
    /// the closing bracket moved below at the original indentation.
    private func newLine() -> Bool {
        let (before, cursor) = lineBeforeCursor()
        let base = leadingWhitespace(before)
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let opens = trimmed.last.map { "{([".contains($0) } ?? false
        var next = cursor
        let nextChar = gtk_text_iter_get_char(&next)
        let closesNext = nextChar == UInt32(("}" as Unicode.Scalar).value) || nextChar == UInt32((")" as Unicode.Scalar).value)
            || nextChar == UInt32(("]" as Unicode.Scalar).value)
        gtk_text_buffer_begin_user_action(b)
        if gtk_text_buffer_get_has_selection(b) != 0 { _ = gtk_text_buffer_delete_selection(b, 1, 1) }
        if opens && closesNext {
            let inner = "\n" + base + Self.indent
            gtk_text_buffer_insert_at_cursor(b, inner + "\n" + base, -1)
            var iter = GtkTextIter()
            gtk_text_buffer_get_iter_at_mark(b, &iter, gtk_text_buffer_get_insert(b))
            _ = gtk_text_iter_backward_chars(&iter, Int32(1 + base.count))
            gtk_text_buffer_place_cursor(b, &iter)
        } else {
            gtk_text_buffer_insert_at_cursor(b, "\n" + base + (opens ? Self.indent : ""), -1)
        }
        gtk_text_buffer_end_user_action(b)
        gtk_text_view_scroll_mark_onscreen(cast(raw(view)), gtk_text_buffer_get_insert(b))
        return true
    }

    /// A `}` typed after only whitespace takes the indentation of its matching `{`.
    private func closeBrace() -> Bool {
        let (before, cursor) = lineBeforeCursor()
        guard !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }) else { return false }
        // Scan back for the matching brace (strings and comments are not skipped).
        var start = GtkTextIter()
        gtk_text_buffer_get_start_iter(b, &start)
        var cur = cursor
        let c = gtk_text_buffer_get_text(b, &start, &cur, 0)!
        let textBefore = String(cString: c)
        g_free(c)
        var depth = 0
        var openIndex: String.Index?
        var i = textBefore.endIndex
        while i > textBefore.startIndex {
            i = textBefore.index(before: i)
            let ch = textBefore[i]
            if ch == "}" { depth += 1 }
            if ch == "{" {
                if depth == 0 { openIndex = i; break }
                depth -= 1
            }
        }
        guard let openIndex else { return false }
        let lineStart = textBefore[..<openIndex].lastIndex(of: "\n").map { textBefore.index(after: $0) } ?? textBefore.startIndex
        let indent = leadingWhitespace(String(textBefore[lineStart...]))
        var lineBegin = cursor
        gtk_text_iter_set_line_offset(&lineBegin, 0)
        var end = cursor
        gtk_text_buffer_begin_user_action(b)
        gtk_text_buffer_delete(b, &lineBegin, &end)
        gtk_text_buffer_insert_at_cursor(b, indent + "}", -1)
        gtk_text_buffer_end_user_action(b)
        return true
    }

    /// Indents (+1) or outdents (−1) the selected lines, or the cursor line.
    private func shiftSelection(by step: Int) {
        var a = GtkTextIter(), z = GtkTextIter()
        if gtk_text_buffer_get_selection_bounds(b, &a, &z) == 0 {
            gtk_text_buffer_get_iter_at_mark(b, &a, gtk_text_buffer_get_insert(b))
            z = a
        }
        let first = gtk_text_iter_get_line(&a), last = gtk_text_iter_get_line(&z)
        gtk_text_buffer_begin_user_action(b)
        for line in first...last {
            var s = GtkTextIter()
            gtk_text_buffer_get_iter_at_line(b, &s, line)
            if step > 0 {
                gtk_text_buffer_insert(b, &s, Self.indent, -1)
            } else {
                var e = s
                var removed = 0
                while removed < 4, gtk_text_iter_get_char(&e) == 32 { _ = gtk_text_iter_forward_char(&e); removed += 1 }
                if removed > 0 { gtk_text_buffer_delete(b, &s, &e) }
            }
        }
        gtk_text_buffer_end_user_action(b)
    }

    // MARK: - Find (Ctrl+F)

    /// Highlights all matches and selects the next one after the cursor.
    @discardableResult
    func search(_ needle: String, forward: Bool = true) -> Int {
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(b, &start, &end)
        gtk_text_buffer_remove_tag_by_name(b, "lcode-search", &start, &end)
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var iter = start
        var matchStart = GtkTextIter(), matchEnd = GtkTextIter()
        let flags = GtkTextSearchFlags(GTK_TEXT_SEARCH_CASE_INSENSITIVE.rawValue | GTK_TEXT_SEARCH_TEXT_ONLY.rawValue)
        while gtk_text_iter_forward_search(&iter, needle, flags, &matchStart, &matchEnd, nil) != 0 {
            gtk_text_buffer_apply_tag_by_name(b, "lcode-search", &matchStart, &matchEnd)
            iter = matchEnd
            count += 1
        }
        var cursor = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(b, &cursor, gtk_text_buffer_get_selection_bound(b))
        let found = forward
            ? gtk_text_iter_forward_search(&cursor, needle, flags, &matchStart, &matchEnd, nil) != 0
                || gtk_text_iter_forward_search(&start, needle, flags, &matchStart, &matchEnd, nil) != 0
            : gtk_text_iter_backward_search(&cursor, needle, flags, &matchStart, &matchEnd, nil) != 0
        if found {
            gtk_text_buffer_select_range(b, &matchEnd, &matchStart)
            gtk_text_view_scroll_to_iter(cast(raw(view)), &matchStart, 0.2, 0, 0, 0)
        }
        return count
    }
}
