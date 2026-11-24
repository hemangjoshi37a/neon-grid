// Neon-Grid: macOS-style "genie" minimize / restore for Cinnamon.
//
// Cinnamon's WindowManager connects its own minimize/unminimize handlers at
// startup. Ours run right after them: if Cinnamon started an animation, we
// take the actor over (drop it from Cinnamon's bookkeeping, stop its tween)
// and run the genie instead, then tell muffin we're done.
const Clutter = imports.gi.Clutter;
const GObject = imports.gi.GObject;
const Main = imports.ui.main;

const MINIMIZE_MS = 375;   // edit to taste
const RESTORE_MS = 375;
const X_TILES = 10, Y_TILES = 48;   // mesh resolution (more rows = smoother curve)

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const lerp = (a, b, t) => a + (b - a) * t;
const smooth = t => { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); };
// cubic bezier (x1, y1, x2, y2 as in CSS), from a table so it costs nothing per mesh point
function bezierTable(x1, y1, x2, y2) {
    const at = (a, b, u) => 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u;
    const out = [];
    for (let i = 0; i <= 256; i++) {
        let lo = 0, hi = 1;
        for (let k = 0; k < 20; k++) {
            const m = (lo + hi) / 2;
            if (at(x1, x2, m) < i / 256) lo = m; else hi = m;
        }
        out.push(at(y1, y2, (lo + hi) / 2));
    }
    return out;
}
const SLIDE = bezierTable(0.45, 0.03, 0.20, 1.00);
const CURVE = bezierTable(0.25, 0.10, 0.20, 1.00);
const look = (table, t) => {
    const f = clamp(t, 0, 1) * 256, i = Math.min(255, Math.floor(f));
    return table[i] + (table[i + 1] - table[i]) * (f - i);
};

// Unique GType name so the extension can be reloaded without restarting Cinnamon.
var GenieEffect = GObject.registerClass({GTypeName: `NeonGenieEffect${Date.now()}`},
class GenieEffect extends Clutter.DeformEffect {
    _init(src, dst) {
        super._init();
        this.src = src;    // screen rect of the actor's painted area {x, y, w, h}
        this.dst = dst;    // screen rect of the taskbar button
        this.progress = 0; // 0 = normal window, 1 = fully inside the button
        this.set_n_tiles(X_TILES, Y_TILES);
    }

    setProgress(p) {
        this.progress = p;
        this.invalidate();
    }

    vfunc_deform_vertex(width, height, v) {
        const s = this.src, d = this.dst, p = this.progress;
        const u = v.tx, t = v.ty;  // texture coords 0..1 across the window
        const down = (d.y + d.h / 2) >= (s.y + s.h / 2);

        // Phase 1 (curve) bends the sides into a funnel; phase 2 (slide)
        // pours the window down it. They overlap like the macOS effect.
        const curve = look(CURVE, p / 0.45);
        const slide = look(SLIDE, (p - 0.18) / 0.82);

        // Vertical: edges travel toward the button; the leading edge is ahead.
        let y;
        if (down) {
            const top = lerp(s.y, d.y, slide);
            const bot = lerp(s.y + s.h, d.y + d.h, clamp(slide * 1.15, 0, 1));
            y = lerp(top, Math.max(top, bot), t);
        } else {
            const top = lerp(s.y, d.y, clamp(slide * 1.15, 0, 1));
            const bot = lerp(s.y + s.h, d.y + d.h, slide);
            y = lerp(Math.min(top, bot), bot, t);
        }

        // Horizontal: how far down the funnel this row is (0 at the window's
        // far edge, 1 at the button), shaped with an S-curve.
        const farY = down ? s.y : s.y + s.h;
        const nearY = down ? d.y : d.y + d.h;
        const k = smooth((y - farY) / (nearY - farY || 1)) * curve;
        const left = lerp(s.x, d.x, k);
        const right = lerp(s.x + s.w, d.x + d.w, k);
        const x = lerp(left, right, u);

        // Back to the offscreen buffer's coordinates.
        v.x = (x - s.x) * width / s.w;
        v.y = (y - s.y) * height / s.h;
    }
});

let wm = null;
let ids = [];
let running = new Map();   // actor -> {timeline, effect, done}

function iconRect(actor) {
    const win = actor.meta_window;
    let [ok, g] = win.get_icon_geometry();
    if (ok && g.width > 0)
        return {x: g.x, y: g.y, w: g.width, h: g.height};
    // No taskbar button known: aim at the bottom-centre of the work area.
    const wa = win.get_work_area_current_monitor();
    return {x: wa.x + wa.width / 2 - 24, y: wa.y + wa.height - 8, w: 48, h: 8};
}

function paintRect(actor) {
    const [x, y] = actor.get_transformed_position();
    return {x, y, w: Math.max(1, actor.width), h: Math.max(1, actor.height)};
}

function finish(actor) {
    const r = running.get(actor);
    if (!r) return;
    running.delete(actor);
    if (r.timeline) {
        r.timeline.disconnect(r.frameId);
        r.timeline.disconnect(r.doneId);
        r.timeline.stop();
    }
    try {
        actor.remove_effect(r.effect);
        actor.set_opacity(r.opacity);
    } catch (e) {
        global.logError('neon-genie: ' + e);
    }
    r.complete();
}

// Never leave a window stuck half-minimized: on any error, fall back to an
// instant minimize/restore.
function run(actor, minimize, complete) {
    try {
        start(actor, minimize, complete);
    } catch (e) {
        global.logError('neon-genie: ' + e);
        const r = running.get(actor);
        if (r) finish(actor);
        else complete();
    }
}

function start(actor, minimize, complete) {
    const rect = actor.meta_window.get_buffer_rect();
    actor.set_position(rect.x, rect.y);
    actor.set_scale(1, 1);
    actor.set_pivot_point(0, 0);

    const src = paintRect(actor);
    const dst = iconRect(actor);
    const effect = new GenieEffect(src, dst);
    const opacity = actor.opacity === 0 ? 255 : actor.opacity;
    const duration = (minimize ? MINIMIZE_MS : RESTORE_MS) * (Main.wm.window_effect_multiplier || 1);

    effect.setProgress(minimize ? 0 : 1);
    actor.add_effect_with_name('neon-genie', effect);
    if (!minimize) actor.show();

    const r = {timeline: null, effect, opacity, complete};
    running.set(actor, r);
    const timeline = new Clutter.Timeline({duration: Math.max(1, Math.round(duration))});
    r.timeline = timeline;
    r.frameId = timeline.connect('new-frame', () => {
        const f = timeline.get_progress();
        const p = minimize ? f : 1 - f;
        effect.setProgress(p);
        // Fade only in the very last stretch inside the button.
        actor.opacity = Math.round(opacity * (1 - 0.6 * smooth((p - 0.8) / 0.2)));
        global.stage.queue_redraw();   // mesh draws outside the actor's box
    });
    r.doneId = timeline.connect('completed', () => finish(actor));
    timeline.start();
}

function onMinimize(cwm, actor) {
    // Cinnamon decided not to animate (effects off, modal, etc.) -> leave it.
    if (!Main.wm._minimizing.delete(actor)) return;
    actor.remove_all_transitions();
    run(actor, true, () => cwm.completed_minimize(actor));
}

function onUnminimize(cwm, actor) {
    if (!Main.wm._unminimizing.delete(actor)) return;
    actor.remove_all_transitions();
    run(actor, false, () => cwm.completed_unminimize(actor));
}

function init(metadata) {}

function enable() {
    // A Cinnamon update may change these internals: then do nothing (normal minimize).
    if (!Clutter.DeformEffect || !Main.wm || !(Main.wm._minimizing instanceof Set) ||
        !(Main.wm._unminimizing instanceof Set)) {
        global.logWarning('neon-genie: this Cinnamon is not supported, using its own effects');
        return;
    }
    wm = global.window_manager;
    ids = [
        wm.connect('minimize', onMinimize),
        wm.connect('unminimize', onUnminimize),
        wm.connect('kill-window-effects', (cwm, actor) => finish(actor)),
    ];
}

function disable() {
    ids.forEach(id => wm.disconnect(id));
    ids = [];
    for (const actor of [...running.keys()]) finish(actor);
}
