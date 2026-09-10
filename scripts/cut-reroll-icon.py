#!/usr/bin/env python3
"""The reroll mark -- two gold arrows chasing each other -- lifted off the red
plate the shop paints it on.

    art/.venv/bin/python scripts/cut-reroll-icon.py

The Army screen's REROLL button needs the game's own sign for "roll again",
and the only painting that has one is the shop's REROLL MARKET button, where
the arrows sit on crimson. slice-reference's modes cannot take them off it:
rect keeps the crimson, and darkkey keys against a dark ground, which this is
not. Gold and crimson differ where it counts, though -- gold is bright in green
and crimson has almost none -- so the matte is the green channel against the
red one, and each pixel's colour is un-mixed from the plate's own red, so the
arrows' edges carry no pink onto the green plate they are set on.
"""
import pathlib
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "art/reference/shop.png"
OUT = ROOT / "client/assets/icons/reroll_arrows.png"
# The arrows on shop.png's REROLL MARKET button, with a little plate around them
# and clear of the button's gold border.
BOX = (684, 573, 730, 619)


def main() -> None:
    im = Image.open(SRC).convert("RGB").crop(BOX)
    arr = np.asarray(im).astype(np.float32)
    r, g = arr[..., 0], arr[..., 1]
    # Gold: green well above what the crimson plate has at the same red.
    alpha = np.clip((g - 0.45 * r - 10.0) / 40.0, 0.0, 1.0)
    ring = np.concatenate([arr[0, :], arr[-1, :], arr[:, 0], arr[:, -1]])
    bg = np.median(ring, axis=0)
    a = np.maximum(alpha[..., None], 1e-3)
    fg = np.clip((arr - bg * (1.0 - alpha[..., None])) / a, 0, 255)
    rgba = np.dstack([fg, alpha * 255.0]).astype(np.uint8)
    out = Image.fromarray(rgba, "RGBA")
    ys, xs = np.where(alpha > 0.05)
    out = out.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    out.save(OUT, optimize=True)
    print(f"reroll_arrows: {out.width}x{out.height} <- shop.png{BOX}, plate {bg.round().astype(int).tolist()}")


if __name__ == "__main__":
    main()
