#!/usr/bin/env python3
"""Draw Compagnon's app icon and menu bar icon into Compagnon/Assets.xcassets.

The icons are drawn in code from the same shapes as the character
(CompagnonStyle.swift): a mint gumdrop with navy eyes and a coral antenna bulb,
on a navy rounded square. Standard library only:

    python3 scripts/gen-icons.py
"""
import json
import math
import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(__file__), "..", "Compagnon", "Assets.xcassets")

# Palette (keep in sync with CompagnonStyle.swift)
BODY_TOP = (0.925, 0.984, 0.961)
BODY_BOTTOM = (0.722, 0.886, 0.820)
INK = (0.078, 0.129, 0.239)
ACCENT = (1.000, 0.420, 0.290)
BG_TOP = (0.157, 0.231, 0.388)
BG_BOTTOM = (0.071, 0.110, 0.204)
BLUSH = (1.0, 0.471, 0.588)
TOP_EXP, BOTTOM_EXP = 2.3, 3.6


# ── Geometry helpers (unit space: icon is 1×1, y down) ────────────────────────

def clamp(v, a=0.0, b=1.0):
    return a if v < a else b if v > b else v


def coverage(d, px):
    """Signed distance (negative inside) → antialiased coverage."""
    return clamp(0.5 - d / px)


def superellipse_d(x, y, cx, cy, rx, ry, n_top, n_bottom):
    dx, dy = (x - cx) / rx, (y - cy) / ry
    n = n_bottom if dy > 0 else n_top
    f = (abs(dx) ** n + abs(dy) ** n) ** (1 / n)
    return (f - 1) * min(rx, ry)


def rounded_rect_d(x, y, cx, cy, hw, hh, r):
    qx = abs(x - cx) - (hw - r)
    qy = abs(y - cy) - (hh - r)
    outside = math.hypot(max(qx, 0), max(qy, 0))
    return outside + min(max(qx, qy), 0) - r


def circle_d(x, y, cx, cy, r):
    return math.hypot(x - cx, y - cy) - r


def bezier_points(p0, p1, p2, steps=40):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        a, b, c = (1 - t) ** 2, 2 * (1 - t) * t, t * t
        pts.append((a * p0[0] + b * p1[0] + c * p2[0], a * p0[1] + b * p1[1] + c * p2[1]))
    return pts


def segment_d(x, y, a, b):
    ax, ay = a
    bx, by = b
    vx, vy = bx - ax, by - ay
    t = clamp(((x - ax) * vx + (y - ay) * vy) / (vx * vx + vy * vy + 1e-12))
    return math.hypot(x - (ax + t * vx), y - (ay + t * vy))


def over(dst, src, a):
    """Composite colour `src` with alpha `a` over premultiplied `dst` (r, g, b, a)."""
    r, g, b, da = dst
    return (src[0] * a + r * (1 - a), src[1] * a + g * (1 - a), src[2] * a + b * (1 - a), a + da * (1 - a))


def lerp3(c0, c1, t):
    return tuple(c0[i] + (c1[i] - c0[i]) * t for i in range(3))


# ── The character, in unit space ──────────────────────────────────────────────

def character(cx, cy, rx):
    """Shapes for a character centred at (cx, cy) with half-width rx."""
    R = rx / 1.14
    ry = R * 0.88
    length = ry * 0.50
    base = (cx, cy - ry * 0.96)
    angle = 0.18
    tip = (base[0] + math.sin(angle) * length, base[1] - math.cos(angle) * length)
    ctrl = (base[0] + math.sin(angle) * length * 0.25, base[1] - length * 0.6)
    eye_w, eye_h = R * 0.22, R * 0.30
    eye_x = math.sin(0.35) * rx
    eye_y = cy + math.sin(0.10) * ry
    return {
        "R": R, "rx": rx, "ry": ry, "cx": cx, "cy": cy,
        "stalk": bezier_points(base, ctrl, tip), "stalk_w": ry * 0.075,
        "tip": tip, "bulb_r": ry * 0.15,
        "eyes": [(cx - eye_x, eye_y), (cx + eye_x, eye_y)], "eye_w": eye_w, "eye_h": eye_h,
    }


def stalk_d(x, y, ch):
    pts = ch["stalk"]
    return min(segment_d(x, y, pts[i], pts[i + 1]) for i in range(len(pts) - 1)) - ch["stalk_w"] / 2


def body_d(x, y, ch):
    return superellipse_d(x, y, ch["cx"], ch["cy"], ch["rx"], ch["ry"], TOP_EXP, BOTTOM_EXP)


def eyes_d(x, y, ch):
    w, h = ch["eye_w"], ch["eye_h"]
    return min(rounded_rect_d(x, y, ex, ey, w / 2, h / 2, w / 2) for ex, ey in ch["eyes"])


def glints_d(x, y, ch):
    w, h = ch["eye_w"], ch["eye_h"]
    r = w * 0.17
    return min(circle_d(x, y, ex + w * 0.12, ey - h * 0.24, r) for ex, ey in ch["eyes"])


# ── App icon ──────────────────────────────────────────────────────────────────

def app_icon_pixel(x, y, px):
    col = (0.0, 0.0, 0.0, 0.0)
    # macOS icon grid: 824/1024 rounded square, corner radius ≈ 185/1024
    bg_d = rounded_rect_d(x, y, 0.5, 0.5, 0.4023, 0.4023, 0.1807)
    a = coverage(bg_d, px)
    if a <= 0:
        return col
    bg = lerp3(BG_TOP, BG_BOTTOM, clamp((y - 0.1) / 0.8))
    col = over(col, bg, a)

    ch = CHAR
    # Soft glow behind the bulb
    gd = math.hypot(x - ch["tip"][0], y - ch["tip"][1])
    glow = clamp(1 - gd / (ch["bulb_r"] * 3.2)) ** 2 * 0.55
    col = over(col, ACCENT, glow * a)
    # Shadow under the body
    sd = superellipse_d(x, y, ch["cx"], ch["cy"] + ch["ry"] * 1.02, ch["rx"] * 0.8, ch["ry"] * 0.16, 2, 2)
    col = over(col, (0, 0, 0), clamp(-sd / (ch["ry"] * 0.3)) * 0.35 * a)
    # Stalk
    col = over(col, INK, coverage(stalk_d(x, y, ch), px) * a)
    # Bulb with highlight
    bd = circle_d(x, y, ch["tip"][0], ch["tip"][1], ch["bulb_r"])
    ba = coverage(bd, px)
    if ba > 0:
        hl = clamp(1 - math.hypot(x - (ch["tip"][0] + ch["bulb_r"] * 0.3),
                                  y - (ch["tip"][1] - ch["bulb_r"] * 0.35)) / (ch["bulb_r"] * 0.9))
        col = over(col, lerp3(ACCENT, (1, 1, 1), hl * 0.7), ba * a)
    # Body
    bda = coverage(body_d(x, y, ch), px)
    if bda > 0:
        t = clamp(((ch["cx"] + ch["rx"] * 0.7 - x) + (y - ch["cy"] + ch["ry"] * 0.85)) / (ch["rx"] * 1.5 + ch["ry"] * 1.75))
        body = lerp3(BODY_TOP, BODY_BOTTOM, t)
        # top-right highlight
        h = clamp(1 - math.hypot(x - (ch["cx"] + ch["rx"] * 0.34), y - (ch["cy"] - ch["ry"] * 0.46)) / (ch["R"] * 0.5))
        body = lerp3(body, (1, 1, 1), h * 0.5)
        # rim shade
        dn = clamp(-body_d(x, y, ch) / (ch["R"] * 0.35))
        body = lerp3(body, (body[0] * 0.8, body[1] * 0.8, body[2] * 0.8), (1 - dn) * 0.6)
        col = over(col, body, bda * a)
        # Blush
        for sd_ in (-1, 1):
            bl = superellipse_d(x, y, ch["cx"] + sd_ * ch["rx"] * 0.55, ch["cy"] + ch["ry"] * 0.25,
                                ch["R"] * 0.17, ch["R"] * 0.10, 2, 2)
            col = over(col, BLUSH, clamp(-bl / (ch["R"] * 0.08)) * 0.35 * bda * a)
        # Eyes and glints
        col = over(col, INK, coverage(eyes_d(x, y, ch), px) * bda * a)
        col = over(col, (1, 1, 1), coverage(glints_d(x, y, ch), px) * 0.9 * bda * a)
    return col


# ── Menu bar template (black silhouette, eyes cut out) ────────────────────────

def menubar_pixel(x, y, px):
    ch = MENU_CHAR
    shape = min(body_d(x, y, ch), stalk_d(x, y, ch),
                circle_d(x, y, ch["tip"][0], ch["tip"][1], ch["bulb_r"] * 1.15))
    a = coverage(shape, px)
    a *= 1 - coverage(eyes_d(x, y, ch), px)
    return (0.0, 0.0, 0.0, a)


# ── PNG output ────────────────────────────────────────────────────────────────

def render(size, fn):
    px = 1.0 / size
    rows = []
    for j in range(size):
        row = bytearray([0])
        y = (j + 0.5) * px
        for i in range(size):
            r, g, b, a = fn((i + 0.5) * px, y, px)
            if a > 0:
                r, g, b = r / a, g / a, b / a  # un-premultiply
            row += bytes(int(clamp(v) * 255 + 0.5) for v in (r, g, b, a))
        rows.append(bytes(row))
    return rows


def write_png(path, size, rows):
    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


CHAR = character(0.5, 0.585, 0.255)
MENU_CHAR = character(0.5, 0.64, 0.40)


def main():
    app_dir = os.path.join(ROOT, "AppIcon.appiconset")
    images = []
    cache = {}
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            size = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            if size not in cache:
                cache[size] = render(size, app_icon_pixel)
            write_png(os.path.join(app_dir, name), size, cache[size])
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}", "filename": name})
    with open(os.path.join(app_dir, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")

    menu_dir = os.path.join(ROOT, "MenuBarIcon.imageset")
    images = []
    for scale in (1, 2, 3):
        size = 18 * scale
        name = f"menubar{'' if scale == 1 else f'@{scale}x'}.png"
        write_png(os.path.join(menu_dir, name), size, render(size, menubar_pixel))
        images.append({"idiom": "universal", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(menu_dir, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1},
                   "properties": {"template-rendering-intent": "template"}}, f, indent=2)
        f.write("\n")
    print("Icons written to", os.path.normpath(ROOT))


if __name__ == "__main__":
    main()
