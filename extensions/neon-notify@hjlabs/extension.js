// Neon-Grid notifications
//  1. pop-ups unfurl from the screen edge as frosted glass and go back the same way
//  2. dismissed notifications glide out; the ones below close the gap
//  3. the notification panel gets a switch for everything and one for each app
// The pictures come from neon-motion (its unfurl and glass effects). Without it, or if anything
// here fails, Cinnamon's own animation runs. Switches: ~/.config/neon-grid/notify.json
const AppletManager = imports.ui.appletManager;
const Clutter = imports.gi.Clutter;
const GLib = imports.gi.GLib;
const Main = imports.ui.main;
const MessageTray = imports.ui.messageTray;
const PopupMenu = imports.ui.popupMenu;

const OPEN_MS = 320, CLOSE_MS = 240, LEAVE_MS = 190, CLOSE_GAP_MS = 220, STAGGER_MS = 28;
const CURVE_IN = [0.18, 0.60, 0.30, 1.00], CURVE_OUT = [0.40, 0.00, 0.70, 0.25];
const CORNER = 20;
const UUID = 'notifications@cinnamon.org';
const FILE = GLib.get_user_config_dir() + '/neon-grid/notify.json';

let tray, timers, orig, pop, hooked, settings, settingsId, trayId;
let apps = {};                                  // app name -> true (on) or false (off)

// ---------- helpers ----------
function later(ms, f) {
    const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
        timers.delete(id);
        try { f(); } catch (e) { global.logError('neon-notify: ' + e); }
        return GLib.SOURCE_REMOVE;
    });
    timers.add(id);
    return id;
}
function bezier(c, x) {
    let lo = 0, hi = 1, t = x;
    const at = (a, b, s) => 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s;
    for (let i = 0; i < 18; i++) {
        t = (lo + hi) / 2;
        if (at(c[0], c[2], t) < x) lo = t; else hi = t;
    }
    return at(c[1], c[3], t);
}
const animate = () => Main.animations_enabled && global.neonMotion && global.neonMotion.UnfurlEffect;

// ---------- app switches ----------
function load() {
    apps = {};
    try {
        const [ok, data] = GLib.file_get_contents(FILE);
        const j = ok ? JSON.parse(imports.byteArray.toString(data)) : {};
        for (const k in j.apps || {}) apps[k] = j.apps[k] !== false;
    } catch (e) { /* no file yet */ }
}
function save() {
    try {
        GLib.mkdir_with_parents(GLib.path_get_dirname(FILE), 0o700);
        GLib.file_set_contents(FILE, JSON.stringify({apps}, null, 1) + '\n');
    } catch (e) { global.logError('neon-notify: ' + e); }
}
function appOf(n) {
    const s = n && n.source;
    return String((s && (s.title || (s.app && s.app.get_name && s.app.get_name()))) || 'Other').slice(0, 60);
}
const muted = n => apps[appOf(n)] === false;
const anyMuted = () => Object.values(apps).includes(false);

// every notification passes through here before it is shown
function dropMuted() {
    for (const n of [...tray._notificationQueue]) {
        const name = appOf(n);
        if (!(name in apps)) { apps[name] = true; save(); }
        if (!muted(n)) continue;
        const i = tray._notificationQueue.indexOf(n);
        if (i >= 0) tray._notificationQueue.splice(i, 1);
        orig.destroy.call(n, MessageTray.NotificationDestroyedReason.DISMISSED);
    }
}

// ---------- pop-up ----------
// pop = {p, effect, pane, timeline, ids}: how far the pop-up is open and what draws it
function clearPop() {
    if (!pop) return;
    stopPop();
    const bin = tray._notificationBin;
    try { if (pop.effect) bin.remove_effect(pop.effect); } catch (e) { /* already off */ }
    try { if (pop.pane && global.neonMotion) global.neonMotion.dropGlass(pop); } catch (e) { /* gone */ }
    try { if (bin.child && bin.child.child) bin.child.child.remove_style_class_name('neon-glass'); } catch (e) { /* gone */ }
    pop = null;
}
function stopPop() {
    if (!pop || !pop.timeline) return;
    for (const id of pop.ids) pop.timeline.disconnect(id);
    pop.timeline.stop();
    pop.timeline = null;
}
function makePop() {
    const bin = tray._notificationBin, M = global.neonMotion;
    const shape = {cx: 1, cy: tray.bottomPosition ? 1 : 0, dx: 1, dy: 0, scale: 0.86, lag: 0.45};
    pop = {p: 0, actor: bin, sourceActor: bin, timeline: null, ids: []};
    bin.get_preferred_size();                   // sizes are known from here on
    pop.effect = new M.UnfurlEffect(shape, bin.width, bin.height);
    pop.effect.setProgress(0);
    bin.add_effect_with_name('neon-unfurl', pop.effect);
    try {
        pop.pane = M.addGlass(pop, shape);
        bin.remove_style_class_name('neon-glass');
        if (bin.child && bin.child.child) bin.child.child.add_style_class_name('neon-glass');
        const fx = pop.pane.effect;
        fx.set_uniform_float(fx.get_uniform_location('u_glass'), 2, [30, CORNER]);
        fx.setProgress(0);
    } catch (e) { pop.pane = null; global.logError('neon-notify glass: ' + e); }
}
function runPop(to, done) {
    stopPop();
    const from = pop.p, opening = to > from;
    const ms = Math.max(1, Math.round((opening ? OPEN_MS : CLOSE_MS) * Math.abs(to - from)));
    if (from === to) { if (done) done(); return; }
    const me = pop, tl = new Clutter.Timeline({duration: ms, delay: from === 0 ? 34 : 0})     // the first picture is drawn before it moves;
    me.timeline = tl;
    const set = p => {
        me.p = p;
        me.effect.setProgress(p);
        if (me.pane) me.pane.effect.setProgress(p);
    };
    me.ids = [
        tl.connect('new-frame', () => set(from + (to - from) * bezier(opening ? CURVE_IN : CURVE_OUT, tl.get_progress()))),
        tl.connect('completed', () => { stopPop(); set(to); if (done) done(); }),
    ];
    tl.start();
}
// Cinnamon asks its pop-up to fade; it unfurls instead and Cinnamon's "finished" runs afterwards
function binEase(params) {
    const bin = tray._notificationBin, plain = () => { clearPop(); Clutter.Actor.prototype.ease.call(bin, params); };
    if (!params || !('opacity' in params) || !animate()) { plain(); return; }
    try {
        const finish = () => { if (params.onComplete) params.onComplete(); };
        if (params.opacity === 255) {
            if (pop && pop.child !== bin.child) clearPop();
            if (!pop) { makePop(); pop.child = bin.child; }
            bin.opacity = 255;
            runPop(1, finish);
        } else {
            if (!pop) { plain(); return; }
            runPop(0, () => { bin.opacity = 0; clearPop(); finish(); });
        }
    } catch (e) {
        global.logError('neon-notify pop-up: ' + e);
        plain();
    }
}

// ---------- dismissing ----------
function destroy(reason) {
    const R = MessageTray.NotificationDestroyedReason;
    const byApp = reason === R.SOURCE_CLOSED || reason === R.EXPIRED;
    try {
        const a = this.actor;
        if (this._neonLeaving && !byApp) return undefined;
        if (!byApp && !this._destroyed && a && a.mapped && animate()) {
            const why = R.DISMISSED;
            if (tray._notification === this && pop) {
                this._neonLeaving = true;
                a.reactive = false;
                runPop(0, null);
                later(CLOSE_MS + 20, () => { if (!this._destroyed) orig.destroy.call(this, why); });
                return undefined;
            }
            if (this._inNotificationBin) {
                this._neonLeaving = true;
                a.reactive = false;
                leave(a, 0);
                later(LEAVE_MS + CLOSE_GAP_MS - 60, () => { if (!this._destroyed) orig.destroy.call(this, why); });
                return undefined;
            }
        }
    } catch (e) { global.logError('neon-notify: ' + e); }
    return orig.destroy.call(this, reason);
}
function leave(a, delay) {
    a.ease({opacity: 0, translation_x: 70, duration: LEAVE_MS, delay, mode: Clutter.AnimationMode.EASE_IN_QUAD});
    a.set_clip_to_allocation(true);
    a.height = a.height;                        // a fixed height can shrink; the ones below follow
    a.ease_property('height', 1, {duration: CLOSE_GAP_MS, delay: delay + LEAVE_MS - 70, mode: Clutter.AnimationMode.EASE_IN_OUT_QUAD});
}

// ---------- panel ----------
function dress(n) {
    try {
        n._titleLabel.add_style_class_name('notification-title');
        n._timeLabel.add_style_class_name('notification-time');
        if (n.urgency === MessageTray.Urgency.CRITICAL) n._table.add_style_class_name('critical');
    } catch (e) { /* only looks */ }
}

function showState(h) {
    const on = settings.get_boolean('display-notifications');
    if (h.all && h.all.state !== on) h.all.setToggleState(on);
    h.applet._applet_icon_box.opacity = on ? 255 : 110;
    if (!on || anyMuted()) h.applet.actor.show();   // otherwise there would be no way back
}

function fill(h) {
    h.list.removeAll();
    const names = Object.keys(apps).sort((a, b) => a.localeCompare(b));
    if (!names.length) {
        const none = new PopupMenu.PopupMenuItem('Apps appear here after their first notification', {reactive: false});
        h.list.addMenuItem(none);
    }
    for (const name of names) {
        const it = new PopupMenu.PopupSwitchMenuItem(name, apps[name]);
        it.connect('toggled', (_, state) => { apps[name] = state; save(); for (const x of hooked) showState(x); });
        h.list.addMenuItem(it);
    }
    h.sub.label.set_text(anyMuted() ? 'Apps (%d off)'.format(names.filter(n => !apps[n]).length) : 'Apps');
}

function addItems(h) {
    const menu = h.applet.menu;
    h.menu = menu;
    h.all = new PopupMenu.PopupSwitchMenuItem('Show notifications', settings.get_boolean('display-notifications'));
    h.all.connect('toggled', (_, state) => settings.set_boolean('display-notifications', state));
    h.sub = new PopupMenu.PopupSubMenuMenuItem('Apps');
    h.list = h.sub.menu;
    h.sep = new PopupMenu.PopupSeparatorMenuItem();
    menu.addMenuItem(h.all, 0);
    menu.addMenuItem(h.sub, 1);
    menu.addMenuItem(h.sep, 2);
    h.openId = menu.connect('open-state-changed', (_, open) => { if (open) { fill(h); showState(h); } });
    fill(h);
    showState(h);
}
function dropItems(h) {
    try { h.menu.disconnect(h.openId); } catch (e) { /* rebuilt */ }
    for (const k of ['all', 'sub', 'sep']) { try { h[k].destroy(); } catch (e) { /* gone with the menu */ } h[k] = null; }
}

function hook(applet) {
    if (hooked.some(h => h.applet === applet)) return;
    const h = {applet};
    hooked.push(h);
    h.display = applet._display;
    applet._display = function () { const r = h.display.call(applet); try { addItems(h); } catch (e) { global.logError('neon-notify: ' + e); } return r; };
    h.update = applet.update_list;
    applet.update_list = function () { const r = h.update.call(applet); try { showState(h); } catch (e) { /* only looks */ } return r; };
    h.clear = applet._clear_all;
    applet._clear_all = function () {
        const all = [...applet.notifications];
        if (!all.length || !applet.menu.isOpen || !animate()) return h.clear.call(applet);
        // the ones on screen go one after the other
        all.forEach((n, i) => {
            n._neonLeaving = true;
            leave(n.actor, Math.min(i, 8) * STAGGER_MS);
        });
        later(LEAVE_MS + CLOSE_GAP_MS + 8 * STAGGER_MS, () => {
            for (const n of all) if (!n._destroyed) orig.destroy.call(n, MessageTray.NotificationDestroyedReason.DISMISSED);
        });
        return undefined;
    };
    if (applet.menu) addItems(h);
}
function find(tries) {
    try { for (const a of AppletManager.getRunningInstancesForUuid(UUID)) hook(a); } catch (e) { /* not there yet */ }
    if (!hooked.length && tries > 0) later(1000, () => find(tries - 1));
}

// ---------- on and off ----------
function enable() {
    tray = Main.messageTray;
    timers = new Set();
    hooked = [];
    pop = null;
    settings = tray.settings;
    load();
    const N = MessageTray.Notification.prototype;
    orig = {destroy: N.destroy, update: tray._updateState};
    N.destroy = destroy;
    tray._updateState = function (...a) {
        try { dropMuted(); if (tray._notificationQueue.length) tray._notificationQueue.forEach(dress); } catch (e) { global.logError('neon-notify: ' + e); }
        return orig.update.apply(this, a);
    };
    tray._notificationBin.ease = binEase;
    settingsId = settings.connect('changed::display-notifications', () => { for (const h of hooked) showState(h); });
    trayId = tray.connect('notify-applet-update', () => find(0));
    find(30);
}

function disable() {
    clearPop();
    for (const id of timers) GLib.source_remove(id);
    timers.clear();
    MessageTray.Notification.prototype.destroy = orig.destroy;
    delete tray._updateState;
    delete tray._notificationBin.ease;
    settings.disconnect(settingsId);
    tray.disconnect(trayId);
    for (const h of hooked) {
        dropItems(h);
        for (const k of ['_display', 'update_list', '_clear_all']) delete h.applet[k];
        h.applet._applet_icon_box.opacity = 255;
        h.update.call(h.applet);
    }
    hooked = [];
}

function init() {}
