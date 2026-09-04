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

## Style — "Gilded Iron"

Flat 2D art-deco / noir line art, taken from Idle Mafia Game's own visual
language: a **dark charcoal silhouette whose form is described entirely by thick
line work**. Flat fills, no painterly shading, no gradients, no texture. Bold
confident strokes like a woodcut or a logo. High contrast, iconic, legible as a
tiny icon.

`art/refs/STYLE-REFERENCE.png` is the anchor. Pass it as `--image` on every
subsequent generation to keep the whole set in one family.

### Why this style, concretely

It was chosen over painterly loot-icon art for four measurable reasons:

1. **The tier ladder is nearly free.** Black has no hue, so recolouring only the
   chromatic pixels swaps the tier colour and leaves the silhouette untouched.
   One generation yields all seven tiers via `scripts/tier-tint.py`, exactly on
   the palette in `balance/tiers.json`, consistent by construction rather than by
   luck. Painterly art needs seven separate generations per item and they drift.
2. **It mattes far better.** Measured on the same subject: flat line art gives
   79k opaque / 29k semi-transparent pixels; the painterly version gave 24k / 130k.
   Flat fills have hard edges, so there is almost no haze to clean up.
3. **It survives 96px**, which is the size the inventory grid actually draws.
4. **A text-to-image model reproduces it consistently.** Flat shapes and a
   limited palette are a much smaller target than matched brushwork across 200
   assets.

### Prompt skeleton

> Flat 2D vector game icon, art-deco noir style, in the visual language of a
> vintage engraved emblem. **&lt;subject&gt;**, seen straight from the side,
> perfectly symmetrical. The body is a solid dark charcoal silhouette. Its form
> is described by VERY THICK, bold, heavy warm gold line art: chunky gold
> outlines of uniform generous weight, broad gold edge highlights, simple bold
> gold ornament. Thick confident strokes like a woodcut or a logo, not fine
> detail. Flat fills only, no shading, no gradients, no texture. Extremely high
> contrast, graphic and iconic, readable as a tiny icon. Centred, filling 85
> percent of the frame. Flat solid medium teal background, RGB 45 110 110,
> completely uniform, no vignette, no border, no frame, no text.

Generate in **gold**, always. Gold is a mid-hue with strong saturation, which is
the best source for recolouring in either direction along the ladder.

### Tier production

```bash
scripts/gen-local.sh "<prompt>" art/refs/weapon_sword_02.png 1024 1024 6
python .claude/skills/asset-gen/tools/rembg_matting.py \
  art/refs/weapon_sword_02.png -o art/matted/weapon_sword_02.png --alpha-floor 0.06
art/.venv/bin/python scripts/tier-tint.py \
  art/matted/weapon_sword_02.png art/promoted --prefix weapon_sword_02
```

Roughly two minutes of compute per *design*, not per tier. `proof/art/tier-ladder.png`
shows the result on real item cards.

### Tier is never signalled by colour alone

Every card carries the tier colour on the frame AND the line work, the tier name
spelled out, and a 1–7 pip count. A gray/green/blue/violet/gold/magenta/red
ladder is not reliably separable under deuteranopia, and roughly 8% of a
male-skewed audience is affected.
