// Neon-Grid login motion (GNOME login screen only).
//
// Enter pressed      -> light starts to circle the user picture while the password is checked
// wrong password     -> it turns red and falls back
// right password     -> it grows into the picture neon-splash shows after the login and comes to
//                       rest. The graphics server keeps that last picture on screen while it
//                       starts, and neon-splash begins at rest in the same pose: no cut, no black.
// after booting      -> the login screen fades in from the boot animation's picture
//
// It only ever adds drawings on top and calls GNOME's own functions: whatever goes wrong here, the
// login itself carries on (see `always`). It does not load on a GNOME version it was not made for.
import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import GdkPixbuf from 'gi://GdkPixbuf';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as AuthPrompt from 'resource:///org/gnome/shell/gdm/authPrompt.js';
import * as LoginDialog from 'resource:///org/gnome/shell/gdm/loginDialog.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension, InjectionManager} from 'resource:///org/gnome/shell/extensions/extension.js';

const DATA = '/usr/local/share/neon-grid/';
const BOX = 460, CX = 230, CY = 160;          // same drawing as neon-splash
const START_AT = 560;                         // ms of animation before the session is started
const GROW_MS = 700, REST_MS = 900;           // grown, and completely at rest, after this long
const BOOT_FADE_MS = 1100;

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
function bezier(x1, y1, x2, y2) {
    const at = (a, b, u) => 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u;
    return t => {
        t = clamp(t, 0, 1);
        let lo = 0, hi = 1;
        for (let i = 0; i < 20; i++) {
            const m = (lo + hi) / 2;
            if (at(x1, x2, m) < t) lo = m; else hi = m;
        }
        return at(y1, y2, (lo + hi) / 2);
    };
}
const SOFT = bezier(0.22, 0.75, 0.25, 1), MOVE = bezier(0.35, 0, 0.1, 1);

function colours(dir) {
    const c = {bg: '#080a14', text: '#d6f6ff', primary: '#00f0ff', tertiary: '#ff2bd6', container: '#12304a'};
    try {
        const [ok, bytes] = GLib.file_get_contents(dir + 'login.json');
        if (ok) {
            const j = JSON.parse(new TextDecoder().decode(bytes));
            for (const k of Object.keys(c)) if (/^#[0-9a-f]{6}$/i.test(j[k] || '')) c[k] = j[k];
        }
    } catch (e) { /* the built-in colours */ }
    const o = {};
    for (const [k, v] of Object.entries(c)) o[k] = [1, 3, 5].map(i => parseInt(v.slice(i, i + 2), 16) / 255);
    return o;
}

// a picture on every monitor, loaded at once (a style sheet would load it a moment later)
function pictures(path, fallback) {
    let content = null, pw = 16, ph = 9;
    try {
        const pb = GdkPixbuf.Pixbuf.new_from_file(path);
        pw = pb.get_width();
        ph = pb.get_height();
        content = St.ImageContent.new_with_preferred_size(pw, ph);
        content.set_bytes(global.stage.context.get_backend().get_cogl_context(), pb.read_pixel_bytes(),
            pb.get_has_alpha() ? Cogl.PixelFormat.RGBA_8888 : Cogl.PixelFormat.RGB_888, pw, ph, pb.get_rowstride());
    } catch (e) {
        content = null;
    }
    return Main.layoutManager.monitors.map(m => {
        const box = new Clutter.Actor({x: m.x, y: m.y, width: m.width, height: m.height, clip_to_allocation: true});
        if (content) {
            const k = Math.max(m.width / pw, m.height / ph), w = pw * k, h = ph * k;
            const a = new Clutter.Actor({x: (m.width - w) / 2, y: (m.height - h) / 2, width: w, height: h, content});
            box.add_child(a);
        } else {
            box.add_child(new St.Widget({width: m.width, height: m.height, style:
                `background-image: url("file://${path}"); background-size: cover; background-position: center; background-color: ${fallback};`}));
        }
        return box;
    });
}

// the turning shapes; `grow` 0 = only the light around the picture, 1 = the full welcome drawing
class Orb {
    constructor(c, name) {
        this.c = c;
        this.name = name;
        this.t = 0;
        this.show = {x: 0, from: 0, to: 0, t: 1, ms: 300};
        this.grow = {x: 0, from: 0, to: 0, t: 1, ms: GROW_MS};
        this.bad = {x: 0, from: 0, to: 0, t: 1, ms: 200};
        this.ring = 60;
        this.rest = null;                     // {at} once it is coming to rest
        this.area = new St.DrawingArea({width: BOX, height: BOX, reactive: false});
        this.area.connect('destroy', () => { this.gone = true; this.tl?.stop(); });
        this.area.connect('repaint', () => {
            const cr = this.area.get_context();
            try { this.draw(cr); } catch (e) { logError(e, 'neon-login'); }
            cr.$dispose();
        });
        this.tl = new Clutter.Timeline({actor: this.area, duration: 1000, repeat_count: -1});
        this.tl.connect('new-frame', () => this.frame());
        this.last = 0;
    }

    to(o, v, ms) { Object.assign(o, {from: o.x, to: v, t: 0, ms}); if (!this.tl.is_playing()) { this.last = 0; this.tl.start(); } }

    frame() {
        const now = GLib.get_monotonic_time() / 1e6;
        const dt = this.last ? clamp(now - this.last, 0, 0.05) : 0.016;
        this.last = now;
        this.t += dt * 1.5;
        if (this.rest) {
            this.rest.u = clamp((now - this.rest.at) * 1000 / REST_MS, 0, 1);
            const u = this.rest.u, left = REST_MS / 1000 * (0.5 - (u - u * u * u + u * u * u * u / 2));
            this.p = -left;                   // the welcome drawing's clock: ends at exactly 0, standing still
            this.t -= dt * 1.5 * (1 - (1 - u) * (1 - u) * (1 + 2 * u)) + 0;
            if (u >= 1 && this.grow.t >= 1 && this.show.t >= 1) { this.area.queue_repaint(); this.tl.stop(); return; }
        }
        if (this.gone) return;
        for (const o of [this.show, this.grow, this.bad]) {
            if (o.t >= 1) continue;
            o.t = Math.min(1, o.t + dt * 1000 / o.ms);
            o.x = o.from + (o.to - o.from) * (o === this.grow ? MOVE : SOFT)(o.t);
        }
        if (this.show.x === 0 && this.show.t >= 1 && this.show.to === 0) { this.tl.stop(); this.area.hide(); }
        else this.area.queue_repaint();
    }

    cookie(cr, r, amp, n, rot) {
        for (let i = 0; i <= 160; i++) {
            const a = i / 160 * 2 * Math.PI, q = r * (1 + amp * Math.cos(n * a));
            cr.lineTo(CX + q * Math.cos(a + rot), CY + q * Math.sin(a + rot));
        }
        cr.closePath();
    }

    draw(cr) {
        const c = this.c, t = this.rest ? this.p : this.t, g = this.grow.x, a = this.show.x, bad = this.bad.x;
        const S = this.rest ? MOVE(this.rest.u) : 0;       // 0 moving freely .. 1 in the resting pose
        const set = (k, al) => {
            const r = [0.96, 0.36, 0.42];
            cr.setSourceRGBA(...k.map((v, i) => v + (r[i] - v) * bad), clamp(al, 0, 1));
        };
        if (g > 0.01) {
            this.cookie(cr, 92 * g, 0.085, 9, t * 0.55); set(c.container, 0.75 * g); cr.fill();
            this.cookie(cr, 74 * g, 0.10, 8, -t * 0.8); set(c.primary, 0.92 * g); cr.fill();
            this.cookie(cr, 46 * g, 0.12, 6, t * 1.1); set(c.bg, 0.85 * g); cr.fill();
            for (let k = 0; k < 6; k++) {
                const q = t * 1.3 + k * Math.PI / 3;
                cr.arc(CX + 27 * g * Math.cos(q), CY + 27 * g * Math.sin(q), 3.2 + 1.6 * Math.sin(t * 4 + k), 0, 2 * Math.PI);
                set(k % 2 ? c.tertiary : c.primary, g); cr.fill();
            }
        }
        cr.setLineCap(1);
        for (let k = 0; k < 3; k++) {
            const r = this.ring + (118 - this.ring) * g + k * (7 + 4 * g) + 14 * (1 - a);
            // free: turning with the clock; at rest: the start angles of neon-splash, reached the short way
            let st = this.t * (2.4 - 0.5 * k) + k * 2.1, len = 1.0 + 0.6 * Math.sin(this.t * 1.7 + k);
            if (S > 0) {
                const goal = k * 2.1, turn = 2 * Math.PI;
                const d = ((goal - st) % turn + turn * 1.5) % turn - turn / 2;
                st += d * S;
                len += (0.6 + 0.5 * Math.sin(k) - len) * S;
            }
            cr.newPath();
            cr.arc(CX, CY, r, st, st + len);
            cr.setLineWidth((4 - k) + 1.5 * (1 - g));
            set(k === 1 ? c.tertiary : c.primary, (0.95 - 0.25 * k) * a);
            cr.stroke();
        }
        if (g > 0.35 && this.name) {
            const b = clamp((g - 0.35) / 0.65, 0, 1);
            const h = new Date().getHours();
            const hi = h < 5 ? 'GOOD NIGHT' : h < 12 ? 'GOOD MORNING' : h < 17 ? 'GOOD AFTERNOON' : 'GOOD EVENING';
            for (const [s, y, size, bold, al, rise] of [[hi, 352, 13, 0, 0.8, 14], [this.name, 386, 24, 1, 1, 18]]) {
                cr.selectFontFace('Orbitron', 0, bold);
                cr.setFontSize(size);
                const e = cr.textExtents(s);
                cr.moveTo(CX - e.xAdvance / 2, y + rise * (1 - b));
                set(c.text, al * b);
                cr.showText(s);
            }
            cr.newPath();
            for (let k = 0; k <= 95; k++) {
                const f = k / 95;
                if (f > b) break;
                cr.lineTo(CX - 95 + 190 * f, 424 + 5 * Math.sin(f * Math.PI) * Math.sin(f * 26 - t * 7));
            }
            cr.setLineWidth(3.5);
            set(c.primary, 0.95 * b);
            cr.stroke();
        }
    }
}

export default class NeonLogin extends Extension {
    enable() {
        this._dir = GLib.getenv('NEON_LOGIN_DATA') || DATA;
        this._injections = new InjectionManager();
        this._timers = new Set();
        this._running = false;
        const self = this;
        const soft = fn => { try { fn(); } catch (e) { logError(e, 'neon-login'); self._drop(); } };
        soft(() => this._fromBoot());
        const A = AuthPrompt.AuthPrompt.prototype, L = LoginDialog.LoginDialog.prototype;
        if (![A.startSpinning, A.stopSpinning, A._onVerificationFailed, L._startSession].every(f => typeof f === 'function'))
            return;
        this._injections.overrideMethod(A, 'startSpinning', orig => function (...args) {
            orig.apply(this, args);
            soft(() => self._check(this));
        });
        this._injections.overrideMethod(A, 'stopSpinning', orig => function (...args) {
            orig.apply(this, args);
            soft(() => self._calm());
        });
        this._injections.overrideMethod(A, '_onVerificationFailed', orig => function (...args) {
            soft(() => self._fail());
            return orig.apply(this, args);
        });
        this._injections.overrideMethod(L, '_startSession', orig => function (...args) {
            // always start the session, exactly once, whatever happens to the animation
            let done = false;
            const always = () => { if (!done) { done = true; orig.apply(this, args); } };
            GLib.timeout_add(GLib.PRIORITY_HIGH, START_AT, () => { always(); return GLib.SOURCE_REMOVE; });
            try { self._welcome(this); } catch (e) { logError(e, 'neon-login'); self._drop(); always(); }
        });
    }

    disable() {
        this._injections?.clear();
        this._injections = null;
        for (const id of this._timers ?? []) GLib.source_remove(id);
        this._timers = null;
        this._drop();
    }

    _later(ms, fn) {
        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            this._timers?.delete(id);
            try { fn(); } catch (e) { logError(e, 'neon-login'); }
            return GLib.SOURCE_REMOVE;
        });
        this._timers?.add(id);
    }

    _drop() {
        if (this._orb) {
            this._orb.gone = true;
            this._orb.tl.stop();
            this._orb.area.destroy();
        }
        this._orb = null;
        this._veil?.destroy();
        this._veil = null;
        this._running = false;
        this._cover?.destroy();
        this._cover = null;
    }

    // the boot animation's picture lies over everything at first and lifts when the login is ready
    _fromBoot() {
        if (!GLib.file_test(this._dir + 'boot.jpg', GLib.FileTest.EXISTS)) return;
        const cover = new St.Widget({reactive: false, width: global.stage.width, height: global.stage.height});
        for (const a of pictures(this._dir + 'boot.jpg', 'black')) cover.add_child(a);
        global.stage.add_child(cover);
        this._cover = cover;
        let gone = false;
        const lift = () => {
            if (gone) return;
            gone = true;
            cover.ease({opacity: 0, duration: BOOT_FADE_MS, mode: Clutter.AnimationMode.EASE_IN_OUT_CUBIC,
                onStopped: () => { cover.destroy(); if (this._cover === cover) this._cover = null; }});
        };
        const id = Main.layoutManager.connect('startup-complete', () => { Main.layoutManager.disconnect(id); this._later(150, lift); });
        this._later(2500, lift);                  // whatever happens it lifts
        this._later(5000, () => { if (this._cover === cover) { cover.destroy(); this._cover = null; } });
    }

    // middle and size of the user picture, or of the prompt when there is none
    _spot(prompt) {
        const find = a => {
            if (a.has_style_class_name?.('user-icon') && a.mapped && a.width > 20) return a;
            for (const k of a.get_children()) { const r = find(k); if (r) return r; }
            return null;
        };
        const icon = find(prompt) ?? prompt;
        const [x, y] = icon.get_transformed_position(), [w, h] = icon.get_transformed_size();
        return {x: x + w / 2, y: icon === prompt ? y + 60 : y + h / 2, r: icon === prompt ? 60 : Math.max(w, h) / 2 + 9};
    }

    _check(prompt) {
        if (this._running || !prompt.mapped) return;
        const at = this._spot(prompt);
        if (!this._orb) {
            this._orb = new Orb(colours(this._dir), '');
            global.stage.add_child(this._orb.area);
        }
        this._failing = false;
        const o = this._orb;
        o.ring = at.r;
        o.rest = null;
        o.bad.x = 0; o.bad.t = 1;
        o.grow.x = 0; o.grow.t = 1;
        o.area.remove_all_transitions();
        o.area.set_position(Math.round(at.x - CX), Math.round(at.y - CY));
        o.area.show();
        global.stage.set_child_above_sibling(o.area, null);
        o.to(o.show, 1, 260);
    }

    _calm() {
        if (this._running || !this._orb || this._failing) return;
        this._orb.to(this._orb.show, 0, 320);
    }

    _fail() {
        if (this._running || !this._orb) return;
        this._failing = true;
        this._orb.to(this._orb.show, 1, 60);
        this._orb.to(this._orb.bad, 1, 160);
        this._later(620, () => { this._failing = false; this._calm(); });
    }

    _welcome(dialog) {
        this._running = true;
        const prompt = dialog._authPrompt;
        this._check2(prompt);
        const o = this._orb;
        const user = dialog._user;
        o.name = user?.get_real_name?.() || user?.get_user_name?.() || '';
        // the welcome picture behind everything, on every monitor
        const veil = new St.Widget({reactive: false, width: global.stage.width, height: global.stage.height, opacity: 0});
        for (const a of this._welcomePictures ?? pictures(this._dir + 'welcome.jpg', `rgb(${o.c.bg.map(v => Math.round(v * 255)).join(',')})`)) veil.add_child(a);
        this._welcomePictures = null;
        this._veil = veil;
        global.stage.add_child(veil);
        global.stage.set_child_above_sibling(o.area, null);
        const ease = (a, props, ms, mode) => a.ease({...props, duration: ms, mode: mode ?? Clutter.AnimationMode.EASE_OUT_CUBIC});
        ease(prompt, {opacity: 0, scale_x: 0.94, scale_y: 0.94}, 240);
        ease(veil, {opacity: 255}, 520, Clutter.AnimationMode.EASE_IN_OUT_CUBIC);
        const m = Main.layoutManager.primaryMonitor;
        ease(o.area, {x: Math.round(m.x + m.width / 2 - BOX / 2), y: Math.round(m.y + m.height / 2 - BOX / 2)}, GROW_MS,
            Clutter.AnimationMode.EASE_IN_OUT_CUBIC);
        o.to(o.show, 1, 200);
        o.to(o.grow, 1, GROW_MS);
        o.rest = {at: GLib.get_monotonic_time() / 1e6, u: 0};
        o.p = -REST_MS / 2000;
        // if the session does not take over after all, give the login screen back
        this._later(9000, () => {
            prompt.remove_all_transitions();
            prompt.set({opacity: 255, scale_x: 1, scale_y: 1});
            this._drop();
        });
    }

    _check2(prompt) {
        this._running = false;
        this._check(prompt);
        if (!this._orb) {
            this._orb = new Orb(colours(this._dir), '');
            global.stage.add_child(this._orb.area);
        }
        this._orb.area.show();
        this._running = true;
    }
}
