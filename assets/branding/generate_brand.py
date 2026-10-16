#!/usr/bin/env python3
"""Danaview brand + platform icon generator (final mark: 6B page-fold Dv).

Everything is hand-written geometry on a 1024 grid; no fonts or downloads.
Run from anywhere:  python3 assets/branding/generate_brand.py
Needs /opt/homebrew/bin/rsvg-convert and magick.

Construction (1024 grid, glyph centred on 512,512):
  page        x 288-736, y 288-736 (448 square)
  spine       left side, corners r 68
  bowl        bottom-right arc r 216 about (520,520)
  fold        35 deg; A on top edge 220 in from the corner -> A (516,288),
              B on right edge 220*tan35 = 154 down -> B (736,442).
              Flap = corner reflected across AB; vertex C (591.2,494.7).
              The flap's free edges AC and CB form the v (90 deg, tilted 10).
  knockout    page is cut 44 around the flap; flap drawn with its fold edge
              set 20 in from AB and a 4 round stroke -> 40 visible gap.
  flap tone   #C9CBFF on the indigo tile (or the product accent).
"""
import math, os, subprocess, base64, shutil, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RSVG = "/opt/homebrew/bin/rsvg-convert"
MAGICK = "/opt/homebrew/bin/magick"

GRAD = ("#7C7FF5", "#5141DD")
FLAP = "#C9CBFF"
PRODUCTS = [  # file, name, flap colour
    ("player", "Player", FLAP),
    ("editor", "Editor", "#8B5CF6"),
    ("camera", "Camera", "#06B6D4"),
    ("photos", "Photos", "#F59E0B"),
    ("docs", "Docs", "#10B981"),
]
FONT = "Figtree, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"

# ---------------------------------------------------------------- geometry
L, T, RR, BB = 288, 288, 736, 736
CORNER_R = 68
BOWL_R = 216
BOWL_C = (520, 520)
FOLD_DEG = 35
FOLD_A = 220
KNOCK = 44          # half-width of the knockout around the flap
FLAP_INSET = 20     # fold edge of the visible flap, measured in from AB
FLAP_ROUND = 4      # round stroke half-width on the flap


def _fold():
    th = math.radians(FOLD_DEG)
    A = (RR - FOLD_A, T)
    B = (RR, T + FOLD_A * math.tan(th))
    ang = math.radians(2 * FOLD_DEG - 180)
    C = (A[0] - FOLD_A * math.cos(ang), A[1] - FOLD_A * math.sin(ang))
    return A, B, C


A, B, C = _fold()


def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def pts(p):
    return " ".join(f"{f(x)},{f(y)}" for x, y in p)


def _flap_shrunk(d):
    ax, ay = A; bx, by = B; cx, cy = C
    h = abs((bx - ax) * (ay - cy) - (ax - cx) * (by - ay)) / math.hypot(bx - ax, by - ay)
    t = d / h
    mv = lambda P: (P[0] + (cx - P[0]) * t, P[1] + (cy - P[1]) * t)
    return [mv(A), C, mv(B)]


PAGE = (f"M{L + CORNER_R} {T} L{f(A[0])} {T} L{RR} {f(B[1])} L{RR} {BOWL_C[1]} "
        f"A{BOWL_R} {BOWL_R} 0 0 1 {BOWL_C[0]} {BB} L{L + CORNER_R} {BB} "
        f"A{CORNER_R} {CORNER_R} 0 0 1 {L} {BB - CORNER_R} L{L} {T + CORNER_R} "
        f"A{CORNER_R} {CORNER_R} 0 0 1 {L + CORNER_R} {T} Z")


def glyph(uid, page="#FFFFFF", flap=FLAP):
    """The mark: page silhouette with the flap knocked out, plus the flap."""
    m = (f'<mask id="k{uid}" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
         f'<rect width="1024" height="1024" fill="#fff"/>'
         f'<polygon points="{pts([A, C, B])}" fill="#000" stroke="#000" stroke-width="{2 * KNOCK}" stroke-linejoin="round"/></mask>')
    fl = _flap_shrunk(FLAP_INSET)
    return (f'<defs>{m}</defs><path d="{PAGE}" fill="{page}" mask="url(#k{uid})"/>'
            f'<polygon points="{pts(fl)}" fill="{flap}" stroke="{flap}" stroke-width="{2 * FLAP_ROUND}" stroke-linejoin="round"/>')


def shadow_filter(fid, std, dy):
    return (f'<filter id="{fid}" x="-40%" y="-40%" width="180%" height="180%" color-interpolation-filters="sRGB">'
            f'<feGaussianBlur in="SourceAlpha" stdDeviation="{std}"/><feOffset dy="{dy}" result="blur"/>'
            f'<feFlood flood-color="#000000" flood-opacity="0.16"/><feComposite in2="blur" operator="in" result="shadow"/>'
            f'<feMerge><feMergeNode in="shadow"/><feMergeNode in="SourceGraphic"/></feMerge></filter>')


def bg_defs(uid, stops=GRAD):
    a, b = stops
    return (f'<linearGradient id="bg{uid}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="1024" y2="1024">'
            f'<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'
            f'<radialGradient id="gl{uid}" gradientUnits="userSpaceOnUse" cx="225.28" cy="143.36" r="798.72">'
            f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.10"/><stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.035"/>'
            f'<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>')


def icon_body(uid, flap=FLAP, stops=GRAD):
    """Full-bleed square icon content (no outer <svg>)."""
    return (f'<defs>{bg_defs(uid, stops)}{shadow_filter("sh" + uid, 25.6, 15.36)}</defs>'
            f'<rect width="1024" height="1024" fill="url(#bg{uid})"/><rect width="1024" height="1024" fill="url(#gl{uid})"/>'
            f'<g filter="url(#sh{uid})">{glyph(uid, flap=flap)}</g>')


def svg(body, w=1024, h=1024, extra=""):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"{extra}>{body}</svg>\n'


# Squircle used by the existing danaview_icon_rounded.svg (824 tile at 100).
SQUIRCLE = ("M640.64 100 c99.185 0 148.778 0 186.662 19.303 a177.1 177.1 0 0 1 77.396 77.396 c19.303 37.884 19.303 87.476 19.303 186.662 "
            "L924 640.64 c0 99.185 0 148.778 -19.303 186.662 a177.1 177.1 0 0 1 -77.396 77.396 c-37.884 19.303 -87.476 19.303 -186.662 19.303 "
            "L383.36 924 c-99.185 0 -148.778 0 -186.662 -19.303 a177.1 177.1 0 0 1 -77.396 -77.396 c-19.303 -37.884 -19.303 -87.476 -19.303 -186.662 "
            "L100 383.36 c0 -99.185 0 -148.778 19.303 -186.662 a177.1 177.1 0 0 1 77.396 -77.396 c37.884 -19.303 87.476 -19.303 186.662 -19.303 Z")


def tile_svg(uid, inset, shadow=True, flap=FLAP):
    """Squircle tile of side 1024-2*inset with the full icon scaled into it."""
    side = 1024 - 2 * inset
    s = side / 824
    sq = f'<path transform="translate({f(inset - 100 * s)} {f(inset - 100 * s)}) scale({f(s)})" d="{SQUIRCLE}"/>'
    k = side / 1024
    sh = ""
    if shadow:
        sh = (f'<filter id="ts{uid}" x="-20%" y="-20%" width="140%" height="140%" color-interpolation-filters="sRGB">'
              f'<feGaussianBlur in="SourceAlpha" stdDeviation="{f(12 * s)}"/><feOffset dy="{f(10 * s)}" result="blur"/>'
              f'<feFlood flood-color="#000000" flood-opacity="0.28"/><feComposite in2="blur" operator="in"/></filter>')
    body = (f'<defs><clipPath id="tc{uid}">{sq}</clipPath>{sh}</defs>'
            + (f'<g filter="url(#ts{uid})" fill="#000">{sq}</g>' if shadow else "")
            + f'<g clip-path="url(#tc{uid})"><g transform="translate({f(inset)} {f(inset)}) scale({f(k)})">{icon_body(uid, flap)}</g></g>')
    return svg(body)


def adaptive_glyph(uid, mono=False):
    """Android adaptive foreground: glyph at 2/3 (72/108) on a 1024 layer."""
    g = glyph(uid, page="#FFFFFF", flap="#FFFFFF") if mono else glyph(uid)
    if mono:
        return svg(f'<g transform="translate(512 512) scale(0.6667) translate(-512 -512)">{g}</g>')
    return svg(f'<defs>{shadow_filter("gs" + uid, 17.067, 10.24)}</defs>'
               f'<g filter="url(#gs{uid})"><g transform="translate(512 512) scale(0.6667) translate(-512 -512)">{g}</g></g>')


BACKGROUND = svg(
    '<defs><linearGradient id="bgFill" gradientUnits="userSpaceOnUse" x1="170.667" y1="170.667" x2="853.333" y2="853.333">'
    '<stop offset="0" stop-color="#7C7FF5"/><stop offset="1" stop-color="#5141DD"/></linearGradient>'
    '<radialGradient id="bgGlow" gradientUnits="userSpaceOnUse" cx="320.853" cy="266.24" r="532.48">'
    '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.10"/><stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.035"/>'
    '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient></defs>'
    '<rect width="1024" height="1024" fill="url(#bgFill)"/><rect width="1024" height="1024" fill="url(#bgGlow)"/>')


def mono_svg(uid, color="currentColor"):
    return svg(glyph(uid, page=color, flap=color))


def lockup(uid, layout, text_color):
    clip = f'<clipPath id="lc{uid}"><rect width="1024" height="1024" rx="229"/></clipPath>'
    mark = f'<g clip-path="url(#lc{uid})">{icon_body(uid)}</g>'
    if layout == "horizontal":
        w, h = 600, 160
        body = (f'<defs>{clip}</defs><g transform="translate(16 16) scale(0.125)">{mark}</g>'
                f'<text x="170" y="103" fill="{text_color}" font-family="{FONT}" font-size="64" font-weight="700" letter-spacing="-0.6">Danaview</text>')
    else:
        w, h = 360, 290
        body = (f'<defs>{clip}</defs><g transform="translate(116 16) scale(0.125)">{mark}</g>'
                f'<text x="180" y="232" text-anchor="middle" fill="{text_color}" font-family="{FONT}" font-size="54" font-weight="700" letter-spacing="-0.5">Danaview</text>')
    return svg(body, w, h)


# ---------------------------------------------------------------- helpers
def write(rel, text):
    p = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as fh:
        fh.write(text)
    return p


def render(svg_path, out, size, opaque=False):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run([RSVG, "-w", str(size), "-h", str(size), "-o", out, svg_path], check=True)
    if opaque:
        subprocess.run([MAGICK, out, "-background", "#5141DD", "-alpha", "remove", "-alpha", "off", out], check=True)


def tmp_svg(tmp, name, text):
    p = os.path.join(tmp, name)
    with open(p, "w") as fh:
        fh.write(text)
    return p


# ---------------------------------------------------------------- main
def main():
    tmp = tempfile.mkdtemp(prefix="dvbrand")
    br = "assets/branding"
    # 1. masters (same filenames and roles as before)
    icon = write(f"{br}/danaview_icon.svg", svg(icon_body("i")))
    rounded = write(f"{br}/danaview_icon_rounded.svg", tile_svg("r", 100))
    gly = write(f"{br}/danaview_glyph.svg", adaptive_glyph("g"))
    bgp = write(f"{br}/danaview_background.svg", BACKGROUND)
    write(f"{br}/danaview_glyph_mono.svg", mono_svg("m"))
    render(icon, os.path.join(ROOT, br, "danaview_icon.png"), 1024, opaque=True)
    render(rounded, os.path.join(ROOT, br, "danaview_icon_rounded.png"), 1024)
    render(gly, os.path.join(ROOT, br, "danaview_glyph.png"), 1024)
    render(bgp, os.path.join(ROOT, br, "danaview_background.png"), 1024, opaque=True)
    for key, name, col in PRODUCTS:
        write(f"{br}/products/{key}.svg", svg(icon_body("p" + key, flap=col)))
    for layout in ("horizontal", "stacked"):
        write(f"{br}/wordmark/danaview_lockup_{layout}.svg", lockup("w" + layout[0], layout, "#FFFFFF"))
        write(f"{br}/wordmark/danaview_lockup_{layout}_light.svg", lockup("l" + layout[0], layout, "#0F1118"))

    # 2. platform icons
    ios = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for fn, px in [("Icon-App-1024x1024@1x.png", 1024), ("Icon-App-20x20@1x.png", 20), ("Icon-App-20x20@2x.png", 40),
                   ("Icon-App-20x20@3x.png", 60), ("Icon-App-29x29@1x.png", 29), ("Icon-App-29x29@2x.png", 58),
                   ("Icon-App-29x29@3x.png", 87), ("Icon-App-40x40@1x.png", 40), ("Icon-App-40x40@2x.png", 80),
                   ("Icon-App-40x40@3x.png", 120), ("Icon-App-60x60@2x.png", 120), ("Icon-App-60x60@3x.png", 180),
                   ("Icon-App-76x76@1x.png", 76), ("Icon-App-76x76@2x.png", 152), ("Icon-App-83.5x83.5@2x.png", 167)]:
        render(icon, os.path.join(ROOT, ios, fn), px, opaque=True)
    mac = "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for px in (16, 32, 64, 128, 256, 512, 1024):
        render(rounded, os.path.join(ROOT, mac, f"app_icon_{px}.png"), px)
    res = "android/app/src/main/res"
    legacy = tmp_svg(tmp, "legacy.svg", tile_svg("a", 42.67))
    mono_ad = tmp_svg(tmp, "mono_ad.svg", adaptive_glyph("am", mono=True))
    for d, base in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
        layer = base * 108 // 48
        render(legacy, os.path.join(ROOT, res, f"mipmap-{d}", "ic_launcher.png"), base)
        render(gly, os.path.join(ROOT, res, f"mipmap-{d}", "ic_launcher_foreground.png"), layer)
        render(bgp, os.path.join(ROOT, res, f"mipmap-{d}", "ic_launcher_background.png"), layer, opaque=True)
        render(mono_ad, os.path.join(ROOT, res, f"mipmap-{d}", "ic_launcher_monochrome.png"), layer)
    win = tmp_svg(tmp, "win.svg", tile_svg("wn", 0, shadow=False))
    sizes = [16, 24, 32, 48, 64, 128, 256]
    frames = []
    for px in sizes:
        o = os.path.join(tmp, f"win_{px}.png")
        render(win, o, px)
        frames.append(o)
    write_ico(tmp, frames, sizes, os.path.join(ROOT, "windows/runner/resources/app_icon.ico"))

    # 3. sheets
    build_preview(tmp, icon, rounded)
    build_brand_sheet(tmp)
    shutil.rmtree(tmp)


def write_ico(tmp, frames, sizes, out):
    """ICO like the previous one: BMP frames up to 64 px (via magick),
    PNG-compressed frames for 128 and 256."""
    import struct
    small = [(fr, px) for fr, px in zip(frames, sizes) if px <= 64]
    big = [(fr, px) for fr, px in zip(frames, sizes) if px > 64]
    tmp_ico = os.path.join(tmp, "small.ico")
    subprocess.run([MAGICK] + [fr for fr, _ in small] + [tmp_ico], check=True)
    raw = open(tmp_ico, "rb").read()
    n = struct.unpack_from("<H", raw, 4)[0]
    entries = []
    for i in range(n):
        w, h, cc, r, planes, bpp, size, off = struct.unpack_from("<BBBBHHII", raw, 6 + 16 * i)
        entries.append(((w, h, cc, planes, bpp), raw[off:off + size]))
    for fr, px in big:
        entries.append(((px % 256, px % 256, 0, 1, 32), open(fr, "rb").read()))
    hdr = struct.pack("<HHH", 0, 1, len(entries))
    off = 6 + 16 * len(entries)
    dirs, blobs = b"", b""
    for (w, h, cc, planes, bpp), blob in entries:
        dirs += struct.pack("<BBBBHHII", w, h, cc, 0, planes, bpp, len(blob), off)
        off += len(blob); blobs += blob
    with open(out, "wb") as fh:
        fh.write(hdr + dirs + blobs)


def data_uri(path):
    with open(path, "rb") as fh:
        return "data:image/png;base64," + base64.b64encode(fh.read()).decode()


def zoom(src, out, px):
    subprocess.run([MAGICK, src, "-filter", "point", "-resize", f"{px}x{px}", out], check=True)
    return out


def build_preview(tmp, icon, rounded):
    """Same layout as the previous preview_sheet.png: dark and light halves."""
    imgs = {}
    for px in (180, 60, 29, 16):
        o = os.path.join(tmp, f"pv_{px}.png"); render(rounded if px == 16 else icon, o, px); imgs[px] = o
    mac16 = os.path.join(tmp, "pv_mac16.png"); render(rounded, mac16, 16)
    win16 = os.path.join(tmp, "pv_win16.png"); render(os.path.join(tmp, "win.svg"), win16, 16)
    big = os.path.join(tmp, "pv_big.png"); render(icon, big, 1024)
    z29 = zoom(os.path.join(ROOT, "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png"), os.path.join(tmp, "z29.png"), 232)
    z16w = zoom(win16, os.path.join(tmp, "z16w.png"), 128)
    z16m = zoom(mac16, os.path.join(tmp, "z16m.png"), 128)
    W, H = 2652, 2328
    parts = []
    for half, (bgc, fg) in enumerate([("#141318", "#C9CAD3"), ("#F2F1F6", "#3A3B45")]):
        y0 = half * H // 2
        parts.append(f'<rect x="0" y="{y0}" width="{W}" height="{H // 2}" fill="{bgc}"/>')
        parts.append(f'<clipPath id="c{half}"><rect x="48" y="{y0 + 48}" width="1024" height="1024" rx="229"/></clipPath>')
        parts.append(f'<image x="48" y="{y0 + 48}" width="1024" height="1024" href="{data_uri(big)}" clip-path="url(#c{half})"/>')
        parts.append(f'<text x="48" y="{y0 + 1108}" fill="{fg}" font-family="{FONT}" font-size="22">iOS 1024</text>')
        x = 1120
        cells = [(imgs[180], 180, "iOS 180", 40), (imgs[60], 60, "iOS 60", 13), (imgs[29], 29, "iOS 29", 6.5),
                 (win16, 16, "Win 16", 0), (mac16, 16, "mac 16", 0), (z29, 232, "iOS 29 x8", 52), (z16w, 128, "Win 16 x8", 0), (z16m, 128, "mac 16 x8", 0)]
        for path, sz, lbl, r in cells:
            yb = y0 + 690
            parts.append(f'<clipPath id="k{half}{lbl.replace(" ", "")}"><rect x="{x}" y="{yb - sz}" width="{sz}" height="{sz}" rx="{r}"/></clipPath>')
            parts.append(f'<image x="{x}" y="{yb - sz}" width="{sz}" height="{sz}" href="{data_uri(path)}" '
                         f'clip-path="url(#k{half}{lbl.replace(" ", "")})" style="image-rendering:pixelated"/>')
            parts.append(f'<text x="{x}" y="{yb + 34}" fill="{fg}" font-family="{FONT}" font-size="22">{lbl}</text>')
            x += max(sz, 120) + 50
    p = tmp_svg(tmp, "preview.svg", svg("".join(parts), W, H))
    subprocess.run([RSVG, "-o", os.path.join(ROOT, "assets/branding/preview_sheet.png"), p], check=True)


def build_brand_sheet(tmp):
    W, H = 2400, 3060
    P = [f'<rect width="{W}" height="{H}" fill="#07080C"/>']
    tx = lambda x, y, s, t, c="#E6E7EE", w=400, a="start": P.append(
        f'<text x="{x}" y="{y}" fill="{c}" font-family="{FONT}" font-size="{s}" font-weight="{w}" text-anchor="{a}">{t}</text>')
    tx(120, 170, 76, "Danaview", "#FFFFFF", 700)
    tx(120, 236, 30, "Brand sheet · mark 6B page-fold Dv · v1", "#9A9DB0")
    # master
    P.append(f'<g transform="translate(120 320) scale(0.5)"><clipPath id="mc"><rect width="1024" height="1024" rx="229"/></clipPath>'
             f'<g clip-path="url(#mc)">{icon_body("bs")}</g></g>')
    tx(120, 880, 24, "Master icon · white page on the indigo gradient", "#9A9DB0")
    # construction
    cx0, cy0, k = 760, 320, 0.5
    g = [f'<rect width="1024" height="1024" fill="#0F1118"/>']
    for i in range(0, 1025, 64):
        g.append(f'<line x1="{i}" y1="0" x2="{i}" y2="1024" stroke="#1C1F2B" stroke-width="2"/><line x1="0" y1="{i}" x2="1024" y2="{i}" stroke="#1C1F2B" stroke-width="2"/>')
    g.append(glyph("bc", page="#3A3F78", flap="#6F73D9"))
    g.append(f'<circle cx="512" cy="512" r="338" fill="none" stroke="#10B981" stroke-width="3" stroke-dasharray="14 10"/>')
    g.append(f'<rect x="{L}" y="{T}" width="{RR - L}" height="{BB - T}" fill="none" stroke="#F59E0B" stroke-width="3" stroke-dasharray="10 8"/>')
    g.append(f'<line x1="{f(A[0] - 120 * math.cos(math.radians(FOLD_DEG)))}" y1="{f(A[1] - 120 * math.sin(math.radians(FOLD_DEG)))}" '
             f'x2="{f(B[0] + 120 * math.cos(math.radians(FOLD_DEG)))}" y2="{f(B[1] + 120 * math.sin(math.radians(FOLD_DEG)))}" stroke="#06B6D4" stroke-width="4"/>')
    g.append(f'<circle cx="{BOWL_C[0]}" cy="{BOWL_C[1]}" r="{BOWL_R}" fill="none" stroke="#8B5CF6" stroke-width="3" stroke-dasharray="6 6"/>')
    for (x, y), n in ((A, "A"), (B, "B"), (C, "C")):
        g.append(f'<circle cx="{f(x)}" cy="{f(y)}" r="9" fill="#FFFFFF"/><text x="{f(x + 16)}" y="{f(y - 14)}" fill="#FFFFFF" font-family="{FONT}" font-size="34">{n}</text>')
    P.append(f'<g transform="translate({cx0} {cy0}) scale({k})">{"".join(g)}</g>')
    notes = ["Construction on a 1024 grid",
             f"Page 448 square (288 to 736), spine corners r {CORNER_R}",
             f"Bowl r {BOWL_R} about (520, 520)",
             f"Fold {FOLD_DEG} deg: A = 220 in from the corner, B = 154 down",
             "Flap = corner reflected across AB; C is the v vertex",
             f"Knockout {KNOCK} around the flap, flap inset {FLAP_INSET}: 40 gap",
             "Green: 66% safe circle · amber: page box"]
    for i, n in enumerate(notes):
        tx(1320, 360 + i * 46, 26 if i else 30, n, "#FFFFFF" if i == 0 else "#A9ACBF", 700 if i == 0 else 400)
    # sizes
    y = 960
    tx(120, y, 34, "Minimum sizes", "#FFFFFF", 700)
    x = 120
    for px in (180, 60, 48, 29, 16):
        o = os.path.join(tmp, f"bs_{px}.png"); render(os.path.join(ROOT, "assets/branding/danaview_icon.svg"), o, px)
        P.append(f'<clipPath id="sz{px}"><rect x="{x}" y="{y + 220 - px}" width="{px}" height="{px}" rx="{px * 0.2237}"/></clipPath>'
                 f'<image x="{x}" y="{y + 220 - px}" width="{px}" height="{px}" href="{data_uri(o)}" clip-path="url(#sz{px})"/>')
        tx(x, y + 260, 22, f"{px} px", "#7D8094")
        x += px + 60
    tx(900, y + 70, 24, "Icon: 16 px minimum (flap tone carries the v; the gap", "#A9ACBF")
    tx(900, y + 104, 24, "opens from 29 px). Mono glyph: 12 px. Lockup: 24 px mark height.", "#A9ACBF")
    tx(900, y + 150, 24, "Clear space: 1/4 of the tile side on every edge (lockups and", "#A9ACBF")
    tx(900, y + 184, 24, "placements); the gap between mark and word = 1/3 of tile side.", "#A9ACBF")
    # colours
    y = 1330
    tx(120, y, 34, "Colour", "#FFFFFF", 700)
    sw = [("#7C7FF5", "Gradient start"), ("#5141DD", "Gradient end"), ("#FFFFFF", "Page"), (FLAP, "Flap tone"),
          ("#07080C", "UI background"), ("#0F1118", "UI surface")]
    for i, (hx, n) in enumerate(sw):
        x = 120 + i * 360
        P.append(f'<rect x="{x}" y="{y + 30}" width="320" height="120" rx="18" fill="{hx}" stroke="#2A2D3D" stroke-width="2"/>')
        tx(x, y + 190, 24, n, "#E6E7EE", 600); tx(x, y + 222, 22, hx, "#7D8094")
    # family
    y = 1640
    tx(120, y, 34, "Product family · indigo tile, accent on the flap only", "#FFFFFF", 700)
    for i, (key, name, col) in enumerate(PRODUCTS):
        x = 120 + i * 420
        P.append(f'<g transform="translate({x} {y + 40}) scale(0.3125)"><clipPath id="pf{key}"><rect width="1024" height="1024" rx="229"/></clipPath>'
                 f'<g clip-path="url(#pf{key})">{icon_body("bf" + key, flap=col)}</g></g>')
        tx(x, y + 400, 26, name, "#E6E7EE", 600); tx(x, y + 432, 22, col if key != "player" else "#C9CBFF (master)", "#7D8094")
    # wordmark
    y = 2150
    tx(120, y, 34, "Wordmark · Figtree 700", "#FFFFFF", 700)
    P.append(f'<g transform="translate(120 {y + 30}) scale(1.4)">{lockup("bsh", "horizontal", "#FFFFFF").split(">", 1)[1].rsplit("</svg>", 1)[0]}</g>')
    P.append(f'<rect x="1100" y="{y + 30}" width="1180" height="260" rx="24" fill="#F3F3F7"/>')
    P.append(f'<g transform="translate(1140 {y + 50}) scale(1.4)">{lockup("bsl", "horizontal", "#0F1118").split(">", 1)[1].rsplit("</svg>", 1)[0]}</g>')
    # don'ts
    y = 2560
    tx(120, y, 34, "Don't", "#FFFFFF", 700)
    donts = [("rotate(20 512 512)", "rotate it"), ("translate(512 512) scale(1.35 0.8) translate(-512 -512)", "stretch it"),
             ("", "recolour the page"), ("", "add a play triangle")]
    for i, (tr, n) in enumerate(donts):
        x = 120 + i * 560
        inner = icon_body(f"dn{i}")
        if n == "recolour the page":
            inner = inner.replace('fill="#FFFFFF" mask', 'fill="#F59E0B" mask')
        extra = ""
        if n == "add a play triangle":
            extra = '<path d="M420 420 L420 620 L590 520 Z" fill="#5141DD"/>'
        P.append(f'<g transform="translate({x} {y + 30}) scale(0.3125)"><clipPath id="dc{i}"><rect width="1024" height="1024" rx="229"/></clipPath>'
                 f'<g clip-path="url(#dc{i})"><rect width="1024" height="1024" fill="#5141DD"/><g transform="{tr}">{inner}</g>{extra}</g>'
                 f'<line x1="40" y1="984" x2="984" y2="40" stroke="#EF4444" stroke-width="40" stroke-linecap="round"/></g>')
        tx(x, y + 400, 26, n, "#A9ACBF")
    p = tmp_svg(tmp, "brand.svg", svg("".join(P), W, H))
    subprocess.run([RSVG, "-o", os.path.join(ROOT, "assets/branding/brand_sheet.png"), p], check=True)


if __name__ == "__main__":
    main()
