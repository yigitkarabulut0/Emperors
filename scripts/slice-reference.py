"""Manifest-driven slicer: reads JSON manifests, writes PNGs into an assets dir, builds a QA contact sheet.

usage: slice.py <manifest.json>... --refdir art/reference --out client/assets [--sheet qa.png] [--only prefix]

Manifest:
{ "source": "collect.png",
  "crops": [ { "name": "chrome/pill_gold",          # output path under --out, without .png
               "rect": [x, y, w, h],                # in source pixels
               "src": "other.png",                  # optional: override source for this crop
               "mode": "rect" | "darkkey",          # rect = opaque; darkkey = alpha vs the dark ground
               "k": 90, "bg": [r,g,b],              # darkkey tuning (bg defaults to the border median)
               "erase": [ {"rect": [x,y,w,h], "sample_x": [x0,x1], "sample_x2": [x2,x3], "fade_top": px} ],
                     # fill each row of rect with the mean colour of columns x0..x1 (source coords) on that row
                     # -> removes baked text from a plate while keeping its vertical gradient.
                     # With sample_x2, each row runs from the first sample's colour at the rect's left edge
                     # to the second's at its right: a wide ground with a vignette (a page darker at its edges)
                     # is lifted without a flat band or a step where two erases meet.
                     # With fade_top, the first N rows blend from the painting into the fill, so a band lifted
                     # out of a scene falls into shadow instead of cutting it off. Start the rect that many
                     # rows ABOVE what is being lifted, where the painting is still the scene: fading into the
                     # object itself only brings back a ghost of its rim
               "refill": [ {"rect": [x,y,w,h], "band": [y0,y1], "samples": [{"rows": [ya,yb], "x": [[x0,x1],...]}]} ],
                     # clear a wide stretch of a plain panel back to the panel: each row at the panel's level
                     # there (sampled where it is clean, interpolated where it is not), each column shaded
                     # like a clean band of it -- a row-fill across a wide panel reads as a flat board
               "patch": [ {"from": [x,y,w,h], "to": [x,y], "flip": "h" | "v" | "hv", "feather": px, "feather_y": px} ],
                     # lay a clean piece of the painting over a spoiled one, optionally mirrored (source coords,
                     # always from the untouched painting; after refill, before erase) -> a frame corner the
                     # foreground foliage covers is its mirrored twin from the other side of the same frame;
                     # an ornament a refill ran over is put back
               "shade": [ {"rect": [x,y,w,h], "gain": g | [r,g,b], "saturation": s, "feather": px} ],
                     # levels a round region to the tone of its siblings (a lit medallion's interior
                     # brought down to an unlit one's, so its STATE can be drawn over it)
               "inpaint": [ [x,y,w,h], ... ],       # content-aware fill of these source rects (cv2 Telea)
                     # or {"text": [x,y,w,h], "d": 45, "dilate": 5, "radius": 5}: fill only the pixels in the
                     # rect further than d (largest channel difference) from the rect's median colour -- the
                     # plate's -- grown by `dilate` px: a painted word and its shadow lifted off a mottled plate,
                     # which a flat erase leaves as a box and a brightness key leaves as a ghost of the shadow
               "soften": [ [x,y,w,h], ... ],        # replace with a very low-frequency version of the same
                     # region: keeps the painting's own colours and the shape of its light, loses everything
                     # with an edge. For lifting a whole painted object off its field, which Telea smears.
               "hollow": 14 | [l, t, r, b],         # clear everything inside this inset -> a frame, not a tile
                     # a list gives each side its own inset: a painted frame is rarely as thick
                     # at the top (glow, a crest) as it is down the sides
               "mask": {"type": "chamfer", "size": 6} | {"type": "polygon", "points": [[x,y],...]}
                     | {"type": "ellipse", "box": [x0,y0,x1,y1]}, optionally with "feather": px
                     | a list of those, which keeps their union
                     # alpha 0 outside; points and box are relative to the crop
               "tone": {"gain": g | [r,g,b], "saturation": s, "vignette": {"strength": s, "inner": r0, "centre": [cx, cy]}},
                     # levels on the crop, then a radial darkening: each channel times `gain`, then
                     # times 1 - s * smoothstep(r0, 1, d), d the distance from `centre` (fractions of
                     # the crop, default [0.5, 0.5]) over the distance to the farthest corner. For a
                     # painted cloth brought to the tone of the ground it replaces (the rarity velvets).
                     # saturation (1 = as painted, 0 = grey) mixes each pixel toward its luminance: a
                     # painted card of one rarity drained to the grey of the common one
               "hole": <mask shapes>                # clear everything INSIDE these shapes (same forms as
                     # "mask") -> a frame's ring with a chamfered or cornered opening, where "hollow"
                     # can only open a rectangle
               "scale": [w, h]                      # optional: resize the result (LANCZOS)
               "floor": 2,                          # darkkey only: distances up to this are ground (its grain),
                     # so the ground keys to fully clear instead of a faint haze of alpha 1/k
               "solid": <mask shapes>               # darkkey only: alpha is 1 inside these shapes (same forms as
                     # "mask"). For a badge with a dark interior on the dark ground -- its body must stay
                     # opaque while the ornament round it keys cleanly off the ground.
  } ] }
"""
import sys, json, os, argparse
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ap = argparse.ArgumentParser(); ap.add_argument('manifests', nargs='+')
ap.add_argument('--refdir', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--sheet', default=None); ap.add_argument('--only', default=None)
a = ap.parse_args()

def darkkey(im, k, bg, floor=0.0):
    arr = np.asarray(im.convert('RGB')).astype(np.float32)
    if bg is None:
        ring = np.concatenate([arr[0, :], arr[-1, :], arr[:, 0], arr[:, -1]]); bg = np.median(ring, axis=0)
    else: bg = np.array(bg, dtype=np.float32)
    dist = np.abs(arr - bg).max(axis=2); alpha = np.clip((dist - floor) / k, 0, 1)
    fg = np.where(alpha[..., None] > 0, (arr - bg * (1 - alpha[..., None])) / np.maximum(alpha[..., None], 1e-3), arr)
    return Image.fromarray(np.dstack([np.clip(fg, 0, 255), alpha * 255]).astype(np.uint8), 'RGBA')

def apply_erase(img, erases):
    arr = np.asarray(img).copy()
    for e in erases:
        x, y, w, h = e['rect']; x0, x1 = e['sample_x']
        x2, x3 = e.get('sample_x2', (None, None))
        fade = int(e.get('fade_top', 0))
        ramp = np.linspace(0.0, 1.0, w)[:, None] if x2 is not None else None
        for i, row in enumerate(range(y, y + h)):
            left = arr[row, x0:x1 + 1].astype(np.float32).mean(axis=0)
            if ramp is None:
                fill = np.repeat(left[None, :], w, axis=0)
            else:
                right = arr[row, x2:x3 + 1].astype(np.float32).mean(axis=0)
                fill = left * (1 - ramp) + right * ramp
            if i < fade:
                # The scene falling into the band rather than being cut by it.
                t = (i + 1) / (fade + 1)
                fill = arr[row, x:x + w].astype(np.float32) * (1 - t) + fill * t
            arr[row, x:x + w] = fill.round().astype(np.uint8)
    return Image.fromarray(arr)

def apply_refill(img, refills):
    """Clears a large stretch of a plain painted panel back to the panel.

    `erase` fills each row with one colour, which is right for a plate but
    flattens a wide panel: its light falls off towards the frame (a column
    shading) and it has a fine grain, and a row-fill across it reads as a flat
    board. Here each row keeps the panel's level where it is clean -- the mean
    of its `samples` columns on that row, rows with none interpolated between
    the nearest rows that have -- and every column gets the shading of a clean
    `band` of the same panel, so the fill is the panel's own surface.

    {"rect": [x,y,w,h], "band": [y0, y1],
     "samples": [{"rows": [ya, yb], "x": [[x0, x1], ...]}, ...]}
    """
    arr = np.asarray(img).astype(np.float32).copy()
    src = arr.copy()
    for f in refills:
        x, y, w, h = f['rect']; b0, b1 = f['band']
        band = src[b0:b1]                        # the clean band, full width
        raw = band.mean(axis=0)                  # its column shading
        # Only the light's fall-off, not the band's own brush marks: run down
        # the whole fill, those drew stripes. The last few columns against the
        # rect's sides keep the band's own (a frame's inner shadow is sharp).
        k, edge, blend = 41, 16, 10
        prof = raw.copy()
        if w > 2 * (edge + blend):               # a narrow fill keeps the band's own shading
            inner = raw[x + edge:x + w - edge]
            pad = np.pad(inner, ((k // 2, k // 2), (0, 0)), mode='reflect')
            cs = np.cumsum(np.vstack([np.zeros((1, 3)), pad]), axis=0)
            prof[x + edge:x + w - edge] = (cs[k:] - cs[:-k]) / k
            for i in range(blend):               # ease from the sides' own into the smoothed
                t = (i + 1) / (blend + 1)
                a, b = x + edge + i, x + w - edge - 1 - i
                prof[a] = raw[a] * (1 - t) + prof[a] * t
                prof[b] = raw[b] * (1 - t) + prof[b] * t
        level = np.full((h, 3), np.nan, np.float32)
        for s in f['samples']:
            cols = np.concatenate([np.arange(a, b + 1) for a, b in s['x']])
            ref = prof[cols].mean(axis=0)
            for row in range(max(s['rows'][0], y), min(s['rows'][1], y + h - 1) + 1):
                level[row - y] = src[row, cols].mean(axis=0) - ref
        known = np.where(~np.isnan(level[:, 0]))[0]
        for ch in range(3):
            level[:, ch] = np.interp(np.arange(h), known, level[known, ch])
        # The level is the light's slow fall down the panel; row to row, what
        # the samples catch of a rim's glow beside them is noise, and reads as
        # a band across the fill.
        if h > 31:
            pad = np.pad(level, ((15, 15), (0, 0)), mode='edge')
            cs = np.cumsum(np.vstack([np.zeros((1, 3)), pad]), axis=0)
            level = (cs[31:] - cs[:-31]) / 31
        # No grain: the band's own, repeated down the fill, drew a lattice and a
        # streak down every column, and rolled sideways it scattered whatever
        # else the band held (a rim's shadow) as dashes. The panels' grain is
        # two levels deep; smooth reads as the same surface on the phone.
        for r in range(h):
            arr[y + r, x:x + w] = level[r] + prof[x:x + w]
    return Image.fromarray(np.clip(arr, 0, 255).round().astype(np.uint8))

def apply_patch(img, patches, source=None):
    """Lays pieces of the untouched painting (`source`) over `img`.

    With "feather": px, the piece is laid in over a ramp that many pixels wide
    at its sides ("feather_y" for its top and bottom, default the same), so a
    piece of a grained plate taken from beside a word melts into the plate
    instead of showing as a block of a slightly other tone."""
    source = source or img
    out = img.copy()
    for p in patches:
        x, y, w, h = p['from']; piece = source.crop((x, y, x + w, y + h)); flip = p.get('flip', '')
        if 'h' in flip: piece = piece.transpose(Image.FLIP_LEFT_RIGHT)
        if 'v' in flip: piece = piece.transpose(Image.FLIP_TOP_BOTTOM)
        fx = int(p.get('feather', 0)); fy = int(p.get('feather_y', fx))
        if fx or fy:
            def ramp(n, f):
                r = np.ones(n, np.float32)
                for i in range(min(f, n // 2)):
                    r[i] = r[n - 1 - i] = (i + 1) / (f + 1)
                return r
            a = np.outer(ramp(h, fy), ramp(w, fx))
            tx, ty = p['to']
            under = np.asarray(out.crop((tx, ty, tx + w, ty + h))).astype(np.float32)
            over = np.asarray(piece).astype(np.float32)
            piece = Image.fromarray((over * a[..., None] + under * (1 - a[..., None])).round().astype(np.uint8))
        out.paste(piece, tuple(p['to']))
    return out

def apply_shade(img, shades):
    """Brings a round region of the painting to the tone of its own siblings.

    The talents painting lights its top two medallions in every column: the RING
    is cut in both of its states and drawn where the server says, but the glow
    BEHIND the icon is inside the page and cannot be. Levelling those six
    interiors to an unlit one's tone -- desaturated by `saturation`, then scaled
    by `gain` -- is what lets all fifteen start equal, so a medallion's state is
    the ring's alone and never the painting's own choice showing through.

    An entry is {"rect": [x, y, w, h], "gain": g | [r, g, b], "saturation": s,
    "feather": px}: the rect's inscribed ellipse, feathered, so the region meets
    what is round it without an edge.
    """
    from PIL import ImageFilter
    arr = np.asarray(img.convert('RGB')).astype(np.float32)
    for sh in shades:
        x, y, w, h = sh['rect']
        m = Image.new('L', (w * 4, h * 4), 0)
        ImageDraw.Draw(m).ellipse([0, 0, w * 4 - 1, h * 4 - 1], fill=255)
        f = float(sh.get('feather', 0))
        if f:
            m = m.filter(ImageFilter.GaussianBlur(f * 4))
        mask = (np.asarray(m.resize((w, h), Image.BOX)).astype(np.float32) / 255.0)[..., None]
        reg = arr[y:y + h, x:x + w]
        out = reg.copy()
        if 'saturation' in sh:
            lum = (out * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(axis=2, keepdims=True)
            out = lum + float(sh['saturation']) * (out - lum)
        g = sh.get('gain', 1.0)
        out = out * np.array(g if isinstance(g, list) else [g, g, g], np.float32)
        arr[y:y + h, x:x + w] = reg * (1 - mask) + np.clip(out, 0, 255) * mask
    return Image.fromarray(np.clip(arr, 0, 255).round().astype(np.uint8))

def apply_inpaint(img, rects):
    """Content-aware fill. An entry is a rect [x, y, w, h], or a traced shape:

        {"polygon": [[x, y], ...], "dilate": 15, "radius": 12, "blur": 31,
         "exclude": [[x, y, w, h], ...]}

    A painted seal lifted off a card's scene: the polygon is the seal's own
    outline, grown by `dilate` px so its shadow goes with it; Telea fills it
    from `radius` px around; `blur` then softens the fill (only inside the grown
    shape, feathered) so Telea's streaks read as the scene's own out-of-focus
    background. `exclude` keeps rects a patch already repaired (a frame's
    border) out of the fill. A rect-shaped fill cannot do this: its corners take
    whatever else is in them (the edge of the bag beside the seal).

    `also` adds rects to the fill (a patch's box whose picture is the wrong
    side's, around the ornament it was laid for) and `keep` takes traced
    polygons out of it (that ornament, which is not a rect)."""
    import cv2
    arr = np.asarray(img).copy(); bgr = cv2.cvtColor(arr, cv2.COLOR_RGB2BGR)
    mask = np.zeros(arr.shape[:2], np.uint8)
    for r in rects:
        if isinstance(r, dict): continue
        x, y, w, h = r; mask[y:y + h, x:x + w] = 255
    if mask.any(): bgr = cv2.inpaint(bgr, mask, 5, cv2.INPAINT_TELEA)
    for r in rects:
        if not isinstance(r, dict) or 'text' not in r: continue
        x, y, w, h = r['text']
        region = arr[y:y + h, x:x + w].astype(np.int32)
        plate = np.median(region.reshape(-1, 3), axis=0)
        far = np.abs(region - plate).max(axis=2) > int(r.get('d', 45))
        m = np.zeros(arr.shape[:2], np.uint8)
        m[y:y + h, x:x + w] = np.where(far, 255, 0).astype(np.uint8)
        dl = int(r.get('dilate', 0))
        if dl: m = cv2.dilate(m, np.ones((dl, dl), np.uint8))
        bgr = cv2.inpaint(bgr, m, int(r.get('radius', 5)), cv2.INPAINT_TELEA)
    for r in rects:
        if not isinstance(r, dict) or 'text' in r: continue
        m = np.zeros(arr.shape[:2], np.uint8)
        cv2.fillPoly(m, [np.array(r['polygon'], np.int32)], 255)
        d = int(r.get('dilate', 0))
        if d: m = cv2.dilate(m, np.ones((d, d), np.uint8))
        for x, y, w, h in r.get('also', []): m[y:y + h, x:x + w] = 255
        for x, y, w, h in r.get('exclude', []): m[y:y + h, x:x + w] = 0
        for poly in r.get('keep', []): cv2.fillPoly(m, [np.array(poly, np.int32)], 0)
        filled = cv2.inpaint(bgr, m, int(r.get('radius', 5)), cv2.INPAINT_TELEA)
        b = int(r.get('blur', 0))
        if b:
            b += 1 - b % 2
            soft = cv2.GaussianBlur(m.astype(np.float32) / 255.0, (15, 15), 0)[..., None]
            filled = (cv2.GaussianBlur(filled, (b, b), 0) * soft + filled * (1 - soft)).astype(np.uint8)
        bgr = np.where(m[..., None] > 0, filled, bgr)
    return Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))

def apply_soften(img, rects):
    """Replaces each rect with a very low-frequency version of itself.

    A shop card's item sits on a field of tier-coloured light, and lifting the
    item out leaves a hole the size of half the card. Telea inpainting fills a
    hole that big by dragging its edges inward, which produced the diagonal
    smears the cards shipped with -- it repairs scratches, not removals.

    Reducing the region (with a margin of its surroundings, so the fill
    continues them) to a handful of pixels and scaling it back up keeps exactly
    what a background should keep -- the colour and the broad shape of the
    light -- and cannot keep anything with an edge, because at that size the
    object is a pixel or two. The result is pasted back under a feathered mask
    so it meets the untouched surroundings without a seam.
    """
    from PIL import ImageFilter
    out = img.copy()
    for x, y, w, h in rects:
        pad = max(12, min(w, h) // 5)
        bx, by = max(0, x - pad), max(0, y - pad)
        bw, bh = min(img.width, x + w + pad) - bx, min(img.height, y + h + pad) - by
        block = out.crop((bx, by, bx + bw, by + bh))
        # Small enough that the object cannot survive, large enough to keep the
        # gradient's direction.
        tiny = block.resize((6, 7), Image.BOX)
        field = tiny.resize((bw, bh), Image.BICUBIC).filter(ImageFilter.GaussianBlur(max(bw, bh) / 12))
        # The margin is for sampling, not for blending: feathering by half of it
        # left the rect's own corners barely touched, which is how a card kept a
        # legible LEGENDARY under the badge that replaced it. A few pixels are
        # all a seam needs.
        feather = Image.new('L', (bw, bh), 0)
        ImageDraw.Draw(feather).rectangle([x - bx, y - by, x - bx + w - 1, y - by + h - 1], fill=255)
        feather = feather.filter(ImageFilter.GaussianBlur(3))
        block.paste(field, (0, 0), feather)
        out.paste(block, (bx, by))
    return out

def apply_hollow(im, inset):
    """Clears the middle, leaving only the border: a frame rather than a tile.

    The rarity frames are cut as whole painted tiles and drawn as a nine-patch
    with its centre off, which works only at the size they were painted. Enlarge
    the tile and the edge slices stretch, and those slices still hold the item
    that was painted up against the border -- a ghost armour smeared down each
    side, with the level plate along the bottom. With the middle actually gone,
    the ring is the border at any size.
    """
    im = im.convert('RGBA')
    arr = np.asarray(im).copy()
    l, t, r, b = (inset, inset, inset, inset) if isinstance(inset, int) else inset
    arr[t:arr.shape[0] - b, l:arr.shape[1] - r, 3] = 0
    return Image.fromarray(arr, 'RGBA')

def shapes_alpha(size, shapes):
    """The anti-aliased coverage of chamfer / polygon / ellipse shapes, 0..255."""
    ss = 4
    w, h = size; m = Image.new('L', (w * ss, h * ss), 0); d = ImageDraw.Draw(m)
    for sh in (shapes if isinstance(shapes, list) else [shapes]):
        if sh['type'] == 'ellipse':
            x0, y0, x1, y1 = sh['box']; d.ellipse([x0 * ss, y0 * ss, x1 * ss, y1 * ss], fill=255)
            continue
        if sh['type'] == 'chamfer':
            s = sh['size']; pts = [(s, 0), (w - s, 0), (w, s), (w, h - s), (w - s, h), (s, h), (0, h - s), (0, s)]
        else: pts = [tuple(p) for p in sh['points']]
        d.polygon([(x * ss, y * ss) for x, y in pts], fill=255)
    return m.resize((w, h), Image.BOX)

def apply_solid(keyed, original, shapes):
    """Opaque inside the shapes, with the painting's own colour: the dark body of
    a badge that the key alone would have made see-through where it is nearly
    ground-coloured. The key also un-premultiplied those pixels' colour, so the
    original is put back rather than the keyed colour made opaque."""
    arr = np.asarray(keyed.convert('RGBA')).astype(np.float32)
    orig = np.asarray(original.convert('RGB')).astype(np.float32)
    cover = np.asarray(shapes_alpha(keyed.size, shapes)).astype(np.float32)[..., None] / 255.0
    arr[..., :3] = orig * cover + arr[..., :3] * (1 - cover)
    arr[..., 3] = np.maximum(arr[..., 3], cover[..., 0] * 255.0)
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGBA')

def apply_tone(im, tone):
    """Levels and a radial vignette on a crop (see the manifest's "tone")."""
    arr = np.asarray(im.convert('RGBA')).astype(np.float32)
    g = tone.get('gain', 1.0)
    gain = np.array(g if isinstance(g, list) else [g, g, g], dtype=np.float32)
    arr[..., :3] *= gain
    if 'saturation' in tone:
        lum = (arr[..., :3] * np.array([0.2126, 0.7152, 0.0722], np.float32)).sum(axis=2, keepdims=True)
        arr[..., :3] = lum + float(tone['saturation']) * (arr[..., :3] - lum)
    v = tone.get('vignette')
    if v:
        h, w = arr.shape[:2]
        cx, cy = v.get('centre', [0.5, 0.5])
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        dx, dy = xx / max(w - 1, 1) - cx, yy / max(h - 1, 1) - cy
        far = max(np.hypot(max(cx, 1 - cx), max(cy, 1 - cy)), 1e-3)
        d = np.hypot(dx, dy) / far
        r0 = float(v.get('inner', 0.3))
        t = np.clip((d - r0) / max(1.0 - r0, 1e-3), 0, 1)
        t = t * t * (3 - 2 * t)
        arr[..., :3] *= (1.0 - float(v.get('strength', 0.5)) * t)[..., None]
    return Image.fromarray(np.clip(arr, 0, 255).round().astype(np.uint8), 'RGBA')

def apply_hole(im, shapes):
    """Clears everything inside the shapes: a painted frame's ring, its opening
    the frame's own inner edge, chamfer and all."""
    arr = np.asarray(im.convert('RGBA')).copy()
    cover = np.asarray(shapes_alpha(im.size, shapes)).astype(np.uint16)
    arr[..., 3] = (arr[..., 3].astype(np.uint16) * (255 - cover) // 255).astype(np.uint8)
    return Image.fromarray(arr, 'RGBA')

def apply_mask(im, mask):
    """Clears everything outside a chamfer, polygon or ellipse -- or outside
    all of a list of them, which keeps their union (a portrait's ring and the
    crown standing on it).

    The mask is drawn at four times the crop's size and averaged down, so a
    diagonal edge -- a badge's chamfered corner -- is anti-aliased instead of
    a staircase of whole pixels.
    """
    ss = 4
    im = im.convert('RGBA'); w, h = im.size; m = Image.new('L', (w * ss, h * ss), 0); d = ImageDraw.Draw(m)
    shapes = mask if isinstance(mask, list) else [mask]
    for sh in shapes:
        if sh['type'] == 'ellipse':
            x0, y0, x1, y1 = sh['box']; d.ellipse([x0 * ss, y0 * ss, x1 * ss, y1 * ss], fill=255)
            continue
        if sh['type'] == 'chamfer':
            s = sh['size']; pts = [(s, 0), (w - s, 0), (w, s), (w, h - s), (w - s, h), (s, h), (0, h - s), (0, s)]
        else: pts = [tuple(p) for p in sh['points']]
        d.polygon([(x * ss, y * ss) for x, y in pts], fill=255)
    feather = max(float(sh.get('feather', 0)) for sh in shapes)
    if feather:
        # A soft edge, for a mask that cuts through glow rather than along a rim.
        from PIL import ImageFilter
        m = m.filter(ImageFilter.GaussianBlur(feather * ss))
    m = m.resize((w, h), Image.BOX)
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
        if c.get('refill'): work = apply_refill(work, c['refill'])
        if c.get('patch'): work = apply_patch(work, c['patch'], img)
        if c.get('erase'): work = apply_erase(work, c['erase'])
        if c.get('shade'): work = apply_shade(work, c['shade'])
        if c.get('inpaint'): work = apply_inpaint(work, c['inpaint'])
        if c.get('soften'): work = apply_soften(work, c['soften'])
        x, y, w, h = c['rect']
        assert 0 <= x and 0 <= y and x + w <= img.width and y + h <= img.height, f"{c['name']} rect outside {src}"
        crop = work.crop((x, y, x + w, y + h)); mode = c.get('mode', 'rect')
        if mode == 'darkkey':
            out = darkkey(crop, float(c.get('k', 90)), c.get('bg'), float(c.get('floor', 0)))
            if c.get('solid'): out = apply_solid(out, crop, c['solid'])
        elif mode == 'rect': out = crop
        else: raise SystemExit(f"unknown mode {mode} for {c['name']}")
        if c.get('hollow'):
            hv = c['hollow']
            out = apply_hollow(out, [int(v) for v in hv] if isinstance(hv, list) else int(hv))
        if c.get('tone'): out = apply_tone(out, c['tone'])
        if c.get('hole'): out = apply_hole(out, c['hole'])
        if c.get('mask'): out = apply_mask(out, c['mask'])
        if c.get('scale'): out = out.resize(tuple(c['scale']), Image.LANCZOS)
        if c.get('tone') and not c.get('mask') and not c.get('hole') and mode == 'rect':
            out = out.convert('RGB')             # a toned ground stays opaque
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
