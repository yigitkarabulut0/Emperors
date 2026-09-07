"""Manifest-driven slicer: reads JSON manifests, writes PNGs into an assets dir, builds a QA contact sheet.

usage: slice.py <manifest.json>... --refdir art/reference --out client/assets [--sheet qa.png] [--only prefix]

Manifest:
{ "source": "collect.png",
  "crops": [ { "name": "chrome/pill_gold",          # output path under --out, without .png
               "rect": [x, y, w, h],                # in source pixels
               "src": "other.png",                  # optional: override source for this crop
               "mode": "rect" | "darkkey",          # rect = opaque; darkkey = alpha vs the dark ground
               "k": 90, "bg": [r,g,b],              # darkkey tuning (bg defaults to the border median)
               "erase": [ {"rect": [x,y,w,h], "sample_x": [x0,x1]} ],
                     # fill each row of rect with the mean colour of columns x0..x1 (source coords) on that row
                     # -> removes baked text from a plate while keeping its vertical gradient
               "inpaint": [ [x,y,w,h], ... ],       # content-aware fill of these source rects (cv2 Telea)
               "mask": {"type": "chamfer", "size": 6} | {"type": "polygon", "points": [[x,y],...]}
                     # alpha 0 outside; polygon points are relative to the crop
               "scale": [w, h]                      # optional: resize the result (LANCZOS)
  } ] }
"""
import sys, json, os, argparse
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ap = argparse.ArgumentParser(); ap.add_argument('manifests', nargs='+')
ap.add_argument('--refdir', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--sheet', default=None); ap.add_argument('--only', default=None)
a = ap.parse_args()

def darkkey(im, k, bg):
    arr = np.asarray(im.convert('RGB')).astype(np.float32)
    if bg is None:
        ring = np.concatenate([arr[0, :], arr[-1, :], arr[:, 0], arr[:, -1]]); bg = np.median(ring, axis=0)
    else: bg = np.array(bg, dtype=np.float32)
    dist = np.abs(arr - bg).max(axis=2); alpha = np.clip(dist / k, 0, 1)
    fg = np.where(alpha[..., None] > 0, (arr - bg * (1 - alpha[..., None])) / np.maximum(alpha[..., None], 1e-3), arr)
    return Image.fromarray(np.dstack([np.clip(fg, 0, 255), alpha * 255]).astype(np.uint8), 'RGBA')

def apply_erase(img, erases):
    arr = np.asarray(img).copy()
    for e in erases:
        x, y, w, h = e['rect']; x0, x1 = e['sample_x']
        for row in range(y, y + h):
            arr[row, x:x + w] = arr[row, x0:x1 + 1].mean(axis=0).round().astype(np.uint8)
    return Image.fromarray(arr)

def apply_inpaint(img, rects):
    import cv2
    arr = np.asarray(img).copy(); mask = np.zeros(arr.shape[:2], np.uint8)
    for x, y, w, h in rects: mask[y:y + h, x:x + w] = 255
    out = cv2.inpaint(cv2.cvtColor(arr, cv2.COLOR_RGB2BGR), mask, 5, cv2.INPAINT_TELEA)
    return Image.fromarray(cv2.cvtColor(out, cv2.COLOR_BGR2RGB))

def apply_mask(im, mask):
    im = im.convert('RGBA'); w, h = im.size; m = Image.new('L', (w, h), 0); d = ImageDraw.Draw(m)
    if mask['type'] == 'chamfer':
        s = mask['size']; pts = [(s, 0), (w - s, 0), (w, s), (w, h - s), (w - s, h), (s, h), (0, h - s), (0, s)]
    else: pts = [tuple(p) for p in mask['points']]
    d.polygon(pts, fill=255)
    alpha = np.minimum(np.asarray(im)[..., 3], np.asarray(m)); arr = np.asarray(im).copy(); arr[..., 3] = alpha
    return Image.fromarray(arr, 'RGBA')

done = []
cache = {}
for mpath in a.manifests:
    m = json.load(open(mpath)); base = m.get('source')
    for c in m['crops']:
        if a.only and not c['name'].startswith(a.only): continue
        src = os.path.join(a.refdir, c.get('src', base))
        img = cache.get(src) or Image.open(src).convert('RGB'); cache[src] = img
        work = img
        if c.get('erase'): work = apply_erase(work, c['erase'])
        if c.get('inpaint'): work = apply_inpaint(work, c['inpaint'])
        x, y, w, h = c['rect']
        assert 0 <= x and 0 <= y and x + w <= img.width and y + h <= img.height, f"{c['name']} rect outside {src}"
        crop = work.crop((x, y, x + w, y + h)); mode = c.get('mode', 'rect')
        if mode == 'darkkey': out = darkkey(crop, float(c.get('k', 90)), c.get('bg'))
        elif mode == 'rect': out = crop
        else: raise SystemExit(f"unknown mode {mode} for {c['name']}")
        if c.get('mask'): out = apply_mask(out, c['mask'])
        if c.get('scale'): out = out.resize(tuple(c['scale']), Image.LANCZOS)
        dst = os.path.join(a.out, c['name'] + '.png'); os.makedirs(os.path.dirname(dst), exist_ok=True)
        out.save(dst); Image.open(dst).verify(); done.append((c['name'], dst, out.size, mode))
print(f"{len(done)} crops written")
if a.sheet and done:
    font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 11); cell = 200; cols = 6
    rows = (len(done) + cols - 1) // cols; sheet = Image.new('RGBA', (cols * cell, rows * (cell + 18)), (255, 0, 255, 255))
    d = ImageDraw.Draw(sheet)
    for i, (name, dst, size, mode) in enumerate(done):
        im = Image.open(dst).convert('RGBA'); s = min((cell - 8) / im.width, (cell - 8) / im.height, 1.0)
        im = im.resize((max(1, int(im.width * s)), max(1, int(im.height * s))), Image.LANCZOS)
        cx, cy = (i % cols) * cell, (i // cols) * (cell + 18)
        sheet.alpha_composite(im, (cx + 4, cy + 4))
        d.text((cx + 2, cy + cell + 2), f"{name} {size[0]}x{size[1]}", font=font, fill=(0, 0, 0, 255))
    sheet.convert('RGB').save(a.sheet); print('sheet', a.sheet, sheet.size)
