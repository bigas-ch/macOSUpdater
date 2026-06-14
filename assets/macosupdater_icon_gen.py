#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────
#  macosupdater_icon_gen.py — source generator for assets/macosupdater.icns
#
#  Family style (matches Adobe_Toggle): dark Big-Sur squircle, one accent
#  colour, one central symbol. Here: blue gear + white/blue refresh badge.
#  Output is pure vector (SVG) → rendered per-size → packed to .icns.
#
#  Reproduce the .icns (macOS, needs Google Chrome + iconutil + sips):
#    cd "$(dirname "$0")"
#    python3 macosupdater_icon_gen.py                 # writes macosupdater.svg
#    CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
#    cat > _wrap.html <<'EOF'
#    <!DOCTYPE html><html><head><meta charset="utf-8">
#    <style>html,body{margin:0;padding:0}img{width:100vw;height:100vh;display:block}</style>
#    </head><body><img src="macosupdater.svg"></body></html>
#    EOF
#    mkdir -p macosupdater.iconset
#    for SZ in 16 32 64 128 256 512 1024; do
#      "$CHROME" --headless --disable-gpu --force-device-scale-factor=1 \
#        --default-background-color=00000000 --hide-scrollbars \
#        --window-size=$SZ,$SZ --screenshot=r_$SZ.png "file://$PWD/_wrap.html"
#    done
#    cp r_16.png  macosupdater.iconset/icon_16x16.png
#    cp r_32.png  macosupdater.iconset/icon_16x16@2x.png
#    cp r_32.png  macosupdater.iconset/icon_32x32.png
#    cp r_64.png  macosupdater.iconset/icon_32x32@2x.png
#    cp r_128.png macosupdater.iconset/icon_128x128.png
#    cp r_256.png macosupdater.iconset/icon_128x128@2x.png
#    cp r_256.png macosupdater.iconset/icon_256x256.png
#    cp r_512.png macosupdater.iconset/icon_256x256@2x.png
#    cp r_512.png macosupdater.iconset/icon_512x512.png
#    cp r_1024.png macosupdater.iconset/icon_512x512@2x.png
#    iconutil -c icns macosupdater.iconset -o macosupdater.icns
# ─────────────────────────────────────────────────────────────────────
import math, os

CANVAS = 1024

def squircle_path(cx, cy, size, n=5.0, steps=240):
    a = size / 2.0
    pts = []
    for i in range(steps + 1):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = cy + a * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((x, y))
    return "M {:.2f} {:.2f} ".format(*pts[0]) + " ".join(
        "L {:.2f} {:.2f}".format(x, y) for x, y in pts[1:]) + " Z"

def gear_path(cx, cy, r_out, r_root, teeth=8, tip_frac=0.42):
    pts = []
    seg = 2 * math.pi / teeth
    for k in range(teeth):
        a0 = k * seg
        half_tip = seg * tip_frac / 2.0
        half_val = seg * (1 - tip_frac) / 2.0
        for an, rr in ((a0-half_val, r_root), (a0-half_tip, r_out),
                       (a0+half_tip, r_out), (a0+half_val, r_root)):
            pts.append((cx + rr*math.cos(an), cy + rr*math.sin(an)))
    return "M {:.2f} {:.2f} ".format(*pts[0]) + " ".join(
        "L {:.2f} {:.2f}".format(x, y) for x, y in pts[1:]) + " Z"

def arc_pt(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r*math.cos(a), cy + r*math.sin(a)

def refresh_arrows(cx, cy, r, arc_deg=150, head_len=82, head_w=60):
    """Two opposed clockwise arcs (sweep-flag 1), each ending in a tangential arrowhead."""
    arcs, heads = [], []
    for base in (8, 188):                       # two arcs, 180 deg apart
        a0, a1 = base, base + arc_deg
        p0 = arc_pt(cx, cy, r, a0)
        p1 = arc_pt(cx, cy, r, a1)
        large = 1 if arc_deg > 180 else 0
        arcs.append(f'M {p0[0]:.1f} {p0[1]:.1f} A {r} {r} 0 {large} 1 {p1[0]:.1f} {p1[1]:.1f}')
        ar = math.radians(a1)
        # motion direction at a1 for sweep-flag 1 = derivative (-sin, cos); radial = (cos, sin)
        tx, ty = -math.sin(ar), math.cos(ar)
        rx, ry =  math.cos(ar), math.sin(ar)
        tip = (p1[0] + tx*head_len, p1[1] + ty*head_len)
        ca  = (p1[0] + rx*head_w,   p1[1] + ry*head_w)
        cb  = (p1[0] - rx*head_w,   p1[1] - ry*head_w)
        heads.append(f'M {tip[0]:.1f} {tip[1]:.1f} L {ca[0]:.1f} {ca[1]:.1f} L {cb[0]:.1f} {cb[1]:.1f} Z')
    return arcs, heads

sq = squircle_path(512, 512, 880)
gx, gy = 470, 560
gear = gear_path(gx, gy, r_out=312, r_root=250, teeth=8)
bx, by, br = 712, 312, 172
arcs, heads = refresh_arrows(bx, by, 84)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0"    stop-color="#48484C"/>
      <stop offset="0.42" stop-color="#2A2A2D"/>
      <stop offset="1"    stop-color="#121214"/>
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0"    stop-color="#8A8A90" stop-opacity="0.9"/>
      <stop offset="0.18" stop-color="#6A6A70" stop-opacity="0.35"/>
      <stop offset="0.4"  stop-color="#000000" stop-opacity="0"/>
      <stop offset="0.85" stop-color="#000000" stop-opacity="0"/>
      <stop offset="1"    stop-color="#000000" stop-opacity="0.5"/>
    </linearGradient>
    <radialGradient id="vig" cx="0.5" cy="0.36" r="0.72">
      <stop offset="0"    stop-color="#000000" stop-opacity="0"/>
      <stop offset="0.72" stop-color="#000000" stop-opacity="0"/>
      <stop offset="1"    stop-color="#000000" stop-opacity="0.55"/>
    </radialGradient>
    <linearGradient id="blue" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#54ABFF"/>
      <stop offset="0.5" stop-color="#0A84FF"/>
      <stop offset="1" stop-color="#005BD0"/>
    </linearGradient>
    <radialGradient id="badge" cx="0.4" cy="0.32" r="0.85">
      <stop offset="0" stop-color="#34343A"/>
      <stop offset="1" stop-color="#1C1C1F"/>
    </radialGradient>
    <filter id="drop" x="-25%" y="-25%" width="150%" height="170%">
      <feDropShadow dx="0" dy="30" stdDeviation="34" flood-color="#000" flood-opacity="0.5"/>
    </filter>
    <filter id="lift" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.45"/>
    </filter>
  </defs>

  <path d="{sq}" fill="url(#bg)" filter="url(#drop)"/>
  <path d="{sq}" fill="url(#vig)"/>
  <path d="{sq}" fill="none" stroke="url(#rim)" stroke-width="5"/>

  <g filter="url(#lift)">
    <path d="{gear}" fill="url(#blue)" stroke="#0050C0" stroke-width="8" stroke-linejoin="round"/>
    <circle cx="{gx}" cy="{gy}" r="116" fill="url(#bg)"/>
    <circle cx="{gx}" cy="{gy}" r="116" fill="none" stroke="#0050C0" stroke-width="8"/>
    <path d="{gear}" fill="none" stroke="#7FC0FF" stroke-width="6" stroke-linejoin="round" stroke-opacity="0.5"/>
  </g>

  <g filter="url(#lift)">
    <circle cx="{bx}" cy="{by}" r="{br}" fill="url(#badge)" stroke="#0A84FF" stroke-width="16"/>
    {''.join(f'<path d="{a}" fill="none" stroke="#0A84FF" stroke-width="44" stroke-linecap="butt"/>' for a in arcs)}
    {''.join(f'<path d="{h}" fill="#0A84FF"/>' for h in heads)}
  </g>
</svg>'''

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "macosupdater.svg")
with open(out, "w") as f:
    f.write(svg)
print("SVG written:", out, len(svg), "bytes")
