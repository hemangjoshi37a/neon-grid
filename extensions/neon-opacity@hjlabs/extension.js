// Neon-Grid: per-app window translucency.
//   RULES  'wm class (lower case)': opacity 0-255 of the whole window
//   BARS   'wm class': {top, left, alpha}: only the bars at the edge are see-through (browsers:
//          tab strip and address bar), the page itself stays solid. Off in full screen.
const Cinnamon = imports.gi.Cinnamon;
const GObject = imports.gi.GObject;
const Meta = imports.gi.Meta;
const Mainloop = imports.mainloop;

const RULES = {
    'nemo': 228,
};
const BARS = {
    'opera': {top: 84, left: 0, alpha: 0.86},
    'google-chrome': {top: 86, left: 0, alpha: 0.86},
    'chromium': {top: 86, left: 0, alpha: 0.86},
};

var BarEffect = !Cinnamon.GLSLEffect ? null : GObject.registerClass({GTypeName: `NeonBar${Date.now()}`},
class BarEffect extends Cinnamon.GLSLEffect {
    vfunc_build_pipeline() {
        this.add_glsl_snippet(Cinnamon.SnippetHook.FRAGMENT,
            'uniform vec4 u_bar;\nuniform vec2 u_size;\n',
            `vec2 px = cogl_tex_coord_in[0].xy * u_size;
             float bar = max(1.0 - smoothstep(u_bar.x - 1.0, u_bar.x + 1.0, px.y),
                             1.0 - smoothstep(u_bar.y - 1.0, u_bar.y + 1.0, px.x));
             // bright parts (text, icons) stay solid, the dark background lets the desktop through
             float light = dot(cogl_color_out.rgb, vec3(0.299, 0.587, 0.114));
             float a = mix(u_bar.z, 1.0, smoothstep(0.25, 0.75, light));
             cogl_color_out *= mix(1.0, a, bar);`, false);
    }

    shape(top, left, alpha, w, h) {
        this.set_uniform_float(this.get_uniform_location('u_bar'), 4, [top, left, alpha, 0]);
        this.set_uniform_float(this.get_uniform_location('u_size'), 2, [Math.max(1, w), Math.max(1, h)]);
        this.queue_repaint();
    }
});

let createdId = 0;
let focusId = 0;
let bars = new Map();                  // actor -> {effect, ids}

function klass(win) {
    return (win && win.get_window_type() === Meta.WindowType.NORMAL && win.get_wm_class() || '').toLowerCase();
}

function rule(win) {
    return RULES[klass(win)];
}

function apply(win, value) {
    try {
        let v = value !== undefined ? value : rule(win);
        if (v === undefined) return;
        let actor = win.get_compositor_private();
        if (actor) actor.set_opacity(v);
    } catch (e) {
        global.logError('neon-opacity: ' + e);
    }
}

function dropBar(actor) {
    const b = bars.get(actor);
    if (!b) return;
    bars.delete(actor);
    try {
        for (const [o, id] of b.ids) o.disconnect(id);
        if (!actor.is_finalized()) actor.remove_effect(b.effect);
    } catch (e) { /* the window is gone */ }
}

function addBar(win) {
    const r = BARS[klass(win)];
    const actor = win.get_compositor_private();
    if (!r || !BarEffect || !actor || bars.has(actor)) return;
    try {
        const effect = new BarEffect();
        const b = {effect, ids: []};
        const shape = () => {
            const full = win.is_fullscreen(), f = win.get_frame_rect(), o = win.get_buffer_rect();
            effect.set_enabled(!full && f.width > 500 && f.height > 300);
            effect.shape(r.top + f.y - o.y, r.left ? r.left + f.x - o.x : -9, r.alpha, actor.width, actor.height);
        };
        shape();
        actor.add_effect_with_name('neon-bar', effect);
        bars.set(actor, b);
        b.ids.push([win, win.connect('size-changed', shape)], [win, win.connect('notify::fullscreen', shape)],
            [win, win.connect('notify::maximized-vertically', shape)], [actor, actor.connect('notify::size', shape)],
            [actor, actor.connect('destroy', () => bars.delete(actor))]);
    } catch (e) {
        global.logError('neon-opacity: ' + e);
        dropBar(actor);
    }
}

// Window effects end by restoring full opacity, so re-apply shortly after.
function later(win) {
    [250, 900].forEach(ms => Mainloop.timeout_add(ms, () => {
        try { apply(win); addBar(win); } catch (e) { /* closed meanwhile */ }
        return false;
    }));
}

function init(metadata) {}

function enable() {
    createdId = global.display.connect('window-created', (d, win) => later(win));
    focusId = global.display.connect('notify::focus-window', () => {
        let win = global.display.get_focus_window();
        if (win) later(win);
    });
    global.get_window_actors().forEach(a => { apply(a.get_meta_window()); addBar(a.get_meta_window()); });
}

function disable() {
    if (createdId) global.display.disconnect(createdId);
    if (focusId) global.display.disconnect(focusId);
    createdId = focusId = 0;
    [...bars.keys()].forEach(dropBar);
    global.get_window_actors().forEach(a => {
        let win = a.get_meta_window();
        if (rule(win) !== undefined) apply(win, 255);
    });
}
