#!/usr/bin/env python3
"""Draws the README's SVG art into docs/art (needs fontTools). Text becomes outlines, so it looks the same everywhere."""
import math
from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'docs/art'
OUT.mkdir(parents=True, exist_ok=True)
FONTS = {}


def font(weight):
    if weight not in FONTS:
        f = instantiateVariableFont(TTFont(ROOT / 'fonts/Orbitron.ttf'), {'wght': weight})
        FONTS[weight] = (f, f.getGlyphSet(), f.getBestCmap(), f['head'].unitsPerEm)
    return FONTS[weight]


def text(s, x, y, size, weight=700, gap=0.0, anchor='l'):
    f, glyphs, cmap, upm = font(weight)
    k = size / upm
    w = sum(glyphs[cmap.get(ord(c), '.notdef')].width * k + gap for c in s) - gap
    x -= {'l': 0, 'm': w / 2, 'r': w}[anchor]
    d = []
    for c in s:
        g = glyphs[cmap.get(ord(c), '.notdef')]
        pen = SVGPathPen(glyphs, ntos=lambda v: ('%.2f' % v).rstrip('0').rstrip('.'))
        g.draw(TransformPen(pen, (k, 0, 0, -k, x, y)))
        d.append(pen.getCommands())
        x += g.width * k + gap
    return ''.join(d), w


GRAD = ('<linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#6f86f0"/><stop offset=".5" stop-color="#a678d8"/>'
        '<stop offset="1" stop-color="#d9798f"/></linearGradient>')
EASE = 'calcMode="spline" keySplines=".2 0 0 1;.2 0 0 1"'


def save(name, w, h, body, defs=''):
    (OUT / name).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img">'
                            f'<defs>{GRAD}{defs}</defs>{body}</svg>\n')


def wave(x0, x1, y, amp, period, phase):
    pts = [f'{x:.1f} {y + amp * math.sin((x - x0) / period * 2 * math.pi + phase):.2f}' for x in range(int(x0), int(x1) + 1, 8)]
    return 'M' + 'L'.join(pts)


def header(name, title):
    W, H = 1000, 74
    d, w = text(title, 4, 38, 30, 700, 1.5)
    fr = ';'.join(wave(0, W, 58, 4.5, 90, -p * math.pi / 4) for p in range(9))
    save(f'h-{name}.svg', W, H,
         f'<path d="{d}" fill="url(#g)"/>'
         f'<path d="{wave(0, W, 58, 4.5, 90, 0)}" fill="none" stroke="url(#g)" stroke-width="2.5" stroke-linecap="round" mask="url(#m)">'
         f'<animate attributeName="d" values="{fr}" dur="4s" repeatCount="indefinite"/></path>',
         '<linearGradient id="f" x1="0" x2="1"><stop offset="0" stop-color="#fff"/><stop offset=".55" stop-color="#fff" stop-opacity=".55"/>'
         '<stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient><mask id="m"><rect width="1000" height="74" fill="url(#f)"/></mask>')


def scallop(cx, cy, r, lobes=9):
    pts = []
    for i in range(180):
        a = math.radians(i * 2)
        q = r * (1 + .055 * math.cos(lobes * a))
        pts.append(f'{cx + q * math.cos(a):.1f} {cy + q * math.sin(a):.1f}')
    return 'M' + 'L'.join(pts) + 'Z'


def icon(kind):                        # drawn in a 24x24 box
    s = 'fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"'
    return {
        'power': f'<path {s} d="M12 3v8M7 6.2a8 8 0 1 0 10 0"/>',
        'grub': f'<path {s} d="M4 6h16M4 12h16M4 18h10"/><circle cx="19" cy="18" r="1.4" fill="currentColor"/>',
        'boot': f'<path {s} d="M3 13c2-5 4-5 6 0s4 5 6 0 4-5 6 0"/>',
        'login': f'<circle {s} cx="12" cy="8" r="3.6"/><path {s} d="M5 20c1-4.2 3.6-6 7-6s6 1.800 7 6"/>',
        'welcome': f'<path {s} d="M12 3l2 5.500 5.600 1.500-4.600 3.500.6 6-3.600-3.300L8.400 19.500l.6-6L4.400 10 10 8.500z"/>',
        'desktop': f'<rect {s} x="3" y="4" width="18" height="12" rx="2.200"/><path {s} d="M9 20h6M12 16v4"/>',
        'palette': f'<path {s} d="M12 3a9 9 0 1 0 0 18c1.800 0 2-1.300 1.300-2.300-.9-1.300 0-2.700 1.600-2.700H18a3 3 0 0 0 3-3A9.500 9.500 0 0 0 12 3z"/><circle cx="8" cy="10" r="1.200" fill="currentColor"/><circle cx="12" cy="7.500" r="1.200" fill="currentColor"/><circle cx="16" cy="10" r="1.200" fill="currentColor"/>',
        'glass': f'<rect {s} x="3" y="3" width="13" height="13" rx="3"/><rect {s} x="8" y="8" width="13" height="13" rx="3"/>',
        'motion': f'<path {s} d="M3 20C10 20 8 4 21 4"/><circle cx="21" cy="4" r="1.700" fill="currentColor"/><circle cx="3" cy="20" r="1.700" fill="currentColor"/>',
        'gauge': f'<path {s} d="M4 17a8.500 8.500 0 1 1 16 0"/><path {s} d="M12 14l4-4.500"/><circle cx="12" cy="14" r="1.500" fill="currentColor"/>',
        'bell': f'<path {s} d="M6 16V11a6 6 0 0 1 12 0v5l1.600 2H4.400zM10 21h4"/>',
        'chart': f'<path {s} d="M3 20h18M4 15l5-5 4 3 7-8"/>',
        'shield': f'<path {s} d="M12 3l7.500 2.800v5.700c0 4.500-3 7.800-7.500 9.500-4.500-1.700-7.500-5-7.500-9.500V5.800z"/><path {s} d="M8.800 12l2.300 2.300 4.200-4.600"/>',
        'scroll': f'<rect {s} x="7" y="2.500" width="10" height="19" rx="5"/><path {s} d="M12 6.500v4"/>',
        'genie': f'<path {s} d="M4 4h16v6c0 4-6 4-6 10h-4c0-6-6-6-6-10z"/>',
        'browser': f'<rect {s} x="3" y="4" width="18" height="16" rx="2.500"/><path {s} d="M3 9h18M6.500 6.500h.1M9.500 6.500h.1"/>',
        'fan': f'<circle {s} cx="12" cy="12" r="2"/><path {s} d="M12 10c-1-5 1-7 3-7 2.500 0 2 4.500-1.600 7.700M14 12c5-1 7 1 7 3 0 2.500-4.500 2-7.700-1.600M12 14c1 5-1 7-3 7-2.500 0-2-4.500 1.600-7.700M10 12c-5 1-7-1-7-3 0-2.500 4.500-2 7.700 1.600"/>',
        'robot': f'<rect {s} x="4" y="8" width="16" height="11" rx="3"/><path {s} d="M12 4v4M9 13h.1M15 13h.1M9.500 16.300h5"/>',
    }[kind]


def badge(name, kind, back, front):
    save(f'i-{name}.svg', 64, 64, f'<path d="{scallop(32, 32, 28)}" fill="{back}"><animateTransform attributeName="transform" type="rotate" '
         f'from="0 32 32" to="40 32 32" dur="6s" repeatCount="indefinite"/></path><g transform="translate(17 17) scale(1.25)" color="{front}">{icon(kind)}</g>')


def pill(name, label, filled=False, kind=None):
    pad, size = 22, 14.5
    lead = 26 if kind else 0
    d, w = text(label, pad + lead, 27, size, 700 if filled else 600, 0.6)
    W = round(w + 2 * pad + lead)
    back = 'url(#g)' if filled else '#1c2348'
    ic = f'<g transform="translate({pad - 4} 11) scale(.83)" color="#fff">{icon(kind)}</g>' if kind else ''
    save(f'{name}.svg', W, 42, f'<rect x="1" y="1" width="{W - 2}" height="40" rx="20" fill="{back}" stroke="#7f8fe0" stroke-opacity=".7"/>{ic}<path d="{d}" fill="#fff"/>')


def journey():
    W, H = 1200, 230
    steps = [('power', 'POWER'), ('grub', 'GRUB'), ('boot', 'BOOT'), ('login', 'LOGIN'), ('welcome', 'WELCOME'), ('desktop', 'DESKTOP')]
    xs = [110 + i * 196 for i in range(6)]
    ys = [100 + (14 if i % 2 else -14) for i in range(6)]
    p = f'M{xs[0]} {ys[0]}' + ''.join(f'C{xs[i] + 90} {ys[i]} {xs[i + 1] - 90} {ys[i + 1]} {xs[i + 1]} {ys[i + 1]}' for i in range(5))
    cols = [('#364479', '#dfe3ff'), ('#364479', '#dfe3ff'), ('#5c3d54', '#ffd8f3'), ('#364479', '#dfe3ff'), ('#b7c4ff', '#1f2a5c'), ('#5c3d54', '#ffd8f3')]
    b = ['<rect x="1" y="1" width="1198" height="228" rx="28" fill="url(#bg)" stroke="#6f7cc4" stroke-opacity=".5"/>',
         f'<path d="{wave(30, 1170, 60, 12, 320, 0)}" fill="none" stroke="#8ea2ff" stroke-opacity=".16" stroke-width="2"/>',
         f'<path d="{wave(30, 1170, 130, 14, 420, 1.4)}" fill="none" stroke="#d9a0c8" stroke-opacity=".14" stroke-width="2"/>',
         f'<path d="{p}" fill="none" stroke="#8ea2ff" stroke-opacity=".28" stroke-width="3"/>',
         f'<path d="{p}" fill="none" stroke="url(#g)" stroke-width="4" stroke-linecap="round" pathLength="100" stroke-dasharray="100" stroke-dashoffset="100">'
         f'<animate attributeName="stroke-dashoffset" values="100;0;0" keyTimes="0;.8;1" dur="7s" calcMode="spline" keySplines=".35 0 .25 1;0 0 1 1" repeatCount="indefinite"/></path>']
    for i, ((kind, label), (back, front)) in enumerate(zip(steps, cols)):
        x, y = xs[i], ys[i]
        t0 = max(.02, .8 * i / 5 - .05)
        b.append(f'<path d="{scallop(x, y, 40)}" fill="{back}"><animateTransform attributeName="transform" type="rotate" from="0 {x} {y}" '
                 f'to="{40 if i % 2 else -40} {x} {y}" dur="6s" repeatCount="indefinite"/></path>')
        b.append(f'<circle cx="{x}" cy="{y}" r="44" fill="none" stroke="#fff" stroke-opacity="0" stroke-width="2"><animate attributeName="stroke-opacity" '
                 f'values="0;0;.75;0;0" keyTimes="0;{t0:.3f};{t0 + .05:.3f};{min(.97, t0 + .17):.3f};1" dur="7s" repeatCount="indefinite"/>'
                 f'<animate attributeName="r" values="40;40;44;60;60" keyTimes="0;{t0:.3f};{t0 + .05:.3f};{min(.97, t0 + .17):.3f};1" dur="7s" repeatCount="indefinite"/></circle>')
        b.append(f'<g transform="translate({x - 18} {y - 18}) scale(1.5)" color="{front}">{icon(kind)}</g>')
        d, _ = text(label, x, 186, 15, 600, 2, 'm')
        b.append(f'<path d="{d}" fill="#dfe3ff"/>')
    b.append(f'<circle r="7" fill="#fff"><animateMotion path="{p}" keyPoints="0;1;1" keyTimes="0;.8;1" calcMode="spline" keySplines=".35 0 .25 1;0 0 1 1" dur="7s" repeatCount="indefinite"/></circle>')
    save('journey.svg', W, H, ''.join(b), '<linearGradient id="bg" x1="0" x2="1" y2="1"><stop offset="0" stop-color="#12183a"/><stop offset=".6" stop-color="#1d1a3e"/><stop offset="1" stop-color="#2c1c38"/></linearGradient>')


def curves():
    W, H = 1200, 190
    b = ['<rect x="1" y="1" width="1198" height="188" rx="28" fill="url(#bg)" stroke="#6f7cc4" stroke-opacity=".5"/>']
    rows = [('LINEAR', '0 0 1 1', '#7a86a8'), ('NEON-GRID  OPEN', '.16 .84 .3 1', '#b7c4ff'), ('NEON-GRID  MOVE', '.2 0 0 1', '#e4bad9')]
    for i, (label, spline, colour) in enumerate(rows):
        y = 46 + i * 48
        d, _ = text(label, 40, y + 5, 14, 600, 1.2)
        b.append(f'<path d="{d}" fill="{colour}"/><rect x="290" y="{y - 1}" width="860" height="3" rx="1.500" fill="#fff" fill-opacity=".09"/>'
                 f'<rect x="290" y="{y - 13}" width="44" height="26" rx="13" fill="{colour}"><animate attributeName="x" values="290;1106;1106;290;290" keyTimes="0;.38;.5;.88;1" '
                 f'calcMode="spline" keySplines="{spline};0 0 1 1;{spline};0 0 1 1" dur="4.400s" repeatCount="indefinite"/></rect>')
    save('motion.svg', W, H, ''.join(b), '<linearGradient id="bg" x1="0" x2="1" y2="1"><stop offset="0" stop-color="#12183a"/><stop offset="1" stop-color="#2a1c3a"/></linearGradient>')


def colours():
    W, H = 1200, 330
    goals = [('glass', 'PANEL, MENUS, NOTIFICATIONS'), ('desktop', 'GTK APPS, ICONS, BORDERS'), ('gauge', 'WIDGETS'),
             ('grub', 'TERMINALS AND LAUNCHER'), ('browser', 'CHROME AND OPERA'), ('power', 'GRUB, BOOT, LOGIN')]
    cols = ['#b7c4ff', '#c6b9f2', '#e4bad9', '#9fd3e0', '#f0b9b0', '#8ea2ff']
    b = ['<rect x="1" y="1" width="1198" height="328" rx="28" fill="url(#bg)" stroke="#6f7cc4" stroke-opacity=".5"/>']
    # the wallpaper and the palette it becomes
    b.append('<clipPath id="c"><rect x="46" y="105" width="210" height="120" rx="20"/></clipPath><g clip-path="url(#c)"><rect x="46" y="105" width="210" height="120" fill="url(#wp)"/>'
             f'<path d="{wave(46, 256, 190, 8, 120, 0)}L256 225L46 225Z" fill="#12183a" fill-opacity=".55"/><path d="{wave(46, 256, 168, 9, 150, 2)}" fill="none" stroke="#fff" stroke-opacity=".35" stroke-width="2"/></g>'
             '<rect x="46" y="105" width="210" height="120" rx="20" fill="none" stroke="#fff" stroke-opacity=".4"/>')
    d, _ = text('ANY WALLPAPER', 151, 254, 13, 600, 1.4, 'm')
    b.append(f'<path d="{d}" fill="#dfe3ff"/>')
    b.append('<path d="M262 165C320 165 330 165 384 165" fill="none" stroke="#8ea2ff" stroke-opacity=".6" stroke-width="3"/>')
    b.append(f'<path d="{scallop(450, 165, 60)}" fill="#364479"><animateTransform attributeName="transform" type="rotate" from="0 450 165" to="40 450 165" dur="6s" repeatCount="indefinite"/></path>'
             f'<g transform="translate(420 135) scale(2.5)" color="#dfe3ff">{icon("palette")}</g>')
    d, _ = text('NEON-PALETTE', 450, 254, 13, 600, 1.4, 'm')
    b.append(f'<path d="{d}" fill="#dfe3ff"/>')
    b.append('<circle r="6" fill="#fff"><animateMotion path="M262 165C320 165 330 165 384 165" dur="3.600s" keyPoints="0;1;1" keyTimes="0;.3;1" calcMode="spline" keySplines=".3 0 .2 1;0 0 1 1" repeatCount="indefinite"/>'
             '<animate attributeName="opacity" values="1;1;0;0" keyTimes="0;.28;.32;1" dur="3.600s" repeatCount="indefinite"/></circle>')
    for i, ((kind, label), c) in enumerate(zip(goals, cols)):
        y = 45 + i * 48
        p = f'M512 165C600 165 620 {y} 712 {y}'
        b.append(f'<path d="{p}" fill="none" stroke="{c}" stroke-opacity=".38" stroke-width="2.500"/>')
        b.append(f'<circle r="5" fill="{c}" opacity="0"><animateMotion path="{p}" dur="3.600s" keyPoints="0;0;1;1" keyTimes="0;.32;.72;1" calcMode="spline" keySplines="0 0 1 1;.3 0 .2 1;0 0 1 1" repeatCount="indefinite"/>'
                 '<animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;.32;.34;.7;.76;1" dur="3.600s" repeatCount="indefinite"/></circle>')
        b.append(f'<rect x="712" y="{y - 19}" width="440" height="38" rx="19" fill="{c}" fill-opacity=".13" stroke="{c}" stroke-opacity=".55">'
                 '<animate attributeName="fill-opacity" values=".13;.13;.42;.13;.13" keyTimes="0;.7;.78;.95;1" dur="3.600s" repeatCount="indefinite"/></rect>')
        d, _ = text(label, 766, y + 5, 14, 600, 1.1)
        b.append(f'<g transform="translate(728 {y - 11}) scale(.92)" color="{c}">{icon(kind)}</g><path d="{d}" fill="#eef0ff"/>')
    save('colours.svg', W, H, ''.join(b), '<linearGradient id="bg" x1="0" x2="1" y2="1"><stop offset="0" stop-color="#12183a"/><stop offset=".6" stop-color="#1d1a3e"/><stop offset="1" stop-color="#2c1c38"/></linearGradient>'
         '<linearGradient id="wp" x1="0" x2="1" y2="1"><stop offset="0" stop-color="#4866c8"><animate attributeName="stop-color" values="#4866c8;#2f9c74;#d05a48;#4866c8" dur="10.800s" repeatCount="indefinite"/></stop>'
         '<stop offset="1" stop-color="#9a58bd"><animate attributeName="stop-color" values="#9a58bd;#8fa647;#e39a4c;#9a58bd" dur="10.800s" repeatCount="indefinite"/></stop></linearGradient>')


for n, t in (('look', 'ONE DESKTOP, ANY WALLPAPER'), ('journey', 'FROM POWER-ON TO DESKTOP'), ('alive', 'IT MOVES'), ('widgets', 'WIDGETS THAT ANSWER'),
             ('features', 'WHAT YOU GET'), ('install', 'INSTALL'), ('agents', 'LET AN AI AGENT DO IT'), ('victus', 'HP VICTUS AND OMEN'),
             ('safety', 'GOING BACK'), ('more', 'GOOD TO KNOW')):
    header(n, t)
A, B = ('#364479', '#dfe3ff'), ('#5c3d54', '#ffd8f3')
for i, k in enumerate(('palette', 'glass', 'motion', 'gauge', 'bell', 'chart', 'shield', 'scroll', 'genie', 'browser', 'fan', 'robot')):
    badge(k, k, *(A if i % 2 == 0 else B))
pill('b-install', 'INSTALL', True, 'power')
pill('b-agents', 'AI AGENT GUIDE', False, 'robot')
pill('b-tour', 'TOUR', False, 'boot')
pill('b-back', 'GOING BACK', False, 'shield')
for n, t in (('t-cinnamon', 'CINNAMON 6.6'), ('t-x11', 'X11'), ('t-gpl', 'GPL-3.0'), ('t-you', 'MATERIAL YOU')):
    pill(n, t)
journey()
curves()
colours()
