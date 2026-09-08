# Emperors — the frontend reference (rebuilt client)

Everything the client does, where it does it, and what the server will and will
not give you. Written so that somebody who has never opened this repository can
change a screen without guessing.

If you only read one thing: **the client renders, it never decides.** Every gold
figure, every XP award, every combat outcome arrives already resolved. There is
no formula in `client/` and there must not be one.

The second thing: **every pixel of art is a cut of a reference painting.** The
seven screens were painted first (`art/reference/*.png`, 941×1672 each) and the
game is assembled from crops of them. Nothing is redrawn or generated. What the
game sets itself is live text — numbers, names, timers — in Cinzel (capitals) and
EB Garamond (everything else).

---

## 1. How to run it

```sh
godot --path client                                   # the game (dev server at 127.0.0.1:8080)
godot --headless --path client --import               # after adding or re-cutting any asset
python3 scripts/lint-client.py                        # compiles every script, checks layouts ↔ assets ↔ manifests
scripts/sync-layout.sh                                # art/slices/*.layout.json -> client/layout/*.json
```

The API address comes from `res://env.build.json` (written by the export script)
or `user://env.json`, else the dev default. `--api=<url>` overrides it in dev builds.

**Dev flags** (debug builds only): `--dev-login <user> <pw>` signs in (registering
if needed); `--tab <name>` opens a section; `--capture <path> --capture-after <s>`
saves a screenshot and quits. A capture run mounts the scenes in a fixed
941×1672 SubViewport, so the saved PNG is the design grid 1:1 and diffs straight
against `art/reference/<tab>.png` no matter how macOS clamps the window.

**Design grid: 941 × 1672, portrait, locked.** `stretch/mode=canvas_items`,
`aspect=expand`, so a taller phone gets *more* canvas below, never a scaled one.
A source pixel in a reference painting is a layout unit in the game. On a phone
the shell shifts everything down by the display's safe-area inset.

---

## 2. The shape of the app

`scenes/boot/boot.gd` (splash, sign-in state) → `scenes/auth/auth.gd` → `scenes/shell/shell.gd`.
Scene switches go through `Nav.go(path)`, which is what lets a capture run redirect
them into the SubViewport.

`shell.gd` draws the chrome and hosts the seven screens:

- **the left rail** (x 0..160): canonical from `collect.png`; each section's lit
  red plate is cut from the painting where that section is active and scaled so
  its border box is 148×170. Locked sections are dimmed and stamped `LV n`
  from the server's `sections` list.
- **the currency pills** (gold, diamonds, energy) at their `collect.png`
  positions, numbers erased and set live at 29 px.
- **the screen host** — one Control per section. The first section opens at
  once; the other six are built and their data fetched one per frame right
  behind it, then kept hidden with `PROCESS_MODE_DISABLED`, so the first tap on
  any tab lands on a finished screen. A layout placeholder (`items/{item}`)
  draws nothing until its screen fills it; magenta is reserved for an asset
  that is missing.

Autoloads, in load order: `Env` → `Nav` → `Api` → `Session` → `GameState` →
`Art` → `Proof`. Each may only reference the ones above it.

| | |
|---|---|
| `Env` | base URL, dev flags |
| `Nav` | scene switching (root or the capture SubViewport) |
| `Api` | two keep-alive HTTP lanes, 20 s timeout, one 401 → refresh → replay, `offline`/`online` |
| `Session` | tokens in `user://session.dat`, encrypted per install; rotating refresh |
| `GameState` | the store: `snapshot` + `_pending`, projections, `act()` for sequenced actions |
| `Art` | every texture lookup; `Art.item(art_key, set)` maps server art keys onto the paintings |
| `Proof` | dev capture |

---

## 3. GameState — the one rule that matters

`snapshot` holds only what the server confirmed; `_pending` holds optimistic
collects. What a screen shows is `confirmed + replay(pending)`, computed on read
(`display_gold()`, `display_xp()`, `display_energy()`). A prediction is never
written into `snapshot`. `adopt()` is the single choke point for a replacement and
is where level-ups are noticed for every path.

`GameState.act(path, body)` attaches `action_seq` (must be exactly the player's
`action_seq + 1`), adopts a returned `snapshot` or refreshes, and turns
`stale_action` into a refresh rather than a toast. Reads never take a sequence.

One 4 Hz timer in the shell projects energy and repaints the pills. The 30 s
heartbeat (`POST /v1/presence`) is the only request an idle client makes.

---

## 4. The seven screens

Each screen is `scenes/tabs/<name>.gd`, built from `client/layout/<name>.json`
by `Layout.build()`. Estates, the Bank and the Legacy have no painting of their
own and fold into the Family ledger as cards in the GRANARY card's style.

| Rail | Script | Server section | What it does |
|---|---|---|---|
| Family | `family.gd` | `hero` | name (the quill buys a new one for diamonds; price from `snapshot.prices`), level, XP bar, stats (tap a cell to spend a point), gear tiles → chooser, EQUIP BEST, then the ledger: 11 Family upgrades, the Royal Treasury (deposit/withdraw), 8 estate holdings, the Legacy |
| Collect | `collect.gd` | `jobs` | today's three quests (tap to claim), fifteen job rows (six paintings cycle), optimistic COLLECT; each row's mastery track fills toward the next threshold and its three markers read reached / next / after from `job.mastery` |
| Inventory | `inventory.gd` | `items` | equipped gear (tap to unequip), rarity chips, item grid: EQUIP / SELL / REFORGE; the sliders button opens the Collection (donate) |
| Shop | `shop.gd` | `shop` | six offers on the 5-minute window, reroll for diamonds, Diamond Goods (energy refill, shield) |
| Army | `army.gd` | `army` | might, hero support, four soldier cards + next slot, selected soldier (gear, HUNT = autoroll, DISMISS), recruit cards with the published odds |
| Attack | `attack.gd` | `fight` | REVENGE / TARGETS tabs, revenge card, three targets with the power bar, battle history |
| Kingdom | `kingdom.gd` | `house` | identity, renown/treasury/members, realm bonuses, DONATE, reputation ladder, lords, works (+ the Favour shop under View All), ranking; founding and invitations when there is no kingdom |

Unlock levels come from the server's `sections` on `/v1/state`.

---

## 5. Layout files — how a screen is described

`art/slices/<screen>.layout.json` is measured off the painting and copied to
`client/layout/` by `scripts/sync-layout.sh`. Screen code never carries a
coordinate: it asks for parts by id and fills in live values.

```json
{"id": "job_row", "kind": "template", "rect": [166, 517, 762, 156], "pitch": 168,
 "parts": [
   {"id": "frame", "kind": "image", "asset": "collect/job_row", "rect": [0, 0, 762, 156]},
   {"id": "name", "kind": "text", "rect": [190, 12, 290, 36], "font": "title", "size": 24, "weight": 700, "color": "#F4EEE2"},
   {"id": "collect", "kind": "button", "asset": "collect/collect_button", "rect": [566, 13, 178, 76]}
 ]}
```

Kinds: `image` (`fit: contain` keeps a painting's own proportions inside its
box, for item designs drawn into a tile), `text`, `button` (a painted crop; with
no asset, an invisible tap target), `ninepatch`, `fill` (a bar clipped from the left via
`Layout.set_fill`; an `image` carrying a `fill` key is built as one), `scroll`,
`group`, `template` (repeated component;
`instances` may be `[x, y]` or `{pos|at, assets, texts, rects, data}`).
Top-level rects are absolute; part rects are relative to their template.
A top-level element may carry `"anchor": "bottom"` (pinned to the foot of the
screen the player has, which on a tall phone is below the design's 1672) or
`"grow": "bottom"` (its top stays, its bottom follows the screen's -- for the
scroll lists). The rail spans the full height, dialogs centre in the visible
viewport, and the toast hangs off its foot. `--capture-size 941x2040` renders
a capture at a 19.5:9 phone's canvas to check all of this.
`Layout.build()` returns `{id: node}` for plain elements and
`{id: [{node, parts}, ...]}` for templates with instances. A nested template with
instances comes back as a wrapper whose meta `instances` lists them.

Text: `font` is `title` (Cinzel) or `body` (EB Garamond); `size` is the pixel
size measured on the painting; weights are lifted one step in `UI.settings`
because the paintings read heavier. `UI.fit_label(label, max, min)` shrinks a
name to its box — a Label grows to its text, so the box width is kept in meta.

---

## 6. Art — cutting, not drawing

`art/SLICING_GUIDE.md` is the contract. In short:

- `art/slices/<screen>.json` lists every crop: `rect` in source pixels, `mode`
  (`rect` opaque, `darkkey` alpha against the navy ground), `erase` (per-row fill
  that removes baked dynamic text), `inpaint`, `mask`, `scale` (never used for
  content).
- `art/.venv/bin/python scripts/slice-reference.py art/slices/<screen>.json --refdir art/reference --out client/assets`
  cuts them; then import.
- Buttons are cut *with* their painted labels (COLLECT, BUY, EQUIP…). Plates
  that hold live text are cut with that text erased. Static titles stay baked.
- `art/qa/<screen>_sbs.png` is the reference beside the rebuild. When you change
  a screen, capture it and put it beside the painting again — look at it.
- Every asset goes through `Art.tex(name)` (`res://assets/<name>.png`); a missing
  one warns once and draws magenta. Item paintings are chosen per screen set
  (`Art.item(key, "shop"|"inventory"|"equipped"|"family"|"soldier")`) because each
  painting size belongs to one screen.

Things the paintings do not contain, and how they are handled: item designs
(the paintings hold one item per slot per screen, so every slot showed the same
picture; the 21 designs the balance names now ship as their own matted paintings
under `items/painted/`, cut out of the paintings' own item pictures by
`scripts/cut-item-paintings.py` -- object mask plus luminance key, so a glow
survives and the ground goes clear -- and drawn inset into each screen's empty
tile crop; the stone on a gear tile is `family/gem_<tier>` from
`scripts/gen-gem-tints.py`), only six job paintings (cycle), one upgrade painting (the granary, reused), portraits for
rivals and lords (assigned by hashing the id), tier numerals I–III (higher tiers
use a blank plate with live text), one large soldier portrait (others are scaled
into the tile), no lit hexagon but tier II (overlays tint the current tier).

---

## 7. The API, as the client sees it

Unchanged from the server's contract: base `/v1`, `Authorization: Bearer`,
`action_seq` on every mutation, RFC-7807-ish errors `{code, message, request_id}`.
Gold and treasury are JSON strings. The endpoints each screen calls are listed at
the top of its script; the server routes are in `server/internal/httpx/router.go`.
Request bodies are strict (unknown fields are rejected), so send exactly the
documented fields.

---

## 8. What the client must never do

- Compute a game number, simulate a fight, or write a prediction into `snapshot`.
- Send an `action_seq` it did not read from the current snapshot.
- Hardcode an asset path or a coordinate — both come from the layout files.
- Redraw, regenerate or scale a painting. If a screen needs art the paintings do
  not contain, that is a new painting to cut, not a shape to draw.
