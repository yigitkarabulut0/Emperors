# Emperors — Art Design

> Produced by an architecture pass on 2026-09-04 and adversarially reviewed.
> Owner decisions made *after* this document was written take precedence — see the build plan.

**Headline:** Adopt a single painted "Illuminated Iron" loot-icon style locked by one hero reference image, produce all ~200 assets as 33 Gemini grid-sheet generations for ~$8.60, and resolve the epic/mystic clash by keeping both in the same violet hue but splitting them 44 L* apart (epic #9A3AD1 deep, mystic #EDD6FF iridescent) — a palette verified to hold ≥22 ΔE separation under protan/deutan/tritan simulation.

---

Emperors — Art Direction & Gemini Asset Production Plan

Everything below is grounded in the actual code at `/Users/yigitkarabulut/Developer/godogen-src/asset-gen/tools/` (read, not assumed) and in verified 2026 docs for Gemini image models, Godot 4.7 and Google Fonts. Where the shipped tool is broken or misdocumented, that is called out with the file and line.

---

## 0. Ground truth established by reading the tools

These facts change the plan, so record them before anything else.

| Fact | Source | Consequence |
|---|---|---|
| `GEMINI_MODEL = "gemini-3.1-flash-image-preview"` is hardcoded | `asset_gen.py:107` | Cannot use `gemini-3-pro-image` without a patch. See §4.1. |
| Cost is a pure function of `--size`: 5/7/10/15c for 512/1K/2K/4K. `--image` adds **nothing** | `asset_gen.py:110`, `cmd_image()` | **Always pass `--image`.** Image-to-image is free. There is no reason to ever run a bare text-to-image after the style bible exists. |
| `import xai_sdk` is unconditional at module top | `asset_gen.py:23` | `xai-sdk` must be installed even though we never use Grok, or every call crashes on import. |
| `TRIPO3D_API_KEY` is only read lazily inside `get_api_key()` | `tripo3d.py:24` | No Tripo key needed; the `from tripo3d import ...` at `asset_gen.py:28` is safe. |
| Gemini aspect ratios accepted by the CLI include `1:4`, `4:1`, `8:1`, `1:8` | `asset_gen.py:113-116` | Per current Google docs, `gemini-3.1-flash-image` supports only `1:1, 3:2, 2:3, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9`. **Never use the strip ratios** — they will error or silently fall back. |
| `grid_slice.py` fills **row-major** (`row, col = divmod(i, cols)`) and slices on exact integer division `w // cols` | `grid_slice.py:26-31` | `--names` must be listed left-to-right, top-to-bottom. Any object crossing a cell boundary is destroyed by the cut. |
| `rembg_matting.py --preview` raises `NameError` in single mode: `bg_color` is never bound in `main()` | `rembg_matting.py:312` | Documented bug. Workaround in §5.4. |
| `process_batch()` has **no** preview parameter at all | `rembg_matting.py:236` | `--preview` is *silently ignored* in `--batch` mode. This is a second, undocumented bug. |
| `recover_foreground()` sets `fg[alpha < 0.02] = 0.0` — fully transparent pixels get **black RGB** | `rembg_matting.py:135` | Godot must import icons with `process/fix_alpha_border=true` or every icon gets a dark halo when filtered. Non-negotiable. |
| `_generate_gemini` comment: "Gemini may return JPEG data", re-encoded via PIL | `asset_gen.py:150` | JPEG ringing is baked in *before* matting. Background colours must be chosen with large chroma distance, and `--bg-thresh 0.03` is the default remedy. |
| `requirements.txt` pins `onnxruntime-gpu` + `nvidia-cudnn-cu12==9.*` | `tools/requirements.txt` | No Apple Silicon wheels. Must install plain `onnxruntime` (verified: `onnxruntime-1.29.0-cp314-cp314-macosx_14_0_arm64.whl` exists on PyPI, so Python 3.14 is fine). |
| There is **no `music` subcommand** — only `image, video, glb, rig, retarget, resume` | `asset_gen.py:528-578` | Lyria requires a ~30-line sibling script. §7.2. |
| Only `ios.zip` export template is present for 4.7.2.stable | `~/Library/Application Support/Godot/export_templates/4.7.2.stable/` | All art QA happens in the editor or on device. No web build for review. |
| No `GEMINI_API_KEY` / `GOOGLE_API_KEY` in the environment | `env` | Must be exported before the first call. Set **only** `GEMINI_API_KEY` — if both are set, `GOOGLE_API_KEY` silently wins and logs a warning. |

---

## 1. Art direction

### 1.1 The four candidates, scored

| Style | (a) Model reproducibility across 150+ assets | (b) Legibility at 64–128 px | (c) Fit for a 7-tier rarity fantasy |
|---|---|---|---|
| **Painterly semi-realistic game-icon art** (mobile RPG loot icons) | **Excellent.** This is the single most densely represented style in image-model training data. A fixed prompt skeleton + one hero reference reproduces it very tightly. Failure mode is *detail level* drift, not *style* drift — and detail drift is invisible after downscaling to 256 px. | **Conditional.** Painterly micro-detail dissolves below ~96 px. Solvable by mandating a silhouette rule in the style fragment (no feature thinner than 1/40 of the cell). | **Excellent.** Gold filigree, gem inlays, enamel channels, opalescent sheen, blackened steel — the rarity vocabulary is native to the style and needs no invention. |
| Clean stylized vector / flat | **Poor.** Diffusion models cannot hold constant stroke width or true flat fills across 150 assets; gradients and painterly noise creep back in constantly. You end up hand-fixing in a vector tool, which is not the plan. | **Best of the four.** | **Weak.** Flat art cannot carry seven levels of "material richness"; all rarity signalling collapses onto the frame, so the item itself never feels legendary. |
| Chunky hand-painted "Clash" style | **Good.** Well represented, chunky forms self-stabilise. | **Excellent.** | **Good but wrong tone.** Reads comedic/toy. With 21 swords in Clash style the top three tiers stop feeling dangerous, and PvP + a 3% gold steal wants some gravity. **Runner-up.** |
| Pixel art | **Worst.** Gemini produces *fake* pixel art: non-integer pixel grid, anti-aliased edges, inconsistent cluster size. Minimum generation is 1K, so a 1024 px fake-pixel image downsampled to 64 is mush. 150 consistent assets is not achievable. | Excellent at native res only — which we cannot hit. | Fine, but irrelevant given (a). |

### 1.2 Recommendation — **"Illuminated Iron"**

Painterly semi-realistic loot-icon art, **disciplined by the chunky-silhouette rule borrowed from Clash**. Concretely: paint like a mobile RPG loot icon, but compose like a Clash asset — big primary masses, one clear read, no lace.

Justification against the three criteria: it wins (a) outright, it wins (c) outright, and it loses (b) only in its undisciplined form, which the style fragment fixes with one enforceable rule ("no feature thinner than 1/40 of the cell width"). No other candidate wins two of three.

### 1.3 The style prompt fragment — `STYLE_CORE`

Store verbatim at `art/prompts/_style_core.txt` and append to **every** generation. Do not edit it once the style bible is approved; editing it invalidates the whole library's consistency.

```
STYLE — EMPERORS / "ILLUMINATED IRON":
Hand-painted mobile-RPG loot-icon art, semi-realistic, digital oil painting with
visible brush facets and painted specular highlights. Chunky, instantly readable
silhouette: bold primary masses, no feature thinner than one fortieth of the
cell width. Straight-on three-quarter hero angle, object dead centre, object
upright.
Single warm key light from the upper left at 45 degrees; cool fill from the
lower right; a thin warm rim light along the upper-right contour; deep contact
shadow absorbed into the object itself and never cast onto the background.
Materials read as forged iron, blued steel, aged brass, hammered gold, oiled
leather, dark oak, linen and horn. Muted base palette of iron grey, oxblood,
olive, umber and parchment, with exactly ONE saturated accent colour per object.
Crisp painted edges. NO outline stroke, NO cel shading, NO flat vector fills,
NO pixel art, NO 3D render look, NO photograph, NO airbrush gradients.
NO text, NO letters, NO numbers, NO watermark, NO signature, NO logo,
NO decorative border, NO vignette, NO lens flare, NO motion blur, NO depth of
field, NO drop shadow on the background, NO reflection of any other object.
```

And the companion `LAYOUT_GRID` fragment (`art/prompts/_layout_4x4.txt`), which is what actually makes sheet batching work:

```
LAYOUT: a strict 4 by 4 grid of 16 equal square cells filling the whole image.
Exactly one object per cell. Every object is centred in its cell and leaves at
least 12 percent empty background margin on all four sides of that cell. No
object touches or crosses a cell boundary. No object overlaps another. Every
object is drawn at the same scale, the same camera angle and the same lighting.
Do NOT draw grid lines, separators, panels, cards, labels, captions or numbers.
The background is one single flat colour across the entire image, edge to edge,
with no gradient, no vignette, no texture and no shading.
```

### 1.4 Hero-reference strategy (the style lock)

Two levels, chain depth capped at **2** (the skill explicitly warns that deeper chains drift).

**Level 0 — the style bible.** One 2K 1:1 3×3 sheet containing one exemplar of every material family the game will ever need: iron sword, steel cuirass, brown warhorse, gold coin, leather satchel, oak shield, cut gem, stone brick panel, rolled parchment. Iterate until the owner signs off; budget 3 attempts (30c). This file — `art/ref/hero_style_bible.png` — is the most valuable artefact in the project.

**Level 1 — family heroes.** After the first sheet of a family is approved, crop its single best cell, upscale to 1024 with Lanczos, and save as `art/ref/hero_sword.png` / `hero_armor.png` / `hero_horse.png` / `hero_soldier.png`. Every later sheet in that family references it.

**The one-reference problem and its workaround.** `asset_gen.py` exposes a single `--image` (`p_img.add_argument("--image", default=None, ...)`, `asset_gen.py:536`) and passes exactly one `types.Part.from_bytes` (`asset_gen.py:129-133`). Gemini 3.1 Flash accepts up to 10 object + 4 character + 3 style references, but the CLI cannot send them. Rather than patch, **composite two references into one two-panel board**:

```bash
magick "$ART/ref/hero_style_bible.png" -resize 1024x1024 \
       \( "$ART/ref/hero_sword.png" -resize 1024x1024 \) +append \
       "$ART/ref/ref_style_plus_sword.png"
```

and prepend to the prompt:

```
The reference image is a two-panel board. The LEFT panel defines the global
rendering style: brushwork, lighting direction, material treatment, edge
quality, palette temperature. The RIGHT panel defines this object family:
proportions, blade geometry, hilt language, level of ornament. Match both.
Do NOT copy the composition or the layout of the reference.
```

This costs nothing, needs no code change, and is the recommended path.

---

## 2. The tier colour system

### 2.1 Resolving epic = purple / mystic = purple

**Proposal: honour the owner's statement literally — keep both in the same violet hue — and separate them on lightness instead.**

Epic is hue 278°, mystic is hue 274°. They are, as specified, both purple. But epic sits at **L\* 44.9** and mystic at **L\* 88.6** — a 44-point gap. Epic is a deep saturated royal violet; mystic is a pale iridescent lavender-white, the trading-card "holo / secret rare" register. This is a stronger escalation than a hue change would be, and it does not overrule the owner.

The rejected alternative was moving mystic to magenta. That breaks the owner's stated intent, and magenta wedged between gold (legendary) and red (special) is a hue regression that reads worse, not better.

### 2.2 The palette — verified, not guessed

Derived by constrained search over hue-fixed lightness ladders, scored on minimum CIE ΔE across **normal vision plus Machado protanopia, deuteranopia and tritanopia simulations**, subject to ≥3.0:1 contrast against the dark panel `#1B1712`.

**Result: minimum pairwise ΔE = 22.5 across all four vision models.** (Unconstrained the optimum is 22.2 in the constrained space and 19.9 unconstrained-for-contrast — the contrast floor cost nothing.)

| Tier | `base` | `deep` (gradient bottom / stroke) | `text` (≥4.5:1 on `#1B1712`) | `glow` (additive) | L\* | contrast on panel |
|---|---|---|---|---|---|---|
| common | `#6E7D91` | `#3D4A5C` | `#748295` | `#A1A7B0` | 51.9 | 4.25 |
| uncommon | `#97DC74` | `#5CC228` | `#97DC74` | `#C9EAB7` | 81.3 | 10.87 |
| rare | `#64A7F2` | `#0B72E5` | `#64A7F2` | `#B1D2F6` | 67.1 | 7.09 |
| epic | `#9A3AD1` | `#621A8B` | `#AE62DB` | `#BB80DC` | 44.9 | 3.31 |
| legendary | `#F2AA02` | `#8E6300` | `#F2AA02` | `#F9C54D` | 74.6 | 8.94 |
| mystic | `#EDD6FF` | `#C070FF` | `#EDD6FF` | `#FFFFFF` | 88.6 | 13.30 |
| special | `#D3222E` | `#7F1017` | `#E15158` | `#E1666E` | 45.9 | 3.43 |

Closest pairs per vision model (all safely separated):

- normal: common/rare ΔE 35, rare/mystic 37, common/mystic 40
- protanopia: uncommon/legendary 25, rare/mystic 30, common/rare 34
- deuteranopia: **rare/epic 22**, uncommon/special 30, uncommon/legendary 35
- tritanopia: uncommon/rare 25, common/rare 32, uncommon/mystic 33

The binding constraint is deutan rare-vs-epic at 22 — comfortably above the ~15 threshold where 24 px chips become confusable, and it is additionally separated by ray count and gem count (below).

Two supporting neutrals: panel `#1B1712` (dark oiled oak/parchment shadow), parchment `#E8D9B5` (for the light surfaces inside panels).

Godot: store these as a single `TierPalette` resource (`.tres`) with four `PackedColorArray`s indexed by the tier enum. Never inline a hex anywhere else.

### 2.3 Conveying tier without colour

Colour alone can never carry seven categories accessibly. Each tier gets an independent non-colour signature:

| Tier | Frame material | Ornament | Gems | Glow | Rays | Particles |
|---|---|---|---|---|---|---|
| common | rough dark iron band, mid value | plain rivet at each corner | 0 | none | 0 | none |
| uncommon | iron with a single bronze inlay line | small bronze bracket | 1 | 8% | 0 | none |
| rare | polished steel, blued edge | engraved chevron, light value | 2 | 15% | 0 | one sparkle / 4 s |
| epic | dark silver, violet enamel channel | embossed scrollwork, dark value | 3 | 25% | 4 static | slow rising motes |
| legendary | hammered gold, filigree | crown notch top-centre + laurel below | 4 | 35% | 8 rotating | gold embers rising |
| mystic | prismatic opalescent white-silver, starfield inlay | floating silver rings | 5 | 45%, hue cycles ±15° | 12 rotating + shimmer sweep | white sparks drifting |
| special | **obsidian black** (the only dark frame) | crimson wax-seal medallion bottom-centre + torn red ribbon top-left | **0** | 40% crimson | **0** | embers falling **downward** |

The grayscale identity proof — the tuple *(gem count, ray count, frame value)* is unique for all seven: `(0,0,mid) (1,0,mid) (2,0,light) (3,4,dark) (4,8,light) (5,12,white) (0,0,black)`. Common and special share `(0,0,·)` but are separated by frame value (mid grey vs near-black) and by the wax seal. Every tier is therefore identifiable on a monochrome screen.

Special deliberately breaks the ladder — zero gems, zero rays, the only dark frame, particles falling instead of rising. It is *beside* the power ladder, not on top of it, which is exactly what "special" should communicate.

Belt and braces: the tier name is always printed in `text` colour beside the item, and a settings toggle "show tier numerals" adds a small `I`–`VII` badge in the frame's bottom-right.

Rays are **one** asset: a single 1024 px white radial-ray sprite, `modulate`d to the tier's `glow` colour, rotated by a `Tween`, `CanvasItemMaterial.blend_mode = BLEND_MODE_ADD`, with `rays_visible_count` driving a shader `alpha` mask or simply three prebuilt rotations. Zero per-tier cost.

---

## 3. Complete asset inventory

### 3.1 Naming scheme

Generation workspace (**outside** `res://`, never shipped):

```
art/
  prompts/_style_core.txt, _layout_4x4.txt, <batch>.txt   # one committed file per generation
  ref/hero_style_bible.png
  ref/hero_{sword,armor,horse,soldier}.png
  ref/ref_style_plus_{sword,armor,horse,soldier}.png
  raw/<batch>.png            # IMMUTABLE, append-only, the only irreplaceable artefact
  cells/<batch>/<name>.png   # grid_slice output
  cut/<batch>/<name>.png     # rembg output
  qa/<batch>_{magenta,light,64px}.png
  MANIFEST.md
```

Shipped, under `res://art/`:

```
items/sword/item_sword_<tier>_<nn>.png        # tier ∈ common..special, nn ∈ 01..04
items/armor/item_armor_<tier>_<nn>.png
items/horse/item_horse_<tier>_<nn>.png
soldiers/soldier_<type>_<tier>.png            # type ∈ peasant|mercenary|gladiator
ui/tabs/tab_<tab>.png                         # family|collect|inventory|shop|soldiers|attack
ui/icons/icon_<name>.png
ui/frames/frame_<tier>_corner.png  +  frame_<tier>.png
ui/panels/panel_<name>.png
ui/buttons/btn_<class>_corner.png             # class ∈ primary|secondary|danger
ui/materials/mat_<name>.png
collect/job_<slug>.png
upgrades/upg_family_<slug>.png | upg_kingdom_<slug>.png
bg/bg_<screen>.png
fx/fx_<name>.png
brand/{app_icon_1024.png, logo_wordmark.png, splash.png}
```

The database stores only `sprite_key` (e.g. `"sword_legendary_02"`, `"gladiator_mystic"`). The client resolves it through an `ArtRegistry` autoload; the server never knows a file path.

### 3.2 Item icons — N = 4 per (type, tier)

**3 types × 7 tiers × 4 designs = 84 icons.**

Why 4: the shop rolls one item at a time but the inventory holds dozens. With 4 designs, a full inventory of same-tier items shows four distinct silhouettes — enough to defeat the "wall of clones" read — while 4 is exactly one row of a 4×4 sheet, which is what makes the batching plan work. Going to 8 doubles the sheet count for a difference nobody notices past the first hour; going to 2 makes a 30-slot inventory look broken.

**The sheet layout is the key decision: rows = tiers, columns = designs.** One image therefore contains four escalation levels at once, which means the model *self-anchors* the escalation — row 4 comes out demonstrably fancier than row 1 without any post-hoc balancing, and all four designs in a row share tier-appropriate materials by construction. Per type: sheet A = common/uncommon/rare/epic, sheet B = legendary/mystic/special + one spare row.

### 3.3 Full inventory with counts

| Group | Count shipped | Notes |
|---|---:|---|
| Item icons | **84** | 3 types × 7 tiers × 4 (+12 spares generated) |
| Soldier portraits | **21** | 3 types × 7 tiers (+3 spares) |
| Player portraits | 4 | lord/lady × 2 variants |
| Tab bar icons | **6** | active/inactive derived in-engine via `modulate` — see below |
| UI icons | 16 | gold, diamond, energy, attack, defence, power, reputation, XP, timer, lock, protection, plus, 3 empty-slot plates, scroll |
| Tier frame corners | 7 | mirrored into 7 full 9-slice frames |
| Ornament pieces | 9 | corner bracket, cartouche, divider knot, rivet, shield boss, laurel, rope, chain link, tassel |
| Material tiles | 4 | parchment, dark oak, tooled leather, hammered brass — seamless |
| Button corners | 3 | primary/secondary/danger; 9 states derived in-engine |
| Collect job icons | 15 | grapes, strawberries, wheat, apples, honey, fish, timber, wool, iron ore, salt, herbs, silver ore, silk, spices, gold ore |
| Upgrade icons | 20 | family + kingdom trees |
| Backgrounds | 4 | kingdom (Family), battle (Attack), shared parchment interior, kingdom hall banner |
| Banners | 3 | victory, defeat, protected |
| FX | 4 | level-up burst, radial rays, soft particle dot, shimmer sweep |
| Brand | 3 | app icon, wordmark, splash |
| **Total shipped PNGs** | **≈203** | from **226 generated cells** across **33 API calls** |

**The six tab icons are generated once, not twice.** Active/inactive are a `modulate` swap (`#8A7E6B` → `#F2D399`) plus a parchment pill behind and a 1.08 scale tween. Generating 12 icons would guarantee that the two states of the same tab don't quite match — deriving them guarantees they do.

The same principle removes 6 of the 9 button states and all 7 tier tint variations.

### 3.4 The 33 generations and the cost

| # | Batch | Size / AR | Grid | Cells | Cost |
|---|---|---|---|---:|---:|
| 1–3 | style bible (3 iterations) | 2K 1:1 | 3×3 | ref only | 30c |
| 4 | items: sword A (common→epic) | 4K 1:1 | 4×4 | 16 | 15c |
| 5 | items: sword B (legendary/mystic/special/spare) | 4K 1:1 | 4×4 | 16 | 15c |
| 6–7 | items: armor A, armor B | 4K 1:1 | 4×4 | 32 | 30c |
| 8–9 | items: horse A, horse B | 4K 1:1 | 4×4 | 32 | 30c |
| 10–12 | soldiers: peasant, mercenary, gladiator | 4K 3:2 | 4×2 | 24 | 45c |
| 13 | player portraits | 2K 1:1 | 2×2 | 4 | 10c |
| 14 | tab bar icons | 2K 3:2 | 3×2 | 6 | 10c |
| 15 | UI icon sheet | 2K 1:1 | 4×4 | 16 | 10c |
| 16 | tier frame corners | 2K 1:1 | 3×3 | 9 | 10c |
| 17 | ornament pieces | 2K 1:1 | 3×3 | 9 | 10c |
| 18 | material tiles (seamless, **not** matted) | 2K 1:1 | 2×2 | 4 | 10c |
| 19 | button corners | 2K 1:1 | 2×2 | 4 | 10c |
| 20 | collect job icons | 4K 1:1 | 4×4 | 16 | 15c |
| 21–22 | upgrade icons A, B | 4K 4:3 | 4×3 | 24 | 30c |
| 23–25 | bg kingdom / battle / parchment interior | 2K 9:16 | — | 3 | 30c |
| 26 | bg kingdom hall banner | 2K 16:9 | — | 1 | 10c |
| 27–29 | banners: victory / defeat / protected | 1K 16:9 | — | 3 | 21c |
| 30 | fx sheet (burst, rays, dot, shimmer) | 2K 1:1 | 2×2 | 4 | 10c |
| 31–32 | app icon, wordmark | 1K 1:1 | — | 2 | 14c |
| 33 | splash art | 2K 9:16 | — | 1 | 10c |
| | **TOTAL** | | | **226 cells** | **375c = $3.75** |

That is **1.9c per shipped asset**. Realistic total including one reroll per batch and a 1K prompt-debug pass before each of the 20 grid sheets:

`375 (base) + 260 (reroll grids) + 85 (reroll singles) + 140 (20 × 7c drafts) = 860c = **$8.60**`

Working budget **$9.00**, hard cap **$15.00** (§9).

Why 4K for item/soldier/collect/upgrade sheets and 2K elsewhere: a 4K 4×4 gives 1024 px cells, which after `-trim` + Lanczos down to 256 px yields visibly cleaner anti-aliasing than a 2K 4×4's 512 px cells, and leaves headroom to ship 512 px icons for iPad later. The delta is 5c per sheet — $0.45 across the whole project. Take it.

---

## 4. Production strategy

### 4.1 One-time setup

```bash
# Python env. NOTE: the shipped requirements.txt is unusable on Apple Silicon.
uv venv --python 3.14 ~/.venvs/emperors-art
source ~/.venvs/emperors-art/bin/activate
uv pip install google-genai xai-sdk requests numpy pillow rembg pymatting onnxruntime
#              ^^^^ needed even though unused: asset_gen.py:23 imports it unconditionally
#                                                       ^^^^^^^^^^^ NOT onnxruntime-gpu,
#                                                       NOT nvidia-cudnn-cu12 (no arm64 wheels)

export ASSET_GEN_SKILL_DIR="$HOME/Developer/godogen-src/asset-gen"
export ART="$HOME/Developer/Emperors/art"
export GEMINI_API_KEY="…"     # set ONLY this one; GOOGLE_API_KEY would take precedence
```

First `rembg` run downloads BiRefNet (~900 MB) to `~/.u2net`. It will run **CPU-only** on this machine (`_has_nvidia_gpu()` returns false, `rembg_matting.py:38`), roughly 3–8 s per 1024 px cell — budget 30–45 minutes for a full 226-cell matting pass.

**Optional 3-line patch, worth doing before the first paid call** — make the model selectable so `gemini-3-pro-image` is reachable if 3.1-flash's grid layout proves unreliable, and so the `-preview` alias retiring doesn't brick the tool:

```python
# asset_gen.py:107  — replace
GEMINI_MODEL = "gemini-3.1-flash-image-preview"
# with
import os
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-image-preview")
```

Then `GEMINI_MODEL=gemini-3-pro-image` for the hard sheets. Note Pro does **not** support `512`, so keep `--size` at 1K or above.

**Calibration call, run once, before budgeting anything:** Google does not publish the pixel dimensions for `1K`/`2K`/`4K` per aspect ratio. Generate one throwaway 4K 1:1 sheet and record the truth:

```bash
magick identify -format "%wx%h\n" "$ART/raw/_calibration.png"
```

`grid_slice.py` divides with `//`, so a 4096×4096 → 4×4 gives exactly 1024 px cells; a 4096×2731 (3:2) → 4×2 gives 1024×1365 and loses one pixel row. Both fine — just know the real numbers before you write the resize step.

### 4.2 What goes on a sheet, and what does not

| Sheet | Why |
|---|---|
| **On a sheet:** item icons, soldier cards, collect jobs, upgrades, UI icons, tab icons, tier frame corners, ornaments, button corners, materials, FX | All are small, same-scale, same-lighting objects. Sheet generation *forces* consistency: a single denoising pass renders all 16 objects under one lighting model, which no amount of prompt discipline can achieve across 16 separate calls. |
| **Individual:** all backgrounds, all banners, app icon, wordmark, splash | Full-bleed compositions. A grid would waste 90% of the pixels and the aspect ratio must match the display surface. |

**4×4 is the reliability ceiling.** 5×5 works sometimes; 6×6 and above regularly produce merged cells, duplicated objects and drawn grid lines. Do not go above 16 cells to save 5c — a failed 6×6 costs a full reroll plus your afternoon.

### 4.3 The pipeline, per batch

```bash
BATCH=sword_b
LOG=$(mktemp)

# 1 — GENERATE. Always with --image (free) and always with --model gemini (default is grok).
python3 "$ASSET_GEN_SKILL_DIR/tools/asset_gen.py" image \
  --model gemini --size 4K --aspect-ratio 1:1 \
  --image "$ART/ref/ref_style_plus_sword.png" \
  --prompt "$(cat "$ART/prompts/$BATCH.txt")" \
  -o "$ART/raw/$BATCH.png" 2>"$LOG" || tail -20 "$LOG"

# 2 — INSPECT THE RAW SHEET BEFORE SLICING. Accept/reject rule in §5.5.

# 3 — SLICE. Row-major, left-to-right then top-to-bottom (grid_slice.py:27).
python3 "$ASSET_GEN_SKILL_DIR/tools/grid_slice.py" "$ART/raw/$BATCH.png" \
  -o "$ART/cells/$BATCH" --grid 4x4 \
  --names "item_sword_legendary_01,item_sword_legendary_02,item_sword_legendary_03,item_sword_legendary_04,item_sword_mystic_01,item_sword_mystic_02,item_sword_mystic_03,item_sword_mystic_04,item_sword_special_01,item_sword_special_02,item_sword_special_03,item_sword_special_04,item_sword_spare_01,item_sword_spare_02,item_sword_spare_03,item_sword_spare_04"

# 4 — MATTE. Batch mode reuses one BiRefNet session and samples bg per cell.
python3 "$ASSET_GEN_SKILL_DIR/tools/rembg_matting.py" --batch "$ART/cells/$BATCH" -o "$ART/cut/$BATCH"
#   background remnants  -> add --bg-thresh 0.03
#   missing foreground   -> add -m trust
#   coloured halo        -> add -m adapt --fg-thresh 0.10
#   Tune on ONE cell in single mode, then apply the same flags to the batch.

# 5 — QA (replaces the broken --preview; see §5.4)
mkdir -p "$ART/qa"
magick montage "$ART/cut/$BATCH"/*.png -tile 4x4 -geometry 256x256+8+8 \
  -background magenta -flatten "$ART/qa/${BATCH}_magenta.png"
magick montage "$ART/cut/$BATCH"/*.png -tile 4x4 -geometry 256x256+8+8 \
  -background '#F2F2F2' -flatten "$ART/qa/${BATCH}_light.png"
magick montage "$ART/cut/$BATCH"/*.png -tile 4x4 -geometry 64x64+4+4 \
  -background '#1B1712' -flatten "$ART/qa/${BATCH}_64px.png"

# 6 — NORMALISE + DOWNSCALE. -trim/-extent equalises optical size across cells,
#     which is what makes an inventory grid look designed rather than generated.
mkdir -p "$ART/final/items/sword"
magick mogrify -path "$ART/final/items/sword" \
  -trim +repage -filter Lanczos -resize 232x232 \
  -background none -gravity center -extent 256x256 \
  -strip -define png:color-type=6 "$ART/cut/$BATCH/*.png"

# 7 — IMPORT
cp "$ART/final/items/sword"/item_sword_*.png "$GAME/art/items/sword/"
godot --headless --path "$GAME" --import
```

### 4.4 Background colours per batch

Rule: **never prompt "transparent background"** (the model draws a checkerboard). Choose a solid colour whose hue is ≥120° from the batch's dominant subject hue *and* whose L\* differs by ≥30 from every subject mid-tone. Avoid pure chroma key `#00FF00` — it fringes. Prefer a colour near the in-game surround so residual fringe blends.

| Batch | Background | Why |
|---|---|---|
| Swords | `#6B4A2F` saddle brown | Complementary to blue-steel; L\* 38 vs legendary gold L\* 75 gives the colour-matting alpha a 37-point gap even on the gold row. |
| Armor | `#3F4A5C` cold slate | Leather and brass dominate this batch, so a brown bg would collide; slate is the complement. |
| Horses | `#2E5A46` deep forest green | Coats span black, white, chestnut, grey — green is far from all of them, and "pasture" means fringe reads as grass, not error. |
| Soldier cards | `#33564A` muted pine | Skin tones and cloth; green separates skin cleanly and is close to the game's outdoor surround. |
| UI icons / currency | `#3B3B44` charcoal-violet | Batch contains gold, blue diamond and yellow bolt; a neutral dark that is far from all three. |
| Tier frame corners | `#2A2A2E` near-black | Frames are bright metal; huge value gap. Also lets the *special* black frame survive — check its cell manually. |
| Ornaments / buttons | `#33383F` cool charcoal | Brass and oak. |
| Collect jobs / upgrades | `#38424E` cool slate | Mixed produce and ore; wheat-gold would collide with any warm bg. |
| Materials, backgrounds, banners, splash | **none — do not matte** | Full-bleed. `rembg` must never touch these. |

Watch the *special* tier row on the sword sheet: obsidian-black objects on a `#6B4A2F` background matte fine, but if `Transparent: 0` appears in the rembg output, force `-m trust`.

### 4.5 Five (six) verbatim prompts

Each is prepended to `LAYOUT_GRID` + `STYLE_CORE`. Written to `art/prompts/<batch>.txt` and committed *before* any paid call.

**(1) `sword_b.txt` — the legendary/mystic/special sword sheet**

```
SUBJECT: sixteen distinct medieval single-handed and hand-and-a-half SWORDS,
blade pointing up, hilt down, seen from the side, presented as game inventory
icons.

ROW 1 (cells 1-4) — LEGENDARY tier: royal heirloom swords. Hammered gold and
polished pale steel, fullered blades with etched scrollwork, cross-guards shaped
as spread wings, lion heads or laurel, amber and topaz cabochons in the pommel,
grips wrapped in cream leather bound with gold wire. Warm golden accent colour.

ROW 2 (cells 5-8) — MYSTIC tier: arcane blades. Opalescent white-silver steel
with a faint prismatic sheen, blades that read as part crystal and part metal,
guards of woven silver filigree and floating rings, milky moonstone and clear
quartz in the pommel, grips of pale bleached leather. Iridescent pale lavender
accent colour. The edges may look faintly luminous, but the light must stay ON
the blade and must never spill onto the background.

ROW 3 (cells 9-12) — SPECIAL tier: sinister ceremonial blades. Blackened
obsidian-dark steel with crimson enamel channels, guards of thorned iron and
bone, a crimson wax seal medallion set into the pommel, grips of oxblood leather
bound in black cord. Deep crimson accent colour. Darker overall value than the
other three rows.

ROW 4 (cells 13-16) — four plain undecorated arming swords in dull grey iron,
no gems, no gold, no engraving, for use as spares.

Every one of the sixteen swords must have a clearly different blade profile and
a clearly different guard shape, so that all sixteen silhouettes are
distinguishable from one another at thumbnail size. All sixteen must be the same
height in their cells.

BACKGROUND: one single flat solid saddle-brown colour, hex #6B4A2F, edge to
edge, absolutely uniform, no gradient, no texture, no shading, no vignette.
```

**(2) `armor_a.txt` — the armor sheet**

```
SUBJECT: sixteen distinct medieval BODY ARMOURS shown as empty worn suits and
torso cuirasses on an invisible mannequin, front view, shoulders level,
presented as game inventory icons. No head, no helmet, no legs below the hip,
no character inside, no stand or plinth visible.

ROW 1 (cells 1-4) — COMMON tier: peasant protection. Quilted linen gambesons,
boiled leather jerkins, rope-stitched hide, rough patched cloth. Dull umber,
undyed flax and dirty olive. No metal plates, no decoration.

ROW 2 (cells 5-8) — UNCOMMON tier: levy armour. Riveted leather with iron
studs, short mail shirts over padding, simple bronze shoulder caps, plain
buckled belts. One green-dyed cloth accent per suit.

ROW 3 (cells 9-12) — RARE tier: soldier's harness. Blued steel breastplates over
mail, articulated pauldrons, brass rivets and buckles, a plain tabard panel.
One steel-blue cloth accent per suit.

ROW 4 (cells 13-16) — EPIC tier: knight's plate. Fluted dark silver plate with
violet enamel channels, embossed pauldrons, engraved edges, an amethyst set at
the throat, a violet cloth mantle across the shoulders.

Every one of the sixteen armours must have a clearly different shoulder line,
neckline and chest silhouette so that all sixteen shapes are distinguishable at
thumbnail size. Keep all sixteen at the same height in their cells.

BACKGROUND: one single flat solid cold slate-blue colour, hex #3F4A5C, edge to
edge, absolutely uniform, no gradient, no texture, no shading, no vignette.
```

**(3) `horse_a.txt` — the horse sheet**

```
SUBJECT: sixteen distinct medieval WARHORSES, each standing in full side profile
with the head to the left, all four legs visible, tack and barding fitted,
presented as game inventory icons. No rider, no ground, no shadow on the ground.

ROW 1 (cells 1-4) — COMMON tier: farm and pack horses. Shaggy, thick-legged,
mud-flecked. Rope halters, plain blanket, no armour. Dun, muddy bay, dirty grey,
piebald.

ROW 2 (cells 5-8) — UNCOMMON tier: riding horses. Cleaner coats, leather bridles
with bronze fittings, a simple green saddle blanket, light saddle bags.
Chestnut, liver bay, dark dun, strawberry roan.

ROW 3 (cells 9-12) — RARE tier: cavalry chargers. Muscular, braided mane, studded
leather peytral across the chest, a blued steel chanfron on the head, a
steel-blue caparison. Black, dark bay, steel grey, blood bay.

ROW 4 (cells 13-16) — EPIC tier: destriers in full barding. Heavy, arched neck,
articulated dark silver plate barding with violet enamel channels, a violet
caparison with a scalloped hem, engraved chanfron with a small crest.

Every one of the sixteen horses must have a clearly different coat colour and a
clearly different head-and-neck posture so all sixteen silhouettes are
distinguishable at thumbnail size. All sixteen horses must be the same size in
their cells and every single one must face the same direction.

BACKGROUND: one single flat solid deep forest-green colour, hex #2E5A46, edge to
edge, absolutely uniform, no gradient, no texture, no shading, no vignette.
```

*(The skill warns that "facing left" vs "facing right" is unreliable. Do not fight it: accept whichever direction comes back as long as all sixteen agree, and flip horizontally in Godot if the layout ever needs the mirror. Never pay for a mirrored generation.)*

**(4) `soldier_gladiator.txt` — the soldier card sheet (4×2 on a 3:2 canvas)**

```
SUBJECT: eight distinct GLADIATOR soldier portraits for a medieval kingdom game,
each a waist-up three-quarter portrait of a single fighter facing slightly to
the viewer's left, arms and weapons kept entirely inside the cell, presented as
collectible character art WITHOUT any card border.

The eight fighters escalate in status from cell 1 to cell 7; cell 8 is a spare.
cell 1 COMMON — a scarred bare-chested pit fighter in a rope belt and a single
   leather bracer, holding a chipped iron shortsword. Drab, dirty, unadorned.
cell 2 UNCOMMON — a veteran in a studded leather harness with a bronze shoulder
   cap, a green sash, a notched falchion.
cell 3 RARE — a champion in a blued steel manica and segmented shoulder plate, a
   steel-blue cloak pinned at one shoulder, a trident and a small buckler.
cell 4 EPIC — an arena lord in fluted dark silver plate with violet enamel
   channels, a plumed crested helm carried under one arm, an amethyst clasp.
cell 5 LEGENDARY — a golden champion in hammered gold and pale steel armour with
   winged pauldrons, a laurel circlet, a cream cloak embroidered with gold wire.
cell 6 MYSTIC — an ethereal fighter in opalescent white-silver armour with a
   faint prismatic sheen, woven silver filigree, moonstone inlays, pale lavender
   cloth, hair lifted as if by an unfelt wind.
cell 7 SPECIAL — a blood-cult executioner in blackened obsidian-dark plate with
   crimson enamel channels, a thorned iron gorget, a crimson wax seal medallion
   on the chest, an oxblood cloak, the face hidden by a featureless black mask.
cell 8 — a plain hooded recruit in undyed linen holding no weapon, for use as a
   spare.

All eight figures must be the same size, framed from the same distance, cropped
at the same point on the torso, lit identically, and facing the same way. Vary
the face, build, hair, skin tone and arm pose so that the eight read as eight
different people from eight different places.

BACKGROUND: one single flat solid muted pine-green colour, hex #33564A, edge to
edge, absolutely uniform, no gradient, no texture, no shading, no vignette.

LAYOUT: a strict grid of 4 columns by 2 rows, 8 equal cells filling the whole
image, each cell taller than it is wide. Exactly one figure per cell, centred,
leaving at least 10 percent empty background margin on the left, right and top
of the cell. No figure touches or crosses a cell boundary. Do NOT draw grid
lines, separators, card frames, labels, captions, names or numbers.
```

**(5) `panel_corner_oak.txt` — the UI panel set, generated as ONE corner**

This is the most important prompt in the document. Gemini cannot reliably produce a left-right and top-bottom symmetric frame. So generate a single top-left corner and build the frame by mirroring — symmetry becomes arithmetic, not luck.

```
SUBJECT: a single TOP-LEFT CORNER PIECE of an ornate medieval user-interface
panel frame, to be used as a nine-slice corner.

The corner ornament occupies the outer 60 percent of the tile: a thick band of
dark oiled oak framed in blackened iron, with an aged brass corner bracket held
by four hand-forged rivets, a small engraved scroll flourish curling inward, and
a shallow chiselled bevel catching the key light.

The inner 40 percent of the tile — the strip running down the right edge and the
strip running along the bottom edge — is a PLAIN, PERFECTLY STRAIGHT,
UNTEXTURED band of uniform width and uniform colour, with no ornament, no
rivets, no engraving and no variation of any kind, so that it can be tiled and
stretched. The extreme bottom-right region of the tile is empty background.

Draw ONLY the corner piece. Do NOT draw a complete rectangle. Do NOT close the
frame. Do NOT draw the other three corners. Do NOT draw anything inside the
frame.

BACKGROUND: one single flat solid near-black charcoal colour, hex #2A2A2E, edge
to edge, absolutely uniform, no gradient, no texture, no shading, no vignette.
```

Then build the perfectly symmetric frame locally, for free:

```bash
C="$ART/final/frames/panel_oak_corner.png"     # already matted, 1024x1024
magick "$C" \( "$C" -flop \) +append \
  \( \( "$C" -flip \) \( "$C" -flip -flop \) +append \) -append \
  -filter Lanczos -resize 512x512 "$GAME/art/ui/panels/panel_oak.png"
# NinePatchRect: patch_margin_left/right/top/bottom = 250 on the 512px texture
# (leaves a 12px stretchable centre band that is, by construction, plain).
```

The same command builds all seven tier frames from `frame_<tier>_corner.png` and all three button styleboxes from `btn_<class>_corner.png`.

**(6) `ui_icons.txt` — the currency / stat / empty-slot sheet**

```
SUBJECT: sixteen distinct medieval game UI ICONS, each a single object, centred,
upright, straight-on, drawn as a small solid emblem:
 1 a stack of three gold coins with a crown stamped on the top coin
 2 a cut brilliant blue diamond
 3 a lightning bolt forged from hammered brass
 4 two crossed steel swords
 5 a kite shield with a heavy iron boss
 6 a clenched armoured gauntlet fist
 7 a hanging heraldic banner on a crossbar
 8 a five-pointed star of pale gold
 9 a brass hourglass with running sand
10 a heavy iron padlock, closed
11 a kite shield wrapped in a protective ward
12 a thick plus sign cut from solid brass
13 an empty weapon rack: an iron hook with a faint engraved sword outline
14 an empty armour stand: a bare dark wooden torso mannequin
15 an empty stall: an iron ring with a faint engraved horseshoe
16 a rolled parchment scroll tied with red cord

Each icon must be a bold, closed, immediately recognisable silhouette that still
reads at 32 pixels. No icon may contain a thin line, a hairline or an open
outline.

BACKGROUND: one single flat solid dark charcoal-violet colour, hex #3B3B44,
edge to edge, absolutely uniform, no gradient, no texture, no shading, no
vignette.
```

---

## 5. Consistency control

### 5.1 How 21 swords stay one family

Four mechanisms, in decreasing order of effect:

1. **Sheet-level co-generation.** Twelve of the twenty-one swords are rendered in two images. Within one image the model resolves one lighting model, one paint density, one edge treatment for every cell. This is worth more than any amount of prompt engineering and is the primary reason for the batching plan.
2. **Rows = tiers.** The escalation is decided *inside* the sheet, so the legendary row is visibly richer than the epic row without any cross-image calibration.
3. **The two-panel reference on every call.** `hero_style_bible` (global) + `hero_sword` (family), composited with `+append`. Free, since cost depends only on `--size`.
4. **A frozen `STYLE_CORE`.** One file, appended verbatim, never edited after the bible is signed off.

### 5.2 Drift risk and the chain rule

The skill's warning is explicit: chains drift, keep them ≤2 deep. Enforce it as a hard rule:

- `hero_style_bible` is generated with **no** reference (depth 0).
- `hero_sword` is **cropped from** an approved sheet — cropping is not a generation, so it stays at depth 1.
- Every production sheet is depth 2.
- **Never** promote a cell from a depth-2 sheet into a new hero. If sword sheet A is approved and sheet B references a crop of A, that is still depth 2 (A's crop is data, not a generation step) — but if you then crop B to seed sheet C, you are at depth 3 and the family will start to slide. All sheets in a family reference the *same* `hero_<family>.png`, forever.

A second, quieter drift source: the model behind `gemini-3.1-flash-image-preview` can change under you. Mitigation — pin `GEMINI_MODEL` explicitly (the patch in §4.1), record the model string in `MANIFEST.md` next to every asset, and if a family needs extending months later, regenerate the *whole* family rather than appending to it.

### 5.3 The QA loop

**Stage 1 — the raw sheet, before slicing.** This is where 90% of rejections happen and it costs nothing to look. Check:
- cells are equal and axis-aligned; no object crosses a boundary (`grid_slice.py` would guillotine it)
- exactly one object per cell, no duplicates, no empties
- uniform scale, uniform camera angle, uniform key-light direction
- no drawn grid lines, labels, captions or numbers
- background is genuinely flat edge to edge (sample the four corners — `sample_bg_color` averages 2×2 blocks at all four corners, `rembg_matting.py:90`, so a vignette poisons the matte)

**Stage 2 — the matte.** Read `${BATCH}_magenta.png` (catches leftover background and punched-out interiors) and `${BATCH}_light.png` (catches dark fringing from the black-RGB transparent pixels). Also read the per-cell stdout: `Transparent: 0` means the matte failed outright.

**Stage 3 — the 64 px squint test.** Read `${BATCH}_64px.png`. If a sword is not distinguishable from an axe, or two cells look like the same object, the silhouette rule was violated.

**Stage 4 — the scale-variance check**, automated:

```bash
for f in "$ART/cut/$BATCH"/*.png; do
  magick "$f" -trim +repage -format "%[fx:w] %[fx:h] $(basename "$f")\n" info:
done | sort -n
```
Any cell whose trimmed width deviates by more than ±15% of the median is an outlier. In practice `-trim`/`-extent` in step 6 fixes moderate variance for free; only reject if an object is so small it becomes soft after being scaled up to 232 px.

### 5.4 The broken `--preview`, and the workaround

Two separate defects:

1. **Single mode raises `NameError`.** `rembg_matting.py:312` calls `make_qa_preview(out, output_path, bg_color)` but `bg_color` is only ever bound inside `remove_background()` (`:169`) — it is never returned and never assigned in `main()`. Passing `--preview` on a single image crashes *after* writing the output, so the matte survives but the QA image never appears.
2. **Batch mode ignores it entirely.** `process_batch()` (`:236`) takes no preview argument and `main()` never passes one, so `--preview` is silently a no-op for `--batch` — which is the mode we actually use.

**Workaround: do not use `--preview` at all.** The three `magick montage` commands in §4.3 are strictly better — they QA 16 assets in one image instead of one, they composite over two contrasting colours instead of one auto-chosen one, and they include the 64 px squint test that the tool never had. Delete the `_qa` concept from the workflow entirely.

If someone insists on the tool's own preview, the one-line fix is to have `remove_background` return `(out, bg_color)` and unpack at both call sites — but this is a third-party checkout and patching it creates a maintenance burden for zero gain over the montage.

### 5.5 Accept / reject rule

**ACCEPT a sheet when all of these hold:**
- every cell contains exactly one object, fully inside its cell
- key light comes from the upper left in every cell
- after `-trim`, no cell's bounding box deviates more than ±15% from the sheet median
- after matting, no cell shows visible background remnants on the magenta QA sheet, and none shows a dark halo on the light QA sheet
- at 64 px every object is distinguishable from all fifteen others
- the tier escalation is legible: row 4 is visibly richer than row 1

**REJECT and regenerate the whole sheet when:** any object crosses a cell boundary, grid lines or text were drawn, or ≥3 of 16 cells fail.

**Repair rather than reroll when 1–2 cells fail:** regenerate just those objects individually at **1K** (7c) using `--image` pointed at a *good neighbouring cell from the same sheet*, then drop the replacement into `cut/`. A 7c repair beats a 15c reroll that also throws away fourteen good assets — and this is the single biggest cost lever in the project.

**The no-seed consequence.** `asset_gen.py` exposes no seed parameter, so you cannot preview cheaply and then re-render the *same* image larger. Therefore: 1K drafts validate the **prompt**, never the **image**. Once the prompt is right, run the 4K final once and accept it — and then bias it toward the approved draft by passing the draft itself as `--image`. That is the closest thing to a seed this toolchain has, and it works well.

---

## 6. Godot import settings and the atlas plan

### 6.1 Per-class import settings

Enum values as written to the `[params]` block of a `.import` file: `compress/mode` — 0 Lossless, 1 Lossy, 2 VRAM Compressed, 3 VRAM Uncompressed, 4 Basis Universal. `detect_3d/compress_to` — 0 Disabled, 1 VRAM Compressed, 2 Basis Universal.

| Asset class | compress/mode | mipmaps/generate | process/fix_alpha_border | detect_3d/compress_to | CanvasItem texture_filter |
|---|---|---|---|---|---|
| Item icons, soldier cards, collect, upgrades, UI icons | **0 Lossless** | **true** | **true** | **0 Disabled** | Linear with Mipmaps |
| Tab bar icons (fixed size) | 0 Lossless | false | true | 0 Disabled | Linear |
| 9-slice frames, panels, buttons | 0 Lossless | **false** | **true** | 0 Disabled | Linear |
| Material tiles (seamless) | 0 Lossless | true | false | 0 Disabled | Linear with Mipmaps, `texture_repeat = Enabled` |
| Backgrounds, splash | **1 Lossy**, `lossy_quality = 0.85` | false | false | 0 Disabled | Linear |
| FX (rays, burst, particle dot) | 0 Lossless | true | true | 0 Disabled | Linear with Mipmaps |

The four settings that actually matter, and why:

- **Never VRAM Compressed.** The Godot docs are explicit that it "should be avoided for 2D as it exhibits noticeable artifacts, especially for lower-resolution textures". This is the single most common mobile-2D mistake.
- **`detect_3d/compress_to = 0`.** If a texture is ever touched by a 3D node Godot silently re-imports it as VRAM Compressed and your icons quietly degrade. Disable the detector project-wide for 2D.
- **`process/fix_alpha_border = true` on everything matted.** `recover_foreground()` writes **black RGB into fully transparent pixels** (`rembg_matting.py:135`). Without alpha-border fixing, linear filtering pulls that black into the icon edge and every asset gets a dark halo. This is not optional.
- **Mipmaps OFF for 9-slice.** Mipmaps blend across the patch margins and visibly break the seams where a NinePatchRect stitches. Mipmaps ON for icons, which do get scaled (256 authored → ~128 design px, plus scale-pop tweens).

Project settings: `display/window/size/viewport_width = 1080`, `viewport_height = 1920`, `stretch/mode = canvas_items`, `stretch/aspect = expand`, `rendering/textures/canvas_textures/default_texture_filter = Linear`, `rendering/renderer/rendering_method.mobile = mobile`. Design at 1080×1920; an iPhone 15/16 Pro lands at ~1.09–1.12× scale, so a 256 px authored icon shown at 128 design px renders at ~140 device px — comfortably supersampled.

Practical application: configure one icon in the Import dock, click **Set as Default for 'Texture2D'**, then select the `ui/panels`, `ui/frames`, `ui/buttons` and `bg` folders and re-import those with their overrides. Hand-writing `.import` files works but the `uid://` and the imported-path hash are generated by Godot, so do not template them from scratch — copy an existing one and let Godot regenerate on import.

**App icon:** 1024×1024, fully opaque (the App Store rejects alpha), no rounded corners (iOS masks it):
```bash
magick "$ART/final/brand/app_icon_raw.png" -background '#2A1B10' -alpha remove -alpha off \
  -filter Lanczos -resize 1024x1024 -strip "$GAME/art/brand/app_icon_1024.png"
```
Godot's iOS exporter generates the 120/152/167/180 px variants from it. For the launch screen, enable the storyboard option in the iOS export preset and point it at a centred wordmark on the panel colour — otherwise the Godot logo shows.

### 6.2 The atlas plan — and why no packer is needed

godogen ships `grid_slice.py` and no packer. **This does not matter, because the generation grid *is* the atlas grid.**

Every icon in this project is produced as one cell of an N×N sheet of equal square cells, all normalised to exactly 256×256 by the `-trim`/`-extent` step. Re-assembling them is a fixed-stride `montage`, not a rectangle-packing problem. No packer algorithm is ever required.

**v1: ship individual PNGs. No atlas.** Godot 4's 2D batcher breaks a batch on texture change, so a 24-item inventory grid costs ~24 extra draw calls — irrelevant on any A-series GPU. VRAM: 84 items × 256² × 4 B × 1.33 (mipmaps) ≈ 29 MB, plus ~20 MB for soldiers and UI icons ≈ **50 MB**. Acceptable. Verify on device with the `RENDER_TEXTURE_MEM_USED` performance monitor before doing anything more.

**v2, only if the device floor demands it:**

```bash
magick montage "$GAME/art/items/sword"/item_sword_{common,uncommon,rare,epic}_0*.png \
  -tile 4x4 -geometry 256x256+0+0 -background none \
  -define png:color-type=6 "$GAME/art/atlas/items_sword_a.png"
```

then emit one `AtlasTexture` `.tres` per cell (generated by a script, not by hand):

```
[gd_resource type="AtlasTexture" load_steps=2 format=3]
[ext_resource type="Texture2D" path="res://art/atlas/items_sword_a.png" id="1"]
[resource]
atlas = ExtResource("1")
region = Rect2(0, 0, 256, 256)
filter_clip = true
```

`filter_clip = true` prevents neighbouring cells bleeding in under linear filtering. Godot 4.7 added TextureRect support for drawing an AtlasTexture region as a repeating/nine-patch texture, so atlasing no longer blocks nine-slice usage — but keep frames, material tiles and backgrounds out of atlases regardless (patch margins, `texture_repeat`, and size respectively).

---

## 7. Fonts, audio, juice

### 7.1 Type system

Three faces, all SIL OFL 1.1, all on Google Fonts. Ship `OFL.txt` and list them on a credits screen.

| Role | Face | Weights | Notes |
|---|---|---|---|
| Display — screen titles, tab labels, tier names, button captions, all-caps only | **Cinzel** | SemiBold 600, Bold 700 | Roman-inscription capitals; reads "empire" without blackletter illegibility. Its lowercase are effectively small caps, which is why it is only ever used in caps — a constraint that conveniently prevents misuse. |
| UI body **and every number** | **Inter** | Regular 400, Medium 500, SemiBold 600, Bold 700 | The reason this is not a themed face: gold counters reach eight digits and must not jitter. Enable `tnum` (tabular figures) and `zero` (slashed zero) via **Advanced Import Settings → Metadata Overrides → OpenType Features**. Import Inter **twice**: once with `tnum=1` for numeric labels, once with `tnum=0` for prose. |
| Ceremonial accent — VICTORY / DEFEAT / LEVEL UP banners and the wordmark only | **Grenze Gotisch** | Bold 700 | Modernised blackletter, legible at display size only. Never below 48 px, never for a number, never for a full sentence. |

Font import settings: `antialiasing = Grayscale` (**not** LCD subpixel — the iPhone is OLED and subpixel AA produces colour fringing), `hinting = Light`, `subpixel_positioning = Auto`, **`msdf = OFF`**. The Godot docs explicitly list mobile as a case to avoid MSDF ("higher baseline rendering cost"), and our text sizes are small and fixed, which is MSDF's worst case. Pre-declare the exact sizes used (e.g. 22/26/32/44/64) so the rasterisation cache does not thrash on first paint.

Warmer alternative if Inter reads too corporate in review: **Alegreya Sans** (humanist, calligraphic, OFL). Swap only if it passes the same test — tabular lining figures in a 1,284,930 gold counter.

### 7.2 Audio

**Music — Lyria 3.** `asset_gen.py` has **no `music` subcommand** (subparsers are `image, video, glb, rig, retarget, resume`, `asset_gen.py:528-578`), so this needs a ~30-line sibling script. Model IDs are `lyria-3-clip-preview` (30 s clips — what we want) and `lyria-3-pro-preview` (full songs). Output is MP3, 48 kHz stereo, via the same `client.models.generate_content(model=..., contents="...")` shape the existing code already uses. **Verify pricing in the console before the first call** — it is not published in the model docs.

Five pieces: main/Family theme (calm, lute + strings, ~28 s loop), Collect work loop (light rhythmic, hand drums), Attack sting + battle bed (tense, low brass), Kingdom hall theme (ceremonial), and two one-shots (victory fanfare, defeat sting).

Lyria produces songs, not seamless loops. Convert with a tail-to-head crossfade and ship `.ogg` (Godot's Vorbis importer supports `loop` and `loop_offset`; MP3 looping is gapless-unfriendly):

```bash
ffmpeg -i theme.mp3 -filter_complex \
  "[0]atrim=0:28,asetpts=N/SR/TB[a];[0]atrim=28:30,asetpts=N/SR/TB[b];[b][a]acrossfade=d=2" \
  -c:a libvorbis -q:a 5 theme_loop.ogg
```

**SFX — cannot be generated.** Lyria is music-only; there is no sound-effect model in our toolchain and no Grok/video path. Source from CC0 / royalty-free libraries and record the licence per file in `art/CREDITS.md`: Kenney (CC0, has a usable UI/RPG pack), the Sonniss GDC audio bundles (royalty-free, commercial use permitted), freesound.org filtered to CC0 only, and Zapsplat (attribution tier — read the terms before shipping). Verify each licence at download time; do not trust a memory of it.

~25 cues: tab switch, button tap, collect success, coin burst, level up, item-drop stinger ×3 (reused across the seven tiers with pitch shift — `AudioStreamPlayer.pitch_scale` 0.85→1.30 across the ladder), equip, buy, shop refresh, soldier recruit reveal, attack swing, hit, victory, defeat, shield activate, error, energy-empty, upgrade purchase, diamond spend, timer tick.

### 7.3 Juice — all of it free

None of the following needs a new asset:

- Tier-tinted `GPUParticles2D` driven by one 32 px soft dot, `modulate` = tier `glow`.
- Number pop: `Tween` scale 1.0 → 1.25 → 1.0 with `TRANS_BACK`, plus a `Label` outline in the tier `deep` colour.
- Gold counter roll with `tnum` figures so digit widths never shift.
- Screen shake on attack resolve — a `Camera2D` offset noise curve.
- `CanvasItemMaterial` with `BLEND_MODE_ADD` for the legendary+ frame glow.
- The single rays sprite, slowly rotated, count and tint driven by tier.
- Tier reveal on soldier recruit: a `ColorRect` wipe in the tier colour, then the card, then the particle burst. The whole rarity dopamine loop is one shader and one particle system.

---

## 8. Phased asset roadmap

**The anti-blocking mechanism, built first, before any generation.** An `ArtRegistry` autoload maps `sprite_key → Texture2D`, and returns a procedural placeholder for any key with no file on disk. The placeholder is generated at runtime by an `@tool` script — a rounded rect in the tier's `base` colour with the type's initial letter — so every screen, every tier and every item type is renderable on day zero with zero art. **Rule: no scene, script or `.tscn` ever references an art path directly; everything goes through `ArtRegistry`.** Art then lands incrementally without a single code change, and a missing asset is a visible grey box rather than a crash.

| Phase | Assets | Cost (incl. drafts + 1 reroll) | Unblocks |
|---|---|---|---|
| **0 — grey-box** | none; `ArtRegistry` + procedural tier placeholders + Cinzel/Inter installed | **$0** | Every screen buildable. Code is never blocked again. |
| **1 — vertical slice** | style bible; sword A, armor A, horse A (common→epic); tier frame corners; UI icon sheet; tab icons; collect job icons; shared parchment background | **≈$2.90** | Family / Collect / Inventory / Shop feel like a real game for the first four tiers. This is the build you show anyone. |
| **2 — feature complete** | sword B, armor B, horse B (legendary/mystic/special); 3 soldier sheets; 2 upgrade sheets; kingdom + battle + hall backgrounds; 3 banners | **≈$3.80** | Soldiers, Attack, Kingdom, and the full seven-tier ladder. |
| **3 — store ready** | player portraits; material tiles; ornaments; button corners; FX sheet; app icon; wordmark; splash; store screenshots; music | **≈$1.90** + music | Submission. |

Store screenshots are composited from real gameplay captures plus text — no generation cost. The `app-store-screenshots` skill available in this environment scaffolds that page; use it rather than hand-building an exporter.

Deliberately deferred and never blocking: material tiles and ornaments (phase 1 panels use `StyleBoxFlat` with the tier colours), player portraits (a silhouette works), and every background (a flat `#1B1712` reads fine and is arguably better for list legibility).

---

## 9. Cost control

**Budget.** Working budget **$9.00** for images, hard cap **$15.00**. Audio cap **$10.00** pending Lyria price verification. Per-phase caps: $3.50 / $4.50 / $2.50. Breaching a phase cap stops generation and requires an explicit owner decision — it is a signal that a prompt is wrong, not that the budget is small.

**Per-batch approval gate.** No `asset_gen.py` call runs unless all three are true:
1. The prompt exists as a committed file at `art/prompts/<batch>.txt`.
2. A row is pre-added to `art/MANIFEST.md` with the batch name, grid, expected cell count and **expected cost in cents**.
3. The owner has said "go" for that specific batch.

Every call prints `{"ok": true, "path": ..., "cost_cents": N}` on stdout. Write the **actual** cents back into the manifest row immediately. The manifest follows the godogen convention (Name / Description / **Size** / Path / Cost) — the in-game Size column is what stops implementers scaling assets wrong.

**How to avoid paying twice for the same asset:**

- **Everything downstream of `raw/` is free.** Slicing, matting, trimming, resizing, mirroring, recolouring, montaging and atlasing are all local. **Never regenerate for a format, size, crop or colour change.**
- **`art/raw/` is immutable and append-only, and is committed.** Because there is no seed, a raw sheet is genuinely irreplaceable — a reroll produces a *different* image, not the same one bigger. `cells/`, `cut/` and `final/` are all reproducible from `raw/` by a `make` target and can be gitignored.
- **Repair, don't reroll.** 1–2 bad cells cost 7c to fix individually at 1K; a full reroll costs 15c *and* discards fourteen good assets. See §5.5.
- **Draft at 1K, final at 4K, once.** 1K passes debug the prompt. Never iterate at 4K.
- **Derive states in-engine.** Button pressed/disabled (`StyleBoxTexture.modulate_color`), tab active/inactive (`modulate`), all seven tier tints (one rays sprite + palette), all mipmaps and downscales. This removes ~25 generations from the naive plan.
- **Mirror, never generate the mirror.** Frame corners → four corners by `-flip`/`-flop`. Left/right facing → `flip_h` at runtime; the skill explicitly warns that direction prompts are unreliable, so paying for a mirror buys a coin flip.
- **Always pass `--image`.** Cost depends only on `--size` (`asset_gen.py:98-105`); the reference is free and materially reduces reroll rate.
- **Batch API (deferred).** Gemini's batch mode halves per-image cost, but `asset_gen.py` does not support it and wiring it up is not worth engineering time below ~$50 of spend. Revisit only if the project ever needs a second full art pass.

---

## 10. Critical files for implementation

- `/Users/yigitkarabulut/Developer/godogen-src/asset-gen/tools/asset_gen.py` — hardcoded `GEMINI_MODEL` at line 107, cost table at 110, unconditional `import xai_sdk` at 23, single-`--image` limit at 536, the six subcommands (no music) at 528–578.
- `/Users/yigitkarabulut/Developer/godogen-src/asset-gen/tools/rembg_matting.py` — the `--preview` `NameError` at line 312, the missing preview in `process_batch` at 236, and the black-RGB-in-transparent-pixels behaviour at 135 that forces `process/fix_alpha_border=true` in Godot.
- `/Users/yigitkarabulut/Developer/godogen-src/asset-gen/tools/grid_slice.py` — row-major fill order at line 27 and the integer-division cell math at 24, which together dictate the `--names` ordering and the "no object may cross a cell boundary" rule.
- `/Users/yigitkarabulut/Developer/godogen-src/asset-gen/rembg.md` — the background-colour doctrine and the threshold-tuning table referenced throughout §4.4.
- `/Users/yigitkarabulut/Developer/godogen-src/asset-gen/tools/requirements.txt` — the `onnxruntime-gpu` + `nvidia-cudnn-cu12` pins that must be replaced with plain `onnxruntime` on Apple Silicon.
- `/Users/yigitkarabulut/Developer/Emperors/art/prompts/_style_core.txt` (to be created) — the frozen style fragment that every future generation depends on.


---

## Key decisions

- **Art style: painterly semi-realistic mobile-RPG loot-icon art ("Illuminated Iron"), disciplined by a Clash-derived chunky-silhouette rule (no feature thinner than 1/40 of the cell width).**
  - Rejected: Clean stylized vector/flat; chunky hand-painted Clash style; pixel art.
  - Why: Painterly loot-icon art is the most densely represented style in image-model training data, so it reproduces reliably across 150+ assets, and its material vocabulary (filigree, enamel, opalescence, blackened steel) natively carries seven rarity tiers. Vector/flat cannot hold constant stroke width across a diffusion model and cannot sell 'legendary'. Pixel art is the worst case: Gemini produces fake pixel art with a non-integer grid, and the 1K minimum generation means downsampling turns it to mush. Clash style is the runner-up but reads as a toy, which undercuts a PvP game where losing costs 3% of your gold.
- **Resolve epic=purple / mystic=purple by keeping BOTH in the same violet hue (278 deg and 274 deg) and separating them on lightness: epic #9A3AD1 at L* 44.9, mystic #EDD6FF at L* 88.6.**
  - Rejected: Moving mystic to magenta/hot pink, or moving epic off purple.
  - Why: The owner said both are purple; this honours that literally rather than overruling it. A 44-point L* gap is a stronger, more legible escalation than a hue shift, and it lands mystic in the trading-card holo/secret-rare register which reads as above-legendary. Magenta wedged between legendary gold and special red is a hue regression that reads worse than the pale-iridescent solution.
- **Palette derived by constrained numerical search, not by eye: minimum pairwise CIE dE of 22.5 across normal vision plus Machado protanopia/deuteranopia/tritanopia simulation, with every tier holding at least 3.0:1 contrast on the #1B1712 panel.**
  - Rejected: Hand-picking the conventional gray/green/blue/purple/orange/pink/red MMO ladder.
  - Why: The naive conventional ladder measured at dE 5 for rare-vs-epic under deuteranopia -- indistinguishable at 24px. The constrained search found a set at dE 22 worst-case for zero cost in contrast. Each tier also gets a unique (gem count, ray count, frame value) tuple so all seven remain identifiable with no colour at all.
- **Batch every icon as a 4x4 grid sheet with ROWS = TIERS and COLUMNS = designs; 4 designs per (type, tier).**
  - Rejected: One sheet per (type, tier); one generation per icon; larger 6x6 or 8x8 sheets.
  - Why: Cost is per sheet, not per icon, so the binding constraint is layout reliability, not money -- and 4x4 is the reliability ceiling before Gemini starts merging cells and drawing grid lines. Rows-as-tiers means one denoising pass resolves all four escalation levels under one lighting model, so the escalation self-anchors and intra-family consistency comes free. 4 designs is exactly one row, which is what makes the scheme work.
- **Generate UI panel/button/tier frames as a SINGLE top-left corner, then build the symmetric 9-slice locally with ImageMagick -flip/-flop.**
  - Rejected: Prompting Gemini for a complete symmetric rectangular frame.
  - Why: Diffusion models cannot reliably produce left-right and top-bottom symmetric frames; the failure is subtle enough to survive review and obvious enough to ruin a UI. Mirroring makes symmetry arithmetic instead of luck, costs one generation instead of many rerolls, and the prompt can additionally demand that the inner edge bands be plain -- which is exactly what a 9-slice needs to stretch cleanly.
- **Ship individual PNGs with no texture packer in v1; atlas only if on-device profiling demands it.**
  - Rejected: Integrating Free Texture Packer or TexturePacker, or building a rectangle-packing step.
  - Why: godogen ships a slicer and no packer, but no packer is needed: every icon is produced as an equal cell of an NxN grid and normalised to exactly 256x256, so re-assembly is a fixed-stride montage, not a packing problem. At ~50MB total VRAM and ~24 extra draw calls for a full inventory grid, atlasing buys nothing on an A-series GPU. The montage + AtlasTexture .tres path stays documented as a v2 lever.
- **Always pass --image (the two-panel style-bible + family-hero composite) on every single generation.**
  - Rejected: Text-to-image for most assets, reserving image-to-image for variants; or patching --image to accept multiple references.
  - Why: Reading asset_gen.py confirms cost is a pure function of --size -- the reference is literally free -- so there is no reason to ever run a bare text-to-image after the bible exists. The CLI only wires one reference despite Gemini 3.1 Flash accepting up to 10 object + 4 character + 3 style refs, so compositing two refs side-by-side with `magick +append` gets both the global style and the family lock with zero code change and zero risk.
- **Abandon rembg's --preview entirely and QA with three magick montage contact sheets (over magenta, over light grey, and at 64px).**
  - Rejected: Patching rembg_matting.py to fix the NameError at line 312 and to thread preview through process_batch.
  - Why: There are two defects, not one: single mode crashes on an unbound bg_color, and batch mode -- the mode we actually use -- ignores --preview silently because process_batch never takes the argument. The montage replacement is strictly better anyway: it QAs 16 assets in one image, checks two contrasting backgrounds instead of one, and adds a 64px squint test the tool never had. Patching a third-party checkout would buy nothing and create maintenance debt.
- **Fonts: Cinzel (display, caps only) + Inter with tnum/zero enabled (all body and every number) + Grenze Gotisch (banners only). MSDF OFF.**
  - Rejected: A single themed medieval face for everything; MSDF font rendering for crispness at any size.
  - Why: Eight-digit gold counters need tabular figures or the digits jitter on every tick, which no medieval display face provides well. Cinzel's lowercase are effectively small caps, so the caps-only constraint enforces itself. Godot's own docs list mobile as a case to avoid MSDF because of its higher baseline cost, and our text is small and fixed-size, which is MSDF's worst case.
- **Build an ArtRegistry autoload with procedural tier placeholders in phase 0, before any art is generated, and forbid direct art paths anywhere in code.**
  - Rejected: Generating a minimal placeholder art set first, or letting scenes reference art paths directly.
  - Why: This is the mechanism that guarantees art never blocks code: every screen is renderable on day zero, art lands incrementally with zero code changes, and a missing asset shows a labelled grey box rather than crashing. It also means the phased roadmap can be reordered freely without touching a single scene.

## Risks flagged

- Grid layout failure is the single biggest schedule risk. Gemini 3.1 Flash may draw grid lines, merge adjacent cells, duplicate objects, or let a sword tip cross a cell boundary -- and grid_slice.py guillotines anything that crosses. Mitigation: the explicit LAYOUT_GRID fragment demanding 12% per-cell margins, a hard 4x4 ceiling, inspecting the raw sheet before slicing, and the GEMINI_MODEL env patch so gemini-3-pro-image can be swapped in for stubborn sheets.
- There is no seed parameter in asset_gen.py, so an image can never be reproduced. A 'retry' is always a different picture, and the cheap-draft-then-upscale workflow is impossible. art/raw/ is therefore genuinely irreplaceable and must be committed and backed up; losing it means regenerating and re-approving an entire family.
- GEMINI_MODEL is hardcoded to the alias 'gemini-3.1-flash-image-preview' while current Google docs list the GA id as 'gemini-3.1-flash-image'. If the preview alias is retired mid-project, every call fails until the constant is patched -- and worse, if the alias is silently repointed to a newer model, the style drifts across the library with no error.
- rembg runs CPU-only on this machine (no NVIDIA GPU), so BiRefNet takes roughly 3-8s per 1024px cell -- 30-45 minutes for a full 226-cell matting pass. The shipped requirements.txt also pins onnxruntime-gpu and nvidia-cudnn-cu12, neither of which has an Apple Silicon wheel, so a naive `pip install -r requirements.txt` fails outright.
- asset_gen.py re-encodes Gemini output through PIL with the comment 'Gemini may return JPEG data', so JPEG ringing around the subject may be baked in before matting ever runs, producing fringe that no threshold tuning fully removes. Mitigation is high chroma distance in the background choice plus --bg-thresh 0.03, but some batches may still need a reroll for this alone.
- recover_foreground() writes black RGB into fully transparent pixels. If a single texture is imported without process/fix_alpha_border=true, it gets a dark halo under linear filtering -- and because the default import preset is set once in the editor, a folder imported before the preset was configured will silently carry the defect.
- Only ios.zip export templates are present for 4.7.2.stable, so there is no web or desktop build for reviewing art. Every visual QA pass runs in the editor or on a physical iPhone, which slows the feedback loop and makes it easy to ship something that looks wrong at real device DPI.
- Lyria pricing is not published in the model documentation and asset_gen.py has no music subcommand at all, so the audio budget is an estimate against an unwritten script. Music spend could materially exceed the $10 reserve.
- SFX cannot be generated by any tool we have -- Lyria is music-only and there is no Grok or video path. Every one of ~25 cues comes from a third-party CC0/royalty-free library, so licence compliance is a manual, per-file obligation recorded in CREDITS.md; a single mis-licensed file is a store-submission risk.
- Gemini-generated images carry an invisible SynthID watermark and are governed by the current Google AI Studio terms. Commercial-use terms for a paid mobile game should be re-read before submission rather than assumed from the free-tier defaults.
- The protanopia worst case (uncommon green vs legendary gold, dE 25) is near the practical floor for green-vs-gold and cannot be improved further without abandoning the owner's stated green and yellow. The non-colour cues (gem count, ray count, tier name in text) carry that pair, so if the frame ornamentation is ever cut for scope, that distinction degrades first.

## Questions raised for the owner

- Do you accept mystic as a pale iridescent lavender-white (#EDD6FF, same 274-degree violet hue as epic but 44 L* lighter), or do you want mystic moved off purple entirely to magenta? This decides all seven frame designs, the entire tint system and the mystic soldier/item prompts -- changing it later means regenerating the mystic row of every sheet.
- Is 'special' above the power ladder or beside it? I have designed it as beside -- obsidian frame, zero gems, no rays, downward embers -- to signal 'event/promo, not strictly stronger'. If special is meant to be the true top tier, its whole visual language and its frame need to invert.
- Can soldiers roll the special tier, or is special items-only? This changes whether the three soldier sheets need a special cell (currently they do, cell 7) and whether the recruit reveal animation needs a seventh outcome.
- Does the player have a visible avatar portrait on the Family tab, and is there any appearance or gender choice? I budgeted 4 portraits on one 2K sheet; a full customisation system would need a different, much larger plan.
- In the Soldiers list, does each soldier show a full waist-up card portrait or just a small bust in a ~96px list row? I have specified waist-up cards at 4K, which costs 45c and gives real presence. If they only ever appear at 96px, that drops to one 2K sheet and 10c -- but you lose the collectible-card feel that makes tier reveals land.
- Do items have individual names and lore ('Ashfang, Blade of the Ninth Siege') or generic ones ('Legendary Sword')? With individual names, 4 designs per tier starts to feel thin because players will notice two differently-named items sharing art.
- What is the device floor -- iPhone SE 2nd gen, iPhone 11, or newer? This decides whether the ~50MB no-atlas texture plan holds or whether phase 2 must include the montage + AtlasTexture step.
- Are there monetisation art requirements for v1 -- diamond bundle tiles, starter pack hero images, a battle-pass banner? Each pack needs its own hero image and none of that is in the current 33-generation plan.
- Do you approve the $9.00 working budget with a $15.00 hard cap for images, plus a $10.00 reserve for Lyria music pending price verification?
- Is there ever a light/parchment UI theme, or is the dark #1B1712 panel the only surface? The tier text tokens are tuned for the dark panel; a light theme needs a second contrast pass and roughly doubles the UI chrome work.

---

# Adversarial review — verdict: needs-revision


## BLOCKER (2)

### The nine-slice frame/button plan (§4.5 prompt 5, §6.1) produces textures that cannot be drawn at the sizes the UI actually needs. The corner prompt puts the ornament in the outer 60% of a 1024 px tile; after the 2×2 mirror and the resize to 512 px the doc sets patch_margin_left/right/top/bottom = 250, leaving a 12 px stretchable band. It then says the same command builds all seven tier frames and all three button styleboxes.

**Breaks because:** A NinePatchRect/StyleBoxTexture with 250 px margins on each side needs a control at least 500 px in that axis. Godot does not error — it shrinks and non-uniformly scales the border to fit (godotengine/godot#52136, #34725), so the ornament is visibly crushed. In a 1080×1920 portrait UI a primary button is roughly 320×96 and an inventory tier frame roughly 140×140; both are far below 500 px, so every button and every item frame — the two most-repeated elements in the game — renders wrong. The margin is also larger than needed: with the ornament at the outer 60% of the corner, its extent in the assembled 512 px texture is only 154 px, so the extra 96 px of margin buys nothing and destroys 192 px of stretchable band.

**Fix:** Three changes. (1) Change the prompt: ornament occupies the outer 25% of the corner tile, not 60%; replace the ambiguous sentence 'the strip running down the right edge and the strip running along the bottom edge' (a model will read that as a vertical band at the right edge) with: 'A plain, perfectly straight, uniform-width, uniform-colour horizontal bar runs from the corner ornament rightward to the right edge of the tile, occupying only the top 25 percent of the tile height. A matching plain vertical bar runs from the corner ornament downward to the bottom edge, occupying only the left 25 percent of the tile width. Everything else in the tile is background.' (2) Ship three assemblies from the same corner, not one: panel_oak_512.png with patch_margin 96; frame_<tier>_192.png with patch_margin 40 (min drawable 80 px); btn_<class>_128.png with patch_margin 28 (min drawable 56 px). All are free local resizes of the same mirrored 2048 px master. (3) Add a hard rule to §6: patch_margin <= floor(min_control_dimension / 2) - 1, checked per StyleBox. If an ornament must overhang a small button, use StyleBoxTexture.expand_margin_* rather than a larger texture_margin.

### The matting QA gate keys on a stdout line that never appears in the mode the pipeline uses. §5.3 Stage 2 says 'read the per-cell stdout: Transparent: 0 means the matte failed outright', and §4.4 says 'if Transparent: 0 appears in the rembg output, force -m trust'.

**Breaks because:** rembg_matting.py prints Opaque / Transparent / Semi-transparent only in single-image mode (lines 306–308 of main()). process_batch() (lines 236–258) never prints them. §4.3 step 4 runs --batch. So the only automated failure detector in the whole matting stage silently never fires, and a fully-failed matte (alpha 255 everywhere, i.e. the background still attached) passes the gate. This compounds with the second, real defect the doc did correctly find: --preview is a silent no-op in batch mode, so there is no fallback signal either.

**Fix:** Replace the Transparent: 0 check with the two lines process_batch DOES emit, both from remove_background(): 'Regime: color' means BiRefNet's mask failed (detect_regime returned color because mask coverage was <5%), and 'Mask: fg=N (X%)' below ~5% or above ~70% is the warning band. Add an explicit post-hoc audit to §4.3 as step 4b, which is what actually catches a no-op matte:

for f in "$ART/cut/$BATCH"/*.png; do
  a=$(magick "$f" -alpha extract -format '%[fx:mean]' info:)
  o=$(magick "$f" -alpha extract -format '%[fx:mean>0.99?1:0]' info:)
  printf '%s %s\n' "$a" "$(basename "$f")"
done | sort -rn

Mean alpha above ~0.85 on an icon cell means nothing was removed; mean alpha below ~0.02 means the subject was removed. Both are hard rejects. Also grep the batch stdout: `... | grep -E 'Regime: color|Mask: fg=[0-9]+ \(([0-4]\.|[7-9][0-9]\.)' `.


## MAJOR (7)

### The cost-control system in §9 records the wrong number the moment you take §4.1's own advice to switch to gemini-3-pro-image for 'the hard sheets'. §9 mandates writing 'the actual cents' from the tool's stdout into MANIFEST.md.

**Breaks because:** cmd_image() computes cost = GEMINI_COSTS[size] (asset_gen.py:74, 189) from --size alone and is completely blind to the model. Verified against Google's pricing page: gemini-3.1-flash-image is $0.045/$0.067/$0.101/$0.151 for 0.5K/1K/2K/4K, which does match the tool's 5/7/10/15c. But gemini-3-pro-image is $0.134 for 1K AND 2K and $0.24 for 4K. Under the doc's own patch the tool would still print cost_cents: 15 for a Pro 4K sheet that actually cost 24c — a 60% undercount at 4K and 34% at 2K. The $9.00 working budget and the per-phase caps ($3.50/$4.50/$2.50) are all enforced against a number that becomes fiction under the documented escalation path.

**Fix:** Extend the §4.1 patch beyond one line (note the constant is at asset_gen.py:72, not 107):

import os
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-image")
GEMINI_COSTS = {"512": 5, "1K": 7, "2K": 10, "4K": 15}
PRO_COSTS    = {"1K": 14, "2K": 14, "4K": 24}

and in cmd_image: cost = (PRO_COSTS if "3-pro-image" in GEMINI_MODEL else GEMINI_COSTS)[size]. Add two rules to §9: (a) MANIFEST.md gains a Model column and the cost row is only trusted if the model string matches; (b) because Pro charges the same $0.134 for 1K and 2K, never generate Pro at 1K — always 2K. Also drop the GA model id to 'gemini-3.1-flash-image' as the default: Google's model page lists that as the stable id with no -preview alias, which removes the doc's own 'the preview alias may be retired' risk.

### §7.2 specifies the Lyria integration against an API surface that does not exist for Lyria: 'via the same client.models.generate_content(model=..., contents="...") shape the existing code already uses', with output 'MP3, 48 kHz stereo'.

**Breaks because:** Lyria 3 is served by the Interactions API, not generate_content. Verified shape is interaction = client.interactions.create(model="lyria-3-clip-preview", input="..."), with audio at interaction.output_audio and bytes via base64.b64decode(generated_audio.data). Output is 44.1 kHz stereo, not 48 kHz. A '~30-line sibling script' written to the documented shape will fail on the first call with an unsupported-model or missing-method error, and client.interactions requires a google-genai version newer than whatever asset_gen.py currently pins.

**Fix:** Rewrite §7.2's script spec to:

import base64, sys
from google import genai
client = genai.Client()
it = client.interactions.create(model="lyria-3-clip-preview", input=PROMPT)
open(out, "wb").write(base64.b64decode(it.output_audio.data))

Pin google-genai to a version that exposes client.interactions and record it in MANIFEST.md alongside the model string. Correct the sample rate to 44.1 kHz throughout, and change the ffmpeg loop command to be explicit about it (-ar 44100). Also evaluate lyria-3.5, which the same docs list as supporting WAV output and multi-minute prompt-controlled duration — WAV removes the MP3→Ogg generation loss the crossfade step currently bakes in, and the longer duration removes the need to stitch a 28 s loop at all. Keep the honest note that pricing is unpublished and must be read in the console before the first call.

### The soldier portrait prompts bake weapons and armour into the artwork, which directly contradicts the equipment system in the brief (each soldier has exactly 3 slots: weapon / armor / horse).

**Breaks because:** §4.5 prompt 4 specifies 'arms and weapons kept entirely inside the cell', then per cell: 'holding a chipped iron shortsword', 'a notched falchion', 'a trident and a small buckler', 'fluted dark silver plate with violet enamel channels', and so on. A common-tier Peasant equipped with a mystic sword and epic plate will forever render as a bare-chested pit fighter holding a chipped iron shortsword. The entire point of a 7-tier, 3-slot equipment economy is that gear is visible; here the soldier's tier permanently overrides everything the player equips, so equipping produces a stat change with no visual feedback. This is the single loop that drives shop purchases and inventory engagement.

**Fix:** Reframe soldier art as identity, not loadout. Change the subject line to: 'eight distinct head-and-shoulders portraits, cropped at the collarbone, no weapon, no shield, no horse, no torso plate visible'. Express tier through face, scarring, hair, skin, expression, headgear/helm, collar/gorget and the rim treatment only — e.g. common = bare-headed and dirt-streaked; uncommon = leather coif; rare = blued steel sallet with the visor raised; epic = dark silver helm with violet plume; legendary = laurel circlet over gold-chased helm; mystic = hoodless, hair lifted, opalescent circlet; special = featureless black mask. Then the Soldiers/Inventory row renders portrait + three 96 px equipped-item slots drawn from the existing 84 item icons, which is the art you already paid for. This also removes the 4×2 grid's hardest constraint (keeping outstretched arms and long weapons inside a cell) and therefore lowers the reroll rate on the three most expensive sheets in the plan.

### The 203-asset inventory contains no art for the monetisation system, even though Phase 3 is labelled 'store ready' and diamonds are the only revenue source in the brief (IAP for energy refills, protection, shop rerolls, premium packs).

**Breaks because:** The full UI-icon sheet has exactly one diamond icon and one generic plus. There is no diamond-pack art (an IAP store is normally 5–6 escalating SKUs whose containers are the entire conversion visual), no starter/premium bundle art, no energy-refill or protection-purchase art, no shop-reroll token, no 'best value' ribbon and no purchase-confirmation banner. Shipping an idle/PvP game to the App Store with a placeholder IAP screen is the highest-cost art omission possible, because that screen is where the money is made and it is the one screen a reviewer and every paying player sees.

**Fix:** Add one 2K 1:1 4×4 sheet on the #3B3B44 charcoal-violet background (10c, plus a 7c 1K draft = 17c, which fits inside the existing $9.00 working budget and does not breach the $15 hard cap). Sixteen cells: (1) small leather diamond pouch, (2) brass-bound diamond casket, (3) oak diamond chest, (4) iron-banded diamond strongbox, (5) overflowing stone diamond vault, (6) starter bundle crate with a rope-tied scroll, (7) premium bundle chest with a crown clasp, (8) energy flask of glowing amber liquid, (9) wax-sealed protection charter, (10) shop-reroll token: a two-faced brass coin, (11) VIP crown on a cushion, (12) hourglass with the sand already fallen (timer skip), (13) a blank banner ribbon for 'BEST VALUE' (text drawn in Cinzel at runtime, never generated), (14) gold-pile purchase icon, (15) receipt/ledger page, (16) spare. Add the sheet as batch 34 in §3.4 and to Phase 3 in §8. Derive the purchase-confirmed banner from the existing victory banner via modulate — free.

### Asynchronous PvP and the Kingdom clan system are given four player portraits total ('lord/lady × 2 variants') and no per-kingdom identity art.

**Breaks because:** The Attack tab is a scrollable list of real opponents and the Kingdom system has a reputation leaderboard. With 4 portraits, every opponent in the list is one of four faces and every kingdom on the leaderboard is unbranded. In a Shakes & Fidget–style game the opponent list is the screen the player scans most in the PvP loop, and rival identity is what makes a revenge attack feel personal. Four faces makes that list read as filler and makes the leaderboard unreadable at a glance.

**Fix:** Generate procedural heraldry instead of more portraits. One 2K 1:1 4×4 sheet (10c) of sixteen heraldic charges rendered as flat white-silver emblems on #3B3B44: lion rampant, eagle displayed, boar, wolf, stag, tower, key, anchor, rose, fleur-de-lis, crown, crossed swords, chevron, cross patty, mullet/star, hand. Plus reuse the existing kite-shield UI icon as the blank. At runtime: shield blank tinted field colour + one charge tinted metal colour + optionally a division overlay (per pale / per fess / per bend / quarterly), all three keys derived from hash(player_id) or hash(kingdom_id). 16 charges × 4 divisions × ~10 tincture pairs gives 640+ visually distinct crests for 10c, and the identical asset serves opponent avatars, kingdom crests, the leaderboard and the kingdom-hall banner. Keep the 4 player portraits for the player's own Family tab only.

### §2.2 introduces a second surface colour, parchment #E8D9B5, 'for the light surfaces inside panels', but every tier text/base colour is validated only against the dark panel #1B1712.

**Breaks because:** Measured contrast of each tier's text colour against #E8D9B5: mystic 1.04:1, uncommon 1.17:1, legendary 1.43:1, rare 1.80:1, epic 2.70:1, special 2.72:1, common 2.80:1. Every one fails 4.5:1 and none even reaches the 3:1 large-text floor. The deep ramp is no better on parchment (uncommon 1.63:1, mystic 2.15:1, rare 3.30:1, legendary 3.82:1). Since the plan generates a parchment material tile, a shared parchment-interior background and describes the panel interiors as light surfaces, the moment any tier-coloured label lands on parchment it is invisible — and mystic, the second-rarest tier, is the worst offender at 1.04:1, effectively white on cream.

**Fix:** Pick one. (A) Simplest and recommended: make it a hard rule that tier colour never appears on a light surface — parchment areas use #1B1712 for all text and carry tier only as a small saturated chip or the frame ornament, both of which are shape-and-value cues that already work. (B) If tier-coloured text on parchment is required, add a fifth PackedColorArray 'text_on_light' to the TierPalette .tres, validated at >=4.5:1 on #E8D9B5: common #536073 (4.57), uncommon #42672F (4.68), rare #326298 (4.50), epic #9023CF (4.52), legendary #7E5800 (4.58), mystic #675B70 (4.54), special #C20714 (4.51). Note the cost of option B: mystic collapses to a grey-violet #675B70 and loses the pale-iridescent identity that the whole epic/mystic resolution rests on — which is itself the argument for option A. Either way, state the chosen rule explicitly in §2.2 so it cannot be violated by a later screen.

### The -trim in §4.3 step 6 and §5.3 Stage 4 will silently no-op on matted cells, so the optical-size normalisation and the automated scale-variance check both stop working.

**Breaks because:** rembg_matting.py:207 does alpha[alpha < 0.01] = 0.0, so alpha values between 0.01 and roughly 0.02 survive as 3–5/255 across the cell wherever the colour matte produced a weak lower bound. ImageMagick's -trim without -fuzz treats any pixel that differs from the corner pixel as content, so a single 3/255 stray anywhere near the cell edge pins the bounding box at the full cell. Then 'magick mogrify -trim +repage -resize 232x232 -extent 256x256' degenerates into a plain downscale with no size equalisation — exactly the step the doc says 'is what makes an inventory grid look designed rather than generated' — and §5.3's median-bounding-box outlier detector reports every cell as identical, so the check can never fail.

**Fix:** Add -fuzz to every -trim in the document. §4.3 step 6 becomes: magick mogrify -path "$ART/final/items/sword" -fuzz 2% -trim +repage -filter Lanczos -resize 232x232 -background none -gravity center -extent 256x256 -strip -define png:color-type=6 "$ART/cut/$BATCH/*.png". §5.3 Stage 4 becomes: magick "$f" -fuzz 2% -trim +repage -format "..." info:. Optionally pre-clean the alpha in the same pass with -channel A -level 2%,100% +channel, which hard-zeroes the sub-threshold residue rather than relying on fuzz. (Note: the quoted glob in mogrify is fine — verified that ImageMagick 7.1.2 on this machine expands quoted globs internally.)


## MINOR (8)

### Two batches violate §4.4's own stated background rule ('L* differs by >=30 from every subject mid-tone'), and the worst offender is a row the doc invented for itself.

**Breaks because:** Measured: sword background #6B4A2F is L* 34.5. Sheet B row 4 is specified as 'four plain undecorated arming swords in dull grey iron' — a dull grey iron mid-tone sits near L* 52, a gap of 17.6, and being achromatic it also fails the companion '>=120 degrees of hue separation' criterion, which is undefined for zero chroma. Running the tool's own compute_alpha_color() on that pair gives an alpha lower bound of 0.37, meaning the matte for that entire row is mask-driven with no colour support — the exact regime the doc identifies as fringe-prone. The special/obsidian row on the same background gives 0.80 and a dL* of 28.2, also below the rule. On the frames sheet, the obsidian special frame on #2A2A2E gives 0.55.

**Fix:** Two changes. (1) Delete the grey-iron spare row entirely — see the next finding, which replaces it with additional common-tier designs on the sheet-A background where the value gap is correct. (2) Split the obsidian assets off the dark backgrounds: generate the special-tier tier-frame corner as its own 1K single call (7c) on a light neutral #B9B2A6 (L* 73, dL* 67 against obsidian), and if the special sword/armor/horse rows on sheet B show fringing, repair those 4 cells individually at 1K on #B9B2A6 rather than rerolling the sheet — which is exactly the repair-don't-reroll lever §5.5 already establishes. Also add the achromatic case to the §4.4 rule text: 'if the subject is achromatic, the hue criterion does not apply and the L* gap must be >=40.'

### Twelve generated cells are burned on 'spares' while the tier that the player actually sees most often gets only 4 designs, and the spares then leak into the shipped game.

**Breaks because:** The shop rerolls every five minutes with tier-weighted rolls, so common and uncommon dominate what a new player sees; 4 common sword designs will visibly repeat inside the first session, which is precisely the 'wall of clones' read §3.2 says the 4-design choice exists to prevent. Meanwhile row 4 of each B sheet already generates 'four plain undecorated arming swords in dull grey iron, no gems, no gold, no engraving' — which is a literal description of common-tier art, labelled 'spare' and then thrown away. Separately, §4.3 step 6 mogrifies "$ART/cut/$BATCH/*.png" (all 16 cells, spares included) into final/, and step 7 copies item_sword_*.png into res:// — so item_sword_spare_01..04.png ship into the game.

**Fix:** Rename row 4 on each B sheet from spare to common_05..08 and move it onto the sheet-A background instead (regenerate row 4 as part of sheet A's overflow, or simply accept them on the B background since the value gap issue above disappears once they are explicitly common-tier art rendered dull and dark). Common goes from 4 to 8 designs per type at zero additional cost. Then add a free multiplier in ArtRegistry: derive flip_h and one of three scale steps (0.94 / 1.00 / 1.06) from hash(item_id), which turns 8 designs into roughly 48 apparent variants for no art. Do the same for the 3 soldier spare cells (make them extra common/uncommon peasant faces). Finally, make step 7's copy explicit rather than globbed, so nothing unintended reaches res://.

### Mipmaps combined with rembg's black-RGB transparent pixels will still produce dark halos even with process/fix_alpha_border = true, which §6.1 calls 'non-negotiable' and treats as a complete fix.

**Breaks because:** The doc correctly identifies that recover_foreground() writes fg[alpha < 0.02] = 0.0 (rembg_matting.py:134, not 135) so fully transparent pixels carry black RGB. But Godot's fix_alpha_border only dilates nearby opaque colour into transparent pixels over a small radius on mip 0; the mip chain is then generated by averaging RGB across the base image including whatever black remains outside that radius. By the doc's own scale arithmetic a 256 px icon is displayed at ~140 device px, so the sampler blends mip 0 and mip 1 and picks up some of it. This is a partial fix presented as a complete one.

**Fix:** Pick one. (A) Cheapest: turn mipmaps off for icons and author closer to display size. The doc already establishes the display size is ~140 device px, so authoring at 192 px instead of 256 px removes the mip chain entirely, removes the halo class of bug, and cuts the stated 29 MB item-icon VRAM figure by about 44%. Keep texture_filter = Linear. (B) If mipmaps stay on, add an explicit alpha-bleed pass to §4.3 step 6 that replaces transparent-pixel RGB with a mid-tone instead of black:

magick "$f" \( +clone -alpha off -fill '#7A6E5E' -colorize 100% \) -compose DstOver -composite \
       \( "$f" -alpha extract \) -alpha off -compose CopyOpacity -composite "$out"

Run it before -trim. Either way, keep fix_alpha_border = true; it is necessary but not sufficient.

### The §0 ground-truth table states as verified fact that gemini-3.1-flash-image supports only 1:1, 3:2, 2:3, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9 and instructs 'Never use the strip ratios — they will error or silently fall back'.

**Breaks because:** Google's model page for gemini-3.1-flash-image lists 'New 1:4, 4:1, 1:8 and 8:1 aspect ratios' as a headline capability of this exact model. The doc has the fact backwards. Direct harm is low because nothing in the plan uses a strip ratio, but the table is presented as the evidentiary foundation for the whole document ('these facts change the plan'), and the false prohibition forecloses a genuinely useful cheap option.

**Fix:** Correct the row to: gemini-3.1-flash-image supports 1:1, 3:2, 2:3, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9 and additionally 1:4, 4:1, 1:8, 8:1. Then use them where they help: the 4 material tiles and 4 button corners currently occupy two separate 2K 2×2 sheets (20c) and could be one 2K 8:1 1×8 strip; the 6 tab icons at 2K 3:2 3×2 fit a 2K 8:1 more naturally at the same 10c with better per-icon pixel budget. Note that grid_slice.py divides with // so a 1×8 strip slices exactly. Keep the 4×4 reliability ceiling for anything with more than 8 cells.

### Internal numeric inconsistencies that indicate sections were not reconciled after the design changed.

**Breaks because:** (a) §5.1 is titled 'How 21 swords stay one family' and says 'Twelve of the twenty-one swords are rendered in two images', but §3.2 and the key-decisions list both specify 4 designs × 7 tiers = 28 swords, and all 28 are rendered in exactly two images — 21 is the leftover count from a 3-designs-per-tier version, and 'twelve of' is wrong under either count. (b) §2.2's parenthetical 'Unconstrained the optimum is 22.2 in the constrained space and 19.9 unconstrained-for-contrast — the contrast floor cost nothing' is self-contradictory: relaxing a constraint cannot lower an optimum, so an unconstrained optimum of 19.9 below a constrained 22.2 is impossible. (c) Per-phase caps of $3.50/$4.50/$2.50 sum to $10.50 against a stated $9.00 working budget.

**Fix:** (a) Rewrite the §5.1 heading and first mechanism as: 'How 28 swords stay one family — all 28 are rendered in just two images (sheet A: common→epic, sheet B: legendary/mystic/special/common-extra).' (b) Delete the parenthetical entirely; the verified headline (min pairwise dE = 22.5, binding pair deutan rare/epic at 22.5) stands on its own and I reproduced it exactly, so the confused footnote only damages credibility. (c) State explicitly that the per-phase caps are per-phase stop-gates that sum above the working budget on purpose and that the $9.00 working budget is the aggregate ceiling, or lower them to $3.00/$3.75/$2.25.

### Most line-number citations into asset_gen.py in §0 and §10 are wrong by about 35 lines, including the one the reader is told to edit.

**Breaks because:** Verified against the file: GEMINI_MODEL is at line 72 (doc says 107); GEMINI_COSTS at 74 (doc says 110); GEMINI_ASPECT_RATIOS at 75–78 (doc says 113–116); types.Part.from_bytes at 122 (doc says 129–133); the 'Gemini may return JPEG data' comment at 141 (doc says 150); the 'cost at asset_gen.py:98-105' citation actually points at _image_data_uri. In rembg_matting.py, fg[alpha < 0.02] = 0.0 is at 134, not 135. §4.1 instructs '# asset_gen.py:107 — replace', and line 107 is 'def _generate_gemini(args, output, cost):' — following the instruction literally corrupts the function. (Correct as cited: xai_sdk import at 23, --image at 536, subparsers 528–579, the bg_color NameError at 312, process_batch at 236, sample_bg_color at 90, _has_nvidia_gpu at 38, tripo3d lazy key at 24.)

**Fix:** Renumber the §0 and §10 citations against the actual file, and reword the §4.1 patch instruction to be anchor-based rather than line-based: 'replace the GEMINI_MODEL constant (module scope, immediately above GEMINI_SIZES)'. Anchor-based references survive upstream edits to a third-party checkout; line numbers do not, which is the same reason the doc correctly refuses to patch rembg_matting.py.

### The style bible is itself a 3×3 grid and is fed as the left panel of the reference board on every 4×4 production call, which actively fights the doc's own #1 risk.

**Breaks because:** §1.4 specifies the bible as 'One 2K 1:1 3×3 sheet containing one exemplar of every material family'. §5.1 mechanism 3 then attaches it, composited with a family hero, to every production generation. The doc's own top-ranked risk is 'Gemini may draw grid lines, merge adjacent cells, duplicate objects'. Showing the model a 3×3 grid of objects on a flat background while the prompt demands a 4×4 grid of objects on a flat background is the single strongest way to induce grid-count confusion — and the mitigation offered ('Do NOT copy the composition or the layout of the reference') is asking the model to ignore the most structurally salient property of the image it was given. The board is also 2048×1024, a 2:1 aspect not in the supported output list, which adds a second layout pressure against the requested 1:1.

**Fix:** Two changes, both free. (1) Generate the bible as a non-gridded material study: nine objects clustered naturally on a single plate — 'a still-life arrangement of nine objects overlapping on a plain surface, no grid, no cells, no separators' — so it carries brushwork, lighting, palette and material treatment without carrying a layout. (2) Before compositing the board, crop the bible down to a 1–2 object detail crop; the left panel only needs to define rendering, not inventory. Then make the board square-ish (two 512×512 panels side by side = 1024×512, or better, stack the two panels vertically into 512×1024 so the board's aspect never argues with a 1:1 request). Separately: since you are already patching asset_gen.py for GEMINI_MODEL, change --image to action="append" and append one types.Part.from_bytes per reference — a two-line change that uses the API as designed (gemini-3.1-flash-image accepts up to 10 object + 4 character + 3 style refs, which the doc states correctly) and removes the two-panel board and its 'do not copy the layout' instruction entirely.

### §9 mandates that art/raw/ is 'committed' and 'immutable and append-only' without addressing repository size, and the Emperors working directory is currently empty and is not a git repository at all.

**Breaks because:** The plan generates roughly 12 sheets at 4K plus 14 at 2K plus rerolls, all re-encoded as full-quality PNG by asset_gen.py (_generate_gemini saves with img.save(output, format="PNG")). A 4096×4096 painterly PNG realistically runs 15–40 MB, putting art/raw/ at roughly 0.4–0.8 GB before rerolls. Committed as ordinary git blobs that permanently bloats every clone, and individual files approaching 50 MB trip GitHub's large-file warning. Since the doc correctly identifies raw/ as genuinely irreplaceable (no seed parameter, so a reroll is a different picture), losing or being unable to push it is a real project risk, not a hygiene issue.

**Fix:** Add to §9: initialise the repo with Git LFS before the first paid call, and track art/raw/**.png in .gitattributes. Gitignore cells/, cut/, final/ and qa/ as the doc already proposes, since all four are reproducible from raw/ by a make target. Add a second, off-repo backup of art/raw/ (the doc's own no-seed risk makes a single copy insufficient), and record the sha256 of every raw sheet in MANIFEST.md so corruption is detectable. If LFS is undesirable, store raw/ outside the repo and commit only the manifest plus 1K WebP-lossless proxies for review.


## Missing coverage

- IAP / diamond store art — the only revenue system in the brief (diamond packs, energy refills, protection purchase, shop rerolls, premium packs) has one diamond icon and nothing else across 203 assets, while Phase 3 is labelled 'store ready'. Fix costed at 17c in the confirmed problems.
- Per-player and per-kingdom identity art — asynchronous PvP against real players and a kingdom reputation leaderboard are served by 4 total player portraits and no crest system. Fix costed at 10c via a procedural heraldry sheet.
- Tier colours validated for the light (parchment) surface the palette itself introduces — all seven tier text colours measure between 1.04:1 and 2.80:1 on #E8D9B5.
- Collect milestone badges — the brief specifies per-job milestones at 25 / 50 / 100 collects granting +5% / +10% / +15%. Each Collect row needs a visible progress and milestone state; nothing in the 203-asset inventory covers it. Cheapest fix: three notch/pip glyphs added to the existing 16-cell UI icon sheet by replacing spare cells, plus a runtime progress arc drawn with draw_arc — zero extra generations.
- Offline-return / 'welcome back' art — the hybrid idle model accrues tax income offline up to ~8 hours, and the return-to-game reward screen is the single highest-retention moment in an idle game. The plan has victory / defeat / protected banners but no offline-earnings banner or treasury art. Derive from the existing victory banner plus the gold-pile icon at zero cost, but it must be named in the inventory or it will not exist.
- A stated rule that sprite_key is cosmetic-only — with 4 (or 8) designs per (type, tier), players will read design variance as stat variance. The doc stores sprite_key in the DB but never states that it is chosen by a deterministic hash of item id, stable for the item's lifetime, and carries no gameplay meaning. That belongs next to the ArtRegistry contract in §8.
- Verification that the 'show tier numerals' accessibility toggle introduced in §2.3 has an implementation path — no I–VII numeral asset appears in the inventory. It can be Cinzel text (Cinzel has good Roman numerals), but §7.1 restricts Cinzel to all-caps display use and never mentions this, so the toggle is currently unimplementable as written.
- Actual billed cost verification — §9's entire gate rests on the cost_cents value printed by asset_gen.py, which is a hardcoded local estimate keyed only on --size. There is no step that reconciles the manifest against the real Google AI Studio billing page at the end of each phase. Add 'read the console billing total and reconcile against MANIFEST.md' as the phase exit criterion.

## Corrected recommendations

## What is genuinely sound — do not touch it

I verified these and they hold up:

- **The palette is correct to the digit.** I recomputed every value independently: all seven L\* figures, all seven contrast ratios against `#1B1712`, and the ΔE tables under Machado protan/deutan/tritan simulation at severity 1.0. Every number matches, including the global minimum **ΔE 22.5 at deutan rare/epic** and the per-model closest pairs (protan uncommon/legendary 25, tritan uncommon/rare 24–25, normal common/rare 35). The `text` ramp does clear 4.5:1 on the dark panel for all seven (worst is common at 4.56). The epic/mystic lightness-split resolution is a good call and the grayscale `(gems, rays, frame value)` tuple really is unique across all seven. Freeze this section.
- **The ImageMagick mirror command in §4.5(5) is correct** — the nested-paren `+append` / `-append` scoping produces the intended 2048×2048. Only the *margins* derived from it are wrong.
- **`mogrify` with a quoted glob works** — verified on ImageMagick 7.1.2-29 on this machine; it expands globs internally. No change needed.
- **The Godot 4.7 AtlasTexture-in-TextureRect claim is real** (godotengine/godot#113808, shipped in 4.7).
- **All Godot import-option names and enum values are correct**: `compress/mode` 0–4, `detect_3d/compress_to` 0–2, `process/fix_alpha_border`, `mipmaps/generate`, `rendering/textures/canvas_textures/default_texture_filter`, `NinePatchRect.patch_margin_*`, `StyleBoxTexture.modulate_color`, `AtlasTexture.filter_clip`, `AudioStreamOggVorbis.loop_offset`.
- **The device-scale arithmetic is right**: 1179/1080 = 1.092, 1206/1080 = 1.117 under `canvas_items` + `expand`.
- **The reference-image limits are right** (10 object + 4 character + 3 style for gemini-3.1-flash-image), **4K is genuinely supported**, and **the 5/7/10/15c cost table matches Google's real published prices** ($0.045 / $0.067 / $0.101 / $0.151) — so the $3.75 base and $8.60 realistic budget are sound *for this model*.
- **The 33-call / 226-cell / 203-shipped arithmetic all reconciles**, and the `--names` ordering in §4.3 correctly matches `grid_slice.py`'s row-major `divmod(i, cols)`.
- **The ffmpeg tail-to-head crossfade is a correct loop construction** (`acrossfade` output = 2 + 28 − 2 = 28 s, seam removed).
- **Repair-don't-reroll, derive-states-in-engine, mirror-never-generate, always-pass-`--image`, and the ArtRegistry-first phase 0** are all correct and are the strongest parts of the plan.

---

## Corrected §4.5(5): the frame corner

Replace the geometry paragraph. New target: **ornament in the outer 25%**, not 60%.

```
The corner ornament occupies only the outer 25 percent of the tile: a band of
dark oiled oak framed in blackened iron, an aged brass corner bracket held by
four hand-forged rivets, a small engraved scroll flourish curling inward.

A plain, perfectly straight, uniform-width, uniform-colour HORIZONTAL bar runs
from the corner ornament rightward to the right edge of the tile, occupying only
the top 25 percent of the tile height, with no ornament, rivets or engraving.
A matching plain VERTICAL bar runs from the corner ornament downward to the
bottom edge of the tile, occupying only the left 25 percent of the tile width.
Everything else in the tile — the entire lower-right region — is background.

Draw ONLY the corner piece. Do NOT draw a complete rectangle. Do NOT close the
frame. Do NOT draw the other three corners.

BACKGROUND: one single flat solid near-black charcoal colour, hex #2A2A2E, ...
```

Then ship **three** assemblies from the one mirrored 2048 master, not one:

| Use | Texture size | `patch_margin_*` | Min drawable control |
|---|---:|---:|---:|
| Screen / list panel | 512 | 96 | 192 px |
| Item tier frame | 192 | 40 | 80 px |
| Button stylebox | 128 | 28 | 56 px |

Rule to add to §6: `patch_margin ≤ floor(min_control_dimension / 2) - 1`. If an ornament genuinely has to overhang a small control, use `StyleBoxTexture.expand_margin_*` rather than a bigger texture margin.

---

## Corrected §4.1 patch (constant is at line **72**, not 107)

```python
import os
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.1-flash-image")  # GA id, no -preview
GEMINI_COSTS = {"512": 5, "1K": 7, "2K": 10, "4K": 15}
PRO_COSTS    = {"1K": 14, "2K": 14, "4K": 24}   # gemini-3-pro-image, verified pricing
```

and in `cmd_image`:

```python
cost = (PRO_COSTS if "3-pro-image" in GEMINI_MODEL else GEMINI_COSTS)[size]
```

While you are in the file, make `--image` repeatable — two lines, and it deletes the entire two-panel-board workaround:

```python
p_img.add_argument("--image", default=None, action="append",
                   help="Reference image (repeatable, up to 14)")
```

```python
for ref in (args.image or []):
    contents.append(types.Part.from_bytes(data=Path(ref).read_bytes(),
                                          mime_type=_mime_for_image(Path(ref))))
```

Budget consequences: Pro charges the same for 1K and 2K, so **never run Pro at 1K**. Add a `Model` column to `MANIFEST.md` and reconcile against the AI Studio billing page at each phase exit.

---

## Corrected §7.2 Lyria script shape

```python
import base64
from google import genai
client = genai.Client()
it = client.interactions.create(model="lyria-3-clip-preview", input=PROMPT)   # 30 s
open(out, "wb").write(base64.b64decode(it.output_audio.data))
```

Output is **44.1 kHz** stereo MP3, not 48 kHz — fix the `ffmpeg` step to `-ar 44100`. Evaluate `lyria-3.5`, which supports WAV output and prompt-controlled multi-minute duration; WAV removes the MP3→Ogg generation loss, and the longer duration may remove the crossfade step entirely. Pin the `google-genai` version that exposes `client.interactions` and record it in the manifest.

---

## Corrected soldier sheet subject line

```
SUBJECT: eight distinct HEAD-AND-SHOULDERS portraits of medieval gladiator
fighters, cropped at the collarbone, facing slightly to the viewer's left.
NO weapon, NO shield, NO horse, NO torso plate, NO hands visible.
Tier is expressed ONLY through face, scarring, hair, skin, expression,
headgear and collar/gorget.
```

Per-cell: common bare-headed and dirt-streaked → uncommon leather coif → rare blued-steel sallet, visor raised → epic dark silver helm with violet plume → legendary laurel circlet over gold-chased helm → mystic hoodless, hair lifted, opalescent circlet → special featureless black mask. Then render portrait + three equipped-item slots side by side using the 84 item icons you already paid for. This also removes the hardest layout constraint from the three most expensive sheets, which should lower the reroll rate.

---

## Two batches to add (27c total, fits inside the existing $9.00)

**Batch 34 — IAP store, 2K 1:1 4×4 on `#3B3B44` (10c + 7c draft).** Five escalating diamond containers (pouch → casket → chest → strongbox → vault), starter crate, premium chest, energy flask, wax-sealed protection charter, reroll token, VIP crown, spent hourglass, blank ribbon (text drawn in Cinzel at runtime), gold-pile, ledger page, spare.

**Batch 35 — heraldry, 2K 1:1 4×4 on `#3B3B44` (10c).** Sixteen flat white-silver charges: lion rampant, eagle displayed, boar, wolf, stag, tower, key, anchor, rose, fleur-de-lis, crown, crossed swords, chevron, cross patty, mullet, hand. Tint field + charge + division at runtime from `hash(player_id)` / `hash(kingdom_id)` → 640+ unique crests serving opponent avatars, kingdom crests, the leaderboard and the hall banner.

Revised budget: $8.60 + $0.27 = **$8.87** against the $9.00 working budget, $15.00 hard cap unchanged.

---

## Corrected pipeline steps (§4.3)

Step 4b, replacing the non-existent `Transparent: 0` check:

```bash
for f in "$ART/cut/$BATCH"/*.png; do
  printf '%s %s\n' "$(magick "$f" -alpha extract -format '%[fx:mean]' info:)" "$(basename "$f")"
done | sort -rn
# mean alpha > 0.85  -> nothing was removed (hard reject)
# mean alpha < 0.02  -> subject was removed  (hard reject)
```
plus `grep -E 'Regime: color' "$LOG"` on the batch output.

Step 6, with fuzz and (if mipmaps stay on) the alpha bleed:

```bash
magick mogrify -path "$ART/final/items/sword" \
  -fuzz 2% -trim +repage -filter Lanczos -resize 232x232 \
  -background none -gravity center -extent 256x256 \
  -strip -define png:color-type=6 "$ART/cut/$BATCH/*.png"
```

Step 5, ordered montage so QA cells map to sheet cells (the shell glob sorts alphabetically and will not match row order):

```bash
magick montage $(tr ',' '\n' <<< "$NAMES" | sed "s|^|$ART/cut/$BATCH/|;s|$|.png|") \
  -tile 4x4 -geometry 256x256+8+8 -background magenta -flatten "$ART/qa/${BATCH}_magenta.png"
```

---

## Palette addendum

Add to §2.2, immediately after the table:

> **Tier colour never appears on the parchment surface `#E8D9B5`.** Measured contrast of the `text` ramp on parchment is 1.04:1 (mystic) to 2.80:1 (common) — all seven fail. Parchment areas use `#1B1712` text and carry tier only as a saturated chip plus the frame ornament. If a future screen requires tier-coloured type on parchment, it uses a separate `text_on_light` array: common `#536073`, uncommon `#42672F`, rare `#326298`, epic `#9023CF`, legendary `#7E5800`, mystic `#675B70`, special `#C20714` — all ≥4.5:1 on parchment, none valid on the dark panel.

Also note the units slip: "epic is hue 278°, mystic is hue 274°" are **HSL** hues quoted inside a paragraph otherwise written in CIE L\*. In CIE LCh they are 316.3° and 311.9°. The conclusion (same violet family, 4° apart) is unchanged, but say which space you mean. And `legendary #F2AA02` is amber/gold at HSL 42°, not the "yellow" the owner specified — that is the right call visually, but flag it as a deliberate deviation in the same paragraph where you claim to honour the owner's purple literally, or the inconsistency will be pointed at.

---

## Recommended sequencing change

Move the **`GEMINI_MODEL` + `--image append` + `PRO_COSTS` patch** and the **frame-margin geometry decision** to Phase 0, before the style bible. Both are free, both are irreversible-if-wrong downstream (the bible's grid layout and the corner's ornament fraction are baked into `raw/`, which has no seed and therefore cannot be regenerated identically). Everything else in the phased roadmap can stay as written.