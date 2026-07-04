#!/usr/bin/env python3
"""Generate the MeshTracker app icon (1024x1024 PNG, drawn at 2048 and downsampled).

Design: deep navy->teal field, faint radar rings, a breadcrumb trail curving up into a
teal location pin (the tag), with LoRa arcs radiating top-right. iOS masks its own corners.

    python3 make_app_icon.py ../ios/MeshTracker/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersampled canvas; output is S/2


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def main(out_path):
    img = Image.new("RGB", (S, S))
    # Vertical gradient: deep navy -> dark teal
    top, bottom = (8, 22, 38), (13, 58, 77)
    px = img.load()
    for y in range(S):
        row = lerp(top, bottom, y / S)
        for x in range(0, S, 8):
            for dx in range(8):
                px[x + dx, y] = row
    draw = ImageDraw.Draw(img, "RGBA")

    cx, cy = S // 2, int(S * 0.42)  # pin head center

    # Faint radar rings around the pin
    for r, alpha, w in ((520, 46, 12), (680, 32, 10), (840, 22, 9)):
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, alpha), width=w)

    # Breadcrumb trail: quadratic curve from bottom-left toward the pin tail
    p0, p1, p2 = (300, 1760), (420, 1280), (985, 1230)
    n = 9
    for i in range(n):
        t = i / (n - 1)
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t**2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t**2 * p2[1]
        r = 12 + 14 * t
        a = int(120 + 110 * t)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=(190, 235, 245, a))

    # Pin shape mask (circle head + tail triangle)
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    R = 330
    md.ellipse([cx - R, cy - R, cx + R, cy + R], fill=255)
    md.polygon([(cx - 235, cy + 235), (cx + 235, cy + 235), (cx, int(S * 0.63) + 320)], fill=255)

    # Teal gradient fill for the pin
    grad = Image.new("RGB", (S, S))
    gtop, gbot = (45, 212, 191), (8, 145, 178)
    gp = grad.load()
    y0, y1 = cy - R, int(S * 0.63) + 320
    for y in range(S):
        t = min(max((y - y0) / max(y1 - y0, 1), 0), 1)
        row = lerp(gtop, gbot, t)
        for x in range(0, S, 16):
            for dx in range(16):
                gp[x + dx, y] = row
    # Soft drop shadow under the pin
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.bitmap((26, 34), mask, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    img = Image.alpha_composite(img.convert("RGBA"), shadow)
    img.paste(grad, (0, 0), mask)
    draw = ImageDraw.Draw(img, "RGBA")

    # Pin hole (white) with a subtle inner dot
    hr = 138
    draw.ellipse([cx - hr, cy - hr, cx + hr, cy + hr], fill=(255, 255, 255, 255))
    draw.ellipse([cx - 48, cy - 48, cx + 48, cy + 48], fill=(11, 44, 60, 255))

    # LoRa arcs radiating top-right of the pin
    for r, w, a in ((470, 34, 235), (610, 30, 190), (750, 26, 140)):
        draw.arc([cx - r, cy - r, cx + r, cy + r], start=-78, end=-14, fill=(125, 211, 252, a), width=w)

    out = img.convert("RGB").resize((S // 2, S // 2), Image.LANCZOS)
    out.save(out_path, "PNG")
    print(f"wrote {out_path} ({S // 2}x{S // 2})")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
