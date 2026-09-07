import sys
from PIL import Image
# usage: zoom.py <img> x y w h scale out
img = Image.open(sys.argv[1]).convert('RGB')
x, y, w, h, s = map(int, sys.argv[2:7])
img.crop((x, y, x + w, y + h)).resize((w * s, h * s), Image.NEAREST).save(sys.argv[7])
print(sys.argv[7], w*s, h*s)
