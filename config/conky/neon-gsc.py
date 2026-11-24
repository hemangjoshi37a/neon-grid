#!/usr/bin/env python3
"""Neon-Grid Search Console collector.

Pulls the last 28, 60, 90 and 365 days (one file each) of Google Search Console data for one domain
property, splits it by subdomain, and writes a tab-separated file that the
Conky widget (neon-gsc.lua) draws. Besides the totals it stores, per site and per top
query, daily series, pages, queries, countries and devices for the hover details. Read-only; uses the service-account key of
a service account. Run it with a Python that has google-api-python-client:

    $NEON_GSC_PYTHON neon-gsc.py
"""
import collections
import datetime
import os
import sys
import time
import urllib.parse

from google.oauth2 import service_account
from googleapiclient.discovery import build



def settings():
    """Private settings from ~/.config/neon-grid/.env (see .env.example); the environment wins."""
    out = {}
    try:
        with open(os.path.expanduser("~/.config/neon-grid/.env")) as fh:
            for line in fh:
                k, sep, v = line.strip().partition("=")
                if sep and not k.startswith("#"):
                    out[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    out.update({k: v for k, v in os.environ.items() if k.startswith("NEON_")})
    return out


ENV = settings()
DOMAIN = ENV.get("NEON_GSC_DOMAIN", "")
PROPERTY = "sc-domain:" + DOMAIN
KEY = os.path.expanduser(ENV.get("NEON_GSC_KEY", ""))
OUT = os.path.expanduser("~/.cache/neon-grid/gsc-%d.txt")
RANGES = (28, 60, 90, 365)
LAG = 3          # fallback only: days to step back if the latest published day cannot be found
# Sites that must always be listed, even with no search traffic yet.
ALWAYS = [x.strip() for x in ENV.get("NEON_GSC_ALWAYS", "").split(",") if x.strip()]

COUNTRY = {"ind": "India", "usa": "USA", "gbr": "UK", "deu": "Germany", "fra": "France",
           "can": "Canada", "aus": "Australia", "bra": "Brazil", "rus": "Russia", "chn": "China",
           "jpn": "Japan", "kor": "S. Korea", "ita": "Italy", "esp": "Spain", "nld": "Netherlands",
           "pol": "Poland", "tur": "Turkey", "idn": "Indonesia", "pak": "Pakistan",
           "bgd": "Bangladesh", "vnm": "Vietnam", "phl": "Philippines", "mex": "Mexico",
           "twn": "Taiwan", "hkg": "Hong Kong", "sgp": "Singapore", "mys": "Malaysia",
           "tha": "Thailand", "ukr": "Ukraine", "che": "Switzerland", "swe": "Sweden",
           "are": "UAE", "sau": "Saudi Arabia", "zaf": "S. Africa", "egy": "Egypt",
           "arg": "Argentina", "irn": "Iran", "isr": "Israel", "nga": "Nigeria", "bel": "Belgium",
           "aut": "Austria", "cze": "Czechia", "rou": "Romania", "prt": "Portugal",
           "lka": "Sri Lanka", "arm": "Armenia", "ken": "Kenya", "mar": "Morocco", "dza": "Algeria",
           "col": "Colombia", "chl": "Chile", "per": "Peru", "grc": "Greece", "hun": "Hungary",
           "dnk": "Denmark", "fin": "Finland", "nor": "Norway", "irl": "Ireland", "nzl": "N. Zealand",
           "srb": "Serbia", "bgr": "Bulgaria", "kaz": "Kazakhstan", "irq": "Iraq", "npl": "Nepal", "zzz": "Unknown"}


def query(svc, body):
    rows, start = [], 0
    while True:
        b = dict(body, rowLimit=25000, startRow=start)
        got = svc.searchanalytics().query(siteUrl=PROPERTY, body=b).execute().get("rows", [])
        rows += got
        if len(got) < 25000:
            return rows
        start += 25000


def main():
    if not DOMAIN or not os.path.isfile(KEY):
        sys.exit("set NEON_GSC_DOMAIN and NEON_GSC_KEY in ~/.config/neon-grid/.env")
    creds = service_account.Credentials.from_service_account_file(
        KEY, scopes=["https://www.googleapis.com/auth/webmasters.readonly"])
    svc = build("searchconsole", "v1", credentials=creds, cache_discovery=False)
    failed = None

    # Google publishes each day's figures a few days late and the delay varies, so
    # end the window on the latest day that actually has data instead of guessing.
    today = datetime.date.today()
    probe = query(svc, {"startDate": str(today - datetime.timedelta(days=10)),
                        "endDate": str(today), "dimensions": ["date"]})
    published = [r["keys"][0] for r in probe if r.get("impressions", 0) > 0]
    if published:
        end = datetime.date.fromisoformat(max(published))
    else:
        end = today - datetime.timedelta(days=LAG)
    # the oldest day Google still has: without a full previous period there is nothing to compare
    old = query(svc, {"startDate": str(today - datetime.timedelta(days=800)), "endDate": str(end),
                      "dimensions": ["date"]})
    oldest = min((r["keys"][0] for r in old), default=str(end))
    for n in RANGES:
        try:
            collect(svc, end, n, oldest)
        except Exception as e:          # one range failing must not cost the others
            failed = e
            print("%d days: %r" % (n, e), file=sys.stderr)
    if failed:
        sys.exit(1)


def collect(svc, end, DAYS, oldest):
    start = end - datetime.timedelta(days=DAYS - 1)
    pend = start - datetime.timedelta(days=1)
    pstart = pend - datetime.timedelta(days=DAYS - 1)
    days = [str(start + datetime.timedelta(days=i)) for i in range(DAYS)]
    has_prev = str(pstart) >= oldest
    cur = {"startDate": str(start), "endDate": str(end)}
    prev = {"startDate": str(pstart), "endDate": str(pend)}

    # property totals
    def totals(rng):
        r = query(svc, dict(rng))
        if not r:
            return [0.0, 0.0, 0.0, 0.0]
        r = r[0]
        return [r["clicks"], r["impressions"], r["ctr"] * 100, r["position"]]

    tot, ptot = totals(cur), totals(prev) if has_prev else [-1.0] * 4
    by_day = {r["keys"][0]: r for r in query(svc, dict(cur, dimensions=["date"]))}
    h_clicks = [by_day.get(d, {}).get("clicks", 0) for d in days]
    h_impr = [by_day.get(d, {}).get("impressions", 0) for d in days]
    h_pos = [by_day.get(d, {}).get("position", 0) for d in days]

    # per-subdomain, current period (with daily series)
    sites = collections.defaultdict(lambda: {"c": 0.0, "i": 0.0, "p": 0.0,
                                             "spark": collections.defaultdict(float),
                                             "cs": collections.defaultdict(float),
                                             "ps": collections.defaultdict(float)})
    for r in query(svc, dict(cur, dimensions=["date", "page"])):
        host = urllib.parse.urlparse(r["keys"][1]).netloc.lower()
        s = sites[host]
        s["c"] += r["clicks"]
        s["i"] += r["impressions"]
        s["p"] += r["position"] * r["impressions"]
        s["spark"][r["keys"][0]] += r["impressions"]
        s["cs"][r["keys"][0]] += r["clicks"]
        s["ps"][r["keys"][0]] += r["position"] * r["impressions"]
    for h in ALWAYS:
        sites[h]

    # per-subdomain, previous period
    psites = collections.defaultdict(lambda: [0.0, 0.0, 0.0])
    for r in query(svc, dict(prev, dimensions=["page"])) if has_prev else []:
        host = urllib.parse.urlparse(r["keys"][0]).netloc.lower()
        psites[host][0] += r["clicks"]
        psites[host][1] += r["impressions"]
        psites[host][2] += r["position"] * r["impressions"]
    if not has_prev:
        psites = collections.defaultdict(lambda: [-1.0, -1.0, 0.0])

    all_queries = query(svc, dict(cur, dimensions=["query"]))
    queries = sorted(all_queries, key=lambda r: (-r["clicks"], -r["impressions"]))[:20]
    # opportunity: often seen just below the top results but rarely clicked
    def missed(r):
        return r["impressions"] * max(0, 0.08 - r["ctr"]) if 3.5 <= r["position"] <= 15 else 0
    chance = sorted(all_queries, key=missed, reverse=True)[:3]
    chance_page = {r["keys"][0]: ("", -1) for r in chance}
    wanted = {r["keys"][0] for r in queries}
    pquery = {r["keys"][0]: r for r in (query(svc, dict(prev, dimensions=["query"])) if has_prev else [])
              if r["keys"][0] in wanted}
    none = 0 if has_prev else -1
    qdays = {}
    for r in query(svc, dict(cur, dimensions=["date", "query"])):
        if r["keys"][1] in wanted:
            qdays[(r["keys"][1], r["keys"][0])] = r

    # Google itemises queries, countries and devices for only part of each site's traffic
    # (the rest is anonymised), so the board shows those as shares, not totals.
    # breakdowns for the hover details: owner -> label -> [clicks, impressions, position x impr]
    def table():
        return collections.defaultdict(lambda: collections.defaultdict(lambda: [0.0, 0.0, 0.0]))

    def add(t, owner, label, r):
        v = t[owner][label]
        v[0] += r["clicks"]
        v[1] += r["impressions"]
        v[2] += r["position"] * r["impressions"]

    def split(url):
        u = urllib.parse.urlparse(url)
        path = urllib.parse.unquote(u.path) or "/"
        return u.netloc.lower(), path + ("?" + u.query if u.query else "")

    s_query, s_page, s_country, s_device = table(), table(), table(), table()
    q_page, q_country, q_device = table(), table(), table()
    a_page, a_country, a_device = table(), table(), table()
    for r in query(svc, dict(cur, dimensions=["page", "query"])):
        host, path = split(r["keys"][0])
        add(s_query, host, r["keys"][1], r)
        if r["keys"][1] in chance_page and r["impressions"] > chance_page[r["keys"][1]][1]:
            chance_page[r["keys"][1]] = (host + path, r["impressions"])
        if r["keys"][1] in wanted:
            add(q_page, r["keys"][1], host + path, r)
    for r in query(svc, dict(cur, dimensions=["page"])):
        host, path = split(r["keys"][0])
        add(s_page, host, path, r)
        add(a_page, "all", host + path, r)
    for dim, st, qt, at, name in (
            ("country", s_country, q_country, a_country, lambda k: COUNTRY.get(k, k.upper())),
            ("device", s_device, q_device, a_device, lambda k: k.capitalize())):
        for r in query(svc, dict(cur, dimensions=["page", dim])):
            add(st, split(r["keys"][0])[0], name(r["keys"][1]), r)
        for r in query(svc, dict(cur, dimensions=["query", dim])):
            if r["keys"][0] in wanted:
                add(qt, r["keys"][0], name(r["keys"][1]), r)
        for r in query(svc, dict(cur, dimensions=[dim])):
            add(at, "all", name(r["keys"][0]), r)

    def clean(v, n=70):
        return " ".join(str(v).split())[:n]

    def top(tag, t, owner, ident, n, by_impr=False):
        """Detail lines: tag, owner id, label, clicks, impressions, position, share of total %."""
        items = t[owner].items() if owner in t else []
        whole = sum(v[1] for _, v in items) or 1
        key = (lambda kv: (-kv[1][1], kv[0])) if by_impr else (lambda kv: (-kv[1][0], -kv[1][1], kv[0]))
        return ["\t".join([tag, ident, clean(k), f(v[0]), f(v[1]),
                           f(v[2] / v[1] if v[1] else 0), f(100 * v[1] / whole)])
                for k, v in sorted(items, key=key)[:n]]

    def series(vals):
        return ",".join(("%.1f" % v).rstrip("0").rstrip(".") for v in vals)

    def f(v):
        return "%.2f" % v

    lines = ["\t".join(["meta", str(start), str(end), str(int(time.time())),
                        str(DAYS), str(int(has_prev)), DOMAIN]),
             "\t".join(["tot"] + [f(v) for v in tot + ptot]),
             "\t".join(["h_clicks"] + [f(v) for v in h_clicks]),
             "\t".join(["h_impr"] + [f(v) for v in h_impr]),
             "\t".join(["h_pos"] + [f(v) for v in h_pos])]
    lines += top("ap", a_page, "all", "all", 6) + top("ac", a_country, "all", "all", 6, True)
    lines += top("ad", a_device, "all", "all", 3, True)
    for host, s in sorted(sites.items(), key=lambda kv: (-kv[1]["i"], kv[0])):
        ctr = 100 * s["c"] / s["i"] if s["i"] else 0
        pos = s["p"] / s["i"] if s["i"] else 0
        lines.append("\t".join(["site", host, f(s["c"]), f(s["i"]), f(ctr), f(pos),
                                f(psites[host][0]), f(psites[host][1]),
                                ",".join("%d" % s["spark"].get(d, 0) for d in days),
                                ",".join("%d" % s["cs"].get(d, 0) for d in days),
                                series(s["ps"][d] / s["spark"][d] if s["spark"].get(d) else 0
                                       for d in days),
                                f(psites[host][2] / psites[host][1] if psites[host][1] else 0)]))
        lines += top("sq", s_query, host, host, 6) + top("sp", s_page, host, host, 5)
        lines += top("sc", s_country, host, host, 5, True) + top("sd", s_device, host, host, 3, True)
    for r in chance:
        lines.append("\t".join(["op", clean(r["keys"][0], 60), f(r["clicks"]), f(r["impressions"]),
                                f(r["position"]), clean(chance_page[r["keys"][0]][0])]))
    for n, r in enumerate(queries, 1):
        q = r["keys"][0]
        p = pquery.get(q, {})
        got = [qdays.get((q, d), {}) for d in days]
        lines.append("\t".join(["query", clean(q, 60), f(r["clicks"]), f(r["impressions"]),
                                f(r["position"]), f(p.get("clicks", none)), f(p.get("impressions", none)),
                                f(p.get("position", 0)),
                                ",".join("%d" % g.get("impressions", 0) for g in got),
                                ",".join("%d" % g.get("clicks", 0) for g in got),
                                series(g.get("position", 0) for g in got)]))
        lines += top("qp", q_page, q, str(n), 4) + top("qc", q_country, q, str(n), 5, True)
        lines += top("qd", q_device, q, str(n), 3, True)

    out = OUT % DAYS
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, out)


if __name__ == "__main__":
    main()
