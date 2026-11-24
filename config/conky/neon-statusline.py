#!/usr/bin/env python3
"""Neon-Grid status line for Claude Code.

Reads the status JSON Claude Code passes on stdin and prints two lines:

  model / effort // folder // git branch // context bar // session cost
  5-hour and weekly plan usage bars with reset countdowns // lines changed

Truecolor ANSI only; pure standard library; never raises.
"""
import json
import os
import subprocess
import sys
import time

CYAN, MAGENTA, GREEN = (0, 240, 255), (255, 43, 214), (41, 255, 163)
YELLOW, RED = (249, 248, 113), (255, 59, 107)
TEXT, DIM, FAINT = (214, 246, 255), (122, 134, 168), (59, 66, 102)
RESET = "\033[0m"

# wallpaper colours (neon-palette); on any problem the colours above are used
try:
    with open(os.path.expanduser("~/.config/neon-grid/palette-state.json")) as _f:
        _p = {k: tuple(int(v[i:i + 2], 16) for i in (1, 3, 5)) for k, v in (json.load(_f)["palette"] or {}).items()}
    CYAN, MAGENTA, GREEN = _p.get("primary", CYAN), _p.get("tertiary", MAGENTA), _p.get("green", GREEN)
    YELLOW, TEXT, DIM, FAINT = _p.get("yellow", YELLOW), _p.get("text", TEXT), _p.get("dim", DIM), _p.get("line", FAINT)
except Exception:
    pass


def fg(c, s, bold=False):
    return "\033[%s38;2;%d;%d;%dm%s%s" % ("1;" if bold else "", c[0], c[1], c[2], s, RESET)


def level(pct):
    return RED if pct >= 90 else YELLOW if pct >= 70 else CYAN


def bar(pct, width=10, colour=None):
    pct = max(0.0, min(100.0, pct))
    n = int(round(pct / 100.0 * width))
    if pct > 0 and n == 0:
        n = 1
    return fg(colour or level(pct), "━" * n) + fg(FAINT, "━" * (width - n))


def countdown(reset):
    s = int(reset - time.time())
    if s <= 0:
        return "reset"
    d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return "%dd %dh" % (d, h) if d else "%dh %02dm" % (h, m)


def branch(cwd):
    try:
        out = subprocess.run(["git", "-C", cwd, "branch", "--show-current"], capture_output=True,
                             text=True, timeout=1).stdout.strip()
        return out
    except Exception:
        return ""


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    sep = fg(MAGENTA, " // ")

    model = (d.get("model") or {}).get("display_name") or "Claude"
    effort = (d.get("effort") or {}).get("level")
    cwd = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or os.getcwd()
    home = os.path.expanduser("~")
    shown = "~" + cwd[len(home):] if cwd == home or cwd.startswith(home + "/") else cwd
    parts = shown.split("/")
    if len(parts) > 4:
        shown = "/".join([parts[0], "…"] + parts[-2:])

    head = fg(CYAN, "◢ ", True) + fg(CYAN, model.upper(), True)
    if effort:
        head += fg(DIM, " · " + effort)
    if d.get("fast_mode"):
        head += fg(YELLOW, " · fast")
    line1 = [head, fg(TEXT, shown)]
    b = branch(cwd)
    if b:
        line1.append(fg(GREEN, "⎇ " + b))
    ctx = (d.get("context_window") or {}).get("used_percentage")
    if ctx is not None:
        line1.append(fg(DIM, "ctx ") + bar(float(ctx), 10) + fg(TEXT, " %d%%" % ctx))
    cost = (d.get("cost") or {}).get("total_cost_usd")
    if cost:
        line1.append(fg(GREEN, "$%.2f" % cost))

    line2 = []
    rl = d.get("rate_limits") or {}
    for key, label in (("five_hour", "5H"), ("seven_day", "7D")):
        r = rl.get(key) or {}
        if "used_percentage" not in r:
            continue
        pct = float(r["used_percentage"])
        seg = fg(CYAN, label, True) + " " + bar(pct, 12) + fg(level(pct), " %d%%" % pct, True)
        if r.get("resets_at"):
            seg += fg(DIM, "  resets " + countdown(r["resets_at"]))
        line2.append(seg)
    c = d.get("cost") or {}
    added, removed = c.get("total_lines_added") or 0, c.get("total_lines_removed") or 0
    if added or removed:
        line2.append(fg(GREEN, "+%d" % added) + " " + fg(RED, "-%d" % removed))

    print(sep.join(line1))
    if line2:
        print(fg(MAGENTA, "◥ ", True) + sep.join(line2))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Claude")
