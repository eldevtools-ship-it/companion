#!/usr/bin/env python3
"""Draw Compagnon's icons from the cloud character (CompagnonStyle.swift).

- App icon: a white cloud with sober eyes on a black rounded square.
- Menu bar icon: the cloud as a template silhouette (eyes cut out), 24 × 18 pt.
- docs/personnage.png: the cloud in four states, for the README.

Standard library only:

    python3 scripts/gen-icons.py
"""
import json
import math
import os
import struct
import zlib

HERE = os.path.dirname(__file__)
ROOT = os.path.join(HERE, "..", "Compagnon", "Assets.xcassets")
DOCS = os.path.join(HERE, "..", "docs")

# Palette (keep in sync with CompagnonStyle.swift)
BODY_TOP = (1.000, 1.000, 1.000)
BODY_BOTTOM = (0.851, 0.851, 0.957)
INK = (0.149, 0.165, 0.267)

# Cloud puffs in unit space (x −1.06…1.06, y −0.78…0.84), same as CompagnonStyle.cloudPuffs
PUFFS = [(-0.60, 0.18, 0.46), (0.60, 0.18, 0.46), (-0.24, -0.20, 0.58), (0.30, -0.12, 0.52), (0.00, 0.24, 0.60)]


# ── Helpers (unit space: y down) ──────────────────────────────────────────────

def clamp(v, a=0.0, b=1.0):
    return a if v < a else b if v > b else v


def coverage(d, px):
    """Signed distance (negative inside) → antialiased coverage."""
    return clamp(0.5 - d / px)


def rounded_rect_d(x, y, cx, cy, hw, hh, r):
    qx = abs(x - cx) - (hw - r)
    qy = abs(y - cy) - (hh - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def over(dst, src, a):
    """Composite colour `src` with alpha `a` over premultiplied `dst` (r, g, b, a)."""
    r, g, b, da = dst
    return (src[0] * a + r * (1 - a), src[1] * a + g * (1 - a), src[2] * a + b * (1 - a), a + da * (1 - a))


def lerp3(c0, c1, t):
    return tuple(c0[i] + (c1[i] - c0[i]) * t for i in range(3))


# ── The cloud ─────────────────────────────────────────────────────────────────

class Cloud:
    """A cloud centred at (cx, cy), half-width rx (the app's main character)."""

    def __init__(self, cx, cy, rx):
        self.cx, self.cy, self.rx = cx, cy, rx
        self.s = rx / 1.06                  # unit → icon space
        self.R = rx / 1.14                  # BotEngine's R
        self.ry = self.R * 0.88
        ew, eh = self.R * 0.22, self.R * 0.30
        ex = math.sin(0.35) * rx
        ey = cy + math.sin(0.10) * self.ry
        self.eyes = [(cx - ex, ey), (cx + ex, ey)]
        self.eye_w, self.eye_h = ew, eh

    def d(self, x, y):
        s = self.s
        ux, uy = (x - self.cx) / s, (y - self.cy) / s + 0.03
        return min(math.hypot(ux - px, uy - py) - r for px, py, r in PUFFS) * s

    def eyes_d(self, x, y):
        w, h = self.eye_w, self.eye_h
        return min(rounded_rect_d(x, y, ex, ey, w / 2, h / 2, w / 2) for ex, ey in self.eyes)

    def paint(self, col, x, y, px, tint=None, alpha=1.0):
        """Lit body (soft key light top left, lavender shadows, inner rim) and eyes."""
        a = coverage(self.d(x, y), px) * alpha
        if a <= 0:
            return col
        t = clamp(((self.cx + self.rx * 0.6 - x) + (y - self.cy + self.ry)) / (self.rx * 1.2 + self.ry * 2.0))
        body = lerp3(BODY_TOP, BODY_BOTTOM, t)
        if tint:
            k = clamp((y - (self.cy - self.ry)) / (self.ry * 2.0)) ** 1.4 * 0.85
            body = lerp3(body, tint, k)
        key = clamp(1 - math.hypot(x - (self.cx - self.rx * 0.34), y - (self.cy - self.ry * 0.5)) / (self.R * 0.75))
        body = lerp3(body, (1, 1, 1), key * 0.6)
        depth = clamp(-self.d(x, y) / (self.R * 0.12))
        rim_top = clamp((self.cy - y) / self.ry) * (1 - depth)
        body = lerp3(body, (1, 1, 1), rim_top * 0.7)
        rim_bottom = clamp((y - self.cy) / self.ry) * (1 - depth)
        body = lerp3(body, lerp3(body, BODY_BOTTOM, 1.0), rim_bottom * 0.6)
        col = over(col, body, a)
        return over(col, INK, coverage(self.eyes_d(x, y), px) * a)


# ── App icon ──────────────────────────────────────────────────────────────────

APP_CLOUD = Cloud(0.5, 0.52, 0.27)


def app_icon_pixel(x, y, px):
    col = (0.0, 0.0, 0.0, 0.0)
    # macOS icon grid: 824/1024 rounded square, corner radius ≈ 185/1024
    bg_d = rounded_rect_d(x, y, 0.5, 0.5, 0.4023, 0.4023, 0.1807)
    a = coverage(bg_d, px)
    if a <= 0:
        return col
    # Black, with the faintest lift at the top so the square reads on a dark Dock
    bg = lerp3((0.075, 0.075, 0.085), (0.0, 0.0, 0.0), clamp((y - 0.1) / 0.55))
    col = over(col, bg, a)
    # Hairline edge light along the top
    edge = clamp(1 - abs(bg_d + px * 1.5) / (px * 1.5)) * clamp((0.5 - y) / 0.4) * 0.35
    col = over(col, (1, 1, 1), edge * a)
    c = APP_CLOUD
    # Soft white glow behind the cloud, and a shadow under it
    glow = clamp(1 - math.hypot(x - c.cx, (y - c.cy) * 1.3) / (c.rx * 1.6)) ** 2 * 0.12
    col = over(col, (0.85, 0.85, 1.0), glow * a)
    sh = clamp(1 - math.hypot((x - c.cx) / (c.rx * 0.85), (y - (c.cy + c.ry * 1.12)) / (c.ry * 0.16)))
    col = over(col, (0, 0, 0), sh * 0.5 * a)
    return c.paint(col, x, y, px, alpha=a)


# ── Menu bar template (black silhouette, eyes cut out) ────────────────────────

MENU_W, MENU_H = 24, 18
MENU_CLOUD = Cloud(0.5, 0.5, 0.46)   # in a 24×18 box: units are the box width


def menubar_pixel(x, y, px):
    c = MENU_CLOUD
    a = coverage(c.d(x, y), px)
    a *= 1 - coverage(c.eyes_d(x, y), px)
    return (0.0, 0.0, 0.0, a)


# ── README picture: the cloud in four states ──────────────────────────────────

STATES = [None, (0.231, 0.620, 1.0), (0.961, 0.647, 0.141), (0.204, 0.831, 0.600)]  # rest, working, waiting, done
PIC_W, PIC_H = 960, 240


def personnage_pixel(x, y, px):
    # x in 0…4 (one cell per state), y in 0…1
    col = (0.0, 0.0, 0.0, 1.0)
    i = min(3, int(x))
    cell = Cloud(i + 0.5, 0.52, 0.27)
    tint = STATES[i]
    if tint:
        g = clamp(1 - math.hypot(x - cell.cx, (y - (cell.cy + cell.ry)) * 2.2) / (cell.rx * 1.4)) ** 2 * 0.35
        col = over(col, tint, g)
    return cell.paint(col, x, y, px, tint=tint)


# ── PNG output ────────────────────────────────────────────────────────────────

def render(w, h, fn, unit_w=None):
    """Render a w×h image; x and y are in units where the image width is `unit_w` (default 1)."""
    unit_w = unit_w or 1.0
    px = unit_w / w
    rows = []
    for j in range(h):
        row = bytearray([0])
        y = (j + 0.5) * px
        for i in range(w):
            r, g, b, a = fn((i + 0.5) * px, y, px)
            if a > 0:
                r, g, b = r / a, g / a, b / a  # un-premultiply
            row += bytes(int(clamp(v) * 255 + 0.5) for v in (r, g, b, a))
        rows.append(bytes(row))
    return rows


def write_png(path, w, h, rows):
    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def main():
    app_dir = os.path.join(ROOT, "AppIcon.appiconset")
    images, cache = [], {}
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            size = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            if size not in cache:
                cache[size] = render(size, size, app_icon_pixel)
            write_png(os.path.join(app_dir, name), size, size, cache[size])
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}", "filename": name})
    with open(os.path.join(app_dir, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")

    menu_dir = os.path.join(ROOT, "MenuBarIcon.imageset")
    images = []
    for scale in (1, 2, 3):
        w, h = MENU_W * scale, MENU_H * scale
        name = f"menubar{'' if scale == 1 else f'@{scale}x'}.png"
        # Units: box width = 1, so the cloud's y centre is at (H/W)/2
        global MENU_CLOUD
        MENU_CLOUD = Cloud(0.5, (MENU_H / MENU_W) / 2 + 0.01, 0.40)
        write_png(os.path.join(menu_dir, name), w, h, render(w, h, menubar_pixel))
        images.append({"idiom": "universal", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(menu_dir, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1},
                   "properties": {"template-rendering-intent": "template"}}, f, indent=2)
        f.write("\n")

    write_png(os.path.join(DOCS, "personnage.png"), PIC_W, PIC_H,
              render(PIC_W, PIC_H, personnage_pixel, unit_w=4.0))
    print("Icons written to", os.path.normpath(ROOT), "and docs/personnage.png")


if __name__ == "__main__":
    main()
