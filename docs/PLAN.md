# Emperors — Build Plan

## Context

Build **Emperors**: a 2D, portrait, mobile-first idle/RPG kingdom game — the medieval reskin of
the Roblox game **"Idle Mafia Game"** (group *Stacks of Cash*, launched 2026-08-06, 1.7M visits,
~6.4k concurrent, itself an homage to Mafia Wars 2009), crossed with **Shakes & Fidget**'s
character progression and asynchronous PvP.

No character movement, no world traversal. The whole game is menus, lists, grids and numbers
going up. All in-game text is English. iPhone first, then Android, then Steam.

`/Users/yigitkarabulut/Developer/Emperors` is **empty** — this is greenfield.

**Why this shape.** The reference game reached 1.7M visits in a month with essentially no art
budget, because the loop carries it. The owner already has a Neon Postgres instance, a Google AI
Studio key with image generation, Godot 4.7.2, Go 1.27, and Xcode 26.3 with valid signing
identities. And a mobile client is a hostile client, so every number must live on the server.

**What has already been done.** Godogen was investigated (it ships only docs + a paid asset CLI —
no scaffold, and its Godot guide mandates C#/3D, so we use only its asset pipeline). The reference
games were researched down to Shakes & Fidget's actual combat source. Seven subsystem
architectures were designed and each adversarially reviewed — 28 blockers, 88 major and 37 minor
defects were found and corrected before a line of code exists.

---

## Decisions locked with the owner

| Area | Decision |
|---|---|
| Engine | Godot 4.7.2, **GDScript** — C# has no Godot web export and its mobile export is still experimental |
| Client role | Thin renderer. Server is authoritative for every number |
| Backend | **Go 1.27**, single stateless binary, Docker on **Hetzner Cloud** (Falkenstein/Nürnberg) |
| Database | **New Neon project in `aws-eu-central-1` (Frankfurt)** — the current London project is empty, and Neon regions are immutable after creation. Co-locating with Hetzner turns ~18 ms/query into ~3 ms |
| Admin panel | **Next.js**, talks only to the Go `/admin` API, holds no DB credentials |
| Auth | **Username + password from day one**, on a multi-credential schema so email / Apple / Google can be added later without a rewrite |
| Test device | **iPhone 15/16/17 class** — modern memory budget, no texture atlas needed in v1 |
| Domain | Free subdomain (`sslip.io`) for development; a real domain before TestFlight (iOS ATS rejects self-signed certs) |
| Repo | **Private** `github.com/yigitkarabulut0/emperors`, bundle id `com.emperors.game`, Apple team `JS3GR55886` |
| Idle model | **Hybrid** — active Collect is primary; Territory holdings produce passive tax, accruing offline up to a cap |
| Treasury | **Yes, 10% deposit fee.** Deposited gold is safe from theft. The reference game's best mechanic: a real risk decision every session, and the largest gold sink |
| Item sink | **Sell + Collection** — donating an item type once grants a small permanent stat bonus; completing a set grants a large one |
| Player equipment | The player has their own Weapon/Armor/Horse slots, in addition to each soldier's three |
| Navigation | **Left vertical icon rail**, 7 icons, always visible. Bottom strip reserved for the primary action button. No bottom navbar |
| Tier colors | gray → green → blue → **violet `#A855F7`** → gold → **magenta `#E040FB`** → red. Never color alone: every card also shows the tier name and a 1–7 pip count |
| Art | **"Gilded Iron" — flat 2D art-deco line art**, matching Idle Mafia Game's own visual language. Generated free and offline with FLUX.2-klein (Apache-2.0) on the Mac, since the Google key has zero quota. One generation per design yields all 7 tiers by recolouring the line work |
| Battle UX | Animated round-by-round replay, with a "fast battle" toggle after the first few fights |
| Ads | None in v1; the server-side reward endpoint and daily caps are built now, AdMob wired later |
| Name | **Emperors** |

---

## The seven sections

| # | Section | Building | Contents |
|---|---|---|---|
| 1 | Family | The Keep | Stats, level/XP, power, stat-point allocation, family upgrades, Treasury, kingdom card, soldier summary |
| 2 | Collect | Fields | Job list; energy → gold + XP. Mastery at 25/50/100 completions |
| 3 | Inventory | Armory | Weapon / Armor / Horse across 7 tiers; equip, sell, donate to Collection |
| 4 | Shop | Market | Rerolls every 5 minutes; random tier and type, priced by tier |
| 5 | Soldiers | Barracks | Buy a slot (escalating cost), recruit Peasant / Mercenary / Gladiator — differently-weighted tier rolls. Train to keep pace with your level |
| 6 | Attack | War Gate | Async PvP; steal 3% of the target's *unbanked* gold; a defender who loses gets a 30-minute shield |
| 7 | Territory | Map Table | Personal holdings producing gold/sec + kingdom-contested map regions |

Kingdom (the clan) is founded from Family and threads through Territory, Attack (reputation) and
the leaderboards.

---

## Repository layout

Single private monorepo. The one rule that matters: **`art/` is a sibling of `client/`, never
inside it** — Godot must not import 2K generation sheets, and generation inputs must never reach
the shipped bundle.

```
Emperors/
├── client/                 Godot 4.7 project (project.godot, scenes/, scripts/, assets/, theme/)
├── server/                 Go: cmd/{api,admincli,simulate}, internal/{game,service,db,httpx,auth,...}
│                           db/{migrations,queries}, api/openapi.yaml
├── admin/                  Next.js App Router + TypeScript
├── balance/                *.json — the seed balance documents (jobs, items, tiers, upgrades, pvp)
├── art/                    refs/, sheets/, sliced/, matted/, promoted/  (generation workspace)
├── contract/               OpenAPI → generated Go server stubs + TS client
├── infra/                  Dockerfile, compose.yml, Caddyfile, deploy.sh, SOPS-encrypted secrets
├── docs/                   ARCHITECTURE.md, ECONOMY.md, SCHEMA.md, ART.md, API.md, RUNBOOK.md
├── proof/                  per-milestone device screenshots + evidence
└── .claude/skills/asset-gen/   vendored fork of godogen's asset pipeline
```

**Do not run `godogen/publish.sh` against this repo.** `--force` does `rm -rf` on the target and
its skill install is `rsync --delete` over `.claude/skills/`. Instead a `scripts/vendor-asset-gen.sh`
copies only `asset-gen/` out of `~/Developer/godogen-src`, and four patches are committed on top:

1. Make the `xai_sdk` import lazy (we have no xAI key; today it fails at import).
2. Default `--model` to `gemini` and add `--gemini-model` so we can select `gemini-3-pro-image`
   (Nano Banana Pro) for hero references and `gemini-3.1-flash-image` for bulk sheets.
3. Strip `onnxruntime-gpu` and `nvidia-cudnn-cu12` from `requirements.txt` — no Apple Silicon
   wheels — and use CPU `onnxruntime` inside a `uv` venv.
4. Fix the `bg_color` `NameError` at `asset-gen/tools/rembg_matting.py:312`.

Also note godogen's stock `.gitignore` ignores `assets` — our paid art **must** be committed.

---

## Architecture

### Backend (Go)

`chi v5` + `pgx v5` + `sqlc` + `goose`, one stateless binary, no Redis and no WebSockets in v1.
Handlers decode and delegate; `internal/service` owns transactions; **`internal/game` is pure** —
no `context`, no `pgx`, no `net/http`, no `time.Now()` — which is what makes the economy unit
testable, the admin simulator possible, and every roll auditable. A CI dependency check enforces it.

The three load-bearing rules:

- **Integer-only economy.** Gold, XP and diamonds are `int64`; every multiplier is integer basis
  points; rounding is always floor. No `float64` touches currency, so server, simulator and client
  prediction agree bit-for-bit. Values above 2^53 serialise as JSON strings.
- **Lazy time accrual.** Energy and tax are stored as `(value, anchor, period_ms)` and settled by a
  locking SQL function at the top of any request that touches the player. No cron sweeps players.
  On a rate change, settle at the old rate first, then carry the partial tick proportionally.
- **Atomicity.** `READ COMMITTED` with pessimistic `SELECT … FOR UPDATE`. Multi-player locks (PvP)
  are taken in ascending UUID order as separate statements to avoid deadlock. Idempotency is
  insert-first `ON CONFLICT DO NOTHING RETURNING` inside a savepoint, so business errors commit and
  infrastructure errors roll back.

Determinism: `ChaCha8` from `math/rand/v2`, seeded by HMAC-SHA256 over a server secret. Shop
contents are a pure function of `(secret, player_id, floor(unix/300), reroll_counter)` — never
stored, so retrying cannot reroll. PvP target offers are stateless HMAC-signed tokens. Shields are a
`shield_until` timestamp compared on read.

Auth: username + password (Argon2id) → Ed25519 JWT access tokens (15 min) + opaque rotating refresh
tokens in Postgres with reuse detection. The `identities` table is credential-typed from day one, so
email, Apple and Google are additive later.

Neon specifics: **two DSNs** — pooled for the app, direct (unpooled) for `goose`. pgx keeps its
default `cache_statement` mode against the pooled endpoint, with an env escape hatch, and CI runs a
second integration pass through PgBouncer in transaction mode to prove it.

### Database (PostgreSQL 18, Neon Frankfurt)

Three layers:

1. **Content registry** — append-only, identity and slug only. Player rows FK to it.
2. **Balance config** — immutable, hash-sealed, versioned JSONB documents with an append-only
   activation log. The newest activation row *is* the live config. This is what lets the admin
   panel retune the game with no client or server redeploy, and roll back in one click.
3. **Player state** — normalised tables.

Key modelling calls:
- The equipped-on pointer lives on the **item** row, which makes "one item, two holders"
  structurally impossible.
- `total_power` is materialised on `players`, maintained by one Go function inside the mutating
  transaction (no trigger), with `power_config_version` as the staleness detector.
- Leaderboards are a generation-swapped snapshot table refreshed every 5 minutes, plus an exact
  index-only count for "your rank".
- The ledger is split by currency: `gold_ledger` partitioned weekly with rollup-then-`DROP
  PARTITION` retention; `diamond_ledger` partitioned yearly and kept forever. Grind income is
  buffered and flushed hourly as aggregate rows so collect taps don't each write a ledger row.
- Item and soldier rolled stats are **frozen at acquisition** — a rebalance never nerfs what a
  player already earned.

Every partitioned table's primary key includes the partition key (one of the reviewed blockers).

### Client (Godot 4.7 / GDScript)

- 720×1280 portrait base, `stretch/mode=canvas_items`, `stretch/aspect=expand`, `mobile` renderer
  (with a `.web` override to `gl_compatibility` for the later web build). Safe-area insets computed
  as fractions of the physical screen and applied only under `OS.has_feature("mobile")`.
- Autoloads: `Api` (pooled, cancel-safe HTTP with backoff and 401 refresh), `GameState` (per-domain
  stores, one `changed` signal each), `Actions` (the action queue), `Clock`, `UiTheme`,
  `ArtRegistry`, `Audio`. **No UI node reads state in `_process`**; a single 10 Hz projector drives
  the two self-moving numbers (tax and energy).
- **The critical UX decision — optimistic display without desync.** A prediction is never written
  into a store. `display_gold()` is a function returning `confirmed + replay(pending)`. The server
  ships *resolved* payouts (already multiplied and rounded), so the client's prediction is a table
  lookup, not a formula it could drift on. Milestone crossings predict pessimistically. Two lanes:
  optimistic + batched for deterministic high-frequency actions (collect, stat points); pessimistic
  single-flight with a reveal animation for random ones (recruit, shop buy, attack).
- Tabs lazily instantiated on first open, cached hidden with `PROCESS_MODE_DISABLED`, in-flight
  requests cancelled by tag on exit. Inventory grid recycles views above ~120 cells.
- Theme built in GDScript with `theme_type_variation`, not an authored `.tres`. Cinzel for display,
  a tabular-figures body face for every number.
- Device loop: `xcrun devicectl` one-click deploy with remote debug. The exported Xcode project is
  generated only for TestFlight, IAP and Instruments.

### Admin panel (Next.js)

Holds **no database credentials** — every read and write goes through the Go `/admin` API, which
binds to the Docker network only and is reachable exclusively through a Cloudflare Tunnel behind
Cloudflare Access. Identity, hashing, 2FA, sessions and RBAC live in Go; Next.js holds an opaque
session cookie. Destructive actions require step-up re-authentication. The audit log is a hash chain
with `UPDATE`/`DELETE` revoked from the application role.

The balance editor is the point of the whole panel: edit a draft, see a **simulator that runs the
real production Go economy code** against the draft (zero formulas of its own), review the diff,
acknowledge server-computed risk codes, publish, and roll back in one click.

### Art pipeline

One painted style locked by a single hero reference image, passed as `--image` on **every**
generation. Everything batches as 4×4 grid sheets — rows are tiers, columns are designs — then
`grid_slice.py` → batch `rembg_matting.py` → ImageMagick downscale → promote into `client/assets/`.
Never prompt for a transparent background; prompt a solid color chosen to matte cleanly. Nine-slice
frames are generated as a single top-left corner and mirrored locally with `magick -flip/-flop`.

`rembg`'s `--preview` is abandoned (it's broken in single-image mode); QA is three `magick montage`
contact sheets — over magenta, over light grey, and at 64px.

~200 assets in roughly 33 generations, estimated **~$9–15 total**. An `ArtRegistry` autoload with
procedural tier placeholders exists from day one, so no scene ever references an art path directly
and code is never blocked on art.

---

## Core game math

Full derivations go to `docs/ECONOMY.md` at M0. The headline shape:

- **Energy** — flat regen (1/60 s, upgradeable to +60%), one pool shared by Collect and Attack. Max
  Energy raises offline banking, not daily throughput, so it can't be stacked into runaway income.
- **Levels** — cap 60, ~90 days for a committed player. Each level grants stat points spendable on
  Max Energy / Attack / Defense, so a player with zero soldiers still progresses.
- **Collect** — 15 jobs; gold-per-energy rises ~13× across the ladder so higher jobs are always the
  right choice, but low jobs stay usable. Mastery at 25/50/100 gives **+5/+10/+15% replacing** (not
  cumulative), extended to 250/500/1000 → +20/+25/+30%.
- **Tiers** — one ×7.6 stat ladder shared by items and soldiers, seven rungs.
- **Power** — `Might = 2·√(Σattack × Σ effective HP)` across the player plus every soldier and every
  equipped item.
- **Combat** — deterministic seeded volley auto-battle; the server stores only inputs (seed, config
  version, packed army snapshots) and returns a replay the client animates. Randomness is a
  per-side "Fortune of War" roll surfaced as a visible pre-battle die, calibrated so a **+20% Might
  advantage wins 75%** of the time. Golden replay files pin the math in CI.
- **PvP economics** — steal 3% of the defender's *unbanked* gold, capped by attacker level so a
  whale cannot drain a hoarder. Defender who loses gets 30 minutes of shield; attacking cancels your
  own shield unless it's a revenge attack. Per-pair attack cooldown to stop farming. Gold is a
  **transfer inside one transaction, never a mint**.
- **Bonus stacking is additive within eight hard-capped buckets**, applied by a single
  `ApplyBucket()` that CI enforces as the only call site — this is what stops upgrade bonuses from
  multiplying into runaway inflation.
- **Diamonds never buy gold and never buy power.** They buy energy refills, protection, shop
  rerolls, cosmetics and convenience.
- **Bot "wandering warband" opponents** fill the Attack tab at launch behind a `BOT_FILL_RATIO` that
  decays to zero as the real population grows — otherwise the core loop is empty on day one.

---

## Milestones

Each ends demonstrable on the phone. Rough solo effort in focused days.

| # | Goal | Key deliverables | Done when | ~Days |
|---|---|---|---|---|
| **M0** | Prove the whole pipe | Monorepo, machine setup, new Neon Frankfurt project, Hetzner VPS + Caddy + TLS, Go `/healthz`, Godot app calling it, deployed to the iPhone. Design corpus written into `docs/` | The phone shows a number that came from Postgres over TLS | 3 |
| **M1** | The core loop | Username/password auth, `/v1/state`, lazy energy, Collect tab, gold, XP, levels, stat points, Treasury. Grey-boxed art | 10 minutes of real play on the phone | 7 |
| **M2** | Gear | Items, tiers, rolled stats, Inventory, equip on player, Shop with the 5-minute deterministic roll, sell | You can buy a sword and watch your power rise | 6 |
| **M3** | The army | Soldier slots, three recruit types, tier rolls, equipment on soldiers, Train, Might formula | A visible army with a real power number | 6 |
| **M3.5** | **Vertical slice** | Attack vs bots, seeded battle sim, animated replay, shields | **The first genuinely fun 10 minutes** | 4 |
| **M4** | Real PvP | Player matchmaking, gold transfer, revenge, cooldowns, battle log, leaderboards | Two phones can raid each other | 5 |
| **M5** | Idle + depth | Territory holdings, passive tax with offline cap, family upgrades, Collection | The game rewards coming back | 6 |
| **M6** | Social | Kingdoms, roles, invites, donations, kingdom upgrades, reputation, contested regions | A kingdom can be founded and fought over | 6 |
| **M7** | Live ops | Admin panel, balance editor + simulator, player tools, economy dashboards, moderation | You can retune the game without a deploy | 8 |
| **M8** | Art & juice | Style test → approval → full asset run, audio, animation, polish | It looks like a shipped game | 9 |
| **M9** | Ship | Real domain, privacy policy, App Store assets, TestFlight → review. Then Android, then Steam | Live on TestFlight | 6 |

M7 (admin) and M8 (art) can run in parallel with M4–M6. M0 must not be parallelised — everything
depends on it.

---

## One-time machine setup (M0, before anything else)

1. `export PATH="$HOME/go/bin:$PATH"` in `~/.zshrc` — `air`, `goose`, `migrate`, `gopls`,
   `staticcheck` are all installed but invisible today. Also `brew install golangci-lint`.
2. Download the full Godot 4.7.2 export templates (1.28 GB) — only `ios.zip` is present:
   `https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz`
3. `uv venv` in `art/` and install the patched asset-gen requirements (CPU `onnxruntime`).
4. Create the new Neon project in `aws-eu-central-1`; capture both pooled and direct DSNs.
5. Provision the Hetzner CPX server (Falkenstein), install Docker + Caddy, point an `sslip.io`
   name at it.
6. Store secrets with SOPS + age; nothing plaintext in git. Export `GOOGLE_API_KEY` for art.
7. `gh repo create yigitkarabulut0/emperors --private`.

Android (JDK 17, the whole SDK, Godot Android templates, debug keystore) is deliberately **not**
set up now — it is M9 work, and Android is entirely absent from this machine today.

---

## Verification

Every milestone produces evidence under `proof/M<n>/`, not a claim:

- **Server** — Go unit tests on pure `internal/game`, integration tests against real Postgres 18 via
  a template database, plus a second CI pass through PgBouncer in transaction mode. Golden files pin
  battle replays and economy curves so a rebalance can never silently change combat.
- **Client** — headless GDScript tests of the API client and stores against a scripted fake
  transport and an injected clock.
- **End to end** — a scripted UI tour on the physical iPhone producing one screenshot per step, a
  contact sheet, and a short screen recording; plus `psql` output showing the database agrees with
  what the screen showed.
- **Economy** — `cmd/simulate` runs a headless 30-day simulation and asserts the sink/faucet balance
  before any balance change ships.

---

## Risk register

| Risk | Mitigation | Early warning |
|---|---|---|
| Neon pooled endpoint breaks prepared statements | Two DSNs; CI pass through PgBouncer in transaction mode | Integration suite fails, not production |
| Neon autosuspend cold start on the first query | Keep-warm ping sized to stay inside the plan's compute quota; paid tier before launch | p99 latency spikes after idle |
| Docker image built on Apple Silicon won't run on the VPS | Build `linux/amd64` in CI, never locally | `exec format error` on first deploy |
| iOS signing and provisioning friction | Real device deploy is M0's definition of done, not M9's | Any delay surfaces on day 3, not month 3 |
| App Store rejection (PvP + IAP + minors) | Privacy policy, age rating, no gambling framing, IAP deferred to v1.1 | Review notes on the first submission |
| Art style drifts across 200 assets | One hero reference passed as `--image` on every generation; owner approves a ~$3 test batch first | The contact sheet at each batch |
| Economy inflates | Additive capped buckets, Treasury fee as the primary sink, ledger reconciliation, 30-day simulator gate | Gold-created vs destroyed diverging on the dashboard |
| Whales farm beginners | Might-band matchmaking, per-pair cooldown, level-capped steal, shields | Steal distribution skew in the admin panel |
| Empty Attack tab at launch | Decaying bot fill ratio | Bot-fought ratio on the dashboard |
| Modified client | Server-authoritative everything, ledger, faucet-ceiling anomaly detection, `X-Client-Version` kill switch, App Attest at v1.1 | Anomaly flags |
| Scope creep across 7 sections | The cut list below is fixed; M3.5 is the honest fun test | Slipping past M3.5 |
| Lost accounts | Username + password from day one; multi-credential schema ready for email recovery | Support requests |

---

## Explicitly NOT in v1

IAP/StoreKit (diamonds exist and are earned, purchasing lands in v1.1) · rewarded ads (endpoint
built, SDK not) · prestige/legacy · guild raids and guild-vs-guild battles beyond territory ·
crafting/item merging · chat · push notifications · localisation · iPad-specific layout · Android ·
Steam · texture atlasing · WebSockets · Redis.

---

## First actions on approval

1. Scaffold the monorepo and write the seven design documents into `docs/` (they exist in full in
   the workflow journal at
   `~/.claude/projects/-Users-yigitkarabulut-Developer-Emperors/3c296e3c-.../subagents/workflows/wf_af930763-11b/journal.jsonl`
   — session-scoped, so this must happen first).
2. Run the M0 machine setup above.
3. Stand up the Go server, Neon Frankfurt schema, and the Godot shell, and get a number from
   Postgres onto the iPhone.


## Navigation, after the Idle Mafia Game pass (September 2026)

The owner's complaint was that the game read as strange and the Keep in
particular was unintelligible, with the clan system buried two taps deep. The
reference game was re-examined and three rules came out of it.

**One section does one thing.** Idle Mafia gives Jobs, Properties, Crew, Bank,
Fight and Family each their own rail entry. Ours had a "Keep" holding your
character, the vault, estate income, a link into the clan system, and the
upgrade tree -- five unrelated things, which is why it could not be understood
at a glance. Bank and House are now sections of their own, estate income moved
next to the estates that earn it, and Hero is your character and your upgrades.

**Names are literal.** "Keep", "Fields", "Armory", "War Gate" and "Map" are good
flavour and tell a new player nothing. The rail now reads Jobs, Hero, Shop,
Items, Estates, Army, Bank, Fight, House. The flavour lives inside the screens.

**Sections unlock as you level, and locked ones stay visible.** Nine tabs handed
to a new player at once is unreadable, and most of them do nothing yet: no gold
to spend, no army to gear, no house to join. The gates live in the balance
document (`progression.sections`) and ride along on `/v1/state`, so they are
tunable without a deploy. A locked entry is dimmed and carries its level, because
seeing what is coming is most of what makes levelling feel like progress.

Levels land just before the thing behind them turns on: Shop at 2 when a job
pays enough to buy from it, Army at 5 when the first slot becomes free, House at
20 when founding unlocks.

Sources consulted: idlemafiagame.wiki, allthings.how progression guide,
roblox.com/games/73897506680154.
