# Emperors — Schema Design

> Produced by an architecture pass on 2026-09-04 and adversarially reviewed.
> Owner decisions made *after* this document was written take precedence — see the build plan.

**Headline:** Split the data into three layers — an append-only content registry that player rows FK to, an immutable versioned JSONB balance-config that the admin panel publishes and rolls back without any redeploy, and player state in normalised Postgres tables — with equipment modelled as a pointer on the item row (making "one item, one holder" structurally impossible to violate), power materialised on `players` by application code in-transaction, leaderboards served from a 5-minute snapshot table plus an index-only rank count, and the ledger split by currency into weekly-partitioned gold (35-day retention, DROP PARTITION) and yearly-partitioned diamonds (kept forever).

---

> Target: PostgreSQL 18.6 on Neon (eu-west-2), Go 1.27 server, sqlc + pgx/v5, goose migrations, Next.js admin.
> Verified against: PG18 release notes, Neon connection-pooling / compatibility docs, PgBouncer 1.22 protocol-level prepared statements, sqlc/pgx datatype docs.

---

# 0. The three-layer model (read this first)

Everything in this design follows from one split. Getting this wrong is the expensive mistake.

| Layer | What lives here | Storage | Mutability | Who edits |
|---|---|---|---|---|
| **L1 — Content registry** | *Identity only*: `id`, `key` slug, `slot`, art asset key, `retired_at`. ~200 rows total across all content types. | Normalised tables, `content_*` prefix | **Append + retire only. Never delete, never renumber.** | Admin panel (create/retire), goose (seed) |
| **L2 — Balance config** | *Every tunable number*: cost curves, tier stat multipliers, shop roll weights, recruit tier weights, milestone thresholds, combat coefficients, tier colours. | Versioned JSONB documents, compiled to an immutable byte-identical bundle | Draft → validate → publish → rollback, atomically, **no redeploy** | Admin panel |
| **L3 — Player state** | Everything a player owns or has done. | Normalised tables, FK to **L1 ids** only | Written by the game server in ACID transactions | Game server |

**Why not put item definitions entirely in the JSONB config?** Because `player_items.def_id` must be a real foreign key. If defs live only in a config blob, publishing a config that drops a def silently orphans hundreds of thousands of rows and there is no database-level protection. L1 gives you that FK. L1 rows are tiny and change once a month.

**Why not put balance numbers in normalised tables?** Because "publish" and "rollback" then mean restoring hundreds of rows across a dozen tables transactionally, and diffing two candidate balances becomes a join nightmare. L2 as an immutable versioned document makes rollback a single `UPDATE config_active SET version_id = <older>` that restores *byte-identical* config.

**Why not in Go code?** Because that is exactly the redeploy the requirement forbids. Go holds the *interpretation* (the `Curve` evaluator, the effect-kind switch), never the coefficients.

**The one honest caveat, stated up front:** adding a *new kind of effect* (say, "reduces enemy horse defense") requires a Go deploy, because Go has to know what the effect means. Adding a new *upgrade track, item def, collect job, tier weight table, or cost curve* using an existing effect kind does **not**. That boundary is where "no redeploy" actually ends, and you should tell the designer that.

**Money and math conventions used throughout:**
- All currency is `bigint`, whole units. Sub-unit rates are `bigint` in **milli-units** (`tax_rate_mgps` = milligold per second).
- All percentages/multipliers in config are integers scaled ×1000 (`_milli` suffix). `3.000%` is `30000` milli-percent... no: `gold_steal_pct_milli: 3000` = 3.000%.
- **Cost/curve math may use float64 internally then round** (server-only, never replayed).
- **Combat math is integer-only, no floats anywhere.** The client re-simulates battles from a seed; a single float rounding difference between Go and GDScript desyncs every replay. This is a hard rule, not a preference.
- All timestamps are `timestamptz`, `now()` default, UTC.

---

# 1. Migration plan

`goose`, SQL migrations, sequential five-digit numbering (one developer; switch to timestamp prefixes if the team reaches 3+). Files under `db/migrations/`.

```
00001_extensions_and_enums.sql
00002_admin_users.sql               -- config FKs actor -> admin_users, so admin comes first
00003_config_system.sql
00004_content_registry.sql
00005_players_and_auth.sql
00006_progression.sql               -- family upgrades, collect progress
00007_soldiers.sql                  -- slots then soldiers
00008_items_and_equipment.sql       -- FK targets soldiers, so it comes after 00007
00009_shop_state.sql
00010_kingdoms.sql                  -- adds players.kingdom_id FK (circular, resolved by ALTER)
00011_battles_and_shields.sql       -- partitioned
00012_ledgers.sql                   -- partitioned
00013_leaderboards.sql
00014_iap.sql
00015_moderation_and_ops.sql
00016_mail.sql
00017_roles_and_grants.sql
```

**Ordering constraints that will bite you if ignored:**
- `admin_users` before `config_versions` (`created_by` FK).
- `config_versions` before `players` (`power_config_version` FK) and before `player_items`/`soldiers` (`rolled_config_version` FK).
- `player_soldier_slots` before `soldiers` (composite FK).
- `soldiers` before `player_items` (composite FK `(equipped_soldier_id, player_id)`).
- `players` and `kingdoms` are mutually referential — create `kingdoms` in 00010 and `ALTER TABLE players ADD CONSTRAINT ... FOREIGN KEY (kingdom_id)` in the same file.

**Enum caveat:** `ALTER TYPE ... ADD VALUE` cannot be used in the same transaction that then uses the new value. goose runs each migration in a transaction by default. Any migration that adds an enum value must be marked `-- +goose NO TRANSACTION` and put the `ADD VALUE` in its own migration, separate from any migration that inserts rows using it.

**Migrations run against the DIRECT (unpooled) Neon endpoint.** goose takes a *session-level* advisory lock and issues `SET` statements; Neon's PgBouncer runs in transaction mode and supports neither. Runtime traffic uses the pooled endpoint. Two env vars: `DATABASE_URL` (pooled, `...-pooler.eu-west-2.aws.neon.tech`) and `DATABASE_URL_DIRECT` (no `-pooler`).

**Seeding is NOT done in goose.** goose does DDL plus the L1 registry rows only (`INSERT ... ON CONFLICT (key) DO NOTHING`). L2 config version 1 is seeded by a separate idempotent command:

```
cmd/emperors-seed/     // //go:embed seed/config/v1/*.json
  → validates every section against its JSON Schema
  → validates every referenced slug exists in the L1 registry
  → creates config_versions row, config_documents rows, compiles the bundle, publishes it
  → no-op if a published version already exists (unless --force-new-version)
```
Rationale: a 200 KB JSON blob inside a `.sql` file is unreviewable in a PR and unrunnable per-environment. Embedded JSON gets diffed properly in git and applied identically to every Neon branch.

---

# 2. DDL

## 00001 — Extensions and enums

```sql
-- +goose Up
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive names, anti-impersonation
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- admin fuzzy search on player/kingdom names
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_bytes for codes/secrets
-- NOTE: pg_cron is NOT available on Neon (no background workers). All scheduled
-- work runs in the Go server; see §9.

CREATE TYPE player_state       AS ENUM ('active','dormant','banned','deleted');
CREATE TYPE item_slot          AS ENUM ('weapon','armor','horse');
CREATE TYPE item_tier          AS ENUM ('common','uncommon','rare','epic','legendary','mystic','special');
CREATE TYPE soldier_type       AS ENUM ('peasant','mercenary','gladiator');
CREATE TYPE item_source        AS ENUM ('shop','battle','starter','quest','admin','iap','kingdom');
CREATE TYPE kingdom_role       AS ENUM ('leader','officer','member');
CREATE TYPE battle_outcome     AS ENUM ('attacker_win','defender_win');
CREATE TYPE currency           AS ENUM ('gold','diamond');
CREATE TYPE identity_provider  AS ENUM ('device','apple','google','email');
CREATE TYPE iap_platform       AS ENUM ('ios','android');
CREATE TYPE config_status      AS ENUM ('draft','published','archived');
CREATE TYPE admin_role         AS ENUM ('owner','admin','designer','support','readonly');
CREATE TYPE sanction_kind      AS ENUM ('ban','mute','name_reset','shadowban');
```

**Enum vs lookup table policy.** Enums for *closed, schema-level* sets that the game engine switches on (above). A `smallint` FK to a lookup table for sets that grow with gameplay features and need display metadata — specifically `ledger_reasons`. Rationale: enums give sqlc real Go constants (`ItemTierMystic`), which is what you want for combat and roll logic; ledger reasons need a human label and an analytics category, and are 2 bytes instead of an OID-sized enum on a table that will have tens of millions of rows.

**Why `bigint GENERATED ALWAYS AS IDENTITY` and not `uuidv7()` PKs**, even though PG18 has `uuidv7()`: 8 bytes vs 16 across ~15 FK columns and every index entry, on the tables that dominate storage (`player_items`, `gold_ledger`, `battles`). Enumeration is not a threat because every endpoint authorises on `player_id` from the JWT. For anything a human shares (support tickets, friend invites) `players.player_code` is an opaque 8-char base32 string.

## 00002 — Admin

```sql
CREATE TABLE admin_users (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at       timestamptz NOT NULL DEFAULT now(),
    last_login_at    timestamptz,
    disabled_at      timestamptz,
    totp_enrolled_at timestamptz,
    email            citext NOT NULL UNIQUE,
    name             text   NOT NULL,
    password_hash    text,            -- argon2id; NULL when SSO-only
    totp_secret      bytea,           -- sealed application-side, never plaintext
    role             admin_role NOT NULL DEFAULT 'readonly'
);

CREATE TABLE admin_sessions (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_id      bigint NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    token_hash    bytea  NOT NULL UNIQUE,      -- sha256(session token)
    issued_at     timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,
    revoked_at    timestamptz,
    ip            inet,
    user_agent    text
);
CREATE INDEX admin_sessions_admin_idx ON admin_sessions (admin_id) WHERE revoked_at IS NULL;

-- Append-only. Partitioned monthly, NEVER dropped. Grants in 00017 revoke UPDATE/DELETE.
CREATE TABLE admin_audit_log (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    at          timestamptz NOT NULL DEFAULT now(),
    actor_id    bigint REFERENCES admin_users(id) ON DELETE SET NULL,
    actor_email citext NOT NULL,          -- denormalised: survives admin deletion
    action      text   NOT NULL,          -- 'config.publish', 'player.grant_gold', ...
    target_type text   NOT NULL,          -- 'player' | 'kingdom' | 'config' | 'item'
    target_id   text,
    before      jsonb,
    after       jsonb,
    ip          inet,
    request_id  uuid,
    PRIMARY KEY (id, at)
) PARTITION BY RANGE (at);

CREATE INDEX admin_audit_target_idx ON admin_audit_log (target_type, target_id, at DESC);
CREATE INDEX admin_audit_actor_idx  ON admin_audit_log (actor_id, at DESC);
```

## 00003 — The versioned config system

This is the answer to "retune without a redeploy".

```sql
-- Section catalogue. One row per top-level config domain. The JSON Schema is stored
-- here so the Next.js admin can render a form and validate client-side using the
-- exact same schema the server enforces.
CREATE TABLE config_sections (
    key            text PRIMARY KEY,
    display_name   text NOT NULL,
    sort_order     smallint NOT NULL DEFAULT 0,
    json_schema    jsonb NOT NULL,
    client_visible boolean NOT NULL DEFAULT true,   -- false => never leaves the server
    description    text NOT NULL DEFAULT ''
);

CREATE TABLE config_versions (
    id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label        text    NOT NULL,                  -- 'v14 — nerf gladiator'
    status       config_status NOT NULL DEFAULT 'draft',
    parent_id    integer REFERENCES config_versions(id),   -- forked from
    created_by   bigint  REFERENCES admin_users(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_by bigint  REFERENCES admin_users(id) ON DELETE SET NULL,
    published_at timestamptz,
    notes        text NOT NULL DEFAULT '',
    CONSTRAINT config_versions_published_ck
        CHECK ((status = 'draft') = (published_at IS NULL))
);
CREATE INDEX config_versions_status_idx ON config_versions (status, created_at DESC);

-- One row per (version, section). Editing one section does not touch the others,
-- so two designers can work on shop weights and collect jobs without conflicting.
CREATE TABLE config_documents (
    version_id  integer NOT NULL REFERENCES config_versions(id) ON DELETE CASCADE,
    section_key text    NOT NULL REFERENCES config_sections(key),
    body        jsonb   NOT NULL,
    updated_by  bigint  REFERENCES admin_users(id) ON DELETE SET NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (version_id, section_key)
);

-- Compiled, immutable artefact. Built exactly once, on publish. Rollback restores
-- byte-identical bytes, which is why rollback is safe.
CREATE TABLE config_bundles (
    version_id         integer PRIMARY KEY REFERENCES config_versions(id) ON DELETE CASCADE,
    etag               text  NOT NULL UNIQUE,   -- 'sha256:...' over body_raw
    body_raw           bytea NOT NULL,          -- canonical (sorted-key) JSON, client_visible sections only
    body_gzip          bytea NOT NULL,
    byte_size          integer NOT NULL,
    built_at           timestamptz NOT NULL DEFAULT now(),
    client_min_version text                     -- semver gate; older clients keep the old bundle
);

-- Singleton row. The game server polls this every 10s (see §9); the poll doubles as
-- the Neon keep-alive that prevents autosuspend cold starts.
CREATE TABLE config_active (
    only_row         boolean PRIMARY KEY DEFAULT true CHECK (only_row),
    version_id       integer NOT NULL REFERENCES config_versions(id),
    etag             text    NOT NULL,
    activated_at     timestamptz NOT NULL DEFAULT now(),
    activated_by     bigint REFERENCES admin_users(id) ON DELETE SET NULL,
    grace_version_id integer REFERENCES config_versions(id),  -- previous version
    grace_until      timestamptz                              -- accepted from in-flight clients until then
);

CREATE TABLE config_publish_log (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version_id          integer NOT NULL REFERENCES config_versions(id),
    previous_version_id integer REFERENCES config_versions(id),
    action              text NOT NULL CHECK (action IN ('publish','rollback')),
    actor_id            bigint REFERENCES admin_users(id) ON DELETE SET NULL,
    at                  timestamptz NOT NULL DEFAULT now(),
    diff_summary        jsonb NOT NULL DEFAULT '{}',  -- per-section changed-key counts
    sim_report          jsonb                          -- dry-run economy simulation output
);
```

### Publish pipeline (server-side, one transaction)

1. **Schema validation** — every section body against `config_sections.json_schema`.
2. **Referential validation** — every slug referenced in the config (`item def keys`, `collect job keys`, `upgrade track keys`, `iap skus`) must exist and be non-retired in the L1 registry. Every effect kind must be one Go knows. Every tier weight map must reference only the seven tiers and sum > 0. No negative costs. Curves monotonic where required.
3. **Dry-run simulation** — run a headless 30-day economy sim (levels 1→40) under the candidate config and diff gold/hour, time-to-level, expected shop spend against the currently published version. Store as `sim_report`. Block publish if any metric moves more than a configured threshold without an explicit `--acknowledge-large-change`.
4. **Compile** — canonical JSON (sorted keys, no whitespace) of `client_visible` sections → `body_raw`; gzip; `etag = 'sha256:' || encode(digest(body_raw,'sha256'),'hex')`.
5. **Flip** — `UPDATE config_versions SET status='published'...`; `UPDATE config_active SET version_id, etag, grace_version_id = <old>, grace_until = now() + interval '5 minutes'`; insert `config_publish_log`; insert `admin_audit_log`.

**Rollback** is step 5 alone, pointing at an older version whose bundle already exists. Nothing is rebuilt, so a rollback cannot itself introduce a compile difference.

### How the client fetches and caches it

- `POST /v1/session` (login) returns `{"config_version": 14, "config_etag": "sha256:ab…"}`.
- Godot client: if `user://config_<etag>.json` exists, load it; else `GET /v1/config` with `If-None-Match: <cached etag>` → `304` or `200` + gzipped body (expect 60–250 KB), write to `user://`, keep the two most recent.
- Ship a **baked fallback bundle** inside the `.pck` so a cold first launch on a dead network still renders the shell and the tier colours.
- Every gameplay response carries `X-Config-Version`. If it differs from the client's, the client refetches and soft-reloads its UI data (no scene reload).
- Every **mutating** request sends `X-Config-Version`. The server rejects with `409 CONFIG_STALE` unless it equals `config_active.version_id`, or equals `grace_version_id` while `now() < grace_until`. This is what stops "I saw the old price, I paid the old price" desync at a publish boundary.

### Config sections and their shapes

| `section_key` | client_visible | Contents |
|---|---|---|
| `economy` | yes | energy base/regen/refill, tax base + offline cap, level XP curve, stat points per level, respec cost, gold cap |
| `tiers` | yes | the seven tiers: stat multiplier, price multiplier, **colour, glow, frame asset** |
| `collect_jobs` | yes | the job ladder + milestone thresholds and bonuses |
| `items` | yes | per-def stat weight, roll variance, sell-price fraction |
| `shop` | **no** | slot count, refresh seconds, type + tier weight tables, price formula, reroll cost |
| `soldiers` | partial | type costs, **tier weight tables (server-only)**, base stat tables (client-visible) |
| `family_upgrades` | yes | tracks, effect kinds, cost curves, value curves, max levels |
| `kingdom` | yes | founding cost, member cap, upgrade tracks, reputation rates |
| `combat` | yes | integer coefficients — the client re-simulates battles, so it needs these |
| `pvp` | yes | energy cost, steal %, shield seconds, matchmaking band |
| `iap` | yes | sku → diamonds |

`shop` and soldier tier weights are `client_visible = false`: the client must not be able to compute the roll table and datamine "what's in the shop next epoch". `combat` **must** be client-visible for replay.

```jsonc
// section: tiers  -- resolves the epic/mystic purple conflict, tunable without a redeploy
{
  "order": ["common","uncommon","rare","epic","legendary","mystic","special"],
  "tiers": {
    "common":    {"stat_mult_milli": 1000, "price_mult_milli":   1000, "color":"#9CA3AF", "glow":"none",              "frame":"frame_plain"},
    "uncommon":  {"stat_mult_milli": 1450, "price_mult_milli":   2200, "color":"#22C55E", "glow":"none",              "frame":"frame_plain"},
    "rare":      {"stat_mult_milli": 2100, "price_mult_milli":   5000, "color":"#3B82F6", "glow":"soft",              "frame":"frame_notched"},
    "epic":      {"stat_mult_milli": 3050, "price_mult_milli":  11000, "color":"#8B5CF6", "glow":"soft",              "frame":"frame_notched"},
    "legendary": {"stat_mult_milli": 4400, "price_mult_milli":  24000, "color":"#F59E0B", "glow":"strong",            "frame":"frame_crown"},
    "mystic":    {"stat_mult_milli": 6400, "price_mult_milli":  52000, "color":"#E879F9", "glow":"animated_gradient", "frame":"frame_arcane"},
    "special":   {"stat_mult_milli": 9200, "price_mult_milli": 115000, "color":"#EF4444", "glow":"animated_flame",    "frame":"frame_royal"}
  },
  "roll_variance_milli": 120
}
```

```jsonc
// section: collect_jobs -- note thresholds are config, which is why the DB stores
// only total_collects and never a derived milestone tier.
{
  "jobs": [
    {"key":"grapes",       "min_level":1,  "energy":1, "gold":2,   "xp":1},
    {"key":"strawberries", "min_level":3,  "energy":2, "gold":4,   "xp":2},
    {"key":"wheat",        "min_level":6,  "energy":4, "gold":9,   "xp":5},
    {"key":"olives",       "min_level":10, "energy":7, "gold":17,  "xp":9},
    {"key":"quarry",       "min_level":15, "energy":11,"gold":29,  "xp":16}
  ],
  "milestones": [
    {"at":25,  "gold_bonus_pct_milli":5000},
    {"at":50,  "gold_bonus_pct_milli":10000},
    {"at":100, "gold_bonus_pct_milli":15000}
  ]
}
```

```jsonc
// section: family_upgrades -- effect is a CLOSED enum interpreted by Go.
// New tracks: no deploy. New effect kinds: deploy.
{
  "effect_stacking": "additive",
  "tracks": [
    {"key":"granary",     "effect":"collect_gold_pct", "max_level":50,
     "cost":  {"kind":"geometric","base":250,"growth_milli":1220},
     "value": {"kind":"linear","base":0,"step":2000}},
    {"key":"treasury",    "effect":"tax_rate_pct",     "max_level":50,
     "cost":  {"kind":"geometric","base":400,"growth_milli":1250},
     "value": {"kind":"linear","base":0,"step":3000}},
    {"key":"barracks",    "effect":"soldier_attack_pct","max_level":40,
     "cost":  {"kind":"geometric","base":900,"growth_milli":1300},
     "value": {"kind":"linear","base":0,"step":2500}},
    {"key":"stable",      "effect":"max_energy_flat",  "max_level":25,
     "cost":  {"kind":"geometric","base":1500,"growth_milli":1450},
     "value": {"kind":"linear","base":0,"step":1}},
    {"key":"scriptorium", "effect":"xp_pct",           "max_level":30,
     "cost":  {"kind":"geometric","base":700,"growth_milli":1280},
     "value": {"kind":"linear","base":0,"step":2000}}
  ]
}
```

Closed effect enum in Go: `collect_gold_pct`, `tax_rate_pct`, `soldier_attack_pct`, `soldier_defense_pct`, `hero_attack_pct`, `hero_defense_pct`, `max_energy_flat`, `energy_regen_pct`, `xp_pct`, `shop_price_pct`, `steal_pct`, `offline_cap_seconds_flat`.

```go
// internal/balance/curve.go — the whole "designers pick a shape, not code" mechanism.
type Curve struct {
    Kind        string  `json:"kind"`         // const | linear | geometric | polynomial | table | piecewise
    Base        int64   `json:"base"`
    Step        int64   `json:"step"`         // linear
    GrowthMilli int64   `json:"growth_milli"` // geometric: value = base * (growth/1000)^n
    ExpMilli    int64   `json:"exp_milli"`    // polynomial: value = base * n^(exp/1000)
    Values      []int64 `json:"values"`       // table
    Points      []struct{ At int; Value int64 } `json:"points"` // piecewise linear
    Cap         *int64  `json:"cap"`
}
func (c Curve) At(n int) int64   // clamps to Cap; returns Values[last] past the end of a table
```
No expression evaluator, ever. An `eval()` in config is a remote-code-execution hole in your admin panel and a determinism hazard in combat.

## 00004 — Content registry (L1)

```sql
CREATE TABLE content_item_defs (
    id         smallint PRIMARY KEY,             -- explicit, stable, assigned by the designer
    key        text     NOT NULL UNIQUE,         -- 'sword_falchion_02'
    slot       item_slot NOT NULL,
    art_key    text     NOT NULL,                -- maps to res://art/items/<art_key>.png
    name_key   text     NOT NULL,                -- i18n key
    min_tier   item_tier NOT NULL DEFAULT 'common',
    max_tier   item_tier NOT NULL DEFAULT 'special',
    retired_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- required so player_items can prove a horse never lands in a weapon slot:
    CONSTRAINT content_item_defs_id_slot_uq UNIQUE (id, slot)
);
CREATE INDEX content_item_defs_live_idx ON content_item_defs (slot) WHERE retired_at IS NULL;

CREATE TABLE content_collect_jobs (
    id         smallint PRIMARY KEY,
    key        text     NOT NULL UNIQUE,
    sort_order smallint NOT NULL DEFAULT 0,
    art_key    text     NOT NULL,
    retired_at timestamptz
);

CREATE TABLE content_family_upgrades (
    id         smallint PRIMARY KEY,
    key        text     NOT NULL UNIQUE,
    art_key    text     NOT NULL,
    retired_at timestamptz
);

CREATE TABLE content_kingdom_upgrades (
    id         smallint PRIMARY KEY,
    key        text     NOT NULL UNIQUE,
    art_key    text     NOT NULL,
    retired_at timestamptz
);

CREATE TABLE content_iap_products (
    id         smallint PRIMARY KEY,
    sku        text     NOT NULL,
    platform   iap_platform NOT NULL,
    kind       text     NOT NULL CHECK (kind IN ('consumable','non_consumable','subscription')),
    retired_at timestamptz,
    UNIQUE (platform, sku)
);

CREATE TABLE ledger_reasons (
    id       smallint PRIMARY KEY,
    code     text     NOT NULL UNIQUE,    -- 'collect_income','shop_buy','battle_steal_in', ...
    currency currency NOT NULL,
    category text     NOT NULL CHECK (category IN ('income','spend','transfer','admin','iap'))
);
```

The registry holds `id` **and** `key`. Config documents reference `key` (readable, diffable in git). Player tables store `id` (2 bytes). The Go config loader builds the `key ↔ id` map once at startup and rejects a config referencing an unknown or retired key.

## 00005 — Players, identities, devices, sessions

```sql
CREATE TABLE players (
    -- 8-byte columns first: minimises alignment padding on the hottest row in the DB
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kingdom_id            bigint,                     -- FK added in 00010 (circular)
    gold                  bigint NOT NULL DEFAULT 0  CHECK (gold >= 0),
    diamonds              bigint NOT NULL DEFAULT 0  CHECK (diamonds >= 0),
    xp                    bigint NOT NULL DEFAULT 0  CHECK (xp >= 0),
    gold_seq              bigint NOT NULL DEFAULT 0,  -- per-player ledger sequence
    diamond_seq           bigint NOT NULL DEFAULT 0,
    action_seq            bigint NOT NULL DEFAULT 0,  -- request idempotency, see §7
    total_power           bigint NOT NULL DEFAULT 0  CHECK (total_power >= 0),
    hero_power            bigint NOT NULL DEFAULT 0,
    army_power            bigint NOT NULL DEFAULT 0,
    tax_rate_mgps         bigint NOT NULL DEFAULT 0  CHECK (tax_rate_mgps >= 0),
    tax_carry_mg          bigint NOT NULL DEFAULT 0  CHECK (tax_carry_mg >= 0),
    kingdom_donated_gold  bigint NOT NULL DEFAULT 0,
    kingdom_rep_earned    bigint NOT NULL DEFAULT 0,

    created_at            timestamptz NOT NULL DEFAULT now(),
    last_seen_at          timestamptz NOT NULL DEFAULT now(),
    energy_updated_at     timestamptz NOT NULL DEFAULT now(),
    tax_accrued_at        timestamptz NOT NULL DEFAULT now(),
    power_recomputed_at   timestamptz NOT NULL DEFAULT now(),
    shield_until          timestamptz,
    last_attacked_at      timestamptz,
    kingdom_joined_at     timestamptz,

    level                 integer NOT NULL DEFAULT 1 CHECK (level >= 1),
    stat_points_unspent   integer NOT NULL DEFAULT 0 CHECK (stat_points_unspent >= 0),
    stat_max_energy       integer NOT NULL DEFAULT 0 CHECK (stat_max_energy >= 0),
    stat_attack           integer NOT NULL DEFAULT 0 CHECK (stat_attack >= 0),
    stat_defense          integer NOT NULL DEFAULT 0 CHECK (stat_defense >= 0),
    respec_count          integer NOT NULL DEFAULT 0,
    energy_current        integer NOT NULL DEFAULT 0 CHECK (energy_current >= 0),
    inventory_cap         integer NOT NULL DEFAULT 150 CHECK (inventory_cap > 0),
    power_config_version  integer NOT NULL REFERENCES config_versions(id),
    wins                  integer NOT NULL DEFAULT 0,
    losses                integer NOT NULL DEFAULT 0,
    defenses_won          integer NOT NULL DEFAULT 0,
    defenses_lost         integer NOT NULL DEFAULT 0,

    state                 player_state NOT NULL DEFAULT 'active',
    kingdom_role          kingdom_role,
    tz_offset_min         smallint NOT NULL DEFAULT 0,
    is_bot                boolean NOT NULL DEFAULT false,

    player_code           text   NOT NULL UNIQUE,     -- 8 chars base32, human-shareable
    display_name          citext NOT NULL UNIQUE,
    avatar_key            text   NOT NULL DEFAULT 'avatar_01',
    locale                text   NOT NULL DEFAULT 'en',

    CONSTRAINT players_kingdom_role_ck CHECK ((kingdom_id IS NULL) = (kingdom_role IS NULL)),
    CONSTRAINT players_name_len_ck     CHECK (length(display_name) BETWEEN 3 AND 16)
) WITH (fillfactor = 80);
```

**`fillfactor = 80` is deliberate and load-bearing.** `players` is updated on every single collect (gold, xp, energy, action_seq). With free space on the page Postgres can do a HOT update — a new tuple version on the same page and **no index maintenance at all**. Without it every collect dirties every index on `players`. This one setting is worth more than most of the indexes below.

The corollary: **do not index `gold`, `xp`, `energy_current`, or `action_seq`.** Any index on those columns destroys HOT and turns the highest-frequency write in the game into an index-update storm. The gold leaderboard is served by a periodic scan instead (§6) precisely for this reason.

**Kingdom membership lives on `players`, not in a `kingdom_members` join table.** A player is in at most one kingdom, so a single nullable column makes that rule structural with no unique index and no possibility of drift between two sources of truth. The matchmaking query needs `kingdom_id` on the player row anyway. Membership *history* (joins, leaves, kicks, promotions) goes to a separate low-volume audit table in 00010, which is what a join table would actually have been used for.

```sql
CREATE INDEX players_matchmaking_idx  ON players (total_power, id) WHERE state = 'active';
CREATE INDEX players_kingdom_idx      ON players (kingdom_id, kingdom_role) WHERE kingdom_id IS NOT NULL;
CREATE INDEX players_name_trgm_idx    ON players USING gin (display_name gin_trgm_ops);
CREATE INDEX players_dormancy_idx     ON players (last_seen_at) WHERE state = 'active';
```

`players_matchmaking_idx` deliberately has **no `INCLUDE` clause**. The obvious move is `INCLUDE (display_name, level, kingdom_id, shield_until, gold)` for an index-only scan, but `gold` changes on every collect and `shield_until` on every lost defence — including them re-introduces the exact index churn `fillfactor` was set to avoid. Matchmaking fetches ~24 candidate heap rows, which is ~24 random page reads (~1 ms warm). Not worth it.

```sql
CREATE TABLE player_identities (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id     bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    provider      identity_provider NOT NULL,
    provider_uid  text   NOT NULL,
    email         citext,
    linked_at     timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz,
    UNIQUE (provider, provider_uid)
);
-- many devices per account, but exactly one Apple / Google / email identity
CREATE UNIQUE INDEX player_identities_one_per_provider_uq
    ON player_identities (player_id, provider) WHERE provider <> 'device';
CREATE INDEX player_identities_player_idx ON player_identities (player_id);

CREATE TABLE devices (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id     bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    device_hash   bytea  NOT NULL,        -- sha256(identifierForVendor || server salt)
    platform      text   NOT NULL CHECK (platform IN ('ios','android','web','editor')),
    model         text,
    os_version    text,
    app_version   text,
    push_token    text,
    push_provider text CHECK (push_provider IN ('apns','fcm')),
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (player_id, device_hash)
);
CREATE INDEX devices_hash_idx ON devices (device_hash);                    -- multi-accounting detection
CREATE INDEX devices_push_idx ON devices (player_id) WHERE push_token IS NOT NULL;

CREATE TABLE sessions (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id      bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    device_id      bigint REFERENCES devices(id) ON DELETE SET NULL,
    refresh_hash   bytea  NOT NULL UNIQUE,   -- sha256 of the refresh token; plaintext never stored
    family_id      uuid   NOT NULL,          -- rotation family for reuse detection
    issued_at      timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    last_used_at   timestamptz,
    revoked_at     timestamptz,
    revoked_reason text,
    ip             inet,
    user_agent     text
);
CREATE INDEX sessions_player_idx ON sessions (player_id) WHERE revoked_at IS NULL;
CREATE INDEX sessions_expiry_idx ON sessions (expires_at) WHERE revoked_at IS NULL;
CREATE INDEX sessions_family_idx ON sessions (family_id);
```

Access tokens are stateless 15-minute JWTs (no DB read on the hot path). Refresh tokens are rows, rotated on every use; presenting an already-rotated token in a `family_id` revokes the whole family (standard reuse detection).

**Energy and tax are lazily evaluated, never ticked.** No cron, no per-player timer:
```
max_energy = cfg.energy.base_max
           + stat_max_energy * cfg.energy.per_stat_point
           + Σ family/kingdom max_energy_flat
energy_now = min(max_energy,
                 energy_current + (now - energy_updated_at) / regen_seconds_per_point)

elapsed    = min(now - tax_accrued_at, cfg.tax.offline_cap_seconds + upgrades)
accrued_mg = tax_carry_mg + tax_rate_mgps * elapsed
gold_gain  = accrued_mg / 1000 ;  new tax_carry_mg = accrued_mg % 1000
```
Both are written back in the same transaction as any mutation. `tax_carry_mg` exists so repeated short claims don't round the remainder to zero and silently steal income from the player.

## 00006 — Progression

```sql
CREATE TABLE player_family_upgrades (
    player_id  bigint   NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    upgrade_id smallint NOT NULL REFERENCES content_family_upgrades(id),
    level      integer  NOT NULL DEFAULT 0 CHECK (level >= 0),
    gold_spent bigint   NOT NULL DEFAULT 0 CHECK (gold_spent >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, upgrade_id)
);

CREATE TABLE player_collect_progress (
    player_id       bigint   NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    job_id          smallint NOT NULL REFERENCES content_collect_jobs(id),
    total_collects  bigint   NOT NULL DEFAULT 0 CHECK (total_collects >= 0),
    lifetime_gold   bigint   NOT NULL DEFAULT 0,
    lifetime_xp     bigint   NOT NULL DEFAULT 0,
    last_collect_at timestamptz,
    PRIMARY KEY (player_id, job_id)
) WITH (fillfactor = 70);
```

Rows exist only where `level > 0` / `total_collects > 0`, so a new player has ~2 rows, not 15.

**`total_collects` is stored; the milestone tier is not.** The 25/50/100 thresholds and the +5/+10/+15% bonuses are config, so a derived column or trigger would hard-code them into the schema and a retune would require a migration and a backfill. Go reads `total_collects` and looks the bonus up in the active config — a threshold change applies retroactively and correctly to every player instantly.

`fillfactor = 70` because this table takes ~200 UPDATEs/day/player across ~5 rows; no indexed column changes, so every one is a HOT update.

**Family/kingdom upgrades are a table, not a JSONB column on `players`.** A JSONB column is cheaper (no extra rows, no second query) but loses the FK to the registry and makes the admin panel's "what fraction of players bought Barracks 10?" a full-table JSONB scan. 600k rows is nothing; live-ops analytics is not.

## 00007 — Soldier slots and soldiers

```sql
-- Purchased slots are REAL ROWS, not a counter on players. That makes
-- "a soldier cannot exist in a slot you never bought" a foreign key
-- instead of an application invariant, and gives the purchase audit for free.
CREATE TABLE player_soldier_slots (
    player_id    bigint   NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    slot_index   smallint NOT NULL CHECK (slot_index >= 0 AND slot_index < 32),
    purchased_at timestamptz NOT NULL DEFAULT now(),
    price_gold   bigint   NOT NULL DEFAULT 0 CHECK (price_gold >= 0),
    PRIMARY KEY (player_id, slot_index)
);

CREATE TABLE soldiers (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id             bigint   NOT NULL,
    recruited_at          timestamptz NOT NULL DEFAULT now(),
    base_attack           integer  NOT NULL CHECK (base_attack  >= 0),
    base_defense          integer  NOT NULL CHECK (base_defense >= 0),
    rolled_config_version integer  NOT NULL REFERENCES config_versions(id),
    price_gold            bigint   NOT NULL DEFAULT 0,
    slot_index            smallint NOT NULL,
    type                  soldier_type NOT NULL,
    tier                  item_tier    NOT NULL,
    name                  text,

    CONSTRAINT soldiers_id_player_uq   UNIQUE (id, player_id),        -- target of the items FK
    CONSTRAINT soldiers_slot_uq        UNIQUE (player_id, slot_index),
    CONSTRAINT soldiers_slot_fk FOREIGN KEY (player_id, slot_index)
        REFERENCES player_soldier_slots (player_id, slot_index) ON DELETE CASCADE
);
```

**Rolled stats are frozen on the row.** `base_attack`/`base_defense` are computed once at recruit from `(type, tier, config)` and never re-derived. Recomputing from live config would mean a rebalance silently nerfs soldiers players already paid for — the single fastest way to lose a mid-core audience. `rolled_config_version` records which balance produced the roll, so an admin migration job can deliberately re-roll a cohort with a full audit trail when a genuine balance bug ships.

## 00008 — Items and equipment

This is the section the brief asks to defend hardest.

```sql
CREATE TABLE player_items (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id             bigint  NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    equipped_soldier_id   bigint,
    acquired_at           timestamptz NOT NULL DEFAULT now(),
    def_id                smallint NOT NULL,
    attack                integer NOT NULL CHECK (attack  >= 0),
    defense               integer NOT NULL CHECK (defense >= 0),
    rolled_config_version integer NOT NULL REFERENCES config_versions(id),
    slot                  item_slot   NOT NULL,   -- denormalised from the def, on purpose
    tier                  item_tier   NOT NULL,
    source                item_source NOT NULL,
    equipped_on_hero      boolean NOT NULL DEFAULT false,
    is_locked             boolean NOT NULL DEFAULT false,  -- player-marked "don't auto-sell"

    is_equipped boolean GENERATED ALWAYS AS
        (equipped_on_hero OR equipped_soldier_id IS NOT NULL) STORED,

    -- (a) an item is held by at most one thing
    CONSTRAINT player_items_single_holder_ck
        CHECK (NOT (equipped_on_hero AND equipped_soldier_id IS NOT NULL)),

    -- (b) a horse can never be a "weapon": slot is proven to match the definition
    CONSTRAINT player_items_def_slot_fk
        FOREIGN KEY (def_id, slot) REFERENCES content_item_defs (id, slot),

    -- (c) you can only equip onto YOUR OWN soldier, and deleting a soldier
    --     unequips rather than orphans. The column list on SET NULL (PG15+) is
    --     what makes this legal: player_id stays NOT NULL.
    CONSTRAINT player_items_soldier_owner_fk
        FOREIGN KEY (equipped_soldier_id, player_id)
        REFERENCES soldiers (id, player_id)
        ON DELETE SET NULL (equipped_soldier_id)
);

-- (d) at most one item per slot per soldier
CREATE UNIQUE INDEX player_items_soldier_slot_uq
    ON player_items (equipped_soldier_id, slot)
    WHERE equipped_soldier_id IS NOT NULL;

-- (e) at most one item per slot on the hero
CREATE UNIQUE INDEX player_items_hero_slot_uq
    ON player_items (player_id, slot)
    WHERE equipped_on_hero;

-- Inventory list: free items, newest/strongest first, paged.
CREATE INDEX player_items_free_idx
    ON player_items (player_id, slot, tier DESC, attack DESC, id DESC)
    WHERE equipped_on_hero = false AND equipped_soldier_id IS NULL;

-- Load the whole equipped loadout in one scan (army power, battle snapshot).
CREATE INDEX player_items_equipped_idx
    ON player_items (player_id)
    INCLUDE (equipped_soldier_id, equipped_on_hero, slot, tier, attack, defense, def_id)
    WHERE equipped_on_hero = true OR equipped_soldier_id IS NOT NULL;
```

### Why the pointer lives on the *item*, not as three columns on the soldier

Three columns on `soldiers` (`weapon_item_id`, `armor_item_id`, `horse_item_id`) is the obvious model and it **cannot express the requirement**. You can put a `UNIQUE` on each column, but three independent uniques do not compose: nothing stops item #5000 being in soldier A's `weapon_item_id` *and* soldier B's `armor_item_id`. Expressing "unique across three columns of the same table" declaratively requires an exclusion constraint over an unnest, or a trigger. Both are worse than the alternative.

With the pointer on the item, "an item cannot be equipped on two soldiers" isn't enforced by a constraint at all — it's enforced by **cardinality**. A row has one `equipped_soldier_id`. There is no representation of the illegal state. That is the strongest form of the guarantee available.

The other four requirements then fall out as declarative constraints (b)–(e) above. Full illegal-state coverage:

| Illegal state | Blocked by |
|---|---|
| Item equipped on two soldiers | Single-valued column — unrepresentable |
| Item equipped on a soldier *and* the hero | CHECK (a) |
| Horse in a weapon slot | Composite FK (b): `slot` must match the definition's slot |
| Two weapons on one soldier | Partial unique (d) |
| Two horses on the hero | Partial unique (e) |
| Equipping another player's item | Composite FK (c) on `(soldier_id, player_id)` |
| Deleting a soldier orphaning equipped items | `ON DELETE SET NULL (equipped_soldier_id)` (c) |

**Rejected alternative for the hero:** give every player a synthetic row in `soldiers` with `type='hero'`. That collapses hero and soldiers into one code path and one unique index, and the battle engine would like it. Rejected because the hero's stats come from level and allocated stat points, not from `(type, tier)`; every roster query, every slot-purchase price calc and every recruit path would need `WHERE type <> 'hero'`, and the `soldiers_slot_fk` to a purchased slot would need a fake slot row. The boolean costs one byte and one extra partial index.

**Note on `is_equipped`:** it exists as a STORED generated column because the client payload wants it, but the partial index predicates are written out longhand (`equipped_on_hero = false AND equipped_soldier_id IS NULL`) rather than `WHERE NOT is_equipped`. Queries must use the identical longhand predicate for the planner to match the partial index. Put that predicate in exactly one sqlc query and never hand-write it again.

### Row count and size at 100k players — and why NOT to partition

Row width: 4×8-byte + 4×4-byte + 3×4-byte enums + 3 bools = 63 bytes payload → 64 aligned + 24 header ≈ **88 bytes/row**.

| Scenario | Items/player | Rows | Heap | Indexes (4) | Total |
|---|---|---|---|---|---|
| Realistic (100k registered, ~30k DAU) | ~70 | 7.0 M | 620 MB | ~460 MB | **1.1 GB** |
| Cap-saturated (every player at 150) | 150 | 15.0 M | 1.3 GB | ~1.0 GB | **2.3 GB** |
| Cap raised to 400, all saturated | 400 | 40.0 M | 3.5 GB | ~2.7 GB | **6.2 GB** |

**Decision: a single unpartitioned `player_items` table.** Reasons, in order of weight:
1. Every query is `WHERE player_id = $1`. That is a two-or-three-level B-tree descent. Hash partitioning by `player_id` makes it *identical* — the planner prunes to one partition and does the same descent. Zero gain on the hot path.
2. Partitioning forces `player_id` into every unique index and into the PK. That breaks the `(equipped_soldier_id, slot)` partial unique (it would have to become `(player_id, equipped_soldier_id, slot)` — still correct, but the composite FK from other tables gets uglier) and adds 8 bytes to every index entry.
3. At 2.3 GB the working set is comfortably cacheable on a 2 CU Neon compute (8 GB) plus Neon's local file cache.

**The documented trigger to revisit:** row count > 100 M, or the `player_items_free_idx` no longer fitting in the compute's cache. At that point convert to `PARTITION BY HASH (player_id)` with 32 partitions, PK becomes `(player_id, id)`, and the partial uniques gain a leading `player_id`. Write the migration now, run it never (hopefully).

**The real lever is the inventory cap, not partitioning.** `players.inventory_cap` (default 150, expandable with diamonds) is what actually bounds this table. Selling an item is a hard `DELETE`, never a soft delete — a `deleted_at` column would make this the biggest table in the database for no operational benefit. The forensic record of a sale is the ledger row, which carries `{def_id, tier, attack, defense}` in its `meta`.

## 00009 — Shop state

The shop refreshes every 5 minutes for every player. Storing 6 offer rows per player and rewriting them on each epoch is **600k rows rewritten 288×/day = 173 M writes/day**. Do not do that.

**Shop offers are derived, not stored.**

```
epoch      = floor(unix_seconds / cfg.shop.refresh_seconds)
seed       = SipHash-2-4(key = SHOP_SECRET, msg = player_id ‖ epoch ‖ reroll_index)
slot_seed  = seed XOR (slot_index * 0x9E3779B97F4A7C15)
offer[i]   = roll(slot_seed, cfg.shop.slot_type_weights,
                  cfg.shop.slot_tier_weights_by_level[player.level],
                  live content_item_defs for that slot)
```

`SHOP_SECRET` lives in the server environment, **not in the database**, so a database dump does not let anyone predict rolls. Storage is zero, write amplification is zero, and it is *fully auditable*: an admin endpoint `GET /admin/players/:id/shop?epoch=…&reroll=…&config_version=…` recomputes exactly what the player saw.

The only state that must persist is what they already did with it:

```sql
CREATE TABLE player_shop_state (
    player_id       bigint PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
    epoch           bigint   NOT NULL,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    purchased_mask  integer  NOT NULL DEFAULT 0 CHECK (purchased_mask >= 0),  -- bit per slot
    reroll_index    smallint NOT NULL DEFAULT 0 CHECK (reroll_index >= 0),
    rerolls_used    smallint NOT NULL DEFAULT 0 CHECK (rerolls_used >= 0)
) WITH (fillfactor = 70);
```
One row per player, updated only on a purchase or reroll. Reading the shop is a *pure function* plus one PK lookup.

**Anti-tamper purchase.** The client sends `{epoch, reroll_index, slot_index, def_id, tier, price, config_version}`. The server re-derives the offer and requires an exact match on `(def_id, tier, price)`, checks the slot's bit in `purchased_mask` is clear, and checks `config_version` is active-or-in-grace. Any mismatch → `409`. The client cannot invent an offer, and a stale client cannot buy at a stale price.

**The one wrinkle:** publishing a config that changes roll weights reshuffles every open shop mid-epoch. Bounded to a ≤5-minute window and cosmetically harmless; the `config_version` check on purchase prevents any economic exploit. If the owner finds even that unacceptable, gate config activation to epoch boundaries.

## 00010 — Kingdoms

```sql
CREATE TABLE kingdoms (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    founder_id    bigint REFERENCES players(id) ON DELETE SET NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    disbanded_at  timestamptz,
    reputation    bigint  NOT NULL DEFAULT 0 CHECK (reputation >= 0),
    treasury_gold bigint  NOT NULL DEFAULT 0 CHECK (treasury_gold >= 0),
    level         integer NOT NULL DEFAULT 1 CHECK (level >= 1),
    member_count  integer NOT NULL DEFAULT 0 CHECK (member_count >= 0),
    member_cap    integer NOT NULL DEFAULT 20 CHECK (member_cap > 0),
    name          citext  NOT NULL UNIQUE CHECK (length(name) BETWEEN 3 AND 24),
    tag           citext  NOT NULL UNIQUE CHECK (length(tag)  BETWEEN 2 AND 5),
    description   text    NOT NULL DEFAULT '',
    join_policy   text    NOT NULL DEFAULT 'invite_only'
                          CHECK (join_policy IN ('invite_only','open','apply')),
    state         text    NOT NULL DEFAULT 'active'
                          CHECK (state IN ('active','disbanded')),
    banner        jsonb   NOT NULL DEFAULT '{}'
) WITH (fillfactor = 85);

CREATE INDEX kingdoms_rep_idx       ON kingdoms (reputation DESC) WHERE state = 'active';
CREATE INDEX kingdoms_name_trgm_idx ON kingdoms USING gin (name gin_trgm_ops);
CREATE INDEX kingdoms_open_idx      ON kingdoms (member_count) WHERE state='active' AND join_policy='open';

-- Resolve the players <-> kingdoms cycle here.
ALTER TABLE players
    ADD CONSTRAINT players_kingdom_fk
    FOREIGN KEY (kingdom_id) REFERENCES kingdoms(id) ON DELETE SET NULL;

CREATE TABLE kingdom_upgrade_levels (
    kingdom_id bigint   NOT NULL REFERENCES kingdoms(id) ON DELETE CASCADE,
    upgrade_id smallint NOT NULL REFERENCES content_kingdom_upgrades(id),
    level      integer  NOT NULL DEFAULT 0 CHECK (level >= 0),
    gold_spent bigint   NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (kingdom_id, upgrade_id)
);

CREATE TABLE kingdom_donations (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    kingdom_id  bigint NOT NULL,
    player_id   bigint NOT NULL,
    amount_gold bigint NOT NULL CHECK (amount_gold > 0),
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE INDEX kingdom_donations_kingdom_idx ON kingdom_donations (kingdom_id, created_at DESC);
CREATE INDEX kingdom_donations_player_idx  ON kingdom_donations (player_id,  created_at DESC);

CREATE TABLE kingdom_invites (
    kingdom_id  bigint NOT NULL REFERENCES kingdoms(id) ON DELETE CASCADE,
    player_id   bigint NOT NULL REFERENCES players(id)  ON DELETE CASCADE,
    invited_by  bigint REFERENCES players(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    responded_at timestamptz,
    status      text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','accepted','declined','expired','cancelled')),
    direction   text NOT NULL DEFAULT 'invite' CHECK (direction IN ('invite','application')),
    PRIMARY KEY (kingdom_id, player_id)
);
CREATE INDEX kingdom_invites_player_idx  ON kingdom_invites (player_id)  WHERE status = 'pending';
CREATE INDEX kingdom_invites_kingdom_idx ON kingdom_invites (kingdom_id) WHERE status = 'pending';

-- Membership history. This is what a kingdom_members join table would have been for.
CREATE TABLE kingdom_member_events (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kingdom_id bigint NOT NULL REFERENCES kingdoms(id) ON DELETE CASCADE,
    player_id  bigint NOT NULL REFERENCES players(id)  ON DELETE CASCADE,
    event      text   NOT NULL CHECK (event IN ('join','leave','kick','promote','demote','found','disband')),
    actor_id   bigint REFERENCES players(id) ON DELETE SET NULL,
    old_role   kingdom_role,
    new_role   kingdom_role,
    at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX kingdom_member_events_kingdom_idx ON kingdom_member_events (kingdom_id, at DESC);
CREATE INDEX kingdom_member_events_player_idx  ON kingdom_member_events (player_id,  at DESC);
```

`member_count` is denormalised for the kingdom browser; it is maintained in the same transaction as the membership change. Nightly invariant check:
```sql
SELECT k.id, k.member_count, count(p.id)
FROM kingdoms k LEFT JOIN players p ON p.kingdom_id = k.id
WHERE k.state='active' GROUP BY k.id, k.member_count
HAVING k.member_count <> count(p.id);
```
Must return zero rows; alert if not.

**Reputation** is a direct `UPDATE kingdoms SET reputation = reputation + $1`. At 20 members × 20 attacks/day that is ~400 updates/day/kingdom — no lock contention at all. If member caps ever go to 100+ and attack rates rise, switch to a `kingdom_reputation_deltas` insert-only table aggregated every 5 min by the leaderboard job. Documented, not built.

## 00011 — Battles, replays, shields

```sql
CREATE TABLE battles (
    id                  bigint GENERATED ALWAYS AS IDENTITY,
    created_at          timestamptz NOT NULL DEFAULT now(),
    attacker_id         bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    defender_id         bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    attacker_kingdom_id bigint,
    defender_kingdom_id bigint,
    attacker_power      bigint NOT NULL,
    defender_power      bigint NOT NULL,
    gold_stolen         bigint NOT NULL DEFAULT 0 CHECK (gold_stolen >= 0),
    xp_gained           bigint NOT NULL DEFAULT 0,
    rng_seed            bigint NOT NULL,
    config_version      integer  NOT NULL REFERENCES config_versions(id),
    rep_gained          integer  NOT NULL DEFAULT 0,
    energy_cost         integer  NOT NULL,
    rounds              smallint NOT NULL,
    outcome             battle_outcome NOT NULL,
    PRIMARY KEY (id, created_at),
    CONSTRAINT battles_not_self_ck CHECK (attacker_id <> defender_id)
) PARTITION BY RANGE (created_at);

CREATE INDEX battles_attacker_idx ON battles (attacker_id, created_at DESC);
CREATE INDEX battles_defender_idx ON battles (defender_id, created_at DESC);
CREATE INDEX battles_kingdom_idx  ON battles (attacker_kingdom_id, created_at DESC)
    WHERE attacker_kingdom_id IS NOT NULL;

-- Replay inputs only. NOT the round-by-round log.
CREATE TABLE battle_replays (
    battle_id  bigint NOT NULL,
    created_at timestamptz NOT NULL,
    format     smallint NOT NULL DEFAULT 1,   -- encoding version
    attacker   bytea NOT NULL,                -- varint-packed unit stat array
    defender   bytea NOT NULL,
    PRIMARY KEY (battle_id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE shield_grants (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id     bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    battle_id     bigint,
    granted_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,
    diamonds_paid bigint NOT NULL DEFAULT 0 CHECK (diamonds_paid >= 0),
    source        text NOT NULL CHECK (source IN ('defense_loss','purchase','admin','new_player'))
);
CREATE INDEX shield_grants_player_idx ON shield_grants (player_id, granted_at DESC);
```

**Replay design.** Shakes-&-Fidget combat is deterministic given `(rng_seed, attacker army, defender army, combat config)`. So store *inputs*, never the round log — the round log is 10–50× larger and fully re-derivable. The client fetches the replay and re-simulates locally to animate the fight. Volume math at 100k DAU × 15 attacks:

| Storage choice | Bytes/battle | Per day | 7 days |
|---|---|---|---|
| Round-by-round JSON log | ~12 KB | 18 GB | 126 GB — impossible |
| Two JSONB army snapshots | ~2.5 KB | 3.7 GB | 26 GB — too expensive |
| **Varint-packed `bytea` snapshots** | **~700 B** | **1.0 GB** | **7 GB — acceptable** |

Snapshot encoding v1 (per side): `level(varint) hero_atk hero_def n_soldiers [tier(u8) atk(varint) def(varint) def_id(varint)]×n`. ~40 bytes/unit, ≤ 13 units.

`battle_replays` is partitioned **daily with 7-day retention via `DROP TABLE`**. Nulling out a column instead would generate 1.5 M dead tuples/day and enormous vacuum + WAL load; dropping a partition is instant and produces no garbage. This is the single best use of partitioning in the schema.

`battles` (summary, no blobs, ~110 B/row) is partitioned **weekly with 13-week retention**, then rolled up into `battle_stats_monthly` before the partition drops.

**Hard requirement on the transaction:** an attack locks two player rows. Two players attacking each other simultaneously will deadlock unless lock order is fixed.
```sql
-- ALWAYS. In every code path that touches two players.
SELECT id, gold, energy_current, shield_until, total_power
FROM players WHERE id = ANY($1::bigint[]) ORDER BY id FOR NO KEY UPDATE;
```
`FOR NO KEY UPDATE` rather than `FOR UPDATE`, because many tables carry FKs to `players` and a plain `FOR UPDATE` blocks their FK validation checks unnecessarily.

## 00012 — The ledger

The brief says "every gold/diamond/energy change should be auditable" and asks how to stop it becoming the biggest table. Three decisions do that.

### Decision 1 — energy is not ledgered

Ledgering energy would add a third of the volume for a resource that has no real-money value, regenerates for free, and is fully reconstructible. Energy remains auditable without a ledger:
- `players.energy_current` + `energy_updated_at` fix the regeneration curve exactly.
- Every spend is recorded with its `energy_cost` in `collect_events` (aggregated) or `battles` (exact).

You can replay a player's entire energy history from those two sources. That is auditability; a row per point of energy is bookkeeping theatre.

### Decision 2 — two ledgers, because retention differs by 100×

```sql
CREATE TABLE gold_ledger (
    player_id     bigint      NOT NULL,
    seq           bigint      NOT NULL,        -- players.gold_seq, monotonic per player
    created_at    timestamptz NOT NULL DEFAULT now(),
    delta         bigint      NOT NULL,
    balance_after bigint      NOT NULL CHECK (balance_after >= 0),
    ref_id        bigint,                      -- battle id / iap id / item id / kingdom id
    reason_id     smallint    NOT NULL REFERENCES ledger_reasons(id),
    meta          jsonb,                       -- usually NULL; item snapshot on a sale
    PRIMARY KEY (player_id, seq, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE diamond_ledger (
    player_id     bigint      NOT NULL,
    seq           bigint      NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    delta         bigint      NOT NULL,
    balance_after bigint      NOT NULL CHECK (balance_after >= 0),
    ref_id        bigint,
    reason_id     smallint    NOT NULL REFERENCES ledger_reasons(id),
    meta          jsonb,
    PRIMARY KEY (player_id, seq, created_at)
) PARTITION BY RANGE (created_at);

-- Rollup destination before gold partitions are dropped.
CREATE TABLE gold_flow_monthly (
    player_id   bigint   NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    month       date     NOT NULL,
    reason_id   smallint NOT NULL REFERENCES ledger_reasons(id),
    delta_sum   bigint   NOT NULL,
    entry_count integer  NOT NULL,
    PRIMARY KEY (player_id, month, reason_id)
);
```

| | `gold_ledger` | `diamond_ledger` |
|---|---|---|
| Partition interval | **weekly** | **yearly** |
| Retention | **6 weeks (~42 days)**, then rollup + `DROP` | **indefinite (≥7 years)** |
| Volume @100k DAU | ~4.5 M rows/day, ~400 MB/day | ~50 k rows/day, ~5 MB/day |
| Why | soft currency, support window is ~30 days | real money — refunds, chargebacks, tax, dispute evidence |

Weekly, not daily, partitions for gold: "my last 50 transactions" without a date bound would otherwise touch 42 partitions (42 index descents). Weekly makes it 6.

`seq` is `players.gold_seq` incremented in the same transaction as the balance change. It gives total ordering per player, makes duplicate detection trivial, and makes `balance_after` a self-verifying chain — a reconciliation job can walk a player's ledger and assert `balance_after[n] = balance_after[n-1] + delta[n]` and that the final value equals `players.gold`.

**`players.gold` is authoritative; the ledger is the audit trail.** Do not event-source the balance. Summing 4.5 M rows to answer "how much gold do I have" is not a thing a game server can do 200 times per second.

### Decision 3 — synchronous for transactions, aggregated for grind

This is what actually keeps the table small.

| Class | Examples | Written | Rows/day/player |
|---|---|---|---|
| **Material transaction** | shop buy, item sell, recruit, slot purchase, upgrade, battle steal in/out, kingdom donation, IAP grant, admin adjustment, shield purchase | **Synchronously, same transaction as the balance change** | ~35 |
| **Grind income** | collect gold, offline tax | **Buffered in the Go process, flushed hourly / on logout / on shutdown as one aggregate row per (player, hour, reason)** | ~4 |

Without the aggregation a player generates ~200 collect ledger rows/day and the gold ledger is 20 M rows/day at 100k DAU. With it, ~39. The player's actual *gold balance* is still updated with full ACID guarantees on every collect — only the audit row is aggregated. A hard crash loses at most one hour of grind-income *audit granularity*, never any gold; the reconciliation job detects the gap as drift between the ledger chain and `players.gold` and writes a single `reconciliation` correction row.

Alongside it, the analytics aggregate:

```sql
CREATE TABLE collect_events (
    player_id   bigint      NOT NULL,
    hour_bucket timestamptz NOT NULL,          -- date_trunc('hour', ...)
    job_id      smallint    NOT NULL REFERENCES content_collect_jobs(id),
    collects    integer NOT NULL DEFAULT 0,
    gold        bigint  NOT NULL DEFAULT 0,
    xp          bigint  NOT NULL DEFAULT 0,
    energy      integer NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, hour_bucket, job_id)
) PARTITION BY RANGE (hour_bucket);
```
Same buffered flush, `ON CONFLICT (player_id, hour_bucket, job_id) DO UPDATE SET collects = collect_events.collects + EXCLUDED.collects, …`. Weekly partitions, 6-week retention.

### Retention job (runs hourly, Go, advisory-locked)

```
for each partitioned parent:
    ensure the next `PreCreate` partitions exist  (CREATE TABLE ... PARTITION OF ... FOR VALUES FROM ... TO ...)
    for partitions older than `Retain`:
        if parent == gold_ledger: INSERT INTO gold_flow_monthly SELECT ... GROUP BY player_id, month, reason_id
        DROP TABLE <partition>
    assert the DEFAULT partition is empty; page if not
```

| Parent | Interval | Pre-create | Retain | Rollup before drop |
|---|---|---|---|---|
| `gold_ledger` | week | 4 | 6 | `gold_flow_monthly` |
| `diamond_ledger` | year | 2 | ∞ | — |
| `battles` | week | 4 | 13 | `battle_stats_monthly` |
| `battle_replays` | day | 3 | 7 | — |
| `collect_events` | week | 4 | 6 | `gold_flow_monthly` |
| `kingdom_donations` | month | 2 | 12 | — |
| `admin_audit_log` | month | 2 | ∞ | — |

Each parent gets a `DEFAULT` partition as a data-loss safety net, and the job alerts loudly if any default partition is ever non-empty (it means partition pre-creation failed silently).

## 00013 — Leaderboards

```sql
CREATE TABLE leaderboard_boards (
    id      smallint PRIMARY KEY,
    code    text NOT NULL UNIQUE,      -- 'player_power' | 'player_gold' | 'kingdom_reputation'
    subject text NOT NULL CHECK (subject IN ('player','kingdom')),
    top_n   integer NOT NULL DEFAULT 200
);

CREATE TABLE leaderboard_generations (
    board_id      smallint NOT NULL REFERENCES leaderboard_boards(id),
    generation    integer  NOT NULL,
    built_at      timestamptz NOT NULL DEFAULT now(),
    build_ms      integer  NOT NULL,
    subject_count bigint   NOT NULL,
    PRIMARY KEY (board_id, generation)
);

CREATE TABLE leaderboard_entries (
    board_id   smallint NOT NULL,
    generation integer  NOT NULL,
    rank       integer  NOT NULL,
    subject_id bigint   NOT NULL,
    score      bigint   NOT NULL,
    payload    jsonb    NOT NULL,   -- name, level, avatar, kingdom tag — FROZEN at build
    PRIMARY KEY (board_id, generation, rank),
    FOREIGN KEY (board_id, generation)
        REFERENCES leaderboard_generations (board_id, generation) ON DELETE CASCADE
);
CREATE INDEX leaderboard_entries_subject_idx ON leaderboard_entries (board_id, generation, subject_id);

CREATE TABLE leaderboard_active (
    board_id   smallint PRIMARY KEY REFERENCES leaderboard_boards(id),
    generation integer NOT NULL,
    FOREIGN KEY (board_id, generation)
        REFERENCES leaderboard_generations (board_id, generation)
);

-- Scale-out escape hatch for O(1) "your rank"; not populated at launch.
CREATE TABLE leaderboard_buckets (
    board_id    smallint NOT NULL,
    generation  integer  NOT NULL,
    bucket_no   integer  NOT NULL,
    score_floor bigint   NOT NULL,
    count_above bigint   NOT NULL,   -- subjects strictly above score_floor
    PRIMARY KEY (board_id, generation, bucket_no)
);
CREATE INDEX leaderboard_buckets_score_idx
    ON leaderboard_buckets (board_id, generation, score_floor DESC);
```

**Chosen: a periodically-refreshed snapshot *table*, refreshed every 5 minutes by the Go server.**

Rejected — **materialized view**: `REFRESH MATERIALIZED VIEW` takes `ACCESS EXCLUSIVE` (blocks all readers); `CONCURRENTLY` avoids that but requires a unique index, does a full old-vs-new diff, and is slower. Neither variant lets you *store the rank as a column*, which is the whole point. And you cannot control the transaction, so you cannot atomically swap three related boards.

Rejected — **Redis sorted sets**: genuinely O(log N) and sub-millisecond, but adds a second stateful service, a second persistence story, a cold-start rebuild after every restart, and a sync problem against the Postgres source of truth. At 100k players that buys ~3 ms on a screen players open a few times a day. Revisit at ~1 M players, or when you add real-time seasonal ladders.

Chosen mechanism: **generation-swap.** The job writes generation `N+1` (a fresh set of rows, no contention with readers), then `UPDATE leaderboard_active SET generation = N+1`. Readers on generation `N` finish undisturbed; a janitor drops `N-1`. No locks, no blocking, atomic.

`payload` is frozen at build time, so the top-100 read is **one index range scan and zero joins**:
```sql
SELECT rank, subject_id, score, payload
FROM leaderboard_entries
WHERE board_id = $1
  AND generation = (SELECT generation FROM leaderboard_active WHERE board_id = $1)
ORDER BY rank LIMIT 100;
```

**"Your rank" at launch — exact index-only count:**
```sql
SELECT count(*) + 1 FROM players
WHERE state = 'active' AND total_power > $1;   -- players_matchmaking_idx, index-only
```
At 100k players a mid-table player scans ~50k index tuples ≈ **2–5 ms**. Cache the result in the Go process for 60 s per player. That is entirely adequate and needs no extra infrastructure.

**"Your rank" at scale — the bucket table.** When the exact count exceeds ~20 ms, the 5-minute job additionally writes 1000 bucket rows per board. Then:
```sql
WITH b AS (
  SELECT count_above, score_floor FROM leaderboard_buckets
  WHERE board_id=$1 AND generation=$2 AND score_floor <= $3
  ORDER BY score_floor DESC LIMIT 1)
SELECT b.count_above + 1
     + (SELECT count(*) FROM players
        WHERE state='active' AND total_power > $3 AND total_power >= b.score_floor)
FROM b;
```
One index lookup plus ~100 index tuples. O(log N)-ish, still no Redis.

**Board-specific notes:**
- `player_power` — reads `players.total_power`, which is already indexed. Recomputes any player whose `power_config_version` is stale while it scans (see §5).
- `player_gold` — **deliberately has no index on `players.gold`.** The job seq-scans 100k rows and sorts: ~40 ms every 5 minutes. Cheaper than paying index maintenance on every collect for every player forever.
- `kingdom_reputation` — only ~5k rows; `kingdoms_rep_idx` serves both top-N and rank directly, but it goes through the same snapshot machinery so the client has one code path.

## 00014 — IAP

```sql
CREATE TABLE iap_transactions (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id               bigint NOT NULL REFERENCES players(id) ON DELETE RESTRICT,
    purchase_date           timestamptz NOT NULL,
    created_at              timestamptz NOT NULL DEFAULT now(),
    verified_at             timestamptz,
    granted_at              timestamptz,
    refunded_at             timestamptz,
    diamonds_granted        bigint NOT NULL DEFAULT 0 CHECK (diamonds_granted >= 0),
    price_micros            bigint,
    app_account_token       uuid,           -- StoreKit 2: binds the purchase to a player
    product_id              smallint NOT NULL REFERENCES content_iap_products(id),
    platform                iap_platform NOT NULL,
    transaction_id          text NOT NULL,
    original_transaction_id text,
    currency_code           text,
    country_code            text,
    environment             text NOT NULL CHECK (environment IN ('production','sandbox')),
    status                  text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','verified','granted','failed','refunded','revoked')),
    signed_payload          text,           -- Apple JWS / Google purchase token payload
    failure_reason          text,

    -- THE anti-replay constraint. A receipt can grant diamonds exactly once, ever.
    CONSTRAINT iap_transactions_uq UNIQUE (platform, transaction_id)
);
CREATE INDEX iap_tx_player_idx   ON iap_transactions (player_id, created_at DESC);
CREATE INDEX iap_tx_original_idx ON iap_transactions (platform, original_transaction_id)
    WHERE original_transaction_id IS NOT NULL;
CREATE INDEX iap_tx_token_idx    ON iap_transactions (app_account_token)
    WHERE app_account_token IS NOT NULL;
CREATE INDEX iap_tx_pending_idx  ON iap_transactions (created_at) WHERE status IN ('pending','verified');

CREATE TABLE iap_server_notifications (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    platform          iap_platform NOT NULL,
    notification_uuid text NOT NULL,
    notification_type text NOT NULL,     -- CONSUMPTION_REQUEST, REFUND, REVOKE, ...
    subtype           text,
    signed_payload    text NOT NULL,
    transaction_id    text,
    received_at       timestamptz NOT NULL DEFAULT now(),
    processed_at      timestamptz,
    process_error     text,
    CONSTRAINT iap_notifications_uq UNIQUE (platform, notification_uuid)
);
CREATE INDEX iap_notif_unprocessed_idx ON iap_server_notifications (received_at)
    WHERE processed_at IS NULL;
```

`app_account_token` is the UUID the Godot client passes to StoreKit at purchase time (set it to a per-player UUID stored alongside `player_code`). Apple echoes it in every signed transaction and in App Store Server Notifications V2 — it is the only reliable way to attribute an out-of-band refund notification back to a player. `original_transaction_id` is Apple's stable per-user handle and is what the Consumption Request flow keys on. Both indexed.

Grant flow, one transaction: insert `iap_transactions` (unique constraint = idempotency), verify the JWS signature against Apple's root certs, `UPDATE players SET diamonds = diamonds + $1`, insert `diamond_ledger`, set `status='granted'`. `ON DELETE RESTRICT` on `player_id` so an account deletion cannot silently erase purchase history — deletion anonymises the player row instead.

## 00015 — Moderation, ops, idempotency

```sql
CREATE TABLE moderation_reports (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reporter_id       bigint REFERENCES players(id) ON DELETE SET NULL,
    target_player_id  bigint REFERENCES players(id)  ON DELETE CASCADE,
    target_kingdom_id bigint REFERENCES kingdoms(id) ON DELETE CASCADE,
    handled_by        bigint REFERENCES admin_users(id) ON DELETE SET NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    handled_at        timestamptz,
    target_kind       text NOT NULL CHECK (target_kind IN ('player','kingdom')),
    reason            text NOT NULL CHECK (reason IN ('name','chat','cheating','impersonation','other')),
    note              text NOT NULL DEFAULT '',
    status            text NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open','triaged','actioned','dismissed')),
    resolution        text,
    CONSTRAINT moderation_target_ck CHECK (
        (target_kind='player'  AND target_player_id  IS NOT NULL AND target_kingdom_id IS NULL) OR
        (target_kind='kingdom' AND target_kingdom_id IS NOT NULL AND target_player_id  IS NULL))
);
CREATE INDEX moderation_open_idx ON moderation_reports (created_at) WHERE status = 'open';
CREATE UNIQUE INDEX moderation_dedupe_uq ON moderation_reports (reporter_id, target_player_id)
    WHERE status = 'open' AND target_player_id IS NOT NULL;

CREATE TABLE player_sanctions (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id  bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    issued_by  bigint REFERENCES admin_users(id) ON DELETE SET NULL,
    lifted_by  bigint REFERENCES admin_users(id) ON DELETE SET NULL,
    report_id  bigint REFERENCES moderation_reports(id) ON DELETE SET NULL,
    issued_at  timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    lifted_at  timestamptz,
    kind       sanction_kind NOT NULL,
    reason     text NOT NULL
);
CREATE INDEX player_sanctions_active_idx ON player_sanctions (player_id) WHERE lifted_at IS NULL;

CREATE TABLE player_anomaly_flags (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id   bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    at          timestamptz NOT NULL DEFAULT now(),
    reviewed_at timestamptz,
    severity    smallint NOT NULL CHECK (severity BETWEEN 1 AND 5),
    rule        text  NOT NULL,   -- 'collect_rate','impossible_gold','seq_replay','device_share'
    detail      jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX player_anomaly_open_idx ON player_anomaly_flags (severity DESC, at DESC)
    WHERE reviewed_at IS NULL;

-- Scheduler bookkeeping for the in-process job runner.
CREATE TABLE job_runs (
    job_name   text PRIMARY KEY,
    last_start timestamptz,
    last_ok    timestamptz,
    last_error text,
    run_count  bigint NOT NULL DEFAULT 0,
    fail_count bigint NOT NULL DEFAULT 0
);

-- Idempotency for DIAMOND-SPEND endpoints only. See §7 for why this is tiny.
CREATE TABLE idempotency_keys (
    player_id   bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    request_id  uuid   NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    endpoint    text   NOT NULL,
    status_code smallint NOT NULL,
    response    jsonb  NOT NULL,
    PRIMARY KEY (player_id, request_id)
);
CREATE INDEX idempotency_keys_gc_idx ON idempotency_keys (created_at);
```

## 00016 — Mail

Needed for admin grants, offline rewards, and kingdom notices. Without it there is nowhere to put "an admin granted you 500 diamonds".

```sql
CREATE TABLE player_mail (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id    bigint NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    read_at      timestamptz,
    claimed_at   timestamptz,
    kind         text  NOT NULL CHECK (kind IN ('system','admin_grant','kingdom','battle','compensation')),
    subject_key  text  NOT NULL,           -- i18n key
    body_params  jsonb NOT NULL DEFAULT '{}',
    rewards      jsonb NOT NULL DEFAULT '[]',  -- [{"kind":"gold","amount":500}, {"kind":"item","def_id":12,"tier":"rare"}]
    sent_by      bigint REFERENCES admin_users(id) ON DELETE SET NULL
);
CREATE INDEX player_mail_inbox_idx ON player_mail (player_id, created_at DESC)
    WHERE claimed_at IS NULL AND expires_at > now();  -- see note
```
`now()` is not IMMUTABLE, so that predicate is illegal. Use instead:
```sql
CREATE INDEX player_mail_inbox_idx ON player_mail (player_id, created_at DESC) WHERE claimed_at IS NULL;
```
and filter `expires_at > now()` in the query. (Flagged explicitly because it is a classic trap.)

## 00017 — Roles and grants

```sql
-- Neon gives you neon_superuser on the owner role; create these under it.
CREATE ROLE emperors_app     LOGIN PASSWORD :'app_pw';      -- game server
CREATE ROLE emperors_admin   LOGIN PASSWORD :'admin_pw';    -- Next.js admin panel
CREATE ROLE emperors_migrate LOGIN PASSWORD :'migrate_pw';  -- goose only, DDL

GRANT USAGE ON SCHEMA public TO emperors_app, emperors_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO emperors_app;
GRANT USAGE                        ON ALL SEQUENCES   IN SCHEMA public TO emperors_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO emperors_admin;
GRANT USAGE                        ON ALL SEQUENCES   IN SCHEMA public TO emperors_admin;

-- The audit log is append-only at the database level, not just by convention.
REVOKE UPDATE, DELETE ON admin_audit_log FROM emperors_app, emperors_admin;

-- The game server must never publish config; only the admin panel may.
REVOKE INSERT, UPDATE, DELETE ON config_versions, config_documents, config_bundles,
                                  config_active,  config_publish_log
    FROM emperors_app;
GRANT SELECT ON config_versions, config_documents, config_bundles, config_active TO emperors_app;
```

---

# 3. Denormalised power — the full mechanism

**Materialised on `players`, maintained by application code inside the mutating transaction. No trigger.**

The decisive argument against a trigger: power depends on family-upgrade percentages, kingdom-upgrade percentages, tier stat multipliers and hero stat-point weights — **all of which live in versioned JSONB config interpreted by Go**. A PL/pgSQL trigger would have to re-implement the `Curve` evaluator and the effect-stacking rules in SQL, in a second language, and stay in sync with them forever. That is a guaranteed source of silent divergence between what the battle engine computes and what matchmaking sorts on.

Secondary arguments: a trigger firing on every `player_items` insert would re-sum the whole army per statement (an equip-all-6-soldiers batch becomes 18 full recomputations); and the control flow is invisible at the call site.

**One function, one call site rule:**
```go
// internal/game/derive.go
//
// Recomputes hero_power, army_power, total_power, tax_rate_mgps and the effective
// max-energy cache for one player under the supplied config snapshot, and writes
// them to the players row.
//
// MUST be called inside the same pgx.Tx as any mutation that can affect them:
//   equip / unequip / sell item, acquire auto-equipped item,
//   recruit / dismiss soldier, spend stat point, respec, level up,
//   buy family upgrade, buy kingdom upgrade, join / leave kingdom.
func RecomputeDerived(ctx context.Context, tx pgx.Tx, cfg *balance.Snapshot, playerID int64) error
```

It needs one round trip, not four — and this query doubles as the "load my entire game state" query for the home screen:

```sql
-- name: LoadPlayerAggregate :one
SELECT
  to_jsonb(p) AS player,
  COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'soldier', to_jsonb(s),
      'items', COALESCE((SELECT jsonb_agg(to_jsonb(i)) FROM player_items i
                          WHERE i.equipped_soldier_id = s.id), '[]'::jsonb)))
    FROM soldiers s WHERE s.player_id = p.id), '[]'::jsonb) AS army,
  COALESCE((SELECT jsonb_agg(to_jsonb(i)) FROM player_items i
            WHERE i.player_id = p.id AND i.equipped_on_hero), '[]'::jsonb) AS hero_items,
  COALESCE((SELECT jsonb_object_agg(fu.upgrade_id::text, fu.level)
            FROM player_family_upgrades fu WHERE fu.player_id = p.id), '{}'::jsonb) AS family,
  COALESCE((SELECT jsonb_object_agg(ku.upgrade_id::text, ku.level)
            FROM kingdom_upgrade_levels ku WHERE ku.kingdom_id = p.kingdom_id), '{}'::jsonb) AS kingdom
FROM players p
WHERE p.id = $1
FOR NO KEY UPDATE OF p;
```

The formula (all integer, milli-scaled multipliers):
```
hero_atk   = cfg.hero.base_attack + stat_attack  * cfg.hero.attack_per_point  + Σ hero_items.attack
hero_def   = cfg.hero.base_defense+ stat_defense * cfg.hero.defense_per_point + Σ hero_items.defense
hero_atk   = hero_atk * (1000 + Σ effects[hero_attack_pct]) / 1000        -- and likewise def
hero_power = (hero_atk * cfg.power.atk_weight_milli + hero_def * cfg.power.def_weight_milli) / 1000

per soldier s:
  atk = (s.base_attack  + Σ equipped.attack)  * (1000 + Σ effects[soldier_attack_pct])  / 1000
  def = (s.base_defense + Σ equipped.defense) * (1000 + Σ effects[soldier_defense_pct]) / 1000
  pow = (atk * atk_weight_milli + def * def_weight_milli) / 1000
army_power  = Σ pow
total_power = hero_power + army_power

tax_rate_mgps = cfg.tax.base_mgps
              * (1000 + Σ effects[tax_rate_pct]) / 1000
              + Σ soldiers * cfg.tax.per_soldier_mgps
```

**The safety net is `power_config_version`, not a trigger.** Every recompute stamps the config version used. A config publish therefore makes every player's power *detectably* stale rather than silently wrong. Two mechanisms clear it:

1. **Lazily** — on the player's next authenticated request. `LoadPlayerAggregate` already ran; if `power_config_version <> active`, recompute and write back. Effectively free.
2. **Eagerly** — the 5-minute leaderboard job already scans all active players; it recomputes stale ones in batches of 500 per transaction, rate-limited, spread over ~30 minutes.

No index is needed for finding stale players (an index on `power_config_version` would churn on every recompute); the leaderboard job's full scan finds them for free. The consequence — for a few minutes after a rebalance, matchmaking and the power ladder use slightly stale numbers — is acceptable and should be stated in the admin UI at publish time.

**Matchmaking query.** Do not use `ORDER BY random()`; pick a random pivot inside the band and walk the index both ways:
```sql
-- name: FindTargets :many
(SELECT id, display_name, level, total_power, kingdom_id, shield_until
   FROM players
  WHERE state = 'active' AND total_power >= $pivot
  ORDER BY total_power ASC, id ASC LIMIT 12)
UNION ALL
(SELECT id, display_name, level, total_power, kingdom_id, shield_until
   FROM players
  WHERE state = 'active' AND total_power <  $pivot
  ORDER BY total_power DESC, id DESC LIMIT 12);
```
Two index descents plus 24 heap fetches, ~1 ms warm. Go then filters out self, same-kingdom, live shields and same-target cooldown, shuffles, and returns 5. `$pivot` is drawn uniformly from `[my_power * (1 - band), my_power * (1 + band)]` with `band` from `cfg.pvp.matchmaking.power_band_pct_milli`. Seed the pool at launch with `is_bot = true` accounts so early players have targets.

---

# 4. Index catalogue — every hot path

| # | Query | Table | Index |
|---|---|---|---|
| 1 | Login by device / Apple / Google id | `player_identities` | `UNIQUE (provider, provider_uid)` |
| 2 | Refresh-token exchange | `sessions` | `UNIQUE (refresh_hash)` |
| 3 | Revoke all my sessions | `sessions` | `sessions_player_idx … WHERE revoked_at IS NULL` |
| 4 | Token-reuse detection | `sessions` | `sessions_family_idx (family_id)` |
| 5 | Expired-session GC | `sessions` | `sessions_expiry_idx (expires_at) WHERE revoked_at IS NULL` |
| 6 | Load whole game state | `players` | PK |
| 7 | Soldier roster | `soldiers` | `UNIQUE (player_id, slot_index)` |
| 8 | Whole equipped loadout | `player_items` | `player_items_equipped_idx (player_id) INCLUDE(...) WHERE equipped` |
| 9 | One soldier's 3 slots | `player_items` | `UNIQUE (equipped_soldier_id, slot) WHERE … NOT NULL` |
| 10 | Inventory page (free items) | `player_items` | `player_items_free_idx (player_id, slot, tier DESC, attack DESC, id DESC) WHERE free` |
| 11 | Inventory cap check | `player_items` | same partial index, `count(*)` |
| 12 | Equip / unequip / sell | `player_items` | PK + the two partial uniques |
| 13 | Collect action | `player_collect_progress` | PK `(player_id, job_id)` |
| 14 | Collect aggregate flush | `collect_events` | PK upsert `(player_id, hour_bucket, job_id)` |
| 15 | Family upgrade list / buy | `player_family_upgrades` | PK `(player_id, upgrade_id)` |
| 16 | Shop open / buy | `player_shop_state` | PK |
| 17 | **Matchmaking candidates** | `players` | `players_matchmaking_idx (total_power, id) WHERE state='active'` |
| 18 | **Own power rank** | `players` | same index, index-only `count(*)` |
| 19 | My attack log | `battles` | `(attacker_id, created_at DESC)` + partition pruning |
| 20 | Who attacked me | `battles` | `(defender_id, created_at DESC)` |
| 21 | Kingdom battle feed | `battles` | `(attacker_kingdom_id, created_at DESC) WHERE NOT NULL` |
| 22 | Fetch a replay | `battle_replays` | PK `(battle_id, created_at)` |
| 23 | Shield history | `shield_grants` | `(player_id, granted_at DESC)` |
| 24 | Kingdom roster | `players` | `players_kingdom_idx (kingdom_id, kingdom_role) WHERE NOT NULL` |
| 25 | Kingdom name search | `kingdoms` | `GIN (name gin_trgm_ops)` |
| 26 | Browse open kingdoms | `kingdoms` | `(member_count) WHERE state='active' AND join_policy='open'` |
| 27 | Kingdom rep rank | `kingdoms` | `(reputation DESC) WHERE state='active'` |
| 28 | My pending invites | `kingdom_invites` | `(player_id) WHERE status='pending'` |
| 29 | Kingdom's pending applications | `kingdom_invites` | `(kingdom_id) WHERE status='pending'` |
| 30 | Donation history | `kingdom_donations` | `(kingdom_id, created_at DESC)` |
| 31 | My gold history | `gold_ledger` | PK `(player_id, seq, created_at)` + pruning |
| 32 | My purchase history | `diamond_ledger` | PK |
| 33 | Leaderboard top-100 | `leaderboard_entries` | PK `(board_id, generation, rank)` |
| 34 | Am I on the board? | `leaderboard_entries` | `(board_id, generation, subject_id)` |
| 35 | Bucketed rank (scale-out) | `leaderboard_buckets` | `(board_id, generation, score_floor DESC)` |
| 36 | Config poll (every 10 s) | `config_active` | PK singleton |
| 37 | Config bundle by ETag | `config_bundles` | `UNIQUE (etag)` |
| 38 | **IAP replay guard** | `iap_transactions` | `UNIQUE (platform, transaction_id)` |
| 39 | Apple notification → player | `iap_transactions` | `(platform, original_transaction_id)`, `(app_account_token)` |
| 40 | Unprocessed notifications | `iap_server_notifications` | `(received_at) WHERE processed_at IS NULL` |
| 41 | Admin player search | `players` | `GIN (display_name gin_trgm_ops)`, `UNIQUE (player_code)` |
| 42 | Open moderation queue | `moderation_reports` | `(created_at) WHERE status='open'` |
| 43 | Active sanctions on login | `player_sanctions` | `(player_id) WHERE lifted_at IS NULL` |
| 44 | Admin audit by target | `admin_audit_log` | `(target_type, target_id, at DESC)` |
| 45 | Multi-account detection | `devices` | `(device_hash)` |
| 46 | Push-notification fan-out | `devices` | `(player_id) WHERE push_token IS NOT NULL` |
| 47 | Dormancy sweep (daily) | `players` | `players_dormancy_idx (last_seen_at) WHERE state='active'` |
| 48 | Unclaimed mail badge | `player_mail` | `(player_id, created_at DESC) WHERE claimed_at IS NULL` |
| 49 | Anomaly review queue | `player_anomaly_flags` | `(severity DESC, at DESC) WHERE reviewed_at IS NULL` |
| 50 | Diamond-spend idempotency | `idempotency_keys` | PK `(player_id, request_id)` |

**Indexes deliberately NOT created**, and why: `players.gold`, `players.xp`, `players.energy_current`, `players.action_seq` — all four change on every collect, and any index on them converts the game's highest-frequency write from a HOT update into an index-update storm. The gold leaderboard pays a 40 ms seq-scan every 5 minutes instead. That trade is not close.

---

# 5. Idempotency without a 25M-row/day table

The reflex answer is an `idempotency_keys` table keyed on a client-generated request UUID. At 100k DAU × ~250 mutating requests that is **25 M rows/day** — bigger than the ledger — plus the vacuum churn of deleting them daily.

**Chosen instead: a per-player monotonic action sequence, stored as one bigint column on `players`.**

- Client sends `X-Action-Seq: <last_known + 1>` on every mutating request.
- Server, inside the transaction that already locks the player row: accept only if `req_seq == players.action_seq + 1`, then increment.
- A network retry replays the same seq → `409 SEQ_MISMATCH`, body carries the authoritative player state, client reconciles and re-renders. The action is never applied twice.
- Cost: zero storage, zero GC, and it doubles as replay/reordering anti-cheat (a captured request cannot be replayed even once).
- Constraint accepted: one in-flight mutating request per player. For a single-player-session idle game that is the desired invariant anyway.

The small `idempotency_keys` table survives **only for diamond-spend endpoints** (energy refill, shop reroll, shield purchase) where returning a 409 instead of the cached success would be a support ticket about lost hard currency. That is ~5 rows/day per *spending* player — a few thousand rows/day, GC'd at 48 hours.

Real-money purchases need no key at all: `UNIQUE (platform, transaction_id)` on `iap_transactions` is a stronger idempotency guarantee than any client-generated UUID, because it is Apple's identifier.

---

# 6. Storage at scale

Per-row widths include the 24-byte tuple header and alignment padding.

### 100k registered / ~30k DAU (realistic launch year)

| Table | Rows | Heap | Indexes | Total |
|---|---|---|---|---|
| `players` | 100 k | 30 MB | 25 MB | 55 MB |
| `player_items` | 7.0 M | 620 MB | 460 MB | 1.1 GB |
| `soldiers` | 500 k | 40 MB | 30 MB | 70 MB |
| `player_soldier_slots` | 600 k | 25 MB | 20 MB | 45 MB |
| `player_collect_progress` | 800 k | 50 MB | 30 MB | 80 MB |
| `player_family_upgrades` | 600 k | 28 MB | 22 MB | 50 MB |
| `battles` (13 wk) | 41 M | 4.5 GB | 2.6 GB | 7.1 GB |
| `battle_replays` (7 d) | 3.2 M | 2.8 GB | 90 MB | 2.9 GB |
| `gold_ledger` (6 wk) | 57 M | 5.1 GB | 2.0 GB | 7.1 GB |
| `collect_events` (6 wk) | 13 M | 0.9 GB | 0.5 GB | 1.4 GB |
| `diamond_ledger` (∞) | 0.5 M/yr | 45 MB | 20 MB | 65 MB |
| everything else | — | ~200 MB | ~150 MB | 350 MB |
| **Total** | | | | **≈ 20 GB** |

### 100k DAU (stretch)

| Table | Rows | Total |
|---|---|---|
| `player_items` (cap-saturated at 150) | 15 M | 2.3 GB |
| `battles` (13 wk @ 1.5 M/day) | 137 M | 24 GB |
| `battle_replays` (7 d) | 10.5 M | 9.5 GB |
| `gold_ledger` (6 wk @ 4.5 M/day) | 189 M | 24 GB |
| `collect_events` (6 wk) | 42 M | 4.5 GB |
| everything else | | 1 GB |
| **Total** | | **≈ 65 GB** |

At the stretch figure, shorten `battles` retention to 6 weeks and `gold_ledger` to 4 weeks, which brings it back to ~40 GB. Compute: 2 CU is right for launch, 4 CU at 100k DAU.

---

# 7. Neon operations

### Endpoints

| Use | Endpoint | Why |
|---|---|---|
| Game server, admin panel | **pooled** (`…-pooler.eu-west-2.aws.neon.tech`) | Up to 10 000 client connections multiplexed |
| goose migrations, `psql`, `pg_dump`, seed | **direct** (no `-pooler`) | PgBouncer transaction mode supports neither session advisory locks nor `SET` |

### pgx configuration (verified, not guessed)

Neon's PgBouncer is ≥1.22, which **does support protocol-level prepared statements**. Keep pgx v5's default `QueryExecModeCacheStatement` — do *not* downgrade to `QueryExecModeSimpleProtocol` as older PgBouncer advice says. What is *not* supported and must be avoided in application code: SQL-level `PREPARE`/`DEALLOCATE`, `SET`/`RESET`, `LISTEN`/`NOTIFY`, `WITH HOLD` cursors, and **session-level advisory locks**.

```go
cfg, _ := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
cfg.MaxConns              = 30    // one VPS container; do not open 100 just because you can
cfg.MinConns              = 4     // keeps the Neon compute warm
cfg.MaxConnLifetime       = 30 * time.Minute  // lets PgBouncer rebalance
cfg.MaxConnIdleTime       = 5  * time.Minute
cfg.ConnConfig.ConnectTimeout = 10 * time.Second // MUST exceed the ~3s cold-start p99
```

### Autosuspend

Neon suspends a compute after 5 minutes idle by default; the cold start is ~1.8 s p50 / ~3.1 s p99. For a game server that is a user-visible stall on the first request after any quiet period. **Three mitigations, apply all three:**
1. Set autosuspend to **never** on the production branch. It costs money; a cold start on a paying player's first request costs more.
2. The config poll (`SELECT … FROM config_active` every 10 s) is a natural keep-alive and is already required by the design. Keep `MinConns >= 4`.
3. `ConnectTimeout = 10s` so that if a suspend does happen, the request is slow rather than failed.

Leave autosuspend **enabled** (5 min) on dev and preview branches — that is where the cost saving actually is.

### Latency — the finding that matters most operationally

Neon is in **eu-west-2 (AWS London)**. A request touches Postgres 3–8 times.

- **DigitalOcean LON1** → AWS London: ~1–3 ms RTT. 8 queries ≈ **8–24 ms** of network.
- **Hetzner Falkenstein/Nuremberg** → AWS London: ~15–25 ms RTT. 8 queries ≈ **120–200 ms** of network, *per request*, invisible in every profiler you'd point at the Go code.

**Recommendation: DigitalOcean LON1** (or Hetzner only if Neon is moved to `eu-central-1` Frankfurt). If Hetzner is non-negotiable for cost reasons, move the Neon project. This decision is worth more than every index in §4 combined, and it must be made before there is production data to migrate. It also reinforces the `LoadPlayerAggregate` single-round-trip pattern — with a 20 ms RTT, collapsing 5 queries into 1 saves 80 ms.

### Branching

| Branch | Purpose | Autosuspend | Created by |
|---|---|---|---|
| `main` (production) | live | never | — |
| `staging` | pre-release soak | 5 min | branched from `main`, `neon branches reset` weekly |
| `preview/pr-<n>` | per-PR CI | 5 min | GitHub Action on PR open, deleted on merge |
| `dev-<name>` | local development | 5 min | manual |

CI runs `goose up` against each preview branch's **direct** endpoint, then the seed command, then integration tests. Once there is real player data, `staging` and preview branches must be created as **schema-only** branches (GDPR — Neon is in the EU and this is a game with real-money purchases).

Watch Neon's **history retention** setting: branch churn plus daily partition drops generate a lot of WAL, and history retention is billed. 7 days on `main`, 1 day on preview branches.

### Not available on Neon (confirmed)

`pg_cron` (no background workers), `CREATE TABLESPACE`, superuser, `track_commit_timestamp`. Unlogged tables do not survive scale-to-zero, so never use one for game state. Everything the schema needs — declarative partitioning, materialized views, triggers, `citext`, `pg_trgm`, `pgcrypto`, `CREATE INDEX CONCURRENTLY` — is available.

### Scheduled jobs (the pg_cron replacement)

A singleton goroutine in the Go server, each job guarded by a **transaction-level** advisory lock, which *does* work through PgBouncer because it is released at commit:

```go
// pg_advisory_xact_lock — NOT pg_advisory_lock. Session locks are unavailable on the pooler.
if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, lockID); err != nil { … }
```

| Job | Interval | Lock id | Work |
|---|---|---|---|
| `config_poll` | 10 s | none (read-only) | reload bundle if `config_active.version_id` changed; keeps Neon warm |
| `leaderboard_refresh` | 5 min | 1001 | build generation N+1 for 3 boards, swap, drop N-1, recompute stale power |
| `partition_maintenance` | 1 h | 1002 | pre-create + rollup + drop per §"Retention job" |
| `ledger_flush` | 60 s | none (per-process buffer) | flush buffered collect/tax aggregates |
| `session_gc` | 1 h | 1003 | delete sessions past `expires_at + 7d`, idempotency keys past 48 h |
| `dormancy_sweep` | 24 h | 1004 | `state='active' → 'dormant'` where `last_seen_at < now() - 30d` |
| `invariant_check` | 24 h | 1005 | member_count drift, ledger-chain drift, soldiers-in-unpurchased-slots, orphaned equips |
| `iap_notification_worker` | 30 s | 1006 | process unprocessed Apple/Google notifications, claw back refunds |

Set `application_name` per job so `pg_stat_statements` attributes them. Enable `pg_stat_statements` and `auto_explain` (`log_min_duration = 200ms`) from day one.

---

# 8. Tier colour conflict — resolution proposal

The brief specifies `epic = purple` and `mystic = purple`. That is unshippable as stated: those are the 4th and 6th tiers of a seven-tier ladder, and players must distinguish them at a glance in a dense grid on a phone.

**Proposal (encoded in the `tiers` config section in §2, so the owner can change it in the admin panel in ten seconds without any deploy):**

| Tier | Colour | Hex | Glow | Frame |
|---|---|---|---|---|
| common | gray | `#9CA3AF` | none | plain |
| uncommon | green | `#22C55E` | none | plain |
| rare | blue | `#3B82F6` | soft | notched |
| **epic** | **violet** (flat) | `#8B5CF6` | soft | notched |
| legendary | gold | `#F59E0B` | strong | crown |
| **mystic** | **magenta** + animated sheen | `#E879F9` | animated gradient | arcane |
| special | red + gold outline | `#EF4444` | animated flame | royal |

Rationale: keeping *epic* purple preserves the genre convention players already have from every other RPG. *Mystic* sits above legendary, so it should read as "beyond gold" — a saturated magenta with an animated gradient reads as rarer than flat violet and is unmistakable next to it.

**Second, independent problem:** gray/green/blue/violet/gold/magenta/red is not distinguishable to a red-green colourblind player, and roughly 8% of a male-skewed audience is. The `frame` and `glow` fields exist for this: **every tier gets a distinct frame silhouette and a distinct corner glyph**, so tier is legible without colour at all. This costs nothing extra with the Gemini sheet workflow — one 2K sheet of 7 frames, grid-sliced. Do not ship colour as the only tier signal.

---

# 9. Seeding

```
seed/registry/*.json     -> L1 content rows, applied by goose 00004 as INSERT ... ON CONFLICT DO NOTHING
seed/config/v1/*.json    -> L2 config version 1, applied by cmd/emperors-seed (//go:embed)
```

`cmd/emperors-seed` is idempotent and safe to run on every deploy:
1. Upsert L1 registry rows from `seed/registry/`.
2. If a published config version already exists → exit 0 (no-op) unless `--force-new-version`.
3. Otherwise: create version, insert one `config_documents` row per section, run the full validation pipeline (schema + referential + simulation), compile the bundle, publish, log.
4. `--dry-run` prints the validation and simulation report without writing.

Every Neon branch (preview, staging, dev) gets the identical published config, so a bug reproduced on staging reproduces on production.

**Load-testing seed** (`cmd/emperors-seed --bots N`): generates N `is_bot = true` players with a realistic power distribution. Needed for two reasons — the PvP pool is empty on launch day, and you cannot validate the matchmaking index or the leaderboard job against 200 rows.

---

# 10. sqlc configuration

```yaml
version: "2"
sql:
  - engine: postgresql
    schema: db/migrations
    queries: db/queries
    gen:
      go:
        package: dbgen
        out: internal/db/dbgen
        sql_package: pgx/v5
        emit_pointers_for_null_types: true    # nullable enums/ints -> *T, so NULL is unambiguous
        emit_enum_valid_method: true
        emit_json_tags: false
        overrides:
          - db_type: "timestamptz"; go_type: "time.Time"
          - db_type: "timestamptz"; nullable: true; go_type: "*time.Time"
          - db_type: "jsonb";       go_type: "encoding/json.RawMessage"
```
`emit_pointers_for_null_types` matters here: `players.shield_until`, `kingdom_id` and `kingdom_role` are all nullable and all carry real game meaning when absent. Getting a zero value instead of a nil pointer for `shield_until` would make every player permanently shielded-since-the-epoch.

sqlc parses `db/migrations` directly, so partitioned tables and enums are picked up automatically. The generated enums give you `ItemTierMystic`, `SoldierTypeGladiator` etc. as real Go constants — use them in the roll and combat code rather than strings.

---

# 11. Implementation order

1. **00001–00004** + `cmd/emperors-seed` skeleton + the `balance.Curve` evaluator and `balance.Snapshot` loader. *Nothing else works until config loads.*
2. **00005** + auth (device identity → JWT + refresh rotation) + `LoadPlayerAggregate`. First end-to-end request.
3. **00006** + Collect + energy/tax lazy accrual + the buffered ledger flush. First playable loop.
4. **00012** ledgers, wired into everything from step 3 onward. Retrofitting a ledger is miserable.
5. **00007 + 00008** soldiers, slots, items, equipment + `RecomputeDerived`. The constraint set in 00008 is the highest-value part of the schema — write the negative tests (try to equip one item on two soldiers, a horse in a weapon slot, another player's item) before writing the happy path.
6. **00009** shop (derivation function + the seed-match purchase validation).
7. **00011** battles: the integer-only combat simulator in Go, then the *identical* simulator in GDScript, then a golden-file test that runs 10 000 seeded battles through both and asserts byte-identical outcomes. Do this before any battle animation work.
8. **00010** kingdoms.
9. **00013** leaderboards + the job runner + `partition_maintenance` (partitions from steps 4 and 7 need it before their first rollover).
10. **00014** IAP. **00002/00015/00016** admin panel, moderation, mail.

---

# Critical files for implementation

- `/Users/yigitkarabulut/Developer/Emperors/db/migrations/00003_config_system.sql` — the versioned config tables; every other design decision depends on this existing first.
- `/Users/yigitkarabulut/Developer/Emperors/db/migrations/00008_items_and_equipment.sql` — `player_items` plus the six constraints that make illegal equipment states unrepresentable.
- `/Users/yigitkarabulut/Developer/Emperors/db/migrations/00005_players_and_auth.sql` — the hottest row in the database, including `fillfactor = 80`, `total_power`, `power_config_version`, `action_seq` and the matchmaking index.
- `/Users/yigitkarabulut/Developer/Emperors/internal/balance/curve.go` — the `Curve` evaluator and closed effect enum; the exact boundary between "retune without a deploy" and "needs a deploy".
- `/Users/yigitkarabulut/Developer/Emperors/internal/game/derive.go` — `RecomputeDerived`, the single call site that maintains `total_power` and `tax_rate_mgps`; if this is ever called outside a mutating transaction the whole denormalisation strategy fails.


---

## Key decisions

- **Three-layer split: an append-only normalised content registry (identity + slug only) that player rows FK to, plus all balance numbers in immutable versioned JSONB config documents, plus normalised player state.**
  - Rejected: Everything in JSONB config blobs, or everything in normalised balance tables.
  - Why: Pure JSONB gives no FK protection — publishing a config that drops an item def would silently orphan millions of player_items rows. Pure normalised tables make 'publish' and 'rollback' a multi-table row restore instead of a single pointer flip. The split gives FK integrity where player data lives and atomic byte-identical rollback where designers work.
- **The equipped-on pointer lives on the ITEM row (equipped_soldier_id + equipped_on_hero), not as weapon/armor/horse columns on the soldier row.**
  - Rejected: Three nullable item-id columns on soldiers with a UNIQUE on each.
  - Why: Three independent uniques do not compose: nothing stops item #5000 sitting in soldier A's weapon column and soldier B's armor column. With the pointer on the item, 'one item, one holder' is enforced by cardinality — the illegal state has no representation at all. Slot correctness then comes from a composite FK on (def_id, slot), and same-owner from a composite FK on (soldier_id, player_id) with PG15+ ON DELETE SET NULL (equipped_soldier_id).
- **total_power is materialised on players and maintained by one Go function inside the mutating transaction; no trigger. power_config_version acts as the staleness detector.**
  - Rejected: A PL/pgSQL trigger on player_items / soldiers / upgrades.
  - Why: Power depends on family and kingdom upgrade percentages, tier multipliers and hero stat weights that all live in versioned JSONB config interpreted by Go. A trigger would have to reimplement the Curve evaluator in SQL and stay in sync forever, guaranteeing divergence between what the battle engine computes and what matchmaking sorts on. Stamping power_config_version makes a config publish render power detectably stale rather than silently wrong; the existing leaderboard scan clears it in batches.
- **Leaderboards are a generation-swapped snapshot TABLE refreshed every 5 minutes, plus an exact index-only count for 'your rank', with a 1000-row bucket table as the pre-designed scale-out.**
  - Rejected: Redis sorted sets, or a materialized view refreshed CONCURRENTLY.
  - Why: A materialized view cannot store rank as a queryable column and REFRESH either blocks readers or is slow; you also cannot atomically swap three related boards. Redis is genuinely faster but adds a second stateful service, a second persistence story and a cold-start rebuild to buy ~3ms on a screen opened a few times a day at 100k players. The snapshot table gives O(1) top-N with zero joins (payload frozen at build), and the exact rank count is 2-5ms at 100k, cached 60s per player.
- **Split the ledger by currency: gold_ledger partitioned weekly with 6-week retention and monthly rollup before DROP; diamond_ledger partitioned yearly and kept indefinitely. Energy is not ledgered at all.**
  - Rejected: One currency_ledger table covering gold, diamonds and energy with a uniform retention policy.
  - Why: Retention requirements differ by ~100x — gold's support window is 30 days, diamonds are real money needing 7 years for refunds and chargebacks. Ledgering energy would add a third of the volume for a free-regenerating resource that is fully reconstructible from energy_updated_at plus the energy_cost already recorded on collect_events and battles.
- **Material transactions are ledgered synchronously in the balance-change transaction; grind income (collect, tax) is buffered in-process and flushed hourly as one aggregate row.**
  - Rejected: One ledger row per collect action.
  - Why: A player performs ~200 collects/day. Ledgering each produces 20M rows/day at 100k DAU — larger than every other table combined. Aggregation cuts it to ~39 rows/day/player. Gold balance still updates with full ACID guarantees on every collect; only the audit granularity is aggregated, and the reconciliation job detects any crash-lost row as ledger-chain drift.
- **Shop offers are derived from SipHash(SHOP_SECRET, player_id ‖ epoch ‖ reroll_index), not stored. Only purchased_mask and reroll_index persist, in one row per player.**
  - Rejected: Storing 6 rolled offer rows per player and rewriting them every 5-minute epoch.
  - Why: Stored offers mean 600k rows rewritten 288 times a day = 173M writes/day of pure churn. Derivation costs zero storage and zero writes, is fully reproducible for support ('what was in my shop at 14:35?'), and keeping the secret out of the database means a DB dump does not let anyone predict rolls.
- **Per-player monotonic action_seq column on players for request idempotency, instead of an idempotency_keys table (kept only for diamond-spend endpoints).**
  - Rejected: A general idempotency_keys table keyed on a client-generated request UUID.
  - Why: At 100k DAU x ~250 mutating requests that table is 25M rows/day — bigger than the ledger — plus daily delete churn. A sequence column costs zero storage, doubles as replay/reordering anti-cheat, and the accepted constraint (one in-flight mutation per player) is the desired invariant for a single-session idle game anyway. Real-money purchases need no key at all: UNIQUE (platform, transaction_id) is a stronger guarantee.
- **player_items stays a single unpartitioned table; the inventory cap is the growth lever. Documented conversion to HASH(player_id) x32 only past ~100M rows.**
  - Rejected: Hash-partitioning player_items by player_id from day one.
  - Why: Every query is WHERE player_id = $1, a single B-tree descent that partitioning makes identical, not faster. Partitioning forces player_id into every unique index and the PK, complicating the equipment constraints. At the cap-saturated worst case (15M rows) it is 2.3GB total, comfortably cacheable on a 2 CU Neon compute.
- **Battle replays store only inputs (rng_seed, config_version, two varint-packed bytea army snapshots) in a daily-partitioned table with 7-day retention via DROP PARTITION; combat math is integer-only in both Go and GDScript.**
  - Rejected: Storing the round-by-round combat log, or nulling out old snapshot columns instead of dropping partitions.
  - Why: A round log is ~12KB vs ~700 bytes for packed inputs — 18GB/day vs 1GB/day at 100k DAU. Nulling columns generates 1.5M dead tuples/day of vacuum and WAL load; DROP TABLE on a partition is instant and produces no garbage. Integer-only math is mandatory because the client re-simulates from the seed and one float rounding difference desyncs every replay.
- **Kingdom membership is columns on players (kingdom_id, kingdom_role), with a separate kingdom_member_events audit table for history.**
  - Rejected: A kingdom_members join table with UNIQUE(player_id).
  - Why: A player is in at most one kingdom, so a single nullable column makes that rule structural with no unique index. The matchmaking covering path needs kingdom_id on the player row regardless, so a join table would create two sources of truth and a whole class of drift bugs. The audit table covers the only thing a join table was actually better at — history.
- **Item and soldier rolled stats are frozen on the row at acquisition, with rolled_config_version recorded for forensics.**
  - Rejected: Deriving stats live from the active config so rebalances apply retroactively.
  - Why: Live derivation means a rebalance silently nerfs items and soldiers players already paid for — the fastest way to lose a mid-core audience. Freezing also makes power computation cheap and stable. rolled_config_version lets an admin migration job deliberately re-roll a cohort with a full audit trail when a genuine balance bug ships.
- **Deploy the Go server on DigitalOcean LON1 rather than Hetzner, given Neon is pinned to eu-west-2 (AWS London).**
  - Rejected: Hetzner Falkenstein/Nuremberg with the existing Neon London project.
  - Why: Hetzner-to-AWS-London is ~15-25ms RTT versus ~1-3ms from DO LON1. At 3-8 queries per request that is 120-200ms of pure network per request, invisible in any Go profiler. If Hetzner is required for cost, move the Neon project to eu-central-1 instead. This must be decided before there is production data to migrate.
- **players carries fillfactor = 80 and gold, xp, energy_current and action_seq are deliberately left unindexed.**
  - Rejected: Indexing players.gold to serve the gold leaderboard directly.
  - Why: players is updated on every collect. With free page space Postgres does a HOT update with zero index maintenance; any index on a column that changes per-collect destroys that and turns the highest-frequency write in the game into an index-update storm. The gold leaderboard pays a 40ms seq-scan every 5 minutes instead.
- **goose handles DDL and L1 registry rows only; L2 config version 1 is seeded by a separate idempotent Go command from //go:embed JSON.**
  - Rejected: Seeding the initial balance as INSERT statements inside a goose migration.
  - Why: A 200KB JSON blob inside a .sql file is unreviewable in a PR and unrunnable per-environment. Embedded JSON diffs properly in git, runs the full validation and simulation pipeline before publishing, and applies identically to every Neon branch so a staging repro is a production repro.
- **Migrations run against the direct (unpooled) Neon endpoint; runtime uses the pooled endpoint with pgx v5's default QueryExecModeCacheStatement.**
  - Rejected: One connection string for everything, or downgrading pgx to simple protocol for PgBouncer compatibility.
  - Why: goose takes session-level advisory locks and issues SET, neither of which PgBouncer transaction mode supports. Conversely Neon's PgBouncer is >=1.22 and does support protocol-level prepared statements, so the common advice to downgrade pgx to simple protocol is obsolete and would cost real throughput. Scheduled jobs use pg_advisory_xact_lock (transaction-scoped) precisely because session locks are unavailable on the pooler.

## Risks flagged

- Combat determinism drift between the Go server and the GDScript client. The replay design stores only a seed and army snapshots and re-simulates on the client; a single float rounding difference, a different RNG, or a different iteration order silently desyncs every replay animation from its recorded outcome. Mitigation is mandatory and non-negotiable: integer-only combat math on both sides, one specified PRNG (PCG32 or xoshiro128**) implemented identically, and a golden-file test running 10,000 seeded battles through both implementations asserting byte-identical outcomes, wired into CI before any battle UI work starts.
- Config publish invalidates power for every player at once. A publish that changes any stat multiplier makes all 100k power_config_version stamps stale; recomputing eagerly is 100k transactions and would take ~8 minutes of sustained load. The batched 500-per-transaction drip over ~30 minutes is the mitigation, but during that window matchmaking bands and the power ladder use mixed old/new numbers. Publishes touching combat or stat config must be scheduled at low traffic and the admin UI must warn about it.
- Neon autosuspend cold start on the first request after a quiet period (~1.8s p50, ~3.1s p99). If autosuspend is left at the 5-minute default on production, the first player after any lull eats a multi-second stall on login. Requires explicitly disabling autosuspend on the main branch, MinConns >= 4, and ConnectTimeout >= 10s — three separate settings, all easy to forget on a redeploy or a branch reset.
- Cross-region VPS-to-Neon latency multiplied by round trips per request. Hetzner-to-London is 15-25ms RTT; at 3-8 queries per request that is 120-200ms of network invisible to Go profiling and easily misdiagnosed as slow application code. If the VPS region decision is deferred past launch it becomes a data migration rather than a config change.
- Silent failure of the partition maintenance job. If pre-creation stops running, inserts land in the DEFAULT partition (which then grows unboundedly and makes future ATTACH operations scan it); if the retention side stops, gold_ledger and battle_replays grow at ~1.4GB/day at 100k DAU and Neon storage billing follows. The job_runs table and the non-empty-DEFAULT-partition alert are the only things standing between a working system and a surprise invoice.
- Frozen rolled stats make a balance bug permanent. Because item and soldier stats are stamped at acquisition, shipping a config with a wrong tier multiplier bakes overpowered items into player inventories forever. The admin re-roll migration job that fixes this is described but not scoped in this design, and it is the kind of tool nobody builds until the emergency.
- Denormalised counters can drift: players.total_power, kingdoms.member_count, kingdoms.reputation and the ledger balance_after chain are all application-maintained. A single code path that mutates equipment or membership without calling RecomputeDerived, or a partial failure between the balance UPDATE and the ledger INSERT, produces drift that is invisible until a player complains. The nightly invariant_check job is the only detector and must actually page someone.
- Shop determinism breaks if SHOP_SECRET is rotated or lost. Rotating it reshuffles every open shop instantly and makes historical shop reconstruction for support impossible; losing it makes every past shop unauditable. It needs to be in a secret manager with an explicit no-rotation policy, and if rotation is ever required the version of the secret must become part of the seed input and be stored on player_shop_state.
- ALTER TYPE ... ADD VALUE cannot be used in the same transaction that then uses the new value, and goose runs migrations in a transaction by default. Any future migration adding an item tier, soldier type or ledger currency will fail confusingly unless it is split into its own -- +goose NO TRANSACTION migration. This is a footgun that will fire months from now, in production, on a Friday.
- Neon storage billing on WAL and branch history retention. Daily partition drops plus per-PR branch churn generate substantial WAL; history retention is billed and defaults higher than this workload needs. Left unconfigured this can quietly cost more than the compute.
- Account deletion versus IAP retention are in tension. iap_transactions uses ON DELETE RESTRICT on player_id so purchase history survives, meaning a GDPR erasure request cannot simply DELETE the player row — it must anonymise instead. The anonymisation path (which columns to null, what to do with display_name uniqueness, battle log references, leaderboard payloads) is not designed here and is a legal requirement given the game targets the EU.
- The 'no redeploy' promise is partial and will be mis-sold. New upgrade tracks, item defs, collect jobs, cost curves and tier weights genuinely need no deploy; a new kind of effect does. If the designer is told 'you can change anything from the admin panel' without that caveat, the first request for an effect Go doesn't know about becomes a trust problem rather than a ticket.

## Questions raised for the owner

- Tier colours: do you approve epic = flat violet #8B5CF6 and mystic = magenta #E879F9 with an animated gradient sheen? And do you accept that every tier also gets a distinct frame silhouette and corner glyph, so tier is legible without colour at all (roughly 8% of a male-skewed audience cannot reliably separate the gray/green/violet/magenta ladder)?
- Inventory cap: is 150 owned items the right default, and is raising the cap a diamond sink? This single number is the primary control on the size of the largest player-data table, so it is a design decision with a direct infrastructure cost.
- Should rolled item and soldier stats be frozen at acquisition (my recommendation — a rebalance never nerfs what a player already paid for), or re-derived live from config so rebalances apply retroactively? This changes the schema (frozen needs the stat columns, live needs only the def and tier) and cannot be changed cheaply after launch.
- PvP gold steal: is the 3% taken from the defender's full current gold with no floor or ceiling? Should there be a protected 'vault' or a minimum balance below which nothing is stolen? Without one, a player who logs in with a large uncollected balance is a farm target and will churn.
- Should there be a per-pair attack cooldown (I have provisioned cfg.pvp.attack_cooldown_same_target_seconds but defaulted it to 1 hour)? Without one, a strong player can farm one weak target repeatedly the moment each 30-minute shield lapses.
- Does the player's hero have its own 3 equipment slots (weapon/armor/horse), as I have assumed and built constraints for? And what is the maximum number of soldier slots — I have capped slot_index at 32 in the schema, so a design that wants more needs to say so now.
- How does the client submit collect actions — one HTTP request per tap, or a batched request covering N taps? This changes the anti-cheat boundary, the request rate the VPS must absorb, and whether the action_seq idempotency scheme is comfortable or tight.
- Kingdom treasury: can the leader withdraw gold from the treasury, or does it only ever flow into kingdom upgrades? A withdrawal path is a well-known vector for scam guilds and needs an audit and approval design if it exists at all.
- What is the refund clawback policy when Apple refunds a diamond purchase the player has already spent? Options are allow the balance to go negative, block gameplay until repaid, absorb the loss, or ban on repeat abuse. The schema supports all four but the answer determines whether diamond_ledger.balance_after can drop its CHECK (balance_after >= 0) constraint.
- Will the game be sold in the EU, and what is the target SLA for account deletion? Neon is in London and this is a real-money game, so the anonymise-versus-delete path (IAP records use ON DELETE RESTRICT specifically to survive deletion) needs a decision before launch, not after the first request arrives.
- Can the VPS go on DigitalOcean LON1 rather than Hetzner? Hetzner adds roughly 15-25ms RTT to every one of the 3-8 database round trips per request. If Hetzner is required for cost, the alternative is moving the Neon project to eu-central-1 — but either way this must be settled before there is production data.
- Are bot/filler accounts acceptable for seeding the PvP pool at launch? I have provisioned players.is_bot for this. Without them the first few hundred real players have almost nobody to attack, which breaks the core loop exactly when retention matters most.

---

# Adversarial review — verdict: needs-revision


## BLOCKER (4)

### The economy does not close. Income is bounded at ~3x lifetime growth while upgrade costs grow ~20,000x. The collect ladder's gold-per-energy is 2.00 → 2.00 → 2.25 → 2.43 → 2.64 (a 1.32x spread across 15 character levels). The only multipliers are granary (+2%/level × 50 = +100%) and per-job milestones (+15%). Max lifetime gold/energy = 2.64 × 2.0 × 1.15 = 6.06, i.e. 3.03x the starting 2.00. Meanwhile the geometric cost curves total: granary 23.6M, treasury 112.1M, barracks 108.4M, stable 36.1M, scriptorium 4.1M ≈ 284M gold to max the five tracks. Even at an extremely generous 1 energy/10s (8,640 energy/day) endgame income is ~52k gold/day, so treasury alone is 2,150 days and the full set is 15 years. The top ~15 levels of every track are unreachable by three to four orders of magnitude.

**Breaks because:** For an additive-percent upgrade with a linear value curve V(n)=n·step and a geometric cost curve C(n)=base·g^n, time-to-next-level scales as g^n/n and diverges exponentially. There is no income term in the design that grows geometrically to absorb it: the job ladder is arithmetic-ish, family bonuses are additive and capped at +100%, and energy throughput grows only +25 flat from stable. The design's own risk list does not contain this, and the publish pipeline's 'dry-run 30-day economy sim' would have caught it — but the sim gates changes against the *currently published* config, so it would happily bless the broken v1.

**Fix:** Make the primary income axis geometric and shorten the upgrade tracks so cost growth tracks income growth. Rule to encode in the publish validator: for any income-multiplier track, growth_milli^max_level must land within ~5–20x of the lifetime income-growth multiplier (payback stretch), not 300x above it.

(1) Replace the 5-rung collect ladder with a 12-rung geometric one, gold/energy × 1.45 per rung (59.6x lifetime):
key/min_level/energy/gold/xp — grapes 1/1/2/1; strawberries 3/2/6/3; wheat 6/3/13/5; olives 10/5/30/12; beeswax 15/8/71/27; quarry 21/12/154/54; ironworks 28/18/335/109; vineyard 36/26/701/212; saltworks 45/38/1485/419; goldmine 55/55/3117/819; armory 66/80/6574/1609; cathedral 78/115/13702/3121. (xp/energy grows ×1.35 per rung.)

(2) Level curve XP(L→L+1) = round(40·L^1.8). At 100% energy utilisation (1440 energy/day at 1 energy/60s) this gives L10≈3d, L21≈17d, L28≈30d, L40≈58d, L78≈169d.

(3) Rewrite family tracks — halve the lengths, double the per-level value, raise growth:
  granary  collect_gold_pct  max_level 25 value step 4000 (+4%/lvl, +100% total) cost {geometric, base 30,  growth_milli 1330}
  treasury tax_rate_pct      max_level 25 value step 6000 cost {geometric, base 50,  growth_milli 1330}
  barracks soldier_attack_pct max_level 20 value step 6000 cost {geometric, base 300, growth_milli 1420}
  stable   max_energy_flat   max_level 20 value step 2    cost {geometric, base 500, growth_milli 1420}
  scriptorium xp_pct         max_level 20 value step 4000 cost {geometric, base 200, growth_milli 1420}
This puts marginal payback at ~8h for the first level of granary rising to ~100h for the last, which is the standard shape.

### The partition-maintenance job cannot create partitions. §7 runs `partition_maintenance` as a goroutine in the Go server on the pooled `DATABASE_URL` as role `emperors_app`, doing `CREATE TABLE ... PARTITION OF ...` and `DROP TABLE <partition>`. Migration 00017 grants `emperors_app` only `USAGE ON SCHEMA public` (no CREATE) and never makes it the owner of any table.

**Breaks because:** `CREATE TABLE ... PARTITION OF parent` is an implicit ATTACH and requires ownership of the parent partitioned table — there is no GRANT that substitutes for it (confirmed on the pgsql-hackers thread 'Partition Creation Permissions'). It also requires CREATE on the schema, which since PG15 is not granted to PUBLIC. `DROP TABLE` on a partition requires ownership of that partition, and the initial partitions created by goose are owned by `emperors_migrate`. So on day one the job errors on both the pre-create and the retention paths.

**Fix:** Split the job runner off the request pool:
1. Add role `emperors_jobs LOGIN`. In 00017: `GRANT CREATE, USAGE ON SCHEMA public TO emperors_jobs;` and, for every partitioned parent (`gold_ledger`, `diamond_ledger`, `battles`, `battle_replays`, `collect_events`, `kingdom_donations`, `admin_audit_log`), `ALTER TABLE <parent> OWNER TO emperors_jobs;` plus `ALTER TABLE <each seeded partition> OWNER TO emperors_jobs;`.
2. Give the scheduler its own small `pgxpool` (MaxConns 2) built from `DATABASE_URL_DIRECT` — it needs DDL and it is low-frequency, so the pooler buys nothing.
3. Note that INSERT/SELECT through the parent skips partition-level ACL checks (documented inheritance behaviour), so `emperors_app` needs no grants on future partitions — only the parent grants from 00017. Do not add per-partition GRANTs.
4. Because DEFAULT partitions are present, `CREATE TABLE ... PARTITION OF` takes ACCESS EXCLUSIVE on the DEFAULT partition and scans it to prove no rows belong to the new range. Keep the defaults, but pre-create partitions far enough ahead (the design's 3–4 is fine) and alert on non-empty defaults as already planned.

### Migration 00017 is not valid SQL and will break both goose and sqlc. It uses psql client-side variable interpolation: `CREATE ROLE emperors_app LOGIN PASSWORD :'app_pw';`

**Breaks because:** `:'name'` is a psql meta-command feature expanded by the psql client before the server ever sees it. goose executes migration statements over database/sql via pgx; the server receives the literal `:'app_pw'` and raises a syntax error. Separately, `sqlc.yaml` sets `schema: db/migrations`, so sqlc parses every file in that directory with pg_query — 00017 will fail parsing and `sqlc generate` will not run at all, which blocks the entire codegen step the design depends on. Third, putting login passwords in a migration file puts them in git.

**Fix:** Take role/grant management out of goose entirely.
1. Delete 00017. Create the three (now four) roles once per Neon project via the Neon console/API or a `scripts/bootstrap_roles.sql` run manually with `psql -v app_pw=...` against the direct endpoint. Neon copies roles into child branches at branch-creation time, so branches inherit them and `CREATE ROLE` must not be re-run there anyway.
2. Move the GRANT/REVOKE statements into a goose migration that contains no passwords, and add the piece the design is missing entirely: `ALTER DEFAULT PRIVILEGES FOR ROLE emperors_migrate IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO emperors_app, emperors_admin;` and the same for `USAGE ON SEQUENCES`. Without it, every table added by a future migration is invisible to the app, because `GRANT ... ON ALL TABLES` only affects tables that exist at grant time.
3. If you keep any non-parseable file under `db/migrations`, move it out — sqlc has no exclude mechanism for its schema directory.

### The recommended PRNG cannot be implemented in GDScript, so the client-side battle replay — the design's own #1 risk — is guaranteed to desync or crash. The design says 'one specified PRNG (PCG32 or xoshiro128**) implemented identically'. PCG32 has 64-bit unsigned state and its output function is `xorshifted = ((state >> 18) ^ state) >> 27`, plus `rot = state >> 59`.

**Breaks because:** GDScript's `int` is signed 64-bit with no unsigned type, and its shift operators are broken for negative left operands: the editor raises a compile error, and code that reaches runtime produces wrong results — godotengine/godot#88163 (still open, reproduced on 4.2.1+) documents `-1 >> 1` returning `-1` rather than a logical shift. Any 64-bit LCG state will exceed 2^63 roughly half the time, which in GDScript is a negative int, so every `>>` in the PCG output function is either a hard error or silently arithmetic where Go's `uint64 >>` is logical. The golden-file test the design mandates would catch it, but only after the GDScript simulator is written against an impossible spec.

**Fix:** Specify xoshiro128** (four 32-bit lanes) as the one PRNG, and write the GDScript port with explicit 32-bit masking so no value is ever negative:
```gdscript
const M := 0xFFFFFFFF
func _rotl(x: int, k: int) -> int:
    return ((x << k) | (x >> (32 - k))) & M   # x is always 0..2^32-1, so >> is safe
func next() -> int:
    var r := (_rotl((s1 * 5) & M, 7) * 9) & M
    var t := (s1 << 9) & M
    s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3; s2 ^= t
    s3 = _rotl(s3, 11)
    return r
```
On the Go side use `uint32` lanes, not `uint64`. Seed both sides by splitting `battles.rng_seed` (int64) into four uint32 lanes with a fixed, documented byte order. Add a lane-level golden test (first 1,000 outputs from 100 seeds, byte-identical) *before* the 10,000-battle test, so a PRNG mismatch is diagnosed separately from a combat-logic mismatch.
Also add to the shared spec: GDScript `/` and `%` truncate toward zero and so does Go's, so integer division matches — but `%` on a negative dividend returns a negative remainder in both, and the milli-scaled formulas (`x * (1000 + bonus) / 1000`) must be written with the multiply first in both languages and must never take a negative intermediate.


## MAJOR (14)

### `players_dormancy_idx ON players (last_seen_at) WHERE state='active'` destroys HOT on the hottest write path, directly contradicting the design's own headline rationale for `fillfactor = 80`.

**Breaks because:** A HOT update requires that no *indexed* column changed. A collect writes gold, xp, energy_current, energy_updated_at, action_seq, tax_carry_mg, tax_accrued_at — none indexed, so HOT holds. But `last_seen_at` must be bumped on every authenticated request for the dormancy sweep to mean anything, and it *is* indexed. Every collect therefore becomes a non-HOT update that inserts into `players_dormancy_idx` and, because a non-HOT update writes a new tuple in a new index-visible position, also into `players_matchmaking_idx` and `players_name_trgm_idx` (a GIN index — the expensive one). The design spends a whole paragraph arguing against indexing gold/xp/energy and then indexes an equally hot column two lines later.

**Fix:** Two changes, both required:
1. Drop `players_dormancy_idx`. The dormancy sweep runs once a day over 100k rows; a sequential scan of a 30 MB table is single-digit hundreds of milliseconds on Neon and costs nothing. Remove row 47 from the index catalogue.
2. Make `last_seen_at` coarse regardless, so it stops dirtying the row on every request: update it only when it is actually stale — `UPDATE players SET last_seen_at = now() WHERE id = $1 AND last_seen_at < now() - interval '15 minutes'`. Issue it as a separate statement outside the mutation transaction, or fold the predicate into the mutation UPDATE's SET list with `last_seen_at = CASE WHEN last_seen_at < now() - interval '15 minutes' THEN now() ELSE last_seen_at END`.
Same reasoning applies to `total_power`: it is indexed, so every level-up, equip and upgrade is a non-HOT update. That is fine (those are rare), but it means the leaderboard job's mass power-recompute is a full index rewrite — schedule it accordingly.

### `gold_ledger.balance_after` cannot form the self-verifying chain the design claims, because the design's own hourly aggregation of grind income breaks it on every player who collects.

**Breaks because:** The design asserts 'a reconciliation job can walk a player's ledger and assert balance_after[n] = balance_after[n-1] + delta[n]'. But collect and tax income mutate `players.gold` with no ledger row, buffered in-process and flushed an hour later as a single aggregate. In the meantime, material transactions (shop buy, recruit, battle steal) write synchronous rows whose `balance_after` reflects gold that includes un-ledgered collect income. Walking the chain, every synchronous row after any collect fails the assertion. The reconciliation job would fire on essentially every active player, every run, and the 'reconciliation correction row' mechanism the design describes for crash recovery becomes the normal path. Separately, `seq` is defined as `players.gold_seq` incremented 'in the same transaction as the balance change' — but the buffered rows take their seq an hour later, so their seq sorts *after* transactions that happened during the buffered window, and the flush must also UPDATE `players.gold_seq` for every active player every hour, adding a non-trivial write to the hot row that the design does not account for.

**Fix:** Accept that gold is not event-sourced and stop pretending the chain exists.
1. Drop `balance_after` from `gold_ledger` entirely. Keep it on `diamond_ledger`, where every single mutation is synchronous and the chain genuinely holds — that is where it is worth having, because that is the real-money table.
2. Change `gold_ledger.seq` semantics: allocate it from `players.gold_seq` for synchronous rows only, and give aggregate rows `seq = 0` with a `reason_id` in the `income` category. Make the PK `(player_id, created_at, seq)` so aggregate rows do not collide (two hourly buckets in the same partition differ by created_at). Add `CHECK (seq > 0 OR reason_id IN (<grind reason ids>))`.
3. Rewrite `invariant_check` for gold as a windowed reconciliation, not a chain walk: `players.gold` must equal `opening_balance(window) + sum(gold_ledger.delta over window)` where opening balance comes from `gold_flow_monthly`. Tolerate one hour of drift (the unflushed buffer) and alert only above that.
4. State explicitly that the buffered flush is single-process. Two Go instances would each hold a buffer for the same player; `collect_events` survives via ON CONFLICT DO UPDATE but `gold_ledger` would double-count nothing yet still race on `gold_seq`. Add this as a documented scale-out blocker.

### The 'your rank' query will not get an index-only scan, so the claimed 2–5 ms is off by one to two orders of magnitude. `SELECT count(*)+1 FROM players WHERE state='active' AND total_power > $1` is supposed to be index-only against `players_matchmaking_idx`.

**Breaks because:** An index-only scan still visits the heap for any tuple whose page is not marked all-visible in the visibility map. `players` is updated on every collect and every request (see the `last_seen_at` finding), so the VM bits are cleared continuously and autovacuum cannot keep up with a 100k-row table taking millions of updates a day. A mid-table player therefore scans ~50k index tuples *and* performs tens of thousands of heap visits, many of them random pages fetched from the Neon pageserver on a cold cache. That is hundreds of milliseconds, not 2–5 ms — and it is on a screen the design says players open regularly. The 60 s per-player cache does not help the first hit or a cold cache after a deploy.

**Fix:** Build `leaderboard_buckets` from day one instead of deferring it. It is 1000 rows per board and the 5-minute job already sequentially scans all 100k `players` rows for the `player_gold` board, so the bucket boundaries come out of a scan you are already paying for:
```sql
-- inside the same scan, per board
SELECT total_power, row_number() OVER (ORDER BY total_power DESC) FROM players WHERE state='active'
-- emit every ceil(N/1000)-th row as (score_floor, count_above)
```
Then serve rank from `leaderboard_buckets` + a bounded residual count limited to one bucket (~100 rows), exactly as the design's own §00013 'scale-out' query already specifies. Delete the 'not populated at launch' note. Cost: 1000 extra rows per board per generation, ~3000 rows every 5 minutes. Additionally, set `players` to `autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_cost_delay = 0` via a `WITH` clause on the table so the VM at least stays reasonable for the matchmaking scan.

### The attack endpoint has no server-side target validation, in a design that is otherwise rigorous about anti-tamper. Matchmaking returns 5 candidates from `FindTargets`, but nothing described anywhere binds the subsequent attack to that candidate set.

**Breaks because:** The design goes to real trouble for the shop — the client must echo `{epoch, reroll_index, slot_index, def_id, tier, price, config_version}` and the server re-derives the offer and requires an exact match. The attack path has no equivalent: the client presumably POSTs a `defender_id`, and the only checks named are self, same-kingdom, shield and cooldown. A modified client can therefore attack any `player_id` it can enumerate, ignoring `cfg.pvp.matchmaking.power_band_pct_milli` entirely — pick the weakest, richest account in the database and farm it, or scan ids to map the player base. `battles_not_self_ck` and the shield check are the only server-side gates, and neither bounds the power band. The design also never states that the same-kingdom rule is re-checked at attack time rather than only at matchmaking time, and there is no DB constraint for it.

**Fix:** Persist the candidate set the same way `player_shop_state` persists shop state — one row per player, cheap:
```sql
CREATE TABLE player_pvp_targets (
    player_id    bigint PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
    generated_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    my_power     bigint NOT NULL,
    target_ids   bigint[] NOT NULL
) WITH (fillfactor = 70);
```
The attack endpoint requires `defender_id = ANY(target_ids)` and `now() < expires_at` (5–10 min TTL), then re-validates inside the transaction: defender still `state='active'`, `shield_until IS NULL OR shield_until < now()`, `defender.kingdom_id IS DISTINCT FROM attacker.kingdom_id`, and `defender.total_power BETWEEN my_power*(1-band) AND my_power*(1+band)` re-derived from the row it just locked. Reject with 409 otherwise. Cost: one row per player, one PK lookup, no new index.

### Shop offer derivation depends on `content_item_defs`, which is mutable L1 state outside the versioned config, so the design's two headline shop claims — 'fully auditable, an admin endpoint recomputes exactly what the player saw' and the anti-tamper purchase match — both fail as soon as a def is added or retired.

**Breaks because:** The roll is `roll(slot_seed, cfg.shop.slot_type_weights, cfg.shop.slot_tier_weights_by_level[level], live content_item_defs for that slot)`. The def pool is read live and is not part of the seed, not part of the config version, and not stamped anywhere. (a) The admin replay endpoint takes `epoch`, `reroll`, `config_version` — but not a def-pool version, so once a def is retired the reconstruction silently returns a different item and support is looking at a lie. (b) Retiring or adding a def is an admin action on L1 that is *not* gated by `config_version`, so the grace-window protection the design built for exactly this problem does not cover it: a player renders their shop, an admin retires a def, the player taps buy, the server re-derives against the new pool, `(def_id, tier, price)` no longer matches, and the purchase 409s for no reason the player can understand.

**Fix:** Move the pool into L2 so `config_version` fully determines the roll:
1. Add to the `shop` config section an explicit, ordered `def_pool` per slot: `{"weapon": ["sword_falchion_02", ...], "armor": [...], "horse": [...]}`. Publish validation already checks that every referenced slug exists and is non-retired in L1 — extend it to also require that the pool is non-empty per slot and that ordering is stable (append-only relative to the parent version, so a republish does not reshuffle existing epochs gratuitously).
2. Roll against `def_pool` by index, never against a live `SELECT ... WHERE retired_at IS NULL` (which also has no defined ordering — a second, independent source of nondeterminism, since `content_item_defs_live_idx` gives no ORDER BY guarantee).
3. Retiring a def then becomes a config publish like everything else, subject to the grace window and the `config_version` check on purchase. The admin replay endpoint's existing `config_version` parameter becomes sufficient.

### `config_documents` rows for an already-published version are freely UPDATE-able, which breaks the 'immutable, byte-identical rollback' guarantee for the half of the config that never goes into the bundle.

**Breaks because:** `config_bundles.body_raw` contains only `client_visible` sections, so the server's own copy of `shop` (roll weights, price formula, reroll cost) and the server-only soldier tier weights is not in any immutable artefact — the Go server must reassemble it from `config_documents`. Those rows carry `updated_by`/`updated_at`, i.e. they are designed to be mutated, and nothing in the schema or the grants prevents an admin from editing a published version's documents. Do that and a rollback to that version restores byte-identical *client* config but silently different *server* config — which is precisely the class of bug the whole L2 design exists to prevent, and it lands on the shop roll tables, the most exploit-sensitive numbers in the game.

**Fix:** 1. Add a server-side bundle alongside the client one: `config_bundles.server_body_raw bytea NOT NULL` and `server_etag text NOT NULL`, built in the same compile step from *all* sections (canonical sorted-key JSON). The server loads its snapshot from `server_body_raw`, never from `config_documents`. Rollback then restores both halves byte-identically.
2. Enforce immutability in the database, not by convention:
```sql
CREATE FUNCTION config_documents_guard() RETURNS trigger AS $$
BEGIN
  IF (SELECT status FROM config_versions WHERE id = OLD.version_id) <> 'draft' THEN
    RAISE EXCEPTION 'config_documents are immutable once the version leaves draft';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;
CREATE TRIGGER config_documents_immutable BEFORE UPDATE OR DELETE ON config_documents
  FOR EACH ROW EXECUTE FUNCTION config_documents_guard();
```
(The design's blanket 'no triggers' rule is about *game* logic that duplicates the Curve evaluator; a four-line integrity guard on an admin table is not that.)
3. Also add `CREATE UNIQUE INDEX config_versions_one_published ON config_versions ((status)) WHERE status = 'published';` or drop the `published` status in favour of `config_active` being the sole source of truth — right now nothing stops several rows sitting in `status='published'`, and the rollback procedure ('step 5 alone') never demotes the version being rolled back from.

### §7 says 'Set `application_name` per job so pg_stat_statements attributes them' four paragraphs after correctly listing `SET`/`RESET` as unsupported on the Neon pooler.

**Breaks because:** Verified against Neon's connection-pooling docs: the unsupported list on pooled connections is exactly `SET`/`RESET`, `LISTEN`/`NOTIFY`, `WITH HOLD` cursors, SQL-level `PREPARE`/`DEALLOCATE`, temp tables with PRESERVE/DELETE ROWS, `LOAD`, and session-level advisory locks. `SET application_name` is the first item on that list. And even if it worked, the jobs share the request pool, so a `SET` on a pooled connection would leak the job's application_name onto the next player request that lands on it.

**Fix:** This resolves itself once the job runner gets its own pool (see the partition-maintenance fix): build the jobs pool from `DATABASE_URL_DIRECT` with `application_name=emperors-jobs` in the DSN, which is sent in the startup packet and needs no SET. For per-job attribution inside that pool, prefix each job's SQL with a comment — `/* job=leaderboard_refresh */ SELECT ...` — and set `pg_stat_statements.track_utility`/`compute_query_id` accordingly; comments survive normalisation as distinct queryids only if `pg_stat_statements.track = all` and the comment is inside the statement text, so if you want reliable attribution use the `job_runs` table (already in 00015) plus Go-side timing rather than leaning on pg_stat_statements. Also drop the pgx comment `MinConns = 4 // keeps the Neon compute warm` — Neon suspends after 5 minutes with *no active queries*; idle open connections do not keep it alive. The 10 s `config_active` poll is the keep-alive; MinConns only avoids connect latency.

### `player_soldier_slots` allows `slot_index < 32` while the replay encoding and its storage estimate assume '≤ 13 units'. The `player_items` sizing also assumes `inventory_cap = 150` bounds the whole table, but index #11 counts only *free* items against the cap.

**Breaks because:** Two compounding under-counts. (a) With 32 slots a side, a replay is 33 units × ~40 B × 2 sides ≈ 2.6 KB, not the ~700 B the design's table asserts, so `battle_replays` is ~3.8 GB/day at 100k DAU rather than 1.0 GB/day, and the 7-day retention holds ~27 GB rather than 7 GB. That flips the design's own comparison table: packed bytea at 32 slots is worse than the JSONB option it rejected at 13 slots. (b) A player at 32 slots holds 96 equipped items plus 150 free, so the 'cap-saturated' row should be ~246 items/player, not 150 — 24.6 M rows and ~3.8 GB rather than 15 M and 2.3 GB, which also moves the 'revisit at 100 M rows' trigger closer.

**Fix:** Pick the number once and make it structural. Recommend 12 purchasable slots (13 units with the hero), which is what the replay format was actually designed for:
1. `CHECK (slot_index >= 0 AND slot_index < 16)` in `player_soldier_slots`, with the *effective* cap in config (`cfg.soldiers.max_slots = 12`) so it is tunable upward without a migration, and publish validation rejecting `max_slots > 16`.
2. Add the missing slot price curve the brief explicitly demands ('each slot purchased makes the next slot more expensive') — there is no such curve anywhere in the config sections. Add to the `soldiers` section: `"slot_cost": {"kind":"geometric","base":400,"growth_milli":1708}`, giving slots at 400, 683, 1167, 1993, 3404, 5814, 9931, 16962, 28971, 49482, 84515, 144352 (total ~347k), which tracks the corrected income curve at roughly 20 h of endgame income for the last slot.
3. Make `inventory_cap` count *all* rows for the player, not just free ones, and change index #11 to count against `player_items_free_idx` plus the equipped count — or simpler, add `players.item_count integer` maintained in `RecomputeDerived` (it already runs on every acquire/sell). Restate the storage table with items/player ≈ 12×3 + 150 = 186.

### The batched power-recompute drip is not actually protected against overlapping itself. §7 gives `leaderboard_refresh` a 5-minute interval and lock id 1001 using `pg_advisory_xact_lock`; §3 says the same job additionally recomputes stale players 'in batches of 500 per transaction, rate-limited, spread over ~30 minutes'.

**Breaks because:** `pg_advisory_xact_lock` is released at COMMIT — that is exactly why the design chose it (it works through PgBouncer). A 30-minute drip spanning hundreds of transactions therefore holds the lock only for the duration of each 500-row batch. The 5-minute scheduler will fire five more times during that window, each acquiring the lock between batches and starting its own drip. After a config publish (when every one of 100k rows is stale) you get six concurrent drips writing `total_power` and `power_config_version`, each doing non-HOT updates to `players_matchmaking_idx`, while matchmaking reads the same index. This is the design's own stated risk #2 made materially worse.

**Fix:** 1. Split the jobs. `leaderboard_refresh` (5 min, short, lock 1001) does only the generation build and swap. `power_recompute` becomes its own job with a longer interval and a *lease*, not a lock.
2. Add lease columns to the existing `job_runs` table: `lease_owner uuid`, `lease_until timestamptz`. Acquire with a single conditional UPDATE that works fine through the pooler:
```sql
UPDATE job_runs SET lease_owner = $1, lease_until = now() + interval '2 minutes', last_start = now()
WHERE job_name = $2 AND (lease_until IS NULL OR lease_until < now())
RETURNING job_name;
```
Renew the lease every batch; release on completion. Zero rows returned means another instance holds it — skip this tick.
3. Drive the drip off a cursor rather than a scan: `WHERE power_config_version <> $active AND id > $last_id ORDER BY id LIMIT 500`, storing `$last_id` in `job_runs`. No index on `power_config_version` needed (correctly rejected by the design), and PK order makes the batches deterministic and resumable.

### `emperors_admin` is granted `SELECT, INSERT, UPDATE, DELETE ON ALL TABLES`, which includes `iap_transactions`, `diamond_ledger`, `gold_ledger` and `battles` — destroying the anti-replay guarantee the design just built.

**Breaks because:** §00014 calls `UNIQUE (platform, transaction_id)` 'THE anti-replay constraint. A receipt can grant diamonds exactly once, ever.' That is only true if nobody can delete the row. The Next.js admin panel's role can `DELETE FROM iap_transactions WHERE ...` and then re-submit the same Apple receipt for a second diamond grant, and can `DELETE FROM diamond_ledger` to erase the evidence — on a table the design says must be kept 7 years for chargebacks and tax. The design carefully revokes UPDATE/DELETE on `admin_audit_log` and revokes config writes from `emperors_app`, then hands the internet-facing admin panel unrestricted DML over the money tables.

**Fix:** Least-privilege the admin role explicitly, immediately after the blanket grant:
```sql
REVOKE INSERT, UPDATE, DELETE ON iap_transactions, iap_server_notifications,
                                 diamond_ledger, gold_ledger, gold_flow_monthly,
                                 battles, battle_replays, collect_events
    FROM emperors_admin;
REVOKE DELETE ON players, kingdoms, soldiers, player_items FROM emperors_admin;
REVOKE INSERT, UPDATE, DELETE ON gold_ledger, diamond_ledger FROM emperors_admin;
```
Every admin action with an economic effect (grant gold/diamonds, adjust a balance, refund, re-roll a cohort) must go through the *game server's* admin API, which writes the ledger row and the `admin_audit_log` row in one transaction as `emperors_app`. The admin panel keeps direct SELECT for dashboards and direct DML only on genuinely admin-owned tables (`moderation_reports`, `player_sanctions`, `player_mail`, `config_*`, `content_*`). This also removes the need for the panel to hold a second database credential at all if you route everything through the API.

### The per-job collect milestones are dead on arrival: 25/50/100 collects are reached in under two hours of play for every job, and the thresholds are a single global list applied to a ladder whose energy cost spans 1 → 115.

**Breaks because:** At a plausible 60 energy/hour, 100 collects of grapes (1 energy each) is 100 energy ≈ 1.7 hours. Even the deepest job in the design's own ladder (quarry, 11 energy) hits 100 collects in 1,100 energy ≈ 18 hours. So the entire mechanic — which the brief calls out as a named feature — is fully maxed on day one and never thought about again. Worse, on any corrected ladder the spread makes a single global threshold list incoherent: 100 collects of a 1-energy job and 100 collects of a 115-energy job differ by 115x in effort but grant the same bonus. Separately, the design never states whether milestones are cumulative (+5/+10/+15 = +30% total) or replacing (+15% at 100) — a 2x swing in the value of the mechanic that Go must decide and that nothing in the JSON disambiguates.

**Fix:** 1. Denominate milestones in *energy spent on that job*, which auto-normalises across the ladder and needs no per-job tables:
```jsonc
"milestones": [
  {"at_energy":   500, "gold_bonus_pct_milli":  5000},
  {"at_energy":  5000, "gold_bonus_pct_milli": 10000},
  {"at_energy": 50000, "gold_bonus_pct_milli": 15000}
],
"milestone_stacking": "cumulative"
```
At 1440 energy/day and roughly even spread across the two or three jobs a player actively uses, tier 1 lands in ~1 day, tier 2 in ~1 week, tier 3 in ~2 months per job — a real long-tail hook.
2. This requires a schema change the design is missing: `player_collect_progress` stores `lifetime_gold` and `lifetime_xp` but **not** `lifetime_energy`. Add `lifetime_energy bigint NOT NULL DEFAULT 0 CHECK (lifetime_energy >= 0)`. (`collect_events.energy` exists but is a 6-week-retention analytics aggregate, so it cannot be the source of a permanent bonus.)
3. Make `milestone_stacking` an explicit config enum with the same treatment as `effect_stacking`, and have the publish validator reject an unknown value rather than letting Go default silently.

### The publish pipeline runs a 30-day headless economy simulation as step 3 of a single database transaction, inside an admin HTTP request.

**Breaks because:** A simulation over levels 1→40 that is detailed enough to gate a publish is seconds to minutes of CPU. Holding a Postgres transaction open for that on Neon pins a pooled connection (starving the request pool), blocks the `config_versions`/`config_active` rows against any concurrent admin work, and extends `xmin` horizon so autovacuum cannot clean anything on the busiest tables for the duration. It will also exceed the Next.js/Vercel serverless request timeout for the admin panel. And nothing in the simulation writes to the database until step 5, so the transaction buys nothing.

**Fix:** Restructure as: (1) validate + simulate outside any transaction, as a separate `POST /admin/config/:id/validate` that returns the sim report and stores it on the draft; (2) `POST /admin/config/:id/publish` opens a short transaction that re-checks the schema/referential validation, re-checks that the stored `sim_report` matches the current document hashes, compiles the bundle, flips `config_active`, and writes the two log rows. Total transaction time: milliseconds.
Separately, scope the simulator down for v1. A 30-day economy sim that *blocks* publishes is weeks of work that must be accurate to be useful, and it is on the critical path of shipping the config system at all. Ship instead a deterministic **derived-metrics diff**: for character levels {1,10,20,30,40}, compute gold/hour at full energy utilisation, hours-to-next-level, marginal payback hours for every upgrade track level, and the total cost of each track; render old-vs-new side by side in the admin UI; warn, do not block. That is a few hundred lines, is exactly as good at catching the geometric-cost blowup identified above, and cannot itself be wrong in a way that blocks a legitimate hotfix.

### Tax accrual and `RecomputeDerived` have no specified ordering, so buying a tax upgrade retroactively applies the new rate to up to 8 hours of already-elapsed time.

**Breaks because:** `tax_rate_mgps` is materialised on `players` and rewritten by `RecomputeDerived`, which the design says must run in the same transaction as 'buy family upgrade'. Accrual is `accrued_mg = tax_carry_mg + tax_rate_mgps * (now - tax_accrued_at)`. If the upgrade transaction calls `RecomputeDerived` before settling the accrual, the treasury level the player just bought is applied to the whole elapsed window since `tax_accrued_at` — up to the 8-hour offline cap. With treasury at +150% that is a free 1.5x on 8 hours of tax, repeatable on every single level purchase, i.e. 25 free windows per player. The same bug applies in reverse to `max_energy_flat` from `stable` and to leaving a kingdom.

**Fix:** Make it structural rather than a convention. Introduce one entry point that every mutating handler calls first:
```go
// Settles time-based accrual (energy regen, tax) up to now() at the CURRENTLY STORED rates,
// writing energy_current/energy_updated_at/gold/tax_carry_mg/tax_accrued_at.
// MUST be called before any mutation and before RecomputeDerived.
func SettleAccrual(ctx context.Context, tx pgx.Tx, cfg *balance.Snapshot, p *Player) error
```
and document the fixed order in `derive.go`: `LoadPlayerAggregate (FOR NO KEY UPDATE)` → `SettleAccrual` → apply mutation → `RecomputeDerived` → single UPDATE. Add a negative test: buy a treasury level after 8 h offline, assert gold gained equals the pre-purchase rate × elapsed, not the post-purchase rate.
While there: the accrual formula caps `elapsed` at the offline cap but the design never says what happens to `tax_accrued_at` afterwards. State it — `tax_accrued_at = now()`, forfeiting the excess — because setting it to `tax_accrued_at + elapsed` would bank tax indefinitely and defeat the cap.

### `jsonb_agg` in `LoadPlayerAggregate` has no ORDER BY, so soldier and item ordering is nondeterministic — and that ordering feeds the battle replay encoder.

**Breaks because:** `(SELECT jsonb_agg(to_jsonb(s)) FROM soldiers s WHERE s.player_id = p.id)` returns rows in whatever order the plan produces, which varies with plan choice, heap order after updates, and parallelism. Power computation is a sum of integers so it is order-independent, but the replay snapshot is `[tier atk def def_id] × n` — a positional array. If the server encodes units in one order and any later re-simulation (or the client's animation, which pairs units by index) assumes another, the replay diverges from the recorded `outcome`. This is the design's #1 risk arriving through a path the design does not mention, and it will present as an intermittent, unreproducible desync.

**Fix:** 1. Add `ORDER BY s.slot_index` to the soldier aggregation and `ORDER BY i.slot, i.id` to both item aggregations in `LoadPlayerAggregate`.
2. Write the canonical unit order into the replay format spec, not just the query: 'unit 0 is the hero; units 1..n are soldiers in ascending `slot_index`; a soldier's items are ordered weapon, armor, horse by the `item_slot` enum's declared order.' Put it in a comment block at the top of the encoder in both Go and GDScript.
3. Add it to the golden test: assert the encoded bytea is byte-identical across 100 runs of the same player state, after forcing a plan change with `SET enable_seqscan = off` in the test harness (which works on the direct endpoint the tests should use anyway).


## MINOR (2)

### Seven of the twelve declared effect kinds have no upgrade track, so they are untested Go switch branches shipping as dead code; and the sqlc configuration block is not valid YAML.

**Breaks because:** The closed effect enum declares `collect_gold_pct, tax_rate_pct, soldier_attack_pct, soldier_defense_pct, hero_attack_pct, hero_defense_pct, max_energy_flat, energy_regen_pct, xp_pct, shop_price_pct, steal_pct, offline_cap_seconds_flat`. The `family_upgrades` section uses five; the `kingdom` section is described but never given tracks. So `soldier_defense_pct`, `hero_attack_pct`, `hero_defense_pct`, `energy_regen_pct`, `shop_price_pct`, `steal_pct` and `offline_cap_seconds_flat` have no config that exercises them — the first designer to add such a track discovers whether the effect summation, the milli-scaling and the `RecomputeDerived` wiring for that kind actually work, in production, which is exactly the 'no redeploy' promise failing at the moment it is being tested. Separately, `overrides: - db_type: "timestamptz"; go_type: "time.Time"` is not YAML — `;` is not a separator — and sqlc's documented form is a mapping with `db_type` (canonically `pg_catalog.timestamptz`), `nullable`, and `go_type` as either a string or an `import`/`package`/`type` map.

**Fix:** 1. Ship a kingdom upgrade track for each otherwise-unused effect kind so every branch has coverage on day one — e.g. `walls → soldier_defense_pct`, `keep → hero_defense_pct`, `training_yard → hero_attack_pct`, `beacon → energy_regen_pct`, `market → shop_price_pct`, `warcamp → steal_pct`, `granary_stores → offline_cap_seconds_flat`. If a kind has no plausible track, delete it from the enum; an untested branch is worse than a missing feature.
2. Add a unit test that iterates the effect enum and fails if any kind is unreferenced by the seeded v1 config — this turns the coverage rule into CI.
3. Fix the sqlc block:
```yaml
        overrides:
          - db_type: "pg_catalog.timestamptz"
            go_type: "time.Time"
          - db_type: "pg_catalog.timestamptz"
            nullable: true
            go_type: "*time.Time"
```
4. Note that `LoadPlayerAggregate`'s `to_jsonb(p)` and `jsonb_agg(...)` come back as `[]byte`, so this one query — the one every request runs — gets none of sqlc's type safety and needs hand-written structs kept in sync manually. Either accept that explicitly and cover it with a round-trip test, or split it into a typed `players` row plus two typed `:many` queries and pay one extra round trip (at DO LON1's 1–3 ms RTT that is ~4 ms, which the design's own latency argument makes affordable).

### PvP gold economics are inverted at both ends of the curve, and the shield rule is farmable by an alt account.

**Breaks because:** (a) With the design's flat ladder, 3% of a defender's bank almost always exceeds the opportunity cost of the energy, so attacking strictly dominates collecting — contradicting the brief's 'collect actions are the primary gold source'. With a corrected geometric ladder the opposite happens: at level 78, 15 energy is worth ~1,800 gold of collecting while 3% of a typical bank is ~1,300, so PvP becomes strictly worse and the tab dies. Neither end has a cap, so a whale who logs off holding a day's income is a farmable resource for everyone in their power band. (b) The shield is granted for *losing* a defence. An alt account with slightly higher power can attack the main, lose 3% of the main's gold to nobody's benefit but its own — then transfer it back — and the main gets a 30-minute shield on demand. `shield_grants.source` distinguishes `defense_loss` from `purchase`, and `devices.device_hash` exists for multi-account detection, but no rule connects them and there is no per-day cap on shields.

**Fix:** 1. Bound and floor the steal in the `pvp` config so it stays relevant without being farmable:
```jsonc
"steal": {
  "pct_milli": 3000,
  "min_gold_curve": {"kind":"geometric","base":40,"growth_milli":1120},   // by attacker level
  "max_gold_pct_of_attacker_hourly_milli": 400000                            // <= 4h of own income
}
```
Go clamps to `[min_curve.At(attacker.level), max]`. This keeps a level-5 attack worth taking and stops a level-40 player draining a whale in one hit.
2. Make items and reputation the endgame PvP reward, not gold: `item_source` already has `'battle'`, and `battles.rep_gained`/`xp_gained` exist. Add `"battle_item_drop": {"chance_milli": ..., "tier_weights": {...}}` to the `pvp` section (server-only, like `shop`), which is the thing that keeps the Attack tab alive at level 78.
3. Gate the loss-shield: grant it only when `gold_stolen >= min_steal_for_shield` **and** at most N per rolling 24 h, tracked with a partial index on the existing table — `CREATE INDEX shield_grants_recent_idx ON shield_grants (player_id, granted_at DESC) WHERE source = 'defense_loss';` — and add the same-`device_hash` attacker/defender pair as an automatic `player_anomaly_flags` rule (`rule = 'shield_farm'`), which the schema already supports.


## Missing coverage

- Almost every number the game actually needs is absent. The config sections name them but no values are given for: energy base max, energy regen seconds per point, `cfg.energy.per_stat_point`, the level XP curve, stat points per level, respec cost, gold cap, `cfg.tax.base_mgps`, `cfg.tax.per_soldier_mgps`, offline cap seconds, `cfg.hero.base_attack`/`base_defense`/`attack_per_point`/`defense_per_point`, `cfg.power.atk_weight_milli`/`def_weight_milli`, soldier type costs, soldier tier weight tables, soldier base stat tables, the shop price formula and reroll cost, and the kingdom founding cost / member cap curve / reputation rates. Roughly 25 numbers that the formulas in §3 and §5 dereference by name. A schema-and-balance design that specifies tiers, jobs and five family tracks and omits the rest is not shippable as a spec.
- The soldier SLOT price curve is an explicit brief requirement ('you must first buy a soldier SLOT with gold; each slot purchased makes the next slot more expensive') and appears nowhere. The `soldiers` config section is described as holding 'type costs, tier weight tables, base stat tables' — no slot cost curve. `player_soldier_slots.price_gold` exists as a column with nothing to populate it from.
- Diamond sinks have no prices. The brief names energy refills, protection, shop rerolls and premium packs; the `iap` config section is `sku → diamonds` only. `shield_grants.diamonds_paid`, `player_shop_state.rerolls_used` and `idempotency_keys` (scoped explicitly to 'diamond-spend endpoints') all exist to serve prices that are not defined anywhere. Needs a `diamonds` config section: energy_refill, shop_reroll, shield_30m, inventory_expand, respec, with the price for each.
- Batch collecting. At 1 energy/60s a player generates ~1,440 collects/day, and the design's request model is one HTTP round trip per collect with a strictly serialised `action_seq`. That is 1,440 taps and 1,440 round trips per player per day, and it is the single most-executed path in the game. `collect_events.collects` is an integer count, so batching is clearly anticipated, but no endpoint shape, no `cfg.collect.max_batch`, and — the part that is genuinely subtle — no statement of how the per-job milestone multiplier is applied when a batch crosses a threshold mid-way (it must be evaluated per collect inside the batch, or crossing 5,000 lifetime energy in the middle of a 200-energy batch silently mis-pays).
- The combat model itself. The design mandates integer-only math, specifies the replay encoding, sizes `battles.rounds` as a smallint and declares the `combat` config section client-visible — but never states how a fight resolves: turn order, how hero and N soldiers are paired, the damage formula, whether attack/defense are opposed rolls or a ratio, how `rounds` terminates, or how `rng_seed` is consumed. Without it the golden-file test in step 7 of the implementation order has nothing to test, and it is the highest-risk piece of the whole project.
- GDPR account deletion. The design correctly flags it as a risk (`iap_transactions` uses `ON DELETE RESTRICT`, so a DELETE always fails and deletion must be anonymisation) and then does not design it. Concretely unresolved: `players.display_name` is `citext NOT NULL UNIQUE` so anonymisation must generate a unique replacement; `leaderboard_entries.payload` freezes the name at build time and is never rewritten; `battles` rows reference the player id forever across 13 weeks of partitions; `devices.device_hash`, `sessions.ip` and `admin_audit_log.actor_email` all hold personal data with 'never dropped' retention. Needs a designed `anonymise_player(id)` procedure and a decision on what `player_state = 'deleted'` actually implies for each of those.
- No chat or kingdom messaging exists, yet `moderation_reports.reason` includes `'chat'` and `player_mail.kind` includes `'kingdom'`. Either a kingdom chat table is in scope (in which case it needs retention, rate limits and a moderation path, and it is a meaningful chunk of work) or the `'chat'` reason should be removed. A clan system with no communication channel is also a real product gap.
- `ALTER DEFAULT PRIVILEGES` is absent. 00017's `GRANT ... ON ALL TABLES IN SCHEMA public` covers only tables that exist when it runs. Every table added by migration 00018 onward will be inaccessible to `emperors_app` and `emperors_admin`, failing at runtime rather than at migration time.
- Inventory-full behaviour is undefined. `inventory_cap` defaults to 150 and selling is a hard DELETE, but nothing says what happens when a battle-won item, a `player_mail.rewards` item grant, or an admin grant arrives at a full inventory. Silently dropping it is a support ticket; blocking mail claim is a UX dead end; auto-selling needs a config'd rule. `is_locked` ('don't auto-sell') implies auto-sell was intended but it is never specified.
- `players.shield_until` and the `shield_grants` table are two sources of truth for the same fact and reconciliation between them is not in the `invariant_check` job (which covers member_count, ledger chain, soldiers-in-unpurchased-slots and orphaned equips). A purchase that inserts a grant but fails to bump `shield_until` is invisible until a player is attacked through a shield they paid diamonds for.
- The `player_shop_state` reroll semantics are unspecified: whether `reroll_index` incrementing clears `purchased_mask`, and how the row is reset when `epoch` advances (a purchase after an epoch rollover must not see the previous epoch's mask). Also `reroll_index` and `rerolls_used` are two counters that appear to encode the same thing.
- StoreKit 2 has no first-party Godot support. The IAP design depends on `appAccountToken`, which only exists in StoreKit 2; Godot's official iOS `InAppStore` plugin is StoreKit 1 and does not expose it. Working third-party options exist (godot-sdk-integrations/godot-storekit2, atlasapplications/godot-store-kit) but adopting one is a real dependency decision with its own Godot-version compatibility matrix, and the design presents `app_account_token` as if it were free. It should be listed as a prerequisite alongside the export template.

## Corrected recommendations

## What is genuinely sound — keep it unchanged

Do not spend revision effort here; these are correct and I verified the load-bearing ones:

- **The equipment model.** Pointer-on-item is right, and the argument that three nullable id columns on `soldiers` cannot express "one item, one holder" (three independent uniques do not compose) is correct. Constraints (a)–(e) are well chosen. `ON DELETE SET NULL (column_list)` is PG15+ and legal here because the listed column is a subset of the FK columns and `player_id` stays NOT NULL.
- **`FOR NO KEY UPDATE` over `FOR UPDATE`.** Correct: FK checks on child inserts take `FOR KEY SHARE`, which conflicts with `FOR UPDATE` but not with `FOR NO KEY UPDATE`.
- **`ORDER BY id ... FOR NO KEY UPDATE` for deadlock avoidance.** Correct — the planner places `LockRows` above `Sort` and will not push a locking clause below a Sort, so rows are locked in returned order.
- **pgx on the Neon pooler.** Correct and worth the emphasis: Neon's PgBouncer supports protocol-level prepared statements (PgBouncer ≥ 1.22, `max_prepared_statements=1000`), so keeping `QueryExecModeCacheStatement` is right and the common "downgrade to simple protocol" advice is obsolete. The unsupported list the design cites — `SET`/`RESET`, `PREPARE`/`DEALLOCATE`, `LISTEN`/`NOTIFY`, `WITH HOLD`, temp tables, session-level advisory locks — matches Neon's docs exactly, and `pg_advisory_xact_lock` is the right substitute.
- **Migrations on the direct endpoint**, runtime on the pooled one. Correct for the stated reasons.
- **`ALTER TYPE ... ADD VALUE` cannot be used in the transaction that adds it.** Correct, and the `-- +goose NO TRANSACTION` remedy is right.
- **`now()` is not IMMUTABLE in an index predicate.** Correct, and the design caught it itself.
- **Derived shop offers over stored offers**, **no-trigger power materialisation**, **generation-swapped snapshot leaderboards over a matview or Redis**, **`pg_cron` unavailable on Neon**, **bigint identity PKs over uuidv7**, **frozen rolled stats with `rolled_config_version`**, **kingdom membership as columns on `players`**, **energy not ledgered**. All correctly reasoned; keep.
- **Tier `price_mult ≈ stat_mult²`** (2.2 ≈ 1.45²) is a good convex chase-item curve. Keep the tier table as-is, including the epic/mystic resolution and the frame/glow colourblind fallback — that section is the strongest in the document.

## Revision order

The four blockers are independent and should be fixed before any code is written, because three of them invalidate work already planned:

1. **Rebalance (blocker 1)** before `cmd/emperors-seed` exists, because the seed embeds v1 and the whole point of the config system is that v1 is what every branch gets.
2. **Roles/grants/ownership (blockers 2 and 3)** before `goose up` is run once, because 00017 as written breaks both goose and `sqlc generate`.
3. **PRNG choice (blocker 4)** before the Go combat simulator, because the Go side must use `uint32` lanes to be mirrorable.

Then the majors, roughly in the implementation order the design already gives: the `last_seen_at`/HOT fix and the `player_pvp_targets` table land with step 2; the ledger `balance_after` fix with step 4; the `slot_index < 16` cap and `lifetime_energy` column with step 5; the shop `def_pool` with step 6; the `SettleAccrual` ordering rule with step 3; the leaderboard bucket table and the job lease with step 9.

## Corrected v1 balance (drop-in replacement for §2's three JSON blocks)

```jsonc
// section: economy   (this block does not exist in the design at all)
{
  "energy": { "base_max": 60, "regen_seconds_per_point": 60, "per_stat_point": 5 },
  "tax":    { "base_mgps": 300, "per_soldier_mgps": 60, "offline_cap_seconds": 28800 },
  "level":  { "xp_curve": {"kind":"polynomial","base":40,"exp_milli":1800},
              "stat_points_per_level": 3, "respec_cost_diamonds": 60 },
  "hero":   { "base_attack": 10, "base_defense": 10,
              "attack_per_point": 4, "defense_per_point": 4 },
  "power":  { "atk_weight_milli": 1000, "def_weight_milli": 800 },
  "gold_cap": 9000000000000000000
}
```

```jsonc
// section: collect_jobs   -- gold/energy x1.45 per rung, xp/energy x1.35 per rung
{
  "jobs": [
    {"key":"grapes",       "min_level": 1, "energy":  1, "gold":     2, "xp":    1},
    {"key":"strawberries", "min_level": 3, "energy":  2, "gold":     6, "xp":    3},
    {"key":"wheat",        "min_level": 6, "energy":  3, "gold":    13, "xp":    5},
    {"key":"olives",       "min_level":10, "energy":  5, "gold":    30, "xp":   12},
    {"key":"beeswax",      "min_level":15, "energy":  8, "gold":    71, "xp":   27},
    {"key":"quarry",       "min_level":21, "energy": 12, "gold":   154, "xp":   54},
    {"key":"ironworks",    "min_level":28, "energy": 18, "gold":   335, "xp":  109},
    {"key":"vineyard",     "min_level":36, "energy": 26, "gold":   701, "xp":  212},
    {"key":"saltworks",    "min_level":45, "energy": 38, "gold":  1485, "xp":  419},
    {"key":"goldmine",     "min_level":55, "energy": 55, "gold":  3117, "xp":  819},
    {"key":"armory",       "min_level":66, "energy": 80, "gold":  6574, "xp": 1609},
    {"key":"cathedral",    "min_level":78, "energy":115, "gold": 13702, "xp": 3121}
  ],
  "milestone_stacking": "cumulative",
  "milestones": [
    {"at_energy":   500, "gold_bonus_pct_milli":  5000},
    {"at_energy":  5000, "gold_bonus_pct_milli": 10000},
    {"at_energy": 50000, "gold_bonus_pct_milli": 15000}
  ],
  "max_batch": 50
}
```

```jsonc
// section: family_upgrades
{
  "effect_stacking": "additive",
  "tracks": [
    {"key":"granary",     "effect":"collect_gold_pct",  "max_level":25,
     "cost":{"kind":"geometric","base":  30,"growth_milli":1330}, "value":{"kind":"linear","base":0,"step":4000}},
    {"key":"treasury",    "effect":"tax_rate_pct",      "max_level":25,
     "cost":{"kind":"geometric","base":  50,"growth_milli":1330}, "value":{"kind":"linear","base":0,"step":6000}},
    {"key":"barracks",    "effect":"soldier_attack_pct","max_level":20,
     "cost":{"kind":"geometric","base": 300,"growth_milli":1420}, "value":{"kind":"linear","base":0,"step":6000}},
    {"key":"stable",      "effect":"max_energy_flat",   "max_level":20,
     "cost":{"kind":"geometric","base": 500,"growth_milli":1420}, "value":{"kind":"linear","base":0,"step":2}},
    {"key":"scriptorium", "effect":"xp_pct",            "max_level":20,
     "cost":{"kind":"geometric","base": 200,"growth_milli":1420}, "value":{"kind":"linear","base":0,"step":4000}}
  ]
}
```

Pacing this produces, at 100% energy utilisation (1,440 energy/day): L10 ≈ 3 days, L21 ≈ 17 days, L28 ≈ 30 days, L40 ≈ 58 days, L78 ≈ 169 days; lifetime gold/energy growth 59.6x; granary marginal payback rises 8 h → ~100 h across its 25 levels. Real players at 40–60% utilisation will be roughly 2x slower, which is the intended shape.

**The invariant to encode in the publish validator**, which is what actually prevents this class of bug recurring: for every track with an income-multiplier effect, `growth_milli^max_level` must fall within `[3x, 25x]` of the lifetime income-growth multiplier implied by the `collect_jobs` ladder (`gold_per_energy[last] / gold_per_energy[0]`). The original config sat at 20,700 vs 1.32 — a factor of ~15,000 outside the window — and a five-line check would have blocked it. This is a far better use of validator effort than the 30-day simulator.

## Migration-file changes, consolidated

| File | Change |
|---|---|
| `00005` | Delete `players_dormancy_idx`. Add `WITH (fillfactor = 80, autovacuum_vacuum_scale_factor = 0.02)`. |
| `00006` | Add `player_collect_progress.lifetime_energy bigint NOT NULL DEFAULT 0 CHECK (>= 0)`. |
| `00007` | `CHECK (slot_index >= 0 AND slot_index < 16)`. |
| `00009` | New `player_pvp_targets` table (see the attack-validation fix). Document the epoch-rollover reset of `purchased_mask`. |
| `00012` | Drop `balance_after` from `gold_ledger`; PK becomes `(player_id, created_at, seq)`. Keep `balance_after` on `diamond_ledger`. |
| `00013` | Populate `leaderboard_buckets` from generation 1; remove "not populated at launch". |
| `00015` | Add `job_runs.lease_owner uuid`, `job_runs.lease_until timestamptz`, `job_runs.cursor bigint`. |
| `00003` | Add `config_bundles.server_body_raw bytea NOT NULL`, `server_etag text NOT NULL`; add the `config_documents` immutability trigger; add the one-published-version partial unique index. |
| `00017` | Delete. Replace with a password-free grants migration plus `ALTER DEFAULT PRIVILEGES`, and a separate manual `scripts/bootstrap_roles.sql` run with `psql -v` against the direct endpoint. Add the fourth role `emperors_jobs` and `ALTER TABLE ... OWNER TO emperors_jobs` on all seven partitioned parents and their seeded partitions. Add the `REVOKE` block narrowing `emperors_admin`. |

## Smaller corrections worth folding in

- `is_equipped` is a STORED generated column the design then instructs you never to use in a predicate. It is one byte plus a recompute on the hottest table, purely so a client payload does not have to `OR` two fields in Go. Drop it.
- `LoadPlayerAggregate` takes `FOR NO KEY UPDATE` on a path the design also calls "load my entire game state". A row lock sets `xmax`, dirties the page and writes a WAL lock record on every home-screen open. Emit two sqlc queries from the same SQL — a locking one for mutations and a non-locking one for reads.
- The `players` column comment says `MinConns = 4 // keeps the Neon compute warm`. Neon suspends on five minutes with no *active queries*; idle connections do not count. The 10 s `config_active` poll is the actual keep-alive. Fix the comment so nobody later "optimises" the poll away.
- Use an explicit SipHash library (`github.com/dchest/siphash`) for `SHOP_SECRET`, not `hash/maphash` — Go's maphash seed is per-process random and its algorithm is explicitly not stable across releases, which would silently reshuffle every shop on deploy. Also replace `slot_seed = seed XOR (slot_index * 0x9E3779B97F4A7C15)` with a second SipHash over `seed ‖ slot_index`; XOR-mixing a multiplied constant leaves correlated low bits across slots, and the low bits are exactly what a modulo-based roll consumes.
- The etag is computed in SQL via `pgcrypto`'s `digest()`. Compute it in Go over the same bytes you are about to insert — it removes a round trip, removes the `pgcrypto` dependency for this purpose (PG has built-in `sha256(bytea)` anyway), and makes the digest verifiable client-side against the body it actually received.
- `battles` at 13-week retention is 41 M rows / ~7 GB at only 30k DAU, for a table whose read paths are "my last ~20 attacks", "who attacked me", and a kingdom feed. Cut to 4 weeks with the monthly rollup, and re-derive the storage table.
- Section cross-references are wrong throughout: `players.action_seq` says "see §7" (it is §5); `power_config_version` says "see §5" (it is §3); `admin_audit_log` and the config poll say "see §9" for scheduled jobs (they are in §7); the gold-leaderboard note says "(§6)" pointing at the storage section. Worth one pass before anyone implements from this.
- `content_item_defs.id` is a designer-assigned `smallint` PK while the seed uses `ON CONFLICT (key) DO NOTHING`. An admin-created def and a seed def can collide on `id` with different `key`s, producing a PK violation on deploy rather than a no-op. Either make `id` `GENERATED ALWAYS AS IDENTITY` and key everything off `key` (the config already references `key`), or make the seed `ON CONFLICT (id) DO UPDATE SET key = EXCLUDED.key, ...`.

## Critical files for implementation

- `/Users/yigitkarabulut/Developer/Emperors/db/migrations/00017_roles_and_grants.sql` — must be rewritten or deleted; as written it breaks both `goose up` and `sqlc generate`, and it is the root cause of the partition-maintenance blocker.
- `/Users/yigitkarabulut/Developer/Emperors/seed/config/v1/collect_jobs.json` and `.../family_upgrades.json` — the two files that carry the broken economy; replace with the corrected blocks above before `cmd/emperors-seed` publishes v1 to every branch.
- `/Users/yigitkarabulut/Developer/Emperors/internal/game/derive.go` — needs the new `SettleAccrual` entry point and the fixed call order (`Load` → `SettleAccrual` → mutate → `RecomputeDerived`), plus deterministic unit ordering for the replay encoder.
- `/Users/yigitkarabulut/Developer/Emperors/internal/game/rng.go` (and its GDScript twin) — must be xoshiro128** on masked 32-bit lanes, not PCG32; this is the single highest-risk file in the project.
- `/Users/yigitkarabulut/Developer/Emperors/db/migrations/00012_ledgers.sql` — `balance_after` and `seq` semantics on `gold_ledger` need to change before anything writes to it; retrofitting a ledger is exactly as miserable as the design says.
