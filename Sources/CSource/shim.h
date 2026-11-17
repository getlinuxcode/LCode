#include <gtksourceview/gtksource.h>

/* Étiquette d'erreur : soulignement ondulé rouge et fond rosé (lignes signalées par le compilateur). */
static inline GtkTextTag *lcode_error_tag(GtkTextBuffer *buffer) {
    return gtk_text_buffer_create_tag(buffer, "lcode-error", "underline", PANGO_UNDERLINE_ERROR,
                                      "background", "rgba(255,59,48,0.12)", NULL);
}

/* Résultat de recherche mis en évidence. */
static inline GtkTextTag *lcode_search_tag(GtkTextBuffer *buffer) {
    return gtk_text_buffer_create_tag(buffer, "lcode-search", "background", "rgba(255,214,10,0.45)", NULL);
}
