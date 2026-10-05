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
        ("Window open", ["15 minutes of changes", "every call audited"], "root for its length", AMBER),
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


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs")
    data = json.load(open(os.path.join(ROOT, "docs", "measurements", "figures.json"), encoding="utf-8"))
    figures = {"rerun.svg": rerun(data["rerun"]), "install-flow.svg": install_flow(), "unlock.svg": unlock()}
    for name, svg in figures.items():
        with open(os.path.join(outdir, name), "w", encoding="utf-8") as f:
            f.write(svg)
    print("wrote " + ", ".join(sorted(figures)))


if __name__ == "__main__":
    main()
