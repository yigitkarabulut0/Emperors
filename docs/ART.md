# Art pipeline

## Current path: local, free, offline

The Google AI Studio key has zero quota (every model returns
`free_tier ... limit: 0`), so generation runs **locally on the Mac** instead.

- **Model:** `Runpod/FLUX.2-klein-4B-mflux-4bit` via [mflux](https://github.com/filipstrand/mflux) (MLX).
- **Licence:** Apache-2.0 — output is usable in a commercial game.
- **Cost:** zero. 4.6 GB on disk, no API key, works offline.
- **Speed:** ~17 s/step, ~100 s per 1024×1024 image at 6 steps on an M4 (8 GPU cores).
  Peak memory 12.4 GB, so close other apps on a 16 GB machine.

```bash
scripts/gen-local.sh "<prompt>" art/refs/out.png 1024 1024 6
```

If billing is ever enabled on the Google key, switch back: Gemini follows a
prompt more precisely, which matters for grid sheets where each cell must be a
specific tier. The vendored CLI already defaults to `--model gemini`, and
`--gemini-model pro` selects Nano Banana Pro.

## Pipeline

```
prompt ──▶ scripts/gen-local.sh ──▶ art/refs/*.png        (flat solid background)
       ──▶ grid_slice.py         ──▶ art/sliced/          (only for grid sheets)
       ──▶ rembg_matting.py      ──▶ art/matted/          (alpha)
       ──▶ magick -resize        ──▶ art/promoted/        (game-ready)
       ──▶ client/assets/
```

`art/` is a **sibling** of `client/`, never inside it: Godot must not import 2K
generation sheets, and generation inputs must never reach the shipped bundle.

## Rules that are not optional

- **Never prompt for a transparent background.** The model draws a checkerboard.
  Prompt a flat solid colour, then matte it out. For metal subjects use dark
  teal (`RGB 31 74 74`) — distinct from steel, gold and leather, and dark enough
  that residual fringe blends into the `#1B1712` panel.
- **Always pass `--alpha-floor`** (default 0.06). Background pixels keep their
  computed `alpha_color` regardless of `--bg-thresh`, so a generated background
  that is not perfectly uniform leaves a low-alpha haze over the whole frame —
  a visible square halo on a dark panel. `--bg-thresh` cannot fix this; it
  reclassifies pixels, it never zeroes them. Measured on the hero sword:
  460k semi-transparent pixels at floor 0.01, 130k at 0.06.
- **QA on `#1B1712`, not white**, and always look at 96 px. That is the size the
  inventory grid actually draws.

## Style

Painterly semi-realistic mobile-RPG loot-icon art. Hand-painted rendering, warm
rim light upper-left, bold chunky silhouette with no feature thinner than 1/40 of
the frame, object centred filling ~80%, flat solid background, no text, no frame.

`art/promoted/weapon_legendary_hero.png` is the style reference. Pass it as
`--image` on every subsequent generation to keep 200 assets in one family.
