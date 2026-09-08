#!/usr/bin/env python3
"""Tier-coloured stones for the gear tiles, from the one red stone the Family
painting has.

    art/.venv/bin/python scripts/gen-gem-tints.py

Reads client/assets/family/gem_red.png (a crop of the painted stone on its
frame) and writes gem_<tier>.png for every tier in balance/tiers.json plus
gem_empty.png, an unlit stone for a bare slot. Only the stone's red pixels are
recoloured -- hue set to the tier colour, lightness and saturation kept, so the
facets stay facets -- and the gold rim and frame around it are untouched.
"""
import colorsys, json, pathlib
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "client/assets/family/gem_red.png"
OUT = ROOT / "client/assets/family"

def hsv(rgb):
    return np.array([colorsys.rgb_to_hsv(*(c / 255.0 for c in rgb))])

im = np.array(Image.open(SRC).convert("RGBA")).astype(float)
rgb = im[..., :3] / 255.0
mx, mn = rgb.max(axis=2), rgb.min(axis=2)
sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
# hue in degrees
h = np.zeros_like(mx)
d = np.maximum(mx - mn, 1e-6)
h = np.where(mx == r, (60 * ((g - b) / d)) % 360, h)
h = np.where(mx == g, 60 * ((b - r) / d) + 120, h)
h = np.where(mx == b, 60 * ((r - g) / d) + 240, h)
stone = (sat > 0.35) & ((h < 22) | (h > 335)) & (mx > 0.2)   # the red glass; gold is hue ~45 and stays

def write(name, colour):
    out = im.copy()
    if colour is None:
        # unlit: the glass goes to dark smoke, its facets still readable
        grey = mx * 0.45
        for i in range(3):
            out[..., i] = np.where(stone, grey * 255 * (0.9 + 0.1 * i / 2), out[..., i])
    else:
        th, ts, tv = colorsys.rgb_to_hsv(*(int(colour[i:i+2], 16) / 255.0 for i in (1, 3, 5)))
        for y, x in zip(*np.where(stone)):
            hh, ss, vv = colorsys.rgb_to_hsv(*rgb[y, x])
            # a vivid tier keeps the glass vivid; a grey one (common) drains it
            nr, ng, nb = colorsys.hsv_to_rgb(th, min(1.0, ss * (0.2 + 0.8 * ts)), vv)
            out[y, x, :3] = (nr * 255, ng * 255, nb * 255)
    Image.fromarray(out.astype(np.uint8), "RGBA").save(OUT / f"{name}.png")
    print("wrote", name)

tiers = json.load(open(ROOT / "balance/tiers.json"))["tiers"]
for t in tiers:
    write("gem_" + t["id"], t["color"])
write("gem_empty", None)
print(f"stone pixels recoloured: {int(stone.sum())} of {stone.size}")
