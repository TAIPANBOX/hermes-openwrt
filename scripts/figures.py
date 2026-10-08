#!/usr/bin/env python3
"""Draw the README's figures from docs/measurements/figures.json.

The numbers live in one file and the SVGs are written from it, so a figure cannot drift from
its data: scripts/gate-figures.sh regenerates them and fails on any difference. Standard
library only. Usage: scripts/figures.py [OUTDIR]   (default: docs)
"""
import json
import os
import sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SANS = "ui-sans-serif,system-ui,sans-serif"
MONO = "ui-monospace,SFMono-Regular,Menlo,monospace"
FG, MUTED, LABEL, PANEL, EDGE = "#e6edf3", "#69788b", "#9aa7b8", "#0f1520", "#30363d"
TEAL, BLUE, GREEN, AMBER = "#2dd4bf", "#4493f8", "#3fb950", "#d29922"


def frame(w, h, label):
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
        f'role="img" aria-label="{escape(label)}">',
        "<defs>",
        '  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0a0e16"/>'
        '<stop offset="1" stop-color="#0d1117"/></linearGradient>',
        f'  <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="{TEAL}"/>'
        f'<stop offset="1" stop-color="{BLUE}"/></linearGradient>',
        '  <pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">'
        '<path d="M 40 0 L 0 0 0 40" fill="none" stroke="#161b22" stroke-width="1"/></pattern>',
        f'  <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        f'orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{BLUE}"/></marker>',
        "</defs>",
        f'<rect width="{w}" height="{h}" fill="url(#bg)"/>'
        f'<rect width="{w}" height="{h}" fill="url(#grid)" opacity="0.5"/>',
        f'<rect width="{w}" height="4" fill="url(#accent)"/>',
    ]


def text(x, y, s, size=14, fill=FG, font=SANS, weight=None, anchor=None, cls=None):
    attrs = f'x="{x}" y="{y}" font-family="{font}" font-size="{size}" fill="{fill}"'
    if weight:
        attrs += f' font-weight="{weight}"'
    if anchor:
        attrs += f' text-anchor="{anchor}"'
    if cls:
        attrs += f' class="{cls}"'
    return f"<text {attrs}>{escape(str(s))}</text>"


def rerun(d):
    w, h = 1280, 560
    out = frame(w, h, d["title"] + ": " + d["subtitle"])
    out.append(text(48, 58, d["title"], 26, weight="600"))
    out.append(text(48, 84, d["subtitle"], 14, MUTED))
    colors = [TEAL, BLUE]
    lx = 48
    for i, r in enumerate(d["routers"]):
        out.append(f'<rect x="{lx}" y="104" width="14" height="14" rx="3" fill="{colors[i]}"/>')
        out.append(text(lx + 22, 116, r, 14, LABEL))
        lx += 120
    panels = [("TIME, SECONDS (shorter is better)", d["time_s"], "s", 48), ("MEMORY AND FLASH, MB", d["size_mb"], "MB", 664)]
    for title, rows, unit, x in panels:
        pw = 568
        ph = 40 + len(rows) * 66
        out.append(f'<rect x="{x}" y="136" width="{pw}" height="{ph}" rx="10" fill="{PANEL}" stroke="{EDGE}"/>')
        out.append(text(x + 24, 166, title, 12, TEAL, weight="600"))
        top = max(max(a, b) for _, a, b in rows)
        bar_max = pw - 24 - 24 - 70
        y = 186
        for name, a, b in rows:
            out.append(text(x + 24, y + 4, name, 13, LABEL, MONO))
            for j, v in enumerate((a, b)):
                by = y + 12 + j * 18
                bw = max(2, round(bar_max * v / top))
                out.append(f'<rect x="{x + 24}" y="{by}" width="{bw}" height="14" rx="3" fill="{colors[j]}"/>')
                out.append(text(x + 24 + bw + 8, by + 12, f"{v} {unit}", 12, FG, MONO))
            y += 66
    out.append(text(48, h - 28, "Source: " + d["source"] + ". One run per figure; the two routers were cleaned first and put back as found.", 13, MUTED))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def install_flow():
    w, h = 1280, 400
    out = frame(w, h, "Install: trust the feed, add the packages, give it a model, start it; then Telegram, the owner unlock and a USB stick are optional")
    out.append("<style>@keyframes flow{to{stroke-dashoffset:-24}}"
               ".flow{stroke-dasharray:8 4;animation:flow 1.2s linear infinite}"
               "@media (prefers-reduced-motion:reduce){.flow{animation:none}}</style>")
    out.append(text(48, 58, "Install", 26, weight="600"))
    out.append(text(48, 84, "Four steps on the router over SSH, or the same through LuCI. Times measured on 2026-10-04 (Flint 2 / Brume 2).", 14, MUTED))
    steps = [
        ("1  Trust the feed", ["its key in /etc/apk/keys", "one repository line"], "no --allow-untrusted"),
        ("2  apk add", ["hermes-agent, luci-app-hermes", "pulls in openwrt-mcp"], "24 s / 64 s"),
        ("3  Give it a model", ["key: root-only file, 0600", "base_url and model in UCI"], "any OpenAI-compatible"),
        ("4  Start it", ["enabled=1, restart", "gateway runs as user hermes"], "about 200 MB resident"),
    ]
    bw, gap, x0, y0 = 266, 38, 48, 116
    for i, (title, lines, foot) in enumerate(steps):
        x = x0 + i * (bw + gap)
        out.append(f'<rect x="{x}" y="{y0}" width="{bw}" height="148" rx="10" fill="{PANEL}" stroke="{EDGE}"/>')
        out.append(f'<rect x="{x}" y="{y0}" width="4" height="148" rx="2" fill="{TEAL}"/>')
        out.append(text(x + 22, y0 + 34, title, 17, weight="600"))
        for k, line in enumerate(lines):
            out.append(text(x + 22, y0 + 66 + k * 22, line, 13, LABEL, MONO))
        out.append(text(x + 22, y0 + 128, foot, 12, GREEN, MONO))
        if i < len(steps) - 1:
            ax = x + bw
            out.append(f'<path class="flow" d="M{ax + 4},{y0 + 74} L{ax + gap - 6},{y0 + 74}" stroke="{BLUE}" stroke-width="2" fill="none" marker-end="url(#arrow)"/>')
    opts = [("Telegram add-on", "+2 s, 12 MB; outbound only"), ("Owner unlock", "PIN and/or app code, the owner sets it"), ("USB stick", "hermes-usb, or extroot for small flash")]
    out.append(text(48, 304, "OPTIONAL", 12, TEAL, weight="600"))
    for i, (t, s) in enumerate(opts):
        x = 48 + i * 400
        out.append(f'<rect x="{x}" y="316" width="376" height="52" rx="8" fill="{PANEL}" stroke="{EDGE}" stroke-dasharray="4 3"/>')
        out.append(text(x + 18, 338, t, 14, FG, weight="600"))
        out.append(text(x + 18, 358, s, 12, LABEL, MONO))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def unlock():
    w, h = 1280, 400
    out = frame(w, h, "An unlock: the owner sends /unlock in the private chat; the bot deletes the message first; openwrt-mcp checks the factor; a window opens for changes; a change that is not confirmed rolls back, after a reboot too")
    n, period = 5, 10
    css = [f"@keyframes lit{{0%,{100 / n * 0.15:.1f}%{{opacity:.28}}{100 / n * 0.35:.1f}%,{100 / n * 1.25:.1f}%{{opacity:1}}{100 / n * 1.6:.1f}%,100%{{opacity:.28}}}}",
           f".st{{animation:lit {period}s ease-in-out infinite}}"]
    for i in range(n):
        css.append(f".s{i}{{animation-delay:{i * period / n:.1f}s}}")
    css.append("@media (prefers-reduced-motion:reduce){.st{animation:none}}")
    out.append("<style>" + "".join(css) + "</style>")
    out.append(text(48, 58, "The owner unlock", 26, weight="600"))
    out.append(text(48, 84, "In the owner profile the agent reads the router freely; a change waits for this. Each step is a check in gate-unlock.sh.", 14, MUTED))
    stages = [
        ("You send", ["/unlock 4821", "in the private chat"], "only allowlisted ids", BLUE),
        ("Deleted first", ["the message is removed", "before anything else"], "never sent to the model", TEAL),
        ("Factor checked", ["by openwrt-mcp: PIN,", "app code or both"], "5 wrong: 15 min lockout", TEAL),
        ("Window open", ["15 minutes of changes", "every call audited"], "settings, VPN, services", AMBER),
        ("Not confirmed?", ["the change is undone", "by itself"], "after a reboot too", GREEN),
    ]
    bw, gap, x0, y0 = 220, 20, 48, 120
    for i, (title, lines, foot, col) in enumerate(stages):
        x = x0 + i * (bw + gap)
        out.append(f'<g class="st s{i}">')
        out.append(f'<rect x="{x}" y="{y0}" width="{bw}" height="170" rx="10" fill="{PANEL}" stroke="{col}"/>')
        out.append(f'<circle cx="{x + 30}" cy="{y0 + 34}" r="14" fill="none" stroke="{col}" stroke-width="2"/>')
        out.append(text(x + 30, y0 + 39, i + 1, 13, col, weight="600", anchor="middle"))
        out.append(text(x + 54, y0 + 40, title, 16, weight="600"))
        for k, line in enumerate(lines):
            out.append(text(x + 18, y0 + 82 + k * 22, line, 13, LABEL, MONO))
        out.append(text(x + 18, y0 + 148, foot, 12, col, MONO))
        out.append("</g>")
    out.append(text(48, 340, "/lock closes the window at once. A scheduled job is refused even inside a window.", 14, LABEL))
    out.append(text(48, 366, "What it does not protect: an open window lets the agent change anything for its length. docs/security.md names every limit.", 14, MUTED))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def draw_flint(x, y):
    """Rear view of a GL-MT6000 as in GL.iNet's photos: a dark wedge body with four tall
    antennas standing behind it, the ports along the back."""
    g = [f'<g transform="translate({x},{y})">']
    for ax in (44, 108, 196, 260):
        g.append(f'<rect x="{ax}" y="0" width="13" height="104" rx="6.5" fill="#2b3544"/>')
        g.append(f'<rect x="{ax + 3}" y="6" width="3" height="90" rx="1.5" fill="#3a4658"/>')
    g.append('<rect x="6" y="78" width="308" height="76" rx="16" fill="#1f2834" stroke="#334155"/>')
    g.append('<rect x="16" y="78" width="288" height="10" rx="5" fill="#2c3747"/>')
    labels = [(34, "USB"), (66, "2.5G"), (98, "2.5G"), (138, "LAN"), (166, "LAN"), (194, "LAN"), (222, "LAN"), (276, "DC")]
    for lx, t in labels:
        g.append(f'<text x="{lx}" y="104" font-family="{SANS}" font-size="6" fill="#8b98a8" text-anchor="middle">{t}</text>')
    g.append('<rect x="27" y="110" width="14" height="26" rx="2" fill="#2f6fd6"/>')
    for px in (54, 86):
        g.append(f'<rect x="{px}" y="110" width="24" height="22" rx="2" fill="#0c1118" stroke="#2dd4bf" stroke-width="1"/>')
        g.append(f'<rect x="{px + 6}" y="127" width="12" height="5" fill="#1f2834"/>')
    for px in (126, 154, 182, 210):
        g.append(f'<rect x="{px}" y="110" width="24" height="22" rx="2" fill="#0c1118" stroke="#46546a"/>')
        g.append(f'<rect x="{px + 6}" y="127" width="12" height="5" fill="#1f2834"/>')
    g.append('<circle cx="276" cy="121" r="8" fill="#0c1118" stroke="#46546a"/><circle cx="276" cy="121" r="2.5" fill="#46546a"/>')
    g.append('<rect x="248" y="117" width="10" height="8" rx="4" fill="#0c1118" stroke="#46546a"/>')
    g.append('<rect x="40" y="154" width="24" height="5" rx="2" fill="#46546a"/><rect x="256" y="154" width="24" height="5" rx="2" fill="#46546a"/>')
    g.append("</g>")
    return g


def draw_brume(x, y):
    """Rear view of the plastic GL-MT2500: a pale lavender-grey box with no antennas; USB-C
    power, USB 3.0, the 2.5G WAN and the 1G LAN on the back."""
    g = [f'<g transform="translate({x},{y})">']
    g.append('<rect x="34" y="34" width="252" height="118" rx="22" fill="#d6d8e4"/>')
    g.append('<rect x="48" y="34" width="224" height="13" rx="6.5" fill="#e6e7ef"/>')
    for lx, t in [(78, "POWER"), (122, "USB"), (168, "WAN 2.5G"), (218, "LAN")]:
        g.append(f'<text x="{lx}" y="86" font-family="{SANS}" font-size="7" fill="#6d7486" text-anchor="middle">{t}</text>')
    g.append('<rect x="67" y="100" width="22" height="9" rx="4.5" fill="#3a4250"/>')
    g.append('<rect x="115" y="94" width="14" height="28" rx="2" fill="#2f6fd6"/>')
    for px in (154, 204):
        g.append(f'<rect x="{px}" y="94" width="28" height="26" rx="2" fill="#3f4756"/>')
        g.append(f'<rect x="{px + 8}" y="115" width="12" height="5" fill="#d6d8e4"/>')
    g.append('<rect x="64" y="152" width="24" height="5" rx="2" fill="#8a90a0"/><rect x="232" y="152" width="24" height="5" rx="2" fill="#8a90a0"/>')
    g.append("</g>")
    return g


def draw_beryl(x, y):
    """The Beryl AX as drawn in docs/usb-stick.svg (front view, from GL.iNet's photos), the
    32 GB stick in its USB 3.0 port."""
    g = [f'<g transform="translate({x + 38},{y + 4})">',
         '<rect x="214" y="14" width="24" height="98" rx="12" fill="#8d9eb1"/>',
         '<rect x="2" y="0" width="28" height="112" rx="14" fill="#a7b7c9"/>',
         f'<text transform="translate(20,62) rotate(-90)" font-family="{SANS}" font-size="9" font-weight="600" fill="#6d7d8f" text-anchor="middle">WiFi 6</text>',
         '<rect x="0" y="72" width="244" height="76" rx="24" fill="#b6c5d5"/>',
         '<rect x="10" y="72" width="224" height="10" rx="5" fill="#c9d6e3"/>',
         f'<text x="44" y="100" font-family="{SANS}" font-size="6" fill="#6d7d8f" text-anchor="middle">5V⎓3A</text>',
         '<rect x="35" y="106" width="18" height="7" rx="3.5" fill="#3a4450"/>',
         '<rect x="88" y="94" width="72" height="34" rx="5" fill="#e6ecf2" stroke="#8d9eb1"/>',
         f'<text x="106" y="91" font-family="{SANS}" font-size="6" fill="#6d7d8f" text-anchor="middle">WAN</text>',
         f'<text x="142" y="91" font-family="{SANS}" font-size="6" fill="#6d7d8f" text-anchor="middle">LAN</text>',
         '<rect x="93" y="100" width="26" height="22" rx="2" fill="#4a5562"/><rect x="100" y="117" width="12" height="5" fill="#e6ecf2"/>',
         '<rect x="129" y="100" width="26" height="22" rx="2" fill="#4a5562"/><rect x="136" y="117" width="12" height="5" fill="#e6ecf2"/>',
         '<rect x="190" y="96" width="14" height="28" rx="2" fill="#2f6fd6"/>',
         '<rect x="186" y="84" width="22" height="50" rx="5" fill="#1f2a38" stroke="#4493f8" stroke-width="1.5"/>',
         f'<text transform="translate(201,109) rotate(-90)" font-family="{MONO}" font-size="8" fill="#9aa7b8" text-anchor="middle">32 GB</text>',
         '<rect x="34" y="148" width="22" height="5" rx="2" fill="#6d7d8f"/>',
         '<rect x="188" y="148" width="22" height="5" rx="2" fill="#6d7d8f"/>',
         "</g>"]
    return g


def routers(d):
    w, card_h, gap, top = 1280, 258, 16, 112
    h = top + 3 * (card_h + gap) + 64
    out = frame(w, h, d["title"] + ": " + ", ".join(b["name"] for b in d["boxes"]))
    out[1:1] = ['<defs><filter id="soft" x="-20%" y="-20%" width="140%" height="140%">'
                '<feDropShadow dx="0" dy="4" stdDeviation="8" flood-color="#000000" flood-opacity="0.45"/></filter></defs>']
    out.append(text(48, 58, d["title"], 26, weight="600"))
    out.append(text(48, 84, d["subtitle"], 14, MUTED))
    draw = {"flint": draw_flint, "brume": draw_brume, "beryl": draw_beryl}
    for i, b in enumerate(d["boxes"]):
        y = top + i * (card_h + gap)
        out.append(f'<rect x="48" y="{y}" width="1184" height="{card_h}" rx="12" fill="#141a23" stroke="#1b2331" filter="url(#soft)"/>')
        out += draw[b["draw"]](64, y + (card_h - 166) // 2)
        out.append(text(424, y + 48, b["model"], 20, weight="600"))
        out.append(text(424, y + 70, b["name"], 14, MUTED))
        for k, line in enumerate(b["spec"]):
            out.append(text(424, y + 102 + k * 22, line, 13, LABEL, MONO))
        out.append(f'<rect x="704" y="{y + 24}" width="1" height="{card_h - 48}" fill="#1b2331"/>')
        for k, (label, value) in enumerate(zip(d["rows"], b["values"])):
            ry = y + 46 + k * 24
            out.append(text(728, ry, label, 13, MUTED))
            out.append(text(964, ry, value, 13, AMBER if k in b["warn"] else FG, MONO))
    for k, note in enumerate(d["notes"]):
        out.append(text(48, top + 3 * (card_h + gap) + 18 + k * 20, note, 12, MUTED))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def usb_choice(d):
    w, h = 1280, 540
    out = frame(w, h, d["title"] + ". " + "; ".join(f'{x["tag"]}: {x["title"]} ({x["sub"]})' for x in d["ways"]))
    out.append(text(48, 58, d["title"], 26, weight="600"))
    out.append(text(48, 84, d["subtitle"], 14, MUTED))
    cols = {"teal": TEAL, "blue": BLUE, "amber": AMBER}
    qx, qy, qw = 490, 108, 300
    out.append(f'<rect x="{qx}" y="{qy}" width="{qw}" height="46" rx="23" fill="{PANEL}" stroke="{FG}"/>')
    out.append(text(qx + qw // 2, qy + 29, d["question"], 15, FG, MONO, anchor="middle"))
    bw, gap, x0, by = 368, 40, 48, 222
    for i, way in enumerate(d["ways"]):
        x = x0 + i * (bw + gap)
        c = cols[way["color"]]
        cx = x + bw // 2
        out.append(f'<path d="M{qx + qw // 2},{qy + 46} C{qx + qw // 2},{qy + 80} {cx},{qy + 70} {cx},{by - 34}" stroke="{c}" stroke-width="2" fill="none" marker-end="url(#arrow)"/>')
        out.append(f'<rect x="{x + 24}" y="{by - 30}" width="{bw - 48}" height="24" rx="12" fill="#0b1018" stroke="{c}"/>')
        out.append(text(cx, by - 13, way["tag"], 12, c, MONO, anchor="middle"))
        out.append(f'<rect x="{x}" y="{by}" width="{bw}" height="290" rx="12" fill="{PANEL}" stroke="{c}"/>')
        out.append(f'<rect x="{x}" y="{by}" width="{bw}" height="5" rx="2.5" fill="{c}"/>')
        out.append(text(x + 24, by + 38, way["title"], 19, weight="600"))
        out.append(text(x + 24, by + 60, way["sub"], 13, MUTED))
        for k, line in enumerate(way["lines"]):
            out.append(text(x + 24, by + 96 + k * 22, line, 13, LABEL, MONO))
        out.append(f'<rect x="{x + 24}" y="{by + 196}" width="{bw - 48}" height="1" fill="{EDGE}"/>')
        out.append(text(x + 24, by + 222, "WITHOUT THE STICK", 11, c, weight="600"))
        out.append(text(x + 24, by + 240, way["stick"], 12, FG))
        out.append(text(x + 24, by + 264, "UNDO", 11, c, weight="600"))
        out.append(text(x + 24, by + 280, way["undo"], 12, FG, MONO))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs")
    data = json.load(open(os.path.join(ROOT, "docs", "measurements", "figures.json"), encoding="utf-8"))
    figures = {"usb-choice.svg": usb_choice(data["usb_choice"]), "boxes.svg": routers(data["routers"]), "rerun.svg": rerun(data["rerun"]), "install-flow.svg": install_flow(), "unlock.svg": unlock()}
    for name, svg in figures.items():
        with open(os.path.join(outdir, name), "w", encoding="utf-8") as f:
            f.write(svg)
    print("wrote " + ", ".join(sorted(figures)))


if __name__ == "__main__":
    main()
