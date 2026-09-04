# Emperors — Roadmap Design

> Produced by an architecture pass on 2026-09-04 and adversarially reviewed.
> Owner decisions made *after* this document was written take precedence — see the build plan.

**Headline:** Build Emperors as a single monorepo (`Emperors/` with `client/`, `server/`, `admin/`, `art/`, `balance/`, `contract/`, `infra/`), fork rather than sync the godogen asset-gen skill, and drive an 11-milestone roadmap whose vertical slice — collect → shop → soldier → attack-a-bot — lands at the end of M3.5, roughly four weeks in.

---


# Emperors — Delivery Plan, Repository Layout and Risk Register

Verified against the machine on 2026-09-04 and against upstream docs as of September 2026.
Nothing here was written from memory where it could be checked.

**Verified environment facts used below**

| Fact | Verified value |
|---|---|
| Godot | `4.7.2.stable.official.ed1daf0bf`, standard build on PATH (4.7 stable shipped 2026-06-18) |
| Go | `go1.27.0 darwin/arm64`, `GOPATH=/Users/yigitkarabulut/go`, `GOBIN=/Users/yigitkarabulut/go/bin` — **not on PATH** |
| `~/go/bin` contents | `air goose gopls govulncheck migrate oapi-codegen sqlc staticcheck wails` |
| Node / npm | `v22.11.0` / `11.9.0` |
| psql | **17.5** — the Neon server is **18.6**. `pg_dump` 17 will refuse to dump an 18 server. |
| Docker | CLI 29.2.1; `colima` 0.10.3 present, daemon stopped |
| Python | `python3` → 3.14.6; **`python3.12` also present** at `/opt/homebrew/bin/python3.12`; `uv 0.11.8` |
| ffmpeg / ImageMagick | 8.1.2 / 7.1.2-29 |
| Xcode | 26.3 (17C529) |
| Signing identities | 2 × `Apple Development … (JS3GR55886)` |
| Provisioning profiles | **`~/Library/MobileDevice/Provisioning Profiles/` is EMPTY** |
| Godot export templates | `~/Library/Application Support/Godot/export_templates/4.7.2.stable/` contains **only `ios.zip`** |
| gh | authenticated as `yigitkarabulut0` (scopes: gist, read:org, repo, workflow) |
| Existing precedent | `~/Developer/GameTest` — a Godot+Go+Neon project by the same author, GDScript autoloads, `client/`+`server/`, headless `TestRunner.tscn`, `tools/capture.gd`. **This plan deliberately extends those conventions.** |

Note: `GameTest/README.md` claims "Godot 4.7.2 (.NET/mono), C#" but the actual `client/` is GDScript
(`autoload/*.gd`, `.uid` files, no `.csproj`). The GDScript reality is the precedent to follow, not the README text.

---

## 1. Repository strategy

### 1.1 Decision: **monorepo**, one Git repo, `github.com/yigitkarabulut0/emperors`, private

**Why.** Emperors is one product with four artefacts that change *together*:

* The client/server contract changes on nearly every feature commit for the first three months. In a polyrepo every such change is two PRs, a version bump and a window where `main` of one repo does not work against `main` of the other. For a solo/small team this is the single largest tax available and it buys nothing.
* `balance/*.json` is consumed by **three** artefacts — the Go server (authoritative math), the Godot client (display strings, icons, "next upgrade costs X"), and the Next.js admin (the balance editor). A shared package across three languages in three repos is a build system; in a monorepo it is a directory.
* Milestone proof (§5) is cross-cutting: a contact sheet of the six tabs is only meaningful next to the server commit that produced the numbers in it. Bisecting a regression across four repos is miserable.
* CI cost is handled by `paths:` filters, not by repo boundaries.

**Rejected: polyrepo** (`emperors-client`, `emperors-server`, `emperors-admin`, `emperors-art`). The only genuine argument for it is repo size from committed art. That is a real concern — and it is solved by the art discipline in §1.4 plus a size gate in CI, not by four repos.

**Rejected: Git submodules for art.** Submodules are the worst of both worlds: you still get a monorepo's coupling problems plus detached-HEAD confusion, and Godot's `.import`/`.uid` files live in `client/` while the PNGs would live in the submodule — splitting one logical asset across two repos.

**Rejected: Git LFS at the start.** Godot's importer plus LFS smudge filters plus CI checkout is three new failure modes for ~60–150 MB of PNGs. Gate it: `art-guard.yml` fails the build if the repo working tree exceeds **750 MB**; that is the signal to introduce LFS for `art/raw/**` only, and it is a one-day migration if it ever fires.

### 1.2 The directory tree

```
Emperors/                                  # git root
├── .github/
│   └── workflows/
│       ├── server.yml                     # paths: server/**, contract/**, balance/**
│       ├── client.yml                     # paths: client/**  (headless Godot test runner)
│       ├── admin.yml                      # paths: admin/**
│       ├── contract-guard.yml             # openapi.yaml changed ⇒ client golden JSON must change
│       └── art-guard.yml                  # asset hygiene + repo size gate
├── .claude/
│   └── skills/
│       └── asset-gen/                     # VENDORED FORK of godogen's skill — committed, patched
│           ├── SKILL.md                   # tokens already substituted (see §1.3)
│           ├── rembg.md
│           ├── EMPERORS-PATCHES.md        # what we changed vs upstream and why
│           └── tools/
│               ├── asset_gen.py           # patched: lazy xai import, --model default gemini,
│               │                          #          --gemini-model flag, tripo3d import removed
│               ├── grid_slice.py          # unmodified
│               ├── rembg_matting.py       # patched: --preview NameError at :312
│               └── requirements.txt       # patched: no xai-sdk / onnxruntime-gpu / nvidia-cudnn
├── .gitignore                             # see §1.5 — art is COMMITTED
├── .env.example                           # committed; real .env is not
├── AGENTS.md                              # project manifest (see §1.3 danger block)
├── CLAUDE.md -> AGENTS.md                 # symlink, matching the author's other repos
├── README.md                              # durable status table + asset table (godogen convention)
├── Makefile                               # the only entry point anyone needs to remember
│
├── docs/
│   ├── 00-vision.md                       # the six-tab brief, verbatim, as the frozen spec
│   ├── 10-architecture.md                 # request lifecycle, authority boundary, caching
│   ├── 20-economy.md                      # every formula in §3 of this doc, with worked examples
│   ├── 30-api.md                          # prose companion to contract/openapi.yaml
│   ├── 40-art-bible.md                    # style anchor, palette, tier colours, sizing rules
│   ├── 50-runbook.md                      # deploy, rollback, secret rotation, incident steps
│   ├── 60-risks.md                        # §6 of this doc, kept live
│   ├── 70-milestones.md                   # §3 of this doc, checkboxes ticked as they land
│   ├── 80-backlog.md                      # where every "wouldn't it be cool if" goes to wait
│   └── adr/
│       ├── 0001-monorepo.md
│       ├── 0002-gdscript-thin-client.md
│       ├── 0003-http-polling-not-websockets.md
│       ├── 0004-balance-in-db-not-in-binary.md
│       └── 0005-vendor-fork-godogen-skill.md
│
├── contract/
│   ├── openapi.yaml                       # SINGLE SOURCE OF TRUTH for the HTTP API
│   ├── errors.md                          # error code enum + client display mapping
│   └── gen.sh                             # oapi-codegen -> server/internal/httpapi/gen/
│
├── balance/                               # shared game data; seeds the DB, never read at runtime
│   ├── jobs.json                          # Collect ladder: energy, gold, xp, unlock_level
│   ├── rarities.json                      # 7 tiers: colour, weight, stat multiplier, sell value
│   ├── items.json                         # weapon/armor/horse templates × art id
│   ├── soldiers.json                      # peasant/mercenary/gladiator: cost, tier weight table
│   ├── slots.json                         # soldier slot price curve
│   ├── levels.json                        # xp curve + stat points per level
│   ├── upgrades_family.json
│   ├── upgrades_kingdom.json
│   ├── combat.json                        # damage formula constants, steal %, shield minutes
│   └── schema/*.schema.json               # JSON Schema; validated in CI and by the admin editor
│
├── client/                                # Godot project root — project.godot lives HERE
│   ├── project.godot                      # config_version=5, 1080x1920, portrait, canvas_items/expand
│   ├── export_presets.cfg                 # iOS preset; team JS3GR55886; com.karabulut.emperors
│   ├── icon.png
│   ├── autoload/
│   │   ├── api.gd                         # HTTPRequest queue, bearer + refresh, retry, timeouts
│   │   ├── session.gd                     # device id, tokens, sign-out, delete-account
│   │   ├── state.gd                       # the client mirror of /v1/state + signals per field
│   │   ├── clock.gd                       # server-time offset; energy/tax interpolation ONLY
│   │   ├── ui.gd                          # tab routing, modal stack, toasts
│   │   ├── theme_db.gd                    # tier colours, icon lookup, rarity frames
│   │   ├── fmt.gd                         # 1.2K / 3.4M / 1:23:45 formatting (unit-tested)
│   │   ├── audio.gd
│   │   ├── haptics.gd
│   │   ├── juice.gd                       # number pops, shakes, tween helpers
│   │   ├── app_lifecycle.gd               # foreground/background -> refresh state
│   │   └── billing.gd                     # STUB in v1 (see cut list §7)
│   ├── scripts/
│   │   ├── net/                           # DTO parse/validate, one file per resource
│   │   ├── model/                         # client-side derived values (display only)
│   │   └── ui/                            # reusable Control scripts, strings.gd
│   ├── scenes/
│   │   ├── Root.tscn                      # tab bar + content stack + top resource bar
│   │   ├── tabs/{Family,Collect,Inventory,Shop,Soldiers,Attack}.tscn
│   │   ├── components/{ItemCard,SoldierCard,JobRow,ResourceBar,TierFrame,...}.tscn
│   │   └── modals/{ItemDetail,Recruit,BattleReplay,WelcomeBack,Odds,DeleteAccount}.tscn
│   ├── ui/theme/                          # Theme resource, StyleBoxFlat set, fonts
│   ├── assets/                            # ONLY what the running game loads. COMMITTED.
│   │   ├── icons/  items/{weapon,armor,horse}/  portraits/  ui/  bg/  fx/
│   │   ├── fonts/
│   │   └── audio/{sfx,music}/
│   ├── ios/
│   │   └── plugins/                       # native iOS plugin binaries, if any (committed)
│   ├── tools/
│   │   ├── build_scenes.gd                # optional; hand-authored .tscn is fine for pure UI
│   │   ├── capture.gd / Capture.tscn      # movie-writer capture harness
│   │   ├── ui_tour.gd / UiTour.tscn       # THE PROOF RITUAL (§5.3)
│   │   ├── verify_assets.gd               # every path in balance/*.json resolves; no missing art
│   │   └── import_art.py                  # art/work/** -> client/assets/**, with sizing rules
│   └── tests/
│       ├── TestRunner.tscn / test_runner.gd
│       ├── test_fmt.gd  test_energy.gd  test_replay.gd  test_dto.gd
│       └── golden/                        # JSON captured by the Go e2e suite (§5.2)
│
├── server/
│   ├── go.mod                             # module github.com/yigitkarabulut0/emperors/server
│   ├── cmd/
│   │   ├── emperors/main.go               # the API + admin API, one binary
│   │   └── emperorsctl/main.go            # seed, bots, loadgen, backfill, balance import
│   ├── internal/
│   │   ├── httpapi/                       # routing, middleware, DTOs, gen/ (oapi-codegen output)
│   │   ├── auth/                          # device auth, JWT issue/verify, refresh rotation
│   │   ├── store/                         # pgx; store.go interface, postgres.go, memory.go
│   │   ├── balance/                       # versioned balance loading + hot reload
│   │   ├── economy/                       # energy, gold, xp, levels, tax, ledger
│   │   ├── collect/                       # job payouts + milestone counters
│   │   ├── shop/                          # deterministic 5-min window rolls
│   │   ├── items/                         # rolling, stats, equip rules
│   │   ├── soldiers/                      # slots, recruitment tier rolls, power
│   │   ├── combat/                        # deterministic seeded battle sim + replay encoding
│   │   ├── matchmaking/                   # OpponentSource: bots (M3.5) then players (M4)
│   │   ├── kingdom/                       # clans, invites, upgrades, reputation
│   │   ├── leaderboard/                   # materialised ranks, refreshed on a schedule
│   │   ├── idem/                          # Idempotency-Key store (Redis)
│   │   ├── ratelimit/                     # Redis token buckets
│   │   ├── antifraud/                     # gold/hour anomaly detection, flags
│   │   ├── adminapi/                      # what admin/ talks to; separate auth
│   │   ├── iap/                           # App Store Server API JWS verify — DORMANT in v1
│   │   └── telemetry/                     # slog + prom metrics
│   ├── migrations/                        # goose; 0001_init.sql ... run with the DIRECT DSN
│   ├── e2e/                               # plays a whole session against a live server
│   ├── loadtest/                          # vegeta targets + emperorsctl loadgen scenarios
│   └── testdata/                          # golden replays, golden balance snapshots
│
├── admin/                                 # Next.js 16.3.x (LTS), App Router, TypeScript
│   ├── app/
│   │   ├── (auth)/login/page.tsx
│   │   └── (dash)/
│   │       ├── players/[id]/page.tsx       # inspect, grant, ban, shield, wipe
│   │       ├── economy/page.tsx            # gold created vs destroyed, per source, per day
│   │       ├── balance/page.tsx            # THE BALANCE EDITOR (JSON Schema driven forms)
│   │       ├── kingdoms/page.tsx
│   │       └── flags/page.tsx              # feature flags + anti-fraud queue
│   ├── lib/api.ts                         # server-side fetch to the Go admin API
│   ├── next.config.ts  package.json  tsconfig.json
│   └── (deployed to Vercel; never talks to Postgres directly)
│
├── art/                                   # GENERATION WORKSPACE — outside client/assets by design
│   ├── style/                             # the locked style anchors (gemini-3-pro-image)
│   │   ├── anchor-item.png                # the one image every item is i2i'd from
│   │   ├── anchor-ui.png
│   │   └── palette.png
│   ├── prompts/                           # the EXACT prompt text used, one file per batch
│   │   └── b03-swords-common-rare.md
│   ├── raw/                               # kept sheets straight out of Gemini. COMMITTED.
│   │   └── b03-swords-common-rare/sheet.png
│   ├── work/                              # sliced + matted intermediates. COMMITTED.
│   │   └── b03-swords-common-rare/{sliced,clean}/
│   ├── rejects/                           # GITIGNORED. Nothing here is ever promoted.
│   ├── manifest.csv                       # name,type,tier,px,path,model,size,cost_cents,prompt
│   └── scripts/
│       ├── gen_batch.sh                   # one 4x4 sheet -> raw/
│       ├── slice_and_matte.sh             # grid_slice + rembg_matting --batch -> work/clean/
│       └── promote.sh                     # work/clean/* -> client/assets/*, appends manifest.csv
│
├── infra/
│   ├── Dockerfile                         # multi-stage, distroless, static Go binary
│   ├── compose.yaml                       # server + redis + caddy (prod), + postgres:18 (local)
│   ├── caddy/Caddyfile                    # TLS for api.<domain> — iOS ATS requires real HTTPS
│   ├── deploy.sh                          # ssh: pull image, goose up (DIRECT dsn), compose up -d
│   ├── keepwarm.cron                      # SELECT 1 every 4 min — beats Neon autosuspend
│   └── cloud-init.yaml                    # a fresh VPS to running in one paste
│
├── proof/                                 # milestone evidence, per §5.3. COMMITTED (compressed).
│   ├── M0/{01-launch.png,contact.png,device.mp4,db.txt}
│   └── M1/... M2/... etc.
│
└── scripts/
    ├── bootstrap-machine.sh               # §2.4, idempotent, safe to re-run
    ├── vendor-asset-gen.sh                # §1.3 — the SAFE godogen import
    └── preflight.sh                       # verifies every tool + secret before you start work
```

### 1.3 Bringing in godogen's asset-gen skill **safely**

`~/Developer/godogen-src/publish.sh` is hostile to an existing repo. Read the script: at line ~85 it does

```bash
if [ "$FORCE" -eq 1 ] && [ -d "$TARGET" ]; then
    rm -rf "${TARGET:?}"          # ← deletes YOUR ENTIRE REPO
```

and even without `--force` it does

```bash
rsync -a --delete "$TMP/skills/" "$TARGET/$SKILLS_DIR_REL/"   # ← wipes sibling skills in .claude/skills/
```

and, if you have no `.gitignore` yet, writes one containing `assets`, `screenshots`, `.godot`, `*.import`, `.claude`, `CLAUDE.md`, `godot.md` — which would silently exclude every paid PNG, every Godot import descriptor, and the skill itself from version control.

**Decision: fork, do not sync.** Vendor once, commit the result, and from that moment treat
`.claude/skills/asset-gen/` as *our* source. Upstream updates are a manual `diff` against a pinned
godogen commit, never an rsync.

`scripts/vendor-asset-gen.sh` — the only sanctioned import path:

```bash
#!/usr/bin/env bash
# Import ONLY the asset-gen skill from a godogen checkout. Never deletes outside
# .claude/skills/asset-gen/. Never writes a .gitignore. Never runs publish.sh.
set -euo pipefail

SRC="${GODOGEN_SRC:-$HOME/Developer/godogen-src}"
ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
DST="$ROOT/.claude/skills/asset-gen"

[ -d "$SRC/asset-gen" ] || { echo "no asset-gen at $SRC"; exit 1; }
[ -n "$(git -C "$ROOT" status --porcelain)" ] && { echo "commit first — this overwrites $DST"; exit 1; }

mkdir -p "$DST"
# --delete is scoped to DST, which contains nothing but this skill. Sibling
# skills under .claude/skills/ are untouched because DST is the skill dir itself.
rsync -a --delete \
  --exclude='__pycache__/' \
  --exclude='tools/tripo3d.py' \
  "$SRC/asset-gen/" "$DST/"

# Substitute the tokens publish.sh would have rendered.
python3 - "$DST" <<'PY'
import pathlib, sys
sub = {
    "${AGENT_NAME}": "Claude",
    "${ASSET_GEN_SKILL_DIR}": ".claude/skills/asset-gen",
    "${ASSET_SKILL_COMMAND}": "/asset-gen",
    "${RUNTIME_ASSET_DIR}": "client/assets",
}
for p in pathlib.Path(sys.argv[1]).rglob("*.md"):
    t = p.read_text()
    for k, v in sub.items():
        t = t.replace(k, v)
    p.write_text(t)
PY

echo "Vendored. Now re-apply the Emperors patches (see EMPERORS-PATCHES.md) and review the diff."
```

**The four patches, applied once and committed** (documented in `EMPERORS-PATCHES.md`):

1. **`tools/requirements.txt`** — remove `xai-sdk` (no key), `onnxruntime-gpu` and
   `nvidia-cudnn-cu12==9.*` (**no Apple Silicon wheels exist**). Add plain `onnxruntime` — the
   official macOS arm64 wheels are built `--use_coreml`, so they include the CoreML EP and are the
   right package here. Also drop `tripo3d`-only deps.
2. **`tools/asset_gen.py`** — `import xai_sdk` is at module scope (line ~21), so **today the tool
   cannot run at all without the xAI SDK installed, even with `--model gemini`.** Move it inside
   `_generate_grok()`. Same for `from tripo3d import ...` — delete it and the `glb`/`rig`/
   `retarget`/`resume` subcommands, since we have no Tripo3D key and the 3D path is out of scope.
3. **`tools/asset_gen.py`** — flip the `--model` default from `grok` to `gemini`, and replace the
   hardcoded `GEMINI_MODEL = "gemini-3.1-flash-image-preview"` with a `--gemini-model` flag,
   default `gemini-3.1-flash-image-preview`, allowed value `gemini-3-pro-image` for the style
   anchors. (Verified pricing, Sept 2026: 3.1 Flash Image ≈ $0.067 at 1K; 3 Pro Image ≈ $0.134 at
   1K/2K, $0.24 at 4K. The skill's own 5/7/10/15¢ table is the Flash tier.)
4. **`tools/rembg_matting.py:312`** — `make_qa_preview(out, output_path, bg_color)` references
   `bg_color`, which only exists inside `remove_background()` (bound at line 169). Single-image
   `--preview` raises `NameError`. Fix: have `remove_background()` return the sampled colour
   alongside the image, or recompute `sample_bg_color()` in `main()` before the preview call.

**Guardrails, written into `AGENTS.md` at the top:**

```markdown
## DANGER — do not run godogen's publish.sh against this repo

~/Developer/godogen-src/publish.sh --force does `rm -rf` on its target directory and
`rsync --delete` on .claude/skills/. Pointing it at Emperors destroys the repository.
The asset-gen skill in .claude/skills/asset-gen/ is a COMMITTED FORK with four local
patches (see .claude/skills/asset-gen/EMPERORS-PATCHES.md). Re-import only via
scripts/vendor-asset-gen.sh, and only on a clean working tree.
```

Belt and braces: `chmod -w ~/Developer/godogen-src/publish.sh` on the dev machine, and keep
`GODOGEN_SRC` unset in the shell so a stray invocation has no default target.

### 1.4 Art discipline (what makes the monorepo viable)

* **`art/` never lives under `client/`.** Godot's importer walks the project directory; a 4K
  generation sheet under `client/` becomes an imported `.ctex` nobody uses and bloats every export.
  Since `art/` is a sibling of `client/`, Godot never sees it and no `.gdignore` is needed.
* **Only kept work is committed.** Rejected generations go to `art/rejects/` (gitignored) and are
  deleted. `art/raw/` holds the sheets that actually produced shipped assets — that is the audit
  trail that justified the spend, and it is what you regenerate variants from.
* **`art/manifest.csv` is mandatory.** Columns: `name,type,tier,px,path,model,size,cost_cents,prompt_file`.
  `make art-cost` sums the column. `art-guard.yml` fails a PR that adds files under
  `client/assets/` without touching `art/manifest.csv`.
* **Display size discipline.** The skill's own warning applies: minimum generation is 1K, so design
  every in-game icon at **≥128 px display**, and never generate single icons — one 2K sheet at
  4×4 gives sixteen 512 px cells for $0.10.

### 1.5 `.gitignore` (the parts that matter)

```gitignore
# --- secrets ---
.env
.env.*
!.env.example
*.p8
*.p12
*.cer
*.mobileprovision
infra/secrets/

# --- Godot ---
client/.godot/
client/android/
client/ios/build/
build/
*.translation

# --- Go ---
server/bin/
server/tmp/
server/emperors

# --- Next.js ---
admin/node_modules/
admin/.next/
admin/.vercel/

# --- Python art pipeline ---
.venv/
__pycache__/
*.pyc

# --- art: rejects only ---
art/rejects/

# --- proof: keep the compressed artefacts, drop the raw ---
proof/**/raw/
proof/**/*.mov

.DS_Store

# ==========================================================================
# DELIBERATELY NOT IGNORED. godogen's generated .gitignore excludes these and
# it is wrong for a commercial project:
#   client/assets/**   paid art — must be versioned
#   art/raw/**         the kept generation sheets — the audit trail for spend
#   .claude/skills/**  our forked asset-gen tooling
#   *.import, *.uid    Godot resource identity. Losing a .uid reimports the
#                      asset under a new UID and silently breaks every
#                      reference to it in every .tscn.
# ==========================================================================
```

### 1.6 Client display settings (pin these in `project.godot` on day one)

```ini
config_version=5
[display]
window/size/viewport_width=1080
window/size/viewport_height=1920
window/size/resizable=false
window/stretch/mode="canvas_items"
window/stretch/aspect="expand"       # NOT keep_width: anchored top/bottom bars must
                                     # hold their edges across iPhone aspect ratios
window/handheld/orientation=1        # portrait
```

`expand` rather than GameTest's `keep_width` because Emperors is anchored-Control UI, not a
fixed-aspect play field. Handle the notch with `DisplayServer.get_display_safe_area()` in
`Root.tscn` and pad the top/bottom bars from it — never hardcode 44 px.

---

## 2. Environment and secrets

### 2.1 The secret inventory

| Secret | Dev location | Prod location | Notes |
|---|---|---|---|
| `DATABASE_URL` | repo-root `.env` | `/etc/emperors/emperors.env` (0600 root) | Neon **pooled** (`…-pooler…`), `sslmode=require` |
| `DATABASE_URL_DIRECT` | repo-root `.env` | same file | Neon **unpooled**. Migrations only. PgBouncer transaction mode cannot run them. |
| `EMPERORS_TOKEN_SECRET` | `.env` | same file | ≥32 random bytes. Server **refuses to boot** without it — no default, following the GameTest precedent. |
| `EMPERORS_ADMIN_TOKEN` | `.env` | same file + Vercel env | Bearer for `/admin/*`. Rotated quarterly. |
| `EMPERORS_SHOP_SALT` | `.env` | same file | Seeds the deterministic shop roll. **If this leaks, players can predict shop contents.** |
| `REDIS_URL` | `redis://127.0.0.1:6379` | `redis://redis:6379` (compose network) | Cache only, never truth |
| `GOOGLE_API_KEY` | `.env` **only** | never on prod | Art generation is a dev-machine activity |
| App Store Connect API key (`.p8`) | `~/.appstoreconnect/private/AuthKey_XXX.p8`, **outside the repo** | GitHub secret (base64) if TestFlight ever moves to CI | `fastlane` reads it via `APP_STORE_CONNECT_API_KEY_PATH` |
| Apple signing cert / profile | macOS Keychain + `~/Library/MobileDevice/Provisioning Profiles/` | n/a | Never in git. `*.p12`/`*.mobileprovision` are gitignored as a tripwire. |
| `DEPLOY_SSH_KEY` | `~/.ssh/emperors_deploy` | GitHub secret | ed25519, deploy-only user on the VPS |

**Hard rules.** No secret ever reaches the Godot client — the client holds only a base URL and its
own device token. No secret is baked into the Docker image; prod reads them via
`env_file: /etc/emperors/emperors.env` in `compose.yaml`. The admin panel never gets a
`DATABASE_URL`; it talks to the Go admin API and its token is a server-only Vercel env var (never
`NEXT_PUBLIC_*`).

### 2.2 `.env.example` (committed)

```bash
# ---- database (Neon, eu-west-2 London) --------------------------------------
# Pooled: what the server uses. Note the "-pooler" in the host.
DATABASE_URL=postgresql://USER:PASS@ep-xxxx-pooler.eu-west-2.aws.neon.tech/emperors?sslmode=require
# Direct/unpooled: goose migrations ONLY. PgBouncer transaction mode cannot run DDL sessions.
DATABASE_URL_DIRECT=postgresql://USER:PASS@ep-xxxx.eu-west-2.aws.neon.tech/emperors?sslmode=require

# ---- server ------------------------------------------------------------------
EMPERORS_ADDR=:8080
EMPERORS_TOKEN_SECRET=            # openssl rand -base64 48
EMPERORS_ADMIN_TOKEN=             # openssl rand -hex 32
EMPERORS_SHOP_SALT=               # openssl rand -hex 32
EMPERORS_ENV=dev                  # dev | staging | prod
REDIS_URL=redis://127.0.0.1:6379

# ---- art pipeline (dev machine only) -----------------------------------------
GOOGLE_API_KEY=                   # https://aistudio.google.com/apikey

# ---- client -------------------------------------------------------------------
# Not read by the server. Used by `make run-client` to pass --api= to Godot.
EMPERORS_API_URL=http://127.0.0.1:8080
```

The `Makefile` is the loader — no `direnv` (not installed), no `godotenv` dependency:

```make
ifneq (,$(wildcard ./.env))
include .env
export
endif
```

The client is pointed at a backend two ways, never by an env var read at runtime:
`OS.get_cmdline_user_args()` for `--api=…` in dev (the GameTest pattern in `autoload/api.gd`), and
a per-preset `ProjectSettings` override `emperors/api_url` baked into the export preset for
device builds. Empty string means "no backend", which must render a clean offline screen rather
than crash — that is a test case, not an aspiration.

### 2.3 What a new machine needs

`scripts/preflight.sh` prints a pass/fail table and is the first thing anyone runs:
git · gh (authenticated) · Godot 4.7.2 · `ios.zip` export template present · Go 1.27 · `goose`,
`sqlc`, `air`, `oapi-codegen`, `staticcheck`, `govulncheck` resolvable on PATH · Node 22 · Docker
daemon reachable · Redis reachable · `.venv/bin/python` exists and imports `google.genai` and
`rembg` · `.env` present with every key in `.env.example` non-empty · `psql "$DATABASE_URL" -c 'select 1'`
succeeds · Xcode present with a valid `Apple Development` identity.

### 2.4 One-time machine setup — the exact commands, in order

```bash
# 1. Put the Go tool bin on PATH. This is the blocker today: goose, sqlc, air,
#    oapi-codegen and staticcheck are all installed in ~/go/bin and none of them
#    resolve. ~/.zshrc currently sets only libpq, nvm and bun.
printf '\n# Go tools\nexport PATH="$HOME/go/bin:$PATH"\n' >> ~/.zshrc
exec zsh -l
command -v goose sqlc air oapi-codegen staticcheck govulncheck    # all six must print

# 2. Start the Docker daemon (colima is installed but stopped).
colima start --cpu 4 --memory 8 --disk 60
docker info >/dev/null && echo "docker ok"

# 3. Start Redis (installed, stopped).
brew services start redis
redis-cli ping                                                    # PONG

# 4. Art pipeline venv on Python 3.12 — NOT 3.14.
#    onnxruntime has no 3.14 wheels; homebrew python3.12 is already on the box.
uv venv --python /opt/homebrew/bin/python3.12 .venv
uv pip install --python .venv/bin/python \
    google-genai requests numpy pillow rembg pymatting onnxruntime
.venv/bin/python -c "import onnxruntime, rembg; from google import genai; print('art ok')"

# 5. The one missing Go tool we actually need (load testing).
go install github.com/tsenart/vegeta/v12@latest

# 6. Neon connectivity, BEFORE writing any code.
psql "$DATABASE_URL" -c 'select version(), current_database(), now();'
psql "$DATABASE_URL_DIRECT" -c 'select 1;'
#    NOTE: local psql is 17.5 against an 18.6 server. Queries work; pg_dump does NOT.
#    For backups/dumps use the matching major version from a container:
#      docker run --rm postgres:18 pg_dump "$DATABASE_URL_DIRECT" > backup.sql

# 7. Apple signing. There are currently ZERO provisioning profiles on this machine.
#    Do this on day one of M0, not on the day you try to ship.
open -a Xcode        # Settings ▸ Accounts ▸ add the Apple ID for team JS3GR55886
                     # then "Download Manual Profiles"
#    Register the test iPhone's UDID at developer.apple.com ▸ Devices.
#    Create App ID com.karabulut.emperors (explicit, not wildcard).
ls ~/Library/MobileDevice/Provisioning\ Profiles/        # must be non-empty afterwards

# 8. Godot export templates. Only ios.zip is present for 4.7.2.stable.
#    iOS needs nothing more. macOS/Windows/Linux templates are only needed at
#    M9c (Steam); Android at M9b; Web is out of scope entirely.
#    Editor ▸ Editor ▸ Manage Export Templates ▸ Download and Install — when you get there.

# 9. Vendor the asset-gen skill (once, on a clean tree).
./scripts/vendor-asset-gen.sh && ./scripts/preflight.sh
```

**Not needed and deliberately not installed:** JDK 17 / Android SDK (M9b only), Rust, Chrome,
golangci-lint (`staticcheck` + `go vet` is enough; `govulncheck` is already present), the .NET SDK
(we are on GDScript — `dotnet` is present but irrelevant).

---

## 3. Milestone roadmap

Effort is in **focused engineering days** for one developer with AI assistance. Total to a
TestFlight-ready iOS build: **≈ 59 days ≈ 12 calendar weeks.**

### Cross-cutting architecture the milestones assume

* **Transport:** HTTPS JSON only. No WebSockets in v1 (ADR-0003). The client polls `/v1/state` on
  foreground and after every mutation; every mutating response returns the affected state slice plus
  a monotonically increasing `state_version`, so the UI never needs a second round trip.
* **Time is the server's.** Every accrual (energy, tax, shield, shop window) is computed from
  Postgres `now()` inside the same statement that reads the row. **`time.Now()` in Go is never used
  for accrual math** — a container clock skew would mint free energy for everybody.
* **Nothing ticks.** Energy and tax are lazily materialised on read. There is no background job
  incrementing rows; that would be a write per player per minute for zero benefit.
* **Idempotency everywhere.** Every mutating request carries an `Idempotency-Key` header; the
  server stores `(player_id, key) → response` in Redis for 24 h. A flaky mobile connection retrying
  a `POST /v1/collect` must not double-pay.
* **Redis is a cache, never truth.** Losing Redis loses rate-limit counters and idempotency records
  for 24 h. It must never lose gold.
* **Balance lives in the DB** (ADR-0004): a `balance_versions(id, json jsonb, active bool, created_at, note)`
  table seeded from `balance/*.json` by `emperorsctl balance import`. One active version; the server
  hot-reloads it every 60 s. This is what makes the M7 balance editor possible without a client release.
* **`OpponentSource` is an interface** from the start: `BotSource` in M3.5, `PlayerSource` in M4.
  This is the single decision that lets the vertical slice land four weeks early.

### The formulas (put these in `docs/20-economy.md`)

**Energy** — stored as `energy int`, `energy_ts timestamptz`:

```
gained    = floor(extract(epoch from now() - energy_ts) / regen_seconds)
energy'   = least(max_energy, energy + gained)
energy_ts'= case when energy' >= max_energy then now()
                 else energy_ts + (gained * regen_seconds) * interval '1 second' end
```

Advancing `energy_ts` by whole ticks rather than to `now()` is what stops the sub-tick remainder
being thrown away on every read — otherwise a player who opens the app every 50 s never regenerates.

**Collect payout**

```
gold = floor(job.base_gold
             * (1 + job_milestone_bonus(collects))
             * (1 + family_income_bonus + kingdom_income_bonus))
xp   = floor(job.base_xp * (1 + family_xp_bonus + kingdom_xp_bonus))

job_milestone_bonus(n) = 0.15 if n >= 100 else 0.10 if n >= 50 else 0.05 if n >= 25 else 0
```

(Replace-not-stack. See open question 2 — cumulative would give +30 % at 100.)

**Levels** — `xp_to_next(L) = floor(50 * L^1.8)`; 1 stat point per level, +1 extra on every 5th.

**Hybrid tax**

```
tax_per_sec = base_tax * (1 + family_tax_bonus + kingdom_tax_bonus)
accrued     = floor(least(28800, extract(epoch from now() - tax_ts)) * tax_per_sec)
```

Claiming sets `tax_ts = now()`. The 8 h cap is `28800`, in `balance/combat.json`, not a constant.

**Power** — the number on the Family tab, and the matchmaking key:

```
unit_power  = (unit.atk * 1.0 + unit.def * 0.8)
total_power = floor( (player_unit + Σ soldier_units) * (1 + family_soldier_bonus) )
```

**PvP steal — a transfer, never a mint:**

```
steal = least( floor(defender.gold * 0.03), 500 * defender.level^1.5 )
```

Both sides move in one transaction. If the attacker's gain is minted rather than transferred, the
economy inflates by 3 % of the loser's bank on every fight, forever.

**Shop window** — deterministic, so a reconnect cannot reroll:

```
window_id = floor(unix_epoch / 300)
seed      = sha256(EMPERORS_SHOP_SALT || player_id || window_id)
```

Six slots rolled from the tier weight table; purchase is idempotent on `(player_id, window_id, slot)`.

**Tier weights** (starting point; these are the numbers that must be displayed in-app for App Store
guideline 3.1.1): common 45 %, uncommon 27 %, rare 15 %, epic 8 %, legendary 3.5 %, mystic 1.2 %,
special 0.3 %.

---

### M0 — The pipe · 3 days

**Goal.** Prove the entire chain — physical iPhone → HTTPS → Go on the VPS → Neon → back — before
a single line of game logic exists.

**The smallest thing that proves the whole pipe.** One button and one label. Tapping the button
calls `POST /v1/auth/device` with a locally-generated device hash; the server upserts a row in
Neon's `players` table, adds 1 gold, and returns `{player_id, gold}`; the label shows the gold.
This single tap exercises, in order: iOS App Transport Security against a real TLS cert, DNS,
Caddy, the Go binary in Docker on the VPS, a pgx connection through Neon's **pooled** endpoint, a
write, a read, and JSON deserialisation in GDScript. Then: force-quit the app, reopen, tap again —
the gold is 2. Then run `psql "$DATABASE_URL" -c 'select id, gold from players'` and see the same
number. Persistence, authority and identity, all proven, with about 150 lines of code.

Do it over **cellular with wifi off**, not just on the LAN. A localhost-only success proves nothing
about ATS or about the VPS firewall.

**Deliverables.**
* Repo created, tree from §1.2 scaffolded, `.gitignore` from §1.5, `AGENTS.md` with the publish.sh
  danger block, `Makefile`, `scripts/{bootstrap-machine,preflight,vendor-asset-gen}.sh`.
* `.claude/skills/asset-gen/` vendored and all four patches applied and committed.
* **server:** `cmd/emperors` with `/healthz`, `/v1/auth/device`; `internal/store` with a pgxpool
  configured for Neon (see risk R1/R2); goose `0001_init.sql` creating `players`; `slog` JSON logs.
* **db:** first migration applied to Neon via `DATABASE_URL_DIRECT`; autosuspend raised; the
  keep-warm cron installed.
* **infra:** `Dockerfile`, `compose.yaml`, `Caddyfile`, `deploy.sh`; a VPS provisioned **in London
  or Falkenstein** (see risk R3), DNS `api.emperors.<domain>` → VPS, Let's Encrypt cert live.
* **client:** Godot project with the §1.6 display settings, `autoload/api.gd` and
  `autoload/session.gd`, one scene, `export_presets.cfg` with team `JS3GR55886` and bundle
  `com.karabulut.emperors`; an `.ipa` installed on the iPhone.
* **CI:** `server.yml` and `client.yml` green.
* **art:** none.

**Definition of done.** A screen recording from the iPhone, on cellular, showing tap → number →
force quit → reopen → number persisted; plus `psql` output showing the matching row. Both committed
to `proof/M0/`.

**Known traps.** iOS ATS will reject plain HTTP and self-signed certs — Caddy + a real domain
solves it and there is no shortcut worth taking. The first request after a quiet period will hit
Neon's cold start (~300–800 ms); set the pgx connect timeout to ≥10 s or M0 will look broken when
it is merely asleep. Expect to lose half a day to provisioning profiles — the machine has none
today.

---

### M1 — The core loop · 7 days

**Goal.** A real game: the Collect tab, energy, gold, XP, levels, and a persistent authoritative
state snapshot. Grey-boxed.

**Deliverables.**
* **server:** `GET /v1/state` (the full snapshot), `POST /v1/collect/{job_id}`,
  `POST /v1/stats/allocate`, `POST /v1/auth/refresh`, `DELETE /v1/account` (build it now — App Store
  5.1.1(v) requires it and it is ten times cheaper here than at M9). `internal/economy` with the
  energy, XP and level formulas; `internal/collect` with per-job counters and milestone bonuses;
  a `gold_ledger` table appended to on *every* gold delta with a reason enum — this is the only
  way M7's economy dashboard and R8's inflation detection are possible later.
* **db:** `players`, `player_stats`, `job_progress`, `gold_ledger`, `refresh_tokens`, `balance_versions`.
* **client:** `Root.tscn` with the six-tab bottom bar (five tabs stubbed with a "coming in Mx"
  card — do not hide them, the tab bar is the product's shape and it should be visible from day
  one); the Collect tab as a `VBoxContainer` of `JobRow`s; the top resource bar with gold / energy /
  XP; `autoload/clock.gd` interpolating energy between snapshots so the bar moves smoothly without
  the client ever deciding what the energy actually is; `fmt.gd` number formatting; a level-up modal;
  tap juice.
* **balance:** `jobs.json` (~12 jobs, Grapes → Strawberries → … ), `levels.json`.
* **art:** grey-box only — flat `StyleBoxFlat` panels, one placeholder icon, one font.
  **Start the M8 style-anchor work in parallel here** (see parallelism note).

**Definition of done.** Ten minutes of tapping on the phone takes a fresh account from level 1 to
about level 5; energy visibly drains and regenerates; killing the app and reopening restores exactly
the server's state; setting the device clock forward gains the player nothing.

---

### M2 — Items, inventory, shop · 5 days

**Goal.** Gold has somewhere to go, and randomness enters the game.

**Deliverables.**
* **server:** `internal/items` (rolling an instance from a template × tier), `internal/shop`
  (deterministic window rolls, §3 formula), `GET /v1/shop`, `POST /v1/shop/buy`,
  `GET /v1/inventory`, `POST /v1/inventory/sell`.
* **db:** `item_templates` (seeded from balance), `items` (instances, owner, equipped_on),
  `shop_purchases` (the idempotency ledger keyed on `player_id, window_id, slot`).
* **client:** Inventory tab (grid, rarity frames, type filter, sort by power), Shop tab (six slot
  cards + a live countdown to the next window driven by `clock.gd`), `ItemDetail` modal,
  **an Odds screen** listing the tier weights — build it with the shop, not at submission time.
* **balance:** `rarities.json`, `items.json`.
* **art:** first real batch — one 2K 4×4 sheet of common/uncommon swords, i2i from the style anchor.
  This is the batch that proves the pipeline end to end for about $0.10.

**Definition of done.** Buy from the shop; gold decrements; the item appears in inventory with the
right tier colour; force-quit and reopen mid-window and the *same six items* are still there;
wait out the window and they change. Two devices logged into the same account see the same shop.

---

### M3 — Soldiers, equipment, power · 5 days

**Goal.** The power number, and the reason to keep buying items.

**Deliverables.**
* **server:** `internal/soldiers` (slot price curve, recruitment tier roll per type),
  `POST /v1/soldiers/slot`, `POST /v1/soldiers/recruit`, `POST /v1/soldiers/{id}/equip`,
  `POST /v1/player/equip`; power computed server-side and returned in `/v1/state`.
* **db:** `soldier_slots`, `soldiers`, plus `items.equipped_on` / `items.equipped_slot`.
* **client:** Soldiers tab (slot grid, locked slots showing the next price, recruit modal with the
  three types and **their tier odds shown**), soldier detail with three equipment slots and a
  drag-or-tap equip flow, Family tab roster + total power.
* **balance:** `soldiers.json`, `slots.json`.
* **art:** soldier portraits by tier — one 2K sheet per soldier type, seven cells each.

**Definition of done.** Total power on the Family tab equals a number computed by hand from the
formula in `docs/20-economy.md`. Equipping and unequipping changes it correctly and immediately.
Buying the third slot costs visibly more than the second.

---

### M3.5 — **The vertical slice**: Attack the bots · 4 days

**Goal.** Close the loop. This is the milestone where Emperors becomes fun (§4).

**Deliverables.**
* **server:** `internal/combat` — a deterministic, seeded round-based simulation that emits a
  compact replay (an array of `{round, actor, target, damage, remaining_hp}`); `internal/matchmaking`
  with the `OpponentSource` interface and a `BotSource` that synthesises opponents from the player's
  own power band using the same item/soldier roll code; `POST /v1/attack` costing energy and
  awarding gold from a bot pool (not from a player — bots mint, and that is fine and bounded because
  bot gold is capped per day).
* **client:** Attack tab with an opponent card and a "Find opponent" button; the
  `BattleReplay` modal animating the server's replay round by round; a result screen.
* **DoD:** the same `attack_id` replayed twice produces a byte-identical animation. A ten-minute
  session on the phone is genuinely enjoyable (§4 walkthrough).

**Why this exists as its own milestone.** It de-risks M4 enormously. The battle simulator, the
replay format and the replay animation — the three hardest and most bug-prone pieces of PvP — all
ship and get exercised here, against opponents that cannot be harmed by a bug. M4 then only has to
swap the `OpponentSource` implementation and add the social consequences.

---

### M4 — Real PvP, shields, battle log · 5 days

**Deliverables.**
* **server:** `PlayerSource` — candidates where `power between 0.75×p and 1.25×p`, `level between
  L-3 and L+5`, `shield_until < now()`, `kingdom_id is distinct from mine`, not attacked by me in
  the last hour. **Do not write `ORDER BY random()`** — that is a full scan on the player table.
  Sample against a btree index on `power`: pick a random `power` inside the band, take the five
  rows on either side with `WHERE power >= x ORDER BY power LIMIT 5`, cache the candidate list in
  Redis for 60 s. Gold **transfers** (§3). A defender who loses gets `shield_until = now() + 30 min`.
  Attack rate limit per attacker; incoming-attack limit per defender per hour.
* **db:** `attacks` (both sides, seed, replay blob, gold moved), `players.shield_until`.
* **client:** the defender's "you were attacked while away" summary on next foreground; an attack
  log with replay playback; a shield indicator; a revenge button (single-step, no chains).
* **DoD:** two accounts, two devices. A attacks B, B's gold drops by exactly what A gained, B gets
  a shield, A's second attack in the shield window is refused with a clear message and **no energy
  charged**. Both sides can replay the fight and see the same thing.

---

### M5 — Family upgrades and hybrid tax · 4 days

**Deliverables.**
* **server:** `POST /v1/family/upgrade`; the stacking rules pinned in `docs/20-economy.md`
  (additive within a category, multiplicative across categories — write it down once and never
  argue about it again); tax accrual and `POST /v1/tax/claim`.
* **client:** the Family tab upgrade list with before/after previews; the welcome-back modal
  showing offline tax with the 8 h cap made visible ("capped — you were away 11 h").
* **DoD:** close the app for 20 minutes, reopen, claimed tax equals `rate × elapsed` within one
  second of tolerance. Move the *server's* clock forward 12 h in a test and the cap holds at 8 h.

---

### M6 — Kingdoms and leaderboards · 6 days

**Deliverables.**
* **server:** found (large gold cost) / invite / accept / leave / kick / roles; the kingdom upgrade
  tree; reputation accrued per member attack; player and kingdom leaderboards as **materialised
  ranks** refreshed on a schedule (`refresh materialized view concurrently` every 5 min), never
  computed per request; the member-vs-member attack ban enforced in `PlayerSource` *and* re-checked
  at attack time.
* **db:** `kingdoms`, `kingdom_members`, `kingdom_invites`, `kingdom_upgrades`,
  `mv_player_ranks`, `mv_kingdom_ranks`.
* **client:** the kingdom card on the Family tab expanded into a full kingdom screen; browse/join;
  two leaderboards.
* **DoD:** two accounts form a kingdom, cannot find each other in matchmaking, an attack by either
  raises kingdom reputation, and the kingdom appears in the board within one refresh interval.

---

### M7 — Admin panel and balance editor · 5 days · **parallelisable from M2**

**Deliverables.**
* **server:** `internal/adminapi` on a separate route group with its own bearer token and its own
  rate limit; endpoints for player lookup/grant/ban/shield/wipe, the gold ledger aggregated by day
  and reason, the anti-fraud queue, and balance version CRUD + activate + rollback.
* **admin:** Next.js 16.3 App Router. Server Components fetch through `lib/api.ts` with the admin
  token held server-side. The balance editor renders forms from `balance/schema/*.schema.json`, so
  adding a field to the schema adds a field to the UI. Saving creates a new `balance_versions` row;
  activating flips the active flag; the server picks it up within 60 s; one-click rollback.
* **DoD:** change a job's gold payout in the browser, and the phone shows the new payout on its next
  collect **without a client rebuild**. Roll it back and the old value returns.

---

### M8 — Art, audio, juice · 9 days · **style anchor must start during M1**

**Deliverables.**
* **Style lock first.** One `gemini-3-pro-image` 2K anchor (≈$0.13) that defines palette, lighting
  angle, outline weight and material feel. Every subsequent batch is `--image art/style/anchor-item.png`
  image-to-image at 1K flash. This is the single highest-leverage action against style drift.
* **Batches, never singles.** 4×4 sheets at 2K → `grid_slice.py --grid 4x4 --names "..."` →
  `rembg_matting.py --batch` → review as a contact sheet → `promote.sh` into `client/assets/`.
  Prompt a solid mid-grey background, never "transparent" (the model draws a checkerboard).
* Roughly 10–14 sheets: swords ×3 (by tier band), armour ×3, horses ×2, soldier portraits ×2,
  UI icons ×2, tab icons ×1, backgrounds ×2 (9:16).
* **Audio:** `lyria-3-pro` for two or three ambient loops, plus UI SFX; normalise everything with
  `ffmpeg -af loudnorm`.
* **Juice:** Godot 4.7's Control offset transforms make card pops and shelf-slides trivial without
  fighting containers; tween every number change; haptics on purchase and on a won battle.
* **DoD:** the M8 contact sheet placed next to the M2 one shows one coherent visual family. Total
  spend in `art/manifest.csv` under $80.

---

### M9 — Ship

**M9a — iOS TestFlight · 6 days.** App Store Connect record; privacy policy URL live; privacy
nutrition labels; age rating (a game with gold-stealing PvP and randomised purchases is not 4+);
the odds screen linked from both shop and recruit; account deletion reachable in **two taps** from
the Family tab (buried deletion is a documented rejection cause); `fastlane` lane for build →
upload → internal TestFlight; five App Store screenshots per required device size.

**M9b — Android · 4 days + 1 day of setup.** Requires JDK 17, the Android SDK, and Godot 4.7's
Android build environment (which did reach stable in 4.7 with Gradle export support). None of it is
installed. Do not start this before iOS is in external TestFlight.

**M9c — Steam · 4 days.** Requires the macOS/Windows/Linux export templates (not downloaded), a
$100 Steamworks fee, and a real decision about whether a portrait-only touch UI belongs on a desktop
store at all. Treat as post-1.0.

### Parallelism — stated explicitly

| Track | Can run alongside | Reason |
|---|---|---|
| **M7 admin** | M2 → M6 | Only needs `/v1/state`'s shape and the admin API surface, which are stable after M1. Building it early makes M2–M6 balancing possible instead of theoretical. |
| **M8 art (style anchor + first batches)** | M1 → M6 | The anchor gates every later batch, so it must be early. Batches then land per-milestone: item art with M2, soldiers with M3, UI polish at the end. |
| **M9a store paperwork** | M6 → M8 | App Store Connect record, bundle ID, privacy policy, and nutrition labels are pure admin work with a multi-day review latency. Start them during M6. |
| **Load testing** | after M4 | The attack endpoint is the only expensive one; testing before it exists measures nothing. |

Everything else is **strictly serial**: M2 needs M1's state shape, M3 needs M2's items, M3.5 needs
M3's power, M4 needs M3.5's combat, and M5/M6 need M4's economy to be real before their multipliers
mean anything.

---

## 4. The vertical slice

**The slice is the end of M3.5** — roughly four weeks in — and it is defined as: *the smallest build
in which two loops feed each other and a player can see themselves getting stronger.*

Concretely: **Collect (M1) + Inventory & Shop (M2) + Soldiers & Equipment (M3) + Attack-the-bots (M3.5).**
No kingdoms, no family upgrades, no tax, no real PvP, grey-box-to-first-batch art.

**Why this line and not an earlier one.** M1 alone is a tapper — the number goes up, and after
ninety seconds you have learned everything it has to teach. M2 alone adds spending but the items
do nothing, so buying them is an act of faith. M3 adds a power number that nothing consumes.
The slice needs the *consumer* of power, and that is combat. Bots are enough: a ten-minute player
cannot tell whether the opponent is a real account, and the fun comes from "my number beat their
number", not from the other person's existence. Deferring real opponents to M4 costs the slice
nothing and buys four weeks.

**The ten minutes, beat by beat.**

| Minute | What happens |
|---|---|
| 0:00 | Launch. No sign-up wall — device auth, straight into the Collect tab. 50 gold, 20/20 energy. |
| 0:00–2:00 | Tap Grapes eleven times. Gold climbs, energy drains, level 2 pops with a stat point. Allocate it to Max Energy. Strawberries unlock. |
| 2:00–3:30 | Energy is empty. This is the moment the game either loses you or hooks you — so the Shop countdown is visible on the tab bar. Open the Shop. Six items, one of them a blue Rare sword you can't quite afford. |
| 3:30–5:00 | Energy trickles back. Collect Strawberries. Buy the sword. Equip it on the player. Attack Power goes 12 → 41. |
| 5:00–6:30 | Buy the first soldier slot. Recruit a Peasant — the tier roll animates and lands on Uncommon. Equip it with the leftover common armour. Total power 41 → 96. |
| 6:30–9:00 | The Attack tab is now above zero power, so it unlocks. Find an opponent. Watch the replay. Win. Steal 340 gold — more than twenty collects earned. |
| 9:00–10:00 | Attack twice more. Lose one — which stings, and teaches that power matters. Spend the winnings on a second shop refresh. Energy is gone again, and the timer says four minutes. |

That last line is the whole design: at minute ten the player is out of energy, has a specific thing
they want, and knows exactly how long until they can act. That is a game.

**What must be *good*, not merely present, in the slice:** number formatting, the energy bar's
smoothness, the tier colours, the recruit roll animation, and the battle replay pacing. Everything
else can be a grey box.

---

## 5. Testing and proof

### 5.1 Automated tests, by layer

**Go — unit.** Table-driven, no mocks where a pure function will do.
* `economy`: energy accrual across the cap boundary, sub-tick remainder preservation, level curve
  monotonicity, tax cap at exactly 8 h and at 8 h + 1 s.
* `combat`: **golden replays** in `server/testdata/` — the same seed and the same rosters must
  produce a byte-identical replay forever. This test is what makes the client's replay animation
  safe to trust.
* `shop`: the same `(salt, player, window)` yields the same six slots; adjacent windows differ.
* `soldiers` / `items`: roll one million tiers and assert the empirical distribution is within
  0.5 % of the published weights — because those weights are a legal disclosure (§6 R5), not just
  a design knob.
* `auth`: refresh-token rotation, replay of a used refresh token is rejected.

**Go — integration.** `internal/store` against a real Postgres. Two modes:
`make test-int` uses a local `postgres:18` from `infra/compose.yaml` (fast, offline); CI uses a
**Neon branch created per PR via the Neon API and deleted on merge** — because the local container
does not have PgBouncer in front of it and therefore cannot catch R1, which is the whole point.

**Go — e2e.** `server/e2e/` uses the `oapi-codegen`-generated client to play a complete session
against a running server: register → 20 collects → level up → allocate → buy → equip → recruit →
equip → attack → verify the ledger balances. It runs in CI against the Neon branch and, before
each deploy, against staging. **It also writes `client/tests/golden/*.json`** — every response it
saw — which is how the client's DTO tests stay honest.

**Go — static.** `go vet`, `staticcheck ./...`, `govulncheck ./...`, `go test -race ./...`.
All four are already installed; none of them are optional.

**Godot — headless.** Follow the GameTest pattern exactly: `client/tests/TestRunner.tscn` run as a
*scene*, not a `--script` MainLoop, so autoloads resolve the way they do in the real game.

```bash
godot --headless --path client --import
godot --headless --path client res://tests/TestRunner.tscn
```

Tests: `fmt.gd` formatting across magnitudes and locales-of-one; `clock.gd` energy interpolation
never exceeding the server value; replay animation state machine driven by a golden replay; and
**`test_dto.gd`, which parses every file in `tests/golden/` and asserts every field it needs is
present and correctly typed.** A server-side field rename now breaks a client test in CI instead of
breaking a player's phone.

`client/tools/verify_assets.gd` runs in the same pass: every art path referenced from `balance/*.json`
must resolve to a real, imported resource. A missing icon is a red CI job, not a pink placeholder
discovered in review.

**Admin.** `tsc --noEmit`, `next build`, `eslint`. No component tests in v1 — it is an internal tool
with one user; the balance editor is protected by JSON Schema validation on the server side, which is
where it matters.

**Contract guard.** `contract-guard.yml` fails any PR that changes `contract/openapi.yaml` without
also changing `client/tests/golden/**`. It is crude and it works.

### 5.2 Load testing

Two tools, two jobs.

* **`emperorsctl loadgen`** — the realistic one. Spawns *N* simulated players with human think times
  (collect every 3–8 s until energy is gone, then idle 4–10 min, then a shop check, then an attack),
  driving the same generated client the e2e suite uses. This is what you run for an hour to find
  connection-pool exhaustion and lock contention.
* **`vegeta`** — the brutal one, for single-endpoint p99 under a fixed rate:
  `vegeta attack -targets=server/loadtest/state.txt -rate=200/s -duration=60s | vegeta report`.

**Targets for v1 launch** (measured from the VPS's own region, then again from a phone):
`GET /v1/state` p99 < 150 ms · `POST /v1/collect` p99 < 120 ms · `POST /v1/attack` p99 < 250 ms ·
1,000 concurrent simulated players on a 4 vCPU VPS with zero 5xx.

**What to watch while it runs, and what each means:** pgxpool `AcquireDuration` (rising ⇒ raise
`MaxConns` or the query is slow); Neon's active connection count against the pooler ceiling; Redis
`used_memory`; and the shape of the `/v1/state` latency histogram — if it is *bimodal* with a
cluster around 700 ms, that is Neon waking up (R2), not your code.

### 5.3 The proof ritual — our replacement for godogen's video mandate

godogen's manifest demands "a 15–20 s video of the game in action". For a 3D action game that is
the right instrument. For Emperors it is the wrong one: a video cannot be diffed, cannot be scanned
in three seconds, and gives you one arbitrary frame of each screen. Our regressions are layout,
state and numbers.

**A milestone is not done until `proof/M<n>/` contains all four of these:**

**1. A scripted UI tour → one PNG per step.** `client/tools/ui_tour.gd` boots the real game against
a seeded staging account, then walks a fixed script: land on Collect, do a collect, open each of
the six tabs, open two modals, buy a shop item, recruit a soldier, run one attack, open the replay.
After each step it waits two frames and saves the viewport:

```gdscript
await get_tree().process_frame
await get_tree().process_frame
var img := get_viewport().get_texture().get_image()
img.save_png("../proof/%s/%02d-%s.png" % [milestone, step, name])
```

Run it against a real window (not `--headless`) so the real renderer, real fonts and real theme are
what get captured:

```bash
godot --path client --resolution 1080x1920 res://tools/UiTour.tscn -- \
      --api=https://staging.api.emperors.dev --milestone=M4 --seed=42
```

The tour fails the milestone if it exits non-zero, if any step produces no PNG, or if any
`push_error` fired during the run.

**2. A contact sheet.** One committed image per milestone:

```bash
magick montage proof/M4/*.png -tile 4x -geometry +8+8 -background '#111' proof/M4/contact.png
```

This is the artefact you actually look at. Two contact sheets side by side make a visual regression
obvious in about a second, which is a thing no video can do.

**3. A device recording.** 20–40 s from the actual iPhone (iOS Screen Recording, or `xcrun devicectl`),
compressed with `ffmpeg -vf scale=-2:854 -crf 30`, showing that milestone's DoD action performed by a
human thumb. **Keep this** — it is the only instrument that catches touch targets that are too small,
text that is illegible at real DPI, content under the notch, and a scroll that fights the tab bar.
The simulator lies about all four.

**4. Database evidence.** `psql` output showing the rows the tour created —
`proof/M4/db.txt` with the attack row, both players' gold before and after, and the ledger entries
summing to zero. This is what proves the *server* did it, not the client's optimistic UI.

Plus: `README.md`'s status table gets its row flipped in the same commit. The godogen convention of
keeping durable status in `README.md` is a good one and we keep it.

**Deliberately not doing:** pixel-diff screenshot regression testing. With generated art and tweened
UI it produces a firehose of false positives and would be switched off inside a week.

---

## 6. Risk register

| # | Risk | L | I | Mitigation | Early warning signal |
|---|---|---|---|---|---|
| **R1** | **Neon pooled-connection incompatibility.** Neon's pooler is PgBouncer in **transaction mode**: no `SET` session state, no `LISTEN/NOTIFY`, no SQL-level `PREPARE/DEALLOCATE`, no session temp tables, and advisory locks do not survive between transactions. Protocol-level prepared statements *are* supported (PgBouncer ≥1.22), which is what pgx v5 uses by default — so it works, until someone writes `SET search_path` or reaches for `LISTEN`. Migrations in particular will fail. | M | H | Two DSNs from day one: pooled for the app, **`DATABASE_URL_DIRECT` for goose**. A CI grep that fails on `LISTEN`/`NOTIFY`/`SET ` outside a transaction in `internal/store`. Redis, not `LISTEN`, for any pub/sub. If prepared-statement errors do appear, set `pgxpool` `DefaultQueryExecMode = QueryExecModeExec` — cheaper than debugging the cache. | `prepared statement "stmtcache_…" already exists` or `unnamed prepared statement does not exist` in logs; `goose up` hanging against the pooled DSN. |
| **R2** | **Neon autosuspend latency.** Default is scale-to-zero after 5 minutes idle; cold start is roughly 300–800 ms, time-to-first-query up to ~1 s. The first player of the morning gets it, and a short pgx connect timeout turns it into an error instead of a pause. | H | M | Raise the autosuspend window on the Neon plan (paid plans can disable it entirely); `infra/keepwarm.cron` runs `SELECT 1` from the VPS every 4 minutes; pgx connect timeout ≥10 s; `MinConns=2` so the pool holds a warm connection. Client shows a spinner, never an error, for the first 3 s. | The `/v1/state` latency histogram going bimodal with a cluster near 700 ms; `context deadline exceeded` clustering right after quiet periods. |
| **R3** | **VPS↔Neon region mismatch.** Neon is in **eu-west-2 (London)**. Every endpoint does several round trips to it. A VPS in the US adds ~80 ms *per query*, so a 4-query `/v1/state` becomes unusable. | M | H | **Provision the VPS in London (DigitalOcean LON1, ~2 ms) or Falkenstein (Hetzner, ~15 ms).** Decide this before creating the droplet — moving it later means a DNS change and a re-cert. Batch reads: `/v1/state` should be one query returning a JSON document, not eight. | `psql -c '\timing' -c 'select 1'` from the VPS showing >5 ms. |
| **R4** | **Godot iOS signing and provisioning friction.** `~/Library/MobileDevice/Provisioning Profiles/` is **empty today**. Godot's iOS export needs a correct 10-character Team ID and an exact bundle identifier, and its own error messages are unhelpful. | H | M | Do all of it on M0 day 1, before there is any game to blame. Use "export project only" and let **Xcode manage signing automatically** on the generated project rather than fighting Godot's provisioning fields. Register the device UDID and create the explicit App ID up front. Set up the App Store Connect API key for fastlane at the same time — the second time you do this dance is much worse. | `No profiles for 'com.karabulut.emperors' were found`; Godot exporting an `.ipa` that installs but immediately closes. |
| **R5** | **App Store rejection.** Three specific exposures: guideline **3.1.1** requires disclosing the odds of randomized items purchasable (directly or indirectly) with money; **5.1.1(v)** requires in-app account deletion, enforced strictly and a common rejection cause; and PvP + accounts + gold-stealing needs a correct age rating, a live privacy policy URL, and accurate nutrition labels. | M | H | Build the odds screen in M2 and the delete-account flow in M1, not in M9. Make deletion reachable in two taps. Never let diamonds buy a randomized roll without the probability table on the same screen. Get the privacy policy live before the first external TestFlight. | The M9 checklist showing any of these items still open two weeks before submission. |
| **R6** | **Art style drift across 150+ assets.** Different sessions, different prompts, different lighting — and the tenth sword does not look like the first. | H | M | One `gemini-3-pro-image` anchor; **every** later asset generated `--image art/style/anchor-item.png`. `art/prompts/` stores the exact prompt per batch so a batch is reproducible. Review as a contact sheet per batch, never file by file. For one bad cell in a good sheet, regenerate *that cell* i2i — never re-roll the sheet. | A new batch's contact sheet needing more than one glance to place next to the previous one. |
| **R7** | **Paid image API cost overrun.** Verified pricing: 3.1 Flash Image ≈ $0.067 at 1K / ~$0.10 at 2K; 3 Pro Image ≈ $0.134 at 1K–2K, $0.24 at 4K. Death is by a thousand single-icon calls. | M | M | Hard rule: **no single-icon generations** — 4×4 sheets only, ~$0.10 for sixteen icons. `art/manifest.csv` has a `cost_cents` column and `make art-cost` sums it. Budget $80 all-in; alert at $75; confirm with the owner before any 4K generation. Batch mode is 50 % cheaper if a big run is ever needed. | `make art-cost` passing 7500. |
| **R8** | **Economy inflation.** Gold is created by collect and tax and destroyed by shop, slots and upgrades. Get the ratio wrong and by day 14 everything is affordable and the game is over. PvP that *mints* the stolen 3 % instead of transferring it inflates forever. | M | H | Every gold delta writes to `gold_ledger` with a reason enum — no exceptions, enforced by making the store's only gold mutator take a reason argument. PvP transfers in one transaction. The M7 dashboard plots created vs destroyed by source, daily; target a sink ratio ≥0.85. Bot rewards in M3.5 are capped per player per day. | Median gold held by day-7 players rising more than 20 % day over day; sink ratio dropping below 0.7. |
| **R9** | **PvP degenerating — whales farming newbies.** A max-power player farming beginners is the fastest way to kill retention in an async PvP game. | H | H | Bracket on power (±25 %) **and** level; 30-minute loser shield; 24-hour shield for new accounts; a cap on incoming attacks per defender per hour; no reward for beating someone more than 30 % below your power; steal capped at `500 × level^1.5` so a rich low-level player is not a jackpot. | Day-2 retention for accounts that lost their first defence being materially below the cohort; the attack log showing repeat attacker→defender pairs. |
| **R10** | **Cheating via a modified client.** GDScript in a `.pck` is trivially extractable. | M | H | The client sends *intents only* — `POST /v1/collect/{job}` carries no amount. The server owns energy, time, RNG and every number. Server time only. Idempotency keys on every mutation. Per-endpoint Redis rate limits. An anti-fraud job flags any player whose gold/hour exceeds `max_energy_regen_per_hour × best_unlocked_job_rate × 1.1`. Accept that a determined attacker can automate *legitimate* play — that is a rate-limit problem, not a crypto problem. | Anti-fraud queue entries; a player's collect count exceeding what their energy could possibly fund. |
| **R11** | **Scope creep from six tabs.** Six tabs is already a large v1. Each one invites "and it should also…". | H | H | §7's cut list is a contract, in `docs/00-vision.md`, and changing it is an explicit decision with a date. A tab ships in its milestone and is then **frozen** except for bugs. Every new idea goes to `docs/80-backlog.md` unread. A milestone running past 150 % of estimate triggers a cut, not an extension. | Any milestone at 150 % of its estimate; a PR touching a tab from a milestone that already closed. |
| **R12** | **GDPR / COPPA.** EU users, user accounts, and a medieval kingdom game that plainly appeals to minors. | M | H | Collect the minimum: a device hash and a nickname. No email, no third-party ad SDK in v1 (ad SDKs are the main COPPA landmine, and dropping them costs nothing because there are no ads in v1). Age gate at first launch. Privacy policy live before external TestFlight. Data export and delete endpoints (delete already exists for 5.1.1(v)). Keep data in the EU — Neon London is already right; put the VPS in the EU too. **Do not enter the Kids Category** — the compliance burden is disproportionate. | A partner or SDK asking for an advertising identifier; any feature proposing to collect an email or a birthdate. |
| **R13** | **Single VPS, no backups, Redis mistaken for a database.** | M | H | Neon's PITR covers the only durable state. The VPS holds nothing that matters — that is a **design constraint to write down**, not an accident. `infra/deploy.sh` and `cloud-init.yaml` make a rebuild a ten-minute operation. Weekly `docker run --rm postgres:18 pg_dump` to object storage as a second line. | Any PR putting authoritative state in Redis; a `docker volume` appearing in `compose.yaml` for anything but Redis's cache dump. |
| **R14** | **Missing export templates and Android toolchain.** Only `ios.zip` exists for 4.7.2.stable; no JDK 17, no Android SDK. Steam additionally needs desktop templates. | H | L | Known and deferred. iOS needs nothing more. Budget a full day of pure setup before M9b and again before M9c. Do not let "we should also do Android" leak into M1–M8. | Anyone starting M9b before iOS reaches external TestFlight. |
| **R15** | **`pg_dump` 17 against Postgres 18.** Local `pg_dump` will refuse a newer major server, which will be discovered at exactly the wrong moment. | H | M | Documented in `docs/50-runbook.md`: dumps go through `docker run --rm postgres:18 pg_dump`. Never `brew`-upgrade libpq to fix it mid-incident. | `pg_dump: error: server version 18.6; pg_dump version 17.5`. |
| **R16** | **Clock-derived economy.** Energy, tax, shields and shop windows are all wall-clock functions. A container clock skew or a stray `time.Now()` hands out free resources at scale. | L | H | All accrual math reads Postgres `now()` in the same statement as the row. `timestamptz` everywhere, never `timestamp`. A CI grep forbidding `time.Now()` inside `internal/economy` and `internal/collect`. | An energy or tax value that a hand calculation cannot reproduce. |
| **R17** | **`godogen publish.sh` run against the repo.** `--force` does `rm -rf` on its target. | L | **Catastrophic** | The `AGENTS.md` danger block; `scripts/vendor-asset-gen.sh` as the only sanctioned path; `chmod -w` on the upstream `publish.sh`; `GODOGEN_SRC` never exported by default. And the repo is pushed to GitHub, so the worst case is losing uncommitted work. | Not applicable — the mitigation is prevention. Push often. |
| **R18** | **The epic/mystic colour collision.** The brief specifies purple for both, so two tiers three ranks apart are visually identical. Players will misread item value, and it will read as a bug. | H | M | Resolve before M2 ships (see open question 1). Proposal: epic stays purple `#8B5CF6`, mystic becomes magenta `#E0409A`, and — because gray/green/blue/purple/yellow/magenta/red is not safe under deuteranopia — every tier badge also carries a **redundant pip count (1–7)**, so colour is never the only channel. | A playtester asking which of two items is better. |

---

## 7. What we are NOT building in v1

This list is a contract. Each line is a real thing a reasonable person will propose; each is
deferred on purpose, and the reason is written down so the argument only has to be had once.

**Monetisation**
* **In-app purchases / StoreKit.** Build the *diamond balance* and its sinks (energy refill,
  protection, shop reroll) so the economy is shaped correctly, but grant diamonds only from level-ups
  and milestones. No StoreKit plugin, no receipt verification path in v1. `internal/iap` exists as
  dormant code. **Rationale:** every Godot iOS IAP plugin is third-party with varying StoreKit 2
  support, it is the single most fragile integration available, and it forces the full 3.1.1 /
  refund / restore surface into a release that has not yet proven anyone wants to play.
* **Ads and rewarded video.** The SDK is heavy and it is the primary COPPA exposure (R12).
* **Battle pass, seasons, starter packs, daily login calendars.**

**Systems**
* **Item upgrading, enchanting, crafting, reforging, salvage-to-materials.** Items are bought,
  equipped and sold for gold. That is the whole item verb list in v1.
* **Item sets and set bonuses.**
* **Player-to-player trading or an auction house.** Fraud surface, economy risk, and a moderation
  burden, for a feature nobody has asked for yet.
* **Kingdom vs kingdom wars, kingdom raids, kingdom chat.** Kingdoms in v1 are: found, invite,
  shared upgrades, reputation, leaderboard, and a no-attack rule. Nothing more.
* **Achievements and quest chains.**
* **Friends lists, blocking, player search by name.**
* **Revenge chains** beyond a single revenge button.
* **Spectate and replay sharing.**

**Technical**
* **WebSockets and any real-time anything.** HTTP polling. Async PvP does not need a socket, and a
  socket needs reconnection logic, backpressure, and a completely different scaling story.
* **Push notifications** ("your energy is full"). Real retention value, real APNs plumbing. v1.1.
* **Sign in with Apple and cross-device account linking.** v1 is device auth plus a recovery code
  the player can write down. Adding Sign in with Apple later also drags in the token-revocation
  requirement on account deletion.
* **Localisation.** English only — but every user-facing string goes through
  `client/scripts/ui/strings.gd` from day one, so adding a language later is a day, not a month.
* **Web export, Android, Steam** in 1.0. M9b and M9c are post-launch.
* **Device attestation / advanced anti-cheat.** Server authority plus rate limits plus anomaly
  detection. Nothing client-side.
* **Multiple server regions, read replicas, sharding.** One VPS, one Neon project. Revisit above
  10k DAU.

**Content and art**
* **Animated sprites.** Not a choice — the video generation path requires an xAI key we do not have.
  Static art with tween-driven juice.
* **Any 3D.** No Tripo3D key, and the game has no 3D surface.
* **Cosmetics, skins, custom avatars.** A fixed portrait set per soldier tier.
* **More than one weapon class.** Swords only, as specified — but many distinct sword designs.

---

## Appendix A — the `Makefile` targets that should exist

```
make preflight      # verify every tool, key and connection before you start
make dev            # air (server) + redis + `godot --path client -- --api=localhost`
make migrate        # goose up, against DATABASE_URL_DIRECT
make migrate-new    # goose create <name> sql
make gen            # contract/gen.sh -> oapi-codegen; balance schema validation
make test           # go test -race ./... && godot headless TestRunner
make test-int       # store tests against a local postgres:18
make e2e            # server/e2e against $EMPERORS_API_URL
make lint           # go vet, staticcheck, govulncheck, tsc, eslint
make build-ios      # godot export (project only) + xcodebuild
make testflight     # fastlane
make deploy         # build+push image, ssh, goose up, compose up -d, smoke test
make art-gen        # art/scripts/gen_batch.sh
make art-promote    # slice + matte + promote + manifest append
make art-cost       # sum art/manifest.csv cost_cents
make proof M=M4     # run the UI tour, build the contact sheet
make loadtest       # emperorsctl loadgen + vegeta
```

## Appendix B — M0's first migration, concretely

```sql
-- server/migrations/00001_init.sql
-- +goose Up
create extension if not exists pgcrypto;

create table players (
    id              uuid primary key default gen_random_uuid(),
    device_hash     text        not null unique,
    nickname        text        not null,
    created_at      timestamptz not null default now(),
    last_seen_at    timestamptz not null default now(),
    deleted_at      timestamptz,

    gold            bigint      not null default 0 check (gold >= 0),
    diamonds        bigint      not null default 0 check (diamonds >= 0),
    level           int         not null default 1 check (level >= 1),
    xp              bigint      not null default 0 check (xp >= 0),

    energy          int         not null default 20 check (energy >= 0),
    energy_ts       timestamptz not null default now(),
    tax_ts          timestamptz not null default now(),
    shield_until    timestamptz,
    state_version   bigint      not null default 1
);

create index players_power_idx on players (level) where deleted_at is null;
create index players_last_seen_idx on players (last_seen_at desc);

-- Every gold movement, with a reason. This table is what makes the M7 economy
-- dashboard and the R8 inflation check possible; nothing may mutate
-- players.gold without appending here.
create table gold_ledger (
    id          bigserial   primary key,
    player_id   uuid        not null references players(id) on delete cascade,
    delta       bigint      not null,
    reason      text        not null,   -- collect|tax|shop_buy|sell|attack_win|
                                        -- attack_loss|slot|upgrade|admin_grant
    ref         text,                   -- job id, item id, attack id, …
    created_at  timestamptz not null default now()
);
create index gold_ledger_player_time_idx on gold_ledger (player_id, created_at desc);

-- +goose Down
drop table gold_ledger;
drop table players;
```

Run it with the **direct** DSN — `goose -dir server/migrations postgres "$DATABASE_URL_DIRECT" up`.
Against the pooled endpoint it will hang or fail, and that failure is R1 announcing itself on day one.

---

## Sources

- [Neon connection pooling (PgBouncer transaction mode, prepared statements)](https://neon.com/docs/connect/connection-pooling)
- [PgBouncer: the one with prepared statements — Neon](https://neon.com/blog/pgbouncer-the-one-with-prepared-statements)
- [Neon connection latency and timeouts / autosuspend](https://neon.com/docs/connect/connection-latency)
- [Godot 4.7 "Lights, Camera, Action!" release](https://godotengine.org/releases/4.7/)
- [Godot — Exporting for iOS](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_ios.html)
- [Go 1.27 release notes](https://go.dev/doc/go1.27)
- [Next.js 16.3](https://nextjs.org/blog/next-16-3)
- [Apple App Review Guidelines (3.1.1 loot box odds, 5.1.1(v) account deletion)](https://developer.apple.com/app-store/review/guidelines/)
- [Apple — account deletion requirement](https://developer.apple.com/news/?id=12m75xbj)
- [Gemini image generation pricing (3 Pro Image / 3.1 Flash Image)](https://www.aifreeapi.com/en/posts/gemini-image-generation-api-pricing)
- [ONNX Runtime releases (official macOS arm64 wheels built with CoreML EP)](https://github.com/microsoft/onnxruntime/releases)


---

## Key decisions

- **Single monorepo `github.com/yigitkarabulut0/emperors` containing client/, server/, admin/, art/, balance/, contract/, infra/, docs/, proof/**
  - Rejected: Polyrepo (four repos) or Git submodules for art
  - Why: The client/server contract changes on nearly every commit for the first three months, and balance/*.json is consumed by all three of Go, GDScript and TypeScript. Polyrepo turns each such change into two PRs plus a version bump plus a broken-main window. The only real argument for polyrepo — repo size from committed art — is solved by art discipline plus a 750 MB CI size gate, at which point Git LFS for art/raw/** is a one-day migration.
- **Fork godogen's asset-gen skill into .claude/skills/asset-gen/ via scripts/vendor-asset-gen.sh; never run publish.sh against the repo**
  - Rejected: Running `publish.sh --engine godot --agent claude --out .` to install and later re-sync the skill
  - Why: publish.sh --force does `rm -rf` on its target (the whole repo), and even without --force it does `rsync --delete` on .claude/skills/, wiping sibling skills. It also writes a .gitignore excluding `assets`, `*.import` and `.claude` — which would silently drop every paid PNG and every Godot resource-identity file from version control. Forking also lets us commit the four patches the skill needs to work at all here.
- **Four committed patches to the vendored skill: lazy xai_sdk import, --model default gemini + --gemini-model flag, requirements.txt without onnxruntime-gpu/nvidia-cudnn, and the rembg_matting.py:312 bg_color NameError fix**
  - Rejected: Using the skill as shipped and working around its failures per invocation
  - Why: `import xai_sdk` is at module scope in asset_gen.py, so today the tool cannot run at all without the xAI SDK — even with --model gemini. requirements.txt pins onnxruntime-gpu and nvidia-cudnn-cu12, neither of which has an Apple Silicon wheel. These are not workarounds-per-call; they are blockers on the first call.
- **Art generation workspace `art/` lives as a sibling of `client/`, never inside it; only promoted, sized assets land in `client/assets/`**
  - Rejected: Generating into client/assets/raw/ with a .gdignore
  - Why: Godot's importer walks the project directory and would import 2K/4K generation sheets as unused .ctex, bloating every export. Keeping art/ outside client/ means Godot never sees it and no .gdignore is needed anywhere — and godot.md warns that a stray .gdignore silently skips a directory.
- **Two Neon DSNs: DATABASE_URL (pooled) for the application, DATABASE_URL_DIRECT (unpooled) for goose migrations**
  - Rejected: One pooled DSN for everything, or GameTest's embed-schema-and-apply-at-boot approach
  - Why: Neon's pooler is PgBouncer in transaction mode: no SET session state, no LISTEN/NOTIFY, no SQL-level PREPARE, no session temp tables. Migrations will hang or fail against it. Separating the DSNs on day one also makes R1 announce itself during M0 rather than during a production deploy.
- **Balance data lives in a versioned `balance_versions` JSONB table seeded from balance/*.json, hot-reloaded every 60s; the admin panel edits versions with one-click rollback**
  - Rejected: Embedding balance JSON in the Go binary (a redeploy per tuning change) or shipping it in the client
  - Why: Tuning an idle economy requires dozens of small changes, and each one gated on a deploy — or worse, an App Store release — means the game never gets balanced. DB-backed versions also give an audit trail and instant rollback when a change is wrong.
- **PvP gold is a transfer inside one transaction, never a mint; every gold delta writes to a gold_ledger row with a reason enum**
  - Rejected: Crediting the attacker and debiting the defender as independent operations, or crediting without an explicit ledger
  - Why: Minting the stolen 3% inflates the economy by 3% of the loser's bank on every fight, forever. The ledger is the only mechanism that makes the M7 economy dashboard and the R8 inflation early-warning possible, and retrofitting it after 50k rows of untracked gold movement is impossible.
- **matchmaking.OpponentSource is an interface from the start: BotSource in M3.5, PlayerSource in M4**
  - Rejected: Building PvP directly against real players in M4
  - Why: It moves the three hardest pieces of PvP — the deterministic simulator, the replay encoding, and the client replay animation — four weeks earlier and lets them be debugged against opponents that cannot be harmed by a bug. It is also what makes a genuinely fun vertical slice land at week four instead of week seven.
- **Energy, tax and shields are lazily materialised on read from Postgres now(); no background ticker, and time.Now() is banned inside internal/economy and internal/collect**
  - Rejected: A cron or goroutine incrementing energy rows per minute
  - Why: A ticker is one write per player per minute for zero benefit and becomes the dominant DB load at scale. Reading now() inside the same statement as the row also removes the entire class of clock-skew exploits — a container clock jump would otherwise mint free energy for everyone.
- **Shop contents are deterministic per (EMPERORS_SHOP_SALT, player_id, window_id=floor(unix/300)), and purchases are idempotent on (player_id, window_id, slot)**
  - Rejected: Rolling the shop on each GET and persisting the result
  - Why: Determinism makes the shop reconnect-safe and reroll-proof with no stored state, and it makes the endpoint cacheable. A stored roll invites a reroll exploit through a forced refresh and needs a cleanup job.
- **The proof ritual is a scripted UI tour producing one PNG per step, a montage contact sheet, one compressed device recording, and psql evidence — committed under proof/M<n>/**
  - Rejected: godogen's mandated 15-20s gameplay video as the sole proof artefact
  - Why: A UI game's regressions are layout, state and numbers. A video cannot be diffed and gives one arbitrary frame per screen; two contact sheets side by side surface a regression in about a second. The device recording is kept anyway because only a real phone catches touch targets, notch overlap and real-DPI legibility.
- **Godot display: 1080x1920, stretch mode canvas_items, aspect `expand`, portrait, with DisplayServer.get_display_safe_area() padding**
  - Rejected: GameTest's 720x1280 with aspect `keep_width`
  - Why: Emperors is anchored-Control UI with a fixed top resource bar and bottom tab bar, not a fixed-aspect play field. `keep_width` crops or letterboxes the anchored edges across iPhone aspect ratios; `expand` lets the anchors hold. 1080 wide also means item art at 128px display is a 1:1 pixel match on the target device.
- **Deterministic seeded battle simulation returning a replay array the client animates, with golden replay files in server/testdata/**
  - Rejected: Simulating combat on the client from both rosters, or streaming the fight over a socket
  - Why: Client-side simulation is a cheat vector and desyncs the moment the formula changes. The golden files make the replay format a frozen contract, which is what lets the client animation be trusted; and a replay array is small enough to store on the attack row for the defender to watch later.
- **No IAP/StoreKit in v1 — diamonds exist as a balance and have sinks, but are granted only from progression**
  - Rejected: Shipping diamond purchases with the first release
  - Why: Every Godot iOS IAP plugin is third-party with varying StoreKit 2 support; it is the most fragile integration available and it drags in the full 3.1.1 odds / refund / restore surface. Shaping the economy around diamonds now costs nothing and keeps the option open, but paying for the integration before anyone has proven they want to play is the wrong order.

## Risks flagged

- Neon pooled connections are PgBouncer transaction mode: no SET, no LISTEN/NOTIFY, no SQL-level PREPARE, no session temp tables — migrations in particular must use a separate unpooled DSN or they hang
- Neon autosuspend (5 min default) gives a 300-800ms cold start that a short pgx connect timeout turns into an error; the first player of the morning eats it
- VPS/Neon region mismatch: Neon is in London (eu-west-2), so a non-EU VPS adds ~80ms per query and a multi-query /v1/state becomes unusable — pick DigitalOcean LON1 or Hetzner FSN before creating the droplet
- Godot iOS signing and provisioning: the dev machine currently has ZERO provisioning profiles, and Godot's iOS export errors are unhelpful — budget half a day on M0 day 1, not at M9
- App Store rejection on three fronts: 3.1.1 randomized-item odds disclosure, 5.1.1(v) in-app account deletion reachable in two taps, and correct age rating + privacy policy for a gold-stealing PvP game with accounts
- Art style drift across 150+ generated assets unless one gemini-3-pro-image anchor is locked and every later asset is generated image-to-image from it
- Paid image API cost overrun via single-icon generations; the discipline is 4x4 sheets only (~$0.10 for sixteen icons) with a cost column in art/manifest.csv and an $80 budget
- Economy inflation if gold sinks lag sources or if PvP mints instead of transfers the stolen 3% — mitigated by a mandatory gold_ledger and a daily created-vs-destroyed dashboard
- PvP degenerating into whales farming newbies, which is the fastest way to kill retention in async PvP — needs power+level brackets, loser shields, newbie shields, incoming-attack caps and a steal cap tied to defender level
- Cheating via a modified client: GDScript in a .pck is trivially extractable, so the client must send intents only and the server must own energy, time and every RNG roll
- Scope creep across six tabs; the cut list must be treated as a contract with tabs frozen after their milestone closes
- GDPR/COPPA exposure from user accounts in a game that appeals to minors — minimum data collection, no ad SDK in v1, EU-only data residency, and explicitly not entering the Kids Category
- Single VPS with no durable state is fine only if Redis is treated strictly as a cache; any authoritative state landing in Redis turns a restart into data loss
- Missing Godot export templates (only ios.zip present) and a completely absent Android toolchain (no JDK 17, no SDK) — a full day of setup each before M9b and M9c
- Local psql/pg_dump is 17.5 against a Postgres 18.6 server: pg_dump will refuse to run, and this will be discovered during an incident unless the runbook prescribes `docker run --rm postgres:18 pg_dump`
- Clock-derived economy (energy, tax, shields, shop windows) breaks catastrophically on server clock skew unless all accrual reads Postgres now() in the same statement as the row
- godogen's publish.sh does `rm -rf` on its target with --force — pointing it at the Emperors repo destroys it; prevention is the only mitigation
- The brief specifies purple for BOTH epic and mystic, making two tiers three ranks apart visually identical; unresolved, players will read it as a bug

## Questions raised for the owner

- Tier colours: epic and mystic are both specified as purple. Proposal — epic stays purple #8B5CF6 and mystic becomes magenta #E0409A, plus a redundant 1-7 pip count on every tier badge because gray/green/blue/purple/yellow/magenta/red is not distinguishable under deuteranopia. Do you accept magenta for mystic, or would you rather move epic (e.g. to teal) and keep mystic purple? This must be settled before M2 ships.
- Collect milestone bonuses: does 25/50/100 collects give +5%/+10%/+15% as REPLACING tiers (max +15%), or CUMULATIVE (+5, then +15, then +30 total)? The plan assumes replace. This changes late-game collect income by a factor of two and is baked into balance/jobs.json.
- Diamonds in v1: the plan grants diamonds only from progression and defers StoreKit entirely to v1.1. Is shipping v1 with no purchasable currency acceptable, or does the first TestFlight need to be monetisable? Adding IAP moves M9a from 6 days to about 12 and pulls the full 3.1.1 odds/refund/restore surface forward.
- Account model: v1 is device auth plus a written-down recovery code, with Sign in with Apple deferred. That means a lost phone can mean a lost account. Acceptable for launch, or is cross-device account recovery a v1 requirement?
- VPS provider and region: Neon is in eu-west-2 London, so DigitalOcean LON1 (~2ms) or Hetzner Falkenstein (~15ms) are the only sensible choices. Which, and do you already have an account? This must be decided before M0 day 2 because moving it later means a DNS change and a re-cert.
- Domain name for the API and the privacy policy. What is it, and is it already registered? The M0 definition of done requires a real TLS cert on a real domain — iOS App Transport Security will not accept a self-signed cert or plain HTTP, and there is no shortcut worth taking.
- GitHub owner and Go module path: the authenticated gh account is yigitkarabulut0, but the precedent project GameTest uses module github.com/karabulut/stardrift/server. The plan assumes github.com/yigitkarabulut0/emperors. Which do you want, and should the repo be private?
- Bot rewards in the M3.5 vertical slice: bots mint gold rather than transferring it, capped per player per day. What daily cap is acceptable, and should M3.5 bot progress carry over into the live economy at M4 or be wiped? Wiping is safer for the economy and worse for the first testers.
- Art budget ceiling: the plan estimates $40-80 all-in for roughly 150 assets using 4x4 sheets, with one gemini-3-pro-image anchor at $0.13. What is the hard cap at which generation stops and asks?
- Target launch window. The plan totals ~59 focused engineering days (~12 calendar weeks solo) to iOS TestFlight. If there is a fixed date, the cut list in section 7 is where the next reductions come from — tell me which of kingdoms (M6, 6 days) or the art pass (M8, 9 days) is more compressible.

---

# Adversarial review — verdict: needs-revision


## BLOCKER (4)

### M4 matchmaking is built on a `players.power` column that no migration creates and nothing maintains. Appendix B's index is named `players_power_idx` but is declared `on players (level)`.

**Breaks because:** M4 specifies `power between 0.75*p and 1.25*p`, `WHERE power >= x ORDER BY power LIMIT 5`, and a btree index on `power`. But §3 defines power as a derived function of the player's equipped items plus every soldier's items — `total_power = floor((player_unit + Σ soldier_units) * (1 + family_soldier_bonus))`. Appendix B's `players` table has no `power` column, and the only index the doc writes is misnamed and indexes `level`. Computing power per candidate at query time means joining `soldiers` and `items` for every row in the band, which is exactly the full scan the doc congratulates itself on avoiding by not writing `ORDER BY random()`.

**Fix:** Add `power bigint not null default 0` to `players` in 00001_init.sql. Make it a denormalised cache recomputed and written inside the same transaction as every mutation that can change it: `POST /v1/soldiers/recruit`, `POST /v1/soldiers/slot`, `POST /v1/soldiers/{id}/equip`, `POST /v1/player/equip`, `POST /v1/inventory/sell`, `POST /v1/stats/allocate`, and level-up inside `POST /v1/collect`. Route all of them through one `store.RecomputePower(ctx, tx, playerID)`. Index it `create index players_power_idx on players (power) where deleted_at is null;`. Add `emperorsctl backfill power` and a `go test` in `internal/soldiers` that asserts stored power equals freshly-computed power for a seeded roster. Do this in M3 (where power is introduced), not M4.

### Idempotency records live only in Redis, but the doc simultaneously asserts Redis 'must never lose gold'. Losing Redis double-pays gold.

**Breaks because:** §3 says `POST /v1/collect` retries must not double-pay, and that the `(player_id, key) → response` map lives in Redis for 24 h. §3 also says 'Redis is a cache, never truth. Losing Redis loses rate-limit counters and idempotency records for 24 h. It must never lose gold.' Both cannot be true: the idempotency record *is* the thing preventing double-pay. Worse, `infra/compose.yaml` puts Redis on the same VPS and `deploy.sh` runs `compose up -d` on every deploy, so every deploy is a window in which an in-flight mobile retry double-credits. R13 even forbids a docker volume 'for anything but Redis's cache dump', which is not durability. The doc is inconsistent with itself: M2 already puts the shop's idempotency ledger in Postgres (`shop_purchases` keyed on `player_id, window_id, slot`).

**Fix:** Move the idempotency record into Postgres, written in the same transaction as the gold mutation. Migration: `create table request_idem (player_id uuid not null references players(id) on delete cascade, key text not null, endpoint text not null, response jsonb not null, created_at timestamptz not null default now(), primary key (player_id, key));` plus `create index request_idem_gc_idx on request_idem (created_at);`. Handler shape: begin tx → `insert ... on conflict (player_id, key) do nothing returning 1` → if no row returned, `select response` and return it verbatim → otherwise do the work, write the ledger row, `update request_idem set response = $1`, commit. Keep Redis strictly as an optional read-through fast path in front of it. Add a daily `delete from request_idem where created_at < now() - interval '48 hours'` to emperorsctl.

### The Docker image architecture is never specified. Building on the Apple Silicon dev machine under colima produces linux/arm64; DigitalOcean LON1 — R3's first recommendation — is x86-64 only.

**Breaks because:** `infra/deploy.sh` is described as 'build+push image, ssh, goose up, compose up -d'. `colima` on Apple Silicon runs an aarch64 Linux VM, so `docker build` with no `--platform` emits a linux/arm64 manifest. Pushing that and running it on an x86 droplet fails at container start with `exec /app/emperors: exec format error`. This lands on M0 day 1, in the milestone whose entire point is proving the pipe end to end, and the failure mode looks like a broken binary rather than a build-config problem. Hetzner ARM (CAX) exists in Falkenstein/Helsinki/Nuremberg but not in a London region, so the arch choice is coupled to R3's region choice and neither is stated.

**Fix:** Decide arch explicitly in `docs/10-architecture.md` and pin it in three places. (a) Dockerfile builder stage: `ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64` (pgx is pure Go, so CGO_ENABLED=0 is required anyway for a distroless/static base). (b) deploy.sh: `docker buildx build --platform linux/amd64 --push -t ...` (buildx cross-compile is trivial here because the Go build itself is cross-compiled, not emulated). (c) `infra/compose.yaml`: `platform: linux/amd64` on the server service. Better still, move image build to a GitHub Actions job (linux/amd64 runners, free, and it removes the Mac from the deploy path entirely) and have deploy.sh only pull-and-restart. If Hetzner CAX/ARM is chosen instead, flip all three to arm64 and note in R3 that London ARM is unavailable.

### `infra/keepwarm.cron` (SELECT 1 every 4 minutes) exceeds the Neon Free plan's monthly compute quota by ~1.8x, and R2's claim that 'paid plans can disable it entirely' does not apply to the plan the project is presumably on.

**Breaks because:** Neon Free is 100 CU-hours per project per month and scale-to-zero after 5 min of inactivity 'cannot be disabled'. A SELECT every 4 minutes keeps a 0.25 CU compute awake ~730 h/month = ~182 CU-hours — 1.8x the quota — before a single player connects, and before the per-PR Neon branches §5.1 mandates add their own compute. Neon's documented behaviour on quota exhaustion: 'The project's compute is suspended until the next billing period or until you upgrade. Existing connections drop and new ones can't open.' The game goes dark mid-month with no warning in the risk register. Separately, `MinConns=2` does not keep the compute warm — Neon suspends on query inactivity and terminates open pooled connections — so that half of the R2 mitigation is inert.

**Fix:** Pick one and write it in docs/50-runbook.md as a cost line. (a) Budget the Neon Launch plan (~$0.106/CU-hour; an always-on 0.25 CU is ~182 CU-hours ≈ $19/mo of metered compute) and disable scale-to-zero there — then delete keepwarm.cron as redundant. (b) Stay on Free, delete keepwarm.cron, and lean entirely on the cold-start handling R2 already prescribes: pgx `ConnectTimeout >= 10s`, `MinConns = 0`, a client spinner for the first 3 s, and one automatic retry on a broken connection (`pgconn.SafeToRetry`). Do not do both. Also add a `NEON_API_KEY` line to §2.1 and a cap on per-PR branches (Free allows 10 per project), or CI branch creation will fail silently around PR #11.


## MAJOR (10)

### M1's definition of done ('ten minutes of tapping takes a fresh account from level 1 to about level 5') is arithmetically impossible against the doc's own XP curve and §4's own pacing.

**Breaks because:** `xp_to_next(L) = floor(50 * L^1.8)` gives 50, 174, 361, 606 for L1→L5, i.e. 1191 cumulative XP. §4's closing beat requires the player to be out of energy at minute 10 with 'the timer says four minutes' — that pins max_energy ≈ 20 and regen ≈ 12 s/energy, so a ten-minute session affords 20 + 600/12 = 70 energy. §4 also states 11 Grapes taps (11 energy) produces level 2, i.e. ~4.5 XP per energy. 70 energy × 4.5 = 315 XP = level 3, not level 5. To hit 1191 XP on 70 energy the ladder would need ~17 XP/energy, which contradicts §4's own walkthrough. Compounding this: `regen_seconds`, starting `max_energy`, and XP-per-energy appear in no formula and no balance file — `balance/` has jobs.json and levels.json but nothing that owns the energy constants the energy formula reads.

**Fix:** Add `balance/energy.json` with `{ "max_energy_base": 20, "regen_seconds": 12, "offline_cap_seconds": 28800 }` and stop hiding these in prose. Flatten the early curve to `xp_to_next(L) = floor(20 * L^1.4)` → 20, 52, 93, 139 (cum 304 to L5), reached at ~61 energy ≈ minute 8 at 5 XP/energy — which matches §4's beat and leaves headroom. Pin XP per energy at 5 across the early ladder in jobs.json (Grapes 1 energy → 2 gold / 5 xp; Strawberries 2 → 4 / 10). Then restate M1's DoD as a *measured* assertion produced by a unit test in `internal/economy` (`TestTenMinuteSession`) that replays 600 s of regen at the balance constants and asserts the resulting level, so the DoD and the numbers can never drift apart again.

### The vertical slice inverts the brief's stated economy: attack gold dominates collect gold by ~17x per energy, which kills the Collect tab — the tab the brief calls the primary gold source.

**Breaks because:** The brief: 'active collect actions are the PRIMARY gold source'. §4 minute 6:30–9:00: 'Steal 340 gold — more than twenty collects earned.' Both actions draw the same energy pool. The low collect ladder is 2 gold/energy (Grapes 1→2, Strawberries 2→4). If an attack costs ~10 energy, 340 gold is 34 gold/energy — 17x collect. A full 20-energy bar of collecting earns 40 gold; one attack earns 8.5 bars' worth. §4 also has the player buying a Rare sword for roughly 110 gold at minute 5, so a single attack at minute 7 buys three of them and the shop's price curve is meaningless by minute 8. And M3.5 says bot attacks *mint* gold ('bots mint, and that is fine and bounded because bot gold is capped per day') with the cap never specified anywhere — so the largest faucet in the game for the entire vertical-slice period is also the only unnumbered one, directly undermining R8.

**Fix:** Three changes, all in balance/combat.json. (1) Cap attack gold against the collect rate: `attack_gold = min(floor(0.03 * opponent_bank), attack_energy_cost * best_unlocked_job_gold_per_energy * 2.0)` — a 2x per-energy premium for the risk of losing, not 17x. (2) Make the bot's bank self-scaling rather than a flat jackpot: `bot_bank = player_gold_earned_last_24h * uniform(0.15, 0.45)`, so the reward tracks the player's own income curve at every level instead of being tuned once for minute 7. (3) Add `bot_gold_daily_cap = 0.25 * (86400 / regen_seconds) * best_unlocked_job_gold_per_energy` — bots can mint at most a quarter of a day's theoretical collect income — and enforce it via a `gold_ledger` sum with `reason = 'attack_win_bot'` over the trailing 24 h. Then move the *excitement* of §4's minute 6:30 off gold and onto items: a won attack rolls a loot item at the opponent's tier band with ~20% probability. Items are what the player actually wants (they raise power); gold stays a sink-feeder. Rewrite §4's minute 6:30 line accordingly.

### A staging environment is required by three separate sections and provisioned by none.

**Breaks because:** §5.1: e2e runs 'before each deploy, against staging'. §5.3's proof command is literally `--api=https://staging.api.emperors.dev`. §5.1 also mandates 'a Neon branch created per PR via the Neon API'. But `infra/` contains exactly one Dockerfile, one compose.yaml, one Caddyfile, one deploy.sh and one cloud-init.yaml; §2.1's secret inventory has `EMPERORS_ENV=dev|staging|prod` but no `NEON_API_KEY` and no staging DSN; and the risk register never mentions the second environment's cost. The proof ritual — which is the doc's gating mechanism for every milestone — therefore cannot be executed as written from M0 onward.

**Fix:** Pick one and make it real. (a) Second stack on the same VPS: add a `server-staging` service to compose.yaml on port 8081 with `EMPERORS_ENV=staging` and its own `DATABASE_URL` pointing at a long-lived Neon branch named `staging`; add `api-staging.<domain>` to the Caddyfile; add `DATABASE_URL_STAGING` and `NEON_API_KEY` to §2.1, .env.example and GitHub secrets; note in the cost line that the staging branch roughly doubles Neon compute burn. (b) Or delete staging entirely: run the pre-deploy e2e and the UI tour against `make dev` on the local `postgres:18` + local server, and change §5.3's command to `--api=http://127.0.0.1:8080`. Given the Neon quota finding above, (b) is the cheaper answer for v1.

### There is no client version gate or forced-update path anywhere in 11 milestones or 18 risks, in a fully server-authoritative game shipped through App Store review.

**Breaks because:** The client is a thin renderer that mirrors `/v1/state`. App Review latency plus users who never update means old binaries will be live against a server whose DTO shape has moved. The doc's own contract guard exists precisely because 'a server-side field rename now breaks a client test in CI instead of breaking a player's phone' — but nothing stops a *shipped* phone from breaking. This is aggravated by ADR-0004: the whole hot-reload-balance story trains the team to ship server changes without a client release, which is safe for values and unsafe for shapes, and the doc never draws that line. Retrofitting a version gate is impossible for the cohort that is already on the old build.

**Fix:** Add to M0, where it is ~20 lines. Client: `api.gd` sends `X-Client-Version: <ProjectSettings application/config/version>` on every request. Server: `/v1/state` and every error response include `{"min_client": "1.0.0", "recommended_client": "1.1.0"}` read from the active balance version; a middleware returns HTTP 426 with an error code `CLIENT_TOO_OLD` when the header parses below `min_client`. Client: `ui.gd` renders a blocking, non-dismissable 'Update required' modal with an App Store deep link on 426, and a dismissable 'Update available' toast when below `recommended`. Write the contract rule into `contract/errors.md`: additive-only changes to response schemas within a major; any field removal or type change requires bumping `min_client` and waiting out review.

### Soft-deleting an account while `device_hash` carries a plain UNIQUE constraint permanently bans that device from re-registering, and fails GDPR erasure.

**Breaks because:** Appendix B declares `device_hash text not null unique` and `deleted_at timestamptz`. M1 ships `DELETE /v1/account` for App Store 5.1.1(v). If deletion sets `deleted_at`, the row keeps its unique `device_hash`, so `POST /v1/auth/device` from the same install hits the unique violation forever. The GameTest precedent (which this plan says it extends) persists the device id in `user://device.id`, so it survives the delete and the user is locked out of their own game. R12 also claims data-delete endpoints satisfy GDPR, but retaining a device identifier after an erasure request does not.

**Fix:** Replace the inline constraint with a partial unique index: drop `unique` from the column and add `create unique index players_device_hash_uq on players (device_hash) where deleted_at is null;`. On delete, in one transaction: `update players set device_hash = 'deleted:' || id::text, nickname = '', deleted_at = now() where id = $1;` and cascade-delete or anonymise `refresh_tokens`, `job_progress` and any nickname on `attacks`. Keep `gold_ledger` rows (they are aggregate economy data, but null the `ref` if it can identify). Add a Godot-side test case: delete account → app clears `user://device.id` → next launch registers a fresh player. That last step is the one that actually gets missed.

### Account recovery is promised in §7 as the v1 substitute for Sign in with Apple, but exists in no milestone, no endpoint, no schema column and no client screen.

**Breaks because:** §7: 'v1 is device auth plus a recovery code the player can write down.' Search the rest of the doc: `players` has no recovery column, M1's endpoint list has no recovery endpoint, no client scene or modal covers it, and it is absent from all 18 risks. Meanwhile identity is a locally-generated id in `user://device.id` (the GameTest pattern the doc adopts), which is destroyed by an app delete/reinstall and does not travel to a new phone. For a game whose entire value proposition is accumulated progress across weeks, 'reinstall the app and lose everything, with no support path' is a top-three retention risk and it is not in the register.

**Fix:** Add to M1 (half a day, and impossible to retrofit for anyone who has already lost their device). Migration: `alter table players add column recovery_code_hash text, add column recovery_issued_at timestamptz;`. Endpoints: `POST /v1/auth/recovery/issue` returns a one-time human-transcribable code (8 groups of 4 from a Crockford base32 alphabet, stored only as an argon2id/bcrypt hash) and is rate-limited to once per 24 h; `POST /v1/auth/recovery/redeem` takes `{code, new_device_hash}`, rebinds the row, rotates all refresh tokens, and invalidates the code. Client: a 'Save your recovery code' card on the Family tab shown once at level 3 and permanently reachable from the same screen as delete-account. Add a risk row: 'device-bound identity means reinstall = total loss; recovery code is the only mitigation and it is worthless unless the player is prompted to record it early.'

### `art/work/**` is committed despite being fully derived, and the 'LFS later is a one-day migration' escape hatch is wrong — retroactive LFS adoption is a history rewrite.

**Breaks because:** §1.4 commits `art/raw/` (2K sheets) *and* `art/work/{sliced,clean}` (16 cells × 2 stages per sheet). But `grid_slice.py` and `rembg_matting.py` are both deterministic given the sheet, so `work/` is regenerable from `raw/` + the recorded prompt — the doc says as much ('[raw] is what you regenerate variants from'). At ~14 sheets that is ~450 extra binary files for zero information. More importantly, §1.1's gate ('fails the build if the working tree exceeds 750 MB; that is the signal to introduce LFS... a one-day migration if it ever fires') is a false comfort: adopting LFS after PNGs are already in history requires `git lfs migrate import --include='art/raw/**'` followed by a force-push, which rewrites every commit SHA and invalidates every existing clone, branch and open PR. It is not a one-day, low-risk migration; it is the kind of operation you schedule.

**Fix:** Two edits, both in M0 before the first PNG lands. (1) Add `art/work/` to .gitignore alongside `art/rejects/`, and make `art/scripts/slice_and_matte.sh` idempotent so `work/` can be rebuilt on demand; keep `art/manifest.csv` and `art/prompts/` as the actual audit trail. (2) Commit a `.gitattributes` at the repo root with `art/raw/** filter=lfs diff=lfs merge=lfs -text` on day one — one line, zero cost while the repo is empty, and it removes the retroactive-rewrite scenario permanently. Deliberately leave `client/assets/**` out of LFS: that is where LFS actually hurts (Godot's importer plus CI checkout, exactly as §1.1 argues), and promoted icons at ≤512 px are small. Keep the 750 MB CI gate as a tripwire, but reframe it as 'something has gone wrong' rather than 'time to migrate'.

### M6's `refresh materialized view concurrently` every 5 minutes has no unique index, no scheduler, contradicts the 'nothing ticks' principle, and is unnecessary at the plan's own scale.

**Breaks because:** Four separate defects in one line. (a) `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires at least one UNIQUE index on the matview or Postgres errors out, and it cannot be the *first* refresh — an unpopulated matview must be refreshed non-concurrently once. Neither is mentioned. (b) Nothing runs it: `infra/` contains only `keepwarm.cron`, and §3's cross-cutting architecture states 'Nothing ticks. There is no background job.' (c) On Neon, a 5-minute refresh cycle guarantees the compute never suspends, which interacts with the quota problem above. (d) §7 targets 'revisit above 10k DAU'; at a few thousand rows, `select ... order by power desc limit 100` on a btree index is sub-millisecond, so the matview machinery is pure cost.

**Fix:** Drop matviews from v1. Serve the player board from `select id, nickname, power from players where deleted_at is null order by power desc limit 100` against the `players_power_idx` recommended above, cached in Redis for 60 s (cache-miss cost is one indexed scan). Serve 'your rank' as `select count(*)+1 from players where power > $1 and deleted_at is null`. Kingdom board: the same shape over a `kingdoms.reputation` column maintained on each attack. Delete `mv_player_ranks` / `mv_kingdom_ranks` from the M6 schema list and put 'materialised ranks' in docs/80-backlog.md with the trigger condition ('players table > 100k rows or the top-100 query p99 > 20 ms'). If matviews are ever reintroduced, the refresh needs a real scheduler (pg_cron on a paid Neon plan, or a single leader-elected goroutine), plus `create unique index on mv_player_ranks (player_id)`.

### The PvP gold transfer specifies a single transaction but no row locking or lock ordering, so it is both racy and deadlock-prone.

**Breaks because:** §3 says 'Both sides move in one transaction' and Appendix B has `gold bigint not null check (gold >= 0)`. Under Postgres READ COMMITTED, two attackers hitting the same defender concurrently each read the pre-attack balance and each steal 3% of it, so the defender loses ~6%. Worse, A-attacks-B concurrent with B-attacks-A locks rows in attacker-then-defender order on both sides and deadlocks (SQLSTATE 40P01), which surfaces as an intermittent 500 and a lost attack that still charged energy. The `check (gold >= 0)` will also surface as a raw constraint-violation 500 rather than a clean error code in any path where the debit is computed outside the locked read.

**Fix:** Lock both rows in one statement in canonical id order, then compute: `select id, gold, level, shield_until from players where id = any($1::uuid[]) and deleted_at is null order by id for update` (passing `[attackerID, defenderID]`; the `order by ... for update` guarantees a consistent lock order across all callers and eliminates the AB/BA deadlock). Re-check `shield_until` and the kingdom rule *after* acquiring the lock, not before. Wrap the whole handler in a single retry on 40P01 and 40001. Never rely on the CHECK constraint for business logic — compute `steal = least(floor(defender_gold * 0.03), 500 * pow(defender_level, 1.5))` from the locked read and return a typed error if it would go negative. Add a Go integration test that fires 20 concurrent attacks at one defender and asserts the defender's final gold equals the ledger sum exactly.

### The parallelism table and the 59-day total are mutually exclusive for the one developer the plan is scoped to, and the headline '4 weeks to vertical slice' understates its own arithmetic.

**Breaks because:** 3+7+5+5+4+5+4+6+5+9+6 = 59, which is the *serial* sum of every milestone including M7 (5 d) and M8 (9 d). If those genuinely run 'alongside M2 → M6' as the parallelism table claims, the critical path is 45 days, not 59. A single developer has no second thread, so 'parallel' can only mean 'reorder the start', never 'overlap the effort' — the table is describing ordering constraints while being presented as throughput. Separately, the slice (M0+M1+M2+M3+M3.5) is 24 focused days; at the stated 4.9 focused days/week that is 4.8 calendar weeks, and the headline says 'roughly four weeks'. Neither number carries any buffer for R4, which the doc itself rates H-likelihood ('expect to lose half a day to provisioning profiles'), or for App Review latency, which sits on M9a's critical path and is measured in days.

**Fix:** Retitle the table 'Ordering constraints — start-by dates, not concurrency' and add a sentence: 'With one developer these are interleaved, not overlapped; the 59-day total already counts them once.' Restate the schedule with an honest velocity: 59 focused days at 4 focused days/week (a realistic solo rate with admin, debugging and life) is 14–15 calendar weeks, not 12. Put the vertical slice at 'weeks 5–6'. Add an explicit line item after M9a: 'App Review: 1–7 days per submission, 2–3 submissions expected — budget 2 calendar weeks that consume zero engineering days.' Then add the R11 trigger the doc already wants: 'a milestone at 150% of estimate triggers a cut' — with 45 vs 59 vs 24 all written down, that trigger is now checkable.


## MINOR (2)

### The proof tour's screenshot code uses a CWD-dependent relative path and the wrong await idiom for reading the viewport texture.

**Breaks because:** `img.save_png("../proof/%s/%02d-%s.png" % [...])` is neither `res://` nor `user://` nor absolute, so it resolves against the process working directory, which differs between `godot --path client ...` run from the repo root, run from `client/`, run from a Makefile recipe, and run from CI. `res://../` is rejected outright by Godot (no traversal above the project root), so there is no res-relative fix. Separately, `await get_tree().process_frame` twice is not the documented way to read the viewport texture in Godot 4 — process_frame fires before the render server has finished the frame, so the capture can be one frame stale or, on the first step, blank. `RenderingServer.frame_post_draw` is the correct signal and is present in the 4.7.2 binary. The doc's own precedent, GameTest's `capture.gd`, already avoids both problems by using `--write-movie` and by parsing `OS.get_cmdline_user_args()` for configuration.

**Fix:** Pass an absolute output directory through user args, matching the capture.gd precedent already in the repo: `godot --path client res://tools/UiTour.tscn -- --api=... --milestone=M4 --out=$(PWD)/proof/M4--seed=42`, and in ui_tour.gd parse `--out=` from `OS.get_cmdline_user_args()`, `DirAccess.make_dir_recursive_absolute(out_dir)`, then `img.save_png(out_dir.path_join("%02d-%s.png" % [step, name]))`. Replace the two process_frame awaits with `await RenderingServer.frame_post_draw`. Make the Makefile target `make proof M=M4` the only sanctioned invocation so the absolute path is computed in one place.

### Several smaller factual and consistency defects that each cost real time on first contact.

**Breaks because:** (a) `create extension if not exists pgcrypto` is unnecessary — `gen_random_uuid()` has been core since PG13 — and on the PG18 target, `uuidv7()` gives time-ordered PKs with far better index locality for `players`, `items`, `attacks` and `gold_ledger`. (b) Patch 3 keeps `gemini-3.1-flash-image-preview` as the `--gemini-model` default, but the published model IDs are `gemini-3.1-flash-image` and `gemini-3-pro-image`; a stale `-preview` alias 404s on the very first generation call. (c) §1.6 claims to pin project.godot 'on day one' but omits `[rendering] renderer/rendering_method` and `config/features` — both of which GameTest sets — and omits `pointing/emulate_mouse_from_touch`, without which the desktop UI tour cannot drive touch-targeted Controls. (d) §1.6's rationale '1080 wide also means item art at 128px display is a 1:1 pixel match on the target device' is false: no shipping iPhone is 1080 native (1179 / 1206 / 1290 / 1320), so with `canvas_items` + `expand` everything is upscaled 1.09–1.22x. (e) `DisplayServer.get_display_safe_area()` returns native screen pixels, not stretched viewport units, so padding the bars from the raw Rect2i over-pads by 9–22% — the exact bug the section was written to prevent. (f) R9's 'no reward for beating someone more than 30% below your power' is unreachable, because PlayerSource already brackets candidates at ±25%; it can only ever apply to the revenge button, which bypasses matchmaking. (g) R9's early-warning signal ('day-2 retention for accounts that lost their first defence') requires an events/cohort pipeline that appears in no milestone — M7 ships an economy dashboard only. (h) §7 promises the diamond economy is 'shaped correctly' in v1 with three named sinks, but no milestone, endpoint or balance file implements any of them. (i) R5 overstates App Store 3.1.1: the guideline scopes odds disclosure to randomized items 'for purchase' with real money, and v1 has no IAP and no purchasable diamonds, so it does not bind yet.

**Fix:** (a) Drop the pgcrypto line; use `id uuid primary key default uuidv7()` on all four tables. (b) Default `--gemini-model` to `gemini-3.1-flash-image`, allow `gemini-3-pro-image`, and add a one-line `--list-models` sanity check to preflight.sh. (c) Add `config/features=PackedStringArray("4.7", "Mobile")`, `renderer/rendering_method="gl_compatibility"` (fastest cold start and lowest memory for a pure-2D anchored-Control UI on iPhone; `mobile` is the fallback if any 2D lighting is wanted), and `pointing/emulate_mouse_from_touch=true`. (d) Replace the 1:1 claim with 'author source art at 1.5x (192 px for a 128 px logical slot)' or raise the base width to 1290. (e) Convert the safe area explicitly: `var s := get_viewport().get_visible_rect().size.x / float(DisplayServer.window_get_size().x); var safe := DisplayServer.get_display_safe_area(); top_pad = safe.position.y * s`. Make it a unit-tested helper in `ui.gd`. (f) Either widen the bracket to ±35% and keep the rule, or restate it as 'applies to revenge targets only'. (g) Add a minimal `events (player_id uuid, name text, ts timestamptz, props jsonb)` table plus one retention query to M7, or replace the signal with something derivable from `attacks` (repeat attacker→defender pairs, defender loss counts per 7 days). (h) Add three endpoints to M5 — `POST /v1/diamonds/refill-energy`, `POST /v1/diamonds/shield`, `POST /v1/diamonds/shop-reroll` — with prices in `balance/`, or move diamonds to the §7 cut list honestly. Note that the reroll sink conflicts with the deterministic-shop decision and needs a `reroll_count` in the seed. (i) Re-rate R5's 3.1.1 exposure to L/M for v1 and keep the odds screen as forward-looking UX, so the register's weight moves to 5.1.1(v), the privacy policy URL and the age rating, which do bind.


## Missing coverage

- Branch and PR policy. Every guard the plan relies on — contract-guard.yml, art-guard.yml, the 750 MB size gate, the Neon-branch-per-PR integration suite — is described as failing 'a PR'. A solo developer pushing directly to main bypasses all of them, and nothing in the doc requires a branch or protects main. Specify: all work on short-lived branches, main protected with required status checks, and 'merge your own PR' as the normal flow.
- Godot in CI. client.yml is asserted green from M0, but the plan never says how a GitHub runner obtains Godot 4.7.2 or the export templates, how the ~200 MB ios.zip and the editor binary are cached, or how long `godot --headless --path client --import` takes once client/assets holds hundreds of PNGs. This is the single most likely CI job to be quietly disabled. Needs an explicit cache key (godot-4.7.2 + hash of client/assets), a committed .godot import cache decision, and a target runtime.
- Migration/deploy ordering. deploy.sh is 'pull image, goose up, compose up -d' — schema first, binary second. Any non-additive migration therefore runs against the still-live old binary, and a failed image start leaves a migrated database with no compatible server. The runbook needs an expand/contract rule (add columns nullable, deploy, backfill, deploy, drop in a later release) and a documented rollback that does not require `goose down`.
- Cost model. The plan has an $80 art budget and nothing else. Missing: VPS (~EUR 5-20/mo), Neon (Free is provably insufficient given the keep-warm cron — see confirmed problems), Vercel, domain, Apple Developer Program ($99/yr, and required before any TestFlight build, i.e. a hard M0/M9a dependency), Steamworks ($100, correctly deferred). A one-table monthly run-rate belongs in docs/50-runbook.md.
- Balance constants for every gold sink. The doc gives formulas for energy, XP, collect, tax, power, steal and shop windows, but no numbers for the things that consume gold: slots.json's price curve, soldier recruit costs by type, item price-by-tier, family and kingdom upgrade costs, kingdom founding cost, base_tax. R8's stated target ('sink ratio >= 0.85') is therefore unverifiable, and M3's DoD ('buying the third slot costs visibly more than the second') has no number behind it.
- Push notifications and the return hook. Correctly deferred to v1.1 in §7, but §4's own closing beat is 'the timer says four minutes' — energy-full is the re-engagement trigger for the entire game loop, and v1 has no way to fire it. This is a product risk worth a row in the register even while the implementation stays deferred, because it changes how aggressively the offline tax cap and energy regen should be tuned in the meantime.
- Analytics / retention instrumentation. R9's early-warning signal, R8's 'median gold held by day-7 players', and the whole notion of tuning an idle economy all assume cohort data. The only data surface built is M7's gold_ledger aggregation. Either add a minimal events table in M7 or downgrade every early-warning signal that depends on cohorts to something the gold_ledger and attacks tables can actually answer.
- Item and gold_ledger retention. gold_ledger appends on every gold delta with no partitioning and no retention policy, on a Neon plan billed by storage (Free is 0.5 GB). At 1,000 DAU x ~200 deltas/day that is ~73M rows/year. Needs either monthly partitioning with a drop-after-90-days policy, or a daily rollup table (player_id, day, reason, sum) with raw rows retained for 30 days.

## Corrected recommendations

## What is genuinely sound — keep it

Verified against the machine and against upstream, these hold up and should not be revisited:

- **Every environment fact.** I checked all of them: `4.7.2.stable.official.ed1daf0bf`, `go1.27.0 darwin/arm64`, `~/go/bin` = `air goose gopls govulncheck migrate oapi-codegen sqlc staticcheck wails`, psql 17.5, `/opt/homebrew/bin/python3.12` present, export templates dir containing **only** `ios.zip`, `~/Library/MobileDevice/Provisioning Profiles/` **empty**, exactly two `Apple Development … (JS3GR55886)` identities. Nothing was fabricated.
- **The godogen analysis is correct line-by-line.** `import xai_sdk` at line 23 and `from tripo3d import (...)` at line 28 are module-scope; `GEMINI_MODEL = "gemini-3.1-flash-image-preview"` at line 72; `--model … default="grok"` at line 530; `make_qa_preview(out, output_path, bg_color)` at line 312 with `bg_color` bound only at line 169 inside `remove_background()`; `requirements.txt` pins `onnxruntime-gpu` + `nvidia-cudnn-cu12==9.*`. `publish.sh` does `rm -rf "${TARGET:?}"` on `--force` and `rsync -a --delete` into `.claude/skills/`, and writes a `.gitignore` containing `assets`, `*.import`, `.claude`. **Fork-not-sync is the right call and the four patches are correct.** One note: `tools/tripo3d.py` is a *local sibling module* importing only `os/time/pathlib/requests`, so patch 1's "drop tripo3d-only deps" is a no-op — there are none in requirements.txt.
- I tested `set -euo pipefail; [ -n "" ] && { …; exit 1; }` — bash **does not** exit early (the `&&`-list exemption applies). `vendor-asset-gen.sh` is fine.
- **Gemini pricing in R7 is exactly right** despite the weak third-party citation. Official: 3 Pro Image `$0.134` at 1K/2K and `$0.24` at 4K; 3.1 Flash Image `$0.045`/`$0.067`/`$0.101`/`$0.151` at 0.5K/1K/2K/4K; batch is half. The 2K-sheet-for-$0.10 discipline is correct.
- **Godot 4.7's `offset_transform_*` Control properties are real** — the M8 juice claim is not invented. Android via GABE really did reach stable in 4.7.
- **Next.js 16 really is Active LTS** — the "(LTS)" label is correct, not marketing invention.
- `expand` over `keep_width` for anchored-Control UI, the two-DSN Neon split, the deterministic shop window, the mandatory `gold_ledger` with a reason enum, PvP-as-transfer-not-mint, `OpponentSource` as an interface from day one, lazy energy materialisation from Postgres `now()`, and the contact-sheet-over-video proof ritual are all good calls. `art/` as a sibling of `client/` is correct — Godot's importer will not walk it.

## The five things to change before writing any code

**1. Add `players.power` in M3, not M4.** It is a denormalised cache written inside the same transaction as every mutation that can move it, routed through a single `store.RecomputePower(ctx, tx, playerID)`. Index `create index players_power_idx on players (power) where deleted_at is null;`. Without it, M4's matchmaking query is fiction and Appendix B's index is indexing the wrong column under a misleading name.

**2. Idempotency goes in Postgres, in the same transaction as the gold move.** Redis becomes an optional read-through cache in front of it. This is what M2 already does for `shop_purchases`; make the general case match. `primary key (player_id, key)`, `insert … on conflict do nothing returning 1` as the guard. Otherwise "Redis must never lose gold" is false the first time a deploy restarts the container mid-retry.

**3. Pin the container architecture in three places on M0 day one.** `ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64` in the Dockerfile builder, `--platform linux/amd64` on the buildx invocation, `platform: linux/amd64` in compose.yaml. Better: move the image build to a GitHub Actions linux/amd64 runner and reduce `deploy.sh` to pull-and-restart. Building on the Mac under colima and deploying to a DO LON1 droplet produces `exec format error` on the very first `make deploy`.

**4. Resolve the Neon plan question before installing `keepwarm.cron`.** Free is 100 CU-hours/project/month with scale-to-zero that *cannot be disabled*; a `SELECT 1` every 4 minutes burns ~182 CU-hours and the project's compute is then suspended until the next billing period, dropping all connections. Either budget the Launch plan (~$19/mo of metered compute for an always-on 0.25 CU) and delete the cron as redundant, or stay on Free, delete the cron, and lean entirely on R2's cold-start handling (`ConnectTimeout ≥ 10s`, `MinConns = 0` — `MinConns=2` does not prevent autosuspend — and a 3-second client spinner). Add `NEON_API_KEY` to §2.1 either way, and cap per-PR branches at 10.

**5. Fix the economy before the slice is built, because the slice *is* the economy.**

Add `balance/energy.json` — `{ "max_energy_base": 20, "regen_seconds": 12, "offline_cap_seconds": 28800 }` — because the energy formula reads three constants that live nowhere today.

Flatten the early XP curve to `xp_to_next(L) = floor(20 * L^1.4)` (20 / 52 / 93 / 139, cumulative 304 to L5) and pin the early ladder at 5 XP per energy. At 20 max energy and 12 s/energy a ten-minute session affords 70 energy, so L5 lands at ~minute 8 — which makes M1's DoD *true*. The current `50 * L^1.8` needs 1,191 XP, i.e. ~17 XP/energy, which contradicts §4's own "eleven Grapes taps → level 2".

Then cap attack gold against the collect rate:

```
attack_gold = min(
  floor(0.03 * opponent_bank),
  attack_energy_cost * best_unlocked_job_gold_per_energy * 2.0
)
bot_bank            = player_gold_earned_last_24h * uniform(0.15, 0.45)
bot_gold_daily_cap  = 0.25 * (86400 / regen_seconds) * best_unlocked_job_gold_per_energy
```

§4's "steal 340 gold" is ~17× the collect rate per energy against a 2 gold/energy ladder, and it buys three of the Rare swords the player was saving for two minutes earlier. That kills the Collect tab, which the brief names the **primary** gold source. Move the excitement to a ~20% item drop at the opponent's tier band — items are what the player actually wants, and they are not a faucet. Write `bot_gold_daily_cap` into `balance/combat.json` and enforce it from `gold_ledger` where `reason = 'attack_win_bot'`; M3.5 currently makes bots the largest faucet in the game and the only unnumbered one, which directly undermines R8.

## Schema corrections to Appendix B

```sql
-- no pgcrypto: gen_random_uuid() has been core since PG13, and PG18 has uuidv7()
create table players (
    id            uuid primary key default uuidv7(),   -- time-ordered: better index locality
    device_hash   text        not null,                 -- NOT inline-unique; see partial index
    ...
    power         bigint      not null default 0,       -- denormalised, maintained in-tx
    ...
);

-- deletion must not permanently ban the device, and must satisfy GDPR erasure
create unique index players_device_hash_uq on players (device_hash) where deleted_at is null;
create index        players_power_idx      on players (power)       where deleted_at is null;
create index        players_last_seen_idx  on players (last_seen_at desc);

create table request_idem (
    player_id  uuid        not null references players(id) on delete cascade,
    key        text        not null,
    endpoint   text        not null,
    response   jsonb       not null,
    created_at timestamptz not null default now(),
    primary key (player_id, key)
);
create index request_idem_gc_idx on request_idem (created_at);
```

Account deletion becomes `update players set device_hash = 'deleted:' || id::text, nickname = '', deleted_at = now()` — plus a client-side clear of `user://device.id`, which is the step that gets missed.

The PvP transfer needs a canonical lock order to be both correct and deadlock-free:

```sql
select id, gold, level, shield_until from players
 where id = any($1::uuid[]) and deleted_at is null
 order by id for update;      -- ordering here kills the AB/BA deadlock
```

Re-check `shield_until` and the kingdom rule *after* the lock, retry once on `40P01`/`40001`, and never let `check (gold >= 0)` be the business logic.

## Scope reductions that buy back time

- **Drop materialised views from M6.** `CONCURRENTLY` needs a UNIQUE index it doesn't have, cannot be the first refresh, has no scheduler in `infra/`, contradicts the "nothing ticks" principle, and guarantees the Neon compute never sleeps. At <10k DAU, `order by power desc limit 100` on `players_power_idx` behind a 60-second Redis cache is sub-millisecond. Move matviews to `docs/80-backlog.md` with a numeric trigger.
- **Gitignore `art/work/`** — it is deterministically regenerable from `art/raw/` plus the recorded prompt, and it roughly triples the binary weight. And commit a `.gitattributes` with `art/raw/** filter=lfs …` **on day one, before the first PNG**. Retroactive LFS is `git lfs migrate import` + force-push, i.e. a full history rewrite — not the "one-day migration" §1.1 promises. Leave `client/assets/**` out of LFS; that is where LFS genuinely hurts, exactly as §1.1 argues.
- **Narrow `contract-guard.yml`.** As written it fires on description-only edits to `openapi.yaml`, and it cannot be satisfied locally because the goldens are produced by the e2e suite running against a CI-created Neon branch with no described write-back. Hash only the `paths` and `components.schemas` subtrees, and make `make e2e` regenerate goldens against the local `postgres:18` stack.
- **Pick one staging story and delete the other.** Staging is invoked by §5.1 (pre-deploy e2e), §5.3 (`--api=https://staging.api.emperors.dev`) and the per-PR Neon branch requirement, and provisioned by none of them. Given the Neon quota finding, the cheap answer is to delete staging and run both the pre-deploy e2e and the UI tour against `make dev` on local `postgres:18`.
- **Re-rate R5.** Guideline 3.1.1 scopes odds disclosure to randomized items *"for purchase"* with real money. v1 has no IAP and diamonds aren't purchasable, so it doesn't bind. Build the odds screen anyway (cheap, good UX, mandatory the day IAP ships), but move the register's weight onto 5.1.1(v), the live privacy-policy URL and the age rating — the three that actually do bind.
- **Reframe the schedule honestly.** 59 focused days is the serial sum *including* M7 and M8; a solo developer cannot also run them "alongside M2 → M6". Retitle the table "ordering constraints, not concurrency", restate 59 focused days at ~4/week as 14–15 calendar weeks, put the slice at weeks 5–6 (it is 24 focused days, not "roughly four weeks"), and add a zero-engineering-day line for App Review latency on M9a's critical path.

## Add these two things to M0/M1 — they are ~a day now and impossible later

**Client version gate (M0).** `X-Client-Version` on every request; `min_client` / `recommended_client` in `/v1/state` from the active balance version; HTTP 426 + `CLIENT_TOO_OLD` below minimum; a blocking "Update required" modal in `ui.gd`. A server-authoritative game shipped through App Review *will* have old binaries live against a moved DTO shape, and ADR-0004 actively trains the team to ship server-side without a client release. Write the rule in `contract/errors.md`: additive-only within a major; any removal or type change bumps `min_client`.

**Account recovery (M1).** `recovery_code_hash` on `players`; `POST /v1/auth/recovery/issue` (once per 24 h, Crockford base32, stored hashed) and `/redeem` (rebinds device, rotates refresh tokens, single-use); a "Save your recovery code" card surfaced at level 3 on the Family tab. §7 promises this as the v1 substitute for Sign in with Apple and nothing implements it. Identity is `user://device.id` — destroyed by reinstall, doesn't travel to a new phone — so today the answer to "I got a new phone" is "start over". That belongs in the risk register regardless.

## Sources

- [Neon Free plan limits and quotas](https://neon.com/faqs/free-plan-limits-and-quotas)
- [Neon connection pooling (PgBouncer transaction mode, prepared statements)](https://neon.com/docs/connect/connection-pooling)
- [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [Godot 4.7 "Lights, Camera, Action!"](https://godotengine.org/releases/4.7/)
- [Next.js support policy (Active LTS / Maintenance LTS)](https://nextjs.org/support-policy)
- [Apple App Review Guidelines (3.1.1, 5.1.1(v))](https://developer.apple.com/app-store/review/guidelines/)
- [UUIDv7 in PostgreSQL 18](https://www.thenile.dev/blog/uuidv7)
- [Docker multi-platform images / exec format error](https://www.baeldung.com/ops/docker-build-run-format-error)