#!/usr/bin/env python3
"""Prepares the splash and loading art the app ships.

    art/.venv/bin/python scripts/make-branding.py

The two paintings live in art/branding/ and do not ship; what ships is built
from them here.

  branding/loading.png       the loading painting with its progress track
                             emptied, so the bar can be filled for real
  branding/loading_fill.png  the gold out of that bar, to fill it with
  branding/launch@2x.png     the splash painting at the sizes iOS wants
  branding/launch@3x.png

The splash is the painting without a progress bar, because iOS shows it before
the app is running and nothing on it should look like it is doing something.
The loading painting has the bar, and boot.gd fills it as each step of the boot
finishes rather than on a timer.

Both paintings are 941x1672, the design grid. A phone is taller than that, so
the launch images are rendered at the phone's own proportions with the painting
scaled to cover and cropped evenly at the sides -- the composition is symmetric,
so it loses only the outer edge of each banner.
"""
import math
import pathlib
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "art/branding"                  # the paintings, which do not ship
OUT = ROOT / "client/assets/branding"        # what does

## The paintings are 941x1672 and a phone is much taller. Covering the screen
## with them crops a fifth of the width, which cuts the E and the S off
## EMPERORS, so each is first extended to the tall canvas by stretching its own
## top and bottom rows: the top is sky between pillars and banners, all
## vertical, and the bottom is carpet and stone, all horizontal, so neither
## shows the stretch. After that the covering crop takes only a little off the
## top and bottom and nothing off the sides.
ART = (941, 1672)
TALL = (941, 2200)
PAD = (TALL[1] - ART[1]) // 2

## The progress track inside the painted frame, in the EXTENDED painting's
## pixels, read off a 2x crop of the bar. boot.gd carries the same numbers.
TRACK = (205, 1787, 514, 30)     # 1523 in the painting, + PAD
FILL = (205, 1791, 514, 21)      # 1527 in the painting, + PAD
SIZES = {"launch@2x.png": (860, 1864), "launch@3x.png": (1290, 2796)}


def extend(im):
    """The painting on the tall canvas, its own edges carrying the difference."""
    out = Image.new("RGB", TALL)
    out.paste(im, (0, PAD))
    top = im.crop((0, 0, ART[0], 4)).resize((ART[0], 1), Image.LANCZOS)
    bot = im.crop((0, ART[1] - 4, ART[0], ART[1])).resize((ART[0], 1), Image.LANCZOS)
    out.paste(top.resize((ART[0], PAD), Image.NEAREST), (0, 0))
    out.paste(bot.resize((ART[0], TALL[1] - ART[1] - PAD), Image.NEAREST), (0, PAD + ART[1]))
    return out


def loading():
    """The painting with its bar emptied, and the gold that fills it."""
    im = extend(Image.open(SRC / "loading_src.jpg").convert("RGB"))
    fx, fy, fw, fh = FILL
    # A slice of the painted gold, to be stretched across however much of the
    # bar is done. Taken from the middle of the run, clear of both ends.
    strip = im.crop((fx + 95, fy, fx + 195, fy + fh))
    tx, ty, tw, th = TRACK
    # The unfilled end of the track, copied across the filled part.
    im.paste(im.crop((tx + tw - 30, ty, tx + tw - 20, ty + th)).resize((tw, th), Image.LANCZOS),
             (tx, ty))
    im.save(OUT / "loading.png")
    strip.save(OUT / "loading_fill.png")
    print(f"loading.png  {im.size}\nloading_fill.png  {strip.size}")


def launch():
    src = extend(Image.open(SRC / "splash_src.jpg").convert("RGB"))
    for name, (w, h) in SIZES.items():
        scale = max(w / src.width, h / src.height)
        big = src.resize((math.ceil(src.width * scale), math.ceil(src.height * scale)),
                         Image.LANCZOS)
        left = (big.width - w) // 2
        top = (big.height - h) // 2
        big.crop((left, top, left + w, top + h)).save(OUT / name)
        print(f"{name}  {w}x{h}")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    loading()
    launch()
