#!/usr/bin/env python3
"""The Favour shop's three goods, lifted off the fields they were painted on.

    art/.venv/bin/python scripts/cut-favour-goods.py

The Kingdom's Favour shop sells an energy potion, a market refresh and an XP
draught, and the Works tab now shows them as three cards. Two of the three
marks were already cut and can be used as they are -- the rail's market tent
(icons/market_tent) and the quest scroll (icons/quest_scroll), both keyed off
the navy by the slicer.

The energy flask cannot be. The shop paints it inside its own lit tile, so
slice-reference's rect crop keeps that tile: on the shop's diamond panel the
tile is the design and nobody sees a box, but on the Kingdom's plate it is a
bright rectangle around the bottle. darkkey cannot help either -- the field it
would have to key away is the flask's own blue glow.

So it comes out the way the item paintings do: a salient-object mask (BiRefNet
through rembg) at 4x, blurred a little, trimmed to what it found. The mask is
cached beside the item masks, so a rerun without rembg installed still works;
delete the file to recompute it.
"""
import pathlib
import numpy as np
from PIL import Image, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
MASKS = ROOT / "art/matted/goods"
OUT = ROOT / "client/assets/icons"

# name -> (reference, rect the good is painted in)
GOODS = {"good_energy": ("shop.png", (197, 1433, 313, 1595))}
UP = 4


def mask_for(name: str, im: Image.Image) -> Image.Image:
    cached = MASKS / f"{name}_mask.png"
    if cached.exists():
        return Image.open(cached).convert("L").resize(im.size, Image.LANCZOS)
    from rembg import remove, new_session  # only needed to (re)build the cache
    m = remove(im, session=new_session("birefnet-general",
                                       providers=["CPUExecutionProvider"]), only_mask=True)
    MASKS.mkdir(parents=True, exist_ok=True)
    m.save(cached)
    return m


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (src, box) in GOODS.items():
        ref = Image.open(ROOT / "art/reference" / src).convert("RGB").crop(box)
        big = ref.resize((ref.width * UP, ref.height * UP), Image.LANCZOS)
        m = mask_for(name, big).filter(ImageFilter.GaussianBlur(3))
        rgba = Image.fromarray(np.dstack([np.array(big), np.array(m)]).astype(np.uint8), "RGBA")
        ys, xs = np.where(np.array(m) > 40)
        rgba = rgba.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
        rgba = rgba.resize((max(1, rgba.width // UP), max(1, rgba.height // UP)), Image.LANCZOS)
        rgba.save(OUT / f"{name}.png", optimize=True)
        print(f"{name}: {rgba.width}x{rgba.height} <- {src}{box}")


if __name__ == "__main__":
    main()
