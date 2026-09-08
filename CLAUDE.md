# Emperors — brief for anyone (or any agent) working in this repository

A 2D portrait mobile idle/RPG kingdom game. Godot 4.7 client, Go 1.27 server,
Postgres on Neon, Next.js live-ops panel. iPhone first.

**Read `docs/FRONTEND.md` before touching `client/`.** It is the screen-by-screen
reference. The client was rebuilt (September 2026) from seven reference
paintings: every icon, button, frame and portrait is a crop of `art/reference/`,
never redrawn; only live text is set in type. `art/SLICING_GUIDE.md` is the rule. This file is the short list of things that will silently break if you do
not know them.

---

## The five rules

**1. The client never computes a game number.**
The server sends resolved values — gold already multiplied by every bonus, XP
already through the bucket. The client renders them. There is no second
implementation of any formula, and adding one is how two screens start
disagreeing. Combat is the sharpest case: the client animates an event log the
server produced and never simulates a fight.

**2. A prediction is never written into the snapshot.**
`GameState.snapshot` holds only what the server confirmed. Optimistic taps go in
`_pending`, and what you see is `confirmed + replay(pending)`, computed on read
(`display_gold()`, `display_energy()`). Nothing needs rolling back because
nothing was written. If you find yourself editing `snapshot` directly, stop.

**3. Balance is data, and the generator owns it.**
`scripts/gen-balance.py` is the source of truth. `balance/*.json` are generated
from it and mirrored into `server/internal/gameconfig/seed/`. Editing the JSON
by hand gets overwritten on the next run.
And editing the JSON is not enough to change the game: the live rules come from
the newest published row in `admin.balance_versions`. See the deploy sequence.

**4. Every percentage bonus goes through `economy.ApplyBucket`.**
Bonuses are basis points, additive inside a bucket, and each bucket has a hard
cap applied exactly once. A second multiplication site anywhere and the caps stop
being caps. The one bucket that cannot use `ApplyBucket` — tax, because it scales
a stored rate rather than an amount — is clamped by hand in
`estates.TaxRate` against `gameconfig.MaxTaxIncomeBP`.

**5. `internal/game` stays pure.**
No `net/http`, no `database/sql`, no pgx, no `time.Now()`. Time arrives as a
parameter. `server/internal/game/purity_test.go` fails the build if you break
this. It is what makes the economy unit-testable with zero infrastructure.

---

## Deploying

Server or balance change, in this order:

```sh
python3 scripts/gen-balance.py                       # if balance changed
cd server && go run ./cmd/migrate up                 # if there is a new migration
cd server && go run ./cmd/adminctl -cmd publish-balance -note "why"
scripts/deploy-hetzner.sh 91.107.215.32
```

Then verify against `https://91-107-215-32.sslip.io`. Both `.env` (repo root) and
`infra/secrets.env` must exist; both are gitignored and neither is in git history.

`deploy-hetzner.sh` rsyncs the **working tree**, so uncommitted changes do ship —
but the image tag comes from `git rev-parse HEAD`, so it will name the wrong
commit until you commit.

**Skipping `publish-balance` is the most common way to "change" a number and see
nothing happen.** The database's active version beats the embedded seed.

---

## Verifying

```sh
python3 scripts/gen-balance.py    # must be idempotent: run twice, no diff
python3 scripts/pace.py           # time-to-level under real session patterns
cd server && go build ./... && go vet ./... && go test -count=1 ./...
python3 scripts/lint-client.py     # compiles every script; layouts <-> assets <-> manifests
godot --path client -- --dev-login <user> <pw> --tab collect --capture shot.png --capture-after 6
```

`scripts/smoke-m*.py` drive the live HTTP API end to end. A capture run saves the
941x1672 design grid 1:1; put it beside `art/reference/<tab>.png` and look.

After a schema change: `cd server && sqlc generate`.

---

## Things that have already gone wrong here

Each of these shipped, and each was found late. They are the shape of mistake
this codebase invites.

- **A number that lies.** `tiers.json`'s `stat_mult` drifted to a completely
  different curve from the multiplier the game runs on. Nothing read it, so
  nothing caught it. Derived values are now generated, and `Validate` rejects a
  document where the readable number disagrees with the real one.
- **A field added to the generator, and the generator not re-run.** Reforging
  (since removed) shipped costing one gold, because a missing ratio reads as
  zero and zero prices the action at the floor rather than refusing to load.
  `Validate` now rejects zero where zero is meaningless.
- **A screen recomputing what the server already resolved.** The Estates tab
  called `estates.Derive` instead of `loadEffects`, so the rate it printed
  dropped kingdom upgrades, live events and the Legacy bonus. The purse was right
  and the screen was wrong, which is worse than the reverse.
- **A response field nothing read.** The server reported a crossed mastery
  milestone for months; the client never looked, so a permanent +20% payout
  arrived with no ceremony at all.
- **A generated id that was never stored.** `InsertBattle` omitted the `id`
  column, so the database defaulted a different one and the `battle_id` handed to
  the client named no stored row. Only surfaced when something finally tried to
  read a battle back.

---

## Layout of the repository

| Path | What |
|---|---|
| `client/` | Godot 4.7 game. 941×1672 portrait, every asset a 1:1 cut of `art/reference/` |
| `server/` | Go API, authoritative for every number |
| `balance/` | Generated tuning documents — **do not hand-edit** |
| `scripts/` | `gen-balance.py`, `pace.py`, `lint-client.py`, smoke tests, deploy |
| `admin/` | Next.js live-ops panel (its own `AGENTS.md`) |
| `art/` | `reference/` (the seven paintings), `slices/` (crop manifests + layouts), `qa/` (side-by-sides), `SLICING_GUIDE.md`. **Never** imported by Godot |
| `docs/design/` | Seven subsystem designs, each with its adversarial review appended |
| `docs/FRONTEND.md` | **Start here for client work** |
| `proof/` | Per-milestone device screenshots |

`docs/design/economy.md` is the deepest document in the repo and parts of it are
now out of date; its header carries a table of exactly which parts and what
replaced them. Trust the table over the body.
