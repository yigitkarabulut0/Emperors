#!/usr/bin/env python3
"""The item designs: 20 cut out of the item paintings in the seven references,
and 42 weapons, armours and horses painted on their own sheets.

    art/.venv/bin/python scripts/cut-item-paintings.py            # writes client/assets/items/painted/*.png
    art/.venv/bin/python scripts/cut-item-paintings.py --review   # also a contact sheet in art/qa/

The references hold six or seven painted items per slot, each inside a frame
and on its own ground: a dark cloudy backdrop for the equipped and inventory
tiles, a coloured glow or a lit field for the shop cards. Each is lifted out
in two steps that together keep what the painter meant and drop the rest:

  1. a salient-object mask (BiRefNet through rembg) says where the item is;
     inside it the pixels stay opaque, so a black horse stays a black horse;
  2. outside the mask a luminance key keeps the item's glow -- the purple
     around a shadow blade, the flames on a red one -- and lets the dark
     ground go clear, with a corner fade so a card whose whole ground is lit
     does not come out as a lit square.

The cut is trimmed, fitted into 220 and centred on a 256 canvas; the screens
draw it inset into their empty tiles ("fit": "contain"), whose backdrops are
the same dark ground the paintings had. Masks are cached in art/matted/items/
so a rerun without rembg still works; delete one to recompute it.

Design keys follow balance/items.json's art keys, plainest to grandest within
each slot.

weapon_08..21, armor_08..21 and horse_08..21 come from art/reference/
items_weapons.png, items_armor.png and items_horses.png (docs/art/
PAINTING_BRIEFS.md R10), fourteen to a sheet, each painted for one definition
by name. They stand alone on the flat navy ground with a glow of their tier's
colour; the same object mask lifts the item and leaves the glow, as it does for
the references' items. A sheet item has no level plate and no frame, so neither
the plate inpaint nor the near-black fill rule (which would cut holes in a
black blade or a black horse) applies to it.

The references hold six horses (war_steed is painted twice, in the inventory and
the family), the horse sheet fourteen and items_horses_2.png one: twenty-one
paintings for twenty-one horses. The six go to the first seven definitions by
the look that suits each name and tier -- the plain brown head to the Plough
Horse, the green-harnessed grey to the Trail Courser, the black horse with the
violet mane to the rare Warden's Charger -- and the Village Pony, horse_02, is
the shaggy dun pony painted for it on its own sheet.
"""
import argparse, pathlib, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
CROPS = ROOT / "client/assets/items"
MASKS = ROOT / "art/matted/items"
OUT = ROOT / "client/assets/items/painted"

# design key -> (reference crop, interior box inside that crop, i.e. without its frame)
FULL, TILE, EQUIP, ARMY = (0, 0, 192, 216), (10, 10, 130, 130), (12, 12, 209, 182), (7, 7, 92, 93)
REFERENCE = ROOT / "art/reference"
SHEET = "sheet:"   # a source painted on its own sheet: "sheet:<reference name>", box in its pixels

# The sheets' cells, row-major, in the order the prompt book painted them: cell k
# is the design for definition k+7 of the slot (the rare tier's second item on).
# Boxes are the cell around the item with its glow, clear of the neighbours.
WEAPON_CELLS = [
    (10, 5, 312, 322), (325, 5, 622, 322), (630, 0, 935, 322),
    (5, 322, 312, 668), (318, 322, 625, 660), (632, 325, 935, 660),
    (5, 645, 312, 975), (320, 638, 625, 968), (638, 645, 935, 972),
    (0, 962, 315, 1300), (308, 955, 630, 1312), (622, 962, 935, 1305),
    (2, 1290, 310, 1628), (315, 1298, 615, 1630),
]
HORSE_CELLS = [
    (8, 5, 320, 322), (322, 5, 622, 322), (624, 5, 935, 322),
    (8, 318, 320, 636), (320, 318, 624, 636), (624, 318, 935, 636),
    (5, 616, 320, 946), (318, 616, 624, 946), (624, 616, 935, 946),
    (5, 934, 320, 1254), (316, 934, 624, 1254), (624, 934, 935, 1256),
    (5, 1242, 320, 1590), (314, 1242, 624, 1590),
]
ARMOR_CELLS = [
    (14, 32, 322, 318), (322, 32, 620, 318), (624, 28, 935, 318),
    (12, 322, 320, 618), (318, 322, 622, 618), (620, 325, 930, 622),
    (8, 612, 322, 918), (318, 618, 622, 918), (620, 618, 930, 922),
    (10, 920, 322, 1232), (316, 920, 624, 1232), (620, 922, 930, 1234),
    (14, 1232, 324, 1560), (318, 1232, 632, 1566),
]
DESIGNS = {
    "weapon_01": ("royal_longsword", EQUIP), "weapon_02": ("knights_blade", TILE), "weapon_03": ("army_spear", (7, 7, 91, 93)),
    "weapon_04": ("shadowfang", TILE), "weapon_05": ("bloodcrown", TILE), "weapon_06": ("knights_oath", FULL), "weapon_07": ("dragonblade", FULL),
    "armor_01": ("recruit_armor", TILE), "armor_02": ("army_leather_armor", (7, 7, 93, 93)), "armor_03": ("ranger_mail", TILE),
    "armor_04": ("lionheart_armor", (12, 12, 208, 182)), "armor_05": ("dragonplate", TILE), "armor_06": ("valiant_armor", FULL),
    "armor_07": ("lionheart_armor_shop", FULL),
    **{f"weapon_{i + 8:02d}": (SHEET + "items_weapons", box) for i, box in enumerate(WEAPON_CELLS)},
    **{f"armor_{i + 8:02d}": (SHEET + "items_armor", box) for i, box in enumerate(ARMOR_CELLS)},
    # horse_02, the Village Pony: alone on items_horses_2.png, its ink at x 53-879,
    # y 296-1343 on the 941x1672 sheet.
    "horse_01": ("army_horse", (7, 7, 96, 93)), "horse_02": (SHEET + "items_horses_2", (30, 270, 910, 1370)),
    "horse_03": ("war_steed", (12, 12, 206, 182)),
    "horse_04": ("forest_charger", TILE), "horse_05": ("warhorse", FULL), "horse_06": ("royal_charger", FULL),
    "horse_07": ("nightmare", TILE),
    **{f"horse_{i + 8:02d}": (SHEET + "items_horses", box) for i, box in enumerate(HORSE_CELLS)},
}


# Slot by slot, plainest to grandest: the order the review sheet lays them out in.
DESIGNS = dict(sorted(DESIGNS.items(), key=lambda kv: (("weapon", "armor", "horse").index(kv[0].split("_")[0]),
                                                        int(kv[0].split("_")[1]))))

# Sheet designs whose light IS the item: a blade made of fire, a burning edge,
# light leaking from cracks, embers along an edge, starlight on a meteoric
# blade. The object mask reads that light as backdrop and leaves a ghost -- the
# Crown of Flame came out as a hilt and a few wisps. These are cut by the ground
# instead (see glow_alpha), which a sheet's flat navy makes exact; every other
# design keeps the rule above that a tier's halo is not the item's.
GLOW_DESIGNS = {"weapon_14", "weapon_16", "weapon_18", "weapon_19", "weapon_21"}


def source(name, box):
    if name.startswith(SHEET):
        im = Image.open(REFERENCE / f"{name[len(SHEET):]}.png").convert("RGB").crop(box)
    else:
        im = Image.open(CROPS / f"{name}.png").convert("RGB").crop(box)
    k = 4 if im.width < 150 else 3  # the small crops need the room for a soft edge
    return im.resize((im.width * k, im.height * k), Image.LANCZOS), k


# The level plate painted into each tile family's bottom-right corner, in crop
# coordinates. The slicer erased only the figure on it; the plate itself stays,
# a flat dark box lying over the item, and it is not part of the item.
PLATES = {TILE: (60, 100, 76, 34), EQUIP: (126, 146, 88, 40), (12, 12, 208, 182): (126, 146, 88, 40),
          (12, 12, 206, 182): (126, 146, 88, 40), ARMY: (44, 70, 50, 26), (7, 7, 91, 93): (44, 70, 50, 26),
          (7, 7, 93, 93): (44, 70, 50, 26), (7, 7, 96, 93): (44, 70, 50, 26)}


def without_plate(im, box, k):
    """Paints the level plate out of the upsampled interior by inpainting it from
    what surrounds it, so an armour that ran under the plate keeps a plausible
    hem instead of a rectangular bite, and a sword that did not is untouched."""
    plate = PLATES.get(box)
    if plate is None:
        return im
    import cv2
    x, y, w, h = plate
    x0, y0 = max(0, (x - box[0]) * k), max(0, (y - box[1]) * k)
    x1, y1 = min(im.width, (x - box[0] + w) * k), min(im.height, (y - box[1] + h) * k)
    if x1 <= x0 or y1 <= y0:
        return im
    m = np.zeros((im.height, im.width), np.uint8)
    m[y0:y1, x0:x1] = 255
    bgr = cv2.cvtColor(np.array(im), cv2.COLOR_RGB2BGR)
    out = cv2.inpaint(bgr, m, 9, cv2.INPAINT_TELEA)
    return Image.fromarray(cv2.cvtColor(out, cv2.COLOR_BGR2RGB))


def mask_for(name, im):
    p = MASKS / f"{name}_mask.png"
    if p.exists():
        return Image.open(p).convert("L").resize(im.size, Image.LANCZOS)
    from rembg import remove, new_session  # only needed to (re)build the cache
    k = max(1, round(im.width / 400))
    small = im.resize((im.width // k, im.height // k), Image.LANCZOS)
    m = remove(small, session=new_session("birefnet-general", providers=["CPUExecutionProvider"]), only_mask=True)
    m = m.resize(im.size, Image.LANCZOS)
    MASKS.mkdir(parents=True, exist_ok=True)
    m.save(p)
    return m


def fade_at_border(alpha, band=26):
    """Fades the alpha out where the item runs off the edge of its source crop.

    Several paintings are cropped by their own card -- the shop's Lionheart
    armour has no bottom, the courser no hindquarters -- so the mask ends in a
    straight razor line at the crop boundary. Inside its frame in the reference
    that line is the frame; lifted onto a tile it is a sliced-off item. A short
    ramp over the last few pixels reads as the painting fading out instead.
    """
    h, w = alpha.shape
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.minimum(np.minimum(xx, w - 1 - xx), np.minimum(yy, h - 1 - yy))
    return alpha * np.clip(d / float(band), 0, 1)


def luma_key(a, lo=0.06, hi=0.34, vignette=0.55):
    lum = 0.30 * a[..., 0] + 0.55 * a[..., 1] + 0.15 * a[..., 2]
    mx, mn = a.max(axis=2), a.min(axis=2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    k = np.clip((lum - lo) / (hi - lo), 0, 1)
    k = np.maximum(k, np.clip((sat - 0.35) / 0.4, 0, 1) * np.clip((mx - 0.18) / 0.3, 0, 1)) ** 0.8
    h, w = lum.shape
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.sqrt(((xx - (w - 1) / 2) / (w / 2)) ** 2 + ((yy - (h - 1) / 2) / (h / 2)) ** 2)
    return np.clip(k * np.clip(1.0 - (r - vignette) / (1.25 - vignette), 0, 1), 0, 1)


def glow_alpha(a, m):
    """Alpha and colour for a design whose light is part of it, off a flat ground.

    The ground is one colour (the sheet's navy), so every pixel's distance from
    it says how much of the item is in it. The item's silhouette -- everything
    at least half the item, holes closed and filled, so a black blade inside a
    burning edge is whole -- is opaque in its painted colour. Outside it the
    light keys off the ground, un-premultiplied (a flame over the shop's gold
    card is a flame, not a smear of navy), at a little over half strength and
    only near the silhouette. Only the largest part of the silhouette and what
    is comparable to it are kept: a neighbour's tip in the cell is not the item.
    """
    from scipy import ndimage
    ring = np.concatenate([a[0, :], a[-1, :], a[:, 0], a[:, -1]])
    bg = np.median(ring, axis=0)
    key = np.clip((np.abs(a - bg).max(axis=2) - 0.05) / 0.30, 0, 1)
    solid = ndimage.binary_fill_holes(ndimage.binary_closing(np.maximum(m, key) > 0.5, iterations=6))
    solid = ndimage.binary_opening(solid, iterations=2)
    lab, n = ndimage.label(solid)
    if n > 1:
        sizes = ndimage.sum(solid, lab, range(1, n + 1))
        solid = np.isin(lab, [i + 1 for i, v in enumerate(sizes) if v >= 0.2 * sizes.max()])
    near = ndimage.binary_dilation(solid, iterations=24)
    halo = np.where(solid | ~near, 0.0, key * 0.55)
    unmul = (a - bg * (1 - key[..., None])) / np.maximum(key[..., None], 1e-3)
    rgb = np.where(solid[..., None], a, np.clip(unmul, 0, 1))
    alpha = np.maximum(ndimage.gaussian_filter(solid.astype(float), 1.2), halo)
    return rgb, alpha


def cut(name, box, key=""):
    im, k = source(name, box)
    sheet = name.startswith(SHEET)
    if not sheet:
        im = without_plate(im, box, k)
    a = np.array(im).astype(float) / 255.0
    # A sheet's cells share one file, so each caches its mask under its design.
    cache = f"{name[len(SHEET):]}_{key}" if sheet else name
    m = np.array(mask_for(cache, im).filter(ImageFilter.GaussianBlur(3))).astype(float) / 255.0
    # The item only. An earlier cut kept the glow around it -- the purple haze
    # on a shadow blade, the flames on a red one -- by keying luminance in a
    # wide ring outside the mask. On the dark tiles that read as atmosphere, so
    # the review sheet passed; on the shop's gold card the same pixels are a
    # dark smear with a visible edge, because a semi-opaque backdrop cannot be
    # right over two different grounds at once. It also painted a rarity into
    # art that balance/items.json shares across three rarities: the purple
    # around weapon_04 belongs to The Sundering (mystic) and rode along onto
    # Guard's Greatsword (uncommon). Rarity is the frame's job.
    alpha = m
    if key in GLOW_DESIGNS:
        a, alpha = glow_alpha(a, m)
    # A flat, near-black fill inside the mask is not the item: it is the level
    # plate the slicer erased from the crop, or ground the mask swallowed. Real
    # shading has some colour or some light in it; this has neither.
    lum = 0.30 * a[..., 0] + 0.55 * a[..., 1] + 0.15 * a[..., 2]
    mx, mn = a.max(axis=2), a.min(axis=2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    flat_dark = (lum < 0.10) & (sat < 0.25)
    if not sheet:
        alpha = np.where(flat_dark, 0.0, alpha)
    alpha = fade_at_border(alpha)
    rgba = np.dstack([a * 255, alpha[..., None] * 255]).astype(np.uint8)
    out = Image.fromarray(rgba, "RGBA")
    ys, xs = np.where(alpha > 0.16)
    out = out.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
    s = min(220 / out.width, 220 / out.height)
    out = out.resize((max(1, round(out.width * s)), max(1, round(out.height * s))), Image.LANCZOS)
    canvas = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    canvas.paste(out, ((256 - out.width) // 2, (256 - out.height) // 2), out)
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--review", action="store_true", help="also write art/qa/item_designs.png")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    done = {}
    for key, (name, box) in DESIGNS.items():
        canvas = cut(name, box, key)
        canvas.save(OUT / f"{key}.png", optimize=True)
        done[key] = canvas
        print(f"{key} <- {name}")
    if args.review:
        # Every design over BOTH grounds it is drawn on. A cut that keeps any of
        # its own backdrop disappears against the dark tile and only shows on
        # the shop's lit card, so a sheet with the tile alone passes work that
        # is visibly wrong in the shop -- which is how the glow shipped.
        tile = Image.open(ROOT / "client/assets/family/gear_tile_empty.png").convert("RGBA")
        card = Image.open(ROOT / "client/assets/shop/card_frame_legendary.png").convert("RGBA")
        cell, rows = 224, 2 * ((len(DESIGNS) + 6) // 7)
        sheet = Image.new("RGB", (cell * 7, (cell - 30) * rows + 40), (25, 25, 25))
        d = ImageDraw.Draw(sheet)
        for i, key in enumerate(DESIGNS):
            im = done[key].copy()
            im.thumbnail((184, 144))
            col, band = i % 7, (i // 7) * 2
            for j, ground in enumerate((tile, card)):
                g = ground.copy()
                g.paste(im, (18 + (184 - im.width) // 2, 14 + (144 - im.height) // 2), im)
                # Its own cell and no more: the shop card is wider and taller than
                # a cell, and at the end of a short row it showed past the design.
                g = g.crop((0, 0, min(g.width, cell - 4), min(g.height, cell - 32)))
                x, y = col * cell, (band + j) * (cell - 30) + 14
                sheet.paste(g.convert("RGB"), (x + 2, y))
                d.text((x + 4, y - 12), key if j == 0 else key + " (shop)", fill=(255, 255, 255))
        (ROOT / "art/qa").mkdir(exist_ok=True)
        sheet.save(ROOT / "art/qa/item_designs.png")
        print("review sheet: art/qa/item_designs.png")


if __name__ == "__main__":
    main()
