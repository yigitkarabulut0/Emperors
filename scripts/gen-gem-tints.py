#!/usr/bin/env python3
"""Tier-coloured stones, from the one red stone the Family painting has.

    art/.venv/bin/python scripts/gen-gem-tints.py

Two sets, tinted the same way so a tier's stone is one colour wherever it is:

  * client/assets/family/gem_red.png -- the stone on its gear tile's rim, with
    the slot's steel plate round it (art/slices/family.json) -- becomes
    family/gem_<tier>.png for the gear tiles;
  * client/assets/rewards/gem_red.png -- the same stone cut clean round its
    gold setting (art/slices/rewards.json) -- becomes rewards/gem_<tier>.png,
    the picture of gear not yet rolled on a reward line (item:<tier>).

Each set gets one stone for every tier in balance/tiers.json plus gem_empty.png,
an unlit stone. Only the stone's red pixels are recoloured -- hue set to the
tier colour, lightness and saturation kept, so the facets stay facets -- and the
gold rim and whatever is round it are untouched (alpha included).
"""
import colorsys, json, pathlib
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SETS = [ROOT / "client/assets/family", ROOT / "client/assets/rewards"]


def tint_set(out_dir):
    im = np.array(Image.open(out_dir / "gem_red.png").convert("RGBA")).astype(float)
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
        Image.fromarray(out.astype(np.uint8), "RGBA").save(out_dir / f"{name}.png")
        print("wrote", out_dir.name + "/" + name)

    tiers = json.load(open(ROOT / "balance/tiers.json"))["tiers"]
    for t in tiers:
        write("gem_" + t["id"], t["color"])
    write("gem_empty", None)
    print(f"{out_dir.name}: stone pixels recoloured: {int(stone.sum())} of {stone.size}")


for s in SETS:
    tint_set(s)
