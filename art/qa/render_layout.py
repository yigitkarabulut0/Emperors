"""Render a <screen>.layout.json from the sliced assets and put it beside the reference.
usage: art/.venv/bin/python art/qa/render_layout.py art/slices/<screen>.layout.json
Writes art/qa/<screen>_render.png and art/qa/<screen>_sbs.png (reference | render).
Templates: instances are [x,y] or {pos, assets:{part->asset}, texts:{part->sample}}.
"""
import sys, json, os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ASSETS = os.path.join(ROOT, 'client', 'assets'); FONTS = os.path.join(ASSETS, 'fonts')
lay = json.load(open(sys.argv[1])); W, H = lay.get('canvas', [941, 1672])
canvas = Image.new('RGBA', (W, H), lay.get('ground', '#0a1620'))
draw = ImageDraw.Draw(canvas)
_fonts = {}

def font(role, size, weight):
    key = (role, size, weight)
    if key not in _fonts:
        f = ImageFont.truetype(os.path.join(FONTS, lay['fonts'][role]), size)
        try: f.set_variation_by_axes([weight])
        except Exception: pass
        _fonts[key] = f
    return _fonts[key]

def asset(name):
    return Image.open(os.path.join(ASSETS, name + '.png')).convert('RGBA')

def draw_image(el, ox, oy, name=None, rect=None):
    # An image element with no asset is a box the layout reserves for a picture
    # only the running game has -- a lord's face, their crest, the gear they
    # carry. There is nothing to draw here; the capture is where it is checked.
    if name is None and not el.get('asset'):
        return
    im = asset(name or el['asset']); x, y, w, h = rect or el['rect']
    if rect is None and el.get('keep_texture_size') and 'paint_rect' in el:
        # The rect is the thumb's; the painting is drawn where the painting has
        # it, which is smaller (UI.tex_button's STRETCH_KEEP_CENTERED).
        x, y, w, h = el['paint_rect']
    if el.get('fill'):
        r = float(el.get('ratio', 1.0)); w2 = max(0, int(w * r))
        if w2 == 0: return
        im = im.resize((w2, h)); canvas.alpha_composite(im, (ox + x, oy + y)); return
    # A measured rect may be fractional (the profile's plates are); the paste
    # takes whole pixels.
    x, y, w, h = int(round(x)), int(round(y)), int(round(w)), int(round(h))
    if (im.width, im.height) != (w, h): im = im.resize((max(1, w), max(1, h)))
    canvas.alpha_composite(im, (int(ox + x), int(oy + y)))

def draw_nine(el, ox, oy, rect=None):
    """A painted plate stretched to a rect, the way Layout's ninepatch draws it:
    the four corners kept, the four edges stretched along their run, the middle
    stretched both ways."""
    im = asset(el['asset']); x, y, w, h = rect or el['rect']
    m = el.get('margin', [10, 10, 10, 10])
    l, t, r, b = (m * 4)[:4] if isinstance(m, list) and len(m) == 4 else (m, m, m, m)
    W0, H0 = im.size
    l, r = min(l, W0 // 2), min(r, W0 // 2)
    t, b = min(t, H0 // 2), min(b, H0 // 2)
    out = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    cols = [(0, l, 0, l), (l, W0 - r, l, w - r), (W0 - r, W0, w - r, w)]
    rows = [(0, t, 0, t), (t, H0 - b, t, h - b), (H0 - b, H0, h - b, h)]
    for sx0, sx1, dx0, dx1 in cols:
        for sy0, sy1, dy0, dy1 in rows:
            if sx1 <= sx0 or sy1 <= sy0 or dx1 <= dx0 or dy1 <= dy0:
                continue
            piece = im.crop((sx0, sy0, sx1, sy1))
            if piece.size != (dx1 - dx0, dy1 - dy0):
                piece = piece.resize((dx1 - dx0, dy1 - dy0))
            out.alpha_composite(piece, (dx0, dy0))
    canvas.alpha_composite(out, (ox + x, oy + y))

def draw_text(el, ox, oy, text=None):
    text = el['sample'] if text is None else text; x, y, w, h = el['rect']
    f = font(el.get('font', 'body'), el['size'], el.get('weight', 500))
    lines = text.split('\n'); lh = int(el['size'] * el.get('line_height', 1.0))
    total = lh * len(lines); align = el.get('align', 'left'); valign = el.get('valign', 'center')
    ty = oy + y + (h - total) // 2 if valign == 'center' else oy + y
    for i, line in enumerate(lines):
        tw = draw.textlength(line, font=f)
        tx = ox + x if align == 'left' else (ox + x + w - tw if align == 'right' else ox + x + (w - tw) / 2)
        draw.text((tx, ty + i * lh + lh / 2), line, font=f, fill=el['color'], anchor='lm')

def draw_el(el, ox=0, oy=0, over_assets=None, over_texts=None, over_rects=None):
    k = el['kind']
    if k in ('image', 'button'):
        draw_image(el, ox, oy, (over_assets or {}).get(el['id']), (over_rects or {}).get(el['id']))
    elif k == 'ninepatch':
        draw_nine(el, ox, oy, (over_rects or {}).get(el['id']))
    elif k == 'text':
        draw_text(el, ox, oy, (over_texts or {}).get(el['id']))
    elif k == 'template':
        # A strip the client builds at run time from a sheet's plates (the tab
        # rows) declares its tabs and its rect, not instances: there is nothing
        # static to draw, and the capture is where it is checked.
        if 'instances' not in el:
            return
        for inst in el['instances']:
            if isinstance(inst, dict): pos, oa, ot, orc = inst['pos'], inst.get('assets', {}), inst.get('texts', {}), inst.get('rects', {})
            else: pos, oa, ot, orc = inst, {}, {}, {}
            for p in el['parts']: draw_el(p, pos[0], pos[1], oa, ot, orc)
    elif k == 'scroll':
        pass  # its content elements are drawn at top level

for el in lay['elements']: draw_el(el)
out = os.path.join(ROOT, 'art', 'qa', lay['screen'] + '_render.png'); canvas.convert('RGB').save(out)
ref = Image.open(os.path.join(ROOT, 'art', 'reference', lay['source'])).convert('RGB')
sbs = Image.new('RGB', (W * 2 + 12, H), (255, 0, 255)); sbs.paste(ref, (0, 0)); sbs.paste(canvas.convert('RGB'), (W + 12, 0))
sbs.save(os.path.join(ROOT, 'art', 'qa', lay['screen'] + '_sbs.png')); print('wrote', out)
