"""Rebuild a screen from its layout JSON + sliced assets, and put it beside the reference.

usage: compose_layout.py art/slices/<screen>.layout.json --assets client/assets --refdir art/reference \
          --out art/qa/<screen>_sbs.png [--state key=value ...]

Draws every image at its rect (natural size, top-left anchored), every text sample with a serif font at
the recorded size/colour, templates at each instance, bars from their pieces. Screens share the rail and
currency pills from art/slices/chrome.json positions, so the left 155 px is copied from the reference.
"""
import sys, json, os, argparse
from PIL import Image, ImageDraw, ImageFont

ap = argparse.ArgumentParser(); ap.add_argument('layout'); ap.add_argument('--assets', required=True)
ap.add_argument('--refdir', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--state', nargs='*', default=[])
a = ap.parse_args()
L = json.load(open(a.layout)); W, H = L.get('canvas', [941, 1672])
ref = Image.open(os.path.join(a.refdir, L['source'])).convert('RGBA')
FONTS = os.path.join(a.assets, 'fonts')
TITLE = os.path.join(FONTS, 'Cinzel-Variable.ttf'); BODY = os.path.join(FONTS, 'CrimsonPro[wght].ttf')
state = dict(kv.split('=', 1) for kv in a.state)

def font(role, size, weight):
    path = TITLE if role == 'title' else BODY
    f = ImageFont.truetype(path, int(size))
    try: f.set_variation_by_axes([int(weight or 500)])
    except Exception: pass
    return f

def hexcol(h):
    h = h.lstrip('#'); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (255,)

canvas = Image.new('RGBA', (W, H), hexcol(L.get('ground', '#0b1620')))
canvas.paste(ref.crop((0, 0, 155, H)), (0, 0))  # shared rail, not this screen's job
draw = ImageDraw.Draw(canvas)
_cache = {}
def asset(name):
    if name not in _cache: _cache[name] = Image.open(os.path.join(a.assets, name + '.png')).convert('RGBA')
    return _cache[name]

def blit(name, x, y):
    canvas.alpha_composite(asset(name), (int(x), int(y)))

def text(el, ox, oy):
    x, y, w, h = el['rect']; x += ox; y += oy
    f = font(el.get('font', 'body'), el.get('size', 24), el.get('weight', 500))
    if el.get('rich'):
        cx = x; cy = y + h / 2
        for run in el['rich']:
            draw.text((cx, cy), run['text'], font=f, fill=hexcol(run['color']), anchor='lm')
            cx += draw.textlength(run['text'], font=f)
        return
    s = el.get('sample', '')
    al = el.get('align', 'left'); anchor = {'left': 'lm', 'center': 'mm', 'right': 'rm'}[al]
    px = {'left': x, 'center': x + w / 2, 'right': x + w}[al]
    draw.text((px, y + h / 2), s, font=f, fill=hexcol(el.get('color', '#ffffff')), anchor=anchor)

def bar(el, ox, oy):
    x, y, w, h = el['rect']; x += ox; y += oy; p = el['pieces']; ratio = el.get('ratio_sample', 0.5)
    left, fa, split, fb, right = (asset(p[k]) for k in ('left', 'fill_a', 'split', 'fill_b', 'right'))
    sx = int(x + w * ratio)
    canvas.alpha_composite(left, (int(x), int(y)))
    xa = int(x) + left.width
    while xa < sx - split.width // 2:
        canvas.alpha_composite(fa, (xa, int(y))); xa += fa.width
    canvas.alpha_composite(split, (sx - split.width // 2, int(y)))
    xb = sx + split.width // 2
    while xb < x + w - right.width:
        canvas.alpha_composite(fb, (xb, int(y))); xb += fb.width
    canvas.alpha_composite(right, (int(x + w) - right.width, int(y)))

def render(el, ox=0, oy=0):
    k = el.get('kind')
    ow = el.get('only_when')
    if ow and state.get('mode') and ow != state.get('mode') and not ow.startswith('not'):
        return
    if k == 'image' or k == 'button':
        if 'states' in el:
            st = el['states'][state.get(el['id'], 'active' if 'active' in el['states'] and el['id'] == 'tab_revenge' else 'inactive')]
            x, y, *_ = st['rect']; blit(st['asset'], x + ox, y + oy)
            if 'label' in st: text(st['label'], ox, oy)
            if el.get('badge_count'): text(el['badge_count'], ox, oy)
            return
        if 'asset' in el:
            x, y, *_ = el['rect']; blit(el['asset'], x + ox, y + oy)
        for p in el.get('parts', []): render(p, ox + el['rect'][0], oy + el['rect'][1])
    elif k == 'text': text(el, ox, oy)
    elif k == 'bar': bar(el, ox, oy)
    elif k == 'template':
        for ix, iy in el.get('instances', [[el['rect'][0], el['rect'][1]]]):
            for p in el['parts']:
                if p.get('only_when') == 'shielded': continue
                render(p, ox + ix, oy + iy)

for el in L['elements']: render(el)

# shared chrome pills, at the chrome positions
for nm, x in (('gold', 180), ('diamond', 439), ('energy', 666)):
    try: blit('chrome/pill_' + nm, x, 21)
    except Exception: pass

sbs = Image.new('RGB', (W * 2 + 10, H), (255, 0, 255))
sbs.paste(ref.convert('RGB'), (0, 0)); sbs.paste(canvas.convert('RGB'), (W + 10, 0))
os.makedirs(os.path.dirname(a.out), exist_ok=True); sbs.save(a.out)
canvas.convert('RGB').save(a.out.replace('_sbs', '_built'))
print(a.out, sbs.size)
