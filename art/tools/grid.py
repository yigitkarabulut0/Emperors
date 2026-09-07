import sys
from PIL import Image, ImageDraw, ImageFont
# usage: grid.py <img> x y w h scale out [step=10 label=50]
img = Image.open(sys.argv[1]).convert('RGB')
x, y, w, h, s = map(int, sys.argv[2:7]); out = sys.argv[7]
step = int(sys.argv[8]) if len(sys.argv) > 8 else 10
lab = int(sys.argv[9]) if len(sys.argv) > 9 else 50
crop = img.crop((x, y, x + w, y + h)).resize((w * s, h * s), Image.NEAREST)
M = 28
canvas = Image.new('RGB', (w * s + M, h * s + M), (255, 255, 255))
canvas.paste(crop, (M, M))
d = ImageDraw.Draw(canvas)
try: font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 11)
except Exception: font = ImageFont.load_default()
for gx in range(0, w + 1, step):
    X = M + gx * s
    big = (x + gx) % lab == 0
    d.line([(X, M - (10 if big else 4)), (X, M)], fill=(0, 0, 0))
    if big:
        d.text((X + 1, 0), str(x + gx), fill=(200, 0, 0), font=font)
        d.line([(X, M), (X, M + h * s)], fill=(255, 0, 255))
for gy in range(0, h + 1, step):
    Y = M + gy * s
    big = (y + gy) % lab == 0
    d.line([(M - (10 if big else 4), Y), (M, Y)], fill=(0, 0, 0))
    if big:
        d.text((0, Y - 6), str(y + gy), fill=(200, 0, 0), font=font)
        d.line([(M, Y), (M + w * s, Y)], fill=(255, 0, 255))
canvas.save(out); print(out, canvas.size)
