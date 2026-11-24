#!/usr/bin/env python3
"""Pre-render the boot splash shapes as colour-free masks (run once at install).

The logos are read from this PC (the distribution's and the one the firmware shows); they are
not stored in the repo. Your own: ~/.config/neon-grid/oem-logo.svg or distro-logo.svg (or .png). neon-boot-theme.py tints the masks per palette.
    python3 make_masks.py out.npz
"""
import io
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SHAPE, SHAPE_FRAMES, LOBES = 280, 48, 9       # one lobe of rotation = a seamless loop
COF, COF_FRAMES = 132, 240                    # Circle of Friends repeats every 120 degrees
UBUNTU = '/usr/share/pixmaps/ubuntu-logo.svg'
BGRT = '/sys/firmware/acpi/bgrt/image'


def orbitron(size, weight):
    for d in (os.path.join(HERE, '..', 'fonts'), os.path.expanduser('~/.local/share/fonts')):
        f = os.path.join(d, 'Orbitron.ttf')
        if os.path.exists(f):
            f = ImageFont.truetype(f, size)
            f.set_variation_by_name(weight)
            return f
    raise SystemExit('Orbitron.ttf not found')


def shape(phase):
    s, n = 4, SHAPE * 4
    img, c, r0 = Image.new('L', (n, n)), n / 2, (SHAPE / 2 - 14) * s
    pts = []
    for i in range(720):
        a = math.radians(i / 2)
        r = r0 * (1 + 0.055 * math.cos(LOBES * a)) / 1.055
        b = a + math.radians(360 / LOBES * phase)
        pts.append((c + r * math.cos(b), c + r * math.sin(b)))
    ImageDraw.Draw(img).polygon(pts, fill=255)
    return np.asarray(img.resize((SHAPE, SHAPE), Image.LANCZOS))


def ubuntu_source(size):
    """White parts of Ubuntu's logo, centred on the ring's own centre."""
    import gi
    gi.require_version('GdkPixbuf', '2.0')
    from gi.repository import GdkPixbuf
    ok, data = GdkPixbuf.Pixbuf.new_from_file_at_size(UBUNTU, size, size).save_to_bufferv('png', [], [])
    # background is orange (blue channel 0x20), the mark is white
    blue = np.asarray(Image.open(io.BytesIO(data)).convert('RGB'))[..., 2].astype(np.float32)
    m = np.clip((blue - 32) / (255 - 32), 0, 1)
    ys, xs = np.nonzero(m > 0.5)
    # three equal dots 120 degrees apart: the centroid of the mark is the rotation centre
    w = m[ys, xs]
    cx, cy = (xs * w).sum() / w.sum(), (ys * w).sum() / w.sum()
    rad = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2).max() + 2
    img = Image.fromarray((m * 255).astype(np.uint8))
    return img.crop((int(cx - rad), int(cy - rad), int(cx + rad), int(cy + rad)))


def read_image(path, size=1200):
    """Any picture as RGB plus its transparency (or None)."""
    if path.lower().endswith('.svg'):
        import gi
        gi.require_version('GdkPixbuf', '2.0')
        from gi.repository import GdkPixbuf
        ok, data = GdkPixbuf.Pixbuf.new_from_file_at_size(path, size, size).save_to_bufferv('png', [], [])
        im = Image.open(io.BytesIO(data))
    else:
        im = Image.open(path)
    im.load()
    if 'A' in im.getbands() and im.getchannel('A').getextrema()[0] < 128:
        return im.convert('RGB'), np.asarray(im.getchannel('A'), np.float32) / 255
    return im.convert('RGB'), None


def ink(im, alpha):
    """0..1: what belongs to the logo. The background is whatever the border is made of."""
    px = np.asarray(im, np.float32)
    if alpha is not None:
        m = alpha
    else:
        edge = np.concatenate([px[:3].reshape(-1, 3), px[-3:].reshape(-1, 3), px[:, :3].reshape(-1, 3), px[:, -3:].reshape(-1, 3)])
        d = np.abs(px - np.median(edge, axis=0)).max(axis=2)
        m = np.clip((d - 12) / max(40.0, np.percentile(d[d > 12], 90) * 0.8 - 12) if (d > 12).any() else d * 0, 0, 1)
    on = m > 0.5
    if on.sum() < 60:
        return None
    ys, xs = np.nonzero(on)
    box = on[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    if box.mean() > 0.82:                       # a filled plate: the mark is what stands out on it
        sub = px[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
        d = np.abs(sub - np.median(sub[box], axis=0)).max(axis=2)
        k = np.clip((d - 30) / 90, 0, 1) * box
        # a rim around the plate is not the mark
        cut = max(2, min(k.shape) // 30)
        inner = np.zeros_like(k)
        inner[cut:-cut, cut:-cut] = k[cut:-cut, cut:-cut]
        if (inner > 0.5).mean() > 0.02:
            m = np.zeros_like(m)
            m[ys.min():ys.max() + 1, xs.min():xs.max() + 1] = inner
    return m


def fitted(m):
    """Cropped to the mark (an emblem above a name loses the name), smooth, at badge size."""
    on = m > 0.4
    rows = np.nonzero(on.any(axis=1))[0]
    if not len(rows):
        return None
    cuts = np.nonzero(np.diff(rows) > max(4, (rows[-1] - rows[0]) * 0.03))[0]
    blocks = np.split(rows, cuts + 1)
    rows = max(blocks, key=lambda r: (r[-1] - r[0]) * (1 if on[r[0]:r[-1] + 1].sum() > 0.15 * on.sum() else 0.1))
    cols = np.nonzero(on[rows[0]:rows[-1] + 1].any(axis=0))[0]
    y0, y1, x0, x1 = rows[0], rows[-1] + 1, cols[0], cols[-1] + 1
    if x1 - x0 < 10 or y1 - y0 < 6:
        return None
    im = Image.fromarray((np.pad(m[y0:y1, x0:x1], 2) * 255).astype(np.uint8))
    wide = im.width / im.height
    w = 176 if wide > 2.2 else 128 if wide > 1 else max(1, round(128 * wide))
    h = max(1, round(w / wide))
    if im.width < w * 4:                        # small firmware pictures: grow, then sharpen the edge again
        big = im.resize((w * 8, h * 8), Image.BICUBIC).filter(ImageFilter.GaussianBlur(7))
        im = big.point(lambda v: 255 if v > 127 else 0)
    return np.asarray(im.resize((w, h), Image.LANCZOS))


MAKERS = {'asustek': 'ASUS', 'micro-star': 'MSI', 'hewlett': 'HP', 'dell': 'DELL', 'lenovo': 'LENOVO', 'acer': 'ACER',
          'gigabyte': 'GIGABYTE', 'samsung': 'SAMSUNG', 'framework': 'FRAMEWORK', 'system76': 'SYSTEM76', 'tuxedo': 'TUXEDO',
          'razer': 'RAZER', 'microsoft': 'SURFACE', 'apple': 'MAC', 'huawei': 'HUAWEI', 'toshiba': 'TOSHIBA', 'fujitsu': 'FUJITSU',
          'lg electronics': 'LG', 'xiaomi': 'XIAOMI', 'qemu': 'QEMU', 'vmware': 'VMWARE', 'innotek': 'VIRTUALBOX'}


def maker():
    """The maker's name from the firmware tables, or ''."""
    for f in ('sys_vendor', 'board_vendor', 'chassis_vendor'):
        try:
            with open('/sys/class/dmi/id/' + f) as h:
                v = h.read().strip()
        except OSError:
            continue
        for k, name in MAKERS.items():
            if k in v.lower():
                return name
        word = (v.replace(',', ' ').split() or [''])[0].upper()
        if 2 <= len(word) <= 12 and word.isascii() and word.isalnum() and not v.lower().startswith(('to be', 'default', 'system', 'o.e.m', 'unknown', 'not ')):
            return word
    return ''


def word(txt):
    size = 60
    while True:
        f = orbitron(size, 'Bold')
        x0, y0, x1, y1 = f.getbbox(txt)
        if x1 - x0 <= 184 or size <= 14:
            break
        size -= 2
    img = Image.new('L', (x1 - x0 + 4, y1 - y0 + 4))
    ImageDraw.Draw(img).text((2 - x0, 2 - y0), txt, font=f, fill=255)
    return np.asarray(img)


def computer():
    """A plain screen, when nothing is known about the machine."""
    s = 4
    img = Image.new('L', (128 * s, 96 * s))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([14 * s, 4 * s, 114 * s, 74 * s], 10 * s, outline=255, width=8 * s)
    d.rounded_rectangle([2 * s, 82 * s, 126 * s, 92 * s], 5 * s, fill=255)
    return np.asarray(img.resize((128, 96), Image.LANCZOS))


def oem():
    """The machine's own logo: your picture, else what the firmware shows, else its name, else a computer."""
    own = [os.path.expanduser('~/.config/neon-grid/oem-logo.' + e) for e in ('svg', 'png', 'jpg', 'webp')]
    for f in own + [BGRT]:
        try:
            if os.path.exists(f):
                m = ink(*read_image(f))
                m = fitted(m) if m is not None else None
                if m is not None:
                    return m
        except Exception as e:
            print('logo', f, 'not usable:', e, file=sys.stderr)
    name = maker()
    return word(name) if name else computer()


def distro(size):
    """The distribution's mark and whether it may turn (only Ubuntu's looks the same after 120 degrees)."""
    info = {}
    try:
        with open('/etc/os-release') as f:
            for line in f:
                k, _, v = line.strip().partition('=')
                info[k] = v.strip('"')
    except OSError:
        pass
    own = [os.path.expanduser('~/.config/neon-grid/distro-logo.' + e) for e in ('svg', 'png')]
    if info.get('ID') == 'ubuntu' and os.path.exists(UBUNTU) and not any(map(os.path.exists, own)):
        try:
            return ubuntu_source(size), True
        except Exception as e:
            print('Ubuntu logo not usable:', e, file=sys.stderr)
    logo, ident = info.get('LOGO', ''), info.get('ID', '')
    found = [f'{d}/{n}.{e}' for n in (logo, f'{ident}-logo', f'{ident}-logo-icon', f'distributor-logo-{ident}', 'distributor-logo') if n
             for e in ('svg', 'png')
             for d in ('/usr/share/pixmaps', '/usr/share/icons/hicolor/scalable/apps', '/usr/share/icons/hicolor/256x256/apps',
                       '/usr/share/icons/hicolor/128x128/apps', '/usr/share/icons/vendor/scalable/emblems')]
    for f in own + found:
        try:
            if os.path.exists(f):
                m = ink(*read_image(f))
                m = fitted(m) if m is not None else None
                if m is not None:
                    break
        except Exception as e:
            print('logo', f, 'not usable:', e, file=sys.stderr)
    else:
        m = word((info.get('NAME') or 'LINUX').split()[0].upper()[:10])
    side = max(m.shape) * 5 // 4
    img = Image.new('L', (side, side))
    img.paste(Image.fromarray(m), ((side - m.shape[1]) // 2, (side - m.shape[0]) // 2))
    return img, False


def label(txt, size=24, spacing=8, pad=10):
    f = orbitron(size, 'Medium')
    d = ImageDraw.Draw(Image.new('L', (1, 1)))
    w = [d.textlength(ch, font=f) for ch in txt]
    asc, desc = f.getmetrics()
    img = Image.new('L', (int(sum(w) + spacing * (len(txt) - 1)) + 2 * pad, asc + desc + 2 * pad))
    d, x = ImageDraw.Draw(img), pad
    for ch, cw in zip(txt, w):
        d.text((x, pad), ch, font=f, fill=255)
        x += cw + spacing
    return np.asarray(img)


def dot(diam):
    s = 8
    img = Image.new('L', ((diam + 2) * s,) * 2)
    ImageDraw.Draw(img).ellipse([s, s, (diam + 1) * s, (diam + 1) * s], fill=255)
    return np.asarray(img.resize((diam + 2,) * 2, Image.LANCZOS))


def build():
    out = {f'shape-{i:02d}': shape(i / SHAPE_FRAMES) for i in range(SHAPE_FRAMES)}
    src, turns = distro(1200)
    side = COF if turns else COF * 5 // 4
    for i in range(COF_FRAMES):
        turned = src.rotate(-120 * i / COF_FRAMES, Image.BICUBIC) if turns else src
        out[f'cof-{i:03d}'] = np.asarray(turned.resize((side, side), Image.LANCZOS))
    out['oem'] = oem()
    out['hint'] = label('TAB  BOOT LOG        ESC  FULL TEXT', size=13, spacing=2)
    for k, t in {'boot': 'STARTING UP', 'shutdown': 'POWERING DOWN', 'reboot': 'RESTARTING',
                 'updates': 'INSTALLING UPDATES'}.items():
        out['sub-' + k] = label(t)
    out['wave'], out['orbit'], out['bullet'] = dot(8), dot(12), dot(12)
    return out


if __name__ == '__main__':
    np.savez_compressed(sys.argv[1], **build())
