#!/usr/bin/env python3
"""Builds the navigation rail's seven icons as SVG, then rasterises them to PNG.

Why these are authored rather than generated: at 34 px on a dark rail, a painterly
render is mush. The rail is the only chrome visible on every screen in the game,
so it gets crisp geometry instead. Everything here is one flat white shape on
transparency, which lets the shell modulate a single texture gold when active and
dim when not -- exactly the state swap the letter glyphs used to get for free.

Holes (a castle gate, a helm's eye slit) are extra subpaths under fill-rule
evenodd, so an icon stays a single modulatable path with no background colour.

Usage: scripts/gen-ui-icons.py [--out DIR] [--px 96]
"""
import argparse
import math
import pathlib
import subprocess
import sys

VIEW = 32.0  # every icon is authored on a 32x32 grid


# --- tiny path helpers -------------------------------------------------------

def poly(*points: tuple[float, float]) -> str:
    """A closed subpath. 'M x,y x,y ...' implies lineto after the first pair."""
    return "M" + " ".join(f"{x:.3g},{y:.3g}" for x, y in points) + "Z"


def rect(x: float, y: float, w: float, h: float) -> str:
    return poly((x, y), (x + w, y), (x + w, y + h), (x, y + h))


def circle(cx: float, cy: float, r: float) -> str:
    """Two half-arcs, so a circle can live inside a path with everything else."""
    return (f"M{cx - r:.3g},{cy:.3g}"
            f"a{r:.3g},{r:.3g} 0 1 0 {2 * r:.3g},0"
            f"a{r:.3g},{r:.3g} 0 1 0 {-2 * r:.3g},0Z")


def crenellated(x: float, w: float, top: float, bottom: float, merlons: int = 3) -> str:
    """A tower: solid body, with square merlons standing on top of it.

    Drawn as one outline that walks up the left side, across the battlement, and
    back down -- rather than a body plus separate merlon rects, which would leave
    hairline seams once the SVG is scaled to an arbitrary pixel size.
    """
    mw = w / (2 * merlons - 1)   # merlon and gap are the same width
    h = 2.6                      # how far a merlon stands above the wall walk
    pts = [(x, bottom), (x, top + h)]
    for i in range(merlons):
        mx = x + i * 2 * mw
        pts += [(mx, top), (mx + mw, top), (mx + mw, top + h)]
        if i < merlons - 1:
            pts += [(mx + 2 * mw, top + h)]
    pts += [(x + w, top + h), (x + w, bottom)]
    return poly(*pts)


def rotated(subpaths: list[str], deg: float, cx: float, cy: float) -> str:
    """Rotation baked into coordinates. Only straight segments are transformed,
    which is all the rotated icons use -- an 'a' arc would need its own handling."""
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    out = []
    for sp in subpaths:
        assert "a" not in sp and "A" not in sp, "rotate() cannot transform arcs"
        pts = []
        for pair in sp[1:-1].split():
            px, py = (float(v) for v in pair.split(","))
            dx, dy = px - cx, py - cy
            pts.append((cx + dx * ca - dy * sa, cy + dx * sa + dy * ca))
        out.append(poly(*pts))
    return " ".join(out)


# --- the seven icons ---------------------------------------------------------

def keep() -> str:
    """Family / The Keep: a tall central tower flanked by two shorter ones.

    An earlier version made all three towers nearly the same height, which at
    34 px collapsed into one squat crenellated wall. The silhouette needs a clear
    vertical hierarchy to read as a castle rather than as battlements.
    """
    return " ".join([
        rect(2, 17, 28, 10),                    # curtain wall
        crenellated(2, 7.5, 12, 27),            # left tower
        crenellated(22.5, 7.5, 12, 27),         # right tower
        crenellated(11.5, 9, 3, 27),            # the keep itself, much taller
        "M13,27 L13,20.5 A3,3 0 0 1 19,20.5 L19,27 Z",   # gate (hole)
    ])


def fields() -> str:
    """Collect / Fields: one wheat ear.

    Three overlapping ears read as a blob at 34 px -- the kernels of one ear land
    in the gaps of the next and the silhouette closes up. A single bold ear with
    one blade keeps the outline open, which is what makes it legible small.
    """
    parts = [rect(15.1, 15, 1.8, 14)]                            # stalk
    parts.append(poly((16, 1.5), (13.5, 6.8), (18.5, 6.8)))      # apex kernel
    for i in range(4):
        y = 6.0 + i * 3.5
        for side in (-1, 1):
            parts.append(poly(
                (16, y + 0.4),                                   # rooted on the stalk
                (16 + side * 5.3, y - 2.3),                      # tip, angled up and out
                (16 + side * 2.9, y + 3.5),                      # belly
            ))
    parts.append(poly((16.6, 20.5), (25.5, 16.8), (18, 25)))     # blade
    return " ".join(parts)


def armory() -> str:
    """Inventory / Armory: a banded chest."""
    return " ".join([
        # arched lid + square body as one silhouette
        "M4,27 L4,16 A12,9 0 0 1 28,16 L28,27 Z",
        rect(4, 16.4, 24, 1.6),                 # lid seam (hole)
        rect(14.2, 14.5, 3.6, 6),               # lock plate (hole)
        circle(16, 21.5, 1.15),                 # keyhole (hole, punched back in)
    ])


def market() -> str:
    """Shop / Market: a striped awning over a counter.

    The hanging rail above the canopy merged into it at small sizes and the whole
    thing read as a bench, so the canopy carries the shape alone: taller, with a
    deeper scalloped hem that survives the downscale.
    """
    hem = "M2,18 "
    for _ in range(4):
        hem += "a3.5,3.6 0 0 0 7,0 "
    hem += "L26.5,5 L5.5,5 Z"
    return " ".join([
        hem,                                    # canopy
        rect(11.3, 5, 2.4, 11),                 # stripe (hole)
        rect(18.3, 5, 2.4, 11),                 # stripe (hole)
        rect(4, 21.5, 24, 3),                   # counter top
        rect(6, 24.5, 2.8, 3.5),                # legs
        rect(23.2, 24.5, 2.8, 3.5),
    ])


def barracks() -> str:
    """Soldiers / Barracks: a great helm."""
    return " ".join([
        "M7.5,27 L7.5,14 A8.5,8.5 0 0 1 24.5,14 L24.5,27 Z",
        rect(9, 14.5, 14, 2.8),                 # eye slit (hole)
        circle(13, 21.5, 1.1),                  # breaths (holes)
        circle(16, 22.4, 1.1),
        circle(19, 21.5, 1.1),
        rect(14.8, 3.5, 2.4, 4),                # crest spike
    ])


def war_gate() -> str:
    """Attack / War Gate: crossed swords."""
    def sword() -> list[str]:
        # Thin blades cross into something closer to scissors than swords. The
        # blade is wide enough here to stay a blade after the 34 px downscale,
        # and the pommel is a distinct block so neither end reads as a point.
        return [
            poly((16, 2), (18.7, 6.8), (18.7, 17), (13.3, 17), (13.3, 6.8)),
            rect(9.2, 17, 13.6, 2.9),                            # crossguard
            rect(14.5, 19.9, 3, 5),                              # grip
            poly((13.4, 24.9), (18.6, 24.9), (17.5, 28.6), (14.5, 28.6)),
        ]
    # Pivot at the guard rather than the blade's middle, and splay wide. Pivoting
    # at the centre stacks both crossguards on the same point and the pair reads
    # as a bowtie; pivoting low fans the blades apart and separates the two hilts.
    return rotated(sword(), 42, 16, 20) + " " + rotated(sword(), -42, 16, 20)


def territory() -> str:
    """Territory / Map Table: a folded map with a marker punched out of it."""
    return " ".join([
        poly((2.5, 8.5), (11.5, 5.5), (20.5, 8.5), (29.5, 5.5),
             (29.5, 23.5), (20.5, 26.5), (11.5, 23.5), (2.5, 26.5)),
        poly((11, 6), (12, 6), (12, 24), (11, 24)),      # fold (hole)
        poly((20, 8.5), (21, 8.5), (21, 26.5), (20, 26.5)),
        # map pin: a teardrop hole
        "M16,11 A3.4,3.4 0 0 1 16,17.8 A3.4,3.4 0 0 1 16,11 Z"
        "M13.4,15.5 L18.6,15.5 L16,21.5 Z",
    ])


ICONS = {
    "keep": keep, "fields": fields, "armory": armory, "market": market,
    "barracks": barracks, "war_gate": war_gate, "territory": territory,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="art/ui")
    ap.add_argument("--promote", default="client/assets/ui")
    ap.add_argument("--px", type=int, default=96, help="raster size; 3x the 32px rail slot")
    args = ap.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    out = root / args.out
    promote = root / args.promote
    out.mkdir(parents=True, exist_ok=True)
    promote.mkdir(parents=True, exist_ok=True)

    for name, fn in ICONS.items():
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {VIEW:g} {VIEW:g}" '
            f'width="{VIEW:g}" height="{VIEW:g}">'
            f'<path fill="#FFFFFF" fill-rule="evenodd" d="{fn()}"/></svg>'
        )
        svg_path = out / f"{name}.svg"
        svg_path.write_text(svg)
        png_path = promote / f"{name}.png"
        subprocess.run(
            ["rsvg-convert", "-w", str(args.px), "-h", str(args.px),
             "-o", str(png_path), str(svg_path)],
            check=True,
        )
        print(f"  {name:<10} {svg_path.relative_to(root)} -> {png_path.relative_to(root)}")
    print(f"{len(ICONS)} icons at {args.px}px")
    return 0


if __name__ == "__main__":
    sys.exit(main())
