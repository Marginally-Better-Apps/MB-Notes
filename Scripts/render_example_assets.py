#!/usr/bin/env python3
"""Render the image assets in examples/packs so their provenance is clear.

Usage: python3 Scripts/render_example_assets.py. Requires Pillow.
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 512
SS = 2


def croissant(path):
    w = SIZE * SS
    img = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # A crescent of overlapping, tapering ellipses with a darker outline and a lighter top.
    center, radius = (w / 2, w * 0.58), w * 0.36
    for pass_ in ("outline", "fill", "highlight"):
        for i in range(9):
            t = i / 8
            angle = math.radians(200 + 140 * t)
            size = w * (0.09 + 0.11 * math.sin(math.pi * t))
            x, y = center[0] + math.cos(angle) * radius, center[1] + math.sin(angle) * radius
            if pass_ == "outline":
                d.ellipse([x - size - 10 * SS, y - size - 10 * SS, x + size + 10 * SS, y + size + 10 * SS], fill=(150, 90, 40, 255))
            elif pass_ == "fill":
                d.ellipse([x - size, y - size, x + size, y + size], fill=(226, 160, 80, 255))
            else:
                d.ellipse([x - size * 0.6, y - size * 0.75, x + size * 0.6, y - size * 0.1], fill=(240, 190, 120, 255))
    img.resize((SIZE, SIZE), Image.LANCZOS).save(path)


def main():
    root = Path(__file__).resolve().parent.parent
    croissant(root / "examples/packs/cozy-cafe.mbpack/images/croissant.png")
    print("rendered croissant.png")


if __name__ == "__main__":
    main()
