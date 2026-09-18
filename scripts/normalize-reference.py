"""Bring a newly painted reference to the canvas the game is cut from.

    art/.venv/bin/python scripts/normalize-reference.py <painting.png> [--kind screen|map|boss]
                                                        [--out art/reference/<name>.png] [--force]

The paintings are made larger than the game draws them (docs/art/PAINTING_BRIEFS.md:
"paint big, draw down"): a generator paints a 1080x1920 screen with more care than
a 941x1672 one, and an icon painted at 220 px and drawn at 72 keeps its detail
where one painted at 72 is mush. This is the single step that brings the
painting to the game's grid, so that every coordinate read off it afterwards
(grid.py, probe.py, the manifests, the layouts) is a layout unit.

What it does, and nothing else:

  * checks the painting's shape against its kind and refuses one that is off by
    more than 2 % -- a squashed painting cut to the grid is a squashed game;
  * scales it to COVER the target with Lanczos (never stretches) and trims the
    remainder evenly from both sides -- at 9:16 into 941x1672 that is one row;
  * drops any alpha against the navy ground (#0B151F) and writes an opaque RGB
    PNG, because every crop mode after this assumes an opaque source;
  * refuses to overwrite a reference already cut from (art/slices names it)
    unless --force, since a re-normalised painting moves every rect by a pixel.

Kinds (the briefs' "Tuval" line):  screen 941x1672 (9:16)  ·  map 776x1030 (3:4)
                                   boss 771x482 (16:10)
"""
import argparse
import glob
import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KINDS = {"screen": (941, 1672), "map": (776, 1030), "boss": (771, 482)}
# The smallest painting of each kind worth accepting: below this the scaling
# goes UP, and a painting drawn up is exactly what the rule forbids.
MIN = {"screen": (1080, 1920), "map": (1552, 2070), "boss": (1542, 964)}
GROUND = (0x0B, 0x15, 0x1F)
TOLERANCE = 0.02


def used_by_manifests(name):
    """The manifests that cut from this reference file."""
    out = []
    for m in sorted(glob.glob(os.path.join(ROOT, "art", "slices", "*.json"))):
        try:
            d = json.load(open(m))
        except (OSError, ValueError):
            continue
        if not isinstance(d, dict):
            continue
        srcs = {d.get("source", "")}
        srcs.update(c.get("src", "") for c in d.get("crops", []) if isinstance(c, dict))
        if name in srcs:
            out.append(os.path.relpath(m, ROOT))
    return out


def normalize(src, kind):
    tw, th = KINDS[kind]
    im = Image.open(src)
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        ground = Image.new("RGBA", im.size, GROUND + (255,))
        im = Image.alpha_composite(ground, im)
    im = im.convert("RGB")
    w, h = im.size
    want, got = tw / th, w / h
    if abs(got - want) / want > TOLERANCE:
        raise SystemExit(
            f"{src}: {w}x{h} is {got:.4f} wide per unit of height; a {kind} is {want:.4f} "
            f"({tw}x{th}). Off by {abs(got - want) / want:.1%} -- ask for the painting again at the "
            f"brief's shape rather than cutting a squashed one.")
    mw, mh = MIN[kind]
    if w < mw or h < mh:
        print(f"  WARN  {w}x{h} is under the brief's {mw}x{mh}: detail will be thinner than the kit's",
              file=sys.stderr)
    scale = max(tw / w, th / h)
    sw, sh = max(tw, round(w * scale)), max(th, round(h * scale))
    im = im.resize((sw, sh), Image.LANCZOS)
    left, top = (sw - tw) // 2, (sh - th) // 2
    return im.crop((left, top, left + tw, top + th)), (w, h), (sw, sh)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("painting")
    ap.add_argument("--kind", choices=sorted(KINDS), default="screen")
    ap.add_argument("--out", help="default: art/reference/<the painting's file name>")
    ap.add_argument("--force", action="store_true", help="overwrite a reference manifests already cut from")
    a = ap.parse_args()

    name = os.path.basename(a.painting)
    if not name.lower().endswith(".png"):
        name = os.path.splitext(name)[0] + ".png"
    out = a.out or os.path.join(ROOT, "art", "reference", name)
    # In place or over another file, the guard is the same: a reference the
    # manifests already cut from is not re-scaled by accident.
    refdir = os.path.join(ROOT, "art", "reference")
    if os.path.exists(out) and os.path.dirname(os.path.abspath(out)) == refdir:
        users = used_by_manifests(os.path.basename(out))
        if users and not a.force:
            raise SystemExit(f"{os.path.relpath(out, ROOT)} is cut from by {', '.join(users)}; "
                             "normalising a new painting over it moves every rect. Pass --force "
                             "and re-measure those manifests.")
    im, was, scaled = normalize(a.painting, a.kind)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    im.save(out, optimize=True)
    tw, th = KINDS[a.kind]
    print(f"  {was[0]}x{was[1]} -> {scaled[0]}x{scaled[1]} -> {tw}x{th}  {os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
