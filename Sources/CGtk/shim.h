#include <gtk/gtk.h>
#include <pango/pangocairo.h>

/* Les macros GLib ne sont pas importées en Swift : petites fonctions d'aide. */
static inline gulong lsim_signal_connect(gpointer instance, const char *signal, GCallback cb, gpointer data) {
    return g_signal_connect_data(instance, signal, cb, data, NULL, 0);
}
