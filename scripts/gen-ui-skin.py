#!/usr/bin/env python3
"""The game's surfaces: carved stone, parchment and imperial red.

StyleBoxFlat can only draw a flat colour, so everything here is a small
nine-slice texture instead and the same StyleBox machinery draws material.

What changed from the version this replaces: that one drew a dark theme out of
vertical gradients, and a gradient is the one thing that cannot say "carved".
The operator that can is `-shade`, which lights a greyscale height map from a
fixed angle -- draw the frame as a white band on black, blur it, shade it, and
the result is a bevel with a lit top-left and a shaded bottom-right. Composited
over a flat colour it is the difference between a border and a border cut into
something.

The previous generator is not gone, it is one command away:
    git show pre-roman-ui:scripts/gen-ui-skin.py
It is not kept beside this one on purpose -- two scripts writing the same twelve
filenames means someone eventually runs the wrong one and reverts the art
without reverting the code.

    python3 scripts/gen-ui-skin.py
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "client/assets/ui/skin"
TILE = ROOT / "client/assets/ui/tile"
CHROME = ROOT / "client/assets/ui/chrome"

# Matches client/scripts/ui/palette.gd. Kept here so the art cannot drift from
# the theme; scripts/check-contrast.py measures the palette side of the pair.
BG = "#E8DCC0"          # parchment ground
PANEL = "#F2E8D2"       # card
PANEL_HIGH = "#FBF4E4"  # raised
RAIL = "#D9CFBA"        # marble
LINE = "#B9A87E"        # rule
GOLD = "#B8860B"
GOLD_DEEP = "#5C3F05"
BANNER = "#7E1C1C"      # imperial red
DANGER = "#8B2222"
STONE_EDGE = "#A08E6A"
INK = "#2E1F14"

# --- nine-slice geometry -----------------------------------------------------
#
# Two families. The big one is unchanged from the previous generator so its
# twelve names stay drop-in; the small one exists because a currency cartouche
# is about 36 units tall and two 42-unit slices do not fit inside 36 -- Godot
# resolves that by squashing both, and the chip renders as mush. client's
# UI.SKIN_GEOM carries the matching numbers.
BIG = dict(size=128, pad=14, radius=10)      # slice 42, bleed 14
SMALL = dict(size=64, pad=6, radius=6)       # slice 22, bleed 6

TMP = pathlib.Path(tempfile.mkdtemp(prefix="romanui-"))


def run(*args: str) -> None:
    """magick, always sRGB with a real alpha channel.

    Without the explicit colorspace a layer containing only black is written as
    grayscale, and compositing a coloured body over a grayscale base converts the
    whole thing to grey. That is not subtle: it once turned the gold button white.
    """
    subprocess.run(["magick", "-colorspace", "sRGB", *args[:-1], "PNG32:" + str(args[-1])],
                   check=True)


def shade_hex(hex_colour: str, factor: float) -> str:
    h = hex_colour.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    f = lambda c: max(0, min(255, int(c * factor)))
    return "#%02X%02X%02X" % (f(r), f(g), f(b))


def t(tag: str) -> pathlib.Path:
    return TMP / (tag + ".png")


# --- materials ---------------------------------------------------------------

def parchment_tile(size: int, base: str, dest: pathlib.Path) -> None:
    """Aged paper: fine fibre under a slow stain, both grey, both tiling.

    Built from noise rather than from `plasma:` -- which is what this did first,
    and plasma cost two things. It carries hue of its own, so the parchment came
    out faintly pink in one corner and green in another; and it has large-scale
    structure, so blending a rolled copy over itself to hide the seam left a
    visible quadrant line instead.

    `-virtual-pixel tile` before each blur is what makes both octaves wrap, so
    the tile meets itself exactly and no seam-hiding trick is needed.
    `-colorspace Gray` is what keeps the colour the base colour's alone.
    """
    # the fibre: one pixel of grain
    run("-size", f"{size}x{size}", "xc:", "+noise", "Random",
        "-virtual-pixel", "tile", "-blur", "0x0.7",
        "-colorspace", "Gray", "-normalize", "-level", "38%,62%", t("pfib"))
    # the stain: slow, uneven ageing across the whole sheet
    run("-size", f"{size}x{size}", "xc:", "+noise", "Random",
        "-virtual-pixel", "tile", "-blur", "0x30",
        "-colorspace", "Gray", "-normalize", t("pstain"))
    run("-size", f"{size}x{size}", f"xc:{base}", t("pflat"))
    run(str(t("pflat")), str(t("pfib")), "-compose", "blend",
        "-define", "compose:args=6", "-composite",
        str(t("pstain")), "-compose", "blend",
        # 4%, and it is still the loudest thing here. This is a GROUND: every
        # list in the game is read on top of it, and anything you can see as a
        # pattern is something competing with a label.
        "-define", "compose:args=4", "-composite", dest)


def marble_tile(size: int, dest: pathlib.Path, base: str = RAIL) -> None:
    """Marble: random noise blurred into veins, then lit as a relief.

    -virtual-pixel tile before the blur is the whole trick for seamlessness --
    it makes the blur wrap at the edges, so the tile meets itself.
    """
    run("-size", f"{size}x{size}", "xc:", "+noise", "Random",
        "-virtual-pixel", "tile", "-blur", "0x3",
        "-shade", "118x22", "-normalize", t("veins"))
    run("-size", f"{size}x{size}", f"xc:{base}", t("flat"))
    # Blended at 14%, not composited at full strength. Stone in a UI has to be
    # legible as a SURFACE and invisible as a pattern -- at full strength the
    # veining competes with the labels sitting on it.
    run(str(t("flat")), str(t("veins")), "-compose", "blend",
        "-define", "compose:args=14", "-composite", dest)


def fabric(size: int, top: str, bottom: str, dest: pathlib.Path) -> None:
    """Dyed cloth: a vertical fall of light with a tight weave in it."""
    run("-size", f"{size}x{size}", f"gradient:{top}-{bottom}",
        "-attenuate", "0.22", "+noise", "Gaussian", "-blur", "0x0.4", dest)


# --- the carving -------------------------------------------------------------

def relief(size: int, draw: list[str], dest: pathlib.Path, blur: float = 3.0,
           azimuth: int = 135, elevation: int = 30) -> None:
    """A lit bevel from a height map.

    `draw` paints the raised shape in white on black. Blurring turns the hard
    edge into a ramp, and -shade lights that ramp from the upper left -- which is
    what the eye reads as depth. The result is grey; the caller composites it
    over the coloured body in Overlay so it darkens one side and lightens the
    other without tinting anything.
    """
    run("-size", f"{size}x{size}", "xc:black", "-fill", "white", *draw,
        "-blur", f"0x{blur}", "-shade", f"{azimuth}x{elevation}", "-normalize", dest)


def rounded(lo: int, hi: int, radius: int) -> str:
    return f"roundrectangle {lo},{lo} {hi},{hi} {radius},{radius}"


def plate(name: str, geom: dict, body: str, *, texture: pathlib.Path | None = None,
          gradient: tuple[str, str] | None = None,
          frame: str = GOLD, frame_px: int = 3,
          double_rule: bool = True, carve: bool = True, sunk: bool = False,
          shadow: bool = True, carve_strength: int = 72,
          dest: pathlib.Path | None = None) -> None:
    """One nine-slice surface: shadow, material, carved frame, rules.

    Ornament goes in the CORNERS and nowhere else. A nine-slice never stretches
    its four corner tiles, stretches the edges along one axis and the centre
    along both -- so a motif on an edge smears, while a plain rule stretches
    invisibly and a rosette in a corner stays a rosette at any size.
    """
    size, pad, radius = geom["size"], geom["pad"], geom["radius"]
    lo, hi = pad, size - 1 - pad
    shape = rounded(lo, hi, radius)
    out = (dest or OUT) / (name + ".png")

    # 1. the shadow the plate casts
    if shadow:
        run("-size", f"{size}x{size}", "xc:none", "-fill", "#00000070",
            "-draw", rounded(lo, hi + 4, radius).replace(f"{lo},{lo}", f"{lo},{lo + 4}"),
            "-blur", "0x5", t("sh"))
    else:
        run("-size", f"{size}x{size}", "xc:none", t("sh"))

    # 2. the material, clipped to the plate
    if texture is not None:
        run(str(texture), "-resize", f"{size}x{size}!", t("mat"))
    elif gradient is not None:
        run("-size", f"{size}x{size}", f"gradient:{gradient[0]}-{gradient[1]}", t("mat"))
    else:
        run("-size", f"{size}x{size}", f"xc:{body}", t("mat"))
    run("-size", f"{size}x{size}", "xc:none", "-fill", "white", "-draw", shape, t("mask"))
    run(str(t("mat")), str(t("mask")), "-alpha", "off",
        "-compose", "CopyOpacity", "-composite", t("b"))

    # 3. the carve: a raised (or sunk) band following the plate's own outline
    if carve:
        band = max(2, frame_px + 3)
        relief(size, ["-stroke", "white", "-strokewidth", str(band),
                      "-fill", "none", "-draw", shape],
               t("rel"), blur=2.6, azimuth=315 if sunk else 135)
        run(str(t("b")), str(t("rel")), "-compose", "Overlay",
            "-define", f"compose:args={carve_strength}", "-composite",
            str(t("mask")), "-alpha", "off", "-compose", "CopyOpacity", "-composite", t("b"))

    # 4. the frame, and the thin second rule inside it that says "made"
    draw = ["-fill", "none", "-stroke", frame, "-strokewidth", str(frame_px * 2), "-draw", shape]
    if double_rule:
        inset = frame_px + 4
        draw += ["-stroke", shade_hex(frame, 1.25), "-strokewidth", "1",
                 "-draw", rounded(lo + inset, hi - inset, max(2, radius - inset))]
    # a lit rim along the top and a shaded foot along the bottom
    lit = shade_hex(body if gradient is None else gradient[0], 1.30)
    foot = shade_hex(body if gradient is None else gradient[1], 0.62)
    draw += ["-stroke", lit, "-strokewidth", "1",
             "-draw", f"line {lo + radius},{lo + frame_px} {hi - radius},{lo + frame_px}",
             "-stroke", foot, "-strokewidth", "1",
             "-draw", f"line {lo + radius},{hi - frame_px} {hi - radius},{hi - frame_px}"]
    run(str(t("b")), *draw, t("b"))

    # 5. body over its own shadow
    run(str(t("sh")), str(t("b")), "-compose", "over", "-composite", str(out))
    print("  %-16s %s" % (name, out.relative_to(ROOT)))


def _disc(cx: float, cy: float, r: float) -> str:
    """ImageMagick's `circle` takes a CENTRE and a point ON the perimeter, not a
    radius. Passing the radius as that second coordinate draws a circle of
    radius |cy - r| -- which for a ring of radius 95 in a 192 box came out as a
    dot two pixels across. This is the conversion, written once."""
    return f"circle {cx:.2f},{cy:.2f} {cx:.2f},{cy - r:.2f}"


def _cut_alpha(size: int, keep: list[str], drop: list[str], dest: pathlib.Path) -> None:
    """An alpha channel drawn as greyscale: white is kept, black is cut away.

    -fill none -draw simply draws nothing, which is why the first attempt at a
    hollow frame came out solid. Building the mask as a grey image and copying
    it into the alpha is the operation that actually removes pixels.
    """
    run("-size", f"{size}x{size}", "xc:black", "-fill", "white", *keep,
        "-fill", "black", *drop, dest)


def portrait_ring(size: int, dest: pathlib.Path) -> None:
    """The carved stone collar around the player's portrait, with a gold bead.

    A circle cannot be nine-sliced, so this is a plain texture drawn at 2x the
    slot it fills and laid over the avatar button. The hole is genuinely
    transparent -- the portrait shows through it rather than being masked by it,
    so a face is never clipped by its own frame.
    """
    c = size / 2.0
    outer = c - 2
    inner = c * 0.68
    mid = (outer + inner) / 2.0

    _cut_alpha(size, ["-draw", _disc(c, c, outer)], ["-draw", _disc(c, c, inner)], t("ring_a"))
    # lit as a relief, so it reads as a collar rather than a printed circle
    relief(size, ["-stroke", "white", "-strokewidth", str(int(outer - inner)),
                  "-fill", "none", "-draw", _disc(c, c, mid)],
           t("ring_rel"), blur=size * 0.030)
    run("-size", f"{size}x{size}", f"xc:{RAIL}", str(t("ring_rel")),
        "-compose", "Overlay", "-composite", t("ring_body"))
    run(str(t("ring_body")), str(t("ring_a")), "-alpha", "off",
        "-compose", "CopyOpacity", "-composite", t("ring_cut"))
    # a gold bead on the inner lip and a stone one outside
    run(str(t("ring_cut")), "-fill", "none",
        "-stroke", GOLD, "-strokewidth", str(max(2, int(size * 0.028))),
        "-draw", _disc(c, c, inner + size * 0.016),
        "-stroke", STONE_EDGE, "-strokewidth", str(max(2, int(size * 0.020))),
        "-draw", _disc(c, c, outer - size * 0.012),
        str(dest))
    print("  %-16s %s" % ("portrait_ring", dest.relative_to(ROOT)))


def rail_frame(dest: pathlib.Path) -> None:
    """The rail's carved edge: a nine-slice whose centre is genuinely empty.

    Only the border is drawn, so the marble tiling underneath shows through the
    middle and the frame stretches to any height without smearing the stone.
    """
    size = 128
    lo, hi = 1, size - 2
    band = 11
    _cut_alpha(size,
               ["-draw", f"rectangle {lo},{lo} {hi},{hi}"],
               ["-draw", f"rectangle {lo + band},{lo + band} {hi - band},{hi - band}"],
               t("rf_a"))
    relief(size, ["-stroke", "white", "-strokewidth", str(band),
                  "-fill", "none",
                  "-draw", f"rectangle {lo + band // 2},{lo + band // 2} "
                           f"{hi - band // 2},{hi - band // 2}"],
           t("rf_rel"), blur=3.0)
    run("-size", f"{size}x{size}", f"xc:{shade_hex(RAIL, 0.86)}", str(t("rf_rel")),
        "-compose", "Overlay", "-define", "compose:args=85", "-composite", t("rf_body"))
    run(str(t("rf_body")), str(t("rf_a")), "-alpha", "off",
        "-compose", "CopyOpacity", "-composite",
        "-fill", "none", "-stroke", STONE_EDGE, "-strokewidth", "2",
        "-draw", f"rectangle {lo},{lo} {hi},{hi}", str(dest))
    print("  %-16s %s" % ("rail_frame", dest.relative_to(ROOT)))


def main() -> int:
    if shutil.which("magick") is None:
        print("ImageMagick is not on PATH", file=sys.stderr)
        return 1
    for d in (OUT, TILE, CHROME):
        d.mkdir(parents=True, exist_ok=True)

    print("materials ->", TMP)
    parchment_tile(256, PANEL, t("parch_panel"))
    parchment_tile(256, PANEL_HIGH, t("parch_high"))
    parchment_tile(256, BG, t("parch_bg"))
    marble_tile(256, t("marble"))
    # Two more stones: the column the rail is cut from, and the plates set into
    # it. They differ by value rather than by outline, because a plate that has
    # to be found by its border is a plate you cannot see at a glance.
    marble_tile(256, t("marble_deep"), shade_hex(RAIL, 0.86))
    marble_tile(256, t("marble_plate"), shade_hex(RAIL, 1.07))
    fabric(128, shade_hex(BANNER, 1.30), shade_hex(BANNER, 0.72), t("cloth"))
    fabric(128, shade_hex(BANNER, 1.45), shade_hex(BANNER, 0.85), t("cloth_hi"))
    fabric(128, shade_hex(BANNER, 0.80), shade_hex(BANNER, 0.55), t("cloth_lo"))
    fabric(128, shade_hex(DANGER, 0.86), shade_hex(DANGER, 0.52), t("cloth_danger"))
    fabric(128, shade_hex(DANGER, 0.62), shade_hex(DANGER, 0.40), t("cloth_danger_lo"))

    # The two grounds, tiled behind everything.
    print("tiles ->", TILE.relative_to(ROOT))
    parchment_tile(256, BG, TILE / "parchment.png")
    marble_tile(256, TILE / "marble.png", shade_hex(RAIL, 0.86))
    print("  parchment.png, marble.png")

    print("surfaces ->", OUT.relative_to(ROOT))
    # Cards. Parchment, a gold hairline, a carved lip.
    plate("panel", BIG, PANEL, texture=t("parch_panel"), frame=LINE, frame_px=2)
    plate("panel_high", BIG, PANEL_HIGH, texture=t("parch_high"), frame=GOLD, frame_px=2)
    plate("panel_gold", BIG, PANEL_HIGH, texture=t("parch_high"), frame=GOLD, frame_px=4)
    # Locked: cut INTO the stone rather than raised off it. Lighting the bevel
    # from the opposite corner is the whole difference.
    plate("panel_sunk", BIG, RAIL, texture=t("marble"), frame=STONE_EDGE, frame_px=2,
          sunk=True, shadow=False, double_rule=False)

    # The one button a screen is about.
    plate("primary", BIG, BANNER, texture=t("cloth"), frame=GOLD, frame_px=3)
    plate("primary_hover", BIG, BANNER, texture=t("cloth_hi"), frame=shade_hex(GOLD, 1.2), frame_px=3)
    plate("primary_press", BIG, BANNER, texture=t("cloth_lo"), frame=GOLD_DEEP, frame_px=3,
          sunk=True, shadow=False)

    # Irreversible. Darker, and framed in bronze rather than gold, so "sell this
    # forever" and "buy this" are never the same button at a glance.
    plate("danger", BIG, DANGER, texture=t("cloth_danger"), frame=STONE_EDGE, frame_px=3)
    plate("danger_press", BIG, DANGER, texture=t("cloth_danger_lo"), frame=shade_hex(STONE_EDGE, 0.7),
          frame_px=3, sunk=True, shadow=False)

    # Secondary.
    plate("ghost", BIG, PANEL_HIGH, texture=t("parch_high"), frame=GOLD_DEEP, frame_px=2,
          double_rule=False)
    plate("ghost_press", BIG, BG, texture=t("parch_bg"), frame=LINE, frame_px=2,
          sunk=True, shadow=False, double_rule=False)
    plate("disabled", BIG, RAIL, texture=t("marble"), frame=shade_hex(STONE_EDGE, 0.9),
          frame_px=2, carve=False, shadow=False, double_rule=False)

    # Chrome.
    plate("banner", BIG, BANNER, texture=t("cloth"), frame=GOLD, frame_px=3, double_rule=True)

    # Small family: the stamped things.
    plate("chip", SMALL, RAIL, texture=t("marble"), frame=GOLD, frame_px=2,
          sunk=True, shadow=False, double_rule=False)
    plate("plaque", SMALL, RAIL, texture=t("marble"), frame=STONE_EDGE, frame_px=2,
          double_rule=False)
    # A nav entry is its own carved plate, and the open one is an imperial plate.
    # They were a flat strip and a lit slab; on a marble column that read as a
    # list of words rather than as nine stones set into it.
    plate("nav", SMALL, RAIL, texture=t("marble_plate"), frame=STONE_EDGE, frame_px=3,
          double_rule=False, carve_strength=100)
    plate("nav_active", SMALL, BANNER, texture=t("cloth"), frame=GOLD, frame_px=3,
          double_rule=False, carve_strength=100)
    plate("rail_active", SMALL, PANEL, texture=t("parch_panel"), frame=GOLD, frame_px=2,
          double_rule=False)

    print("chrome ->", CHROME.relative_to(ROOT))
    portrait_ring(192, CHROME / "portrait_ring.png")
    rail_frame(CHROME / "rail_frame.png")

    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
