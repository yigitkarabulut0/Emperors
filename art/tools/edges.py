"""Band-averaged edge finder. usage: edges.py <img> row|col <index> lo hi [thresh=18] [band=3]
Averages `band` adjacent lines, prints positions where luminance jumps by more than thresh,
with the luminance before/after. Frame bevels show up as +/- pairs a few px apart."""
import sys
import numpy as np
from PIL import Image
img = np.asarray(Image.open(sys.argv[1]).convert('L')).astype(np.float32)
mode, idx, lo, hi = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
th = float(sys.argv[6]) if len(sys.argv) > 6 else 18.0
band = int(sys.argv[7]) if len(sys.argv) > 7 else 3
h = band // 2
line = img[idx - h: idx + h + 1, lo:hi].mean(axis=0) if mode == 'row' else img[lo:hi, idx - h: idx + h + 1].mean(axis=1)
d = np.diff(line)
out = []
for i, v in enumerate(d):
    if abs(v) >= th:
        out.append((lo + i + 1, int(line[i]), int(line[i + 1]), '+' if v > 0 else '-'))
for p, a, b, s in out:
    print(f"{p:5d} {s} {a:3d}->{b:3d}")
