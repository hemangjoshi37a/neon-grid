/* Neon-Grid welcome screen: covers the gap between the login screen and the desktop.
 *
 * Started from ~/.xprofile as soon as X is up. It paints the wallpaper with a live Material
 * animation on every monitor and lets all clicks and keys through. The neon-motion Cinnamon
 * extension fades it into the desktop and ends it. Without that it goes away by itself:
 * GRACE seconds after a compositor is running, or LIMIT seconds after it started, whichever
 * comes first. It never grabs the keyboard or mouse.
 *
 * It shows the same picture in two windows. The "shield" lives in the composite overlay, above
 * whatever Cinnamon paints, so nothing flashes while Cinnamon takes the screen over. The normal
 * window is what Cinnamon sees and can fade. SIGUSR1 (from the extension, once the desktop is
 * ready) takes the shield away; SIGTERM ends it all.
 *
 * The login screen (neon-login) ends on this same picture at rest, and the graphics server keeps
 * it visible while it starts. So the drawing begins at rest, in the same pose, and eases into
 * motion. If that picture is not there it fades in instead, from black or over the wallpaper.
 *
 *   cc -O2 -o neon-splash neon-splash.c $(pkg-config --cflags --libs cairo x11 xext xrandr xcomposite) -lm
 *   neon-splash [seconds]      (a number = demo: ends after that many seconds)
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xcomposite.h>
#include <X11/extensions/Xrandr.h>
#include <X11/extensions/shape.h>
#include <cairo-xlib.h>
#include <math.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define LIMIT 70.0
#define GRACE 45.0         /* Cinnamon can be slow right after booting: keep the picture until it is ready */
#define FADE_IN 0.9
#define MAXMON 8
#define BOX 460            /* animated square in the middle of each monitor */

typedef struct { double r, g, b; } Col;
typedef struct { int x, y, w, h; } Mon;

static volatile sig_atomic_t stop, unshield;
static Display *dpy;
static Window root, win, over, shield;
static Visual *vis;
static int W, H, nmon;
static Mon mon[MAXMON];
static cairo_surface_t *wall, *back, *buf;
static Col bg = {.03, .04, .08}, text = {.92, .92, .9}, acc = {.75, .81, .5}, acc2 = {.63, .82, .77}, cont = {.25, .3, .04};
static char who[64];

static void on_term(int s) { (void)s; stop = 1; }
static void on_usr1(int s) { (void)s; unshield = 1; }
static int x_err(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }
static int x_io(Display *d) { (void)d; _exit(0); }

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static double clamp(double v, double a, double b) { return v < a ? a : v > b ? b : v; }
static double ease_in_out(double t) { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); }
/* cubic bezier .05,.7,.1,1 (quick start, long soft landing), solved for x by bisection */
static double ease(double t) {
    double lo = 0, hi = 1, u = t;
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    for (int i = 0; i < 22; i++) {
        u = (lo + hi) / 2;
        double x = 3 * .05 * u * (1 - u) * (1 - u) + 3 * .1 * u * u * (1 - u) + u * u * u;
        if (x < t) lo = u; else hi = u;
    }
    return 3 * .7 * u * (1 - u) * (1 - u) + 3 * u * u * (1 - u) + u * u * u;
}

static void set(cairo_t *c, Col k, double a) { cairo_set_source_rgba(c, k.r, k.g, k.b, a); }

static void load(void) {
    char p[512], key[32];
    const char *home = getenv("HOME");
    unsigned v;
    if (!home) return;
    snprintf(p, sizeof p, "%s/.cache/neon-grid/splash.txt", home);
    FILE *f = fopen(p, "r");
    if (f) {
        while (fscanf(f, "%31s #%6x", key, &v) == 2) {
            Col c = {(v >> 16 & 255) / 255.0, (v >> 8 & 255) / 255.0, (v & 255) / 255.0};
            if (!strcmp(key, "bg")) bg = c;
            else if (!strcmp(key, "text")) text = c;
            else if (!strcmp(key, "primary")) acc = c;
            else if (!strcmp(key, "tertiary")) acc2 = c;
            else if (!strcmp(key, "container")) cont = c;
        }
        fclose(f);
    }
    snprintf(p, sizeof p, "%s/.cache/neon-grid/splash.png", home);
    wall = cairo_image_surface_create_from_png(p);
    if (cairo_surface_status(wall) != CAIRO_STATUS_SUCCESS) { cairo_surface_destroy(wall); wall = NULL; }
    struct passwd *pw = getpwuid(getuid());
    if (getenv("NEON_NAME")) snprintf(who, sizeof who, "%s", getenv("NEON_NAME"));
    else if (pw) {
        snprintf(who, sizeof who, "%s", pw->pw_gecos && pw->pw_gecos[0] && pw->pw_gecos[0] != ',' ? pw->pw_gecos : pw->pw_name);
        char *c = strchr(who, ',');
        if (c) *c = 0;
    }
}

static void monitors(void) {
    int n = 0;
    nmon = 0;
    XRRMonitorInfo *m = XRRGetMonitors(dpy, root, True, &n);
    for (int i = 0; m && i < n && nmon < MAXMON; i++)
        if (m[i].width > 0) mon[nmon++] = (Mon){m[i].x, m[i].y, m[i].width, m[i].height};
    if (m) XRRFreeMonitors(m);
    if (!nmon) mon[nmon++] = (Mon){0, 0, W, H};
}

/* the still part: wallpaper, darkened towards the middle so the text reads well */
static void paint_back(void) {
    if (back) cairo_surface_destroy(back);
    if (buf) cairo_surface_destroy(buf);
    cairo_surface_t *ws = cairo_xlib_surface_create(dpy, win, vis, W, H);
    back = cairo_surface_create_similar(ws, CAIRO_CONTENT_COLOR, W, H);
    buf = cairo_surface_create_similar(ws, CAIRO_CONTENT_COLOR, BOX, BOX);
    cairo_t *c = cairo_create(back);
    set(c, bg, 1);
    cairo_paint(c);
    for (int i = 0; i < nmon; i++) {
        Mon *m = &mon[i];
        cairo_save(c);
        cairo_rectangle(c, m->x, m->y, m->w, m->h);
        cairo_clip(c);
        if (wall) {
            double iw = cairo_image_surface_get_width(wall), ih = cairo_image_surface_get_height(wall);
            double k = fmax(m->w / iw, m->h / ih);
            cairo_save(c);
            cairo_translate(c, m->x + (m->w - iw * k) / 2, m->y + (m->h - ih * k) / 2);
            cairo_scale(c, k, k);
            cairo_set_source_surface(c, wall, 0, 0);
            cairo_pattern_set_filter(cairo_get_source(c), CAIRO_FILTER_BILINEAR);
            cairo_paint(c);
            cairo_restore(c);
        }
        double cx = m->x + m->w / 2.0, cy = m->y + m->h / 2.0;
        cairo_pattern_t *g = cairo_pattern_create_radial(cx, cy, 60, cx, cy, fmax(m->w, m->h) * 0.62);
        cairo_pattern_add_color_stop_rgba(g, 0, bg.r, bg.g, bg.b, 0.74);
        cairo_pattern_add_color_stop_rgba(g, 0.35, bg.r, bg.g, bg.b, 0.5);
        cairo_pattern_add_color_stop_rgba(g, 1, bg.r, bg.g, bg.b, 0.28);
        cairo_set_source(c, g);
        cairo_paint(c);
        cairo_pattern_destroy(g);
        cairo_restore(c);
    }
    cairo_destroy(c);
    cairo_surface_destroy(ws);
}

/* the whole still picture, at brightness a (0 = black) */
static void show_back(Window w, double a) {
    cairo_surface_t *ws = cairo_xlib_surface_create(dpy, w, vis, W, H);
    cairo_t *c = cairo_create(ws);
    if (a < 0.999) {
        cairo_push_group(c);
        cairo_set_source_rgb(c, 0, 0, 0);
        cairo_paint(c);
    }
    cairo_set_source_surface(c, back, 0, 0);
    cairo_paint_with_alpha(c, a);
    if (a < 0.999) {
        cairo_pop_group_to_source(c);
        cairo_paint(c);
    }
    cairo_destroy(c);
    cairo_surface_destroy(ws);
}

static void cookie(cairo_t *c, double cx, double cy, double r, double amp, int n, double rot) {
    cairo_new_path(c);
    for (int i = 0; i <= 240; i++) {
        double a = i / 240.0 * 2 * M_PI, q = r * (1 + amp * cos(n * a));
        cairo_line_to(c, cx + q * cos(a + rot), cy + q * sin(a + rot));
    }
    cairo_close_path(c);
}

static double label(cairo_t *c, const char *s, double cx, double y, const char *face, double size, int bold, Col k, double a) {
    cairo_text_extents_t e;
    cairo_select_font_face(c, face, CAIRO_FONT_SLANT_NORMAL, bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(c, size);
    cairo_text_extents(c, s, &e);
    set(c, k, a);
    cairo_move_to(c, cx - e.x_advance / 2, y);
    cairo_show_text(c, s);
    return e.x_advance;
}

/* time that starts slowly: at rest at 0, full speed after 0.9 s */
static double phase(double t) {
    double u = clamp(t / 0.9, 0, 1);
    return t >= 0.9 ? t - 0.45 : 0.9 * (u * u * u - u * u * u * u / 2);
}

/* what the screen shows now: 2 = our picture from the login screen, 1 = something, 0 = black */
static int on_screen(void) {
    int hit = 0, lit = 0, all = 0;
    XImage *im = NULL;
    Mon *m = &mon[0];
    int cx = m->x + m->w / 2, cy = m->y + m->h / 2 - BOX / 2 + 160;
    im = XGetImage(dpy, root, cx - 70, cy - 70, 141, 141, AllPlanes, ZPixmap);
    if (!im) return 0;
    for (int k = 0; k < 24; k++) {
        double a = k * 2 * M_PI / 24;
        unsigned long p = XGetPixel(im, 70 + (int)(60 * cos(a)), 70 + (int)(60 * sin(a)));
        double r = (p >> 16 & 255) / 255.0, g = (p >> 8 & 255) / 255.0, b = (p & 255) / 255.0;
        if (fabs(r - acc.r) + fabs(g - acc.g) + fabs(b - acc.b) < 0.42) hit++;
        if (r + g + b > 0.12) lit++;
        all++;
    }
    XDestroyImage(im);
    return hit > all * 3 / 4 ? 2 : lit > all / 3 ? 1 : 0;
}

static void frame(double t, double bright, double in) {
    double p = phase(t);
    time_t tt = time(NULL);
    struct tm *lt = localtime(&tt);
    const char *hi = lt->tm_hour < 5 ? "GOOD NIGHT" : lt->tm_hour < 12 ? "GOOD MORNING" : lt->tm_hour < 17 ? "GOOD AFTERNOON" : "GOOD EVENING";
    Window to[2] = {win, shield};
    for (int i = 0; i < nmon; i++) {
        double ox = mon[i].x + mon[i].w / 2 - BOX / 2, oy = mon[i].y + mon[i].h / 2 - BOX / 2;
        cairo_t *c = cairo_create(buf);
        cairo_set_source_surface(c, back, -ox, -oy);
        cairo_paint(c);
        double cx = BOX / 2.0, cy = 160, a = in;
        t = p;
        double s = 0.8 + 0.2 * in;
        /* turning shapes */
        cookie(c, cx, cy, 92 * s, 0.085, 9, t * 0.55);
        set(c, cont, 0.75 * a); cairo_fill(c);
        cookie(c, cx, cy, 74 * s, 0.10, 8, -t * 0.8);
        set(c, acc, 0.92 * a); cairo_fill(c);
        cookie(c, cx, cy, 46 * s, 0.12, 6, t * 1.1);
        set(c, bg, 0.85 * a); cairo_fill(c);
        /* clock hands of light */
        cairo_set_line_cap(c, CAIRO_LINE_CAP_ROUND);
        for (int k = 0; k < 3; k++) {
            double st = t * (2.4 - 0.5 * k) + k * 2.1, len = 0.6 + 0.5 * sin(t * 1.7 + k);
            cairo_new_path(c);
            cairo_arc(c, cx, cy, 118 * s + k * 11, st, st + len);
            cairo_set_line_width(c, 4 - k);
            set(c, k == 1 ? acc2 : acc, (0.95 - 0.25 * k) * a);
            cairo_stroke(c);
        }
        for (int k = 0; k < 6; k++) {
            double q = t * 1.3 + k * M_PI / 3, rr = 27 * s;
            cairo_new_path(c);
            cairo_arc(c, cx + rr * cos(q), cy + rr * sin(q), 3.2 + 1.6 * sin(t * 4 + k), 0, 2 * M_PI);
            set(c, k % 2 ? acc2 : acc, a); cairo_fill(c);
        }
        /* words */
        double b = in;
        label(c, hi, cx, 352 + 14 * (1 - b), "Orbitron", 13, 0, text, 0.8 * b);
        label(c, who[0] ? who : "", cx, 386 + 18 * (1 - b), "Orbitron", 24, 1, text, b);
        /* wavy line */
        double w = 190, x0 = cx - w / 2, y0 = 424, d = in;
        cairo_new_path(c);
        for (int k = 0; k <= 95; k++) {
            double f = k / 95.0;
            if (f > d) break;
            double env = sin(f * M_PI);
            cairo_line_to(c, x0 + w * f, y0 + 5 * env * sin(f * 26 - t * 7));
        }
        cairo_set_line_width(c, 3.5);
        cairo_set_line_join(c, CAIRO_LINE_JOIN_ROUND);
        set(c, acc, 0.95 * a);
        cairo_stroke(c);
        if (bright < 0.999) {
            cairo_set_source_rgba(c, 0, 0, 0, 1 - bright);
            cairo_paint(c);
        }
        cairo_destroy(c);
        for (int k = 0; k < 2; k++) {
            if (!to[k]) continue;
            cairo_surface_t *ws = cairo_xlib_surface_create(dpy, to[k], vis, W, H);
            c = cairo_create(ws);
            cairo_set_source_surface(c, buf, ox, oy);
            cairo_rectangle(c, ox, oy, BOX, BOX);
            cairo_fill(c);
            cairo_destroy(c);
            cairo_surface_destroy(ws);
        }
    }
    XFlush(dpy);
}

static void opacity(double a) {
    unsigned long v = (unsigned long)(clamp(a, 0, 1) * 0xffffffffUL);
    XChangeProperty(dpy, win, XInternAtom(dpy, "_NET_WM_WINDOW_OPACITY", False), XA_CARDINAL, 32,
        PropModeReplace, (unsigned char *)&v, 1);
}

int main(int argc, char **argv) {
    double demo = argc > 1 ? atof(argv[1]) : 0, limit = demo > 0 ? demo : LIMIT;
    signal(SIGUSR1, on_usr1);
    signal(SIGTERM, on_term); signal(SIGINT, on_term); signal(SIGHUP, on_term);
    alarm((unsigned)limit + 4);                     /* last resort */
    if (!(dpy = XOpenDisplay(NULL))) return 0;
    XSetErrorHandler(x_err);
    XSetIOErrorHandler(x_io);
    int scr = DefaultScreen(dpy), ev = -1, er;
    root = RootWindow(dpy, scr);
    vis = DefaultVisual(dpy, scr);
    W = DisplayWidth(dpy, scr); H = DisplayHeight(dpy, scr);
    load();
    XSetWindowAttributes at = {0};
    at.override_redirect = True;
    at.background_pixmap = None;                    /* keeps whatever is there: no black flash */
    at.event_mask = ExposureMask;
    win = XCreateWindow(dpy, root, 0, 0, W, H, 0, CopyFromParent, InputOutput, CopyFromParent,
        CWOverrideRedirect | CWBackPixmap | CWEventMask, &at);
    XClassHint ch = {(char *)"neon-splash", (char *)"neon-splash"};
    XSetClassHint(dpy, win, &ch);
    XStoreName(dpy, win, "neon-splash");
    unsigned long pid = (unsigned long)getpid();
    XChangeProperty(dpy, win, XInternAtom(dpy, "_NET_WM_PID", False), XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&pid, 1);
    int sb, se;
    if (!XShapeQueryExtension(dpy, &sb, &se)) return 0;     /* could not let clicks through: do nothing */
    XShapeCombineRectangles(dpy, win, ShapeInput, 0, 0, NULL, 0, ShapeSet, Unsorted);
    int rr = XRRQueryExtension(dpy, &ev, &er);
    if (rr) XRRSelectInput(dpy, root, RRScreenChangeNotifyMask | RRCrtcChangeNotifyMask);
    monitors();
    /* the shield above the compositor; its input goes to whatever is below */
    int cb, ce, cmaj = 0, cmin = 0;
    if (XCompositeQueryExtension(dpy, &cb, &ce) && XCompositeQueryVersion(dpy, &cmaj, &cmin) && (cmaj > 0 || cmin >= 3))
        over = XCompositeGetOverlayWindow(dpy, root);
    if (over) {
        XShapeCombineRectangles(dpy, over, ShapeInput, 0, 0, NULL, 0, ShapeSet, Unsorted);
        XSelectInput(dpy, over, SubstructureNotifyMask);
        shield = XCreateWindow(dpy, over, 0, 0, W, H, 0, CopyFromParent, InputOutput, CopyFromParent,
            CWOverrideRedirect | CWBackPixmap | CWEventMask, &at);
        XShapeCombineRectangles(dpy, shield, ShapeInput, 0, 0, NULL, 0, ShapeSet, Unsorted);
    }
    paint_back();
    int had = on_screen();
    /* if the server repaints before we can, it uses this picture too */
    XSetWindowBackgroundPixmap(dpy, root, cairo_xlib_surface_get_drawable(back));
    if (shield) XMapRaised(dpy, shield);
    XMapRaised(dpy, win);
    if (had == 2 || had == 1) { show_back(win, 1); if (shield) show_back(shield, 1); frame(0, 1, had == 2 ? 1 : 0); }
    /* arrange the monitors now, while the picture is at rest */
    char lay[512];
    snprintf(lay, sizeof lay, "%s/.local/share/neon-grid/neon-layout", getenv("HOME") ? getenv("HOME") : "");
    pid_t child = demo > 0 || access(lay, X_OK) ? -1 : fork();
    if (child == 0) {
        close(ConnectionNumber(dpy));
        execl(lay, lay, "apply", (char *)NULL);
        _exit(0);
    }

    Atom cm = XInternAtom(dpy, "_NET_WM_CM_S0", False);
    double t0 = now(), seen = 0, next = t0, look = 0, leave = 0;
    int fd = ConnectionNumber(dpy), redo = 2, full = 0;
    while (!stop) {
        while (XPending(dpy)) {
            XEvent e;
            XNextEvent(dpy, &e);
            if (rr && e.type >= ev) { XRRUpdateConfiguration(&e); redo = 1; }
            else if (e.type == Expose && e.xexpose.count == 0) redo |= 2;
            else if (shield && (e.type == ReparentNotify || e.type == MapNotify || e.type == CreateNotify ||
                                e.type == ConfigureNotify) && e.xany.window == over) {
                /* Cinnamon's stage has arrived in the overlay: stay above it */
                Window w = e.type == MapNotify ? e.xmap.window : e.type == ReparentNotify ? e.xreparent.window
                    : e.type == CreateNotify ? e.xcreatewindow.window : e.xconfigure.window;
                if (w != shield) { XRaiseWindow(dpy, shield); full = 2; }
            }
        }
        double t = now(), bright = had ? 1 : ease_in_out((t - t0) / FADE_IN);
        double in = had == 2 ? 1 : ease((t - t0 - 0.1) / 0.8);
        if (unshield && shield) {
            XDestroyWindow(dpy, shield);
            XCompositeReleaseOverlayWindow(dpy, root);
            shield = over = 0;
        }
        if (redo) {
            int w = DisplayWidth(dpy, scr), h = DisplayHeight(dpy, scr);
            if (w != W || h != H || redo & 1) {
                int changed = w != W || h != H;
                W = w; H = h;
                if (changed) {
                    XMoveResizeWindow(dpy, win, 0, 0, W, H);
                    if (shield) XMoveResizeWindow(dpy, shield, 0, 0, W, H);
                }
                monitors();
                paint_back();
            }
            full = 2;
            redo = 0;
        }
        if (bright < 1 || full) {
            show_back(win, bright);
            if (shield) show_back(shield, bright);
            if (full) full--;
        }
        if (t - look > 0.25) {
            look = t;
            if (!seen && XGetSelectionOwner(dpy, cm) != None) seen = t;
            if (!leave) { XRaiseWindow(dpy, win); if (shield) XRaiseWindow(dpy, shield); }
        }
        if (!leave && (t - t0 > limit || (!demo && seen && t - seen > GRACE))) leave = t;
        if (leave) {                                /* nobody came for us: fade out ourselves */
            unshield = 1;
            double f = (t - leave) / 0.5;
            if (f >= 1) break;
            opacity(1 - f * f * (3 - 2 * f));
        }
        if (child > 0 && waitpid(child, NULL, WNOHANG) == child) { child = -1; t0 = had == 2 ? now() : t0; }
        frame(child > 0 && had == 2 ? 0 : t - t0, bright, in);
        next += 1 / 60.0;
        double wait = next - now();
        if (wait < 0) { next = now(); wait = 0.001; }
        fd_set fs;
        FD_ZERO(&fs); FD_SET(fd, &fs);
        struct timeval tv = {0, (long)(wait * 1e6)};
        select(fd + 1, NULL, NULL, NULL, &tv);
    }
    XSetWindowBackground(dpy, root, BlackPixel(dpy, scr));
    if (shield) XCompositeReleaseOverlayWindow(dpy, root);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
