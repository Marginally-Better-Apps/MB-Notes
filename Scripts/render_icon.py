#!/usr/bin/env python3
"""Render every MB Notes app icon theme.

Usage: python3 Scripts/render_icon.py [asset-catalog-dir]
Defaults to MBNotes/Resources/Assets.xcassets. Requires Pillow.

The icon is a single sheet of ruled paper on a flat theme color. The only colored
mark on the page is the margin rule, a nod to "Marginally better". No text, no
gradients, no decoration, so it reads cleanly at every size.

Each theme produces an icon set with light, dark, and tinted appearances. The
default theme ("iris") is AppIcon; the rest are AppIcon-<Theme>. Every theme also
gets an IconPreview-<Theme> image for the in-app picker. Keep THEMES in sync with
AppTheme in MBNotes/Shared/Theme.swift and the alternate icon list in project.yml.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # supersampling factor
W = SIZE * SS

DEFAULT = "iris"

# icon_bg: the flat background. mark: the margin rule in light mode.
# mark_dark: the margin rule on the dark appearance. page: paper color in light mode.
THEMES = {
    "iris": dict(icon_bg="#6A45E0", mark="#6A45E0", mark_dark="#A08BFF"),
    "graphite": dict(icon_bg="#2C2C2E", mark="#2C2C2E", mark_dark="#D1D1D6"),
    "ocean": dict(icon_bg="#0A62C9", mark="#0A62C9", mark_dark="#5AA9FF"),
    "sage": dict(icon_bg="#2E7650", mark="#2E7650", mark_dark="#6CCB98"),
    "lagoon": dict(icon_bg="#00747F", mark="#00747F", mark_dark="#4FCFD6"),
    "ember": dict(icon_bg="#D2531F", mark="#B8471A", mark_dark="#FF9466"),
    "cherry": dict(icon_bg="#BE1E3D", mark="#BE1E3D", mark_dark="#FF6F87"),
    "rose": dict(icon_bg="#B5336D", mark="#B5336D", mark_dark="#F584B4"),
    "honey": dict(icon_bg="#E0A21B", mark="#8C5A00", mark_dark="#F2B53A"),
    "plum": dict(icon_bg="#7E3A9C", mark="#7E3A9C", mark_dark="#D08BF0"),
    "indigo": dict(icon_bg="#3D4DB7", mark="#3D4DB7", mark_dark="#8D9BFF"),
    "sepia": dict(icon_bg="#8A6142", mark="#7F5537", mark_dark="#D7A982", page="#FBF6EC"),
}

INK = "#1C1C1E"
RULE = "#D8D8DE"


def rgb(hex_color):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def s(v):
    """Scale a 1024-space coordinate to the supersampled canvas."""
    return int(round(v * SS))


def capped_line(draw, p0, p1, width, color):
    """A line with round caps."""
    draw.line([(s(p0[0]), s(p0[1])), (s(p1[0]), s(p1[1]))], fill=color, width=s(width))
    r = s(width) / 2
    for x, y in (p0, p1):
        draw.ellipse([s(x) - r, s(y) - r, s(x) + r, s(y) + r], fill=color)


def render(theme, mode):
    """mode is 'light', 'dark', or 'tinted'."""
    if mode == "light":
        background = rgb(theme["icon_bg"]) + (255,)
        page, rule, ink, mark = rgb(theme.get("page", "#FFFFFF")), rgb(RULE), rgb(INK), rgb(theme["mark"])
        shadow = True
    elif mode == "dark":
        # iOS supplies the dark backdrop; the icon itself is transparent around the page.
        background = (0, 0, 0, 0)
        page, rule, ink, mark = rgb("#2C2C2E"), rgb("#48484A"), rgb("#EBEBF0"), rgb(theme["mark_dark"])
        shadow = False
    else:
        # Tinted icons are grayscale on black; the brightest pixels take the most tint.
        background = (0, 0, 0, 255)
        page, rule, ink, mark = rgb("#4A4A4A"), rgb("#2A2A2A"), rgb("#FFFFFF"), rgb("#FFFFFF")
        shadow = False

    canvas = Image.new("RGBA", (W, W), background)

    page_box = (262, 192, 762, 832)
    if shadow:
        sh = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle([s(page_box[0]), s(page_box[1] + 12), s(page_box[2]), s(page_box[3] + 12)], radius=s(64), fill=(0, 0, 0, 26))
        canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(s(24))))

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle([s(page_box[0]), s(page_box[1]), s(page_box[2]), s(page_box[3])], radius=s(64), fill=page + (255,))
    capped_line(draw, (382, 322), (602, 322), 30, ink + (255,))
    for y in (412, 492, 572, 652):
        capped_line(draw, (382, y), (702, y), 14, rule + (255,))
    capped_line(draw, (342, 252), (342, 772), 20, mark + (255,))

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2) + "\n")


def icon_set(catalog, name):
    return catalog / ("AppIcon.appiconset" if name == DEFAULT else f"AppIcon-{name.capitalize()}.appiconset")


def main():
    catalog = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "MBNotes/Resources/Assets.xcassets"
    info = {"author": "xcode", "version": 1}
    for name, theme in THEMES.items():
        title = name.capitalize()
        out = icon_set(catalog, name)
        out.mkdir(parents=True, exist_ok=True)
        base = "AppIcon" if name == DEFAULT else f"AppIcon-{title}"
        light = render(theme, "light")
        # The light image sits on an opaque background, so drop alpha for the catalog.
        light.convert("RGB").save(out / f"{base}.png")
        render(theme, "dark").save(out / f"{base}-Dark.png")
        render(theme, "tinted").convert("RGB").save(out / f"{base}-Tinted.png")
        write_json(out / "Contents.json", {"images": [
            {"filename": f"{base}.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": f"{base}-Dark.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": f"{base}-Tinted.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ], "info": info})

        preview = catalog / f"IconPreview-{title}.imageset"
        preview.mkdir(parents=True, exist_ok=True)
        light.convert("RGB").resize((256, 256), Image.LANCZOS).save(preview / f"IconPreview-{title}.png")
        write_json(preview / "Contents.json", {"images": [
            {"filename": f"IconPreview-{title}.png", "idiom": "universal"},
        ], "info": info})
        print("rendered", name)


if __name__ == "__main__":
    main()
