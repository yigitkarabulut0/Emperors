# Slicing guide — how every pixel of the new client comes out of `art/reference/`

The owner's rule: **every icon, painting, button, frame and portrait is cut directly from the
reference images. Nothing is redrawn, regenerated or "approximated".** The only things rendered
by the game itself are live values (numbers, names, timers) and the text that changes with them.

## Coordinates

- Reference images are 941 × 1672. The game runs at exactly that base resolution, so a source
  pixel rect is also a layout rect. **Never scale a crop** unless the guide says so.
- The left rail (x 0..160) is shared chrome and is already done (`art/slices/chrome.json`). A
  screen owns everything at **x ≥ 155**. The gutter between rail and content is painted ground.
- The three currency pills (y 27..87) are shared chrome. Each screen's header crop must
  **inpaint** the baked pills it contains (see `inpaint`) so the shared pills can be drawn over.
  The rects to inpaint are that screen's own pill rects, grown by 3 px on every side.

## Tools (run with `art/.venv/bin/python`)

- `art/tools/grid.py <img> x y w h scale out [step label]` — rulered zoom; read coordinates off it.
  Use scale 3 for measuring; every rect you record must have been read from a grid zoom.
- `art/tools/probe.py <img> row|col <index> [lo hi]` — colour runs along one line, for exact edges.
- `scripts/slice-reference.py <manifest>... --refdir art/reference --out client/assets --sheet qa.png`
  — cuts the crops. Modes and options are documented at the top of the file:
  `rect` (opaque), `darkkey` (alpha against the dark ground — for icons and glyphs sitting on the
  navy ground; NOT for dark-interior plates), `erase` (per-row fill from clean columns — removes
  baked dynamic text), `inpaint` (content-aware fill), `soften` (replace a region with a very
  low-frequency version of itself), `mask` chamfer/polygon (alpha outside), `scale`.

## What to cut, and how

| Thing | Mode | Rule |
|---|---|---|
| Header painting with its baked title/subtitle | `rect` | Full width x 155..941. Inpaint the pill rects. Title text stays baked (it is static). |
| Panel / card frame that will hold live text | `rect` + `erase` | Erase every dynamic text region with `erase` (sample clean columns on the same rows, inside the same plate). Keep static labels ("MASTERY BONUSES", "EQUIPPED GEAR", "WEAPON") baked. |
| Button with a fixed label (COLLECT, BUY, EQUIP, SELL, ATTACK, HUNT, DISMISS, RECRUIT, UNLOCK, DONATE, UPGRADE, EQUIP BEST, AUTO EQUIP, MAX LEVEL, REROLL MARKET) | `rect` | Cut with its label. Include the bevel and 1 px of shadow. If it has chamfered corners, add `mask`. One crop per distinct button; identical buttons share one crop. |
| Icon on the navy ground (stat icons, currency glyphs, quest icons, small marks) | `darkkey` | Crop with ~4 px of clean ground around it. |
| Icon inside a plate whose ground is not the navy (e.g. a coin inside a gold-bordered pill) | `rect` | Cut the whole pill instead, erase its number. |
| Painting inside a tier frame (item art, job art, soldier portrait, rival portrait, crest) | `rect` | Cut the painting **and its frame together** when the frame is part of the look; erase any baked level/number badge text inside it (badge plate stays). Also cut each **tier frame** once, empty, if the frame colour changes by tier (inventory has all seven). |
| Progress bars | `rect` | Cut the empty track and, separately, a full-width fill sample. |
| Tab strips (REVENGE/TARGETS, REALM/LORDS/WORKS/RANKS), filter chips | `rect` | One crop per chip state seen (active, inactive), with its label baked when static. |
| Footer ornament lines ("COMPLETE TASKS TO…", "MORE UPGRADES AHEAD") | `rect` | Static, keep. |

Text colours, sizes and positions are recorded in the layout file, not painted.

## Output

1. `art/slices/<screen>.json` — the crop manifest. Asset names: `<screen>/<element>` for
   screen-private pieces; `items/<slug>` for item paintings; `portraits/<slug>` for people;
   `icons/<slug>` for small glyphs that other screens could reuse. If a slug could collide with
   another screen's (e.g. `lionheart_armor` appears in inventory and shop), suffix it with the
   screen name.
2. `art/slices/<screen>.layout.json` — where everything sits and how live text is set:

```json
{
  "screen": "collect",
  "source": "collect.png",
  "ground": "#0b151f",
  "elements": [
    {"id": "header", "kind": "image", "asset": "collect/header", "rect": [155, 0, 786, 300]},
    {"id": "quest_card", "kind": "template", "rect": [178, 335, 240, 160],
     "instances": [[178, 335], [428, 335], [678, 335]],
     "parts": [
       {"id": "frame", "kind": "image", "asset": "collect/quest_card", "rect": [0, 0, 240, 160]},
       {"id": "icon",  "kind": "image", "asset": "icons/quest_scroll", "rect": [18, 22, 60, 60]},
       {"id": "title", "kind": "text", "rect": [90, 20, 140, 60], "font": "body", "size": 24,
        "weight": 600, "color": "#F2EADB", "align": "left", "valign": "center", "sample": "Collect\n20 times"},
       {"id": "bar",   "kind": "image", "asset": "collect/quest_bar", "rect": [20, 92, 200, 22]},
       {"id": "bar_fill", "kind": "image", "asset": "collect/quest_bar_fill", "rect": [22, 94, 196, 18], "fill": "left"},
       {"id": "progress", "kind": "text", "rect": [20, 92, 200, 22], "font": "body", "size": 18, "color": "#E9E1D1", "align": "center", "sample": "0 / 20"},
       {"id": "reward", "kind": "text", "rect": [70, 122, 120, 30], "font": "body", "size": 22, "weight": 600, "color": "#F7E6B0", "align": "left", "sample": "+100 XP"}
     ]},
    {"id": "job_row", "kind": "template", "rect": [172, 515, 760, 155], "pitch": 168, "instances": [[172, 515]],
     "parts": [ ... ]}
  ]
}
```

- Every rect in `parts` is **relative to the template's origin**. Top-level rects are absolute.
- `kind`: `image` (an asset), `text` (live text), `template` (a repeated component with parts),
  `button` (an asset that is tappable; add `"action": "collect"`), `scroll` (a region that scrolls,
  with `"content": [...]`).
- Text: `font` is `title` (Cinzel — used for anything in caps with flared serifs) or `body` (the
  transitional serif used for sentences and numbers). `size` is the cap height matched by eye
  against the grid zoom (record the pixel height of a capital letter × 1.4). `color` is sampled from
  the middle of a stroke. Give a `sample` with the reference's own text so the fit can be checked.
- Record **every** text you erased as a `text` part at the same rect. Record every baked static
  text you kept simply as part of its image.

## Verification — mandatory

After slicing, rebuild the screen from your assets at their layout rects (PIL: paste each asset,
draw each text sample in a serif font at the recorded size/colour) and save it next to a copy of
the reference as one side-by-side image. **Look at it.** Anything that is not the same — a frame
that is cut short, a halo, a leftover digit, a shadow that got keyed out — is a defect: fix the
manifest and cut again. Do not report until the side-by-side shows no defects you can see. Save
the side-by-side as `art/qa/<screen>_sbs.png` and the contact sheet as `art/qa/<screen>_sheet.png`.

## Do not

- Do not scale any crop except where the guide says (none for content).
- Do not use `darkkey` on anything with a dark interior (plates, portraits, armour) — it will
  make the darks transparent. Use `rect` and, if it needs corners, `mask`.
- Do not "clean up" a crop by hand or regenerate anything.
- Do not run git. Do not edit files outside `art/slices/`, `art/qa/`, `client/assets/`.
- Do not change `scripts/slice-reference.py`; if a crop truly needs a capability it lacks, note it
  in your report with the exact rect and what is needed.
- Use `soften`, not `inpaint`, to lift a whole painted object off its field. Telea repairs
  scratches: asked to fill a hole the size of half a card it drags the edges inward, and the shop
  cards shipped with diagonal smears behind every item because of it. `soften` reduces the region
  (plus a margin of its surroundings) to a handful of pixels and scales it back, which keeps the
  field's colour and the shape of its light and cannot keep anything with an edge. `erase` has the
  same trap at a smaller scale: it fills each row from a narrow column sample, so anything in
  those columns is smeared across the whole row.
