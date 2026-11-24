/* Smooth wheel scrolling for GTK 3 programs that jump from notch to notch (Nemo, GNOME Terminal).
 *
 * Loaded with GTK_MODULES, only into the programs named below. Every notch of a mouse wheel is handed
 * on as a run of small steps, one for each picture on the screen, so lists and terminals glide.
 * Touchpads, Ctrl+wheel (zoom), Shift and Alt+wheel and widgets that want whole notches stay as they are.
 *
 * cc -O2 -shared -fPIC -o neon-scroll.so neon-scroll.c $(pkg-config --cflags --libs gtk+-3.0)
 */
#include <gtk/gtk.h>
#include <math.h>
#include <string.h>

#define STIFF 13.0          /* 1/s: how quickly the rest of the way is covered */
#define SOFT 0.030          /* s: gentle start */
#define MAX_REST 24.0       /* notches that may be waiting */

static GtkWidget *over;     /* what is being scrolled (weak pointer) */
static GtkWidget *clock_of; /* whose frame clock ticks (weak pointer) */
static guint tick;
static GdkEvent *last;
static double rest_x, rest_y, speed;
static gint64 before;

static void forget(void) {
    if (tick && clock_of) gtk_widget_remove_tick_callback(clock_of, tick);
    tick = 0;
    if (over) g_object_remove_weak_pointer(G_OBJECT(over), (gpointer *)&over);
    if (clock_of) g_object_remove_weak_pointer(G_OBJECT(clock_of), (gpointer *)&clock_of);
    over = clock_of = NULL;
    if (last) gdk_event_free(last);
    last = NULL;
    rest_x = rest_y = speed = 0;
}

static void hand_on(double dx, double dy) {
    GdkEvent *e = gdk_event_copy(last);
    e->scroll.direction = GDK_SCROLL_SMOOTH;
    e->scroll.delta_x = dx;
    e->scroll.delta_y = dy;
    gtk_main_do_event(e);
    gdk_event_free(e);
}

static gboolean step(GtkWidget *w, GdkFrameClock *fc, gpointer data) {
    (void)w; (void)data;
    if (!over || !last || !gtk_widget_get_mapped(over)) { tick = 0; forget(); return G_SOURCE_REMOVE; }
    gint64 now = gdk_frame_clock_get_frame_time(fc);
    double dt = before ? (now - before) / 1e6 : 1 / 120.0;
    before = now;
    if (dt > 0.05) dt = 0.05;
    if (dt < 0.001) dt = 0.001;
    speed += (1 - speed) * (1 - exp(-dt / SOFT));            /* eases in, then eases out */
    double k = 1 - exp(-STIFF * speed * dt), dx = rest_x * k, dy = rest_y * k;
    gboolean end = fabs(rest_x) + fabs(rest_y) < 0.006;
    if (end) { dx = rest_x; dy = rest_y; }
    rest_x -= dx;
    rest_y -= dy;
    hand_on(dx, dy);
    if (end || !over) { tick = 0; forget(); return G_SOURCE_REMOVE; }
    return G_SOURCE_CONTINUE;
}

static void on_event(GdkEvent *e, gpointer data) {
    (void)data;
    if (e->type == GDK_SCROLL) {
        GdkDevice *dev = gdk_event_get_source_device(e);
        GdkInputSource src = dev ? gdk_device_get_source(dev) : GDK_SOURCE_MOUSE;
        GtkWidget *w = gtk_get_event_widget(e);
        GdkModifierType held = e->scroll.state & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_MOD1_MASK | GDK_SUPER_MASK);
        double dx = 0, dy = 0;
        gboolean wheel = TRUE;
        switch (e->scroll.direction) {
        case GDK_SCROLL_UP: dy = -1; break;
        case GDK_SCROLL_DOWN: dy = 1; break;
        case GDK_SCROLL_LEFT: dx = -1; break;
        case GDK_SCROLL_RIGHT: dx = 1; break;
        default: dx = e->scroll.delta_x; dy = e->scroll.delta_y; wheel = dx != 0 || dy != 0;
        }
        if (w && wheel && !held && src == GDK_SOURCE_MOUSE && e->scroll.window &&
            (gdk_window_get_events(e->scroll.window) & GDK_SMOOTH_SCROLL_MASK)) {
            GtkWidget *top = gtk_widget_get_toplevel(w);
            if (GTK_IS_WINDOW(top)) {
                if (over != w || clock_of != top) {
                    forget();
                    over = w;
                    clock_of = top;
                    g_object_add_weak_pointer(G_OBJECT(over), (gpointer *)&over);
                    g_object_add_weak_pointer(G_OBJECT(clock_of), (gpointer *)&clock_of);
                }
                if (dy * rest_y < 0) rest_y = 0;             /* turned round */
                if (dx * rest_x < 0) rest_x = 0;
                rest_x = CLAMP(rest_x + dx, -MAX_REST, MAX_REST);
                rest_y = CLAMP(rest_y + dy, -MAX_REST, MAX_REST);
                if (last) gdk_event_free(last);
                last = gdk_event_copy(e);
                if (!tick) {
                    before = 0;
                    tick = gtk_widget_add_tick_callback(top, step, NULL, NULL);
                }
                return;
            }
        }
    } else if (tick && (e->type == GDK_BUTTON_PRESS || e->type == GDK_KEY_PRESS)) {
        forget();                                            /* a click or a key stops the glide */
    }
    gtk_main_do_event(e);
}

static gboolean start(gpointer data) {
    (void)data;
    gdk_event_handler_set(on_event, NULL, NULL);
    return G_SOURCE_REMOVE;
}

G_MODULE_EXPORT void gtk_module_init(gint *argc, gchar ***argv) {
    (void)argc; (void)argv;
    const char *name = g_get_prgname();
    char *list = g_strdup(g_getenv("NEON_SCROLL_KEEP"));
    /* programs started from here get the environment they would have had */
    if (list) {
        if (*list) g_setenv("GTK_MODULES", list, TRUE); else g_unsetenv("GTK_MODULES");
        g_unsetenv("NEON_SCROLL_KEEP");
    }
    g_free(list);
    if (!name || gtk_get_major_version() != 3) return;
    char *safe = g_build_filename(g_get_user_config_dir(), "neon-grid", "safe-mode", NULL);
    gboolean off = g_file_test(safe, G_FILE_TEST_EXISTS);
    g_free(safe);
    if (off) return;
    if (strcmp(name, "nemo") && strcmp(name, "org.Nemo") && !strstr(name, "gnome-terminal")) return;
    g_idle_add_full(G_PRIORITY_HIGH, start, NULL, NULL);
}

/* the module stays loaded */
G_MODULE_EXPORT const gchar *g_module_check_init(GModule *m) { g_module_make_resident(m); return NULL; }
