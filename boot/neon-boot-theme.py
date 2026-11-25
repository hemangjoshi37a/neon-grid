#!/usr/bin/python3 -I
"""Neon-Grid: put the wallpaper and its Material You colours on the login, GRUB and
boot/shutdown screens. Runs as root from neon-boot-theme.service whenever neon-palette
records a new wallpaper or palette.

Nothing from the user's home is copied into these places as is: colours are validated hex
values, and the wallpaper is decoded by an unprivileged child process that hands back raw
pixels of a fixed size. All templates and code are root-owned. Only parts that were
installed (their directory exists) are updated, files are replaced atomically, and GRUB's
and the boot image's configuration are never touched.

    neon-boot-theme.py [--root DIR] [--palette FILE --wallpaper FILE]   (test into DIR)
"""
import argparse
import io
import json
import os
import pwd
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

LIB = Path(os.path.realpath(__file__)).parent
W, H = 1920, 1080
LOGIN_W, LOGIN_H = 2560, 1440
NEON = {'bg': '#080a14', 'bg_alt': '#12162a', 'line': '#2a2f4a', 'text': '#d6f6ff', 'dim': '#8f9abc',
        'primary': '#00f0ff', 'tertiary': '#ff7ae6', 'yellow': '#f9f871', 'primary_container': '#004f58',
        'on_primary_container': '#bdf7ff', 'tertiary_container': '#7a1166', 'on_tertiary_container': '#ffd8f3'}
DECODE = '''
import sys
from PIL import Image
Image.MAX_IMAGE_PIXELS = 80_000_000
w, h = int(sys.argv[2]), int(sys.argv[3])
im = Image.open(sys.argv[1], formats=["JPEG", "PNG", "WEBP"])
im.draft("RGB", (w, h))
im = im.convert("RGB")
k = max(w / im.width, h / im.height)
im = im.resize((max(w, round(im.width * k)), max(h, round(im.height * k))), Image.LANCZOS)
x, y = (im.width - w) // 2, (im.height - h) // 2
sys.stdout.buffer.write(im.crop((x, y, x + w, y + h)).tobytes())
'''


def log(*a):
    print(*a, flush=True)


def hex3(v):
    return tuple(int(v[i:i + 2], 16) for i in (1, 3, 5))


def read_palette(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as f:
        data = json.loads(f.read(65536))
    given = data.get('palette') if isinstance(data, dict) else None
    out = dict(NEON)
    if isinstance(given, dict):
        for k in out:
            v = given.get(k)
            if isinstance(v, str) and re.fullmatch(r'#[0-9a-fA-F]{6}', v):
                out[k] = v.lower()
    img = data.get('image') if isinstance(data, dict) else None
    path = img[0] if isinstance(img, list) and img and isinstance(img[0], str) else None
    return out, path


def decode(path, user, w, h):
    cmd = ['/usr/bin/python3', '-I', '-c', DECODE, path, str(w), str(h)]
    kw = {'user': user.pw_uid, 'group': user.pw_gid, 'extra_groups': []} if os.geteuid() == 0 else {}
    r = subprocess.run(cmd, stdout=subprocess.PIPE, timeout=60, env={'PATH': '/usr/bin:/bin'}, cwd='/', **kw)
    if r.returncode or len(r.stdout) != w * h * 3:
        raise SystemExit('wallpaper could not be read; nothing changed')
    return Image.frombytes('RGB', (w, h), r.stdout)


def atomic(path, data):
    tmp = path.with_name('.' + path.name + '.new')
    with open(tmp, 'wb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def png(im):
    b = io.BytesIO()
    im.save(b, 'PNG', compress_level=6)
    return b.getvalue()


def scrim(im, colour, top, middle, bottom):
    """Darken with the palette's base so text stays readable on any picture."""
    h = im.height
    y = np.linspace(0, 1, h, dtype=np.float32)
    a = np.where(y < 0.5, top + (middle - top) * y * 2, middle + (bottom - middle) * (y - 0.5) * 2)[:, None, None]
    px = np.asarray(im, np.float32)
    # bright pictures get a little extra
    a = np.clip(a + max(0.0, px.mean() / 255 - 0.45) * 0.6, 0, 0.9)
    return Image.fromarray((px * (1 - a) + np.array(hex3(colour), np.float32) * a).astype(np.uint8), 'RGB')


def tint(mask, colour, alpha=1.0):
    out = np.empty(mask.shape + (4,), np.uint8)
    out[..., :3] = hex3(colour)
    out[..., 3] = (mask.astype(np.float32) * alpha).astype(np.uint8)
    return Image.fromarray(out, 'RGBA')


def fill(template, p):
    def sub(m):
        k = m.group(1)
        return ', '.join(map(str, hex3(p[k[:-4]]))) if k.endswith('_rgb') else p[k]
    return re.sub(r'@([a-z_]+)@', sub, template)


# ------------------------------------------------------------------ boot / shutdown
def splash(dest, pal, wall, masks):
    if not dest.is_dir():
        return
    files = {'bg.png': png(scrim(wall, pal['bg'], 0.30, 0.46, 0.62)),
             'oem.png': png(tint(masks['oem' if 'oem' in masks.files else 'victus'], pal['on_tertiary_container'])),
             'log-panel.png': png(log_panel(wall, pal)),
             'orbit-a.png': png(tint(masks['orbit'], pal['primary'])),
             'orbit-b.png': png(tint(masks['orbit'], pal['tertiary'])),
             'wave-on.png': png(tint(masks['wave'], pal['primary'])),
             'wave-off.png': png(tint(masks['wave'], pal['text'], 0.22))}
    if 'hint' in masks.files:
        files['hint.png'] = png(tint(masks['hint'], pal['text'], 0.55))
    for name in masks.files:
        if name.startswith('shape-'):
            n = name[6:]
            files[f'shape-a-{n}.png'] = png(tint(masks[name], pal['primary_container']))
            files[f'shape-b-{n}.png'] = png(tint(masks[name], pal['tertiary_container']))
        elif name.startswith('cof-'):
            files[name + '.png'] = png(tint(masks[name], pal['on_primary_container']))
        elif name.startswith('sub-'):
            files[name + '.png'] = png(tint(masks[name], pal['text']))
    for name, data in files.items():
        atomic(dest / name, data)
    log('splash:', len(files), 'images,', sum(map(len, files.values())) // 1024, 'KiB')


# ------------------------------------------------------------------ GRUB
def rounded(size, radius, colour, alpha):
    s = 4
    m = Image.new('L', (size * s, size * s))
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * s - 1, size * s - 1], radius * s, fill=255)
    return tint(np.asarray(m.resize((size, size), Image.LANCZOS)), colour, alpha)


def nine(prefix, radius, colour, alpha):
    """GRUB draws boxes from nine pieces."""
    size = radius * 2 + 8
    im, r, e = rounded(size, radius, colour, alpha), radius, size - radius
    boxes = {'nw': (0, 0, r, r), 'n': (r, 0, e, r), 'ne': (e, 0, size, r), 'w': (0, r, r, e), 'c': (r, r, e, e),
             'e': (e, r, size, e), 'sw': (0, e, r, size), 's': (r, e, e, size), 'se': (e, e, size, size)}
    return {f'{prefix}_{k}.png': png(im.crop(b)) for k, b in boxes.items()}


def pill(prefix, height, colour, alpha):
    """A rounded bar of one fixed height from side caps and a middle: with no top and bottom
    pieces GRUB keeps the text of the selected row in line with the others."""
    s, r = 4, height // 2
    m = Image.new('L', (height * 2 * s, height * s))
    ImageDraw.Draw(m).rounded_rectangle([0, 0, m.width - 1, m.height - 1], r * s, fill=255)
    im = tint(np.asarray(m.resize((height * 2, height), Image.LANCZOS)), colour, alpha)
    return {f'{prefix}_w.png': png(im.crop((0, 0, r, height))), f'{prefix}_c.png': png(im.crop((r, 0, r + 8, height))),
            f'{prefix}_e.png': png(im.crop((height * 2 - r, 0, height * 2, height)))}


def badge(shape, logo, back, front):
    im = tint(shape, back)
    k = 0.46 * im.width / max(logo.shape)
    mark = Image.fromarray(logo).resize((round(logo.shape[1] * k), round(logo.shape[0] * k)), Image.LANCZOS)
    im.alpha_composite(tint(np.asarray(mark), front), ((im.width - mark.width) // 2, (im.height - mark.height) // 2))
    return im.resize((120, 120), Image.LANCZOS)


PANEL = (560, 190, 1360, 850)           # the glass on a 1920x1080 picture; grub-theme.txt.in uses the same place


def glass(im, pal, box, radius=40):
    """Frosted glass baked into the picture: GRUB itself cannot blur."""
    x0, y0, x1, y1 = box
    big = Image.new('L', im.size, 0)
    ImageDraw.Draw(big).rounded_rectangle([x0, y0 + 18, x1, y1 + 18], radius, fill=150)
    shadow = big.filter(ImageFilter.GaussianBlur(34))
    out = Image.composite(Image.new('RGB', im.size, pal['bg']), im, shadow.point(lambda v: v * 2 // 3))
    soft = im.filter(ImageFilter.GaussianBlur(30))
    soft = Image.blend(soft, Image.new('RGB', im.size, pal['bg']), 0.56)
    mask = Image.new('L', (im.width * 2, im.height * 2), 0)
    ImageDraw.Draw(mask).rounded_rectangle([2 * x0, 2 * y0, 2 * x1, 2 * y1], 2 * radius, fill=255)
    out.paste(soft, (0, 0), mask.resize(im.size, Image.LANCZOS))
    # light on the rim, stronger at the top
    rim = Image.new('RGBA', (im.width * 2, im.height * 2), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([2 * x0, 2 * y0, 2 * x1, 2 * y1], 2 * radius, outline=hex3(pal['primary']) + (150,), width=3)
    ramp = Image.linear_gradient('L').resize(im.size).point(lambda v: 255 - v * 3 // 4)
    rim = rim.resize(im.size, Image.LANCZOS)
    rim.putalpha(Image.composite(rim.getchannel('A'), Image.new('L', im.size, 0), ramp))
    out = out.convert('RGBA')
    out.alpha_composite(rim)
    return out


LOG = (300, 150, 1620, 930)             # the boot log: same place as in neon-grid.script


def log_panel(wall, pal):
    x0, y0, x1, y1 = LOG
    im = glass(scrim(wall, pal['bg'], 0.42, 0.52, 0.62), pal, LOG).convert('RGBA').crop(LOG)
    shade = Image.new('RGBA', im.size, hex3(pal['bg']) + (120,))
    im.alpha_composite(shade)
    mask = Image.new('L', (im.width * 2, im.height * 2), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width * 2 - 1, im.height * 2 - 1], 2 * 40, fill=255)
    im.putalpha(mask.resize(im.size, Image.LANCZOS))
    d = ImageDraw.Draw(im)
    f1, f2 = font(17), font(12)
    if f1 and f2:
        d.text((34, 34), 'BOOT LOG', font=f1, fill=pal['primary'], anchor='lm')
        d.text((im.width - 34, 34), 'TAB  CLOSE      ESC  FULL TEXT', font=f2, fill=pal['dim'], anchor='rm')
    d.line([34, 60, im.width - 34, 60], fill=hex3(pal['primary']) + (90,), width=1)
    return im


def font(size):
    for f in ('/usr/local/share/fonts/neon-grid/Orbitron.ttf', '/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Bold.ttf'):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return None


def grub(dest, pal, wall, masks):
    if not dest.is_dir():
        return
    back = glass(scrim(wall, pal['bg'], 0.16, 0.26, 0.42), pal, PANEL)
    cx = (PANEL[0] + PANEL[2]) // 2
    a = badge(masks['shape-00'], masks['cof-000'], pal['primary_container'], pal['on_primary_container'])
    b = badge(masks['shape-00'], masks['oem' if 'oem' in masks.files else 'victus'], pal['tertiary_container'], pal['on_tertiary_container'])
    back.alpha_composite(a, (cx - 132, PANEL[1] + 34))
    back.alpha_composite(b, (cx + 12, PANEL[1] + 34))
    d = ImageDraw.Draw(back)
    f1, f2 = font(27), font(14)
    if f1 and f2:
        d.text((cx, PANEL[1] + 190), 'CHOOSE A SYSTEM', font=f1, fill=pal['text'], anchor='mm')
        d.text((cx, PANEL[3] + 46), 'ARROWS  SELECT      ENTER  START      E  EDIT', font=f2, fill=pal['dim'], anchor='mm')
    files = {'background.png': png(back.convert('RGB')),
             'boot.png': png(scrim(wall, pal['bg'], 0.30, 0.46, 0.62)),      # same as the boot animation's background
             **pill('select', 56, pal['primary'], 1.0), **nine('thumb', 4, pal['primary'], 1.0),
             **pill('barbg', 8, pal['text'], 0.20), **pill('barfg', 8, pal['primary'], 1.0)}
    files['theme.txt'] = fill((LIB / 'grub-theme.txt.in').read_text(), pal).encode()   # last: it names the rest
    for name, data in files.items():
        atomic(dest / name, data)
    for f in dest.glob('*_*.png'):       # pieces of an earlier design would be picked up by name
        if f.name not in files and re.fullmatch(r'(menu|select|thumb|barbg|barfg)_[a-z]{1,2}\.png', f.name):
            f.unlink()
    for name in ('badge-a.png', 'badge-b.png'):
        (dest / name).unlink(missing_ok=True)
    log('grub:', sum(map(len, files.values())) // 1024, 'KiB')


# ------------------------------------------------------------------ GDM
def rest_pose(back, pal, masks):
    """The boot animation at rest (neon-grid.script, `resting`), as the login screen's first picture."""
    im = back.convert('RGBA')
    cx, cy, gap = W // 2, int(H * 0.42), 165

    def put(mask, colour, x, y, alpha=1.0):
        t = tint(mask, colour, alpha)
        im.alpha_composite(t, (int(x), int(y)))
        return t
    sh = masks['shape-00'].shape[0] / 2
    put(masks['shape-00'], pal['primary_container'], cx - gap - sh, cy - sh)
    put(masks['shape-47'], pal['tertiary_container'], cx + gap - sh, cy - sh)
    cof = masks['cof-000']
    put(cof, pal['on_primary_container'], cx - gap - cof.shape[1] / 2, cy - cof.shape[0] / 2)
    oem = masks['oem' if 'oem' in masks.files else 'victus']
    put(oem, pal['on_tertiary_container'], cx + gap - oem.shape[1] / 2, cy - oem.shape[0] / 2 + 6)
    sub = masks['sub-boot']
    put(sub, pal['text'], cx - sub.shape[1] / 2, cy + 235)
    for i in range(112):
        put(masks['wave'], pal['primary'], cx - 112 * 5 / 2 + i * 5, cy + 330)
    return im.convert('RGB')


def login(target, pal, wall, masks=None, with_splash=False):
    src = Path('/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource')
    prefix = '/org/gnome/shell/theme/'
    if not target.parent.is_dir() or not target.exists() or not src.is_file():
        return
    names = subprocess.run(['gresource', 'list', str(src)], capture_output=True, text=True, check=True).stdout.split()
    if prefix + 'gdm.css' not in names:
        raise RuntimeError('Yaru has no gdm.css any more; login theme left as it was')
    with tempfile.TemporaryDirectory(prefix='neon-gdm.') as t:
        t = Path(t)
        rel = []
        for n in names:
            if not n.startswith(prefix) or '..' in n:
                continue
            f = t / 'build' / n[len(prefix):]
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(subprocess.run(['gresource', 'extract', str(src), n], capture_output=True, check=True).stdout)
            rel.append(n[len(prefix):])
        with open(t / 'build/gdm.css', 'a') as f:
            f.write(fill((LIB / 'gdm.css.in').read_text(), pal))
        (t / 'build/neon-login.png').write_bytes(png(scrim(wall, pal['bg'], 0.22, 0.30, 0.42)))
        rel = sorted(set(rel) | {'neon-login.png'})
        (t / 'x.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<gresources><gresource prefix="%s">%s</gresource></gresources>\n'
                                 % (prefix.rstrip('/'), ''.join(f'<file>{r}</file>' for r in rel)))
        out = t / 'out.gresource'
        subprocess.run(['glib-compile-resources', f'--sourcedir={t}/build', f'--target={out}', str(t / 'x.xml')], check=True)
        got = subprocess.run(['gresource', 'list', str(out)], capture_output=True, text=True, check=True).stdout.split()
        if set(got) != {prefix + r for r in rel}:
            raise RuntimeError('built login theme is incomplete; left as it was')
        atomic(target, out.read_bytes())
    # for the login animation: colours and the welcome picture (same shading as neon-splash)
    w, h = wall.size
    y, x = np.mgrid[0:h, 0:w]
    t = np.clip((np.hypot(x - w / 2, y - h / 2) - 60) / (max(w, h) * 0.62 - 60), 0, 1)
    a = np.interp(t, [0, 0.35, 1], [0.74, 0.5, 0.28])[..., None]
    back = np.array([int(pal['bg'][i:i + 2], 16) for i in (1, 3, 5)], float)
    im = Image.fromarray((np.asarray(wall.convert('RGB'), float) * (1 - a) + back * a).astype('uint8'))
    buf = io.BytesIO()
    im.save(buf, 'JPEG', quality=92)
    atomic(target.parent / 'welcome.jpg', buf.getvalue())
    buf = io.BytesIO()
    back = scrim(wall, pal['bg'], 0.30, 0.46, 0.62).resize((1920, 1080), Image.LANCZOS)
    if with_splash and masks is not None:
        try:
            back = rest_pose(back, pal, masks)
        except Exception as e:           # the plain picture does as well
            log('rest pose:', repr(e))
    back.save(buf, 'JPEG', quality=95)
    atomic(target.parent / 'boot.jpg', buf.getvalue())
    atomic(target.parent / 'login.json', json.dumps({
        'bg': pal['bg'], 'text': pal['text'], 'primary': pal['primary'], 'tertiary': pal['tertiary'],
        'container': pal.get('primary_container', pal['bg_alt'])}).encode())
    log('login:', target.stat().st_size // 1024, 'KiB')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='/')
    ap.add_argument('--palette')
    ap.add_argument('--wallpaper')
    ap.add_argument('--user')
    ap.add_argument('--masks', default=str(LIB / 'masks.npz'))
    a = ap.parse_args()
    root = Path(a.root)
    user = pwd.getpwnam(a.user) if a.user else pwd.getpwuid(os.getuid())
    pal, image = read_palette(a.palette or f'{user.pw_dir}/.config/neon-grid/palette-state.json')
    image = a.wallpaper or image or f'{user.pw_dir}/.config/bingwallpaper/BingWallpaper.jpg'
    masks = np.load(a.masks, allow_pickle=False)
    big = decode(image, user, LOGIN_W, LOGIN_H)
    wall = big.resize((W, H), Image.LANCZOS)
    failed = False
    for job in (lambda: splash(root / 'usr/share/plymouth/themes/neon-grid', pal, wall, masks),
                lambda: grub(root / 'boot/grub/themes/neon-grid', pal, wall, masks),
                lambda: login(root / 'usr/local/share/neon-grid/neon-grid-gdm.gresource', pal, big, masks,
                              (root / 'etc/systemd/system/neon-rest.service').exists())):
        try:
            job()
        except Exception as e:          # one screen must not block the others
            failed = True
            log('failed:', repr(e))
    sys.exit(failed)


if __name__ == '__main__':
    os.umask(0o022)
    main()
