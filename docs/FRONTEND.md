# Emperors — the frontend reference

Everything the client does, where it does it, and what the server will and will
not give you. Written so that somebody who has never opened this repository can
change a screen without guessing.

If you only read one thing: **the client renders, it never decides.** Every gold
figure, every XP award, every combat outcome arrives already resolved. There is
no formula in `client/` and there must not be one.

---

## 1. How to run it

```sh
godot --path client                          # the game
godot --headless --path client --import      # after adding any asset
python3 scripts/lint-client.py               # parses every script, checks art + contrast
godot --headless --path client --script tests/shell_fits.gd
```

**There is no `--api` flag.** The address comes from a file, checked in this
order by `Env._ready()`:

1. `res://env.build.json` — written by `scripts/deploy-iphone.sh` at export time
   and deleted again straight after. It lives in `res://`, so leaving one behind
   pins every later desktop run to that address.
2. `user://env.json` — wins when present, and is how a **device build is
   repointed without recompiling**.

Otherwise it falls back to the dev default printed at boot:
`[env] api_base_url=… build=…`. To run against a local server, write
`client/env.build.json`:

```json
{ "api_base_url": "http://127.0.0.1:8080", "build_version": "local" }
```

and delete it when you are done. The deployed server is
`https://91-107-215-32.sslip.io`.

The one real dev flag is `--fake-safe-area=<preset|l,t,r,b>`, which reproduces a
phone's notch insets on a desktop — the layout they break is exactly the layout
nobody sees until the build is on a device.

**Design grid: 720 × 1280, portrait, locked.** `stretch/mode=canvas_items`,
`aspect=expand`, so a tall phone gets a *taller* viewport than 1280 rather than a
scaled one. Every number in the UI constants is in these units.

---

## 2. The shape of the app

`scenes/boot/boot.gd` (splash, reachability) → `scenes/auth/auth.gd` (sign in) →
`scenes/shell/shell.gd` (everything else).

`shell.gd` builds the whole chrome in code — there is no scene tree in the
editor, for any screen. It owns:

- **the top banner** — currency chips (gold, diamonds, energy) and the XP thread
- **the left rail** — nine section plates, always visible, dimmed and stamped
  with an unlock level when locked. "Seeing what is coming is most of what makes
  levelling feel like progress."
- **the bottom action strip** — one button per screen, mounted by that screen
  through `mount_action_bar(host)`. This is the only part of a tall phone a thumb
  reaches, so the primary verb of every screen lives here and nowhere else.

Hidden tabs get `PROCESS_MODE_DISABLED`, so nine screens do not tick at once.

### Autoloads, in load order

`Env` → `Api` → `Session` → `GameState` → `ArtRegistry` → `Proof`.
Each may only reference the ones above it.

| | |
|---|---|
| `Env` | base URL (from `env.build.json` / `user://env.json`), `--fake-safe-area` |
| `Api` | two pooled keep-alive HTTP lanes, 20 s timeout, one 401 → refresh → replay, `offline`/`online` signals |
| `Session` | tokens in `user://session.dat`, encrypted with a per-install key. 15-minute access tokens, rotating refresh |
| `GameState` | **the store** — see §3 |
| `ArtRegistry` | every texture lookup. No scene may hardcode a `res://assets` path, and the linter enforces it |
| `Proof` | dev-only screenshot capture |

---

## 3. GameState — the one rule that matters

```gdscript
snapshot   # ONLY what the server confirmed
_pending   # optimistic actions not yet acknowledged
```

What the screen shows is `confirmed + replay(pending)`, computed on read:
`display_gold()`, `display_xp()`, `display_energy()`, `accrued_tax()`,
`display_seconds_to_next()`.

**A prediction is never written into `snapshot`.** Nothing has to be rolled back
because nothing was written. If you are about to assign to `snapshot`, you have
found the wrong solution.

Taps are queued and flushed in batches of up to `BATCH_MAX = 32`; the server
replies with how many landed and only those leave the queue. There is
deliberately no "N queued" indicator.

### Signals

| Signal | Fires when |
|---|---|
| `changed` | any snapshot replacement — the general "redraw" |
| `energy_changed(current)` | the whole number moved, from the 4 Hz projector |
| `action_failed(message)` | also used for ordinary toasts, not only errors |
| `level_up(level, levels, stat_points, diamonds)` | detected in `adopt()`, so **every** path celebrates — collects, raids, quest claims |
| `mastery_reached(job_id, collects, bonus_bp)` | a job crossed a milestone |

`adopt()` is the single choke point for a snapshot replacement. Anything that
should notice a change belongs there, not in each caller.

### Timing

One 4 Hz timer in `shell.gd` projects energy and the rising gold label. **No UI
node reads state in `_process`.** The 30 s heartbeat (`POST /v1/presence`) is the
only request an idle client makes.

---
## 4. The nine screens

Each screen is a `VBoxContainer` script in `client/scenes/tabs/`, instantiated by
`shell.gd`'s `TABS` dictionary. Each may implement `mount_action_bar(host)`.

| Section | Script | Unlocks | The verb |
|---|---|---|---|
| Jobs | `collect.gd` | 1 | tap a job, spend energy, get gold + XP |
| Hero | `keep.gd` | 1 | spend stat points, buy Family upgrades, begin a Legacy |
| Shop | `shop.gd` | 2 | buy gear, reroll for diamonds |
| Items | `inventory.gd` | 3 | equip, sell, reforge, donate to the Collection |
| Estates | `territory.gd` | 4 | buy and expand holdings |
| Army | `barracks.gd` | 5 | buy slots, recruit, hunt a tier, gear soldiers |
| Bank | `bank.gd` | 8 | deposit (10% fee, burned) or withdraw |
| Fight | `attack.gd` | 10 | raid, avenge, watch the history |
| House | `kingdom.gd` | 20 | realm, lords, works, and the leaderboards |

Unlock levels come from the server in the state snapshot (`sections`), never from
a client-side copy.

### What is on each one

**Jobs.** Fifteen job rows; each shows icon, name, collects done, mastery bonus,
next milestone, gold and energy cost. Above the list sits **today's three
quests** — they are here rather than on a tenth rail entry because most of them
are about collecting and the rail has no room. Quest progress refreshes on
`changed`, throttled to once every three seconds.

**Hero.** Identity card (portrait → `avatar_picker.gd`, 12 avatars), a four-cell
stat grid, three gear plates → `item_chooser.gd`, "EQUIP BEST", the stat-point
spend (3 per level, irreversible, confirmed), eleven Family upgrades, and — only
at the level cap or once a run has been taken — the **Legacy** card.

**Shop.** Two sub-tabs. *Market*: six offers, restocked every 300 s, priced in
gold, with a live countdown. *Diamonds*: energy refill (12) and an 8 h shield
(20), each greyed out with a reason when buying would do nothing. Action bar
rerolls the market for escalating diamonds.

**Items.** A flat list of up to 150, equipped first then by power. Four filter
chips: All / Common / Uncommon / **Wall**. With a tier filter on, SELL becomes a
bulk sell of everything shown. The Wall chip shows the **Collection** — 63
designs in 21 sets of three, held or not. Actions: EQUIP, GIVE (donate), REFORGE,
SELL.

**Estates.** A header card showing gold per hour — **there is no collect
button**, income is credited by middleware on every authenticated request and the
client projects it forward at 4 Hz. Eight holdings, five levels each. Each row
shows what the next level adds, including at level 0.

**Army.** Might headline, hero row, one row per owned slot, then the next-slot
row. Selecting an empty slot turns the list into the **recruit menu**: three
soldier types with their real published odds. Action bar: RECRUIT and **HUNT**
(auto-roll). Tapping an occupied row again opens `unit_sheet.gd` — three gear
slots and Dismiss. Soldiers have no level; their tier is their rank.

**Bank.** Two numbers: on hand (stealable) and in the vault (not). Deposit costs
10%, burned. The whole screen is one risk decision.

**Fight.** Two sub-views. *Raid*: **scores to settle** first (revenge tokens, red
bordered, half energy, ignores their shield), then three matchmade targets with
relative strength and the prize. *History*: every fight either way, who, and the
signed gold; tapping one replays it.

**House.** *Ranks* is always available, even with no kingdom — three boards
(Might, Level, Wealth) with your own rank called out. With a kingdom: *Realm*
(level, treasury, renown, donate), *Lords* (roster, roles, invite), *Works*
(eight treasury-funded upgrades), and the **Kingdom Shop** where Favour is spent.

---
## 5. The API, as the client sees it

Base `https://91-107-215-32.sslip.io/v1`. Everything but `auth/*` needs
`Authorization: Bearer <access token>`; `Api` attaches it and handles one
401 → refresh → replay transparently.

### The sequence number, and why a request fails

Every action that changes something carries `action_seq`, and it must be
**exactly** the player's current `action_seq + 1`. Read it from
`GameState.player().action_seq`. Anything else is `409 stale_action`, which means
"you are behind, re-read state" — not "retry".

This is what makes a lost response safe: a retry with the same number is refused
rather than applied twice. It also means **a loop must refresh between calls**,
or the second request carries a stale number.

Reads (`GET`) never take one. Nor do `POST /v1/daily/claim` and `POST /v1/devices`,
which are idempotent by construction.

### Every endpoint

| | Endpoint | Notes |
|---|---|---|
| **auth** | `POST /auth/register` | `{username, password, tz_offset_minutes}` — the offset is what makes daily resets happen at the player's own midnight |
| | `POST /auth/login` `POST /auth/refresh` | |
| **state** | `GET /state` | player, energy, sections, jobs, server time, config version |
| | `POST /presence` | 30 s heartbeat |
| | `GET /avatars` `POST /avatar` | |
| **jobs** | `POST /collect` `POST /collect/batch` | batch takes `job_ids[]` + `action_seq`; replies `applied`, `applied_through`, `stopped_because`, `milestone_hit`, `milestone_job` |
| | `POST /stats/spend` | |
| **shop** | `GET /shop` | `offers[]` with `slot`, `price`, `item`; plus `window_id`, `seconds_left`, `reroll_cost` |
| | `POST /shop/buy` | `{slot, action_seq}` — **slot, not item id** |
| | `POST /shop/reroll` | diamonds, escalating within a window |
| | `GET /store` `POST /store/buy` | the diamond goods |
| **items** | `GET /inventory` | each item carries `power`, `sell_price`, `reforge_price` |
| | `POST /inventory/equip` `unequip` `sell` | |
| | `POST /inventory/sell/batch` | `item_ids[]`, max 50, one gold movement and one ledger row |
| | `POST /inventory/reforge` | re-rolls quality; **can make it worse**; replies `improved` |
| | `GET /collection` `POST /collection/donate` | a duplicate is refused *before* the item is consumed |
| **army** | `GET /army` | roster, `totals.might`, `recruits[]` (all three types) |
| | `GET /army/odds` | the published tier chances, from the same function the roll uses |
| | `POST /army/slot` `recruit` `dismiss` `equip` `autoequip` | |
| | `POST /army/autoroll` | `{slot, type_id, target_tier, max_gold, action_seq}` → `rolls`, `gold_spent`, `final_tier`, `hit_target`, `stopped_because` |
| | `POST /army/train` | **410 Gone.** Soldiers do not level |
| **estates** | `GET /estates` | `tax.per_hour_milli`; each holding carries `yield_per_level_milli` |
| | `POST /estates/upgrade` `holding` | |
| | `POST /estates/tax/claim` | **410 Gone.** Income is continuous |
| **fight** | `GET /attack/targets` | `targets[]` **and `revenge[]`** |
| | `POST /attack` | `{target_id, action_seq, revenge?}` |
| | `GET /attack/history` `GET /battles/{id}` | the log, and one replay |
| **kingdom** | `GET /kingdom` `search` · `POST /found` `invite` `accept` `leave` `role` `donate` `upgrade` | |
| | `GET /kingdom/shop` `POST /kingdom/shop/buy` | what Favour buys |
| **daily** | `GET /daily` `POST /daily/claim` | seven-square calendar |
| | `GET /quests` `POST /quests/claim` | `{slot, action_seq}` |
| **other** | `GET /leaderboards/{board}` | `might` \| `level` \| `wealth`, plus `my_rank` |
| | `GET /legacy` `POST /legacy/begin` | |
| | `POST /devices` | `{token, platform}` — stored, not yet sent to |

Errors are RFC-7807-ish: `{code, message, request_id}`. `Api` surfaces `message`.
Codes worth handling by name: `stale_action`, `not_enough_energy`,
`not_enough_gold`, `not_enough_diamonds`, `not_enough_favour`, `inventory_full`,
`shop_stale`, `already_claimed`, `quest_unfinished`, `already_collected`,
`no_revenge`, `legacy_unavailable`, `shielded`, `on_cooldown`.

Gold and treasury are **JSON strings**, not numbers — they can exceed 2^53 and a
JS-shaped parser would round them.

---

## 6. Building UI

Everything is code. There is no `.tscn` for any screen, and adding one would
break the pattern every other screen follows.

### The helpers — `client/scripts/ui/ui.gd`

`UI.label(text, size, color, align)` · `UI.button` · `UI.ghost_button` ·
`UI.danger_button` · `UI.line_edit` · `UI.panel_box(bg, border, radius)` ·
`UI.card_box(selected, locked)` · `UI.chip_box` · `UI.skin(name, fallback, pad_h, pad_v)` ·
`UI.section_header(text, action)` · `UI.screen_title` · `UI.stat_grid(entries)` ·
`UI.rule()` · `UI.spacer(h)` · `UI.number(v)` · `UI.grouped(v)` ·
`UI.duration(s)` · `UI.short_duration(s)`

### Type

`F_DISPLAY 58` · `F_H1 40` · `F_H2 32` · `F_NUMBER 30` · `F_BODY 26` ·
`F_CAPTION 22` · `F_MICRO 19`

### Touch targets — these are floors, not suggestions

`TAP_MIN 76` (46 pt) · `TAP_PRIMARY 96` (the one button a screen is about) ·
`TAP_ROW 104` (a list row, 64 pt) · `TAP_ROW_TIGHT 88`

### Spacing and icons

`GAP_XS 4` · `GAP_S 8` · `GAP_M 16` · `GAP_L 24` · `GAP_XL 32` · `CORNER 12`
`ICON_SM 24` · `ICON_MD 40` · `ICON_LG 56` · `ICON_XL 80`

### Nine-slice skins — the trap

`UI.skin()` returns a `StyleBoxTexture` with a **bleed**: it is drawn
`SKIN_BLEED = 14` units *outside* the rect it is given, on every side. That is
deliberate (it lets a carved edge catch light past its own box) and it is the
single most common cause of "why is this drawn over the thing next to it".

`SKIN_GEOM` overrides it per skin. The small stamped family — `chip`, `plaque`,
`rail_active`, `nav`, `nav_active` — is `[15, 0]`: slice 15, **no bleed**.
Anything not in that dictionary falls back to `[42, 14]`.

If you add a skin that should sit inside its rect, add it to `SKIN_GEOM`. The
rail's plates were being drawn twelve units past the column for exactly this
reason.

### Colour — `client/scripts/ui/palette.gd`

Parchment, not a dark theme. `BG #E8DCC0` is the ground; **`PANEL #F2E8D2` is
lighter than the ground**, which is the opposite of most dark-mode instincts.

`TEXT #2E1F14` · `TEXT_DIM` · `TEXT_FAINT` · `LINE` · `PANEL_HIGH` (raised) ·
`RAIL` · `GOLD_INK` (a gold *figure*, 6.26:1 on PANEL) · `GOLD_DEEP` (edges) ·
`ENERGY` · `DIAMOND` · `DANGER` · `SUCCESS` · `BANNER` + `BANNER_INK` (8.28:1)

`Palette.tier(id)` gives a tier's colour, from `balance/tiers.json`.

**Two hard rules the linter enforces:**

1. **Every text colour must clear WCAG AA on every ground it is drawn on.**
   `lint-client.py` checks this and fails the build. `Palette.GOLD` is an
   *ornament* colour and must never be used as type — that is why `GOLD_INK`
   exists.
2. **Tier is never signalled by colour alone.** Every card also carries the tier
   name and a 1–7 pip count, because a gray/green/blue/violet/gold/magenta/red
   ladder is not reliably separable under deuteranopia.

### Lists

`DragScroll.install(scroll)` on every `ScrollContainer`. Godot's own touch
scrolling is gated behind `is_touchscreen_available()` and is eaten by the
buttons a list is made of, so without this a list simply does not follow a
finger.

Rebuild by diffing: `collect.gd` rebuilds rows only when the row *count* changed
and updates in place otherwise, so tapping does not rebuild fifteen rows and lose
scroll position.

### Modals

`Confirm.ask(host, cfg) -> bool` and `Confirm.choose(host, cfg) -> String`.
Both arm their buttons after `ARM_DELAY = 0.25 s`, so a double-tap on the row
underneath cannot resolve a spend. The backdrop deliberately does **not**
dismiss. Both add themselves to the tree root, not to `host`, because opening a
tab hides the outgoing one.

### Safe area

`SafeArea.insets()` / `SafeArea.wrap(node, margins)`. Returns zero on desktop;
`--fake-safe-area=<preset|l,t,r,b>` reproduces device insets. Applied on
`NOTIFICATION_APPLICATION_RESUMED` too, because rotating the phone on the home
screen changes it while backgrounded.

---
## 7. Art

Every texture goes through `ArtRegistry`. **No scene may hardcode a
`res://assets` path** — `lint-client.py` fails the build if one does. This is
what lets art be retuned or replaced without touching a screen.

### The four lookups

| Call | Reads | Example |
|---|---|---|
| `ArtRegistry.ui_icon(name)` | `assets/ui/<name>.png` | `ui_icon("currency/coin")`, `ui_icon("nav/army")`, `ui_icon("skin/nav")` |
| `ArtRegistry.item_icon(art_key, tier)` | `assets/items/<art_key>_<tier>.png` | `item_icon("weapon_03", "legendary")` |
| `ArtRegistry.portrait(name)` | `assets/portraits/<name>.png` | `portrait("knight")` |
| `ArtRegistry.branding(name)` | `assets/branding/<name>.png` | `branding("icon_1024")` |

All four cache, and all four degrade rather than crash: a missing item icon falls
back down the tier ladder and then to a generated placeholder; a missing portrait
falls back to `knight`. **A missing asset therefore does not fail loudly at
runtime** — the linter is what catches it, so run it.

### The directories

```
client/assets/
  ui/skin/      nine-slice surfaces (nav, chip, plaque, banner, rail_active…)
  ui/chrome/    frames and structural pieces (rail_frame…)
  ui/tile/      tiling grounds (marble…)
  ui/orn/       ornaments (laurels, flourishes)
  ui/glyph/     small marks
  ui/stat/      stat icons
  ui/holdings/  one per estate
  ui/upgrades/  one per Family upgrade
  items/        <slot>_<design>_<tier>.png   — 21 designs × 7 tiers
  portraits/    12 avatars
  branding/     app icon, launch images
  fonts/
```

### If you are generating new art

The existing assets are produced by scripts in `scripts/` (`gen-ui-icons.py`,
`gen-ui-skin.py`, `gen-item-art.sh`, `gen-portraits.sh`, `gen-rail-painted.sh`)
into `art/`, which is a **workspace Godot never imports**. Finished assets are
copied into `client/assets/`.

Hand-drawn or model-generated art is fine — the pipeline is not sacred — but four
things are not negotiable:

1. **PNG with alpha, and the size the slot expects.** Item icons and nav icons
   are square; skins are nine-slices whose slice and bleed must match
   `UI.SKIN_GEOM` or they will smear. `gen-ui-skin.py` documents the geometry it
   produces (`SMALL = size 64, pad 3, radius 6 → slice 15, bleed 0`).
2. **The palette.** Everything is parchment-and-ink. A saturated modern icon will
   look pasted on, and if it becomes *type* it will fail the contrast check.
3. **The naming, exactly.** `item_icon` splits `art_key` on `_` to find the slot,
   so `weapon_03_legendary.png` works and `sword-03-legendary.png` does not.
4. **Import it.** Godot writes a `.png.import` next to each texture and both are
   committed. Run `godot --headless --path client --import` after adding files,
   or `ResourceLoader.exists()` returns false and you get the placeholder with
   no error at all.

`lint-client.py` checks that every nav icon, job icon, upgrade icon, holding
icon, slot icon and item design has art, and that every shipped asset is
imported. It is the fastest way to find out you missed one.

### One naming rule that is enforced in the generator

An item named "Falchion" must be *drawn* as a falchion. `gen-balance.py` asserts
this against a `SHAPE_WORDS` table and fails generation if a name and its art
design disagree. If you add designs, extend that table.

---

## 8. Layout budgets, and the tests that guard them

The rail carries nine plates plus the crest, and the shell's column must fit on
the shortest device shipped — **an iPad 10.9 at 1280 units**, which is tighter
than any phone because a tall phone gets a taller viewport.

| Test | What it would catch |
|---|---|
| `shell_fits.gd` | the rail column overflowing off the bottom on any of four devices |
| `rail_crest_inside_frame.gd` | the crest plate drawn over the rail's top border |
| `tabs_fit.gd` | a screen wider than its budget *(needs a server)* |
| `touch_scroll.gd` | a list that no longer follows a finger |
| `confirm_dialog.gd` | the modal arming early, or the backdrop dismissing |
| `energy_projection.gd` `energy_countdown.gd` `energy_rearm.gd` | the 4 Hz projector drifting from the server |
| `input_reaches_game.gd` | an overlay swallowing input |
| `api_latency.gd` `offline_session.gd` `reconnect.gd` | the network layer *(need a server)* |

**Adding a tenth rail section is not a small change.** There is roughly 159 units
of spare column on the binding device. Both new features in this round — the
battle log and the leaderboards — were added as *sub-views inside an existing
screen* for exactly this reason, following the pattern `shop.gd` already used.

---

## 9. What the client must never do

- **Compute a game number.** No formula belongs in `client/`. If a screen needs a
  value the server does not send, add it to the response — do not derive it.
  Every field on `ItemView`, `JobView` and the rest exists because a screen
  needed it and deriving it locally would have been a second implementation.
- **Simulate a fight.** `battle_replay.gd` animates the server's event log. This
  is what keeps cross-platform float determinism off the correctness path.
- **Write a prediction into `snapshot`.** See §3.
- **Send an `action_seq` it did not read from the current snapshot.** Refresh
  between calls in any loop.
- **Hardcode an asset path, or a balance number.** Both come from the server or
  from `ArtRegistry`.
- **Signal anything by colour alone.**

---

## 10. Things that are deliberately missing

So nobody rebuilds them by accident, or assumes they were forgotten:

- **No collect button on Estates.** Income is continuous, credited on every
  authenticated request. `POST /estates/tax/claim` answers 410.
- **No soldier levels, no training.** A soldier's tier is its rank, fixed at
  recruitment. `POST /army/train` answers 410.
- **No chat, no friends, no trading.** Cut in `docs/PLAN.md`.
- **No push notifications yet.** Tokens are collected (`POST /devices`); sending
  needs an APNs key, the Push Notifications capability on the App ID, and a
  native Godot plugin, none of which exist. `entitlements/push_notifications` is
  deliberately **off** in the export preset — turning it on makes every build
  demand a profile carrying that capability.
- **No IAP.** Diamonds are earned only, from levels and the daily calendar.
- **No in-app account deletion, no odds screen link, no client version gate.**
  These three are App Store blockers and are not built. The odds *data* is
  served (`GET /army/odds`) and rendered inline on the recruit rows; a dedicated
  linked screen is still required for review.

---

## 11. Where to look when something is wrong

| Symptom | Look at |
|---|---|
| A number is wrong on screen but right elsewhere | the screen is recomputing instead of using what the server sent |
| `409 stale_action` | an `action_seq` that was not `current + 1`; refresh between calls |
| A change to `balance/*.json` did nothing | you did not run `gen-balance.py`, or did not `publish-balance` |
| A texture is a grey placeholder | wrong filename, or not imported — run `lint-client.py` |
| Something is drawn over its neighbour | nine-slice bleed; see `SKIN_GEOM` in §6 |
| A list will not scroll on a phone | missing `DragScroll.install()` |
| The build fails on `purity_test` | `internal/game` gained an import it may not have |
| A publish is refused | `Validate` rejected it — the error names the exact rule |
