#!/usr/bin/env python3
"""Render every MB Notes app icon theme.

Usage: python3 Scripts/render_icon.py [asset-catalog-dir]
Defaults to MBNotes/Resources/Assets.xcassets. Requires Pillow.

The default theme ("sunset") becomes AppIcon with dark and tinted
appearances. Every other theme becomes an alternate icon set named
AppIcon-<Theme>, plus an IconPreview-<Theme> image the in-app picker shows.
Keep THEMES in sync with AppIconTheme.swift.
"""

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # supersampling factor
W = SIZE * SS

THEMES = {
    "sunset": dict(bg=((255, 166, 120), (247, 108, 160), (128, 86, 246)), paper=(255, 253, 247), rule=(160, 196, 236),
                   margin=(244, 140, 140), ink=(76, 58, 214), sticker="star", sticker_fill=(255, 196, 40)),
    "midnight": dict(bg=((58, 36, 72), (40, 30, 78), (20, 20, 44)), paper=(236, 232, 244), rule=(150, 170, 220),
                     margin=(226, 120, 130), ink=(90, 70, 210), sticker="star", sticker_fill=(255, 202, 70),
                     sticker_outline=(246, 242, 252), back_alpha=60, sheen=0.08),
    "mint": dict(bg=((168, 240, 200), (72, 206, 186), (40, 140, 200)), paper=(250, 255, 252), rule=(150, 210, 200),
                 margin=(240, 150, 160), ink=(24, 120, 110), sticker="heart", sticker_fill=(255, 112, 150)),
    "ocean": dict(bg=((130, 210, 255), (60, 130, 246), (48, 52, 180)), paper=(252, 253, 255), rule=(160, 190, 236),
                  margin=(244, 150, 150), ink=(30, 50, 150), sticker="star", sticker_fill=(255, 210, 60)),
    "lemonade": dict(bg=((255, 236, 120), (255, 190, 80), (255, 128, 90)), paper=(255, 252, 240), rule=(236, 200, 140),
                     margin=(240, 130, 120), ink=(160, 70, 40), sticker="heart", sticker_fill=(255, 92, 120)),
    "bubblegum": dict(bg=((255, 196, 228), (240, 150, 220), (186, 140, 255)), paper=(255, 250, 253), rule=(230, 180, 220),
                      margin=(240, 140, 180), ink=(150, 60, 190), sticker="flower", sticker_fill=(255, 255, 255),
                      sticker_center=(255, 200, 60)),
    "kraft": dict(bg=((214, 176, 128), (184, 140, 96), (140, 100, 70)), paper=(250, 244, 230), rule=(200, 180, 150),
                  margin=(214, 120, 100), ink=(90, 60, 40), sticker="heart", sticker_fill=(226, 70, 70)),
    "graphite": dict(bg=((120, 124, 132), (70, 72, 80), (28, 28, 32)), paper=(250, 250, 250), rule=(200, 200, 205),
                     margin=(210, 210, 214), ink=(30, 30, 34), sticker="star", sticker_fill=(250, 250, 250),
                     sticker_outline=(60, 60, 66)),
}


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def gradient(c0, c1, c2):
    # Build a small diagonal gradient and upscale it; smooth enough for an icon.
    small = 256
    grad = Image.new("RGB", (small, small))
    px = grad.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * small)
            px[x, y] = lerp(c0, c1, t * 2) if t < 0.5 else lerp(c1, c2, (t - 0.5) * 2)
    return grad.resize((W, W), Image.BICUBIC)


def rounded_rect_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def brush_stroke(draw, points, width, color):
    """Stamp round dabs along the path so thick strokes have no joint artifacts."""
    r = width / 2
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        steps = max(1, int(math.hypot(x1 - x0, y1 - y0) / (r * 0.25)))
        for i in range(steps):
            t = i / steps
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            draw.ellipse([x - r, y - r, x + r, y + r], fill=color)
    x, y = points[-1]
    draw.ellipse([x - r, y - r, x + r, y + r], fill=color)


def page_layer(theme):
    pw, ph = int(560 * SS), int(700 * SS)
    page = Image.new("RGBA", (pw, ph), theme["paper"] + (255,))
    d = ImageDraw.Draw(page)
    top, spacing = int(150 * SS), int(62 * SS)
    for y in range(top, ph - int(40 * SS), spacing):
        d.line([(int(36 * SS), y), (pw - int(36 * SS), y)], fill=theme["rule"] + (255,), width=int(5 * SS))
    mx = int(108 * SS)
    d.line([(mx, int(30 * SS)), (mx, ph - int(30 * SS))], fill=theme["margin"] + (255,), width=int(5 * SS))

    # One bold, loopy ink stroke: a prolate cycloid reads as handwriting at any size.
    baseline = top + spacing * 2 - int(8 * SS)
    x0 = mx + int(48 * SS)
    loops, step, radius = 3, 96 * SS, 62 * SS
    stroke = []
    n = 600
    for i in range(n + 1):
        t = i / n * loops * 2 * math.pi
        x = x0 + step * t / (2 * math.pi) - radius * 0.62 * math.sin(t)
        y = baseline - radius * 0.55 * (1 - math.cos(t))
        stroke.append((x, y))
    tail = stroke[-1]
    for i in range(1, 41):
        t = i / 40
        stroke.append((tail[0] + 64 * SS * t, tail[1] - 16 * SS * math.sin(t * math.pi / 2)))
    brush_stroke(d, stroke, 26 * SS, theme["ink"] + (255,))

    page.putalpha(ImageChops.multiply(page.getchannel("A"), rounded_rect_mask((pw, ph), int(54 * SS))))
    return page


def star_points(cx, cy, r_outer, r_inner):
    pts = []
    for i in range(10):
        r = r_outer if i % 2 == 0 else r_inner
        a = -math.pi / 2 + i * math.pi / 5
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    return pts


def heart_points(cx, cy, scale):
    pts = []
    for i in range(200):
        t = i / 200 * 2 * math.pi
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((cx + x * scale, cy - y * scale - scale * 1.5))
    return pts


def draw_shape(draw, kind, c, size, fill):
    if kind == "star":
        draw.polygon(star_points(c, c, size, size * 0.5), fill=fill)
    elif kind == "heart":
        draw.polygon(heart_points(c, c, size / 16), fill=fill)
    elif kind == "flower":
        for i in range(5):
            a = -math.pi / 2 + i * 2 * math.pi / 5
            px, py = c + math.cos(a) * size * 0.52, c + math.sin(a) * size * 0.52
            r = size * 0.46
            draw.ellipse([px - r, py - r, px + r, py + r], fill=fill)


def sticker_layer(theme):
    s = int(300 * SS)
    c = s / 2
    kind = theme["sticker"]
    outline = theme.get("sticker_outline", (255, 255, 255))
    base = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw_shape(ImageDraw.Draw(base), kind, c, 116 * SS, outline + (255,))
    # Grow the silhouette to get a white die-cut border.
    border = base.filter(ImageFilter.MaxFilter(int(19 * SS) | 1))
    art = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ad = ImageDraw.Draw(art)
    draw_shape(ad, kind, c, 112 * SS, theme["sticker_fill"] + (255,))
    if kind == "flower":
        # White petals need a visible edge, then a yellow center.
        petals = art.filter(ImageFilter.MaxFilter(int(7 * SS) | 1))
        tint = Image.new("RGBA", (s, s), theme["ink"] + (255,))
        tint.putalpha(petals.getchannel("A"))
        border.alpha_composite(tint)
        r = 40 * SS
        ad.ellipse([c - r, c - r, c + r, c + r], fill=theme["sticker_center"] + (255,))
    border.alpha_composite(art)
    return border


def shadow_of(layer, blur, opacity):
    pad = int(blur * 3)
    alpha = Image.new("L", (layer.width + pad * 2, layer.height + pad * 2), 0)
    alpha.paste(layer.getchannel("A").point(lambda a: int(a * opacity)), (pad, pad))
    alpha = alpha.filter(ImageFilter.GaussianBlur(blur))
    shadow = Image.new("RGBA", alpha.size, (40, 12, 60, 255))
    shadow.putalpha(alpha)
    return shadow


def paste_rotated(canvas, layer, center, angle, shadow=None):
    if shadow is not None:
        blur, opacity, offset = shadow
        sh = shadow_of(layer, blur * SS, opacity).rotate(angle, resample=Image.BICUBIC, expand=True)
        canvas.alpha_composite(sh, (int(center[0] - sh.width / 2 + offset[0] * SS), int(center[1] - sh.height / 2 + offset[1] * SS)))
    rot = layer.rotate(angle, resample=Image.BICUBIC, expand=True)
    canvas.alpha_composite(rot, (int(center[0] - rot.width / 2), int(center[1] - rot.height / 2)))


def render(theme, grayscale=False):
    canvas = gradient(*theme["bg"]).convert("RGBA")
    fade = Image.linear_gradient("L").resize((W, W)).point(lambda v: int((255 - v) * theme.get("sheen", 0.22)))
    sheen = Image.new("RGBA", (W, W), (255, 255, 255, 0))
    sheen.putalpha(fade)
    canvas.alpha_composite(sheen)

    back = Image.new("RGBA", (int(560 * SS), int(700 * SS)), (255, 255, 255, theme.get("back_alpha", 120)))
    back.putalpha(ImageChops.multiply(back.getchannel("A"), rounded_rect_mask(back.size, int(54 * SS))))
    paste_rotated(canvas, back, (W * 0.54, W * 0.52), -2)
    paste_rotated(canvas, page_layer(theme), (W * 0.47, W * 0.53), 8, shadow=(26, 0.35, (0, 18)))
    paste_rotated(canvas, sticker_layer(theme), (W * 0.72, W * 0.27), -14, shadow=(10, 0.3, (0, 8)))

    img = canvas.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    return img.convert("L").convert("RGB") if grayscale else img


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2) + "\n")


def main():
    catalog = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "MBNotes/Resources/Assets.xcassets"
    info = {"author": "xcode", "version": 1}
    for name, theme in THEMES.items():
        title = name.capitalize()
        icon = render(theme)
        if name == "sunset":
            out = catalog / "AppIcon.appiconset"
            out.mkdir(parents=True, exist_ok=True)
            icon.save(out / "AppIcon.png")
            render(THEMES["midnight"]).save(out / "AppIcon-Dark.png")
            render(theme, grayscale=True).save(out / "AppIcon-Tinted.png")
            write_json(out / "Contents.json", {"images": [
                {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
                {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-Dark.png",
                 "idiom": "universal", "platform": "ios", "size": "1024x1024"},
                {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-Tinted.png",
                 "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            ], "info": info})
        else:
            out = catalog / f"AppIcon-{title}.appiconset"
            out.mkdir(parents=True, exist_ok=True)
            icon.save(out / f"AppIcon-{title}.png")
            write_json(out / "Contents.json", {"images": [
                {"filename": f"AppIcon-{title}.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            ], "info": info})
        preview = catalog / f"IconPreview-{title}.imageset"
        preview.mkdir(parents=True, exist_ok=True)
        icon.resize((256, 256), Image.LANCZOS).save(preview / f"IconPreview-{title}.png")
        write_json(preview / "Contents.json", {"images": [
            {"filename": f"IconPreview-{title}.png", "idiom": "universal"},
        ], "info": info})
        print("rendered", name)


if __name__ == "__main__":
    main()
