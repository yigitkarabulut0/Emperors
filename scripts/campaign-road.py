#!/usr/bin/env python3
"""Find the road on each campaign map, and put the twelve stage nodes on it.

The maps (art/reference/campaign_map_NN.png, 776x1030) each paint one winding
road from the bottom of the frame to a keep at the top. The twelve nodes of a
chapter stand ON that road -- which means their places are the painting's, not
a designer's guess, and they have to come off the pixels like every other
measurement in this repository (CLAUDE.md: measure, don't eyeball).

How: the road is the one broad, bright, tan thing that runs the height of the
frame. We seed on the bottom rows, then walk upward one row at a time, keeping
inside a window around the last row's centre -- a seam, so a tan roof or a
patch of lava somewhere else in the frame cannot pull the path off the road.
The twelve nodes are then sampled along that seam at even heights.

Writes client/layout/campaign_nodes.json, and with --qa also a picture of each
map with its nodes drawn on, to be looked at.
"""
import json
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = os.path.join(ROOT, "art", "reference")
OUT = os.path.join(ROOT, "client", "layout", "campaign_nodes.json")
QA = os.path.join(ROOT, "art", "qa", "campaign_nodes.png")

# What a dirt road is made of, and how much each channel matters. The gap
# between red and blue is what separates tan from grass, rock, water and snow;
# green sitting between the two is what separates it from lava.
ROAD = (198, 168, 126)
WEIGHT = (1.0, 1.0, 1.2)

# Where the nodes stop. The bottom is the frame's own edge; the TOP is not a
# fraction of the frame at all -- it is where the road itself runs out, which
# on one map is the gate of a keep at a tenth of the way down and on another is
# a pass that climbs almost to the sky. Node twelve used to be pinned to a
# fraction, and on the Vale it stood in a lake.
BOTTOM_PAD = 0.045
TOP_MARGIN = 26          # units below the road's last tan row
# How far the seam may move from one row to the next, and how wide the seed is.
WINDOW = 18
SEED_ROWS = 40
# What still counts as road, as a multiple of how tan the road is down where it
# is unmistakable.
ROAD_SLACK = 1.55
# The two stages a chapter puts a boss at, and how much more room a gap beside
# one gets. A boss node is a crowned skull over its ring and stands 118 units
# tall against a field node's 87; at an even spacing its crown sat on the number
# of the mile above it. The gaps either side of a boss are widened instead, and
# every node still stands on the road -- its x is the seam's at its own y.
BOSS_STAGES = (6, 12)
BOSS_GAP = 1.62


def road_score(px, x, y):
    c = px[x, y]
    d = sum(w * abs(c[i] - ROAD[i]) for i, w in enumerate(WEIGHT))
    return d


def seam(img):
    """The road's centre and how tan it was, row by row, bottom to top."""
    w, h = img.size
    px = img.load()

    # The seed: the column with the best average roadness over the bottom rows,
    # looked for across the whole width.
    best_x, best_d = w // 2, None
    for x in range(8, w - 8):
        d = sum(road_score(px, x, y) for y in range(h - SEED_ROWS, h)) / SEED_ROWS
        if best_d is None or d < best_d:
            best_x, best_d = x, d

    xs = [0] * h
    score = [0.0] * h
    x = best_x
    for y in range(h - 1, -1, -1):
        lo, hi = max(4, x - WINDOW), min(w - 4, x + WINDOW)
        # The best column in the window, by the row's own roadness, smoothed
        # over a few columns so a pebble cannot win.
        pick, pd, raw = x, None, 0.0
        for cx in range(lo, hi + 1):
            d = sum(road_score(px, min(w - 1, max(0, cx + o)), y) for o in (-3, 0, 3)) / 3.0
            # A gentle pull toward where the road was, so the seam is a road
            # and not a scatter of the tannest pixels in each row.
            pulled = d + abs(cx - x) * 1.2
            if pd is None or pulled < pd:
                pick, pd, raw = cx, pulled, d
        x = pick
        xs[y] = x
        score[y] = raw
    return xs, score


def road_top(score, h):
    """The highest row the road still reaches.

    The road is unmistakable in the bottom half of every map, so what it scores
    there is the yardstick; the top is the first row on the way up where the
    seam stops looking like a road for a stretch, which is the sky, a keep or a
    mountainside.
    """
    smoothed = smooth(score, 8)
    base = sorted(smoothed[h // 2:])[len(smoothed[h // 2:]) // 2]
    limit = base * ROAD_SLACK
    run = 0
    for y in range(h - 1, -1, -1):
        if smoothed[y] > limit:
            run += 1
            if run >= 12:
                return y + run
        else:
            run = 0
    return 0


def smooth(xs, k=15):
    out = []
    for i in range(len(xs)):
        lo, hi = max(0, i - k), min(len(xs), i + k + 1)
        out.append(sum(xs[lo:hi]) / (hi - lo))
    return out


def nodes_for(path, count=12):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    raw, score = seam(img)
    xs = smooth(raw)
    top = min(h - 1, road_top(score, h) + TOP_MARGIN)
    bottom = int(h * (1.0 - BOTTOM_PAD))
    if top >= bottom - 200:
        top = bottom - 200

    # The gaps, walked from stage one at the bottom to the last at the keep.
    gaps = []
    for i in range(1, count + 1):
        if i in BOSS_STAGES or i - 1 in BOSS_STAGES:
            gaps.append(BOSS_GAP)
        else:
            gaps.append(1.0)
    gaps = gaps[1:]                      # count-1 gaps between count stages
    span = float(bottom - top)
    unit = span / sum(gaps)

    out = []
    y = float(bottom)
    for i in range(count):
        if i > 0:
            y -= gaps[i - 1] * unit
        row = int(round(min(max(y, 0), h - 1)))
        out.append([int(round(xs[row])), row])
    return out, img


def main():
    qa = "--qa" in sys.argv
    maps = sorted(f for f in os.listdir(REF) if f.startswith("campaign_map_"))
    data = {}
    shots = []
    for name in maps:
        key = name[len("campaign_map_"):-len(".png")]
        pts, img = nodes_for(os.path.join(REF, name))
        data[key] = pts
        print(f"{name}: top {pts[-1][1]:4d}  " + " ".join(f"{x},{y}" for x, y in pts))
        if qa:
            shot = img.copy()
            d = ImageDraw.Draw(shot)
            for i, (x, y) in enumerate(pts):
                r = 26 if i + 1 in (6, 12) else 20
                d.ellipse([x - r, y - r, x + r, y + r], outline=(255, 220, 60), width=5)
                d.text((x - 6, y - 8), str(i + 1), fill=(255, 255, 255))
            shots.append(shot)
    with open(OUT, "w") as f:
        json.dump(data, f, indent=1)
        f.write("\n")
    print("wrote", os.path.relpath(OUT, ROOT))
    if qa and shots:
        cols = 5
        rows = (len(shots) + cols - 1) // cols
        sw, sh = shots[0].size
        scale = 0.42
        tw, th = int(sw * scale), int(sh * scale)
        sheet = Image.new("RGB", (cols * tw, rows * th), (11, 22, 32))
        for i, s in enumerate(shots):
            sheet.paste(s.resize((tw, th), Image.LANCZOS), ((i % cols) * tw, (i // cols) * th))
        sheet.save(QA)
        print("wrote", os.path.relpath(QA, ROOT))


if __name__ == "__main__":
    main()
