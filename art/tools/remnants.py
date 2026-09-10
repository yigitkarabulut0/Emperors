"""Finds ink an erase missed: the stub of a painted letter or figure left
standing just outside the rect that was meant to lift it.

usage: remnants.py [--refdir art/reference] [--assets client/assets] [--sheet out.png] [manifest ...]

The Kingdom's level bar shipped with a sliver of the painting's own gold four
pixels past its erase, and a Collect row with the ghost of a G. Both are the
same mistake: a rect measured a little short of the ink. This reads every
crop's erase rects -- the row fills that lift words off flat plates; an
inpaint repairs painted art, where detail touches every edge by nature --
looks at the shipped PNG in a thin band just outside each edge, and reports
short bright runs that touch the edge on a band that is otherwise dark
ground: the cut end of a glyph. A long run along an edge is a frame line or a
bar's rim and is left alone, and so is an edge that runs through painting
rather than plate.

Every hit is for a person to look at: a hit is a place to look, not a verdict.
Hits that were looked at and are the painting's own ink -- a title standing on
an erase's edge, an icon beside it -- are listed in art/qa/remnants_ok.json,
"crop:x,y,w,h" -> why, and not reported again. Exits 1 when anything is left.
"""
import sys, os, json, glob, argparse
import numpy as np
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument('manifests', nargs='*')
ap.add_argument('--refdir', default='art/reference')
ap.add_argument('--assets', default='client/assets')
ap.add_argument('--sheet', default=None)
ap.add_argument('--band', type=int, default=3)
a = ap.parse_args()

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
manifests = a.manifests or sorted(m for m in glob.glob(os.path.join(ROOT, 'art', 'slices', '*.json'))
                                  if not m.endswith('.layout.json'))
ok_path = os.path.join(ROOT, 'art', 'qa', 'remnants_ok.json')
reviewed = set(json.load(open(ok_path))) if os.path.exists(ok_path) else set()

BRIGHT = 150      # max channel of painted ink: cream, white, gold
GROUND = 80       # a plate's ground is darker than this (median of the band)
MAX_RUN = 14      # a glyph stub is short; a frame line runs on
MIN_PIX = 3       # fewer is noise


def runs(mask):
    out, start = [], None
    for i, v in enumerate(list(mask) + [False]):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start, i - 1)); start = None
    return out


def edge_hits(img, rect, band):
    """img: HxWx3 of the shipped crop; rect in crop coords. Yields (edge, a, b)."""
    h, w = img.shape[:2]
    x, y, rw, rh = rect
    lum = img.max(axis=2)
    bands = {
        'left':   (lum[max(0, y):min(h, y + rh), max(0, x - band):max(0, x)], 1),
        'right':  (lum[max(0, y):min(h, y + rh), min(w, x + rw):min(w, x + rw + band)], 1),
        'top':    (lum[max(0, y - band):max(0, y), max(0, x):min(w, x + rw)], 0),
        'bottom': (lum[min(h, y + rh):min(h, y + rh + band), max(0, x):min(w, x + rw)], 0),
    }
    for edge, (b, axis) in bands.items():
        if b.size == 0:
            continue
        # the pixel column/row touching the rect is where a cut glyph shows
        touch = b[:, -1] if edge == 'left' else b[:, 0] if edge == 'right' else b[-1, :] if edge == 'top' else b[0, :]
        if np.median(b) > GROUND:
            continue
        bright = touch > BRIGHT
        for s, e in runs(bright):
            n = e - s + 1
            if MIN_PIX <= n <= MAX_RUN:
                yield edge, s, e


hits = []
for mpath in manifests:
    m = json.load(open(mpath)); base = m.get('source')
    for c in m['crops']:
        rects = [e['rect'] for e in c.get('erase', [])]
        if not rects:
            continue
        png = os.path.join(ROOT, a.assets, c['name'] + '.png')
        if not os.path.exists(png):
            continue
        img = np.asarray(Image.open(png).convert('RGB')).astype(int)
        cx, cy = c['rect'][0], c['rect'][1]
        for r in rects:
            local = (r[0] - cx, r[1] - cy, r[2], r[3])
            for edge, s, e in edge_hits(img, local, a.band):
                key = '%s:%s' % (c['name'], ','.join(str(v) for v in r))
                if key in reviewed:
                    continue
                hits.append((c['name'], r, edge, s, e, local))

for name, r, edge, s, e, local in hits:
    print(f"{name}  rect {r}  {edge} edge, {e - s + 1} px of ink at {s}..{e} along it")
print(f"{len(hits)} place(s) to look at" if hits else "no remnants")

if a.sheet and hits:
    cells = []
    for name, r, edge, s, e, local in hits[:60]:
        img = Image.open(os.path.join(ROOT, a.assets, name + '.png')).convert('RGB')
        x, y, w, h = local
        pad = 18
        box = (max(0, x - pad), max(0, y - pad), min(img.width, x + w + pad), min(img.height, y + h + pad))
        cells.append(img.crop(box).resize(((box[2] - box[0]) * 2, (box[3] - box[1]) * 2), Image.NEAREST))
    W = max(c.width for c in cells); H = sum(c.height + 6 for c in cells)
    sheet = Image.new('RGB', (W, H), (255, 0, 255)); yy = 0
    for c in cells:
        sheet.paste(c, (0, yy)); yy += c.height + 6
    sheet.save(a.sheet); print('sheet', a.sheet)

sys.exit(1 if hits else 0)
