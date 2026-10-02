#!/usr/bin/env python3
"""draw_fit.py OUT.svg -- the "how many agents fit" chart, read straight from the summaries
lt-fit.sh wrote on each router (docs/measurements/2026-10-03), so no number is typed."""
import os, re, sys

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "docs", "measurements", "2026-10-03")
LINE = re.compile(r"^(threads|procs)-(\d+): (?:guard fired (\d+)x, )?wall (\d+) s, (\d+)/\d+ answered, "
                  r"all of Hermes \(cgroup\) peak (\d+) MB, MemAvailable low (\d+) MB, cgroup OOM kills (\d+)")


def runs(box, run):
    out = {}
    for line in open(os.path.join(HERE, box, run, "summary.txt")):
        m = LINE.match(line)
        if m:
            mode, n, guard, wall, ok, peak, avail, oom = m.groups()
            out[(mode, int(n))] = dict(n=int(n), ok=int(ok) == int(n), wall=int(wall), peak=int(peak),
                                       avail=int(avail), guard=int(guard or 0), oom=int(oom))
    return out


def rest(box, run):
    t = open(os.path.join(HERE, box, run, "steps.log")).read()
    return int(re.search(r"gateway at rest: RSS (\d+) MB", t).group(1))


BOXES = [("flint", "GL-MT6000 (Flint 2)", "MT7986, 4 cores, 1 GB, hermes-agent r2, no Telegram add-on"),
         ("brume", "GL-MT2500 (Brume 2)", "MT7981, 2 cores, 1 GB, hermes-agent r5 with Telegram and openwrt-mcp")]
ROWS = [("threads", "out-cap512", "Conversations in one gateway", "512 MB ceiling (default)"),
        ("procs", "out-cap512", "Separate agents", "512 MB ceiling (default)"),
        ("procs", "out-clean", "Separate agents", "no ceiling, clean OpenWrt")]
COLS = 5
W, X0, CW, CH, GAP = 1280, 360, 172, 58, 8
SANS = "ui-sans-serif,system-ui,sans-serif"
MONO = "ui-monospace,SFMono-Regular,Menlo,monospace"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


def text(x, y, s, size=13, fill="#9aa7b8", font=SANS, weight=None, anchor=None):
    w = f' font-weight="{weight}"' if weight else ""
    a = f' text-anchor="{anchor}"' if anchor else ""
    return f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" fill="{fill}"{w}{a}>{esc(s)}</text>'


def cell(x, y, r):
    if r is None:
        return [f'<rect x="{x}" y="{y}" width="{CW}" height="{CH}" rx="6" fill="#0f1520" stroke="#21262d"/>',
                text(x + CW / 2, y + 34, "not run", 12, "#484f58", anchor="middle")]
    if r["ok"]:
        return [f'<rect x="{x}" y="{y}" width="{CW}" height="{CH}" rx="6" fill="#12261b" stroke="#2ea043"/>',
                text(x + 12, y + 23, f"fits, {r['wall']} s", 13, "#3fb950", weight="600"),
                text(x + 12, y + 44, f"{r['avail']} MB left", 12, "#9aa7b8", MONO)]
    why = "ceiling hit" if r["oom"] else "stopped by guard"
    sub = "service restarted" if r["oom"] else "under 120 MB left"
    return [f'<rect x="{x}" y="{y}" width="{CW}" height="{CH}" rx="6" fill="#2a1416" stroke="#da3633"/>',
            text(x + 12, y + 23, f"no, {why}", 13, "#f85149", weight="600"),
            text(x + 12, y + 44, sub, 12, "#9aa7b8", MONO)]


def main(out):
    p, y = [], 150
    for box, name, sub in BOXES:
        data = {run: runs(box, run) for _, run, _, _ in ROWS}
        p.append(text(48, y, name, 16, "#2dd4bf", weight="600"))
        p.append(text(48 + 200, y, f"{sub}; gateway at rest {rest(box, 'out-cap512')} MB", 12, "#69788b"))
        y += 18
        for c in range(COLS):
            p.append(text(X0 + c * (CW + GAP) + CW / 2, y + 14, f"{c + 1} at once", 12, "#69788b", MONO, anchor="middle"))
        y += 24
        for mode, run, label, sublabel in ROWS:
            p.append(text(48, y + 26, label, 14, "#e6edf3", weight="600"))
            p.append(text(48, y + 45, sublabel, 12, "#69788b"))
            for c in range(COLS):
                p += cell(X0 + c * (CW + GAP), y, data[run].get((mode, c + 1)))
            y += CH + GAP
        y += 34
    H = y + 150
    head = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" '
            'aria-label="How many Hermes agents fit on a 1 GB router: conversations in one gateway, separate agents '
            'under the default 512 MB ceiling, and separate agents with no ceiling on clean OpenWrt, measured on two routers">',
            '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0a0e16"/>'
            '<stop offset="1" stop-color="#0d1117"/></linearGradient><linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">'
            '<stop offset="0" stop-color="#2dd4bf"/><stop offset="1" stop-color="#4493f8"/></linearGradient>'
            '<pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse"><path d="M 40 0 L 0 0 0 40" fill="none" '
            'stroke="#161b22" stroke-width="1"/></pattern></defs>',
            f'<rect width="{W}" height="{H}" fill="url(#bg)"/><rect width="{W}" height="{H}" fill="url(#grid)" opacity="0.5"/>',
            f'<rect width="{W}" height="4" fill="url(#accent)"/>',
            text(48, 58, "How many agents fit on a 1 GB router", 26, "#e6edf3", weight="600"),
            text(48, 84, "Hermes 0.21.5, 2026-10-03, both routers, the same task each time (five commands through the "
                 "terminal tool), model gpt-5.6-luna.", 14, "#69788b"),
            text(48, 106, "“MB left” is the lowest memory the router itself still had available during the run.",
                 14, "#69788b")]
    by = H - 128
    foot = [f'<rect x="48" y="{by}" width="1184" height="104" rx="10" fill="#0f1520" stroke="#30363d"/>',
            text(72, by + 30, "READ IT LIKE THIS", 12, "#2dd4bf", weight="600"),
            text(72, by + 56, "A conversation is a thread of the gateway that is already running, so more of them cost "
                 "almost nothing. A separate agent is a whole", 14),
            text(72, by + 78, "second interpreter, about 140 MB each: two fit under the default ceiling, three with no "
                 "ceiling; a fourth takes the router under 120 MB, where the test stopped it.", 14)]
    open(out, "w").write("\n".join(head + p + foot) + "\n</svg>\n")


if __name__ == "__main__":
    main(sys.argv[1])
