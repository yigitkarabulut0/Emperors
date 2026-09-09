#!/usr/bin/env python3
"""Bakes the two pieces the boot screen and the iOS launch image share.

    art/.venv/bin/python scripts/make-branding.py

  branding/medallion.png  the hero portrait in a gold ring, on transparency
  branding/launch@2x.png  the launch image iOS shows while the engine starts
  branding/launch@3x.png

The launch image and the game's first frame are one composition, laid out on
the same 941x1672 grid at the same proportions, so nothing jumps when the
engine takes over. The launch image carries no progress bar and no status
line: nothing on it should look like it is doing something while the app is
not yet running.
"""
import math
import pathlib
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRAND = ROOT / "client/assets/branding"   # what ships
SRC = ROOT / "art/branding"                # the portrait it is built from, which does not
CINZEL = ROOT / "client/assets/fonts/Cinzel-Variable.ttf"

GROUND = (9, 21, 30)
GOLD = (233, 196, 106)
GOLD_DIM = (201, 162, 78)
DIM = (184, 174, 156)

MEDALLION = 560                      # the asset's pixel size

# The composition, in fractions of the screen it is drawn on -- not of the
# 941x1672 design grid. A 19.5:9 phone runs a long way past the grid's foot, so
# a layout measured on the grid leaves the bottom third of the phone empty,
# which is what the first attempt did. boot.gd uses these same numbers.
VISTA_F = 0.235                      # height of the picture band
FADE_F = 0.105                       # over which it becomes the ground
MED_MID_F = 0.345                    # centre of the medallion
MED_W_F = 0.60                       # its width, of the screen's
TITLE_MID_F = 0.545
TITLE_SIZE_F = 0.0625
RULE_F = 0.605
RULE_W_F = 0.32
SUB_MID_F = 0.634
SUB_SIZE_F = 0.018
FOOT_F = 0.062                       # the foliage at the very bottom

SIZES = {"launch@2x.png": (860, 1864), "launch@3x.png": (1290, 2796)}


def medallion():
    """The portrait, round, in a gold ring with a soft light behind it."""
    n = MEDALLION
    ring, glow = 9, 26
    face = n - 2 * (ring + glow)

    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))

    # A warm halo, so the medallion sits in the dark rather than on it.
    halo = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse([glow // 2, glow // 2, n - glow // 2, n - glow // 2],
                                 fill=GOLD_DIM + (70,))
    out = Image.alpha_composite(out, halo.filter(ImageFilter.GaussianBlur(glow / 1.6)))

    src = Image.open(SRC / "hero.png").convert("RGB").resize((face, face), Image.LANCZOS)
    mask = Image.new("L", (face * 4, face * 4), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, face * 4 - 1, face * 4 - 1], fill=255)
    mask = mask.resize((face, face), Image.LANCZOS)
    out.paste(src, (glow + ring, glow + ring), mask)

    # The ring, drawn at 4x and reduced so its edge is clean.
    s = 4
    r = Image.new("RGBA", (n * s, n * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(r)
    box = [(glow + ring // 2) * s, (glow + ring // 2) * s,
           (n - glow - ring // 2) * s, (n - glow - ring // 2) * s]
    d.ellipse(box, outline=GOLD + (255,), width=ring * s)
    d.ellipse([b + (ring + 3) * s * (1 if i < 2 else -1) for i, b in enumerate(box)],
              outline=GOLD_DIM + (150,), width=max(1, s))
    return Image.alpha_composite(out, r.resize((n, n), Image.LANCZOS))


def _font(size, weight):
    f = ImageFont.truetype(str(CINZEL), int(size))
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


def _centred(d, w, text, font, mid_y, fill):
    box = d.textbbox((0, 0), text, font=font)
    d.text(((w - (box[2] - box[0])) / 2 - box[0], mid_y - (box[3] - box[1]) / 2 - box[1]),
           text, font=font, fill=fill)


def launch(w, h, med):
    im = Image.new("RGB", (w, h), GROUND)

    # The vista fills the top band, cropped to it rather than squashed.
    vista = Image.open(BRAND / "vista.png").convert("RGB")
    vh = int(VISTA_F * h)
    scale = max(w / vista.width, vh / vista.height)
    big = vista.resize((math.ceil(vista.width * scale), math.ceil(vista.height * scale)),
                       Image.LANCZOS)
    im.paste(big.crop(((big.width - w) // 2, 0, (big.width - w) // 2 + w, vh)), (0, 0))

    fade_h = int(FADE_F * h)
    ramp = Image.new("L", (1, fade_h))
    for y in range(fade_h):
        ramp.putpixel((0, y), int(255 * (y / max(1, fade_h - 1))))
    im.paste(Image.new("RGB", (w, fade_h), GROUND), (0, vh - fade_h), ramp.resize((w, fade_h)))

    foot = Image.open(BRAND / "foot.png").convert("RGB")
    fh = int(FOOT_F * h)
    im.paste(foot.resize((w, fh), Image.LANCZOS), (0, h - fh))

    ms = int(MED_W_F * w)
    med_s = med.resize((ms, ms), Image.LANCZOS)
    im.paste(med_s, ((w - ms) // 2, int(MED_MID_F * h - ms / 2)), med_s)

    d = ImageDraw.Draw(im)
    _centred(d, w, "EMPERORS", _font(TITLE_SIZE_F * h, 700), TITLE_MID_F * h, GOLD)
    rw, ry = int(RULE_W_F * w), int(RULE_F * h)
    d.rectangle([(w - rw) // 2, ry, (w + rw) // 2, ry + max(2, int(h / 1000))], fill=GOLD_DIM)
    _centred(d, w, "RULE YOUR REALM", _font(SUB_SIZE_F * h, 500), SUB_MID_F * h, DIM)
    return im


def main():
    med = medallion()
    med.save(BRAND / "medallion.png")
    print(f"medallion.png  {MEDALLION}x{MEDALLION}")
    for name, (w, h) in SIZES.items():
        launch(w, h, med).save(BRAND / name)
        print(f"{name}  {w}x{h}")


if __name__ == "__main__":
    main()
