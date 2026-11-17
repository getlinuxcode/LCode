#include <adwaita.h>

/* Helpers for Swift: GLib macros and variadic functions are not imported. */

static inline gulong lcode_connect(gpointer instance, const char *signal, GCallback cb, gpointer data) {
    return g_signal_connect_data(instance, signal, cb, data, NULL, 0);
}

static inline GtkTextTag *lcode_tag(GtkTextBuffer *buffer, const char *name, const char *color, int bold, int italic) {
    return gtk_text_buffer_create_tag(buffer, name, "foreground", color,
                                      "weight", bold ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL,
                                      "style", italic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL, NULL);
}

static inline void lcode_css(const char *css) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, css);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

/* Window-wide shortcut triggering a "win.<name>" action. */
static inline void lcode_shortcut(GtkWidget *window, const char *accel, const char *action) {
    GtkEventController *controller = gtk_shortcut_controller_new();
    gtk_shortcut_controller_set_scope(GTK_SHORTCUT_CONTROLLER(controller), GTK_SHORTCUT_SCOPE_GLOBAL);
    GtkShortcut *shortcut = gtk_shortcut_new(gtk_shortcut_trigger_parse_string(accel),
                                             gtk_named_action_new(action));
    gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(controller), shortcut);
    gtk_widget_add_controller(window, controller);
}

/* items is NULL-terminated. */
static inline GtkWidget *lcode_dropdown(const char *const *items) {
    return gtk_drop_down_new_from_strings(items);
}

static inline GType lcode_application_window_type(void) { return ADW_TYPE_APPLICATION_WINDOW; }
