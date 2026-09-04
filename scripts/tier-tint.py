#!/usr/bin/env python3
"""Produce the full 7-tier ladder from ONE generated line-art icon.

The art style is a near-black silhouette whose form is described by coloured
line work. Black has no hue, so recolouring only the chromatic pixels swaps the
tier colour and leaves the silhouette untouched. That means one generation
(~100s) yields all seven tiers, perfectly consistent with each other by
construction rather than by luck.

Hue is SET, not rotated, so the result lands exactly on the palette in
balance/tiers.json rather than approximately near it. Lightness is preserved so
the linework keeps its modelling.

Usage: scripts/tier-tint.py in.png out_dir/ [--prefix weapon_sword_01]
"""
import argparse, json, pathlib, sys
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Below this saturation a pixel is the black/grey silhouette, not line work.
SAT_FLOOR = 0.18


def hex_to_hsv(h: str):
    h = h.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    if d == 0:
        hue = 0.0
    elif mx == r:
        hue = ((g - b) / d % 6) / 6
    elif mx == g:
        hue = ((b - r) / d + 2) / 6
    else:
        hue = ((r - g) / d + 4) / 6
    return hue, (0.0 if mx == 0 else d / mx), mx


def rgb_to_hsv(a):
    mx = a.max(axis=2); mn = a.min(axis=2); d = mx - mn
    h = np.zeros_like(mx)
    nz = d > 1e-6
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    im = (mx == r) & nz; h[im] = ((g[im] - b[im]) / d[im]) % 6
    im = (mx == g) & nz; h[im] = ((b[im] - r[im]) / d[im]) + 2
    im = (mx == b) & nz; h[im] = ((r[im] - g[im]) / d[im]) + 4
    h /= 6.0
    s = np.where(mx > 1e-6, d / np.maximum(mx, 1e-6), 0.0)
    return h, s, mx


def hsv_to_rgb(h, s, v):
    i = np.floor(h * 6.0)
    f = h * 6.0 - i
    p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    i = (i % 6).astype(int)
    out = np.zeros(h.shape + (3,), dtype=np.float64)
    for k, (rr, gg, bb) in enumerate([(v, t, p), (q, v, p), (p, v, t),
                                      (p, q, v), (t, p, v), (v, p, q)]):
        m = i == k
        out[m] = np.stack([rr, gg, bb], axis=-1)[m]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("out_dir")
    ap.add_argument("--prefix", default=None, help="Output name stem; defaults to the input stem.")
    ap.add_argument("--sat-floor", type=float, default=SAT_FLOOR)
    args = ap.parse_args()

    tiers = json.loads((ROOT / "balance/tiers.json").read_text())["tiers"]
    src = Image.open(args.input).convert("RGBA")
    rgba = np.asarray(src, dtype=np.float64) / 255.0
    rgb, alpha = rgba[:, :, :3], rgba[:, :, 3]

    h, s, v = rgb_to_hsv(rgb)
    # Line work = chromatic AND visible. Everything else is the silhouette.
    ink = (s >= args.sat_floor) & (alpha > 0.15)
    if ink.sum() == 0:
        sys.exit(f"no line work found above saturation {args.sat_floor} — is this the right style?")

    out_dir = pathlib.Path(args.out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    stem = args.prefix or pathlib.Path(args.input).stem
    written = []

    for t in tiers:
        th, ts, _ = hex_to_hsv(t["color"])
        h2, s2 = h.copy(), s.copy()
        h2[ink] = th
        # Scale saturation toward the tier's own, so 'common' genuinely reads as
        # desaturated pewter rather than grey-hued gold.
        s2[ink] = np.clip(s[ink] * (ts / max(s[ink].mean(), 1e-6)), 0, 1)

        out_rgb = hsv_to_rgb(h2, s2, v)
        out = np.dstack([out_rgb, alpha])
        path = out_dir / f"{stem}_{t['id']}.png"
        Image.fromarray((out * 255).clip(0, 255).astype(np.uint8), "RGBA").save(path)
        written.append(path.name)

    print(json.dumps({"ok": True, "ink_pixels": int(ink.sum()), "written": written}))


if __name__ == "__main__":
    main()
