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

## New paintings: paint big, draw down

The paintings added after the first seven (`docs/art/PAINTING_BRIEFS.md`) are made larger than
the game draws them, because a generator paints an object at 220 px with a care it does not give
one at 72, and detail survives being drawn down where it never survives being drawn up.

- **A new painting enters `art/reference/` only through `scripts/normalize-reference.py`**
  (`--kind screen` 9:16 → 941×1672, `map` 3:4 → 776×1030, `boss` 16:10 → 771×482). It scales to
  cover with Lanczos, trims evenly, flattens alpha against the navy ground, refuses a painting whose
  shape is more than 2 % off, and refuses to write over a reference a manifest already cuts from.
  After it, a source pixel is a layout unit again, and everything above holds.
- **Object sheets** (the briefs' S-pages — `rewards_sheet.png`, `ui_bits_sheet.png`,
  `diamond_packs_large.png`, `frames_cosmetic_a|b.png`, `plates_sheet.png` and the like: objects
  painted large on a flat ground, normalised as `screen` like everything 9:16) are the one place a
  crop is scaled: cut the object at its painted size, then `scale` it to the size the brief's
  "Kesim notu" names — always down, never up, and to whole pixels the layout uses.
  A sheet crop that would need scaling up is a painting to ask for again.
- A screen painting's crops are **not** scaled: normalising already put them on the grid.

## Tools (run with `art/.venv/bin/python`)

- `art/tools/grid.py <img> x y w h scale out [step label]` — rulered zoom; read coordinates off it.
  Use scale 3 for measuring; every rect you record must have been read from a grid zoom.
- `art/tools/probe.py <img> row|col <index> [lo hi]` — colour runs along one line, for exact edges.
- `scripts/slice-reference.py <manifest>... --refdir art/reference --out client/assets --sheet qa.png`
  — cuts the crops. Modes and options are documented at the top of the file:
  `rect` (opaque), `darkkey` (alpha against the dark ground — for icons and glyphs sitting on the
  navy ground; NOT for dark-interior plates), `erase` (per-row fill from clean columns — removes
  baked dynamic text; `fade_top` blends its first rows out of the painting, so a band lifted out of
  a scene falls into shadow instead of cutting it — start the rect that many rows above the object,
  where the painting is still the scene), `inpaint` (content-aware fill), `soften` (replace a region
  with a very low-frequency version of itself), `mask` chamfer/polygon (alpha outside), `scale`.

## What to cut, and how

| Thing | Mode | Rule |
|---|---|---|
| Header painting with its baked title/subtitle | `rect` | Full width x 155..941. Inpaint the pill rects. Title text stays baked (it is static). |
| Panel / card frame that will hold live text | `rect` + `erase` | Erase every dynamic text region with `erase` (sample clean columns on the same rows, inside the same plate). Keep static labels ("MASTERY BONUSES", "EQUIPPED GEAR", "WEAPON") baked. |
| Button with a fixed label (COLLECT, BUY, EQUIP, SELL, ATTACK, HUNT, DISMISS, RECRUIT, UNLOCK, DONATE, UPGRADE, EQUIP BEST, AUTO EQUIP, MAX LEVEL, REROLL MARKET) | `rect` | Cut with its label. Include the bevel and 1 px of shadow. If it has chamfered corners, add `mask`. One crop per distinct button; identical buttons share one crop. |
| Icon on the navy ground (stat icons, currency glyphs, quest icons, small marks) | `darkkey` | Crop with ~4 px of clean ground around it. |
| Icon inside a plate whose ground is not the navy (e.g. a coin inside a gold-bordered pill) | `rect` | Cut the whole pill instead, erase its number. |
| Painting inside a tier frame (item art, job art, soldier portrait, rival portrait, crest) | `rect` | Cut the painting **and its frame together** when the frame is part of the look; erase any baked level/number badge text inside it (badge plate stays). Also cut each **tier frame** once, empty, if the frame colour changes by tier (inventory has all seven). |
| Progress bars | `rect` | Cut the empty track and, separately, a fill that is SHORTER than the shortest width it will be drawn at, carrying both of its rounded caps -- `patch` the right cap beside the left one when the painting has them a bar apart. A crop of the whole painted fill is *squashed* at every figure under full, and the squash shows as a seam where the nine-patch's cap meets the middle (boss.json's `hp_fill`: 505 painted, 674 of track). |
| Tab strips (REVENGE/TARGETS, REALM/LORDS/WORKS/RANKS), filter chips | `rect` | One crop per chip state seen (active, inactive), with its label baked when static. |
| Footer ornament lines ("COMPLETE TASKS TO…", "MORE UPGRADES AHEAD") | `rect` | Static, keep. |

Text colours, sizes and positions are recorded in the layout file, not painted.

### A painting that shows one of its objects in TWO states

The talents painting lights the top two medallions of every column and leaves
the rest plain; the expedition painting lights the second of its four cards.
That is the object's whole state set, and both halves are the painting's own
ink, so **cut both and always draw one of them.** Never leave the painting's own
choice showing: a lord's tree lights what the lord has bought, and the page must
be able to light the fifth medallion and leave the first plain.

Two traps:

- **A state's crop carries its neighbours' state too.** A lit ring's crop
  reaches over its pip row, which the painting draws with two ranks bought;
  `patch` those back to the unlit gem of the same row before cutting, or every
  lit talent hands the lord two ranks it does not have.
- **Part of a state may be inside the page and not liftable.** A lit medallion
  also has a glow BEHIND its icon, and the icon is different on all fifteen. Use
  `shade` on the page to level those interiors to an unlit one's tone, so the
  state is carried by the parts that can be drawn (`talents/ring_lit_*`) and
  every medallion starts equal. Measure the tone to level to -- the annulus just
  inside the ring, where no icon reaches -- and never eyeball it.

`shade` takes `{"rect": [x,y,w,h], "saturation": s, "gain": g, "feather": px}`
and levels the rect's inscribed ellipse, feathered into what is round it. It was
added for exactly this and is the only way to take light OUT of a page.

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

**A painting's mock-up shows a plate EMPTY; the game puts words in it.** Two of
this pass's defects were of that shape. `war.png`'s routed row stamps ROUTED
across the name plate -- which the artist could do, their mock plate being blank
-- and with a real name under it neither the name nor the Might beside it could
be read. `throne.png`'s two plates under the crowned ring are 225 and 275 units
wide; the layout recorded boxes 49 and 29 units wider, so a name fitted to the
box overhung the gold caps. When you record a text rect over a painted plate,
measure the PLATE's own field, and then set the longest real string in it and
look.

**One object, three pictures.** A state's picture may not carry its parts in the
same place as the others: `campaign/plate_gold`, `plate_shut` and `plate_lit`
hold their name boards at 28, 15 and 29 with widths 99, 115 and 105. A layout
records one rect, so the screen that swaps the picture must place the words with
it -- measure each state's field, not just the one the layout could hold.

**An `alt` record is a promise, and an unused one is an unchecked one.** The
Attack notice's `alt` (the blank plate and the type its baked words were set in)
sat in the manifest for months with nothing drawing from it, and every number in
it was wrong: cap 18 where the painting's capitals stand 15, size 25 where the
layout's own rule (`size = cap x 1.4`) makes it 21, and a text rect at the
ERASE's left edge rather than the ink's, 13 units left of where the painted
sentence starts. Measure an `alt` against the painting the day something draws
from it, exactly as you would a rect you were cutting fresh.

`art/qa/render_layout.py` builds that side-by-side for a screen whose layout is
its painting's own. It cannot for **a stack** — the Royal Store, the Kingdom,
the Court — where a section with nothing to show is left out and the rest close
up, so a section's y on the screen is not its y in the painting (and the store's
layout is cut from two paintings at once, which `render_layout.py` cannot open at
all). For those, capture the running game with `--scroll` and use
`art/qa/section_sbs.py <painting> x,y,w,h <capture> <out>`: it finds the section
in the capture, lays the painting's own above the game's below at 2×, and prints
the mean pixel difference. **That number is the check** — a section drawn from
its own crops sits near 1; a drift, a halo or a wrong nine-patch pushes it up.

## Do not

- Do not scale any crop except where the guide says (none for content; object sheets down only,
  see "paint big, draw down").
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


## One painting for a screen that already exists

Two of the pack's paintings design a screen the game already has, built from
other references. Cutting one of those is not "using the reference" -- it is
replacing a screen that was measured off ten paintings with a mock-up of it:

- `campaign.png` draws the Attack tab's CAMPAIGN with the tab's header, its
  pills, a two-arrow chapter pager and a foot bar. The built screen is cut from
  `campaign_map_01..10.png` and `campaign_nodes_sheet.png`, and its twelve nodes
  stand on the road's own pixels (`scripts/campaign-road.py` seams the road out
  of each map), with a five-chapter strip and three star chests the painting
  does not have.
- `ui_bits_sheet.png` is the shared kit's master sheet. Every piece on it is
  already in `client/assets`, cut from the screen it appears on, and an audit of
  every layout rect against its crop found no piece drawn past its own size
  where a master would help (the reward tiles look big but draw down --
  `store_view.fit_down`).

When a pack painting and a built screen disagree, measure what the built screen
has that the painting does not before cutting. Say so in the report either way.

## The design pack, painting by painting (audited 2026-09-18)

`~/Downloads/Emperors_Design_Pack/art/reference/` holds 74 paintings. All but
five are cut and in the game. The five, and what each is:

| Painting | State | What it is |
|---|---|---|
| `hunt.png` | **cut** | The Army's REROLL plate (`army/reroll_plate`). |
| `expedition.png` | **cut, page built** | THE HUNT, `client/scenes/pages/hunt_page.gd`. |
| `forge.png` | **cut, page built** | THE FORGE, `client/scenes/pages/forge_page.gd`. |
| `talents.png` | **cut, page built** | THE TALENT TREE, `client/scenes/pages/talents_page.gd`. |
| `offers.png` | **cut, screen built** | ROYAL OFFERS, `client/scenes/court/offers_view.gd`, opened by the Court's OFFERS card. One thing of the painting's is NOT drawn: the value plate it strikes a gold line through, which is a was-price. This game has none -- what a buyer pays is StoreKit's localized price, and the catalogue's `usd_cents` is Royal Favour's arithmetic and never a price to show -- so the plate and its strike are erased from the card rather than left standing empty. `art/slices/offers.json` records the rect (314,205,188,49 inside a card) for the day the catalogue publishes a full price to strike. The BEST VALUE ribbon is cut on its own and hung on whichever offer the catalogue badges `best_value`; the painting bakes it over its first crate, so that crate is cut with the ribbon filled back out of it. |
| `campaign.png` | **not cut** | A second design for the Attack tab's CAMPAIGN, which is built and painted from `attack.png`, `campaign_map_*.png` and `campaign_nodes_sheet.png`. The painting keeps the ATTACK header and its pills and pages the chapters with two arrows; the built screen carries a five-chapter strip and three star chests instead, which is more than the painting has. Cutting it would replace a richer screen with a plainer one. |
| `ui_bits_sheet.png` | **not cut** | The master sheet of the shared kit at full size: the BEST VALUE and MOST POPULAR ribbons, the FIRST PURCHASE x2 seal, the VIP badge, the diamond/coin/green plates, two hourglass medals, a tick seal, a padlock, a key, a sealed letter, an hourglass, a spyglass, an anvil, clasped gauntlets, a crowned skull, crossed banners, a map and compass, a hand banner, a herald's trumpet, a full and an empty star, a crown, an "i" disc, an "x" disc and a gold chevron. Every one of them is already in `client/assets/icons/` etc., cut smaller from the screen it appears on (`icons/padlock` is 44x56 from `wardrobe.png`; the sheet's is 109x155 of the same object). Cutting the masters is worth doing only where a piece is drawn bigger than the crop it has. |
