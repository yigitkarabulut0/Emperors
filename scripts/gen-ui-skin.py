#!/usr/bin/env python3
"""Nine-slice skins for panels and buttons.

StyleBoxFlat can only draw a flat colour. Everything in this game was therefore a
flat rectangle with a flat border, which reads as a wireframe rather than a made
object -- no material, no light, nothing to suggest a button is a thing you press.

These are small nine-slice textures with a vertical gradient, a lit top edge and a
shaded bottom one, so the same StyleBox machinery draws surfaces that catch light.
Generated rather than drawn by hand so the palette stays the single source of
truth: change a colour here and every panel in the game follows.

  python3 scripts/gen-ui-skin.py
"""
import pathlib, subprocess, sys

OUT = pathlib.Path(__file__).resolve().parent.parent / "client/assets/ui/skin"

# Matches Palette. Kept in one place so the skin cannot drift from the theme.
BG         = "#1B1712"
PANEL      = "#241E1A"
PANEL_HIGH = "#2E2721"
RAIL       = "#151210"
LINE       = "#3A322B"
GOLD       = "#E5C97B"
GOLD_DEEP  = "#B99A45"
DANGER     = "#D95A4E"

SIZE = 128       # nine-slice source
PAD = 14         # room around the body for the drop shadow
RADIUS = 22      # corner radius of the body itself
SLICE = PAD + RADIUS + 6   # nine-slice margin: the whole corner must sit inside it


def run(args):
    """Runs magick, always writing sRGB with a full alpha channel.

    Without this the shadow layer -- which contains nothing but black -- is saved
    as a grayscale PNG, and compositing the coloured body over a grayscale base
    converts the whole button to grey. That is not a subtle degradation: the gold
    primary button came out white.
    """
    subprocess.run(args[:1] + ["-colorspace", "sRGB"] + args[1:-1]
                   + ["PNG32:" + str(args[-1])], check=True)


def shade(hex_colour, factor):
    """Lightens (factor > 1) or darkens (factor < 1) a hex colour."""
    h = hex_colour.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    f = lambda c: max(0, min(255, int(c * factor)))
    return "#%02X%02X%02X" % (f(r), f(g), f(b))


def slice_png(name, top, bottom, border, gloss=True, shadow=True, border_px=2):
    """One rounded, graded nine-slice: drop shadow, body, gloss, rim, foot.

    The five layers are what separate a button from a coloured rectangle. A flat
    fill has no light source, so nothing about it suggests it can be pressed.
    """
    out = OUT / (name + ".png")
    tmp = lambda tag: OUT / ("_%s_%s.png" % (tag, name))
    lo, hi = PAD, SIZE - 1 - PAD
    body = f"roundrectangle {lo},{lo} {hi},{hi} {RADIUS},{RADIUS}"

    # 1. the shadow the object casts, offset down and blurred
    if shadow:
        run(["magick", "-size", f"{SIZE}x{SIZE}", "xc:none",
             "-fill", "#00000099", "-draw",
             f"roundrectangle {lo},{lo + 5} {hi},{hi + 5} {RADIUS},{RADIUS}",
             "-blur", "0x6", str(tmp("sh"))])
    else:
        run(["magick", "-size", f"{SIZE}x{SIZE}", "xc:none", str(tmp("sh"))])

    # 2. the body: a vertical gradient, lit from above
    run(["magick", "-size", f"{SIZE}x{SIZE}", f"gradient:{top}-{bottom}", str(tmp("g"))])
    run(["magick", "-size", f"{SIZE}x{SIZE}", "xc:none", "-fill", "white",
         "-draw", body, str(tmp("m"))])
    run(["magick", str(tmp("g")), str(tmp("m")), "-alpha", "off",
         "-compose", "CopyOpacity", "-composite", str(tmp("b"))])

    # 3. a gloss across the upper half, so the surface reads as curved
    if gloss:
        half = lo + (hi - lo) // 2
        run(["magick", "-size", f"{SIZE}x{SIZE}", "xc:none",
             "-fill", "#FFFFFF22", "-draw",
             f"roundrectangle {lo + 2},{lo + 2} {hi - 2},{half} {RADIUS - 2},{RADIUS - 2}",
             "-blur", "0x2", str(tmp("gl"))])
        run(["magick", str(tmp("b")), str(tmp("gl")), "-compose", "over",
             "-composite", str(tmp("m")), "-alpha", "off",
             "-compose", "CopyOpacity", "-composite", str(tmp("b"))])

    # 4. border, plus a lit rim along the top and a shaded foot along the bottom
    run(["magick", str(tmp("b")), "-fill", "none",
         "-stroke", border, "-strokewidth", str(border_px * 2), "-draw", body,
         "-stroke", shade(top, 1.35), "-strokewidth", str(border_px),
         "-draw", f"line {lo + RADIUS},{lo + border_px} {hi - RADIUS},{lo + border_px}",
         "-stroke", shade(bottom, 0.66), "-strokewidth", str(border_px),
         "-draw", f"line {lo + RADIUS},{hi - border_px} {hi - RADIUS},{hi - border_px}",
         str(tmp("b"))])

    # 5. composite the body over its own shadow
    run(["magick", str(tmp("sh")), str(tmp("b")), "-compose", "over",
         "-composite", str(out)])

    for tag in ("sh", "g", "m", "b", "gl"):
        tmp(tag).unlink(missing_ok=True)
    print("  %-22s %s -> %s" % (name, top, bottom))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    print("nine-slice skins ->", OUT)

    # Surfaces.
    slice_png("panel",        shade(PANEL, 1.22),      PANEL,               LINE, gloss=False)
    slice_png("panel_high",   shade(PANEL_HIGH, 1.20), PANEL_HIGH,          shade(LINE, 1.2), gloss=False)
    slice_png("panel_sunk",   shade(BG, 0.88),         shade(BG, 1.10),     LINE, gloss=False, shadow=False)
    slice_png("panel_gold",   shade(PANEL_HIGH, 1.18), PANEL,               GOLD_DEEP, gloss=False)

    # The primary button, and the two states it needs to look pressable.
    slice_png("gold",         shade(GOLD, 1.10),       GOLD_DEEP,           shade(GOLD_DEEP, 0.8))
    slice_png("gold_hover",   shade(GOLD, 1.20),       shade(GOLD_DEEP, 1.12), shade(GOLD_DEEP, 0.9))
    slice_png("gold_press",   GOLD_DEEP,               shade(GOLD_DEEP, 0.80), shade(GOLD_DEEP, 0.7), gloss=False, shadow=False)
    slice_png("danger",       shade(DANGER, 1.12),     shade(DANGER, 0.78),  shade(DANGER, 0.62))
    slice_png("danger_press", shade(DANGER, 0.86),     shade(DANGER, 0.62),  shade(DANGER, 0.55), gloss=False, shadow=False)

    # Ghost buttons: a raised surface that is clearly not the primary action.
    slice_png("ghost",        shade(PANEL_HIGH, 1.16), PANEL,               LINE)
    slice_png("ghost_press",  shade(PANEL, 0.92),      shade(PANEL, 0.80),  LINE, gloss=False, shadow=False)
    slice_png("disabled",     shade(PANEL, 1.04),      shade(PANEL, 0.92),  shade(LINE, 0.8), gloss=False, shadow=False)
    print("done")


if __name__ == "__main__":
    sys.exit(main())
