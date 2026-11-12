#!/usr/bin/env python3
"""
Generate the app icon (v2): a bold orange navigation arrow flying over a cyan
radar crosshair, on a deep-space navy rounded-square background. Renders at 4x
and downsamples for clean edges, writes a 1024px PNG, a README logo.png, and
builds a full .iconset for `iconutil`.
"""
import math
import os

from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(REPO, "assets")
SS = 4               # supersample factor
BASE = 1024


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def squircle_mask(size, n=5.0):
    """Apple-style superellipse (squircle) mask, filled row by row."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    a = size / 2.0
    c = (size - 1) / 2.0
    for y in range(size):
        ny = (y - c) / a
        v = 1.0 - abs(ny) ** n
        if v <= 0:
            continue
        nx = v ** (1.0 / n)
        d.line([(c - nx * a, y), (c + nx * a, y)], fill=255)
    return m


def rotate(points, cx, cy, deg):
    """Rotate a list of (x, y) points around (cx, cy) by deg degrees."""
    rad = math.radians(deg)
    cos, sin = math.cos(rad), math.sin(rad)
    return [(cx + (x - cx) * cos - (y - cy) * sin,
             cy + (x - cx) * sin + (y - cy) * cos) for x, y in points]


def render(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad = Image.new("RGBA", (size, size))
    gd = ImageDraw.Draw(grad)
    # Deep-space navy gradient, slightly darker toward the bottom.
    top, bottom = (30, 41, 89), (12, 16, 38)
    for y in range(size):
        gd.line([(0, y), (size, y)], fill=lerp(top, bottom, y / size) + (255,))
    img.paste(grad, (0, 0), squircle_mask(size))

    d = ImageDraw.Draw(img, "RGBA")
    cx = cy = size / 2.0

    # Two thin cyan crosshair rings.
    for rr, alpha in [(0.310, 210), (0.420, 110)]:
        R = size * rr
        width = max(1, int(size * 0.012))
        d.ellipse([cx - R, cy - R, cx + R, cy + R],
                  outline=(34, 211, 238, alpha), width=width)

    # Tick marks on the outer ring: N / E / S / W.
    Rt = size * 0.420
    tick = size * 0.038
    width = max(1, int(size * 0.014))
    for angle in (0, 90, 180, 270):
        rad = math.radians(angle)
        x1 = cx + math.cos(rad) * (Rt - tick)
        y1 = cy + math.sin(rad) * (Rt - tick)
        x2 = cx + math.cos(rad) * (Rt + tick)
        y2 = cy + math.sin(rad) * (Rt + tick)
        d.line([(x1, y1), (x2, y2)], fill=(34, 211, 238, 230), width=width)

    # Bold navigation arrow, pointing to the upper right. Shallow tail notch
    # (not a deep cursor cut) so it reads as a paper plane / compass needle.
    r = size * 0.210
    upright = [
        (cx, cy - r),                    # tip
        (cx - r * 0.92, cy + r * 0.80),  # left wing
        (cx, cy + r * 0.55),             # shallow tail notch
        (cx + r * 0.92, cy + r * 0.80),  # right wing
    ]
    arrow = rotate(upright, cx, cy, 45)  # +45° -> tip points to NE
    d.polygon(arrow, fill=(251, 146, 60, 255))
    # Crisp white outline so the arrow pops off the dark background.
    d.line(list(arrow) + [arrow[0]], fill=(255, 255, 255, 230),
           width=max(1, int(size * 0.016)), joint="curve")
    # Small cyan dot in the tail notch — the "live position" marker.
    dot_r = size * 0.032
    d.ellipse([cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r],
              fill=(34, 211, 238, 255))
    return img


def main():
    os.makedirs(ASSETS, exist_ok=True)
    big = render(BASE * SS)
    base = big.resize((BASE, BASE), Image.LANCZOS)
    base.save(os.path.join(ASSETS, "icon_1024.png"))
    big.resize((512, 512), Image.LANCZOS).save(os.path.join(ASSETS, "logo.png"))

    iconset = os.path.join(ASSETS, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for px, name in specs:
        big.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    print("wrote", os.path.join(ASSETS, "icon_1024.png"))
    print("wrote", os.path.join(ASSETS, "logo.png"))
    print("wrote", iconset)


if __name__ == "__main__":
    main()
