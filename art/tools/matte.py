"""Cut a sprite out of a reference and give it alpha against its dark ground.
usage: matte.py <img> x y w h out.png [--mode darkkey|rembg] [--bg r,g,b] [--k 90]
darkkey: alpha = clamp(max channel distance from bg / k). Keeps soft shadows/glows.
"""
import sys, argparse
import numpy as np
from PIL import Image
ap = argparse.ArgumentParser()
ap.add_argument('img'); ap.add_argument('x', type=int); ap.add_argument('y', type=int)
ap.add_argument('w', type=int); ap.add_argument('h', type=int); ap.add_argument('out')
ap.add_argument('--mode', default='darkkey'); ap.add_argument('--bg', default=None)
ap.add_argument('--k', type=float, default=90.0); ap.add_argument('--erode', type=int, default=0)
a = ap.parse_args()
im = Image.open(a.img).convert('RGB').crop((a.x, a.y, a.x + a.w, a.y + a.h))
if a.mode == 'rembg':
    from rembg import remove, new_session
    out = remove(im, session=new_session('isnet-general-use'), alpha_matting=True,
                 alpha_matting_foreground_threshold=240, alpha_matting_background_threshold=10,
                 alpha_matting_erode_size=a.erode or 5)
    out.save(a.out); print(a.out, out.size); sys.exit()
arr = np.asarray(im).astype(np.float32)
if a.bg:
    bg = np.array([float(v) for v in a.bg.split(',')])
else:
    # sample the border ring as the background estimate
    ring = np.concatenate([arr[0, :], arr[-1, :], arr[:, 0], arr[:, -1]])
    bg = np.median(ring, axis=0)
dist = np.abs(arr - bg).max(axis=2)
alpha = np.clip(dist / a.k, 0, 1)
# un-premultiply-ish: recover foreground colour where partially transparent
fg = np.where(alpha[..., None] > 0, (arr - bg * (1 - alpha[..., None])) / np.maximum(alpha[..., None], 1e-3), arr)
fg = np.clip(fg, 0, 255)
rgba = np.dstack([fg, alpha * 255]).astype(np.uint8)
Image.fromarray(rgba, 'RGBA').save(a.out)
print(a.out, im.size, 'bg=', bg.round(1).tolist())
