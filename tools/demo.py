#!/usr/bin/env python3
"""Invented data for screenshots: nothing in here is real.

    tools/demo.py <home> <runtime dir> [dusk|forest|sunset]

Writes an abstract wallpaper with its Material You palette, and the data files of both boards, below
<home> and <runtime dir>. Run a board with HOME and XDG_RUNTIME_DIR pointing there.
"""
import importlib.util
import json
import math
import os
import random
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

home, run = Path(sys.argv[1]), Path(sys.argv[2])
LOOK = sys.argv[3] if len(sys.argv) > 3 else 'dusk'
cache = home / '.cache/neon-grid'
for d in (cache, run, home / '.config/neon-grid', home / '.config/conky'):
    d.mkdir(parents=True, exist_ok=True)
rnd = random.Random(7)

# ---- wallpaper: soft dunes of colour
W, H = 2560, 1440
y, x = np.mgrid[0:H, 0:W].astype(np.float32)
u, v = x / W, y / H
img = np.empty((H, W, 3), np.float32)
BASE, DARK, LIGHTS = {
    'dusk': ((18, 24, 58), (12, 14, 38), ((64, 92, 190), (150, 84, 190), (30, 130, 160), (226, 120, 120), (70, 60, 150))),
    'forest': ((14, 38, 34), (8, 24, 24), ((40, 150, 110), (150, 170, 70), (20, 120, 130), (230, 200, 110), (30, 100, 80))),
    'sunset': ((52, 20, 34), (36, 12, 26), ((220, 90, 70), (240, 150, 70), (150, 50, 110), (250, 200, 120), (170, 50, 70))),
}[LOOK]
img[:] = np.array(BASE, np.float32)
for (cx, cy, r), col in zip(((.15, .2, .55), (.82, .18, .5), (.55, .9, .6), (.95, .85, .45), (.35, .6, .35)), LIGHTS):
    d = np.exp(-(((u - cx) * 1.6) ** 2 + (v - cy) ** 2) / (r * r * .5))[..., None]
    img = img * (1 - d * .85) + np.array(col, np.float32) * d * .85
for k in range(9):
    edge = .42 + k * .07 + .05 * np.sin(u * (3 + k * .7) * 2 + k) + .02 * np.sin(u * 13 + k * 2)
    shade = np.clip((v - edge) * 26, 0, 1)[..., None] * .13
    img = img * (1 - shade) + np.array(DARK, np.float32) * shade
    rim = np.exp(-((v - edge) * 160) ** 2)[..., None] * 18
    img += rim
img += np.random.default_rng(3).normal(0, 2.2, img.shape)
wall = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(.6))
wall.save(cache / 'wallpaper.jpg', quality=94)

# ---- palette and derived pictures, with neon-palette's own code (no settings are touched)
here = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('np_', here / 'config/neon-grid/neon-palette.py')
npal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(npal)
npal.WALL = cache / 'wallpaper.jpg'
npal.CONKY = home / '.config/neon-grid/palette.lua'
npal.BROWSER = home / 'browser'
npal.CONF = here / 'config/neon-grid'
npal.chrome_prefs = lambda: None
scheme, p = npal.make_palette(npal.WALL)
npal.conky(p)
npal.splash(p)
npal.browsers(p)
(home / 'palette-state.json').write_text(json.dumps({
    'mode': 'wallpaper', 'base': 'x', 'palette': {k: npal.hx(c) for k, c in p.items()}, 'image': str(npal.WALL)}))

# ---- Search Console board
DAY = 86400
today = int(time.time()) // DAY * DAY
hosts = ['tools', 'docs', 'blog', '', 'studio', 'maps', 'lab', 'notes', 'shop', 'status', 'forms', 'fonts']
words = ['color palette generator', 'image to svg', 'json formatter', 'unit converter', 'free icons', 'regex tester',
         'markdown preview', 'png compressor', 'css gradient', 'base64 decode', 'qr code maker', 'timezone planner',
         'diff two files', 'svg to png', 'font pairing', 'contrast checker', 'cron explained', 'uuid generator',
         'hex to rgb', 'lorem ipsum']
places = [('India', 34), ('USA', 22), ('Germany', 9), ('Brazil', 7), ('Japan', 5), ('UK', 4)]


def series(n, base, grow, wobble):
    a = rnd.random() * 6
    return [max(0, base * (1 + grow * i / n) * (1 + .18 * math.sin(i * 2 * math.pi / 7 + a)) * (1 + rnd.uniform(-wobble, wobble)))
            for i in range(n)]


def row(*v):
    return '\t'.join('%.2f' % x if isinstance(x, float) else str(x) for x in v)


def ints(v):
    return ','.join('%d' % x for x in v)


def part(tag, ident, names, total, share=False):
    out, left = [], 100.0
    for i, nm in enumerate(names):
        nm, pc = nm if isinstance(nm, tuple) else (nm, 34 / (1 + i))
        out.append(row(tag, ident, nm, total[0] * pc / 100, total[1] * pc / 100, 3 + i * 2.3, float(pc)))
    return out


for days in (28, 60, 90, 365):
    end = today - 2 * DAY
    start = end - (days - 1) * DAY
    f = lambda t: time.strftime('%Y-%m-%d', time.gmtime(t))
    sites = []
    for i, h in enumerate(hosts):
        base = 420 / (1 + i * .9)
        im = series(days, base, rnd.uniform(-.3, 1.2), .22)
        pos = [max(1, 5 + i * 1.4 + 2 * math.sin(j / 5 + i) + rnd.uniform(-1, 1)) for j in range(days)]
        ck = [v * rnd.uniform(.02, .07) for v in im]
        sites.append((('%s.example.com' % h).lstrip('.'), im, ck, pos))
    ti = sum(sum(s[1]) for s in sites)
    tc = sum(sum(s[2]) for s in sites)
    hi = [sum(s[1][j] for s in sites) for j in range(days)]
    hc = [sum(s[2][j] for s in sites) for j in range(days)]
    prev = days < 365
    L = [row('meta', f(start), f(end), int(time.time()) - 734, days, int(prev), 'example.com'),
         row('tot', tc, ti, 100 * tc / ti, 8.4, tc * .88 if prev else -1.0, ti * .91 if prev else -1.0, 3.9, 9.1),
         row('h_clicks', *hc), row('h_impr', *hi), row('h_pos', *[8.4 + math.sin(j / 4) for j in range(days)])]
    L += part('ap', 'all', ['tools.example.com/', 'docs.example.com/start', 'blog.example.com/why', 'tools.example.com/svg',
                            'maps.example.com/'], (tc, ti))
    L += part('ac', 'all', places, (tc, ti)) + part('ad', 'all', [('Desktop', 63), ('Mobile', 34), ('Tablet', 3)], (tc, ti))
    for host, im, ck, pos in sites:
        c, i = sum(ck), sum(im)
        g = rnd.uniform(.6, 1.3)
        L.append(row('site', host, c, i, 100 * c / i, sum(pos) / days, c * g if prev else -1.0, i * g if prev else -1.0,
                     ints(im), ints(ck), ','.join('%.1f' % q for q in pos), 9.0))
        L += part('sq', host, rnd.sample(words, 5), (c, i)) + part('sp', host, ['/', '/start', '/guide', '/about'], (c, i))
        L += part('sc', host, places[:5], (c, i)) + part('sd', host, [('Desktop', 60), ('Mobile', 37), ('Tablet', 3)], (c, i))
    for k, w in enumerate(words[:3]):
        L.append(row('op', w, 4.0, 830.0 - k * 200, 8.7, 'tools.example.com/' + w.split()[0]))
    for k, w in enumerate(words, 1):
        im = series(days, 60 / (1 + k * .25), rnd.uniform(-.3, .9), .5)
        ck = [1.0 if rnd.random() < .5 / (1 + k * .2) else 0.0 for _ in im]
        ck = [c * rnd.randint(1, 3) for c in ck]
        c, i = sum(ck), sum(im)
        L.append(row('query', w, c, i, 2 + k * .7, c * .8 if prev else -1.0, i * .9 if prev else -1.0, 3 + k * .7,
                     ints(im), ints(ck), ','.join('%.1f' % (2 + k * .7 + rnd.uniform(-1, 1)) for _ in im)))
        L += part('qp', str(k), ['tools.example.com/' + w.split()[0], 'blog.example.com/' + w.split()[0]], (c, i))
        L += part('qc', str(k), places[:4], (c, i)) + part('qd', str(k), [('Desktop', 70), ('Mobile', 30)], (c, i))
    (cache / f'gsc-{days}.txt').write_text('\n'.join(L) + '\n')


# ---- command panel
def walk(n, lo, hi, step, start=None):
    v, out = start if start is not None else (lo + hi) / 2, []
    for _ in range(n):
        v = min(hi, max(lo, v + rnd.uniform(-step, step)))
        out.append(v)
    return out


N = 150
h = {'cpu': walk(N, 8, 72, 9), 'mem': walk(N, 48, 63, .8), 'gpu': walk(N, 15, 88, 9), 'vram': walk(N, 30, 52, 2),
     'ctemp': walk(N, 52, 84, 4), 'gtemp': walk(N, 48, 66, 2), 'fan1': walk(N, 2900, 3900, 90), 'fan2': walk(N, 2800, 3800, 90),
     'down': [abs(rnd.gauss(0, 1)) ** 3 * 700 + 20 for _ in range(N)], 'up': [abs(rnd.gauss(0, 1)) ** 3 * 160 + 10 for _ in range(N)],
     'rgpu': walk(N, 5, 45, 6), 'read': [abs(rnd.gauss(0, 1)) ** 4 * 6000 for _ in range(N)],
     'write': [abs(rnd.gauss(0, 1)) ** 4 * 3500 for _ in range(N)]}
names = ['web-backend', 'browser', 'video-editor', 'compiler', 'music', 'code-editor', 'indexer', 'mail', 'chat', 'cinnamon',
         'Xorg', 'conky', 'notes', 'sync', 'backup', 'terminal', 'photos']
now = int(time.time())
L = [row('stamp', now + 100000), row('cpu', h['cpu'][-1], 16), row('mem', h['mem'][-1], 12.9, 23.3),
     row('gpu', h['gpu'][-1], 3420.0, 8192.0), row('temp', h['ctemp'][-1], h['gtemp'][-1]),
     row('fan', h['fan1'][-1], h['fan2'][-1], 5800.0, 6100.0, 'BETTER_AUTO'), row('kbd', 'WAVE 60'),
     row('net', h['down'][-1], h['up'][-1], 'wlan0'), row('disk', 61.0, 371.4, 953.0),
     row('topcpu', *sum(([n, float(v)] for n, v in zip(names, (182, 64, 41, 22, 9, 6))), [])),
     row('topmem', *sum(([n, float(v)] for n, v in zip(['browser', 'video-editor', 'code-editor', 'web-backend', 'indexer', 'chat'],
                                                        (3210, 2480, 1370, 910, 620, 410))), [])),
     row('topgpu', 'video-editor', 2900.0, 'browser', 420.0), row('cores', *walk(16, 5, 96, 40)),
     row('load', 5.2, 4.6, 4.1, 4.4, 5.1, 248, 2106), row('memx', 11.6, 5.8, 10.4, 0.6, 8.0),
     row('gpux', 64.0, 1980.0, 3090.0, 'P2', 22.0, 310.0, 512.0),
     row('sens', 'CPU', 71.0, 'Board', 58.0, 'SSD 1', 47.0, 'SSD 2', 52.0, 'Memory', 49.0, 'Radeon', 46.0),
     row('netx', 'My Wi-Fi', 84.0, '866 Mbit/s', '192.0.2.24', 18.4, 2.6),
     row('conn', 'browser', 14.0, 'chat', 5.0, 'sync', 3.0, 'mail', 2.0), row('diskx', h['read'][-1], h['write'][-1], -2.4, 24.0),
     row('prof', 'balanced'), row('bat', 87.0, 'Discharging', 21.5, 97.0, 41.0, 58.0, 66.0),
     row('who_cpu', *['%s|%d' % (names[rnd.choice((0, 0, 0, 1, 2))], 60 + rnd.random() * 120) for _ in range(N)]),
     row('who_mem', *['browser|3200' for _ in range(N)])]
for i, n in enumerate(names):
    cpu = [182, 64, 41, 22, 9, 6, 5, 3, 2.2, 1.6, 1.4, 1.1, .6, .3, .2, .2, .1][i]
    ram = [910, 3210, 2480, 340, 180, 1370, 620, 260, 410, 150, 60, 34, 120, 88, 40, 70, 210][i]
    sp = [max(0, cpu * (1 + .5 * math.sin(j / 3 + i)) + rnd.uniform(-2, 2)) for j in range(40)]
    L.append(row('app', '%08x' % (i + 1), n, float(cpu), float(ram), [820.0, 12.0, 4300.0, 0.0][i % 4], 1 + i % 7, 8 + i * 3, 0.0,
                 4000 + i * 2700, 'restart' if i == 0 else '-' if n in ('cinnamon', 'Xorg', 'conky') else 'end', ints(sp)))
L += [row('h_' + k, *v) for k, v in h.items()]
L += [row('claude', 38.0, now + 7900, 46.0, now + 3 * DAY, 'Claude', 34.0, 4.2, now),
      row('cl_t', *[now - DAY + k * 600 for k in range(144)]), row('cl_5', *[(k * 1.4) % 46 for k in range(144)]),
      row('cl_w', *[30 + k * .11 for k in range(144)])]
(run / 'neon-deck.txt').write_text('\n'.join(L) + '\n')
