#!/usr/bin/env python3
"""Neon-Grid telemetry collector.

Samples CPU/RAM/disk per app (named after its service or project where possible), GPU,
temperatures, fans, network, storage, power and Claude usage every INTERVAL seconds, keeps
a short history, and writes one tab-separated state file that the Conky panel
(neon-panel.lua) draws. neon-apps.json next to it lists each app's processes for neon-act.

Fan, temperature, GPU and keyboard readings come from the victus-control backend
socket; if it is unavailable, hwmon / nvidia-smi are used instead.
"""
import glob
import json
import os
import re
import socket
import struct
import subprocess
import time
import zlib
from collections import deque

import psutil

INTERVAL = 2.0
HISTORY = 150            # samples kept per trace (5 minutes at 2 s)
TOP_N = 6
APPS_N = 14               # rows offered to the panel's app table
SPARK = 40               # samples kept per app
SOCK = "/run/victus-control/victus_backend.sock"
OUT = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()),
                   "neon-deck.txt")
APPS_OUT = os.path.join(os.path.dirname(OUT), "neon-apps.json")
CACHE = os.path.expanduser("~/.cache/neon-grid")
UID = os.getuid()
# programs that run other things: the name says little, so the service or project is shown
HOSTS = re.compile(r"^(python[\d.]*|node|nodejs|MainThread|workerd|bash|sh|dash|java|ruby|perl|php|deno|bun|"
                   r"cloudflared|gunicorn|uvicorn|npm|npx.*|next-server.*|esbuild|chrome-headless.*)$")
# ending these would take the desktop or a terminal session down with them
PROTECTED = re.compile(r"^(Xorg|Xwayland|cinnamon.*|csd-.*|nemo-desktop|systemd.*|\(sd-pam\)|dbus.*|gdm.*|"
                       r"pipewire.*|wireplumber|gnome-keyring.*|gnome-session.*|polkit.*|ibus.*|conky|neon-.*|"
                       r"claude.*|kitty|gnome-terminal.*|xdg-.*|at-spi.*|gvfs.*|dconf.*|bash|sh)$")


def backend(cmd):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2.0)
            s.connect(SOCK)
            p = cmd.encode()
            s.sendall(struct.pack("<I", len(p)) + p)
            hdr = b""
            while len(hdr) < 4:
                c = s.recv(4 - len(hdr))
                if not c:
                    return None
                hdr += c
            n = struct.unpack("<I", hdr)[0]
            if n == 0 or n > 4096:
                return None
            buf = b""
            while len(buf) < n:
                c = s.recv(n - len(buf))
                if not c:
                    return None
                buf += c
            r = buf.decode(errors="replace").strip()
            return None if r.startswith("ERROR") else r
    except (OSError, struct.error):
        return None


def num(s, default=None):
    try:
        return float(s)
    except (TypeError, ValueError):
        return default


def hwmon(name, fname):
    for d in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            if open(d + "/name").read().strip() == name:
                return float(open("%s/%s" % (d, fname)).read())
        except (OSError, ValueError):
            pass
    return None


def nvidia_query():
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=4).stdout
        return [float(x) for x in out.strip().split(",")]
    except Exception:
        return None


PROC_ROW = re.compile(r"^\|\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+(\S.*?)\s+(\d+)MiB\s+\|")


def nvidia_apps():
    """Per-process VRAM from the nvidia-smi process table: [(name, MiB)]."""
    try:
        out = subprocess.run(["nvidia-smi"], capture_output=True, text=True, timeout=4).stdout
    except Exception:
        return []
    agg = {}
    for line in out.splitlines():
        m = PROC_ROW.match(line)
        if m:
            name = os.path.basename(m.group(2).split()[0])
            agg[name] = agg.get(name, 0) + int(m.group(3))
    return sorted(agg.items(), key=lambda kv: -kv[1])[:4]


CLAUDE = os.path.join(os.path.dirname(OUT), "claude-status.json")


def claude_row():
    """Plan usage limits saved by the Claude Code status-line tap, or None."""
    try:
        import json
        age = time.time() - os.path.getmtime(CLAUDE)
        d = json.load(open(CLAUDE))
        rl = d.get("rate_limits") or {}
        fh, wk = rl.get("five_hour") or {}, rl.get("seven_day") or {}
        return [float(fh.get("used_percentage", -1)), int(fh.get("resets_at", 0)),
                float(wk.get("used_percentage", -1)), int(wk.get("resets_at", 0)),
                (d.get("model") or {}).get("display_name", "?"),
                float((d.get("context_window") or {}).get("used_percentage") or 0),
                float((d.get("cost") or {}).get("total_cost_usd") or 0),
                int(time.time() - age)]
    except Exception:
        return None


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def app_name(pid, comm, uid):
    """(label, user service or '') of a process."""
    unit = ""
    for line in read("/proc/%d/cgroup" % pid).splitlines():
        leaf = line.rsplit("/", 1)[-1]
        if leaf.endswith(".service") and not leaf.startswith(("user@", "session", "app-", "dbus", "gnome", "org.")):
            unit = leaf
    if not HOSTS.match(comm):
        return comm, ""
    user_unit = unit if "user@%d" % uid in read("/proc/%d/cgroup" % pid) else "system"
    if unit:
        return unit[:-8], user_unit
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            args = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
    except OSError:
        args = []
    text = " ".join(args[:6])
    m = re.search(r"/Documents/GitHub/([^/ ]+)", text) or re.search(r"/mcp-servers/([^/ ]+)", text)
    if m:
        return m.group(1), ""
    for i, a in enumerate(args[1:], 1):
        if a == "-m" and i + 1 < len(args):
            return args[i + 1].split(".")[0], ""
        if not a.startswith("-") and ("/" in a or a.endswith((".py", ".js", ".mjs"))):
            base = os.path.basename(a.rstrip("/"))
            return base or comm, ""
    return comm, ""


class Apps:
    """CPU, memory and disk activity per app."""

    def __init__(self):
        self.prev = {}          # pid -> (start, cpu seconds, bytes read, bytes written)
        self.disk = {}          # label -> [bytes read, bytes written] since this collector started
        self.names = {}         # pid -> (start, label, unit)
        self.spark = {}         # label -> deque of cpu %

    def sample(self, dt, vram):
        cur, names, app = {}, {}, {}
        for p in psutil.process_iter(["pid", "name", "cpu_times", "memory_info", "create_time",
                                      "uids", "num_threads"]):
            i = p.info
            ct, mi, pid, start = i.get("cpu_times"), i.get("memory_info"), i["pid"], i.get("create_time")
            if ct is None or mi is None or mi.rss == 0:
                continue                      # gone, or a kernel thread
            uid = i["uids"].real if i.get("uids") else -1
            comm = i["name"] or "?"
            known = self.names.get(pid)
            if known and known[0] == start:
                label, unit = known[1], known[2]
            else:
                label, unit = app_name(pid, comm, uid)
            names[pid] = (start, label, unit)
            rd = wr = 0
            if uid == UID:
                for line in read("/proc/%d/io" % pid).splitlines():
                    if line.startswith("read_bytes"):
                        rd = int(line.split(":")[1])
                    elif line.startswith("write_bytes"):
                        wr = int(line.split(":")[1])
            t = ct.user + ct.system
            cur[pid] = (start, t, rd, wr)
            a = app.setdefault(label, {"cpu": 0.0, "ram": 0.0, "io": 0.0, "rd": 0.0, "wr": 0.0, "down": 0.0,
                                       "up": 0.0, "conns": 0, "n": 0, "thr": 0, "vram": 0.0,
                                       "start": start, "unit": unit, "mine": True, "pids": [], "comms": set()})
            old = self.prev.get(pid)
            if old and old[0] == start and dt > 0:
                a["cpu"] += max(0.0, t - old[1]) / dt * 100.0
                dr, dw = max(0, rd - old[2]), max(0, wr - old[3])
                a["rd"] += dr / dt / 1024.0
                a["wr"] += dw / dt / 1024.0
                a["io"] = a["rd"] + a["wr"]
                if dr or dw:
                    tot = self.disk.setdefault(label, [0, 0])
                    tot[0] += dr
                    tot[1] += dw
            a["ram"] += max(0, mi.rss - getattr(mi, "shared", 0)) / 1048576.0
            a["n"] += 1
            a["thr"] += i.get("num_threads") or 1
            a["start"] = min(a["start"], start)
            a["mine"] = a["mine"] and uid == UID
            a["pids"].append([pid, start])
            a["comms"].add(comm)
        self.prev, self.names = cur, names
        for label, v in vram:
            if label in app:
                app[label]["vram"] = float(v)
        for label, a in app.items():
            a["id"] = "%08x" % zlib.crc32(label.encode())
            a["safe"] = a["mine"] and not any(PROTECTED.match(c) for c in a["comms"] | {label})
            self.spark.setdefault(label, deque(maxlen=SPARK)).append(a["cpu"])
        for label in [k for k in self.spark if k not in app]:
            del self.spark[label]
        return app


class Net:
    """Network bytes per app, from the kernel's own counters of every TCP connection (ss).
    Other traffic (UDP: QUIC, calls, DNS) has no such counters and stays unassigned."""
    LOCAL = ("127.", "[::1]", "[::ffff:127.")

    def __init__(self):
        self.prev = None        # (local, remote) -> (received, sent)
        self.total = {}         # label -> [received, sent] since this collector started

    def sample(self, dt, names):
        try:
            out = subprocess.run(["ss", "-tinpHO"], capture_output=True, text=True, timeout=3).stdout
        except Exception:
            return {}
        cur, app = {}, {}
        for line in out.splitlines():
            f = line.split()
            if len(f) < 5 or f[4].startswith(self.LOCAL):
                continue
            rx, tx = re.search(r"bytes_received:(\d+)", line), re.search(r"bytes_acked:(\d+)", line)
            rx, tx = int(rx.group(1)) if rx else 0, int(tx.group(1)) if tx else 0
            pid = re.search(r"pid=(\d+)", line)
            label = names.get(int(pid.group(1)), (0, "?", ""))[1] if pid else "other users"
            key = (f[3], f[4])
            cur[key] = (rx, tx)
            a = app.setdefault(label, {"down": 0.0, "up": 0.0, "conns": 0})
            if f[0] == "ESTAB":
                a["conns"] += 1
            if self.prev is None:
                continue
            old = self.prev.get(key, (0, 0))
            dr, dt_ = rx - old[0], tx - old[1]
            if dr < 0 or dt_ < 0:          # the same addresses, a new connection
                dr, dt_ = rx, tx
            if dr or dt_:
                a["down"] += dr / max(dt, 0.1) / 1024.0
                a["up"] += dt_ / max(dt, 0.1) / 1024.0
                tot = self.total.setdefault(label, [0, 0])
                tot[0] += dr
                tot[1] += dt_
        self.prev = cur
        return app


def wifi():
    """(ssid, signal %, link) of the Wi-Fi connection in use."""
    try:
        out = subprocess.run(["nmcli", "-t", "-f", "ACTIVE,SIGNAL,RATE,SSID", "dev", "wifi", "list",
                              "--rescan", "no"], capture_output=True, text=True, timeout=4).stdout
        for line in out.splitlines():
            p = line.split(":", 3)
            if p[0] == "yes":
                return p[3].replace("\\:", ":"), num(p[1], 0.0), p[2]
    except Exception:
        pass
    return "", 0.0, ""


def local_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))          # no packet is sent: only picks the interface
            return s.getsockname()[0]
    except OSError:
        return ""


def connections(names):
    agg = {}
    try:
        for c in psutil.net_connections(kind="tcp"):
            if c.status == psutil.CONN_ESTABLISHED and c.raddr and c.pid and \
                    not c.raddr.ip.startswith(("127.", "::1", "::ffff:127.")):
                n = names.get(c.pid, (0, "?", ""))[1]
                agg[n] = agg.get(n, 0) + 1
    except Exception:
        pass
    return sorted(agg.items(), key=lambda kv: -kv[1])[:6]


def sensors():
    out = []
    label = {"k10temp": "CPU", "amdgpu": "Radeon", "spd5118": "Memory", "acpitz": "Board"}
    drives = 0
    for d in sorted(glob.glob("/sys/class/hwmon/hwmon*"), key=lambda x: int(x.rsplit("hwmon", 1)[1])):
        name = read(d + "/name")
        v = num(read(d + "/temp1_input"))
        if v is None or v <= 0 or v > 130000:
            continue
        if name == "nvme":
            drives += 1
            out.append(("SSD %d" % drives, v / 1000.0))
        elif name in label:
            out.append((label[name], v / 1000.0))
    return out


def nvidia_extra():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=power.draw,clocks.gr,clocks.max.gr,pstate",
                              "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=4).stdout
        p = [x.strip() for x in out.strip().split(",")]
        return [num(p[0], 0.0), num(p[1], 0.0), num(p[2], 0.0), p[3]]
    except Exception:
        return None


def radeon():
    for d in glob.glob("/sys/class/drm/card*/device"):
        b = num(read(d + "/gpu_busy_percent"))
        if b is not None:
            return [b, num(read(d + "/mem_info_vram_used"), 0) / 1048576.0,
                    num(read(d + "/mem_info_vram_total"), 1) / 1048576.0]
    return [0.0, 0.0, 1.0]


def battery():
    for d in glob.glob("/sys/class/power_supply/BAT*"):
        full, design = num(read(d + "/energy_full")), num(read(d + "/energy_full_design"))
        return [num(read(d + "/capacity"), 0.0), read(d + "/status") or "?",
                num(read(d + "/power_now"), 0.0) / 1e6, 100.0 * full / design if full and design else 0.0,
                num(read(d + "/cycle_count"), 0.0), num(read(d + "/energy_now"), 0.0) / 1e6,
                (full or 0.0) / 1e6]
    return None


class Log:
    """A small file of (time, values...) kept for `days` days, one row per `every` seconds."""

    def __init__(self, name, every, days):
        self.path, self.every, self.keep, self.rows = os.path.join(CACHE, name), every, days * 86400, []
        for line in read(self.path).splitlines():
            try:
                self.rows.append([float(x) for x in line.split()])
            except ValueError:
                pass

    def add(self, *vals):
        now = time.time()
        if self.rows and now - self.rows[-1][0] < self.every:
            return
        self.rows = [x for x in self.rows if now - x[0] < self.keep] + [[now] + [float(v) for v in vals]]
        try:
            os.makedirs(CACHE, exist_ok=True)
            with open(self.path + ".tmp", "w") as f:
                f.write("".join(" ".join("%.2f" % v for v in x) + "\n" for x in self.rows))
            os.replace(self.path + ".tmp", self.path)
        except OSError:
            pass

    def ago(self, seconds):
        """The row nearest to `seconds` ago, if the log reaches back at least half that far."""
        t = time.time() - seconds
        if not self.rows or self.rows[0][0] > t + seconds / 2:
            return None
        return min(self.rows, key=lambda x: abs(x[0] - t))


def net_totals():
    """(rx, tx, name) bytes summed over the physical interfaces that are up."""
    rx = tx = 0
    names = []
    try:
        stats = psutil.net_if_stats()
        for n, v in psutil.net_io_counters(pernic=True).items():
            if n.startswith(("wl", "en", "eth")) and n in stats and stats[n].isup:
                rx += v.bytes_recv
                tx += v.bytes_sent
                names.append(n)
    except Exception:
        pass
    return rx, tx, "+".join(names) or "offline"


def main():
    hist = {k: deque(maxlen=HISTORY) for k in
            ("cpu", "mem", "gpu", "vram", "ctemp", "gtemp", "fan1", "fan2", "down", "up",
             "rgpu", "read", "write")}
    who_cpu, who_mem = deque(maxlen=HISTORY), deque(maxlen=HISTORY)
    net_prev = net_totals()
    last = time.monotonic()
    table = Apps()
    nets = Net()
    disk_log, claude_log = Log("disk.log", 1800, 8), Log("claude.log", 300, 2)
    disk_prev = psutil.disk_io_counters()
    net, conns, extra, profile = ("", 0.0, ""), [], None, ""
    psutil.cpu_percent(None, percpu=True)
    psutil.cpu_percent(None)
    fmax = (num(backend("GET_FAN_MAX_SPEED 1"), 5800), num(backend("GET_FAN_MAX_SPEED 2"), 6100))
    apps, tick = [], 0
    keep = {"ctemp": 0.0, "gtemp": 0.0, "fan1": 0.0, "fan2": 0.0, "gpu": 0.0,
            "vused": 0.0, "vtot": 1.0}

    while True:
        time.sleep(INTERVAL)
        now = time.monotonic()
        dt, last = now - last, now
        app = table.sample(dt, apps)
        by_net = nets.sample(dt, table.names)
        for k, v in by_net.items():
            if k in app:
                app[k].update(v)
        top_cpu = sorted(((k, v["cpu"]) for k, v in app.items()), key=lambda kv: -kv[1])[:TOP_N]
        top_mem = sorted(((k, v["ram"]) for k, v in app.items()), key=lambda kv: -kv[1])[:TOP_N]
        cores = psutil.cpu_percent(None, percpu=True)
        cpu = psutil.cpu_percent(None)
        vm = psutil.virtual_memory()

        ctemp = num(backend("GET_CPU_TEMP"))
        gtemp = num(backend("GET_GPU_TEMP"))
        gpu = num(backend("GET_GPU_USAGE"))
        vram = (backend("GET_GPU_VRAM") or "").split()
        fan1 = num(backend("GET_FAN_SPEED 1"))
        fan2 = num(backend("GET_FAN_SPEED 2"))
        mode = backend("GET_FAN_MODE") or "N/A"
        kbd = backend("GET_KBD_EFFECT") or "N/A"

        if ctemp is None:
            v = hwmon("k10temp", "temp1_input")
            ctemp = v / 1000.0 if v else None
        if fan1 is None:
            fan1 = hwmon("hp", "fan1_input")
        if fan2 is None:
            fan2 = hwmon("hp", "fan2_input")
        vused, vtot = (num(vram[0]), num(vram[1])) if len(vram) == 2 else (None, None)
        if gpu is None or vused is None or gtemp is None:
            q = nvidia_query()
            if q:
                gpu = q[0] if gpu is None else gpu
                vused, vtot = (q[1], q[2]) if vused is None else (vused, vtot)
                gtemp = q[3] if gtemp is None else gtemp

        for k, v in (("ctemp", ctemp), ("gtemp", gtemp), ("fan1", fan1), ("fan2", fan2),
                     ("gpu", gpu), ("vused", vused), ("vtot", vtot)):
            if v is not None:
                keep[k] = v

        if tick % 3 == 0:
            apps = nvidia_apps()
            extra = nvidia_extra() or extra
            conns = connections(table.names)
        if tick % 15 == 0:
            net = wifi()
            profile = read("/sys/firmware/acpi/platform_profile")
            try:
                profile = subprocess.run(["powerprofilesctl", "get"], capture_output=True, text=True,
                                         timeout=4).stdout.strip() or profile
            except Exception:
                pass
        tick += 1

        net_now = net_totals()
        down = max(0.0, net_now[0] - net_prev[0]) / max(dt, 0.1) / 1024.0
        up = max(0.0, net_now[1] - net_prev[1]) / max(dt, 0.1) / 1024.0
        net_prev = net_now
        try:
            du = psutil.disk_usage("/")
            disk = [float(du.percent), du.free / 1073741824.0, du.total / 1073741824.0]
        except Exception:
            disk = [0.0, 0.0, 0.0]
        disk_now = psutil.disk_io_counters()
        rd = max(0, disk_now.read_bytes - disk_prev.read_bytes) / max(dt, 0.1) / 1024.0
        wr = max(0, disk_now.write_bytes - disk_prev.write_bytes) / max(dt, 0.1) / 1024.0
        disk_prev = disk_now
        if disk[1] > 0:
            disk_log.add(disk[1])
        day = disk_log.ago(86400)
        rad = radeon()
        swap = psutil.swap_memory()
        freq = psutil.cpu_freq()
        load = os.getloadavg()
        bat = battery()
        hist["rgpu"].append(rad[0])
        hist["read"].append(rd)
        hist["write"].append(wr)
        who_cpu.append(top_cpu[0] if top_cpu else ("-", 0.0))
        who_mem.append(top_mem[0] if top_mem else ("-", 0.0))
        hist["down"].append(down)
        hist["up"].append(up)

        hist["cpu"].append(cpu)
        hist["mem"].append(vm.percent)
        hist["gpu"].append(keep["gpu"])
        hist["vram"].append(100.0 * keep["vused"] / max(1.0, keep["vtot"]))
        hist["ctemp"].append(keep["ctemp"])
        hist["gtemp"].append(keep["gtemp"])
        hist["fan1"].append(keep["fan1"])
        hist["fan2"].append(keep["fan2"])

        def row(key, *vals):
            return "\t".join([key] + [("%.1f" % v) if isinstance(v, float) else str(v)
                                      for v in vals])

        def pairs(key, items):
            flat = []
            for n, v in items:
                flat += [n.replace("\t", " ")[:24], float(v)]
            return row(key, *flat)

        lines = [
            row("stamp", int(time.time())),
            row("cpu", float(cpu), psutil.cpu_count()),
            row("mem", float(vm.percent), vm.used / 1073741824.0, vm.total / 1073741824.0),
            row("gpu", keep["gpu"], keep["vused"], keep["vtot"]),
            row("temp", keep["ctemp"], keep["gtemp"]),
            row("fan", keep["fan1"], keep["fan2"], float(fmax[0]), float(fmax[1]), mode),
            row("kbd", kbd),
            row("net", down, up, net_now[2]),
            row("disk", *disk),
            pairs("topcpu", top_cpu),
            pairs("topmem", top_mem),
            pairs("topgpu", apps),
            row("cores", *[float(x) for x in cores]),
            row("load", *[float(x) for x in load], (freq.current if freq else 0.0) / 1000.0,
                (freq.max if freq else 0.0) / 1000.0, len(table.names),
                sum(a["thr"] for a in app.values())),
            row("memx", *[x / 1073741824.0 for x in (vm.total - vm.available, vm.cached + vm.buffers,
                                                     vm.available, swap.used, swap.total)]),
            row("gpux", *(extra or [0.0, 0.0, 0.0, "?"]), *rad),
            pairs("sens", sensors()),
            row("netx", net[0], net[1], net[2], local_ip(), net_now[0] / 1073741824.0,
                net_now[1] / 1073741824.0),
            pairs("conn", conns),
            row("diskx", rd, wr, (disk[1] - day[1]) if day else "",
                ((time.time() - day[0]) / 3600.0) if day else ""),
            row("prof", profile),
            row("who_cpu", *["%s|%.0f" % (n[:22].replace("|", " "), v) for n, v in who_cpu]),
            row("who_mem", *["%s|%.0f" % (n[:22].replace("|", " "), v) for n, v in who_mem]),
        ] + [row("h_" + k, *[float(x) for x in v]) for k, v in hist.items()]

        if bat:
            lines.append(row("bat", *bat))
        # the app table: the busiest by CPU, memory and disk
        pick = {}
        for key, n in (("cpu", 14), ("ram", 14), ("io", 5)):
            for k, a in sorted(app.items(), key=lambda kv: -kv[1][key])[:n]:
                pick[k] = a
        rows = sorted(pick.items(), key=lambda kv: -(kv[1]["cpu"] + kv[1]["ram"] / 100.0))[:APPS_N + 6]
        for key in ("io", "down", "up"):       # whoever is busy on the disk or the network is always listed
            for k, a in sorted(app.items(), key=lambda kv: -kv[1][key])[:3]:
                if a[key] >= 1 and all(k != x[0] for x in rows):
                    rows.append((k, a))
        for k, a in rows:
            lines.append(row("app", a["id"], k.replace("\t", " ")[:34], a["cpu"], a["ram"], a["io"], a["n"],
                             a["thr"], a["vram"], int(time.time() - a["start"]),
                             "restart" if a["unit"] not in ("", "system") and a["mine"] and a["safe"]
                             else "end" if a["safe"] and not a["unit"] else "-",
                             ",".join("%.0f" % v for v in table.spark.get(k, ())),
                             a["rd"], a["wr"], a["down"], a["up"], a["conns"]))

        def ident(k):
            return "%08x" % zlib.crc32(k.encode())
        # the same, seen from the network and from the disk: rate now, and the sum since this collector started
        MB = 1048576.0
        seen = []
        for k in set(by_net) | set(nets.total):
            v, t = by_net.get(k, {"down": 0.0, "up": 0.0, "conns": 0}), nets.total.get(k, [0, 0])
            if v["down"] + v["up"] >= 0.05 or t[0] + t[1] > 0 or v["conns"]:
                seen.append((k, v["down"], v["up"], v["conns"], t[0] / MB, t[1] / MB))
        seen.sort(key=lambda x: (-(x[1] + x[2]), -(x[4] + x[5]), -x[3]))
        for x in seen[:10]:
            lines.append(row("napp", ident(x[0]), x[0].replace("\t", " ")[:34], x[1], x[2], x[3], x[4], x[5]))
        lines.append(row("netu", max(0.0, down - sum(x[1] for x in seen)), max(0.0, up - sum(x[2] for x in seen))))
        seen = []
        for k in set(table.disk) | {k for k, a in app.items() if a["io"] >= 0.05}:
            a, t = app.get(k, {"rd": 0.0, "wr": 0.0}), table.disk.get(k, [0, 0])
            seen.append((k, a["rd"], a["wr"], t[0] / MB, t[1] / MB))
        seen.sort(key=lambda x: (-(x[1] + x[2]), -(x[3] + x[4])))
        for x in seen[:10]:
            lines.append(row("dapp", ident(x[0]), x[0].replace("\t", " ")[:34], *x[1:]))
        try:
            with open(APPS_OUT + ".tmp", "w") as f:
                json.dump({a["id"]: {"name": k, "unit": a["unit"], "safe": a["safe"], "pids": a["pids"]}
                           for k, a in rows}, f)
            os.replace(APPS_OUT + ".tmp", APPS_OUT)
        except OSError:
            pass

        c = claude_row()
        if c:
            lines.append(row("claude", *c))
            if c[0] >= 0 and time.time() - c[7] < 600:
                claude_log.add(c[0], c[2])
            span = [x for x in claude_log.rows if time.time() - x[0] < 86400][-288:]
            if len(span) > 1:
                lines.append(row("cl_t", *[int(x[0]) for x in span]))
                lines.append(row("cl_5", *[x[1] for x in span]))
                lines.append(row("cl_w", *[x[2] for x in span]))

        tmp = OUT + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, OUT)


if __name__ == "__main__":
    main()
