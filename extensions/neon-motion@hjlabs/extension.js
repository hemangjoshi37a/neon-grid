// Neon-Grid motion:
//  1. every Cinnamon animation follows a bezier curve instead of a plain one
//  2. the start menu and panel pop-ups unfurl from their button, with frosted glass behind them
//  3. inside the start menu the highlight glides and the wheel scrolls softly
//  4. tooltips and the pop-up menus of applications ease in and out, everywhere
//  5. the desktop glides in after logging in (together with neon-splash)
//
// Each part checks that Cinnamon still offers what it needs and otherwise stays out of the way.
//
// Pop-ups: Cinnamon opens and closes them without its own animation, then we move the finished
// actor with a shader effect only (never its real position), so nothing Cinnamon computes is
// disturbed. Any error means: the pop-up simply opens or closes at once.
const Atk = imports.gi.Atk;
const Cinnamon = imports.gi.Cinnamon;
const Clutter = imports.gi.Clutter;
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const GObject = imports.gi.GObject;
const Graphene = imports.gi.Graphene;
const Meta = imports.gi.Meta;
const Main = imports.ui.main;
const PopupMenu = imports.ui.popupMenu;
const Tooltips = imports.ui.tooltips;
const St = imports.gi.St;

const OPEN_MS = 300, CLOSE_MS = 300;        // start menu
const POPUP_MS = 220;                       // calendar, sound, network ...

// Movement curves (cubic bezier, as in CSS): x1, y1, x2, y2
const CURVE_OPEN = [0.16, 0.84, 0.30, 1.00];    // quick start, soft landing
const CURVE_POPUP = [0.18, 0.60, 0.30, 1.00];   // pop-ups: lands without a long crawl at the end
const CURVE_CLOSE = [0.40, 0.00, 0.70, 0.25];   // gentle lift-off, then away
const CURVE_MOVE = [0.20, 0.00, 0.00, 1.00];    // from one place to another
const CURVE_REVEAL = [0.22, 0.75, 0.25, 1.00];  // desktop settling after login
const CURVE_VEIL = [0.45, 0.00, 0.35, 1.00];    // welcome screen lifting away
const CURVE_FADE = [0.30, 0.00, 0.20, 1.00];    // what used to be a plain fade
const WINDOW_OPEN_MS = 340, WINDOW_CLOSE_MS = 260;
const GLASS_RADIUS = 30, GLASS_CORNER = 14;     // blur and corner radius in pixels

function bezier(c, t) {                          // value of the curve at time t (0..1)
    const at = (a, b, u) => 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u;
    let lo = 0, hi = 1;
    for (let i = 0; i < 18; i++) {
        const m = (lo + hi) / 2;
        if (at(c[0], c[2], m) < t) lo = m; else hi = m;
    }
    return at(c[1], c[3], (lo + hi) / 2);
}

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

let orig = null;
let active = new Map();                     // menu -> {closing, effect, timeline, sources}
let frames = null;                          // test hook: frame times

// The pop-up is painted into a texture and the graphics card does the rest from one number per
// frame: it grows out of its button, the part nearest the button leads and the far part follows,
// coming into focus as it arrives.
const DECL = `
uniform float u_p;        // 0 hidden .. 1 open
uniform vec4 u_anchor;    // anchor x, y, direction x, y
uniform vec4 u_shape;     // smallest scale, lag, texel width, texel height
`;
const SHAPE = `
vec2 c = cogl_tex_coord_in[0].xy;
vec2 away = abs(c - u_anchor.xy);
float vertical = step(0.5, abs(u_anchor.w));
float along = mix(away.x, away.y, vertical);
float side = mix(away.y, away.x, vertical);
float d = clamp(along * 0.8 + side * 0.2, 0.0, 1.0);
float q = clamp(u_p * (1.0 + u_shape.y) - d * u_shape.y, 0.0, 1.0);
float e = q;
float gone = 1.0 - e;
float k = mix(u_shape.x, 1.0, e);
vec2 scale = vec2(k);
scale *= mix(vec2(1.0, 1.0 - 0.08 * gone * along), vec2(1.0 - 0.08 * gone * along, 1.0), vertical);
vec2 src = u_anchor.xy + (c - u_anchor.xy) / scale - u_anchor.zw * 0.04 * gone;
vec2 moved = abs(src - c) / u_shape.zw;          // in pixels
src = mix(src, c, smoothstep(1.2, 0.35, max(moved.x, moved.y)));
float fade = clamp(q * 1.5, 0.0, 1.0);
fade = fade * fade * (3.0 - 2.0 * fade);
`;
const CODE = SHAPE + `
vec4 tex = vec4(0.0);
float r = gone * 5.0;
if (r > 0.15) {
    vec2 px = u_shape.zw * r;
    tex += texture2D(cogl_sampler0, src) * 0.28;
    tex += texture2D(cogl_sampler0, src + vec2(px.x, 0.0)) * 0.12;
    tex += texture2D(cogl_sampler0, src - vec2(px.x, 0.0)) * 0.12;
    tex += texture2D(cogl_sampler0, src + vec2(0.0, px.y)) * 0.12;
    tex += texture2D(cogl_sampler0, src - vec2(0.0, px.y)) * 0.12;
    tex += texture2D(cogl_sampler0, src + px * 0.7) * 0.06;
    tex += texture2D(cogl_sampler0, src - px * 0.7) * 0.06;
    tex += texture2D(cogl_sampler0, src + vec2(px.x, -px.y) * 0.7) * 0.06;
    tex += texture2D(cogl_sampler0, src + vec2(-px.x, px.y) * 0.7) * 0.06;
} else {
    tex = texture2D(cogl_sampler0, src);
}
vec2 in0 = step(vec2(0.0), src) * step(src, vec2(1.0));
cogl_color_out = tex * in0.x * in0.y * fade;
`;
// frosted glass: blurs what is behind (which stays where it is) inside the unfurling shape
const GLASS_DECL = DECL + `
uniform vec2 u_glass;     // blur radius, corner radius
`;
const GLASS_CODE = SHAPE + `
vec2 size = 1.0 / u_shape.zw;
vec2 half_size = size * 0.5;
vec2 pt = abs(src * size - half_size) - half_size + vec2(u_glass.y);
float dist = length(max(pt, vec2(0.0))) + min(max(pt.x, pt.y), 0.0) - u_glass.y;
float mask = clamp(0.5 - dist, 0.0, 1.0) * fade;
vec3 sum = vec3(0.0);
float total = 0.0;
float spin = fract(sin(dot(floor(c * size), vec2(12.9898, 78.233))) * 43758.5453) * 0.9;
for (int i = 0; i < 22; i++) {
    float f = (float(i) + 0.5) / 22.0;
    float ang = float(i) * 2.39996 + spin;
    vec2 at = c + vec2(cos(ang), sin(ang)) * sqrt(f) * u_glass.x * u_shape.zw;
    float w = 1.0 - 0.55 * f;
    sum += texture2D(cogl_sampler0, clamp(at, vec2(0.002), vec2(0.998))).rgb * w;
    total += w;
}
vec3 col = sum / total;
float grey = dot(col, vec3(0.299, 0.587, 0.114));
col = clamp(mix(vec3(grey), col, 1.35), 0.0, 1.0);
col += (spin - 0.45) * 0.018;                               // a little grain
col += vec3(0.05) * smoothstep(3.0, 0.0, abs(dist + 1.5));  // light catching the rim
cogl_color_out = vec4(clamp(col, 0.0, 1.0) * mask, mask);
`;

function shapeUniforms(fx, o, width, height) {
    fx.set_uniform_float(fx.get_uniform_location('u_anchor'), 4, [o.cx, o.cy, o.dx, o.dy]);
    fx.set_uniform_float(fx.get_uniform_location('u_shape'), 4,
        [o.scale, o.lag, 1 / Math.max(1, width), 1 / Math.max(1, height)]);
}

var UnfurlEffect = !Cinnamon.GLSLEffect ? null : GObject.registerClass({GTypeName: `NeonUnfurl${Date.now()}`},
class UnfurlEffect extends Cinnamon.GLSLEffect {
    _init(o, width, height) {
        super._init();
        this.p = 0;
        this._loc = this.get_uniform_location('u_p');
        shapeUniforms(this, o, width, height);
    }

    vfunc_build_pipeline() {
        this.add_glsl_snippet(Cinnamon.SnippetHook.FRAGMENT, DECL, CODE, false);
    }

    setProgress(p) {
        this.p = p;
        this.set_uniform_float(this._loc, 1, [p]);
        this.queue_repaint();
    }
});

var GlassEffect = !Cinnamon.GLSLEffect ? null : GObject.registerClass({GTypeName: `NeonGlass${Date.now()}`},
class GlassEffect extends Cinnamon.GLSLEffect {
    _init() {
        super._init();
        this._loc = this.get_uniform_location('u_p');
        this.set_uniform_float(this.get_uniform_location('u_glass'), 2, [GLASS_RADIUS, GLASS_CORNER]);
    }

    vfunc_build_pipeline() {
        this.add_glsl_snippet(Cinnamon.SnippetHook.FRAGMENT, GLASS_DECL, GLASS_CODE, true);
    }

    shape(o, width, height) { shapeUniforms(this, o, width, height); }

    setProgress(p) {
        this.p = p;
        this.set_uniform_float(this._loc, 1, [p]);
        this.queue_repaint();
    }
});

// ---------- curves for every Cinnamon animation ----------
const points = new Map();
function setCurve(transition, c) {
    let p = points.get(c);
    if (!p) {
        p = [new Graphene.Point({x: c[0], y: c[1]}), new Graphene.Point({x: c[2], y: c[3]})];
        points.set(c, p);
    }
    transition.set_progress_mode(Clutter.AnimationMode.CUBIC_BEZIER);
    transition.set_cubic_bezier_progress(p[0], p[1]);
}

const curveOf = new Map();
for (const name of Object.keys(Clutter.AnimationMode)) {
    if (/BACK|ELASTIC|BOUNCE|STEP|BEZIER|CUSTOM|LAST/.test(name)) continue;
    const c = /^EASE_IN_OUT|^EASE$/.test(name) ? CURVE_MOVE : /OUT/.test(name) ? CURVE_OPEN
        : /IN/.test(name) && name !== 'LINEAR' ? CURVE_CLOSE : name === 'LINEAR' ? CURVE_FADE : CURVE_MOVE;
    curveOf.set(Clutter.AnimationMode[name], c);
}
const NOT_PROPS = new Set(['duration', 'delay', 'mode', 'repeatCount', 'autoReverse', 'animationRequired',
    'onComplete', 'onStopped', 'onUpdate', 'onCompleteScope', 'progress_mode']);
let origEase = null;

function neonEase(props) {
    let curve = null;
    try {
        if (props && props.duration > 0 && !props.repeatCount && !props.autoReverse) {
            curve = curveOf.get(props.mode === undefined ? Clutter.AnimationMode.EASE_OUT_CUBIC : props.mode) || null;
            const wm = Main.wm;
            if (wm && wm._mapping instanceof Set && wm._mapping.has(this)) {
                props = Object.assign({}, props, {duration: WINDOW_OPEN_MS * (wm.window_effect_multiplier || 1)});
                curve = CURVE_OPEN;
            } else if (wm && wm._destroying instanceof Set && wm._destroying.has(this)) {
                props = Object.assign({}, props, {duration: WINDOW_CLOSE_MS * (wm.window_effect_multiplier || 1)});
                curve = CURVE_CLOSE;
            }
        }
    } catch (e) {
        curve = null;
    }
    const names = curve ? Object.keys(props).filter(k => !NOT_PROPS.has(k)) : [];
    origEase.ease.call(this, props);
    if (!curve) return;
    try {
        for (const k of names) {
            const t = this.get_transition(k.replace(/_/g, '-'));
            if (t) setCurve(t, curve);
        }
    } catch (e) { /* the animation simply keeps its own curve */ }
}

function neonEaseProperty(name, target, params) {
    origEase.prop.call(this, name, target, params);
    try {
        if (!params || !(params.duration > 0) || params.repeatCount || params.autoReverse) return;
        const curve = curveOf.get(params.mode || params.progress_mode);
        const t = curve && this.get_transition(name);
        if (t) setCurve(t, curve);
    } catch (e) { /* as above */ }
}

// ---------- frosted glass ----------
let panes = new Map();                      // menu -> {actor, effect, clones, ids}

function addGlass(menu, shape) {
    dropGlass(menu);
    const a = menu.actor;
    const actor = new Clutter.Actor({clip_to_allocation: true, reactive: false});
    // the wallpaper and the windows behind this pop-up, bottom to top
    const box = {x1: a.x, y1: a.y, x2: a.x + a.width, y2: a.y + a.height};
    const behind = [global.window_group.get_children().find(c => /BackgroundActor/.test(c.toString()))];
    for (const w of global.get_window_actors()) {
        if (w.visible && w.opacity > 0 && w.x < box.x2 && w.x + w.width > box.x1 && w.y < box.y2 &&
            w.y + w.height > box.y1)
            behind.push(w);
    }
    const clones = behind.filter(w => w && w.width > 0 && w.height > 0).map(w => {
        const c = new Clutter.Clone({source: w});
        c.neonX = w.x;
        c.neonY = w.y;
        actor.add_child(c);
        return c;
    });
    const effect = new GlassEffect();
    actor.add_effect_with_name('neon-glass', effect);
    const pane = {actor, effect, clones, shape, ids: []};
    const place = () => {
        const w = Math.round(a.width), h = Math.round(a.height), x = Math.round(a.x), y = Math.round(a.y);
        actor.set_position(x, y);
        actor.set_size(w, h);
        clones.forEach(c => c.set_position(c.neonX - x, c.neonY - y));
        effect.shape(pane.shape, w, h);
    };
    place();
    pane.place = place;
    pane.ids.push(a.connect('notify::allocation', () => { try { place(); } catch (e) { dropGlass(menu); } }));
    pane.ids.push(a.connect('destroy', () => dropGlass(menu)));
    pane.ids.push(a.connect('hide', () => dropGlass(menu)));
    Main.uiGroup.insert_child_below(actor, a);
    panes.set(menu, pane);
    a.add_style_class_name('neon-glass');
    return pane;
}

function dropGlass(menu) {
    const pane = panes.get(menu);
    if (!pane) return;
    panes.delete(menu);
    try {
        if (!menu.actor.is_finalized()) {
            for (const id of pane.ids) menu.actor.disconnect(id);
            menu.actor.remove_style_class_name('neon-glass');
        }
    } catch (e) { /* the menu is gone */ }
    pane.actor.destroy();
}

// ---------- inside the start menu ----------
// Cinnamon restyles every entry on each hover and jumps on each wheel click. Here only the two
// entries concerned change, a highlight glides between them, and scrolling follows a spring.
const FOLLOW = 30, SCROLL = 17;             // stiffness of the highlight and of scrolling
let smooths = new Map();                    // applet -> Smooth

class Smooth {
    constructor(applet) {
        this.ap = applet;
        this.ids = [];
        this.views = [applet.applicationsScrollView, applet.categoriesScrollView, applet.sidebarScrollView].filter(v => v);
        this.scrolls = new Map();           // adjustment -> {target, v, last}
        this.goal = null;                   // hovered actor
        this.cur = null;                    // {x, y, w, h, vx, vy ...} in the content of its view
        this.alpha = 0;
        this.port = new Clutter.Actor({reactive: false, clip_to_allocation: true, opacity: 255});
        this.mark = new St.Bin({style_class: 'neon-glide', reactive: false, opacity: 0});
        this.port.add_child(this.mark);
        this.port.hide();
        Main.uiGroup.add_child(this.port);
        for (const v of this.views)
            this.ids.push([v, v.connect('scroll-event', (a, ev) => this.wheel(v, ev))]);
        this.enter = applet._buttonEnterEvent;
        this.leave = applet._buttonLeaveEvent;
        this.toButton = applet._scrollToButton;
        this.display = applet._displayButtons;
        this.rows = new Set();              // entries that are moving
        applet._buttonEnterEvent = b => this.onEnter(b);
        applet._buttonLeaveEvent = b => { this.leave.call(applet, b); this.onLeave(b); };
        applet._scrollToButton = (b, box = applet.applicationsScrollView) => this.onScrollTo(b, box);
        if (typeof this.display === 'function') applet._displayButtons = (...args) => this.onDisplay(args);
        this.tl = new Clutter.Timeline({duration: 1000, repeat_count: -1});
        this.tick = this.tl.connect('new-frame', () => this.frame());
        this.prev = null;
    }

    destroy() {
        this.tl.disconnect(this.tick);
        this.tl.stop();
        delete this.ap._buttonEnterEvent;
        delete this.ap._buttonLeaveEvent;
        delete this.ap._scrollToButton;
        delete this.ap._displayButtons;
        this.restRows();
        for (const [o, id] of this.ids) { try { o.disconnect(id); } catch (e) { /* gone */ } }
        this.port.destroy();
        try { this.ap.menu.actor.remove_style_class_name('neon-smooth'); } catch (e) { /* gone */ }
    }

    opened() {
        this.ap.menu.actor.add_style_class_name('neon-smooth');
        this.hide();
        Main.uiGroup.set_child_above_sibling(this.port, this.ap.menu.actor);
    }

    hide() {
        this.goal = null;
        this.cur = null;
        this.alpha = 0;
        this.mark.opacity = 0;
        this.port.hide();
        this.scrolls.clear();
        this.tl.stop();
        this.restRows();
    }

    viewOf(actor) {
        for (let a = actor; a; a = a.get_parent())
            if (this.views.includes(a)) return a;
        return null;
    }

    run() { if (!this.tl.is_playing()) { this.last = 0; this.tl.start(); } }

    onEnter(b) {
        const ap = this.ap, parent = b.actor.get_parent();
        try {
            if (parent === ap.categoriesBox || !parent) throw null;          // categories: Cinnamon's own way
            const isApp = parent === ap.applicationsBox;
            const clear = o => {
                if (!o || o === b || o.actor.is_finalized()) return;
                if (o.actor.get_parent() === ap.applicationsBox) o.actor.set_style_class_name('appmenu-application-button');
                else o.actor.remove_style_pseudo_class('hover');
                o.actor.remove_accessible_state(Atk.StateType.FOCUSED);
            };
            clear(this.prev);
            if (ap._activeActor && ap._activeActor._delegate) clear(ap._activeActor._delegate);
            if (ap.hoveredCategory) ap.hoveredCategory.remove_style_pseudo_class('hover');
            if (isApp) {
                b.actor.set_style_class_name(`${b.styleClass}-selected`);
                ap.hoveredApp = b.actor;
            } else {
                b.actor.add_style_pseudo_class('hover');
            }
            b.actor.add_accessible_state(Atk.StateType.FOCUSED);
            ap._activeContainer = parent;
            ap._activeActor = b.actor;
            this.prev = b;
        } catch (e) {
            if (e) global.logError('neon-motion menu: ' + e);
            this.enter.call(ap, b);
        }
        this.goal = b.actor;
        this.goneAt = 0;
        this.run();
    }

    onLeave(b) {
        if (this.goal === b.actor) this.goneAt = GLib.get_monotonic_time();
        this.run();
    }

    // ----- scrolling
    limits(adj) { return [adj.lower, Math.max(adj.lower, adj.upper - adj.page_size)]; }

    scrollTo(adj, target) {
        const [lo, hi] = this.limits(adj);
        const st = this.scrolls.get(adj) || {v: 0, last: adj.value};
        st.target = clamp(target, lo, hi);
        this.scrolls.set(adj, st);
        this.run();
    }

    wheel(view, ev) {
        try {
            if (ev.is_pointer_emulated && ev.is_pointer_emulated()) return Clutter.EVENT_STOP;
            const adj = view.get_vscroll_bar().get_adjustment();
            let n = 0;
            const dir = ev.get_scroll_direction();
            if (dir === Clutter.ScrollDirection.UP) n = -1;
            else if (dir === Clutter.ScrollDirection.DOWN) n = 1;
            else if (dir === Clutter.ScrollDirection.SMOOTH) n = ev.get_scroll_delta()[1];
            if (!n) return Clutter.EVENT_PROPAGATE;
            const st = this.scrolls.get(adj);
            const from = st ? st.target : adj.value;
            this.scrollTo(adj, from + n * Math.max(90, Math.pow(adj.page_size, 2 / 3) * 1.35));
            return Clutter.EVENT_STOP;
        } catch (e) {
            return Clutter.EVENT_PROPAGATE;
        }
    }

    onScrollTo(b, box) {
        if (!b) { this.scrolls.delete(box.get_vscroll_bar().get_adjustment()); return this.toButton.call(this.ap, b, box); }
        const adj = box.get_vscroll_bar().get_adjustment();
        const st = this.scrolls.get(adj), now = st ? st.target : adj.value;
        const view = box.get_allocation_box(), it = b.actor.get_allocation_box();
        const height = view.y2 - view.y1;
        let to = now;
        if (this.ap.searchActive && box === this.ap.applicationsScrollView) {       // a new list starts at its top
            this.scrolls.delete(adj);
            return this.toButton.call(this.ap, b, box);
        }
        if (now > it.y1 - 10) to = it.y1 - 10;
        if (height + now < it.y2 + 10) to = it.y2 - height + 10;
        if (to !== now) this.scrollTo(adj, to);
        return undefined;
    }

    // ----- filtering: entries that stay glide to their new place, new ones drift in
    restRows() {
        for (const a of this.rows) {
            try {
                if (a.is_finalized()) continue;
                a.remove_transition('translation-y');
                a.remove_transition('opacity');
                a.set({translation_y: 0, opacity: 255});
                a.set_offscreen_redirect(Clutter.OffscreenRedirect.AUTOMATIC_FOR_OPACITY);
            } catch (e) { /* gone */ }
        }
        this.rows.clear();
    }

    onDisplay(args) {
        const ap = this.ap, box = ap.applicationsBox;
        const still = !origEase || !ap.menu.isOpen || active.has(ap.menu) || !box.mapped;
        if (still) return this.display.apply(ap, args);
        const before = new Map();
        let adj = null;
        try {
            adj = ap.applicationsScrollView.get_vscroll_bar().get_adjustment();
            const top = adj.value - 80, bottom = adj.value + adj.page_size + 80;
            for (const c of box.get_children()) {
                if (!c.visible) continue;
                const b = c.get_allocation_box();
                if (b.y2 < top) continue;
                if (b.y1 > bottom) break;
                before.set(c, {y: b.y1 + c.translation_y - adj.value, o: c.opacity});
            }
        } catch (e) { before.clear(); }
        this.restRows();
        const out = this.display.apply(ap, args);
        try {
            this.animateRows(box, adj, before);
        } catch (e) {
            global.logError('neon-motion menu: ' + e);
            this.restRows();
        }
        return out;
    }

    animateRows(box, adj, before) {
        const go = (a, props, ms, delay) => {
            origEase.ease.call(a, Object.assign({duration: ms, delay, mode: Clutter.AnimationMode.EASE_OUT_QUAD}, props));
            for (const k of Object.keys(props)) {
                const t = a.get_transition(k.replace(/_/g, '-'));
                if (t) setCurve(t, CURVE_POPUP);
            }
        };
        if (this.ap.searchActive) adj.set_value(adj.lower);
        const limit = adj.value + adj.page_size + 60;
        let i = 0, fresh = 0;
        for (const c of box.get_children()) {
            if (!c.visible) continue;
            const b = c.get_allocation_box();            // brings the layout up to date
            if (b.y2 < adj.value - 60) continue;
            if (b.y1 > limit || i > 30) break;
            i++;
            const old = before.get(c), now = b.y1 - adj.value;
            c.set_offscreen_redirect(0);                 // fading a row needs no extra texture
            this.rows.add(c);
            if (old) {
                const d = clamp(old.y - now, -420, 420);
                if (Math.abs(d) > 0.5) { c.translation_y = d; go(c, {translation_y: 0}, 300, 0); }
                if (old.o < 255) { c.opacity = old.o; go(c, {opacity: 255}, 180, 0); }
            } else {
                const wait = Math.min(fresh++ * 14, 140);
                c.translation_y = 16;
                c.opacity = 0;
                go(c, {translation_y: 0}, 300, wait);
                go(c, {opacity: 255}, 200, wait);
            }
        }
    }

    // ----- every frame while something moves
    frame() {
        try {
            const t = GLib.get_monotonic_time() / 1e6;
            const dt = this.last ? clamp(t - this.last, 0.001, 0.05) : 0.012;
            this.last = t;
            let busy = false;
            const step = (o, k, target, w) => {
                const d = o[k] - target, v = o['v' + k] || 0, ex = Math.exp(-w * dt), tmp = (v + w * d) * dt;
                o[k] = target + (d + tmp) * ex;
                o['v' + k] = (v - w * tmp) * ex;
                if (Math.abs(o[k] - target) < 0.25 && Math.abs(o['v' + k]) < 4) { o[k] = target; o['v' + k] = 0; return false; }
                return true;
            };
            for (const [adj, st] of this.scrolls) {
                if (Math.abs(adj.value - st.last) > 1.5) { this.scrolls.delete(adj); continue; }   // somebody else scrolled
                const o = {p: adj.value, vp: st.v};
                const [lo, hi] = this.limits(adj);
                st.target = clamp(st.target, lo, hi);
                const more = step(o, 'p', st.target, SCROLL);
                st.v = o.vp;
                adj.set_value(o.p);
                st.last = adj.value;
                if (more) busy = true; else this.scrolls.delete(adj);
            }
            const g = this.goal;
            if (g && !g.is_finalized() && g.mapped && this.ap.menu.isOpen && !active.has(this.ap.menu)) {
                const view = this.viewOf(g) || this.ap.menu.actor;
                const [vx, vy] = view.get_transformed_position(), [vw, vh] = view.get_transformed_size();
                const [gx, gy] = g.get_transformed_position(), [gw, gh] = g.get_transformed_size();
                const adj = this.views.includes(view) ? view.get_vscroll_bar().get_adjustment() : null;
                const off = adj ? adj.value : 0;
                const to = {x: gx - vx, y: gy - vy + off, w: gw, h: gh};
                if (!this.cur || this.view !== view) { this.cur = Object.assign({}, to); this.alpha = 0; }
                this.view = view;
                for (const k of ['x', 'y', 'w', 'h']) if (step(this.cur, k, to[k], FOLLOW)) busy = true;
                const leaving = this.goneAt && GLib.get_monotonic_time() - this.goneAt > 90000;
                const a = this.alpha + ((leaving ? 0 : 1) - this.alpha) * (1 - Math.exp(-dt * 16));
                if (Math.abs(a - (leaving ? 0 : 1)) > 0.01 || this.goneAt && !leaving) busy = true;
                this.alpha = a;
                this.port.set_position(Math.round(vx), Math.round(vy));
                this.port.set_size(Math.round(vw), Math.round(vh));
                this.mark.set_position(this.cur.x, this.cur.y - off);
                this.mark.set_size(Math.max(1, this.cur.w), Math.max(1, this.cur.h));
                this.mark.opacity = Math.round(255 * a);
                this.port.show();
                if (leaving && a < 0.02) { this.goal = null; this.cur = null; this.port.hide(); }
            } else if (this.port.visible) {
                this.port.hide();
                this.cur = null;
            }
            if (!busy) this.tl.stop();
        } catch (e) {
            global.logError('neon-motion menu: ' + e);
            this.hide();
        }
    }
}

function smoothFor(menu) {
    const ap = menu.launcher;
    if (!ap || !ap.applicationsScrollView || !ap.categoriesScrollView || !ap.applicationsBox ||
        typeof ap._buttonEnterEvent !== 'function' || typeof ap._scrollToButton !== 'function') return null;
    let s = smooths.get(ap);
    if (!s) {
        s = new Smooth(ap);
        smooths.set(ap, s);
        ap.actor.connect('destroy', () => { const x = smooths.get(ap); if (x) { smooths.delete(ap); x.destroy(); } });
    }
    return s;
}

// ---------- pop-ups ----------
function isPanelMenu(menu) {
    try {
        return Main.wm.desktop_effects_menus && Main.animations_enabled && !menu.actor.is_finalized() &&
            menu.sourceActor && !menu.sourceActor.is_finalized() && !!menu.getPanel();
    } catch (e) {
        return false;
    }
}
function isStart(menu) {
    return menu.actor.has_style_class_name('appmenu-background');
}

// point of the pop-up nearest to the button it belongs to, and the direction it comes from
function anchor(menu) {
    const a = menu.actor, s = menu.sourceActor;
    const [sx, sy] = s.get_transformed_position();
    const [sw, sh] = s.get_transformed_size();
    const cx = clamp((sx + sw / 2 - a.x) / Math.max(1, a.width), 0, 1);
    const cy = clamp((sy + sh / 2 - a.y) / Math.max(1, a.height), 0, 1);
    const dx = cx <= 0.001 && sx + sw <= a.x ? -1 : (cx >= 0.999 && sx >= a.x + a.width ? 1 : 0);
    const dy = cy >= 0.999 ? 1 : (cy <= 0.001 ? -1 : 0);
    return {cx, cy, dx: dy ? 0 : dx, dy};
}

function settle(menu) {
    const st = active.get(menu);
    if (!st) return;
    active.delete(menu);
    for (const id of st.sources) GLib.source_remove(id);
    st.sources = [];
    if (st.timeline) {
        for (const id of st.ids) st.timeline.disconnect(id);
        st.timeline.stop();
    }
    try {
        const a = menu.actor;
        if (a.is_finalized()) return;
        if (st.effect) a.remove_effect(st.effect);
        const pane = panes.get(menu);
        if (pane && !st.closing && pane.effect.p !== 1) pane.effect.setProgress(1);
        if (st.closing) {
            dropGlass(menu);
            a.hide();
            a.set_size(-1, -1);
            menu.animating = false;
            menu.emit('menu-animated-closed');
        }
        global.stage.queue_redraw();
    } catch (e) {
        global.logError('neon-motion: ' + e);
    }
}

function begin(menu, closing, from) {
    const a = menu.actor, start = isStart(menu);
    const st = {closing, sources: [], ids: [], effect: null, timeline: null};
    active.set(menu, st);
    const ms = start ? (closing ? CLOSE_MS : OPEN_MS) : POPUP_MS;
    const shape = Object.assign(anchor(menu), {scale: start ? 0.80 : 0.90, lag: start ? 0.55 : 0.3});
    let pane = panes.get(menu) || null;
    try {
        if (!pane && !closing) pane = addGlass(menu, shape);
        if (pane) pane.effect.setProgress(from);
    } catch (e) {
        global.logError('neon-motion glass: ' + e);
        pane = null;
    }
    try {
        const sm = start ? smoothFor(menu) : null;
        if (sm) { if (closing) sm.hide(); else sm.opened(); }
    } catch (e) {
        global.logError('neon-motion menu: ' + e);
    }
    const effect = new UnfurlEffect(shape, a.width, a.height);
    effect.setProgress(from);
    st.effect = effect;
    a.add_effect_with_name('neon-unfurl', effect);
    const tl = new Clutter.Timeline({duration: Math.max(1, Math.round(ms * (Main.wm.window_effect_multiplier || 1)))});
    st.timeline = tl;
    st.ids = [
        tl.connect('new-frame', () => {
            const f = bezier(closing ? CURVE_CLOSE : CURVE_POPUP, tl.get_progress());
            const p = closing ? from * (1 - f) : from + (1 - from) * f;
            effect.setProgress(p);
            if (panes.get(menu) === pane && pane) pane.effect.setProgress(p);
        }),
        tl.connect('completed', () => {
            if (closing) { settle(menu); return; }
            // open: the last frame already shows the menu pixel for pixel, so taking the effect
            // off (a full repaint of the menu) can wait for a quiet moment
            const quiet = GLib.timeout_add(GLib.PRIORITY_LOW, 120, () => {
                st.sources = st.sources.filter(x => x !== quiet);
                if (active.get(menu) === st) settle(menu);
                return GLib.SOURCE_REMOVE;
            });
            st.sources.push(quiet);
        }),
    ];
    const go = () => { if (active.get(menu) === st && !st.started) { st.started = true; tl.start(); } };
    if (closing) {
        go();
    } else {
        // Building the menu is the heavy moment: wait until Cinnamon's own idle work is done,
        // so the first frames are not lost.
        const idle = GLib.idle_add(GLib.PRIORITY_LOW, () => {
            st.sources = st.sources.filter(x => x !== idle); go(); return GLib.SOURCE_REMOVE;
        });
        st.sources.push(idle);
        const late = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 60, () => {
            st.sources = st.sources.filter(x => x !== late); go(); return GLib.SOURCE_REMOVE;
        });
        st.sources.push(late);
    }
    // safety net: never leave a pop-up half way
    const net = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms + 1200, () => {
        st.sources = st.sources.filter(x => x !== net);
        if (active.get(menu) === st) settle(menu);
        return GLib.SOURCE_REMOVE;
    });
    st.sources.push(net);
}

// how far open a pop-up is right now (1 = fully)
function progressOf(menu) {
    const st = active.get(menu);
    return st && st.effect ? st.effect.p : null;
}

function neonOpen(animate) {
    if (!orig || this.isOpen || !isPanelMenu(this)) return orig ? orig.open.call(this, animate) : undefined;
    const from = progressOf(this) || 0;     // reopened while closing: carry on from there
    settle(this);
    orig.open.call(this, false);
    if (!this.isOpen) return undefined;
    try {
        begin(this, false, from);
    } catch (e) {
        global.logError('neon-motion: ' + e);
        settle(this);
    }
    return undefined;
}

function neonClose(animate) {
    if (!orig || !this.isOpen || !isPanelMenu(this) || !this.actor.mapped)
        return orig ? orig.close.call(this, animate) : undefined;
    const menu = this, a = menu.actor;
    const now = progressOf(menu);
    settle(menu);
    const [w, h] = a.get_size();
    const emit = menu.emit, own = Object.prototype.hasOwnProperty.call(menu, 'emit');
    let held = false;
    // Cinnamon closes it for good, except for the final hide, which waits for the animation
    menu.emit = function (name, ...args) {
        if (name === 'menu-animated-closed') { held = true; return undefined; }
        return emit.call(menu, name, ...args);
    };
    a.hide = () => {};
    try {
        a.set_size(w, h);
        orig.close.call(menu, false);
    } finally {
        if (own) menu.emit = emit; else delete menu.emit;
        delete a.hide;
    }
    try {
        if (a.is_finalized()) return undefined;
        if (!a.visible || menu.isOpen) throw new Error('already hidden');
        menu.animating = true;
        begin(menu, true, now === null ? 1 : now);
    } catch (e) {
        global.logError('neon-motion: ' + e);
        if (!active.has(menu)) active.set(menu, {closing: true, sources: [], ids: []});
        settle(menu);
    }
    return undefined;
}

// ---------- tooltips and application pop-ups ----------
const TIP_IN = 190, TIP_OUT = 150;
let origTips = null, tipIds = [], origShould = null;
let ghosts = new Set();

function move(actor, props, ms, curve, done) {
    origEase.ease.call(actor, Object.assign({duration: ms, mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        onStopped: done || (() => {})}, props));
    for (const k of Object.keys(props)) {
        const t = actor.get_transition(k.replace(/_/g, '-'));
        if (t) setCurve(t, curve);
    }
}

// Cinnamon's own tooltips (panel, task bar, menus)
function tipShow(orig) {
    return function (...args) {
        const t = this._tooltip;
        const was = t && t.visible ? t.opacity : 0;
        if (t) { t.neonLeaving = false; t.remove_all_transitions(); }
        const out = orig.apply(this, args);
        try {
            if (t && t.visible && origEase && Main.animations_enabled) {
                const below = t.y + t.height / 2 < global.stage.height / 2;
                t.set_pivot_point(0.5, below ? 0 : 1);
                if (was < 20) t.set({opacity: 0, scale_x: 0.94, scale_y: 0.90, translation_y: below ? -7 : 7});
                move(t, {opacity: 255, scale_x: 1, scale_y: 1, translation_y: 0}, TIP_IN, CURVE_POPUP);
            } else if (t) {
                t.set({opacity: 255, scale_x: 1, scale_y: 1, translation_y: 0});
            }
        } catch (e) { global.logError('neon-motion tooltip: ' + e); }
        return out;
    };
}
function tipHide(orig) {
    return function (...args) {
        const t = this._tooltip;
        if (!t || !t.visible || !t.mapped || t.neonLeaving || !origEase || !Main.animations_enabled)
            return t && t.neonLeaving ? undefined : orig.apply(this, args);
        t.hide = () => {};
        let out;
        try { out = orig.apply(this, args); } finally { delete t.hide; }
        t.neonLeaving = true;
        t.remove_all_transitions();
        const rest = () => {
            if (!t.neonLeaving) return;
            t.neonLeaving = false;
            t.hide();
            t.set({opacity: 255, scale_x: 1, scale_y: 1, translation_y: 0});
        };
        try { move(t, {opacity: 0, scale_x: 0.96, scale_y: 0.94}, TIP_OUT, CURVE_CLOSE, rest); } catch (e) { rest(); }
        return out;
    };
}

// tooltips and menus of applications are windows of their own
function smallType(win) {
    const W = Meta.WindowType;
    return win && [W.TOOLTIP, W.POPUP_MENU, W.DROPDOWN_MENU, W.COMBO, W.MENU].includes(win.get_window_type());
}
function onSmallMap(wm, actor) {
    try {
        const win = actor.meta_window;
        if (!smallType(win) || !origEase || !Main.animations_enabled || actor.width > 1400) return;
        const tip = win.get_window_type() === Meta.WindowType.TOOLTIP;
        const [px, py] = global.get_pointer();
        actor.remove_all_transitions();
        actor.set_pivot_point(clamp((px - actor.x) / Math.max(1, actor.width), 0, 1), clamp((py - actor.y) / Math.max(1, actor.height), 0, 1));
        const op = actor.opacity || 255;
        actor.set({opacity: 0, scale_x: tip ? 0.95 : 0.96, scale_y: tip ? 0.92 : 0.93});
        move(actor, {opacity: op, scale_x: 1, scale_y: 1}, tip ? TIP_IN : 210, CURVE_POPUP, () => {
            if (!actor.is_finalized()) { actor.set({scale_x: 1, scale_y: 1, opacity: op}); actor.set_pivot_point(0, 0); }
        });
    } catch (e) { global.logError('neon-motion pop-up: ' + e); }
}
// a window that closes is gone at once: a picture of it fades instead
function ghost(actor) {
    const w = actor.width, h = actor.height;
    if (!(w > 4 && h > 4) || w > 900 || h > 1100 || ghosts.size > 6 || !actor.get_image) return;
    const image = actor.get_image(null);
    if (!image) return;
    const g = new St.DrawingArea({reactive: false, x: actor.x, y: actor.y, width: w, height: h, opacity: actor.opacity});
    g.connect('repaint', () => {
        const cr = g.get_context();
        cr.setSourceSurface(image, 0, 0);
        cr.paint();
        cr.$dispose();
    });
    g.set_pivot_point(0.5, 0.5);
    ghosts.add(g);
    Main.uiGroup.add_child(g);              // (Cinnamon expects only windows in the window groups)
    move(g, {opacity: 0, scale_x: 0.975, scale_y: 0.965}, TIP_OUT, CURVE_CLOSE, () => { ghosts.delete(g); g.destroy(); });
}

function enableTips() {
    const T = Tooltips.Tooltip && Tooltips.Tooltip.prototype, P = Tooltips.PanelItemTooltip && Tooltips.PanelItemTooltip.prototype;
    if (T && typeof T.show === 'function' && typeof T.hide === 'function') {
        origTips = {show: T.show, hide: T.hide, pshow: P && Object.prototype.hasOwnProperty.call(P, 'show') ? P.show : null};
        T.show = tipShow(origTips.show);
        T.hide = tipHide(origTips.hide);
        if (origTips.pshow) P.show = tipShow(origTips.pshow);
    }
    tipIds.push(global.window_manager.connect('map', onSmallMap));
    if (typeof Main.wm._shouldAnimate === 'function') {
        origShould = Main.wm._shouldAnimate;
        Main.wm._shouldAnimate = function (actor, types = null) {
            try {
                // Cinnamon asks this with a list of types only when a window is closing
                if (types && smallType(actor.meta_window) && origEase && Main.animations_enabled) ghost(actor);
            } catch (e) { /* it simply disappears */ }
            return origShould.call(this, actor, types);
        };
    }
}
function disableTips() {
    for (const id of tipIds) global.window_manager.disconnect(id);
    tipIds = [];
    if (origTips) {
        Tooltips.Tooltip.prototype.show = origTips.show;
        Tooltips.Tooltip.prototype.hide = origTips.hide;
        if (origTips.pshow) Tooltips.PanelItemTooltip.prototype.show = origTips.pshow;
        origTips = null;
    }
    if (origShould) { delete Main.wm._shouldAnimate; origShould = null; }
    for (const g of [...ghosts]) g.destroy();
    ghosts.clear();
}

// ---------- desktop reveal after login ----------
let revealIds = [];
let cover = null;

function splashPid() {
    try {
        const f = Gio.File.new_for_path(GLib.get_user_runtime_dir() + '/neon-splash.pid');
        const [ok, bytes] = f.load_contents(null);
        const pid = parseInt(imports.byteArray.toString(bytes));
        if (!ok || !(pid > 1)) return 0;
        const [ok2, comm] = Gio.File.new_for_path(`/proc/${pid}/comm`).load_contents(null);
        return ok2 && imports.byteArray.toString(comm).trim() === 'neon-splash' ? pid : 0;
    } catch (e) {
        return 0;
    }
}
function endSplash() {
    const pid = splashPid();
    if (pid) GLib.spawn_command_line_async(`kill ${pid}`);
}
function liftShield() {
    const pid = splashPid();
    if (pid) GLib.spawn_command_line_async(`kill -USR1 ${pid}`);
}
function splashActor() {
    return global.get_window_actors().find(a => a.meta_window && a.meta_window.get_wm_class() === 'neon-splash') || null;
}

function later(ms, fn) {
    const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
        revealIds = revealIds.filter(x => x !== id);
        try { fn(); } catch (e) { global.logError('neon-motion reveal: ' + e); endSplash(); uncover(); }
        return GLib.SOURCE_REMOVE;
    });
    revealIds.push(id);
}
function uncover() {
    if (cover) { cover.destroy(); cover = null; }
    try {
        const g = global.window_group;
        g.remove_all_transitions();
        g.set({scale_x: 1, scale_y: 1, translation_x: 0, translation_y: 0});
        for (const p of Main.panelManager.panels) if (p && p.actor) { p.actor.remove_all_transitions(); p.actor.translation_y = 0; p.actor.opacity = 255; }
    } catch (e) { global.logError('neon-motion reveal: ' + e); }
}

function reveal() {
    const a = splashActor();
    if (a) a.remove_all_transitions();
    liftShield();                       // both windows show the same picture, so this is not visible
    later(90, () => revealNow(a && !a.is_finalized() ? a : null));
}

function revealNow(a) {
    const move = (actor, props, ms, curve, delay, done) => {
        origEase.ease.call(actor, Object.assign({duration: ms, delay: delay || 0,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD, onStopped: done || (() => {})}, props));
        for (const k of Object.keys(props)) {
            const t = actor.get_transition(k.replace(/_/g, '-'));
            if (t) setCurve(t, curve);
        }
    };
    // the desktop settles from slightly nearer ...
    // (the group has no size of its own, so the centre is kept in place by hand)
    const g = global.window_group, k = 1.05;
    g.set({scale_x: k, scale_y: k, translation_x: -(k - 1) * global.stage.width / 2,
        translation_y: -(k - 1) * global.stage.height / 2});
    move(g, {scale_x: 1, scale_y: 1, translation_x: 0, translation_y: 0}, 1150, CURVE_REVEAL, 0);
    // ... the panels rise into place ...
    for (const p of Main.panelManager.panels) {
        if (!p || !p.actor) continue;
        p.actor.translation_y = 46;
        p.actor.opacity = 0;
        move(p.actor, {translation_y: 0, opacity: 255}, 800, CURVE_REVEAL, 240);
    }
    // ... and the welcome screen lifts away
    if (a) {
        a.remove_all_transitions();
        a.set_pivot_point(0.5, 0.5);
        move(a, {opacity: 0, scale_x: 1.06, scale_y: 1.06}, 900, CURVE_VEIL, 0, () => { a.hide(); endSplash(); });
    }
    if (cover) move(cover, {opacity: 0}, 900, CURVE_VEIL, 0, () => { if (cover) { cover.destroy(); cover = null; } });
    later(1700, () => { uncover(); endSplash(); });      // whatever happened, end in a clean state
}

// Runs fn once the screen has been drawn evenly for a moment (or after `cap` seconds): right
// after logging in many programs start at once and would make the reveal stutter.
function whenSmooth(cap, fn) {
    let last = 0, good = 0, done = false;
    const begun = GLib.get_monotonic_time();
    const id = global.stage.connect('after-paint', () => {
        const t = GLib.get_monotonic_time();
        if (last) good = t - last < 24000 ? good + 1 : 0;
        last = t;
        if (!done && (good >= 14 || t - begun > cap * 1e6)) {
            done = true;
            later(1, fn);
        }
    });
    const pump = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 8, () => {
        if (done || GLib.get_monotonic_time() - begun > (cap + 0.5) * 1e6) {
            global.stage.disconnect(id);
            revealIds = revealIds.filter(x => x !== pump);
            if (!done) { done = true; later(1, fn); }
            return GLib.SOURCE_REMOVE;
        }
        global.stage.queue_redraw();
        return GLib.SOURCE_CONTINUE;
    });
    revealIds.push(pump);
}

// The graphics card prepares an effect the first time it is drawn: do that while nobody sees it.
function warmEffects() {
    if (!UnfurlEffect) return;
    const a = new St.Bin({x: 0, y: 0, width: 64, height: 64, style: 'background-color: rgba(0,0,0,0.02);'});
    const shape = {cx: 0, cy: 1, dx: 0, dy: 1, scale: 0.8, lag: 0.5};
    const u = new UnfurlEffect(shape, 64, 64), g = new GlassEffect();
    g.shape(shape, 64, 64);
    u.setProgress(0.6);
    g.setProgress(0.6);
    a.add_effect(g);
    a.add_effect(u);
    Main.uiGroup.add_child(a);
    later(400, () => a.destroy());
}

// only while Cinnamon is starting for the first time in this login
function prepareReveal() {
    const starting = Main.runState !== undefined && Main.RunState && Main.runState === Main.RunState.STARTUP &&
        !global.session_running;
    if (!starting) return;
    const begun = GLib.get_monotonic_time();
    const widgets = GLib.file_test(GLib.get_user_config_dir() + '/autostart/neon-hud.desktop', GLib.FileTest.EXISTS);
    let running = 0;
    const count = cls => global.get_window_actors().filter(a => a.meta_window &&
        (a.meta_window.get_wm_class() || '').toLowerCase() === cls).length;
    const poll = () => {
        const t = (GLib.get_monotonic_time() - begun) / 1e6;
        if (Main.runState === Main.RunState.RUNNING && !running) { running = t; warmEffects(); }
        const since = running ? t - running : 0;
        const desktop = running && count('nemo-desktop') > 0;
        const ready = desktop && since > 0.5 && (!widgets || count('conky') > 1 || since > 3) &&
            !(Main.wm._mapping instanceof Set && Main.wm._mapping.size > 0);
        if (ready || t > 6.5) whenSmooth(2.2, reveal);
        else later(100, poll);
    };
    // without a welcome screen: a plain dark cover that fades, instead of a sudden desktop
    if (!splashPid() && !global.settings.get_boolean('startup-animation')) {
        cover = new Clutter.Actor({reactive: false, background_color: new Clutter.Color({red: 0, green: 0, blue: 0, alpha: 255}),
            width: global.stage.width, height: global.stage.height});
        global.stage.add_child(cover);
    }
    later(100, poll);
}

// ---------- test hook (used from Looking Glass): collects frame times ----------
function record(ms) {
    const t = [];
    const id = global.stage.connect('after-paint', () => t.push(GLib.get_monotonic_time() / 1000));
    frames = null;
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
        global.stage.disconnect(id);
        frames = t;
        return GLib.SOURCE_REMOVE;
    });
}

function init(metadata) {}

function enable() {
    const p = PopupMenu.PopupMenu && PopupMenu.PopupMenu.prototype;
    // A Cinnamon update may change these internals: then do nothing (normal menus).
    if (p && typeof p.open === 'function' && typeof p.close === 'function' &&
        typeof p.getPanel === 'function' && UnfurlEffect) {
        orig = {open: p.open, close: p.close};
        p.open = neonOpen;
        p.close = neonClose;
    } else {
        global.logWarning('neon-motion: this Cinnamon is not supported, menus stay as they are');
    }
    const ap = Clutter.Actor.prototype;
    if (typeof ap.ease === 'function' && typeof ap.ease_property === 'function' && Graphene.Point &&
        typeof Clutter.Timeline.prototype.set_cubic_bezier_progress === 'function') {
        origEase = {ease: ap.ease, prop: ap.ease_property};
        ap.ease = neonEase;
        ap.ease_property = neonEaseProperty;
        try { enableTips(); } catch (e) { global.logError('neon-motion tooltip: ' + e); }
        try {
            prepareReveal();
        } catch (e) {
            global.logError('neon-motion reveal: ' + e);
            uncover();
        }
    }
    global.neonMotion = {smooths, smoothFor, record, frames: () => frames, active, panes, reveal, addGlass, dropGlass, anchor, UnfurlEffect};
}

function disable() {
    for (const m of [...active.keys()]) settle(m);
    for (const m of [...panes.keys()]) dropGlass(m);
    for (const x of smooths.values()) x.destroy();
    smooths.clear();
    for (const id of revealIds) GLib.source_remove(id);
    if (revealIds.length) { revealIds = []; uncover(); }
    try { disableTips(); } catch (e) { global.logError('neon-motion tooltip: ' + e); }
    if (origEase) {
        const ap = Clutter.Actor.prototype;
        if (ap.ease === neonEase) ap.ease = origEase.ease;
        if (ap.ease_property === neonEaseProperty) ap.ease_property = origEase.prop;
        origEase = null;
    }
    if (orig) {
        const p = PopupMenu.PopupMenu.prototype;
        if (p.open === neonOpen) p.open = orig.open;
        if (p.close === neonClose) p.close = orig.close;
        orig = null;
    }
    delete global.neonMotion;
}
