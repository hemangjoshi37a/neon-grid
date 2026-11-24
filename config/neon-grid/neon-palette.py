#!/usr/bin/env python3
"""Neon-Grid: take the desktop colours from the wallpaper (Material You, tonal spot).

    neon-palette wallpaper   follow the wallpaper (remembered; re-run on every new image)
    neon-palette neon        back to the built-in cyan/magenta (remembered)
    neon-palette refresh     what the systemd unit runs: redo the current mode if needed
    neon-palette show        print the palette the current wallpaper would give
    neon-palette watch       the user service: follow every wallpaper change, guard Cinnamon

Nothing original is modified. kitty, rofi, Conky, starship and the status line read an
overlay written here. GTK, window borders and Cinnamon get a generated copy of the
Neon-Grid theme named Neon-Grid-You-<hash>: a new name per palette makes open GTK apps
recolour live (GTK caches themes by name). Folder icons get a small icon theme that
inherits Papirus-Dark. Edit ~/.themes/Neon-Grid, then `neon-palette refresh --force`.
"""
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import unquote, urlparse

HOME = Path.home()
CONF = HOME / '.config/neon-grid'
STATE = CONF / 'palette-state.json'
VENV = HOME / '.local/share/neon-grid/venv/bin/python'
THEMES = HOME / '.themes'
BASE = THEMES / 'Neon-Grid'
ICONS = HOME / '.local/share/icons'
PAPIRUS = Path('/usr/share/icons/Papirus')
PREFIX = 'Neon-Grid-You-'
BING = HOME / '.config/bingwallpaper/BingWallpaper.jpg'
WALL = HOME / '.cache/neon-grid/wallpaper.jpg'     # decoded copy, any source format
GTK4 = HOME / '.config/gtk-4.0'
KITTY = HOME / '.config/kitty/neon-palette.conf'
ROFI = HOME / '.config/rofi/neon-palette.rasi'
CONKY = CONF / 'palette.lua'
STARSHIP = HOME / '.config/starship.toml'
TERMINAL = '/org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9/'


def write(path, text):
    """Atomic, so nothing ever reads half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(text)
    os.replace(tmp, path)


def gget(key):
    return subprocess.run(['gsettings', 'get', 'org.cinnamon.desktop.background', key],
                          capture_output=True, text=True, timeout=5).stdout.strip().strip("'")


def source():
    """What is on the desktop now: a picture path, or the plain colour."""
    try:
        uri = gget('picture-uri')
        if gget('picture-options') == 'none' or not uri:
            return gget('primary-color')
        p = Path(unquote(urlparse(uri).path))
        if uri.startswith('file:') and p.is_file():
            return p
    except Exception as e:
        print('wallpaper setting:', e, file=sys.stderr)
    return BING if BING.is_file() else '#101010'


def load_source(src):
    from PIL import Image
    if isinstance(src, str):
        return Image.new('RGB', (960, 540), src if re.fullmatch(r'#[0-9a-fA-F]{6}', src) else '#101010')
    for attempt in range(5):            # it may still be downloading
        try:
            im = Image.open(src)
            im.draft('RGB', (3840, 2160))
            return im.convert('RGB')
        except OSError as e:
            err = e
            if attempt < 4:
                time.sleep(1.5)
    try:                                # SVG, AVIF, HEIC ...: whatever this desktop can show
        import gi
        gi.require_version('GdkPixbuf', '2.0')
        from gi.repository import GdkPixbuf
        pb = GdkPixbuf.Pixbuf.new_from_file_at_size(str(src), 3840, 2160)
        ok, data = pb.save_to_bufferv('png', [], [])
        import io
        return Image.open(io.BytesIO(data)).convert('RGB')
    except Exception:
        raise err


def wallpaper():
    """A JPEG copy of the current wallpaper, refreshed only when the source changed."""
    src = source()
    stamp = [str(src), src.stat().st_mtime_ns if isinstance(src, Path) else 0]
    tag = WALL.with_suffix('.json')
    try:
        if WALL.is_file() and json.loads(tag.read_text()) == stamp:
            return WALL, stamp
    except Exception:
        pass
    im = load_source(src)
    im.thumbnail((3840, 3840))
    WALL.parent.mkdir(parents=True, exist_ok=True)
    tmp = WALL.with_name('wallpaper.tmp')
    im.save(tmp, 'JPEG', quality=93)
    os.replace(tmp, WALL)
    write(tag, json.dumps(stamp))
    return WALL, stamp


def splash(p):
    """Picture and colours for the welcome screen (neon-splash) and the glass behind menus."""
    from PIL import Image, ImageFilter
    d = WALL.parent
    im = Image.open(WALL).convert('RGB')
    w, h = im.size
    k = max(1920 / w, 1080 / h)
    if k < 1:
        im = im.resize((round(w * k), round(h * k)), Image.LANCZOS)
    for name, pic in (('splash.png', im),
                      ('glass.png', im.resize((max(1, im.width // 4), max(1, im.height // 4)), Image.BOX)
                       .filter(ImageFilter.GaussianBlur(11)))):
        tmp = d / (name + '.tmp')
        pic.save(tmp, 'PNG', compress_level=1)
        os.replace(tmp, d / name)
    if p is None:
        c = {'bg': '#080a14', 'text': '#d6f6ff', 'primary': '#00f0ff', 'tertiary': '#ff2bd6',
             'container': '#12304a'}
    else:
        c = {'bg': hx(p['bg']), 'text': hx(p['text']), 'primary': hx(p['primary']),
             'tertiary': hx(p['tertiary']), 'container': hx(p['primary_container'])}
    write(d / 'splash.txt', ''.join(f'{k} {v}\n' for k, v in c.items()))


BROWSER = HOME / '.local/share/neon-grid/browser'


def hsl(argb):
    import colorsys
    r, g, b = (x / 255 for x in rgb(argb))
    hh, l, s = colorsys.rgb_to_hls(r, g, b)
    return {'h': round(hh * 360), 's': round(s * 100), 'l': round(l * 100)}


def browsers(p):
    """An Opera mod and a new-tab page for Chrome, in folders the browsers load once and then
    read again at every start. Chrome's own bars follow the GTK theme (see chrome_prefs)."""
    from PIL import Image
    if p is None:
        p = {'bg': 0x080a14, 'bg_alt': 0x12162a, 'text': 0xd6f6ff, 'dim': 0x7a86a8, 'primary': 0x00f0ff,
             'tertiary': 0xff2bd6, 'primary_container': 0x12304a}
    im = Image.open(WALL).convert('RGB')
    im.thumbnail((2560, 2560))

    def save(path, pic, size=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + '.tmp')
        pic.save(tmp, 'PNG' if path.suffix == '.png' else 'JPEG', **({} if path.suffix == '.png' else {'quality': 90}))
        os.replace(tmp, path)

    def square(n):
        k = min(im.size)
        x, y = (im.width - k) // 2, (im.height - k) // 2
        return im.crop((x, y, x + k, y + k)).resize((n, n))

    version = time.strftime('1.%y.%m%d.%H%M').replace('.0', '.')
    mod = BROWSER / 'opera-mod'
    save(mod / 'wallpaper/dark.jpg', im)
    save(mod / 'wallpaper/preview.png', square(360).crop((45, 0, 315, 360)))
    save(mod / 'icon.png', square(218))
    write(mod / 'manifest.json', json.dumps({
        'manifest_version': 3, 'name': 'Neon-Grid wallpaper', 'version': version, 'icons': {'218': 'icon.png'},
        'description': 'The desktop wallpaper and its Material You colours', 'developer': {'name': 'neon-grid-rice'},
        'mod': {'schema_version': 1, 'payload': {
            'theme': [{'id': 'default', 'name': 'default', 'dark': {
                'accent': hsl(p['primary']), 'background': hsl(p['bg_alt'])}}],
            'wallpaper': [{'id': 'default', 'name': 'default', 'title': 'Wallpaper', 'full_browser': True, 'dark': {
                'groups': [{'layers': [{'resource': 'wallpaper/dark.jpg', 'type': 'image'}]}],
                'preview': {'270x360': 'wallpaper/preview.png'},
                'text_color': hx(p['text']), 'text_shadow': hx(p['bg'])}}]}}}, indent=1) + '\n')
    tab = BROWSER / 'new-tab'
    save(tab / 'wallpaper.jpg', im)
    save(tab / 'icon.png', square(128))
    write(tab / 'palette.css', ':root {' + ' '.join(f'--{k.replace("_", "-")}: {hx(p[k])};' for k in (
        'bg', 'bg_alt', 'text', 'dim', 'primary', 'tertiary', 'primary_container')) + '}\n')
    src = CONF / 'new-tab'
    for f in ('newtab.html', 'newtab.css', 'newtab.js'):
        if (src / f).is_file():
            write(tab / f, (src / f).read_text())
    write(tab / 'manifest.json', json.dumps({
        'manifest_version': 3, 'name': 'Neon-Grid new tab', 'version': version, 'icons': {'128': 'icon.png'},
        'description': 'New tab page with the desktop wallpaper and its Material You colours',
        'chrome_url_overrides': {'newtab': 'newtab.html'}, 'permissions': ['topSites', 'favicon']}, indent=1) + '\n')
    chrome_prefs()


def chrome_prefs():
    """Chrome: 'Use GTK' as its theme, once, while it is closed (it rewrites its settings on exit)."""
    root = HOME / '.config/google-chrome'
    if not root.is_dir() or subprocess.run(['pgrep', '-f', '^/opt/google/chrome/chrome'], capture_output=True).stdout:
        return
    for f in root.glob('*/Preferences'):
        mark = f.with_name('Preferences.before-neon-grid')
        if mark.exists():
            continue                    # done before; a later choice by the user is left alone
        try:
            text = f.read_text()
            d = json.loads(text)
            th = d.setdefault('extensions', {}).setdefault('theme', {})
            if th.get('id') or th.get('system_theme'):
                continue
            th['system_theme'] = 1
            mark.write_text(text)
            mark.chmod(0o600)
            mode = f.stat().st_mode & 0o777
            write(f, json.dumps(d, separators=(',', ':')))
            f.chmod(mode)
        except (OSError, ValueError):
            pass


# ------------------------------------------------------------------ colour maths
def rgb(argb):
    return (argb >> 16) & 255, (argb >> 8) & 255, argb & 255


def hx(argb):
    return '#%06x' % (argb & 0xffffff)


def contrast(a, b):
    def lum(c):
        v = [x / 255 for x in rgb(c)]
        v = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in v]
        return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
    hi, lo = sorted((lum(a), lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def make_scheme(path):
    from PIL import Image
    from materialyoucolor.hct import Hct
    from materialyoucolor.quantize import QuantizeCelebi
    from materialyoucolor.scheme.scheme_tonal_spot import SchemeTonalSpot
    from materialyoucolor.score.score import Score
    im = Image.open(path)
    im.draft('RGB', (512, 512))
    im = im.convert('RGB')
    im = im.resize((128, 128))
    raw = im.tobytes()
    pixels = [(raw[i], raw[i + 1], raw[i + 2], 255) for i in range(0, len(raw), 3)]
    source = Score.score(QuantizeCelebi(pixels, 128))[0]
    return source, SchemeTonalSpot(Hct.from_int(source), True, 0.0, '2021')


def readable(palette, tone, bg, ratio):
    while tone < 98 and contrast(palette.tone(tone), bg) < ratio:
        tone += 1
    return palette.tone(tone)


def make_palette(path):
    source, s = make_scheme(path)
    n, nv = s.neutral_palette, s.neutral_variant_palette
    bg = n.tone(4)                       # near-black base, tinted
    return s, {
        'source': source,
        'bg': bg, 'bg_alt': n.tone(10), 'line': nv.tone(30),
        'term_bg': tinted(source, 22, 7),        # terminals: clearly the wallpaper's hue, still dark
        'text': readable(n, 92, bg, 7), 'dim': readable(nv, 62, bg, 4.5),
        'primary': readable(s.primary_palette, 80, bg, 7),
        'primary_hi': s.primary_palette.tone(90),
        'secondary': readable(s.secondary_palette, 80, bg, 7),
        'tertiary': readable(s.tertiary_palette, 80, bg, 7),
        'tertiary_hi': s.tertiary_palette.tone(90),
        'primary_container': s.primary_palette.tone(30), 'on_primary_container': s.primary_palette.tone(90),
        'tertiary_container': s.tertiary_palette.tone(30), 'on_tertiary_container': s.tertiary_palette.tone(90),
        **{k: soften(c, source, 48, 80) for k, c in
           (('green', 0x29ffa3), ('yellow', 0xf9f871), ('orange', 0xff8c42))},
    }


def tinted(source, chroma, tone):
    from materialyoucolor.hct import Hct
    return Hct.from_hct(Hct.from_int(source).hue, chroma, tone).to_int()


def soften(c, source, chroma, tone):
    from materialyoucolor.blend import Blend
    from materialyoucolor.hct import Hct
    return Hct.from_hct(Hct.from_int(Blend.harmonize(0xff000000 | c, source)).hue, chroma, tone).to_int()


# ------------------------------------------------------------------ writers
def conky(p):
    if p is None:
        return write(CONKY, 'return {}\n')
    names = {'CYAN': 'primary', 'MAGENTA': 'tertiary', 'TEXT': 'text', 'DIM': 'dim', 'BG': 'bg',
             'GREEN': 'green', 'YELLOW': 'yellow', 'ORANGE': 'orange'}     # RED stays (warnings)
    rows = ['    %s = {%.4f, %.4f, %.4f},' % (k, *(c / 255 for c in rgb(p[v]))) for k, v in names.items()]
    write(CONKY, '-- written by neon-palette\nreturn {\n' + '\n'.join(rows) + '\n}\n')


# kitty ANSI colours keep their meaning (red stays red); they are only softened and
# nudged towards the wallpaper's hue.
ANSI = {1: 0xff3b6b, 2: 0x29ffa3, 3: 0xf9f871, 4: 0x3d8bff, 5: 0xff2bd6, 6: 0x00f0ff}


def ansi(p):
    """All 16 terminal colours as hex."""
    lo = [hx(p['bg_alt'])] + [hx(soften(ANSI[i], p['source'], 48, 76)) for i in range(1, 7)] + [hx(p['text'])]
    hi = [hx(p['dim'])] + [hx(soften(ANSI[i], p['source'], 36, 86)) for i in range(1, 7)] + ['#ffffff']
    return lo + hi


def kitty(p):
    if p is None:
        write(KITTY, '# neon-palette: built-in neon colours in use\n')
    else:
        h = {k: hx(v) for k, v in p.items()}
        out = ['# written by neon-palette']
        for k, v in (('foreground', 'text'), ('background', 'term_bg'), ('selection_foreground', 'bg'),
                     ('selection_background', 'primary'), ('cursor', 'tertiary'),
                     ('cursor_text_color', 'bg'), ('url_color', 'primary'),
                     ('active_tab_foreground', 'bg'), ('active_tab_background', 'primary'),
                     ('inactive_tab_foreground', 'dim'), ('inactive_tab_background', 'bg_alt'),
                     ('tab_bar_background', 'term_bg'), ('active_border_color', 'primary'),
                     ('inactive_border_color', 'line'), ('scrollbar_handle_color', 'primary'),
                     ('scrollbar_track_color', 'dim'), ('color0', 'bg_alt'), ('color8', 'dim'),
                     ('color7', 'text')):
            out.append(f'{k} {h[v]}')
        out.append('color15 #ffffff')
        out += [f'color{i} {c}' for i, c in enumerate(ansi(p)) if i not in (0, 7, 8, 15)]
        write(KITTY, '\n'.join(out) + '\n')
    subprocess.run(['pkill', '-USR1', '-u', str(os.getuid()), '-x', 'kitty'])  # kitty: reload config


def rofi(p):
    if p is None:
        return write(ROFI, '/* neon-palette: built-in neon colours in use */\n')
    h = {k: hx(v) for k, v in p.items()}
    write(ROFI, f"""/* written by neon-palette */
* {{
    bg: {h['bg']}ee; bg-alt: {h['bg_alt']}ee; fg: {h['text']}; dim: {h['dim']};
    cyan: {h['primary']}; magenta: {h['tertiary']};
    cyan-soft: {h['primary']}26; magenta-soft: {h['tertiary']}33;
}}
""")


def terminal(p):
    if subprocess.run(['dconf', 'read', TERMINAL + 'visible-name'], capture_output=True,
                      text=True).stdout.strip() != "'Neon-Grid'":
        return
    if p is None:
        c = {'bg': '#080A14', 'term_bg': '#080A14', 'text': '#D6F6FF', 'primary': '#00F0FF', 'tertiary': '#FF2BD6'}
        pal = ['#12162A', '#FF3B6B', '#29FFA3', '#F9F871', '#3D8BFF', '#FF2BD6', '#00F0FF', '#C3C7D1',
               '#3B4266', '#FF6B8F', '#7DFFC6', '#FFFCA8', '#7FB2FF', '#FF7AE6', '#8AF8FF', '#FFFFFF']
    else:
        c, pal = {k: hx(p[k]) for k in ('bg', 'term_bg', 'text', 'primary', 'tertiary')}, ansi(p)
    for key, v in (('background-color', 'term_bg'), ('foreground-color', 'text'),
                   ('cursor-background-color', 'tertiary'), ('cursor-foreground-color', 'bg'),
                   ('highlight-background-color', 'primary'), ('highlight-foreground-color', 'bg')):
        subprocess.run(['dconf', 'write', TERMINAL + key, repr(c[v])], check=True)
    subprocess.run(['dconf', 'write', TERMINAL + 'palette', repr(pal)], check=True)


def gtk4(p):
    """libadwaita apps ignore themes but read this file (open apps need reopening)."""
    GTK4.mkdir(parents=True, exist_ok=True)
    main, line = GTK4 / 'gtk.css', '@import url("neon-palette.css");'
    old = main.read_text() if main.is_file() else ''
    if p is None:
        write(GTK4 / 'neon-palette.css', '/* neon-palette: standard colours in use */\n')
    else:
        h = {k: hx(v) for k, v in p.items()}
        pairs = {'accent-color': 'primary', 'accent-bg-color': 'primary_container',
                 'accent-fg-color': 'on_primary_container', 'window-bg-color': 'bg', 'window-fg-color': 'text',
                 'view-bg-color': 'bg', 'view-fg-color': 'text', 'headerbar-bg-color': 'bg_alt',
                 'headerbar-fg-color': 'text', 'headerbar-backdrop-color': 'bg', 'sidebar-bg-color': 'bg_alt',
                 'sidebar-fg-color': 'text', 'sidebar-backdrop-color': 'bg_alt', 'card-bg-color': 'bg_alt',
                 'card-fg-color': 'text', 'dialog-bg-color': 'bg_alt', 'dialog-fg-color': 'text',
                 'popover-bg-color': 'bg_alt', 'popover-fg-color': 'text'}
        write(GTK4 / 'neon-palette.css', '/* written by neon-palette */\n' +
              ''.join(f'@define-color {k.replace("-", "_")} {h[v]};\n' for k, v in pairs.items()) +
              ':root {\n' + ''.join(f'  --{k}: {h[v]};\n' for k, v in pairs.items()) + '}\n')
    if line not in old:
        write(main, line + '\n' + old)


def starship(p):
    """starship.toml uses named colours; we own the [palettes.wallpaper] block and the
    `palette =` line."""
    if not STARSHIP.is_file() or '[palettes.neon]' not in STARSHIP.read_text():
        return
    text = re.sub(r'\n*# >>> neon-palette.*?# <<< neon-palette\n', '\n', STARSHIP.read_text(), flags=re.S)
    text = re.sub(r'(?m)^palette = ".*"$', 'palette = "%s"' % ('wallpaper' if p else 'neon'), text)
    if p:
        a = ansi(p)
        cols = {'accent': hx(p['primary']), 'accent2': hx(p['tertiary']), 'bad': a[1], 'bad2': a[9],
                'good': a[2], 'warn': a[3], 'info': a[4], 'info2': a[14], 'muted': hx(p['dim'])}
        text = text.rstrip('\n') + '\n\n# >>> neon-palette (generated)\n[palettes.wallpaper]\n' + \
            ''.join(f'{k} = "{v}"\n' for k, v in cols.items()) + '# <<< neon-palette\n'
    write(STARSHIP, text)


# ------------------------------------------------------------------ theme generation
class Recolour:
    """Maps theme colours: neon and Sweet accents to Material roles, tinted greys to the
    same lightness in the wallpaper's neutral; reds, oranges and pure greys unchanged."""
    EXACT = {(0, 240, 255): 'primary', (255, 43, 214): 'tertiary', (214, 246, 255): 'text',
             (122, 134, 168): 'dim', (0, 58, 64): 'primary_container',
             (184, 246, 255): 'on_primary_container', (20, 26, 43): 'bg_alt'}

    def __init__(self, s, p):
        from materialyoucolor.hct import Hct
        self.hct, self.s, self.p, self.cache = Hct, s, p, {}

    def conv(self, c, fill=False):
        key = (c, fill)
        if key not in self.cache:
            self.cache[key] = self._conv(c, fill)
        return self.cache[key]

    def _conv(self, c, fill):
        if c in self.EXACT:
            return rgb(self.p[self.EXACT[c]])
        if max(c) == min(c):
            return c
        s, h = self.s, self.hct.from_int(0xff000000 | c[0] << 16 | c[1] << 8 | c[2])
        if h.chroma < 16:
            return rgb(s.neutral_palette.tone(h.tone))
        if h.chroma < 30 and 195 <= h.hue < 300:
            return rgb(s.neutral_variant_palette.tone(h.tone))
        # A solid accent fill carries white text in this theme, so it must be dark enough.
        tone = min(h.tone, 42) if fill else h.tone
        if 142 <= h.hue < 205:
            return rgb(s.primary_palette.tone(tone))
        if 205 <= h.hue < 300:
            return rgb(s.secondary_palette.tone(tone))
        if 300 <= h.hue < 355 and h.chroma > 60:
            return rgb(s.tertiary_palette.tone(tone))
        return c

    def text(self, text):
        def is_fill(m):
            start = max(text.rfind(ch, 0, m.start()) for ch in ';{}')
            decl = text[start + 1:m.start()].lstrip()
            return decl.startswith('background') or \
                re.match(r'@define-color \w*(selected_bg|suggested)', decl) is not None

        def on_hex(m):
            line = text[text.rfind('\n', 0, m.start()) + 1:m.start()]
            if re.search(r'@define-color [A-Z]+_\d', line):    # elementary's app palette
                return m.group(0)
            v = m.group(1)
            return '#%02x%02x%02x' % self.conv(tuple(int(v[i:i + 2], 16) for i in (0, 2, 4)), is_fill(m))

        def on_rgb(m):
            c = self.conv(tuple(int(m.group(i)) for i in (2, 3, 4)))
            return m.group(1) + ', '.join(map(str, c)) + m.group(5)

        text = re.sub(r'#([0-9a-fA-F]{6})\b', on_hex, text)
        return re.sub(r'(rgba?\(\s*)(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(\s*[,)])', on_rgb, text)

    def png(self, src, dst, tint=None):
        import numpy as np
        from PIL import Image
        a = np.asarray(Image.open(src).convert('RGBA')).copy()
        flat = a.reshape(-1, 4)
        cols, inv = np.unique(flat[:, :3], axis=0, return_inverse=True)
        out = np.array([self.tinted(tuple(int(x) for x in c), tint) for c in cols], np.uint8)
        flat[:, :3] = out[inv.reshape(-1)]
        Image.fromarray(a, 'RGBA').save(dst)

    def tinted(self, c, tint):
        if tint is None:
            return self.conv(c)
        h = self.hct.from_int(0xff000000 | c[0] << 16 | c[1] << 8 | c[2])
        return c if h.chroma < 20 else rgb(tint.tone(min(90, max(h.tone, 70))))


def base_stamp():
    """Changes when the source theme or this script changes."""
    h = hashlib.sha256(Path(__file__).resolve().read_bytes())
    for f in sorted(BASE.rglob('*')):
        if f.is_file():
            st = f.stat()
            h.update(f'{f.relative_to(BASE)} {st.st_size} {st.st_mtime_ns}\n'.encode())
    return h.hexdigest()[:12]


def build_theme(name, s, p):
    out = THEMES / name
    if out.is_dir():
        return
    r = Recolour(s, p)
    tmp = THEMES / f'.{name}.tmp'
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(BASE, tmp, symlinks=True, ignore=shutil.ignore_patterns(
        '*.scss', '*.orig', '*.fish', '*.sh', 'assets.svg', 'assets.txt', 'widgets', 'thumbnail.png'))
    # window buttons: minimise/maximise become accents, close keeps its red
    tints = {'min': s.secondary_palette, 'minimize': s.secondary_palette, 'maximize': s.primary_palette,
             'unmaximize': s.primary_palette}
    for f in sorted(tmp.rglob('*')):
        if f.is_symlink() or not f.is_file():
            continue
        if f.suffix in ('.css', '.rc', '.xml', '.svg') or f.name == 'gtkrc':
            f.write_text(r.text(f.read_text()))
        elif f.suffix == '.png':
            r.png(f, f, tints.get(re.split(r'[_@.]', f.name)[0]))
    idx = tmp / 'index.theme'
    idx.write_text(re.sub(r'(?m)^((?:Name|GtkTheme|MetacityTheme|CinnamonTheme)=)Neon-Grid$', r'\g<1>' + name,
                          idx.read_text()))
    os.replace(tmp, out)


def build_icons(name, s):
    out = ICONS / name
    if out.is_dir() or not PAPIRUS.is_dir():
        return
    from materialyoucolor.hct import Hct

    def on_hex(m):
        h = Hct.from_int(0xff000000 | int(m.group(1), 16))
        if h.chroma < 12 or not 225 <= h.hue < 300:
            return m.group(0)
        return hx(s.primary_palette.tone(min(h.tone + 12, 90) if h.tone > 45 else h.tone))

    tmp = ICONS / f'.{name}.tmp'
    shutil.rmtree(tmp, ignore_errors=True)
    sizes = [n for n in (22, 24, 32, 48, 64) if (PAPIRUS / f'{n}x{n}/places').is_dir()]
    for n in sizes:
        d = tmp / f'{n}x{n}/places'
        d.mkdir(parents=True)
        for f in (PAPIRUS / f'{n}x{n}/places').iterdir():   # folder.svg -> folder-blue.svg and so on
            if f.is_symlink() and f.exists() and '-blue' in f.resolve().name:
                (d / f.name).write_text(re.sub(r'#([0-9a-fA-F]{6})\b', on_hex, f.read_text()))
    ini = ['[Icon Theme]', f'Name={name}', 'Comment=Wallpaper-coloured folders (neon-palette)',
           'Inherits=Papirus-Dark,Papirus,hicolor', 'FollowsColorScheme=true', 'Directories=' +
           ','.join(f'{n}x{n}/places' for n in sizes), '']
    for n in sizes:
        ini += [f'[{n}x{n}/places]', 'Context=Places', f'Size={n}'] + (
            ['Type=Scalable', 'MinSize=64', 'MaxSize=512'] if n == 64 else ['Type=Fixed']) + ['']
    (tmp / 'index.theme').write_text('\n'.join(ini))
    os.replace(tmp, out)


def gset(schema, key, value, mine):
    """Only touch the setting while it still holds one of our themes."""
    cur = subprocess.run(['gsettings', 'get', schema, key], capture_output=True, text=True).stdout.strip().strip("'")
    if cur != value and mine(cur):
        subprocess.run(['gsettings', 'set', schema, key, value], check=True)


def theme(s, p):
    if not BASE.is_dir():
        return
    name, icons = 'Neon-Grid', 'Papirus-Dark'
    if p is not None:
        name = PREFIX + hashlib.sha256((json.dumps(p, sort_keys=True) + base_stamp()).encode()).hexdigest()[:8]
        build_theme(name, s, p)
        ICONS.mkdir(parents=True, exist_ok=True)
        build_icons(name, s)
        if (ICONS / name).is_dir():
            icons = name
    ours = lambda v: v == 'Neon-Grid' or v.startswith(PREFIX)
    gset('org.cinnamon.theme', 'name', name, ours)
    gset('org.cinnamon.desktop.wm.preferences', 'theme', name, ours)
    for schema in ('org.cinnamon.desktop.interface', 'org.gnome.desktop.interface'):
        gset(schema, 'gtk-theme', name, ours)
        gset(schema, 'icon-theme', icons, lambda v: v == 'Papirus-Dark' or v.startswith(PREFIX))
    # keep the current and the previous set (an app may still be reading it)
    for parent in (THEMES, ICONS):
        old = sorted((d for d in parent.glob(PREFIX + '*') if d.is_dir() and d.name != name),
                     key=lambda d: d.stat().st_ctime)
        for d in old[:-1]:
            shutil.rmtree(d)


# ------------------------------------------------------------------ main
def state():
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return {'mode': 'neon'}


def run(mode, force=False):
    s = p = None
    img, stamp = wallpaper()
    if mode == 'wallpaper':
        s, p = make_palette(img)
    cur = {'mode': mode, 'base': base_stamp(), 'palette': p and {k: hx(v) for k, v in p.items()}}
    cur['image'] = [str(img)] + stamp
    old = state()
    if not force and {**cur, 'image': 0} == {**old, 'image': 0}:
        if cur != old:                  # same colours, new picture: the login/boot screens need it
            write(STATE, json.dumps(cur, indent=1) + '\n')
        return print('palette unchanged')
    failed = []
    for name, job in (('splash', lambda: splash(p)), ('conky', lambda: conky(p)), ('kitty', lambda: kitty(p)), ('rofi', lambda: rofi(p)),
                      ('terminal', lambda: terminal(p)), ('starship', lambda: starship(p)),
                      ('gtk4', lambda: gtk4(p)), ('browsers', lambda: browsers(p)), ('theme', lambda: theme(s, p))):
        try:                            # one broken app must not block the others
            job()
        except Exception as e:
            failed.append(name)
            print(f'{name}: {e!r}', file=sys.stderr)
    if failed:
        cur['failed'] = failed          # differs from the next run, so that one retries
    write(STATE, json.dumps(cur, indent=1) + '\n')
    print(mode, 'failed: ' + ', '.join(failed) if failed else cur['palette'] or '')
    sys.exit(bool(failed))


def watch():
    """Re-run `refresh` in a child process whenever the wallpaper (setting or file) changes,
    and put the desktop back to stock if Cinnamon keeps crashing."""
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio, GLib
    here = [sys.executable, '-W', 'ignore', os.path.abspath(__file__)]
    st = {'timer': 0, 'mon': None, 'gone': [], 'up': False}

    def refresh():
        st['timer'] = 0
        try:
            subprocess.run(here + ['refresh'], timeout=120)
        except Exception as e:
            print('refresh:', e, file=sys.stderr, flush=True)
        follow()
        return False

    def soon(*_):
        if st['timer']:
            GLib.source_remove(st['timer'])
        st['timer'] = GLib.timeout_add(2500, refresh)

    def follow():
        src = source()
        if st['mon']:
            st['mon'].cancel()
            st['mon'] = None
        if isinstance(src, Path):
            st['mon'] = Gio.File.new_for_path(str(src)).monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, None)
            st['mon'].connect('changed', soon)

    def appeared(*_):
        st['up'] = True

    def vanished(*_):
        if not st['up']:
            return                      # not started yet
        st['up'] = False
        now = time.monotonic()
        st['gone'] = [t for t in st['gone'] if now - t < 180] + [now]
        if len(st['gone']) >= 3:
            st['gone'] = []
            print('Cinnamon stopped 3 times in 3 minutes: going to safe mode', flush=True)
            subprocess.run([str(CONF / 'neon-safe'), '--auto'])

    settings = Gio.Settings.new('org.cinnamon.desktop.background')
    for key in ('picture-uri', 'picture-options', 'primary-color'):
        settings.connect('changed::' + key, soon)
        settings.get_value(key)
    Gio.bus_watch_name(Gio.BusType.SESSION, 'org.Cinnamon', Gio.BusNameWatcherFlags.NONE, appeared, vanished)
    refresh()
    GLib.MainLoop().run()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'show'
    if cmd == 'watch':
        return watch()
    if cmd == 'show':
        return print(json.dumps({k: hx(v) for k, v in make_palette(wallpaper()[0])[1].items()}, indent=1))
    if cmd not in ('wallpaper', 'neon', 'refresh'):
        sys.exit(__doc__)
    CONF.mkdir(parents=True, exist_ok=True)
    if (CONF / 'safe-mode').exists():
        if cmd == 'refresh':
            return print('safe mode: nothing done (neon-safe --off leaves it)')
        (CONF / 'safe-mode').unlink()
    with open(CONF / '.palette.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            run(state()['mode'] if cmd == 'refresh' else cmd, '--force' in sys.argv)
        except (ImportError, OSError, ValueError, SyntaxError) as e:
            # e.g. unreadable picture, or Python was upgraded under the colour library
            sys.exit(f'colours left as they are: {e!r}')


def repair_venv():
    """After a Python upgrade the colour library must be rebuilt; without network the
    last colours simply stay."""
    ok = subprocess.run([str(VENV), '-c', 'import materialyoucolor.quantize, PIL, numpy'],
                        capture_output=True).returncode == 0 if VENV.exists() else False
    if not ok:
        new = VENV.parents[1].with_name('venv.new')
        shutil.rmtree(new, ignore_errors=True)
        subprocess.run(['/usr/bin/python3', '-m', 'venv', '--system-site-packages', str(new)], check=True, timeout=120)
        subprocess.run([str(new / 'bin/python'), '-m', 'pip', 'install', '-q', '--no-cache-dir', '--only-binary=:all:',
                        'materialyoucolor==3.0.4'], check=True, timeout=180)
        shutil.rmtree(VENV.parents[1], ignore_errors=True)
        os.replace(new, VENV.parents[1])


if __name__ == '__main__':
    if Path(sys.prefix) != VENV.parent.parent:
        if sys.argv[1:2] != ['neon']:
            try:
                repair_venv()
            except Exception as e:
                print('colour library unavailable, colours left as they are:', e, file=sys.stderr)
        if VENV.exists():
            os.execv(VENV, [str(VENV), '-W', 'ignore', os.path.abspath(__file__), *sys.argv[1:]])
    main()
