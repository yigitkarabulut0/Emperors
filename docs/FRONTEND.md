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
scripts/run-client-tests.sh [word...]                 # every client/tests/*.gd headless, each under a time limit
scripts/sync-layout.sh                                # art/slices/*.layout.json -> client/layout/*.json
```

The API address comes from `res://env.build.json` (written by the export script)
or `user://env.json`, else the dev default. `--api=<url>` overrides it in dev builds.

**Dev flags** (debug builds only, parsed by the pure `Env.parse_args`, which
`tests/env_args.gd` holds to moving past exactly the words each flag reads):
`--dev-login <user> <pw>` signs in (registering if needed); `--tab <name>` opens
a section; `--page <name>` opens a page on arrival (`profile`, `ranks`, `stats`,
`guide` — the steward's guide at the lord's step, `daily`, `wall`, `history`, `away`, `mail`, `letter` — the inbox with its
first letter open; `chests` — the Tax Cart over the COURT; `cart_odds` — its odds page; `week` — Collect on THIS WEEK'S QUESTS; `weekly` — the whole week over it); `--replay-last` plays the newest battle;
`--capture <path> --capture-after <s> [--capture-size WxH]` saves a screenshot
and quits. A capture run mounts the scenes in a fixed
941×1672 SubViewport, so the saved PNG is the design grid 1:1 and diffs straight
against `art/reference/<tab>.png` no matter how macOS clamps the window.

**Design grid: 941 × 1672, portrait, locked.** `stretch/mode=canvas_items`,
`aspect=expand`, so a taller phone gets *more* canvas below, never a scaled one.
A source pixel in a reference painting is a layout unit in the game. On a phone
the shell shifts everything down by the display's safe-area inset, and the tab
host keeps its foot on the screen's (`tests/safe_area.gd`): moved with
`position.y` a full-rect control keeps its height, and every tab once ran 141
units past the bottom of an iPhone with a Dynamic Island.

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
| `Api` | two keep-alive HTTP lanes, 20 s timeout, one 401 → refresh → replay, `offline`/`online`; `track()` queues what only the phone sees for `POST /v1/events` (a minute at a time, a beacon on pause, nothing in a capture) |
| `Session` | tokens in `user://session.dat`, encrypted per install; rotating refresh |
| `GameState` | the store: `snapshot` + `_pending`, projections, `act()` for sequenced actions, `adopt_async()` for answers outside the sequence, `badges` + `badges_changed` from the heartbeat |
| `Art` | every texture lookup; `Art.item(art_key)` maps server art keys onto the paintings, `Art.reward_icon(key)` a reward line's icon (a key with a slash is already a crop; the potion and the charter are the paintings' own, `rewards/energy_potion` and `rewards/charter`), `Art.avatar(id)` / `Art.avatar_small(id)` a lord's face (236 / 96 px, frameless: the screen supplies the frame, a card's window or a ring) |
| `Proof` | dev capture |

---

## 3. GameState — the one rule that matters

`snapshot` holds only what the server confirmed; `_pending` holds optimistic
collects. What a screen shows is `confirmed + replay(pending)`, computed on read
(`display_gold()`, `display_xp()`, `display_energy()`, `display_storehouse()`). A
prediction is never written into `snapshot`. The purse takes no estate income:
that fills the storehouse, which `display_storehouse()` ticks from the snapshot's
`storehouse` (`milli + per_hour_milli × elapsed`, to `cap_milli`, never rising
when already over it -- `game/estates.Fill`'s sum) until the lord carries it in. `adopt()` is the single choke point for a replacement and
is where level-ups are noticed for every path.

`GameState.act(path, body, words)` attaches `action_seq` (must be exactly the
player's `action_seq + 1`), adopts a returned `snapshot` or refreshes, and turns
`stale_action` into a refresh rather than a toast; `words` (optional) maps a
refusal's code to the screen's own sentence. Reads never take a sequence.

An endpoint that is not the player's own sequenced action -- claiming a letter
now, a purchase delivered later -- takes no `action_seq` (the server's strict
decoder refuses one it does not expect) and its snapshot goes through
`GameState.adopt_async()`: adopted at once, unless a batch of collects is in
flight, in which case the state is fetched again once the batch lands, because
either answer could arrive first.

One 4 Hz timer in the shell projects energy and repaints the pills. The 30 s
heartbeat (`POST /v1/presence`) is the only request an idle client makes.

---

## 4. The eight screens

Each screen is `scenes/tabs/<name>.gd`, built from `client/layout/<name>.json`
by `Layout.build()`. Estates, the Bank and the Legacy have no painting of their
own and fold into the Family ledger as cards in the GRANARY card's style.

The rail has eight entries -- the seven below and COURT last -- laid out by
`Shell.rail_geometry(h)` from `court.png`'s measurements: entries from y 216
under the portrait's divider, a 200-unit foot, pitch 157 on the 1672 design,
narrowing (and the entries drawing smaller with it) on a shorter rail under a
notch, growing to 190 at most on a taller one with the rest above the seal. A
lit entry is `nav/<id>_lit` (`rail_lit.json`) at one scale, centred on its cell.
At the foot, the event seal (`chrome/rail_seal` and its plate): the running
event's time left, else the next one's start ("in 5h 00m"), else dimmed to 0.45
with an empty plate; a tap opens COURT with the events panel over it
(`Shell.open_events`). The rail is placed by offsets from the screen's foot and
re-laid on resize. `--page court` and `--page events` open them for captures.

| Rail | Script | Server section | What it does |
|---|---|---|---|
| Family | `family.gd` | `hero` | name (the quill buys a new one for diamonds; price from `snapshot.prices`), level, XP bar, stats (a tap opens the stat-points page), gear tiles → the gear page, EQUIP BEST, then the ledger, headed by the STOREHOUSE card (`family_storehouse.png`: the storehouse's picture by fill -- empty under a third, half, overflowing when full -- the gold waiting ticking over its capacity, HOLDS 8H and its Tithe Barn minutes, "Full in 3h 20m" or "Full" in red, COLLECT to the purse and TO VAULT with its fee, dimmed until the vault opens; one carry at a time, `POST /estates/storehouse/carry`), under it the ROYAL TREASURY card (`family_treasury.png`, the bank; see "The TREASURY card" below), and under that the TALENTS / DEEDS / ROAD strip (`family_storehouse.png`'s three medallion cards, 7 under the treasury card as `family_treasury.png` lays them, their outer frames on the ledger's edges: each card whole with the painting's red disc lifted -- the medallion turned half a circle over it, so the ring meets itself; TALENTS opens the tree (Wave 7) and says what waits -- "3 points to spend", else "9 ranks taken", else "Choose your three" -- dimmed only under its own level; DEEDS opens the Deeds; ROAD opens the Victory Road page and says what waits -- "3 rewards waiting", else "Next at level 25", else "The road is walked" -- the count in the COURT cards' disc (`court/badge`, drawn down to 49) from the heartbeat's `road`), then: 11 Family upgrades, 8 estate holdings, the Legacy. Each upgrade and holding wears its own scene, `family/ledger_<id>` (`family.card_scene()`; the Granary keeps `granary_art`; the Legacy wears `family/ledger_legacy`, its gallery of ancestors from `ledger_extra_sheet.png`), under `family/art_frame`, the window's chamfered corner, and an icon for its bucket; gates and the vault's fee are the estates view's |
| Collect | `collect.gd` | `jobs` | the Golden Hour's wheel on the header, the quests pager and the week's chest bar (both below, "The quests pager and the Golden Hour"), fifteen job rows, each wearing its own painting `collect/job_<id>` (`JOB_ART`) under `collect/job_frame` (row one's frame, window cut out; `collect.JOB_WINDOW` is the painting's visible part, which the mastery ceremony shows in its own frame), optimistic COLLECT; each row's mastery track fills toward the next threshold and its three markers read reached / next / after from `job.mastery`. While a server event is live, the event band (`collect_events.png`; the layout's `event_band` group) sits under the header and moves the quests panel, everything on it, the chest bar and the list down 161 -- the band's 147 and the painting's 14-unit gap: the event that ends first, its name, what it is worth to this lord (`effective_bp`: "+50% for you", a loss in red), "· N more", and its time left counted down from the snapshot's adoption (`GameState.live_age_s()`); a tap lists every running event and the next to come. With nothing live, or only upcoming ones, there is no band and nothing moves. `LiveEvents` (`scripts/ui/live_events.gd`) is the one reader of `snapshot.live` -- the band, the COURT tab and the rail's seal |
| Inventory | `inventory.gd` | `items` | equipped gear (tap to unequip), rarity chips, the bag's size, item grid (gear anyone wears is left out): EQUIP, then SELL and FORGE side by side; the sliders button (WALL) opens the Collection page. At the bag's cap, while the Quartermaster can still be bought, MORE ROOM (the Inventory's own EQUIP plate) sits right of the count and opens the Royal Store at its Comforts (`Armory.open_store`, `StoreView.open_at("comfort")`). Any `inventory_full` refusal through `GameState.act` fires `GameState.armory_full`, and the shell answers with `Armory.refused`: the dialog with MORE ROOM and OK, or OK alone once the room is owned |
| Shop | `shop.gd` | `shop` | six offers on the 5-minute window with each one's stat and Power, reroll for diamonds, at most `rerolls_per_day` (20) on the lord's day (dimmed when it cannot be paid or the day's are used: `shop.reroll_state`; the confirm says how many are left), Diamond Goods (titles, captions and amounts are the store's; buying goes through `scripts/ui/goods.gd`, as the energy pill's "+" does) |
| Army | `army.gd` | `army` | might, hero support, a sideways-scrolling row of every soldier slot with the next one to unlock after it (a tap selects; a drag never does), selected soldier (gear, and the wave-7 trio HUNT / REROLL / DISMISS with the soldier's own state above them -- IN THE YARD, a road and what is left of it, or AT THE GATE; the name at one size to its box, EMPTY SLOT too, and the tier chip a nine-patch that follows the name at the painting's 12-unit gap and grows with its word, never pinned after a title of varying length), recruit cards with the tier range; the painted (i) shows every type's published odds. REROLL opens `scenes/army/reroll_panel.gd`: one roll per request (`POST /v1/army/reroll`), or AUTO ROLL until a chosen tier, only while the game is on screen |
| Attack | `attack.gd` | `fight` | a scrolling flow: REVENGE lists one card per raider then the other targets, TARGETS the targets alone, each with an empty state; the history says raids made and raids suffered; View All opens the history page, the notice's (i) the rules page. Every figure on a card (take, rate, energy) is the server's |
| Kingdom | `kingdom.gd` | `house` | in a kingdom: identity (the name shrinks to 26 points, then is cut with an ellipsis, clear of the quill: `UI.fit_line`), renown/treasury/members, the reputation card (each rank draws its own hexagon, `kingdom/rep_hex_<n>` unlit and `_lit` for the rank held, the four words in type) and the REALM / LORDS / WORKS / RANKS tabs; Works and the Realm panel draw each work's own scene `kingdom/work_<id>` in the `kingdom/work_frame` nine-patch (`scenes/kingdom/kingdom_section.gd`; LORDS carries join requests, the king's OPEN / BY REQUEST choice and MANAGE). With none: the hall (`scenes/kingdom/kingdom_hall.gd`, cut from `kingdom_hall.png` and laid out in the painting's own units from x 0, y 462) -- the painted search box, headings set in type on the painted plaques (INVITATIONS (5), SEARCHING…, RESULTS FOR "x"), invitation cards (always with DECLINE), kingdom cards, OR and the founding card at a fixed painted pitch, every button the one its card's `action` names in Cinzel small caps. Plate text (`_plate_words`, `_plate_text`) is one line if it reads, else two inside the border, never cut; a figure keeps its unit, falling back to the short form ("1.23B renown"). The page is three layers (`_top`, `_realm`, `_hall`); show and hide the layer, never a node in it |

**The TREASURY card** (`family.gd`, the `treasury_card` template in
`layout/family.json`, cut from `family_treasury.png` by
`art/slices/family_treasury.json`). The bank used to be a ledger row between
the eleventh upgrade and the first holding, in the kingdom's castle, its vault
on an upgrade's level line: easy to miss, and nothing said bank. The owner
painted its card under the STOREHOUSE; it is cut and laid out the way the
STOREHOUSE's is, so the two read as a pair: gold waiting, gold kept. The
STOREHOUSE stays where `family_storehouse.png` put it (the new painting draws
it 29 shorter); the treasury card is placed by the new painting's gap, its
hairline 11 under the STOREHOUSE's (9 between the crops), and the TALENTS /
DEEDS / ROAD strip 7 under it (again 11 hairline to hairline). The frame
(`family/treasury_card`, 761x252 drawn 748 wide as a nine-patch) is the painted
card with its scene and column cleared to the panel; its left side is its right
side turned over, because the painted scene runs into the left corner
ornaments. The vault's states came, like the storehouse's, smaller than the
card's scene (241x139 against 360x236) and are never drawn up, so the window
is a state at its own size where the STOREHOUSE's window starts:
`family/treasury_window` (the shut vault's frame, its opening cleared) over
`family/treasury_empty|half|full` -- shut and barred with nothing in the vault,
half open on a modest pile with some, wide open and spilling from three full
storehouses' worth (`family.treasury_picture`: `player.treasury` against three
times the storehouse view's `cap`, `TREASURY_FULL_STOREHOUSES`; presentation
only, nothing is computed from it). The painted title (`family/treasury_title`)
and marks (`family/treasury_icon_vault`, the keyhole shield, held to its rim off
the small plate it was painted standing on; `family/treasury_icon_coins`) sit at
the painting's offsets in the column, which keeps its rows and stretches its
two EMPTY plates (STOREHOUSE's timer plate) into the width the smaller window
leaves: the vault's gold with "in the vault" after it on its baseline (fitted
inside the plate like the storehouse's pair, `family._fit_pair`), and "On hand"
with the purse. Under the window, on the buttons' row, the plate STOREHOUSE
says HOLDS 8H on says RAID-PROOF. DEPOSIT and WITHDRAW are the painted plates
(`family/treasury_deposit|withdraw`) with their words lifted and set in type at
the painted cap heights (20 and 19), as COLLECT and TO VAULT are, raised for the
fee under DEPOSIT and FREE under WITHDRAW; each opens the treasury page ready
for that move. Its figures are the snapshot's -- `player.treasury`,
`display_gold()`, the storehouse view's `treasury_open`, `treasury_fee_bp` and
`cap` -- so a deposit on the page or the storehouse's To Vault shows on the card
the next frame. Below the vault's level (`bank`, 8) the picture, the shield and
DEPOSIT are dimmed and the plate under the window says "Opens at level 8" in
gold; WITHDRAW stays lit while gold is banked (a Legacy can put a lord back
under the level), and a tap that cannot be done says why instead of opening the
page (`tests/family_treasury_card.gd`).

**The quests pager and the Golden Hour** (`collect.gd`, `collect_events.png`,
Wave 3). Everything the Wave 3 painting puts in the Collect column is cut from
it and drawn down 762/773 to stand on collect.png's edges (x 166..928); the
layout's notes give the mapping. Under the header, `collect/week_panel` (y 286,
292 tall): its heading and its two page dots are lifted and set live, and its
three painted tiles keep their empty plates. The panel is a pager of two pages
-- TODAY'S QUESTS (`/v1/quests`, claimed through `GameState.act` as before) and
THIS WEEK'S QUESTS (`/v1/weekly`) -- the lit dot (`collect/page_dot_on`) the
page shown; a tap on the heading's right (`quests_flip`) or a sideways drag on
the tiles (`quests_touch`, one touch area: a drag of 70 turns the page, anything
shorter taps the tile under the finger) turns it, the tiles' marks and words
sliding out and back. Six weekly tasks do not fit three tiles and the painting
gives the pager two dots, so the week's page shows the three that most need the
lord (`QuestTile.weekly_order`: one to claim, then the open ones, the claimed
last) and its heading, with the event band's gold chevron after it, opens the
whole week (`weekly_page.gd`). The heading's line is "Resets in 14:26:38" or
"Ends in 3d 14h" (the week's `ends_in`, counted down from its answer). Every
tile is painted by `QuestTile` (`scripts/ui/quest_tile.gd`), the one painter
for a quest on a tile: its mark at its own size where the painting drew each
tile's (`icons/quest_scroll_lg|bolt_lg|swords_lg`, cut from these tiles; the
market's tent drawn down for a buying task), what it asks on the name plate (a
day's from its id and target, a week's its `short`), the painted gold
(`collect/week_bar_fill`) and "7 / 20", TAP TO CLAIM or CLAIMED on the progress
plate, and on the gold plate a day's experience and gold, or a week's first
reward and its points beside the bar's own marker (`collect/chest_marker`),
centred as a pair and shrunk together. A week's task is claimed with `POST
/v1/weekly/claim {slot}` -- no `action_seq`, the answer's `weekly` taken and its
snapshot adopted through `GameState.adopt_async`. The week's dot carries what
waits in the week (tasks to claim, chests to open) in the rail's bubble, and the
rail's Collect bubble counts `badges.weekly` with the day's quests.

Under the panel, the week's chest bar (`week_bar`, y 578..712): the empty
channel (`collect/week_bar`, the painted fill and the chests' feet covered with
its own clean stretch), the fill (`week_bar_fill` as a nine-patch along the
channel, its rounded head kept), and the three chests (`collect/chest_bronze|
silver|gold`, each cut along its outline and its feet traced against the fill,
so the fill shows round them and never through them) with the markers and a
plate under each. The fill reaches each painted marker exactly as the week's
points reach that chest's `at` (`bar_fraction`: in proportion between markers,
full once every chest is reached); a plate says "80 POINTS", OPEN (Cinzel, the
chest breathing) or OPENED (the chest stepped back). A ready chest opens with
`POST /v1/weekly/chest {tier}` and plays `Ceremony.chest`; any other chest opens
the week. The job list starts at 712, its first row at 720, where the painting's
first row stands.

The Golden Hour's wheel (`golden`, from `collect_events.png` at its painted size
and x, laid on collect.png's header 5 higher than painted, its plate 11 higher
on it so its foot clears the panel): `collect/golden_wheel` is the wheel dark
(the painting's dark right half mirrored, the hourglass as painted) and
`collect/golden_wheel_lit` its twelve cells lit (the painting's lit half
mirrored, only the band of cells), drawn over it by a radial
`TextureProgressBar` about the ring's centre (the `lit` part's `centre`),
counter-clockwise from the top as the painting's half-lit wheel is -- to
`snapshot.frenzy.meter` while it fills, and burnt back clockwise from the top as
`ends_in / duration` while it burns. The plate says "Golden Hour" while it
fills, the time left and the energy it still doubles ("0:42", the pills' bolt,
"34") while it burns, with the ceremonies' sunburst breathing behind the
wheel, "Ready in 24m 10s" between hours and "3 of 3 used" when the day's are
spent (the wheel dimmed); hidden below `unlock_level`. It only ever shows what
the last answer confirmed: between answers its clocks count down from the
snapshot's adoption, and a meter left alone empties at `drains_in`. A collect
answer's `frenzy_started` and `frenzy_gold` reach it through
`GameState.golden_hour(gold, started)`: GOLDEN HOUR in gold Cinzel rises beside
the wheel, under the header's subtitle, and "+1,234" rises from the plate over
the ceremonies' coin burst. A tap on the wheel says its rules in the server's
numbers (`golden_rules`).

Unlock levels come from the server's `sections` on `/v1/state`, and whether a
tab is open is its `unlocked` flag (a kingdom member keeps the Kingdom tab).

### Pages over the game

Everything that is not one of the seven screens is a **page**: `scripts/ui/sheet.gd`
(`Sheet.open(host, title, subtitle)`), the dialogs' plate as tall as the phone
with a body that scrolls and a foot for buttons, on its own CanvasLayer. The
pages live in `scenes/pages/`:

| Page | Opened from | Reads |
|---|---|---|
| `profile_page.gd` | the rail portrait | YOUR LORDSHIP, a painted page (`profile.png`): the lord's face in the ring with their worn frame (a tap opens `face_picker(host, changed)`), the name plate with the rename quill and its price, the ribbon with the worn title in the worn colour or the level in gold, three plates -- level, might (`/v1/army`), the kingdom's name or its tag or "No kingdom" (`/v1/kingdom`) -- each figure between its icon's ink and the plate's inner edge, and the crest; all through `Look.mine()`. Seven painted rows, each with its icon and the gold chevron: ROYAL MAIL (the waiting count in the red badge, 9+ past nine), SPLENDOUR, THE CROWN'S FAVOUR, RANKINGS, ACCOUNT (sign out; `POST /v1/account/delete` with the password and `delete_words`' purchase warnings), REDEEM A CODE, INVITE A FRIEND. FRIENDS, SETTINGS and the toggles wait for Wave 6 |
| `redeem_page.gd` | the profile's REDEEM A CODE | `POST /v1/promo/redeem {code, device}`. A painted page: the field keeps only A–Z and 0–9, upper-cased, as the server does; REDEEM is dimmed until 4–20 characters and single-flight; the gift arrives as a letter, shown as one centred block of `Art.reward_line_icon` rows with a way to the mail; every refusal (`promo_invalid`, `promo_used`, `too_many_attempts`, `no_device`) in the page's own words |
| `invite_page.gd` | the profile's INVITE A FRIEND | `GET /v1/referral`, `POST /v1/referral/claim {code, device}`. A painted page: the lord's six letters and COPY, the terms from the server's numbers, the friends brought (faces, looks, rewarded), and while `can_claim` the field for a friend's code with the time left; refusals in the page's own words |
| `leaderboard_page.gd` | the profile page | `GET /v1/leaderboards/{board}`. A painted page on `rankings.png`: two TabStrips -- the period (THIS WEEK / SEASON / ALL TIME) and, inside it, the boards that period keeps (RAIDS / EXPERIENCE this week; RENOWN / RAIDS / EXPERIENCE / MIGHT this season; MIGHT / LEVEL / WEALTH for all time), from the answer's own `boards`. A closing board says when it closes and what its places pay, from `rewards`; lords level on it share a place. The top three sit in the podium's silver, gold and bronze rings as round faces with their worn frames; ranks 4–100 scroll, each name in its worn colour with the worn title (or level) under it; YOUR RANK is the asker's place or "—" |
| `deeds_page.gd` | the Family's DEEDS card, the Victory Road's DEEDS tab, `--page deeds` | `GET /v1/achievements`, `POST /v1/achievements/claim`. See the Court table below |
| `festival_page.gd`, `hourly_odds_page.gd` | the Events page's VIEW and its ROYAL HOURS strip | `GET /v1/festivals`, `POST /v1/festivals/claim`. See the Court table below |
| `daily_page.gd` | the diamond pill while its dot shows, and on arrival when a reward waits | `GET /v1/daily`, `GET /v1/weekly`; `POST /v1/daily/claim {mend?}`, `POST /v1/weekly/chest {tier}` -- none sequenced, answers through `GameState.adopt_async`. DAILY REWARDS, a painted page (`calendar.png`, layout `calendar.json`; see "The calendar" below) |
| `weekly_page.gd` | Collect's THIS WEEK'S QUESTS heading, a week's tile still open, a chest not yet ready (`--page weekly`) | the week the tab holds (`GET /v1/weekly`); claims go through the tab (`claim_weekly_task`, `open_chest`) so the tab, its dot and the page show one week. THIS WEEK'S QUESTS on the Sheet: "Ends in 3d 14h · 120 of 240 points", the six tasks three to a row, each under its name in gold on `collect/week_tile` painted by `QuestTile` (a done one claims on a tap), and THE WEEK'S CHESTS -- the tab's chest bar and under each plate what the chest holds, each line its picture and the server's words |
| `stats_page.gd` | Family's stat strip, the level-up ceremony | `snapshot.prices.stat_gains`; `POST /v1/stats/spend`. A painted page (`stats.png`); SPEND is always shown, dimmed until points are placed |
| `treasury_page.gd` | the Family's TREASURY card: DEPOSIT and WITHDRAW open it with `{"mode": "deposit"|"withdraw"}`, its amount already the whole purse or the whole vault | the estates view's `treasury`; deposit / withdraw. A painted page (`treasury.png`); DEPOSIT stays, dimmed, while deposits are closed |
| `item_picker.gd` | a gear tile (Family, Army) | `/v1/inventory`'s `equipped_on`, `worn_by`, `power` |
| `collection_page.gd` | Inventory's WALL | `GET /v1/collection`. A painted page (`collection.png`): each of the 21 rarity frames is one slot and tier, showing the grandest design held (dark if none) with an n/3 count, gold when whole; a tap lists its three designs ("?" for unheld); the luck plate carries what the wall adds up to; the offers keep the filter and DONATE flow as rows cut from the painting |
| `history_page.gd` | Attack's View All | `GET /v1/attack/history`. A painted page (`history.png`): ALL / MY RAIDS / ON ME, a TabStrip of the short plates standing where the painting's own did (see Tabs), filter the list; each row is the painting's own row for its outcome (gold swords won, red sword lost, silver shield held, red gauntlet raided), the opponent's name in their `opponent_look` colour, the gold in its short form when the full figure will not fit |
| `rules_page.gd` | Attack's notice | the Attack view's `rules` |
| `away_page.gd` | arriving, or coming back from the background | `GET /v1/away?since=`. A painted page (`away.png`); TAKE REVENGE only when someone can be answered (it lands on the revenge view), CONTINUE centred otherwise |
| `road_page.gd` | the Family's ROAD card; `--page road` | `GET /v1/road`; `POST /v1/road/claim {}` or `{index}` -- not sequenced, the snapshot through `GameState.adopt_async`, the lines as the Royal Delivery ("VICTORY ROAD"). VICTORY ROAD, a painted page (`road.png`; see "The Victory Road" below) |

The painted full-screen pages (treasury, stats, away, history, collection,
rankings, the Victory Road) use one host, `scripts/ui/painted_page.gd` (`class_name PaintedPage`:
`open(host, page_id, opts)`, `closed`, `node(id)`, `set_text`, `on(action, fn)`,
`set_enabled` by action or part id, `set_shown`, `place`, `content(scroll_id)`,
`field(...)` a thumb-high text field). The layout, `client/layout/<id>.json`,
has an element `page` holding the whole painting with its live plates erased;
buttons are their own crops (a button that is ever hidden is erased from the
painting); `"stretch": [[y, h, weight]]` names bands of rows that are the same
all the way down, which take a taller phone's height in proportion to their
weight (each drawn in whole units, one unit overlapping the next, so no seam
shows in the gold); `"ground"` is the colour behind the notch, fading into the
painting. Painted slices carry the meta `page_slice`, which is how
`pages_fit.gd` leaves them to `painted_pages.gd`. A list the painting shows as
rows is erased and filled from the page's flat outside ground (x 2–20): the
columns beside the rows carry their shadows and would stripe it. Live rows are
Layout templates in a scroll region; set the `box_w` meta from the template's
rect before fitting text, since a Label has already grown to its sample.
`set_text` balances wrapped text (`UI.balance_lines`, over `UI.wrapped_lines`):
the narrowest width that keeps the same number of lines, the label narrowed
around its alignment inside its box, so no line ends on a lone word when an
even break exists; the box is remembered in `box_w`/`box_x`, so every set starts
from the whole plate. History rows draw their opponent with `Look.paint_name`.

**The calendar** (`daily_page.gd`, `calendar.png`). Twenty-eight squares, a
crown square ending each week, all the server's (`GET /v1/daily`): the page
draws, it never decides which day is today or what a square gives.
`calendar/page` is the painting with the grid, the BROKEN row, the chests, the
bar's fill and CLAIM lifted (refills from the page's own clean band, rows
1142-1156). The 24 plain squares sit at the painting's rows (548, 699, 850,
1001) and its columns evened to one pitch (50 to 653); each is
`calendar/square` with its EMPTY plate, the picture its `kind` names
(`calendar/icon_diamond|purse|flask|scroll|cart`, the painting's own, keyed
off a square's interior from one box so each sits where it was painted), and
its amount on the plate -- diamonds in their blue, a purse's gold short in gold,
flasks and writs as ×N. The square a claim takes (`state` today) is
`calendar/square_today` at (-2,-1) with `calendar/today_glow` behind it; a
taken one wears `icons/tick_seal` (the same wax as the painting's seal) over
its picture darkened to 0.6. The crown squares stand on the same rows, drawn
whole from 18 above (`calendar/crown_title|frame|gear|crest`, chosen by the
square's prize line: a `title:` icon, a `frames/` one, an `icons/crest` one,
gear), their plate the diamonds that come with the prize (`+25`); today's wears
the glow as a nine-patch. A tap on any square toasts its lines ("Day 14,
today: 30 diamonds, Loyal Vassal (frame)"). The header plate says "DAY 6 OF 28
· 33 DAYS IN A ROW", "COME BACK TOMORROW FOR DAY 7" or "THE STREAK IS BROKEN · 1
DAY MISSED". While `broken` is set, the painting's row shows: the BROKEN
ribbon, RESTORE with `restore_diamonds` on its plate (red when the purse is
short), USE PARDON (on only with `can_pardon` and a pardon held, the pardons in
the rail's count bubble on its corner -- placed below the stretch band at 1142,
so on a tall phone it moves with the row instead of being left in the band's
gap) and START ANEW (asked first); the ribbon keys off the page with a floor of
16, the page's own grain, so no box of the painting's texture follows it down a
tall canvas (both in `tests/calendar_page.gd`); otherwise
the row says "ROYAL PARDONS 1 OF 2" and what a pardon does. CLAIM (the
painting's) shows while a plain claim can be made; otherwise CLOSE, the navy
plate with its word in Cinzel, stands in its place. THIS WEEK is the weekly
quests' chests (`GET /v1/weekly`): the points on the painted plate, the fill
(`calendar/week_fill`, caps held) along the channel 201-825 with each
threshold on its painted marker (80 at 451, 160 at 637, 240 at 832 -- the bar
only places the server's points, `bar_fraction`), the markers
(`calendar/marker`) over the fill, each chest dim until reached, bright and
rising and falling while it can be taken, sealed once taken. A claim or a
chest plays the Royal Delivery with its lines ("Day 14", "The silver chest").

**The Victory Road** (`road_page.gd`, `road.png` + `road_map_1..3.png` +
`campaign_nodes_sheet.png`, layout `road.json`). The fifteen milestones the
server pays for levels 3 to 60 (`GET /v1/road`), on a road that climbs from the
fields to the castle. `road/page` is the painting's frame, DEEDS and CLOSE;
its tabs and its whole map window (and the level plate on it) are refilled to
the page's panel, and CLAIM is lifted to its own crop so it dims while nothing
waits. VICTORY ROAD / DEEDS are a TabStrip on the painted row (DEEDS dimmed, a
tap on it toasting "The Deeds open soon", until Wave 4). The window is a scroll
of the three node-less maps stacked 2970 tall (map_3 at the top, each map's
faded foot 60 rows over the next map's misty head: `road/map_2|3` are cut with
a feathered foot). The maps are a `map` kind, 776 wide, drawn 1:1: the window
is narrowed to them (the painting's was 855) and framed with the painting's
reward-box rim as a nine-patch (`road/window_frame`), and a taller phone grows
it through the page's stretch band. The milestones stand where the layout's
`nodes` say -- measured on the maps: every row's run of road colour, tracked
and smoothed into the `centre` line, then fifteen places at even steps along it
that keep every shield off the gate and the two bridges (`landmarks`) -- each
with its reward box on the side the road bends away from. A milestone is the
`milestone` template: `road/shield_ahead` (steel) until reached,
`road/shield_current` (gold in its halo) while its reward waits,
`road/shield_reached` once claimed (the three drawn down to half off the nodes
sheet, their discs' centres at one point), the crown in the disc for 20, 40 and
60, and "LV 20" on its plate. Its box (`road/box`, the painting's closed-chest
box with the chest lifted, a nine-patch) holds a tile per line -- the reward's
picture (`Art.reward_line_icon`, drawn down, never up; rolled gear on its
velvet through `ItemGround.for_line`) over its amount (diamonds as their
number, a count as ×N, one thing as nothing) -- dims while ahead, and wears the
tick seal once claimed. The marching lord (`road/lord`) stands on the highest
milestone reached; the page opens with his milestone in the middle of the
window. The painting's EMPTY level plate floats at the window's top left with
the lord's level. A tap on a waiting milestone (or its box) claims just it; on
any other it lists its lines in a notice ("Reach level 25 to claim it.").
CLAIM takes every one waiting. A claim plays the Royal Delivery titled
VICTORY ROAD and sets the heartbeat's `road` count at once, so the Family's
ROAD card follows.

A Sheet can wear a painted scene at its head: `Sheet.open(host, title, subtitle,
layer, screen, header)` draws `pages/header_*` inside the plate's 8-unit frame,
1:1 (the scenes are 865 wide, the plate's inside), the title rising 26 units
into the scene's painted fade; `Sheet.header_art` does the same for the reroll
panel (drawn down to 0.906). The rules page wears the desk, the recruit odds
the tent, the gear picker the armoury, the reroll panel the training yard.

The sign-in screen (`scenes/auth/auth.gd`, `auth.png`) is one scene that the
keyboard lifts until SIGN IN clears it; on a tall phone the painting's foot sits
on the screen's foot and the extra height above is each column's colour from
the painting's top rows, smoothed across the sky window only and faded down 48
units into the painting, darkening toward the notch.
Sign in with Apple's OR and plate are cut and hidden (`APPLE = false`, which
also closes the fields up inside the panel); TERMS and PRIVACY open `/legal/*`.

### Tabs

Every row of tabs is one component, `scripts/ui/tab_strip.gd`
(`TabStrip.make(ids, rect, first, max_scale)`), drawn from the painted plates
cut by art/slices/tabs_sheet.json: the long plates `tabs/<id>` and
`tabs/<id>_lit` (about 4:1, tabs_sheet_a/b.png) and the short ones
`tabs/short_<id>` and `tabs/short_<id>_lit` (all 254x80, about 3:1,
tabs_sheet_c.png: RAID, ARENA, CAMPAIGN, BOUNTIES, REALM, LORDS, WORKS, RANKS,
CHAT, BOSS, WAR, HELP, ALL, MY RAIDS `my_raids`, ON ME `on_me`). The word is
painted on every plate; nothing is set in type over one. A strip of three or
more whose words all have a short plate draws the short ones
(`TabStrip.takes_short(ids)`, `TabStrip.plate_name(id, short)`): four long
plates abreast shrank to 0.54 and their words went thinner than the paintings'.
A strip of two, or one with a word the short sheet lacks, draws the long ones;
a strip never mixes the two. Each short crop is centred across on the midpoint
of its plate and its word, its plate's foot 2 units above the crop's floor, so
lighting a tab changes its colour and nothing else and every plate stands on
the rule.

The rect's floor is the painted rule the plates stand on; the plates are laid
out evenly, the outer two on the row's edges, at the largest size that fits the
row and never drawn up, so a row of two (Attack) is larger than a row of four.
`max_scale` caps the size further where the painting draws its plates smaller
than the row allows. Every tap area is the rect's full height (give it 95, a
thumb) and its share of the width. A tap lights the plate and emits
`changed(id)`; a tab that is off is dimmed and ignores taps; a count shows in
the rail's own bubble. The rows are instance-less `tabs` entries in their
layouts that the screen's code builds; an optional `plate_h` is the plate height
the painting gives, passed as `max_scale = plate_h / 80`. Where the short
plates stand: the Kingdom's REALM / LORDS / WORKS / RANKS (rect 151,520 780x95,
floor on kingdom.png's gold rule at 615: 190x60 at 0.75, the painting's 16-unit
words) and the battle history's ALL / MY RAIDS / ON ME (rect 142,499 657x96,
floor at 595, `plate_h` 66: 209x66, the painting's 15 between and its 18-unit
words; history.png's own plates, which spell MY RADS, are refilled out of
`history/page`). Attack's RAID / ARENA / CAMPAIGN / BOUNTIES take them since
Wave 5 (rect 183,258 738x95, floor on attack.png's gold rule at 353: 178x56 at
0.709, the painting's own band), with RAID's own REVENGE / TARGETS directly
under it (183,357 738x95, the long plates at their painted 355x88, floor 452)
and the flow starting at 463 -- the painting's own eleven units under a rule.
The Kingdom's CHAT / BOSS / WAR / HELP take them since Wave 6, a second row
directly under the first (rect 151,621 780x63, its plates standing on 684, six
units under the first row's rule): one strip is lit at a time, and a strip that
is not the row you are on is put out with `unlight()`. A tab that is off but not deaf uses
`set_off(id, words)`: it dims and answers the tap with `refused(id, words)`,
because a plate that swallows a finger reads as a broken screen (CAMPAIGN, and
a sub-tab under its level). Attack's REVENGE / TARGETS, the rankings, the wardrobe and
VICTORY ROAD / DEEDS keep the long plates. A script that uses the
`TabStrip` class cannot be compiled from a `--script` test before the autoloads
exist: `load()` it at run time. The rail's lit cells for the eight-entry rail
are cut as `nav/<id>_lit` (art/slices/rail_lit.json), waiting for Wave 2.

### The Kingdom's second row, the hall and the help (Wave 6)

The Kingdom tab carries TWO strips (`tabs` and `tabs2` in `layout/kingdom.json`)
and everything the painting puts under the first row's rule is moved down by
`ROW2_SHIFT` (70). REALM, LORDS, WORKS and RANKS are what they were; CHAT and
HELP are their own scripts, named in `kingdom.gd`'s `SECTION_SCRIPT`; BOSS and
WAR stand dimmed with `set_off` until their waves.

- `scenes/kingdom/chat_section.gd` -- THE HALL, from chat.png. Built in code
  from the painting's own objects (`art/slices/chat.json`: the day's rule, a
  lord's plates and bubble, the realm's horn and scroll, the bar), because a
  hall is a list of rows whose heights depend on what was said. It is the one
  section that FILLS the page rather than growing down it: `fill_height(h)`
  gives it the room from under the strips to the foliage, the room scrolls
  inside it and the bar stands at its foot, where the painting puts it. A
  bubble's height is measured with `get_multiline_string_size`, never a Label's
  own minimum, which is one line however it wraps.
- `scenes/kingdom/help_section.gd` -- the day's shared goal and the calls for
  aid, from help.png. The chests on the goal's bar are the scene's own paint;
  what is live is the bar, its knobs at the balance's thresholds and the plates
  that name them.
- Both listen to `Realtime` while they are open (`listen()` / `hush()`) and poll
  when it is not there (`Realtime.polling()`): a feature that is only live is a
  feature that is broken on a train.

`--tab kingdom --sub chat` (or `--sub help`) opens one from the command line.

### A lord's page, the roll and the settings (Wave 6)

- `scenes/pages/rival_page.gd` + `layout/rival.json` (rival.png) -- what one
  lord may see of another. The face is drawn UNDER the crowned frame whose
  window is opened (`rival/portrait_hole`); each soldier is drawn under its own
  ring crop (`rival/ring_1..5`, cut where that ring stands, because the page's
  ground is not flat across it), and the head-and-shoulders band of the
  soldier's card is taken with an `AtlasTexture` so a square painting shows
  round. The numbers the spyglass buys are the kit's chip across the foot of
  each ring, and nothing else on the page carries a figure.
  `--page rival --lord <id>`.
- `scenes/pages/friends_page.gd` + `layout/friends.json` and
  `scenes/pages/settings_page.gd` + `layout/settings.json`, both built on YOUR
  LORDSHIP's own empty page (`profile/page`) from the pieces profile.png
  already has: the friend's row and its GIFT plate, the hub's row plate, and
  the painting's own switch (`profile/toggle_on` / `toggle_off`), which is how
  every yes-or-no in the realm is drawn. `--page friends`, `--page settings`.
- The hub's seven rows are now the painting's own seven words (FRIENDS,
  WARDROBE, RANKINGS, SETTINGS, ACCOUNT, REDEEM A CODE, INVITE A FRIEND); the
  Royal Mail and the Crown's Favour are reached from the COURT, where their
  cards are, and FRIENDS wears the painted badge for the lords waiting.
- `scenes/pages/rules_of_the_hall.gd` + `layout/chat_rules.json` -- the page a
  lord agrees to before they may speak. The rules come from the balance with
  the room, and `GET /v1/chat/rules` reads them again for the settings' row.
  `--page hall_rules`.

### The Attack tab's sub-tabs (Wave 5)

The Attack tab is four bodies on one painted header, and what shows is decided
PER LAYER, never per node -- the rule the Kingdom tab learned the hard way.
`scenes/tabs/attack.gd` keeps RAID's own body in `_raid` and mounts a sub-tab's
into `_sub_host`; `open_sub(id)` frees one and builds the other. The bodies are
their own scripts with their own layouts, because `Layout.build` takes one
screen name and three paintings' elements in one layout would draw on top of
one another in every test that builds a layout raw:

- `scenes/attack/arena_view.gd` + `layout/arena.json`, cut from arena.png and
  laid **130 units higher than painted** (arena.png's tab rule stands at 483,
  attack.png's at 353);
- `scenes/attack/bounty_board.gd` + `layout/bounties.json`, cut from
  bounties.png and laid **74 higher** (its rule is at 427 -- the two paintings
  do not agree, and the design pack's draft manifest had copied arena's tab
  rects into bounties');
- `scenes/attack/campaign_view.gd` + `layout/campaign.json`, the Conquest
  Campaign (Wave 7). Its body is not a painted screen at all: it is one of the
  ten MAPS (`campaign/map_NN`, 776x1030, cut whole and unscaled) with the
  twelve nodes of a chapter standing on the road painted in it. Where each node
  stands is **measured, not placed**: `scripts/campaign-road.py` seams the road
  out of each painting and writes twelve points per chapter into
  `client/layout/campaign_nodes.json`, in the painting's own pixels; the view
  adds the map's own corner and nothing else. A node is hung on the middle of
  its painted RING (each template carries its own `centre`), so the glowing one
  -- a bigger picture of the same ring -- lands exactly where the plain one did.
  `art/qa/campaign_nodes.png` is that measurement drawn back onto the maps.

Each body is a `Control` with `signal grew(height)`, `refresh()`, a public
`paint(data)` for tests and captures, and `height()` so the tab lays its
foliage under it. `--sub <id>` opens one from the command line, on any tab with
`open_sub` (the Kingdom's four sections have it too).

### The roads, the anvil and the tree (Wave 7)

Three of the wave's four surfaces are not new screens: they are a verb added to
a painted one.

- **HUNT** is the Army tab's own painted plate, which `army.png` has always had
  and nothing used. The selected soldier's column now carries three plates --
  HUNT, REROLL, DISMISS, each a thumb's 95 units -- where the painting had two;
  the third wears the dialogs' quiet plate at the painted one's size, and the
  painting's troop count (a bar that read 320/320 whatever happened) is erased
  out of the crop to make the room. HUNT's word is the soldier's state: HUNT in
  the yard, AWAY on a road, BACK at the gate. `scenes/pages/hunt_page.gd` is the
  roads themselves -- a **PaintedPage** since `expedition.png` was cut: four
  painted cards on the painting's own grid, the chosen one wearing its glow,
  with the server's own ranges on each -- gold and experience, already resolved
  for this lord, never the wages the balance is written in. Under the level the
  hunt opens at, every card wears the painting's padlock and SEND is out, because
  the Army's HUNT stands on every soldier from the first. A soldier away wears
  AWAY on their card in the strip and is drawn back.
- **FORGE** is the inventory card's second verb: SELL and FORGE side by side,
  each 100x96. Which three pieces go in is the SERVER'S offer (`ItemView.forge`
  carries the three ids, the rank that comes out and the fee), because the fee
  follows the best mark of the three and choosing them is part of pricing the
  work. The tap opens `scenes/pages/forge_page.gd`, a **PaintedPage** cut from
  `forge.png`: the three pieces on the anvil's sockets drawn as the Armory draws
  a piece (the tier's ring, the tier's cloth, its own painting), the rank that
  comes out as its ring and badge on its cloth, the fee beside the painted coin,
  the masterwork chance on its plate, and the painting's round **i** for the
  whole rule in words.
- **TALENTS** is the Family strip's own card, painted since Wave 4 and dimmed
  until now. `scenes/pages/talents_page.gd` is the tree, a **PaintedPage** cut
  from `talents.png`: one great oak, three banner columns, fifteen painted
  medallions on the painting's own grid, and under each a row of pip sockets
  with one amber gem per rank bought. The painting shows the medallion in BOTH
  its states -- it lights the top two of every column -- so both rings are cut
  and one of the two is always drawn; a tier the lord has not opened is drawn
  back whole, face and ring together. The painting has no room for words beside
  a medallion and is right not to: a tap says what the rank is, what it is worth
  in its bucket's own units from the server's `per_rank`, and buys it.

### The beast and the war (Wave 8)

Both are **sections of the Kingdom tab**, under the two rows of chips, built in
code beside CHAT and HELP (`SECTION_SCRIPT`): `scenes/kingdom/boss_section.gd`
from `boss.png`, `scenes/kingdom/war_section.gd` from `war.png`. Neither chip
says SOON any more.

- **BOSS.** The panel is cut with its window knocked out (`boss/panel`, a
  polygon `hole`), because the beast changes: the six paintings
  (`bosses_<id>.png`, 771x482) are cut at the window's aspect and drawn DOWN
  into its 728x300 -- the briefs' "paint big, draw down". The name plate and the
  griffin that flank it sit ON the window in the painting, so they are their own
  crops drawn back over whichever beast stands; the griffin is cut once, keyed
  off its own dark sky, and the right-hand one is the same picture turned round
  (`flip_h`), which is what the painting has. The health bar's fill is the
  painting's two rounded CAPS laid side by side and nine-patched across the
  track: the painted fill is 505 long and the track 674, so a crop of the whole
  thing is squashed at any figure under three quarters and the squash shows as a
  seam. The blows a lord still has stand first in gold and the spent ones after
  in steel, the painting's own order. ATTACK's plate is 240x62 and its TAP is a
  thumb's 95, centred on it.
- **WAR.** One crop for the week's banner -- the scene, both shields, the
  crossed swords and the plates are the same every week -- with only what moves
  taken off it: the points bar's two fills (they always meet, so there is no
  empty track to cut), the knob that stands where they meet, and the three
  banners this lord still holds. The ENEMY LORDS panel and the WAR LOG are each
  a head and a nine-patched body, because a kingdom has more lords than the
  painting had room for; one row plate is cut clean with `refill` and every
  piece on it -- face, name, Might, banners, swords, worth, FIGHT -- is drawn
  over it. A routed lord is drawn back, stamped with the painting's own ROUTED,
  and still offered a FIGHT: beating them is worth a quarter, not nothing.

What a lord is worth to beat is the SERVER'S arithmetic, quoted on the card
before the tap and paid by the same function after it. The client works out
nothing on either screen: not the health left, not its fraction, not what a blow
costs, not the points. `client/tests/boss_and_war.gd` holds that, and holds the
blows' order, the banners' order, the taps and the shut doors.

### Court views

The Court's screens -- the Royal Mail now, the Store, the Crown's Favour and
Splendour as they land -- are **views**, not pages: `scenes/court/<id>_view.gd`,
built from `client/layout/<id>.json` like a tab, with a `back_requested` signal,
`refresh()` and a public `paint(data)` for tests and captures. The shell hosts
one over the tab it was opened from (`Shell.VIEWS`, `Shell.open_view(id, data)`,
`Shell.close_view()`): the rail and the pills stay, the tab under it is hidden
and paused, and the back plate goes back to it and refreshes it. Every Court
view with a back plate builds it with `CourtBack.build(view)`
(`scripts/ui/court_back.gd`): the mail painting's plate with its word erased and
the word set in Cinzel 25 by `CourtBack.word_for(view)` -- `COURT_WORD` when the
view lies over the COURT tab, `WORD` ("BACK") over any other. A painted page
closes with its painting's own CLOSE instead.

The COURT tab (`scenes/tabs/court.gd`, `court.png`): the header and six cards,
2×3, each its painting and baked title, a status plate in type and the red disc
(`count_for`, shown only when something waits, 9+ past nine):

| Card | Plate (`status_for`) | Disc | Tap |
|---|---|---|---|
| STORE | the free thing waiting, named (`free_line`: the Stipend's share, Royal Favour's gift, the day's free gift), else the soonest offer's time, else empty | 1 for a free thing | `open_view("store")` |
| ROYAL MAIL | "N letters waiting" / "No letters" | letters waiting | `open_view("mail")` |
| OFFERS | the soonest live offer's time ("Ends in 3h 20m") / "No offer now" | offers not yet seen | `open_view("offers")` -- ROYAL OFFERS, its own painted screen since `offers.png` was cut |
| EVENTS | the festival running ("Harvest Festival · 2d 23h"), else the hour's event, else an operator's ("Job payout +50% · 3h 20m"), else whichever is announced soonest, else "No event now" (`court.events_line`) | the running festival's tasks and milestones waiting, and the hour's gift | `open_view("events")` |
| CHESTS | the Tax Cart from `snapshot.cart` (`court.cart_line`): "2 carts waiting" (a writ counts as one more cart), else "Next cart in 1h 20m" counted down from the snapshot, else "Opens at level 2" in the dim ink | carts waiting + writs (`badges.cart`) | `open_view("chests")` |
| SEASON PASS | the Charter from `snapshot.live.season` (`court.pass_line`): "Tier 12 of 50 · 12d 01h left", nothing before the first season | the Charter's tiers reached and unclaimed | `open_view("pass")` |

The rail's COURT bubble is the sum of the discs (`Shell.court_count`: letters, unseen offers, the free thing, carts and writs, the hour's gift, the festival's and the Charter's).

Wave 4's Court views and pages, in the same shape:

| Screen | What it is |
|---|---|
| COURT ▸ EVENTS (`scenes/court/events_view.gd`, `events.png` + `event_themes.png`) | the hero card (the festival running, else the next announced, else the last to close) with its theme's scene, what it gives this lord and VIEW; two cards for the festivals beside it; the ROYAL HOURS strip (the hour's event, its time and the next hour's, from `/v1/festivals` `hourly`); UPCOMING, the painting's three rows -- the operator's events (running with the hourglass, announced with the calendar) and any festival announced beyond the cards, the spare rows left empty as the painting has them |
| A festival's page (`scenes/pages/festival_page.gd`, a Sheet over the view) | its line (time left, points, place), the day's points against the day's cap, its five tasks on the painted quest tile (`QuestTile.paint_festival`), its milestones in points with CLAIM / TAKEN / NOT YET (the last crowned), CLAIM ALL, its board (ten places and the lord's own), what the places pay, and how points are earned |
| THE ROYAL HOURS (`scenes/pages/hourly_odds_page.gd`) | the published table: every hour's event with its mark, what it does, how long it lasts and its chance of an hour, the hour running marked -- as THE CART'S LOAD lists the cart's odds |
| COURT ▸ SEASON PASS (`scenes/court/pass_view.gd`, `pass.png`) | ROYAL CHARTER: the season's name and clock, the tier medallion and the bar to the next tier, UNLOCK (900 diamonds or the Charter bought through `Billing`) or ROYAL once the lane is open, FREE / ROYAL over fifty tier rows (each tile its reward, CLAIM on one reached, the tick seal once taken, the padlock while the lane is shut), the pedestal with tier 50's frame round the lord's face, and CLAIM ALL |
| THE DEEDS (`scenes/pages/deeds_page.gd`, `deeds.png`) | the DEEDS / VICTORY ROAD strip it shares with the Victory Road, the seven category discs as filters, and a row per deed: its medal (bronze, silver, gold, imperial; the padlock before it is begun, the "?" once it is), its bar and count to the next tier, CLAIM, and the tick seal once all four are taken. A tap opens the deed's four tiers and the title the fourth gives | The shell is in the `"shell"` group, which is how a page
reaches it. `--page <id>` opens a view by its id (`--page letter` opens the
first letter). A view whose script has a `PAGE` constant is a painted page, and
`open_view` sends it through that script's own `open(host, opts)`. The COURT tab
will mount the same views.

| View | Opened from | Reads |
|---|---|---|
| the rail's bubbles | — | `shell.rail_count` / `portrait_count` are the ONE place a `service/badges.go` counter becomes a bubble; the game has no push notifications, so this rail is the telling. COLLECT quests+weekly · ATTACK revenge+campaign · ARMY hunt · KINGDOM requests+chat+aid_calls+decree · COURT `court_count` · FAMILY `family_count` · the portrait mail+friends+gifts. `client/tests/badges_reach_the_rail.gd` names every badge and the bubble it must move. The Kingdom's second row and the Attack tab's strip say WHICH of theirs is waiting (`set_count`), so the rail's total is always resolvable |
| `throne_view.gd` | the Kingdom's throne banner | `GET /v1/throne`. The crowned ring's two plates are the painting's own 225 and 275 units: the emperor's name (or NO EMPEROR, which fits where "THE THRONE IS EMPTY" needed the fitter's floor) and, under it, the kingdom with the reign's clock — or, with the seat empty, WHO LEADS the week's race and when it is decided. Beside DECLARE: the decree and its clock, else "No decree yet", else — with no throne at all — where this lord's own kingdom stands (`my_place`, `my_renown`). PAST REIGNS' four crowns and plates are painted into the panel, so an unused row is bare, not hidden |
| `rules_page.gd` | — | The (i) behind the Attack notice. Every number is the server's `rules`: who may be raided, the rate AND the gold ceiling (`raid_cap`), the ransom, the shield, the cooldown, revenge. No sentence states a rule the server does not send |
| `store_view.gd` | the diamond pill (the calendar while its dot shows), the offer popup, MORE ROOM | `GET /v1/store/court`. A stack of sections cut from `store.png` and `store_2.png` under a fixed header, 10 units apart; a section with nothing to show is left out and the rest close up. Each live offer is its own card (title and timer); diamond packs wear the server's badges and the ×2 FIRST PURCHASE seal while a first purchase still doubles; the daily deals keep their four painted slots (counts always shown, prices struck against `was`, red when the purse is short, slot 3 the cosmetic's own crest, frame or chip, SOLD OUT when absent); what every paid plate says is `StorePrice.words`/`paint` (`scripts/ui/store_price.gd`), in the store and the popup alike: StoreKit's local price; "…" while the App Store has not answered; without StoreKit the catalogue's US price (`usd_cents`) in the muted ink on a plate dimmed exactly as `UI.plate_face`'s disabled plate, under a note that says why and that the prices are in US dollars; OWNED; a patron's time left. Crown Patronage is sold only on THE CROWN'S FAVOUR, which carries 3.1.2's words: the store's patronage plate and card open that page. The Stipend claims through `/v1/stipend/claim`; RESTORE is `Billing.restore()`; TERMS and PRIVACY open `/legal/*`. HERALD'S TIDINGS is the rewarded advert: its two painted boxes carry the server's own words (what one pays) and either how many are left today, when the next may be watched, or the level it opens at; WATCH is lit for exactly one state -- an advert to watch, now. The whole section is absent while `herald.enabled` is false (a realm with no advert to play), drawn but locked while `unlocked` is false. WATCH asks `/v1/ads/watch` for a TICKET and hands it to the AdMob plugin; THE DIAMONDS ARE PAID BY GOOGLE'S CALLBACK TO THE SERVER, so nothing is adopted here -- the purse is read again a moment later. With no plugin in the build, WATCH says so rather than doing nothing |
| `offers_view.gd` | the COURT's OFFERS card; `--page offers` | `GET /v1/store/court`, the Store's own `live_offers` so the two screens can never disagree about what is on sale. Cut from `offers.png`: the merchant's stand as the header, and under it one wide card per offer -- its bundle painted (the painting's three, in its own order), its lines on three reward tiles (a frame drawn as it will be WORN, round the lord's face), the server's seconds on the painted timer plate, and the App Store's own price on the emerald plate (`StorePrice`, never the catalogue's `usd_cents`). The BEST VALUE ribbon is hung on the offer the catalogue badges `best_value` and on no other. The painting's struck **value plate** is NOT drawn: a strike is a was-price and this game has none -- see `art/slices/offers.json`, which records the rect for the day the catalogue publishes one. With nothing on sale the list says so; with no App Store the plates fall back to the catalogue's figures under the dollars note, as the Store does |
| `offer_popup.gd` | an unseen offer (`badges.offers_unseen`), once a session at a calm moment | the live offer that ends soonest (`pick()`); its timer turns red in the last hour; LATER and × close it and mark the offers seen. The plate is cut along its own outline. Layer 80. Its tiles draw each reward large and drawn down: diamonds as the vessel of the largest pack they reach (the layout's `diamond_vessels` ladder, from `diamond_packs_large.png`), potions and charters from their large crops (`tile_art`), a frame round the lord's own face. It also reports a pending (Ask to Buy) or failed purchase |
| `favour_view.gd` | the profile's THE CROWN'S FAVOUR | `GET /v1/store/court`'s `vip` and `patronage`, the patronage product's lines. A `PaintedPage` (`favour.png`, the whole painting; its stretch bands are the surround above and below the frame, so the framed page stays whole on a tall phone): the ten shields lit to the level, the bar toward the next, today's gift (`POST /v1/vip/gift`), the tiers' perks; Crown Patronage with SUBSCRIBE (StoreKit's price only) or its time left and MANAGE (the App Store's subscriptions page), and the 3.1.2 words beside it: title, a month, the price, renewal until cancelled in Settings, and Terms of Use · Privacy Policy on their own line, each a 96-unit target -- set at 22 units (about 9 pt) and never smaller, on the painting's plate drawn 40 rows taller at cut time (`favour.json` repeats its plain middle). Five perk rows take the patronage's five lines (the looks line on `favour/perk_row_bare` with the frame round the lord's face); six or more show four and "and N more" |
| `wardrobe_view.gd` | the profile's SPLENDOUR | `GET /v1/cosmetics`; `/wear`, `/buy` (sequenced, as the other diamond spends). A `PaintedPage` (`wardrobe.png`; the stretch band is the grid's erased ground, so a taller phone shows more tiles): FRAMES / TITLES / COLOURS / CRESTS as a TabStrip, each tile the item's own art (frames `frames/<id>_tile`, crests drawn down to the art box, colours the enamel chip, titles their words on the scroll), marked worn, owned, locked with its source, or held for a time; a price in the store's red-when-short numerals. The strip under the grid is the lord as the realm sees them: face in their frame, name in their colour, title, chip, crest |
| `mail_view.gd` (+ `mail_letter.gd`) | the profile's ROYAL MAIL | `GET /v1/mail`; `/read`, `/claim`, `/claim-all`, `/delete` -- no `action_seq`, the snapshot adopted through `GameState.adopt_async`. Rows at a 112 pitch, each the painting's envelope (its seal by the letter's kind), title and sender plates, and up to three reward tiles; a letter with under two days left wears the short plate and hourglass and says how long in red. CLAIM ALL sits 12 units under the last row until the rows reach its pin, then stays pinned above the footer while the list scrolls under it. A letter opens on the painted card over the list, which grows in height only; THROW AWAY only for an empty or claimed letter. A row draws one reward frame under each reward and none where there is nothing (the rows are cut without their painted frames) |
| `chests_view.gd` (+ `scenes/pages/cart_odds_page.gd`) | the COURT's CHESTS card; `--page chests`, `--page cart_odds` | **The Tax Cart.** `GET /v1/cart`; `POST /v1/cart/open {}` -- no `action_seq`, the snapshot adopted through `GameState.adopt_async`, the COURT's disc set at once from the answer's `cart`. Cut from `chests.png` (`art/slices/chests.json`) in four bands laid edge to edge **16 units higher than painted** -- the painting's pills sit 16 under the chrome's, so the header is cut from y 16 and the painted pills lie exactly under the chrome's, their ends and lower rims mirrored over from the painting beside them; the foot is pinned to the screen's foot where it was painted, its top rows (the plates' rims) the foliage below mirrored up. The header's line is set from `interval` ("every four hours": `ChestsView.every`); the yard shows one painted cart per `cap` place, lit (`chests/cart_lit`) for each of `stock` and grey (`chests/cart_dim`) for the rest, at the painting's three places (x 214.5, 285.5, 356.5) or spread over the panel for another size (`cart_places`); the hourglass's plate counts to `next_in` from the answer's moment ("Full", "Level 2"), and the page asks again once when it runs out; OPEN and the (i) are their own crops lifted out of the controls band, OPEN dimmed (`StorePrice.DIMMED`) unless `can_open`, a tap then saying why (`ChestsView.refusal`). The three cards' plates: in the yard -- "2 waiting · 1 writ", "3 carts waiting", "2 writs held", "None waiting"; on the road -- "Next in 1h 30m", "The yard is full", "Opens at level 2"; opened -- "57 opened", "None opened yet". OPEN plays `Ceremony.cart`: the opened chest's card (`chests/card_opened`) with the prize's name in its plate over the coins' light, then its lines as a purchase's tiles; a prize's gold, experience and unrolled gear are shown in its own painting (`ChestsView.PRIZE_ART`: the purses, the scroll, the gear chest from `reward_icons.png`), rolled gear in its own, tokens in theirs. A gear prize with a full bag is `Armory.refused` (nothing is spent). The (i) -- the painted coin under a 95x97 tap area (44 pt) -- is THE CART'S LOAD, a plain Sheet (the header scenes each belong to one information page): each prize's picture, name, lines and its chance from the server's `bp` (`reroll_panel.percent`), then the terms in the server's numbers |

Every purchase the shell hears of (`Billing.delivered`: a buy, an approved Ask
to Buy, a renewal) plays `Ceremony.delivery` from one listener in the shell. The
one sentence about where diamonds come from is `Goods.WHERE_DIAMONDS`, used by
the goods, the Shop and the Store alike.

A reward line drawn large -- the offer popup's tiles and the Royal Delivery --
goes through `RewardArt.dress(slot, line, avatar)` (`scripts/ui/reward_art.gd`):
diamonds as the vessel of the largest pack they reach, a frame with `FramedFace`
round the lord's face, the large potion and charter, everything else through
`Art.reward_line_icon`. Mail rows and the store's small tiles keep the small
icon. The Royal Delivery lays its lines out as tiles, up to three a row and two
rows at most (a delivery of more -- the Victory Road claiming a dozen milestones -- draws the first six and says "and 18 more rewards"), with a
short last row centred (one line 400 wide, two 294, three or more 192; the
picture in a 120-tall box above the words, one words size for the whole
delivery, the largest from 24 at which every tile fits in four lines; the
nine-patch frame as wide as its widest row); the first-purchase and Royal Favour
notes stay as text.

`ceremony.gd` (`class_name Ceremony`) is built from `ceremony_sheet.png` and has
six entry points sharing one queue: `level_up`, `mastery`, `delivery(host,
delivery)` (a purchase, "A Royal Delivery": the server's Delivery lines, the
first-purchase and Royal Favour notes; nothing plays for one already delivered
or granting nothing), `cart(host, opened)` (a Tax Cart opened: `chests.png`'s
opened card with the prize named in its plate, then the lines as tiles),
`chest(host, title, tier, lines)` (a week's chest opened: the chest of its tier
thrown open -- `icons/chest_wood_open|silver_open|gold_open`, rewards_sheet.png's
own, drawn down to 220 -- over the turning sunburst, its name on the plate,
then the lines as tiles) and
`new_lands(host, section_id, title)` (a section the
level opened; the shell plays one per `GameState.last_unlocked` after the
level-up, whose own list leaves them out). Each is the painted emblem over its
light, then what it brought, then the painted CONTINUE; the list frame and the
name plate are nine-patches (corner margin 56, end margin 38) so only their
plain middles stretch, and the words are live text in cream `#F7EDCF` Cinzel.

The battle (`scenes/battle/battle_replay.gd`) is `battle.png` in two pieces, cut
at y 1010 where the painting is plain navy: the battlefield with the two frames,
plates and bars keeps to the top (below the notch), the results board and
CONTINUE to the foot, and a taller phone shows the painting's own navy between
them. Each frame's window is cut see-through and the side's face
(`Art.avatar`, the avatar the replay stored) is drawn under it, 16 units larger
than the window so a lunge never shows its edge; the lion and wolf crests stay
on top. The HP fills are the painting's own, erased from the scene and drawn
along the channel cut at the current HP (a full bar closes on the channel's
angled end). Every text box is one line tall, centred on its plate: round,
names, power, HP, both Fortune of War rolls with their dice, the story line and
the three result rows ("No diamonds" when a row has nothing). SKIP and CONTINUE
are the painting's plates, the idle one darkened. The glows are drawn
additively over it all, the banner between the ROUND plate and the crests. Both lords are named through `Look.paint_name` (the player's look from the
snapshot, the rival's from whatever opened the replay, a sealed name down to
14). It only plays the server's event log.

Layers: pages 60/70, the offer popup 80, the guide 84, the battle 90,
ceremonies 95, dialogs 100, the toast 110. `Nav.go` clears every overlay layer on a scene change.

The rail carries count bubbles from the heartbeat (`POST /v1/presence` answers
with `badges`, kept in `GameState.badges`): quests to claim (the day's and the
week's, with the week's chests to open: `quests` + `weekly`), raiders to answer,
join requests, and on the portrait the letters waiting; a dot on the diamond
pill for the daily reward. A page that clears some (the Royal Mail) sets the
count itself rather than waiting for the next beat. Under the pills: the next energy and the
shield's time left. While the API does not answer, a banner stays with a retry.

### The guide

A new lord's first ten minutes are the Royal Steward's (`scripts/ui/guide.gd`,
`class_name Guide`, layer 84), cut from `guide.png` and `ftue_sheet.png`
(`art/slices/guide.json`, `ftue.json`; laid out by `client/layout/guide.json`).
The server holds the step (`snapshot.guide`: `step`, `title`, `text`, `done`,
`tab`, `target`, `min_level`, `tap`, `ready`, and on the bandit step `bandit`
{name, avatar, level, might, purse}), so a relaunch, another phone or the
background come back to it. The shell starts it on arrival while
`guide.active`, in place of the away page; the day's reward then waits for its
step and the offer popup for the guide's end. `--page guide` shows it for a
capture. It replaces the five-page tour (`onboarding.gd`, gone).

- The screen is dimmed (the game's navy at 0.74) except a soft spotlight round
  the step's control (a rounded hole 14 units out, feathered over 26): the dim
  takes every other tap (`_Dim._has_point`), the control under the hole its own.
- The steel gauntlet (`ftue/hand`, pressing `ftue/hand_press`; both cut at half
  the painting, the pressing one masked to its own outline because its painted
  flash keyed to a green disc) presses the control every 1.25 s, its fingertip
  -- the layout's `tip` -- a little below and right of the control's centre,
  the gold ring (`ftue/ring`) spreading from it. Mirrored off the right edge,
  turned over at the foot (`Guide.point_at`).
- A control not on screen is reached the way the lord would reach it:
  `Guide.chain` names the control, the view it opens into (the chests card's
  OPEN), then the way there -- the step's tab's rail entry, or the diamond pill
  for the day's reward -- and the way there gets the gold arrow (`ftue/arrow`),
  not the gauntlet. Below the step's `min_level` it is Collect's first job, with
  "LEVEL 3 OF 4" beside the title. A control below the fold of its list is
  scrolled into view (the dim leaves nothing else to scroll with).
- The steward (`guide/steward_r` looking right, `_l` left; 0.70 of the
  painting) stands behind the speech scroll (`guide/speech`, 1:1), his coat's
  foot under the parchment, on the side away from the control and looking at
  it; the scroll sits in the half of the screen the control is not in. The
  words are set on the plain parchment as the letter card sets them: the title
  in Cinzel 25 `#3A2412`, the words in EB Garamond 24 `#2E1D0E` (down to 20 for
  the longest), evened by `UI.balance_lines`. SKIP (`guide/skip`) stands at the
  scroll's other end and asks first (`POST /v1/guide/skip`: the parting gift is
  kept for those who finish).
- A tap step (the welcome, with the story card `guide/story` between the pills
  and the steward's head; the farewell) and a step whose deed is done (`ready`:
  the steward's `done` words) dim the whole screen (0.84) under a pulsing TAP
  TO CONTINUE; a tap anywhere posts `/v1/guide/advance {step}`. What an advance
  hands over -- the steward's purse on the way to the market and to the estates,
  the parting gift -- plays in the Royal Delivery titled FROM YOUR STEWARD.
- A step whose control cannot be found anywhere never dims: the lord is never
  shut in with nothing to press. A page, dialog, ceremony or the battle lying
  over the game hides the guide until it closes, unless the step's control is
  in it (the day's reward page and its CLAIM).
- Controls are found by name through `GuideTargets`
  (`scripts/ui/guide_targets.gd`): each screen registers its own in one line
  where it builds it -- `collect.job0`, `rail.<tab>` and `pill.diamonds` (the
  shell), `daily.claim`, `court.chests`, `chests.open`, `shop.offer.<i>` (the
  guide asks `/v1/shop` which is cheapest), `family.gear.<slot>` (it asks
  `/v1/inventory` for a slot the hero has nothing in), `family.stats`,
  `family.estates`, `army.recruit`, `attack.bandit`. A hidden control is not
  found. `tests/guide_targets.gd` holds every step's target in
  `balance/retention.json` to its owner's line.
- Karel the Bandit: on the bandit step the Attack tab opens below its level for
  his card alone (`Shell._is_locked`; `attack.gd` `_paint_bandit`, above the
  flow once the tab is open anyway): the target card with its painted steal
  line lifted (`attack/target_card_plain`), his face (`Art.avatar("bandit")`,
  the avatars sheet's hooded knave), level, might and purse from
  `guide.bandit`, the lord's might against his. FIGHT posts `/v1/guide/bandit`
  and plays the answer's replay on the battle screen (`Guide.fight_bandit`);
  its result board reads the answer's `gold`, `xp_gained` and `diamonds_gained`.

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
no asset, an invisible tap target; with a `label`, a plate with its word in
type, and a `paint_rect` smaller than its `rect` draws the plate at the
painting's size inside a tap area a thumb can hit), `ninepatch`, `fill` (a bar
clipped from the left via `Layout.set_fill`; an `image` carrying a `fill` key is
built as one; with a `track` it spans the track, its painted ends -- `caps` --
held at their size so a full bar reaches the track's end), `scroll`,
`group`, `template` (repeated component;
`instances` may be `[x, y]` or `{pos|at, assets, texts, rects, data}`).
Top-level rects are absolute; part rects are relative to their template.
A top-level element may carry `"anchor": "bottom"` (pinned to the foot of the
screen the player has, which on a tall phone is below the design's 1672) or
`"grow": "bottom"` (its top stays, its bottom follows the screen's -- for the
scroll lists). The rail spans the full height, dialogs centre in the visible
viewport, and the toast hangs off its foot. `--capture-size 941x2040` renders
a capture at a 19.5:9 phone's canvas to check all of this, and `--inset <units>`
stands in for the phone's notch (141 is a Dynamic Island) so a capture shows
what the top inset pushes down.
`Layout.build()` returns `{id: node}` for plain elements and
`{id: [{node, parts}, ...]}` for templates with instances. A nested template with
instances comes back as a wrapper whose meta `instances` lists them.

Text: `font` is `title` (Cinzel) or `body` (EB Garamond); `size` is the pixel
size measured on the painting; weights are lifted one step in `UI.settings`
because the paintings read heavier. `UI.fit_line(label, max, min)` is the
one-line rule: shrink toward min, then cut with an ellipsis at the box, so a
long name never runs under the button beside it. `UI.time_left(seconds)` says a
duration as the game writes it ("30d 00h", "1d 12h", "4h 38m"). `UI.fit_label(label, max, min)` shrinks a
name to its box — a Label grows to its text, so the box width is kept in meta:
the layout builder records each text part's real width, and a fitted one-line
label is sized back to it before it is written (`UI.fit_line` does this) (`PaintedPage.set_text` does
this), or a label built around a wider sample stays wide and its words sit off
the plate.
A text rect is the type's line centred on its plate: 1.39× the size tall in
Cinzel, 1.36× in Garamond (`text_sits_where_painted.gd` holds every layout to
it).

---

## 6. Art — cutting, not drawing

`art/SLICING_GUIDE.md` is the contract. In short:

- `art/slices/<screen>.json` lists every crop: `rect` in source pixels, `mode`
  (`rect` opaque, `darkkey` alpha against the navy ground), `erase` (per-row fill
  that removes baked dynamic text), `inpaint`, `mask` (chamfer, polygon or
  ellipse, `feather` for a soft edge, a list for their union; drawn at 4x and
  averaged, so diagonals are smooth), `scale` (never used for content).
- A painted word is lifted by its ink (an `inpaint` of kind `text`, or Telea
  for a chip's face), never with a flat erase: a flat erase leaves a box one
  shade off the ground.
- An erase must take all of what it lifts. `art/tools/remnants.py` (run by the
  client lint) looks for ink cut by an erase's edge; the painting's own ink
  standing against one is recorded, with why, in `art/qa/remnants_ok.json`.
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

Items sit on their rarity's velvet (`art/reference/velvet_<tier>.png`, the
owner's seven cloths, cut by `art/slices/velvets.json`): every item picture is
dressed by `ItemGround` (`scripts/ui/item_ground.gd`). A window with a frame
over the item takes the full cut, `items/ground_<tier>` -- `in_ringed_tile` for
the bag and the picker, `in_gear_tile` for the Family, Army and equipped gear
tiles (it adds the ring cut from the tile's own frame, `family/gear_tile_ring`,
`army/gear_tile_ring`); a window without one (shop cards, collection frames,
reward pictures) takes the soft cut, `items/glow_<tier>`, through
`under(…, soft=true)`; reward rows use `for_line(picture, line, rect)`, which
dresses painted gear only when the line carries `tier`. The grounds are cut once
at 256 and only drawn down, toned per tier against the inventory painting's own
tiles (the manifest's `tone {gain, saturation, vignette}`), and follow their
item's rect. A bare slot, an unheld collection frame and a reward line without
a tier get none; an unknown tier in an item view gets common's. The common shop
card is the uncommon card drained to grey (`shop/card_frame_common_*`), and the
gear tile's stone is cut round its gold setting.

Plates: a screen whose painting has its own button keeps that crop (the Shop's
BUY, the Army's HUNT, the Inventory's EQUIP/SELL, the Family's UPGRADE, the
ceremony's CONTINUE); every other surface -- dialogs, Sheet feet, painted pages'
extras, the offline banner -- uses the painted family cut from
`plates_sheet.png` (`art/slices/plates.json`: green, red and navy in five sizes,
and the brick-red NO ENERGY face). `Dialog.CONFIRM_PLATE`, `DANGER_PLATE` and
`QUIET_PLATE` are `plates/green_xs`, `red_xs` and `navy_xs`, drawn as nine-patches
with `Dialog.PLATE_EDGE` (24) so the chamfer never stretches. Nothing recolours a
plate: Collect's NO ENERGY is the painted brick-red face laid over the painted
COLLECT plate. `plates.gd` holds all of it.

Godot traps: a `--script` test that names `PaintedPage`, `TabStrip`, `UI` or
`Layout` as a type compiles them before the autoloads exist -- `load()` them by
path -- and a `class_name` script that touches an autoload in a constant or a
static initialiser breaks every test that loads it; a helper must never be
called `_set`, which is Object's own; and `UI.fit_line` measures against the
width the label had when first sized, so place a label empty and write it after
it is in the tree.

Things the paintings do not contain, and how they are handled: item designs
(the paintings hold one item per slot per screen, so every slot showed the same
picture; every definition the balance names has its own matted painting under
`items/painted/` -- 21 weapons, 21 armours and 21 horses, each its own design
(the Village Pony, `horse_02`, is painted alone on `items_horses_2.png`; a
definition may borrow another's design only while it waits for its painting,
declared in gen-balance.py's `ART_SHARED` -- empty now -- and `item_designs.gd`
fails on any other) -- cut by `scripts/cut-item-paintings.py` out of the
paintings' own item pictures and the weapon, armour and horse sheets (`sheet:`
sources) -- object mask plus luminance key,
so the ground goes clear; the blades whose light is the blade (`GLOW_DESIGNS`)
keep their glow with a ground key instead -- and drawn inset into each screen's
empty tile crop; the stone on a gear tile is `family/gem_<tier>` from
`scripts/gen-gem-tints.py`). Soldiers: `scripts/ui/soldier_art.gd` names every
portrait and numeral. A soldier's look follows its tier -- rough (common,
uncommon), fine (rare, epic), gilded (legendary, mystic, special) --
`portraits/soldier_<type>_<look>` (133x164, the strip card) and `..._large`
(202x286, in `sel_window` under `army/sel_frame`, never stretched over it);
numerals are `army/tier_1..7` (plain) and `army/tier_large_1..7` (fleur), from
`numerals_sheet.json`, each centred in its box so a badge sits in the same place
on every card; recruit cards keep the painting's type cards (a recruit has no
tier yet). Portraits are cut inside their own card's window: the painting's
selection frame must never be in a crop, or it becomes a highlight that never
moves. The battle's painted glows (impact, slash, dodge, spark) are painted on
navy and drawn additively; the critical burst over them normally. `slice-reference.py`'s
`patch` step copies a clean piece of the painting over a flaw (optionally
mirrored), and its darkkey takes `floor` (ground grain counts as
ground) and `solid` (a dark badge face stays opaque). An empty
gear slot shows a faint ghost of the piece that goes in it and the slot's name
(`UI.empty_slot_face`), on the Army and the Family alike. An empty LIST says why
in one card -- the kit's card frame, a shield, a line of caps and a sentence
(`UI.empty_card`): the Attack tab's REVENGE and TARGETS, and the Honour Arena
over a thin ladder, where it spans every rival slot the server could not fill.

Painted on object sheets and drawn down (SLICING_GUIDE, "paint big, draw
down"): all 15 job paintings (`collect_jobs_a`/`_b`), the ledger scenes
(`ledger_upgrades`, `ledger_holdings`), the eight Kingdom Works
(`works_sheet`), the twelve crests `Art.CRESTS` (`crests_sheet`, cut at 182x240 and always
drawn down; `Art.crest(id)` picks one by id for any lord or kingdom that has not
chosen one, on the hall's cards and Attack's rivals alike), the twelve avatar
faces (`avatars_sheet`, balance order; an unknown id is the knight):
`Art.avatar(id)` the 236 square, `avatar_small` the 96, `avatar_ring` a 160
round cut for round windows -- and the rank hexagons (`numerals_rep`).

Reward icons (`Art.reward_icon(key)`, the server's `Line.icon`; a row that has
the whole line draws it with `Art.reward_line_icon(line)`, which also tints a
name colour's chip with the line's `color`): a key with a slash is a crop;
`title:<id>` is `rewards/title_scroll` (the crowned ribbon's middle, from
`titles_sheet.png`); `name_color:<id>` is the enamel chip; `frames/<id>` draws `<id>_square`; `item:<tier>` is
`rewards/gem_<tier>`, the gear stone off the Family tiles cut round its gold
setting and tinted per tier by `gen-gem-tints.py` (an unknown tier the unlit
stone; rolled gear draws its own `items/painted/<art>`); `rewards/steward`,
`quartermaster`, `largesse`, `patronage` and `stipend` are square 120-unit cuts
from the plain-navy icon sheets. `reward_icons.png`'s sixteen (`art/slices/rewards.json`) are keyed off
that sheet's flat navy and drawn down to 120 on the long side:
`rewards/purse_small|purse_heavy|flask_small|flask_large|potion|xp_scroll|fortune_charm|cart_token|gear_chest|cosmetic_token|season_star|pardon|key|homecoming_lantern|renown_laurel`
(the charter was already `rewards/charter`). Wave 3's token keys map onto them:
`flask_small`, `flask_large`, `pardon`, `cart` (the cart token) and `boost:luck`
(the fortune charm). The enamel chip `icons/colour_chip` with
`icons/colour_chip_face` modulated is how a name colour is shown anywhere.
Another lord is always drawn through `Look` (`scripts/ui/look.gd`), the one
reader of a view's `worn` and `vip_seal`: `paint_name` (the worn colour, shrunk
to fit, the seal after the words or at the plate's end), `paint_title` (hidden
when none is worn), `paint_frame` (square on a card, ring on a round window,
the large rings of `looks.json` where a window is wider; sized so its band
covers the portrait's own frame, never drawn up), `crest` (the worn one, else
`Art.crest(id)`), `paint_crest(box, key)` -- the one way a crest is put in a
box: 1:1 and centred when it fits, drawn down when it is larger, never up.
`icons/crest_constancy`, the Crown of Constancy (the calendar's day-28 prize), is
cut 182x240 from its own painting (`art/slices/crest_constancy.json`) like the
twelve sheet crests; it was the day-28 shield's 61x79 for a day, which a rival
card's 91x120 box or the profile's 200x264 blew up three times -- the rule
stays for any crest cut small. The Attack cards, the profile, the Splendour strip and the kingdom
hall all go through `paint_crest`, the Splendour tiles and reward lines through
their own draw-down-only fits (`tests/crest_never_up.gd`) -- and `mine()` for the asker, whose snapshot keeps its look
under `player.worn` like everyone else's. Rival and revenge cards, the kingdom's
lords (each lord's own face in the painted medallion,
`KingdomSection.paint_lord_face`), join requests, the rankings and history rows
all use it; the four catalogue colours read at WCAG 4.5:1 on every plate a name
sits on.
Shared marks from the Favour and Splendour paintings: `icons/vip_seal` (Royal
Favour's wax seal: every list of lords draws it, drawn down, beside a name whose
look has `vip_seal`), `icons/tick_seal`, `icons/padlock`, and each worn frame as
`frames/<id>_square` (160, cards), `_ring` (96, round windows) and `_tile`.
`slice-reference.py`'s `inpaint` entry may be a traced polygon (with `also` and
`keep` to widen or spare parts of it); its `refill`
step repaints a plain panel from sampled rows, and `patch` copies (optionally
mirrored) a piece of the untouched painting, after `refill` and before `erase`.
A frame given as a reward is shown as a frame, round the lord's own face:
`FramedFace.build(square, box, avatar)` (`scripts/ui/framed_face.gd`), the face
covering the frame's window and 2 units past it, read once off the crop's alpha
(`FramedFace.window_of`: the farthest the clear opening reaches from the centre
each way, so a window an ornament crosses is still covered) -- the store's offer
tiles, deal slot 3, the popup and the Royal Delivery alike (`tests/framed_face_window.gd`).
The frames are two sheets cut to one scale: `frames_cosmetic_a.json` (oak, laurel,
laurel_gilded, founder, patron, aureole) and `frames_cosmetic_b.json` (companion,
thirtieth, loyal_vassal, rising_lord, heir, charter; measured by script, each masked
to its own ink), with `looks/<id>_ring_large` for both in `looks.json`. Still waiting for a painting:
the Treasury and Legacy cards, and ringed faces for the kingdom's lord rows
(the member list carries no avatar yet, so they keep the painted medallions).

---

## 7. The API, as the client sees it

Unchanged from the server's contract: base `/v1`, `Authorization: Bearer`,
`action_seq` on every sequenced mutation (never on the Royal Mail or
`/v1/events`), RFC-7807-ish errors `{code, message, request_id}`.
Gold and treasury are JSON strings. The endpoints each screen calls are listed at
the top of its script; the server routes are in `server/internal/httpx/router.go`.
Request bodies are strict (unknown fields are rejected), so send exactly the
documented fields -- and a new field needs the server that knows it deployed
first (CLAUDE.md, Deploying).

Money and the Court, as Wave 1 added them (all under `/v1`, none sequenced
unless it says so):

| Endpoint | What it is |
|---|---|
| `POST /iap/apple/verify {jws}` | a purchase StoreKit signed; answers the Delivery (`lines`, `already`, `for_another`, `first_bonus`, `vip_reached`, `snapshot`). `Billing` finishes the transaction only on a 2xx, or a refusal for good (`iap_invalid`, `iap_wrong_app`, `owned_by_another_account`) |
| `POST /iap/apple/restore {jws: []}` | what this Apple ID owns: `restored`, `refused`, `snapshot` |
| `GET /attack/targets` | the Attack tab. Its `rules` block is the sheet behind the notice's (i), and `raid_cap` in it is the CEILING on one raid at this lord's level — the sheet says it in gold, because "3% of their purse" alone left nobody able to see why three per cent of a rich purse is not three per cent. `scouted_today` is how many lords bought a look at this one's army today, said on the notice bar itself |
| `GET /store/court` | the Royal Store: `products` (lines, first_bonus, badge, available/note, ends_in for an offer, owned), `vip`, `stipend`, `patronage`, `steward`, `deals` (the day's four), `herald` (`enabled`: the realm has an advert to play at all -- false until the owner sets `EMPERORS_ADMOB_UNIT`; `unlocked`: this lord has reached `unlock_level`; `lines`/`diamonds` what one pays, `left`/`per_day` today's allowance, `next_in` the cooldown, `unit` the advert to play) |
| `POST /ads/watch` | a TICKET for one advert: `ticket` (AdMob's `custom_data`), `user_id`, `unit`, `expires_in`. Not sequenced and nothing is adopted -- it pays nothing. A second tap hands back the SAME ticket. Refusals: `herald_shut` (no advert on this realm), `herald_early` (the lord's level), `herald_spent` (today's allowance), `herald_soon` (the cooldown) |
| `GET /ads/admob/ssv` | GOOGLE'S, not the client's: no session, and the only credential is the ECDSA signature over its own raw query. Always answers 200, whatever it decides, so a failure is not retried for hours and a forgery learns nothing from the status |
| `POST /store/deals/claim {slot, action_seq}` | a daily deal, sequenced; answers `lines`, `deals`, `snapshot` |
| `POST /store/offers/seen` | the offers badge is read |
| `POST /stipend/claim`, `POST /vip/gift` | the day's share, the day's Royal Favour gift |
| `POST /steward/run` | the Steward claims every free thing waiting (403 `not_steward`) |
| `GET /cosmetics`, `POST /cosmetics/wear {kind, id}`, `POST /cosmetics/buy {id, action_seq}` | Splendour; buying is sequenced |
| `POST /promo/redeem {code, device}` | a promo code; its reward arrives as a letter |
| `GET /referral`, `POST /referral/claim {code, device}` | a lord's code and friends; entering a friend's |

Wave 3's Tax Cart: the snapshot carries `cart` {`unlocked`, `unlock_level`,
`stock`, `cap`, `tokens`, `next_in`, `interval`} (`GameState.cart()`; `next_in`
counts down from `GameState.live_age_s()`), and the heartbeat's badges `cart`
(carts waiting + writs).

| Endpoint | What it is |
|---|---|
| `GET /cart` | the yard: `stock`, `cap`, `tokens` (Cart Writs), `next_in`, `interval`, `can_open`, `opened`, and `odds` -- every prize with its `bp` and its `lines` resolved for this lord |
| `POST /cart/open {}` | opens one (a waiting cart first, then a writ); not sequenced; answers `prize`, `name`, `lines`, `cart`, `snapshot`. 409 `cart_empty`, 403 `locked`, 409 `inventory_full` (a gear prize with no room: nothing is spent). The Nth cart's prize is seeded: it cannot be rerolled |
| `POST /tokens/use {token, action_seq}` | drinks a flask, sequenced (the pool is predicted): `energy_gained`, `snapshot`; 409 `energy_full`, 409 `no_token`. The energy pill's "+" offers each flask held beside the refill (`Goods.energy`, `Goods.flask_options`) |
| `GET /store` `flasks` | the Small and Great Flasks, apart from the goods so no screen can sell one: {`id`, `name`, `blurb`, `icon`, `token_id`, `tokens`, `amount` (what one would add now, capped at the pool), `useful`} |

Wave 3's week and Golden Hour (the Collect tab's quests pager, chest bar and
wheel; see "The quests pager and the Golden Hour"). The heartbeat's badges carry
`weekly` (the week's tasks done and not claimed, and chests ready). The snapshot
carries `frenzy` {`unlocked`, `unlock_level`, `meter` (0..1 of the fill),
`active`, `ends_in`, `energy_left`, `used`, `per_day`, `ready_in`, `window`,
`bp`, `duration`, `drains_in`, `cooldown`} (`GameState.frenzy()`; the clocks
count down from `GameState.live_age_s()`), and both collect answers
(`/collect`, `/collect/batch`) `frenzy_gold` (the part of `gold_gained` the
hour added) and `frenzy_started` (this answer lit it), which `GameState._pump`
passes on as `golden_hour(gold, started)`. Nothing about the hour is predicted.

| Endpoint | What it is |
|---|---|
| `GET /weekly` | the lord's week: `week`, `ends_in`, `points`, `points_max`, six `tasks` {`slot`, `id`, `name`, `short` (the task as an instruction, 24 characters at most), `blurb`, `icon` (`quest_scroll|bolt|swords`), `target`, `progress`, `done`, `claimed`, `points`, `lines`} and three `chests` {`tier`, `at`, `ready`, `claimed`, `lines`} |
| `POST /weekly/claim {slot}` | a finished task: not sequenced; answers `lines`, `weekly`, `snapshot`. 409 `quest_unfinished`, `already_claimed`, `inventory_full` |
| `POST /weekly/chest {tier}` | a chest the points reached: not sequenced; answers `lines`, `weekly`, `snapshot` (the same refusals) |

The guide (Wave 3), none of it sequenced; every answer's `snapshot` goes
through `GameState.adopt_async`:

| Endpoint | What it is |
|---|---|
| `POST /guide/advance {step}` | moves on from `step` once its deed is done (a tap step at once): `guide`, `lines` (the purse entering buy_gear and upgrade, the parting gift leaving farewell), `snapshot`. 409 `guide_not_ready`, 409 `guide_moved` (the step is not the current one: refresh) |
| `POST /guide/skip {}` | ends the guide without its parting gift: `guide` {active: false}, `snapshot` |
| `POST /guide/bandit {}` | the bandit step's fight: `won`, `replay` (as `/attack`'s), `gold`, `xp_gained`, `diamonds_gained`, `lines` (his purse), `guide`, `snapshot`. Nobody's gold is taken |

The calendar (Wave 3), none of it sequenced; every answer's `snapshot` goes
through `GameState.adopt_async`:

| Endpoint | What it is |
|---|---|
| `GET /daily` | the 28-day calendar: `day` (the square a claim takes, or took today), `claimable`, `claimed_today`, `streak`, `cycle`, `broken` (null, or {`missed`, `restore_diamonds`, `can_restore`, `can_pardon`} for one or two days missed), `pardons`, `pardons_max`, `diamonds`, and `squares` -- 28 of {`day`, `crown`, `state` claimed/today/ahead, `kind` diamonds/purse/flask/scroll/cart/crown, `icon`, `amount`, `text`, `lines`}. `reward`/`rewards` stay for the old seven-square build |
| `POST /daily/claim {mend?}` | takes today's square; `mend` "diamonds", "pardon" or "anew" first mends a broken streak (or starts it over). Answers `lines`, `daily`, `snapshot`. 409 `already_claimed`, `calendar_broken` (broken and no mend), `not_enough_diamonds`, `no_token`, `inventory_full` (day 21's gear) |
| `GET /weekly` | this week's quests and chests: `points`, `points_max`, `ends_in`, `tasks`, `chests` [{`tier`, `at`, `ready`, `claimed`, `lines`}] -- the calendar draws the chests, the Collect tab the tasks |
| `POST /weekly/chest {tier}` | a chest the week's points reached: `lines`, `weekly`, `snapshot`. 409 `quest_unfinished`, `already_claimed`, `inventory_full` |

The Victory Road (Wave 3), not sequenced; its answer's `snapshot` goes
through `GameState.adopt_async`, and the heartbeat's badges carry `road`
(milestones reached and not claimed):

| Endpoint | What it is |
|---|---|
| `GET /road` | `level`, `claimable`, `diamonds_total`, and `milestones` -- 15 of {`index`, `level`, `reached`, `claimed`, `crown`, `lines`} in road order, the lines resolved for this lord |
| `POST /road/claim {}` or `{index}` | every milestone reached and not claimed, or just that one: `lines`, `road`, `snapshot`. 409 `nothing_to_claim`, 409 `inventory_full` (a milestone's gear with no room: nothing is paid) |

Wave 4's live ops. The snapshot's `live` gains `hourly` (the hour's event:
`id` ("" when quiet), `name`, `blurb`, `icon` `hourly/<id>`, `kind` boost |
refill_discount | free_reroll | quest_multiplier | gift, `bucket`, `bp`,
`effective_bp`, `x`, `left`, `lines`, `active`, `ends_in`, `next_in`, `next`),
`festival` (the running one, or the next announced; null when neither) and
`season` {`number`, `ends_in`, `tier`, `tiers`, `royal`}, read through
`GameState.hourly()`, `festival()` and `season()`; every `*_in` counts down
from `GameState.live_age_s()`. The heartbeat's badges carry `hourly` (bool),
`events`, `season` and `achievements`. None of these calls is sequenced; every
answer's `snapshot` goes through `GameState.adopt_async`:

| Endpoint | What it is |
|---|---|
| `POST /hourly/claim {}` | the Royal Courier's gift, once in its hour: `granted` (with `lines`), `snapshot`. 409 `already_claimed`, `hourly_over` |
| `GET /festivals` | the Events page: `current` (the festival running or next: points, day's cap, place, five `tasks`, four `milestones`, `ranks`, the top-50 `board`, `sources`), `upcoming`, `past`, `hourly`, and `hourly_table` (the published odds, 10000 bp with the quiet hour) |
| `POST /festivals/claim {}` or `{kind, index}` | a task's or milestone's reward, or everything done: `lines`, `events`, `snapshot`. 409 `no_festival`, `nothing_to_claim`, `already_claimed`, `inventory_full` |
| `GET /season` | the Royal Charter: `points`, `tier`, `tier_points`, `day_points`/`day_cap`, `royal`, `unlock` (900 diamonds, or the `season.pass` product), `sources`, and 50 `charter` tiers with both lanes' lines and states |
| `POST /season/claim {}` or `{tier, lane}` | a tier's reward in a lane, or every tier reached in both: `lines`, `skipped` (gear with no room), `season`, `snapshot`. 403 `charter_locked`, 409 `nothing_to_claim`, `already_claimed`, `inventory_full` |
| `POST /season/unlock {}` | opens the royal lane for its diamonds: `season`, `snapshot`. 409 `not_enough_diamonds`, `royal_open` |
| `GET /achievements`, `POST /achievements/claim {}` or `{id}` | the deeds: 7 `categories`, 24 `achievements` with four tiers each (`medal` bronze/silver/gold/imperial), `claimable`, `medals`; a claim pays every tier reached (the fourth with its title): `lines`, `achievements`, `snapshot`. 409 `nothing_to_claim`, 404 an unknown deed |
| `GET /leaderboards/{board}` | now also `week_raids`, `week_xp`, `season_renown`, `season_raids`, `season_xp`, `season_might` (the Might gained since the lord's first deed of the season), and every answer says its `name`, `period` (all/week/season), `ends_in`, the `rewards` its places pay and all the `boards` for the chips. Lords level on a week or season board share a place |

`GET /store`'s refill carries `regular_diamonds` and `sale_ends_in` while
Quartermaster's Sale runs; `GET /shop` carries `free_rerolls` and
`free_ends_in`, and a reroll while Fresh Wares has one left is free and does not
use a daily reroll. The Charter is bought through `Billing` like any product
and is not on the Royal Store's shelves.

Wave 2's storehouse: the snapshot carries `storehouse` {`gold`, `milli`, `cap`,
`cap_milli`, `per_hour_milli`, `hours`, `full_in`, `full`, `treasury_fee_bp`,
`treasury_open`}, settled to `server_at`; the screen ticks `milli` up by
`per_hour_milli` to `cap_milli` between snapshots (`game/estates.Fill`'s sum,
computed on read and never written, as energy is). `POST
/estates/storehouse/carry {to: "purse"|"treasury", action_seq}` is sequenced
and answers `carried`, `fee`, `banked`, `snapshot`; 409 `storehouse_empty`,
403 `level_too_low` for the vault before its level. The purse no longer ticks:
`player.tax_milli_per_hour` is always 0, which is what an older build reads.

`device` is `Session.device_id()` (also sent at sign-in). Prices are never
the server's: `Billing.price(store_id)` is the App Store's, in the player's
currency. Other lords arrive with their `worn` {frame, title, color, crest} and
`vip_seal` on raid targets, revenge entries, rankings, kingdom members and the
battle log's `opponent_look`, so one lord looks the same on every screen. The
Terms and Privacy pages are `https://91-107-215-32.sslip.io/legal/terms` and
`/legal/privacy`, served by the API.

---

## 8. What the client must never do

- Compute a game number, simulate a fight, or write a prediction into `snapshot`.
- Track an event the server does not list (`server/internal/service/events.go`),
  or put anything the player typed into one. The lint fails the first.
- Send an `action_seq` it did not read from the current snapshot.
- Hardcode an asset path or a coordinate — both come from the layout files.
- Redraw, regenerate or scale a painting. If a screen needs art the paintings do
  not contain, that is a new painting to cut, not a shape to draw.
- Draw a layout text's `sample`. It is the painting's copy, kept to measure the
  type by; `Layout` builds every text part empty unless it is marked `"static"`
  (fixed copy such as a button's word). The lint fails a text part nothing sets.
- Build a bare `Button` or a `StyleBoxFlat` in a scene. Buttons are
  `UI.plate_button` / `plate_face` / `tex_button` / `hotspot`, fields are
  `UI.field`; the lint fails anything else.
- Clear a screen's `_busy` between an action and the reload after it (the lint
  checks this too): a second tap would act on a card the first already changed.
- Name a class (`Sheet`, `Dialog`, `Goods`) in a test script. It is compiled
  before the autoloads exist; `load()` the script at run time instead.
