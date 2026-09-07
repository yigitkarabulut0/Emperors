import sys
from PIL import Image
# usage: probe.py <img> row|col <index> [x0 x1]  -> prints runs of similar colour along that line
img = Image.open(sys.argv[1]).convert('RGB')
W, H = img.size
mode, idx = sys.argv[2], int(sys.argv[3])
lo = int(sys.argv[4]) if len(sys.argv) > 4 else 0
hi = int(sys.argv[5]) if len(sys.argv) > 5 else (W if mode == 'row' else H)
def px(i):
    return img.getpixel((i, idx)) if mode == 'row' else img.getpixel((idx, i))
def dist(a, b):
    return sum(abs(x - y) for x, y in zip(a, b))
start = lo; prev = px(lo)
for i in range(lo + 1, hi):
    p = px(i)
    if dist(p, prev) > 60:
        print(f"{start:4d}-{i-1:4d} len={i-start:3d} rgb={prev}")
        start = i
    prev = p
print(f"{start:4d}-{hi-1:4d} len={hi-start:3d} rgb={prev}")
