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

SIZE = 96        # nine-slice source size
RADIUS = 20      # corner radius, comfortably inside the slice margin of 28


def run(args):
    subprocess.run(args, check=True)


def shade(hex_colour, factor):
    """Lightens (factor > 1) or darkens (factor < 1) a hex colour."""
    h = hex_colour.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    f = lambda c: max(0, min(255, int(c * factor)))
    return "#%02X%02X%02X" % (f(r), f(g), f(b))


def slice_png(name, top, bottom, border, border_px=2, lit=1.25, shade_bottom=0.72):
    """One rounded, vertically graded nine-slice with a lit top and shaded foot."""
    out = OUT / (name + ".png")
    grad = OUT / ("_grad_" + name + ".png")
    mask = OUT / ("_mask_" + name + ".png")

    # The body: a vertical gradient, light at the top the way a lit surface is.
    run(["magick", "-size", f"{SIZE}x{SIZE}",
         f"gradient:{top}-{bottom}", str(grad)])

    # A rounded-rectangle mask, so the corners are actually round rather than
    # relying on the StyleBox to clip something square.
    run(["magick", "-size", f"{SIZE}x{SIZE}", "xc:none", "-fill", "white",
         "-draw", f"roundrectangle 0,0 {SIZE-1},{SIZE-1} {RADIUS},{RADIUS}",
         str(mask)])

    # Border, plus a brighter hairline along the top edge and a darker one along
    # the bottom: that pair is what makes a flat rectangle read as a raised
    # surface, and it costs two lines.
    inner = RADIUS - border_px
    run(["magick", str(grad), str(mask), "-alpha", "off",
         "-compose", "CopyOpacity", "-composite",
         "-fill", "none",
         "-stroke", border, "-strokewidth", str(border_px * 2),
         "-draw", f"roundrectangle 0,0 {SIZE-1},{SIZE-1} {RADIUS},{RADIUS}",
         "-stroke", shade(top, lit), "-strokewidth", str(border_px),
         "-draw", f"line {RADIUS},{border_px} {SIZE-1-RADIUS},{border_px}",
         "-stroke", shade(bottom, shade_bottom), "-strokewidth", str(border_px),
         "-draw", f"line {RADIUS},{SIZE-1-border_px} {SIZE-1-RADIUS},{SIZE-1-border_px}",
         str(out)])

    grad.unlink(missing_ok=True)
    mask.unlink(missing_ok=True)
    print("  %-22s %s -> %s" % (name, top, bottom))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    print("nine-slice skins ->", OUT)

    # Surfaces.
    slice_png("panel",        shade(PANEL, 1.22),      PANEL,               LINE)
    slice_png("panel_high",   shade(PANEL_HIGH, 1.20), PANEL_HIGH,          shade(LINE, 1.2))
    slice_png("panel_sunk",   shade(BG, 0.88),         shade(BG, 1.10),     LINE)
    slice_png("panel_gold",   shade(PANEL_HIGH, 1.18), PANEL,               GOLD_DEEP)

    # The primary button, and the two states it needs to look pressable.
    slice_png("gold",         shade(GOLD, 1.10),       GOLD_DEEP,           shade(GOLD_DEEP, 0.8))
    slice_png("gold_hover",   shade(GOLD, 1.20),       shade(GOLD_DEEP, 1.12), shade(GOLD_DEEP, 0.9))
    slice_png("gold_press",   GOLD_DEEP,               shade(GOLD_DEEP, 0.80), shade(GOLD_DEEP, 0.7))
    slice_png("danger",       shade(DANGER, 1.12),     shade(DANGER, 0.78),  shade(DANGER, 0.62))
    slice_png("danger_press", shade(DANGER, 0.86),     shade(DANGER, 0.62),  shade(DANGER, 0.55))

    # Ghost buttons: a raised surface that is clearly not the primary action.
    slice_png("ghost",        shade(PANEL_HIGH, 1.16), PANEL,               LINE)
    slice_png("ghost_press",  shade(PANEL, 0.92),      shade(PANEL, 0.80),  LINE)
    slice_png("disabled",     shade(PANEL, 1.04),      shade(PANEL, 0.92),  shade(LINE, 0.8))
    print("done")


if __name__ == "__main__":
    sys.exit(main())
