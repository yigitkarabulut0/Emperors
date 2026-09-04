# Emperors — Admin Design

> Produced by an architecture pass on 2026-09-04 and adversarially reviewed.
> Owner decisions made *after* this document was written take precedence — see the build plan.

**Headline:** Build the Emperors admin panel as a Next.js 16 BFF that holds no database credentials at all — every read and write goes through a Go `/admin` API bound to the Docker network only, reachable exclusively through a Cloudflare Tunnel + Cloudflare Access, with the balance editor modelled as an immutable, hash-sealed, append-only-activated JSON config bundle whose simulator runs the real Go economy code.

---

## Emperors — Next.js Admin Panel: Complete Design

**Status:** greenfield. `/Users/yigitkarabulut/Developer/Emperors` is empty. Every path below is a path to create.
**Verified on this machine, 2026-09-04** (I queried npm, the Go module proxy, and the tools directly — these are not remembered numbers):

| Component | Version | How verified |
|---|---|---|
| Next.js | **16.3.4** (`latest`) | `npm view next dist-tags` |
| React / React DOM | 19.2.8 | npm |
| TypeScript | **7.0.2** (Go-native `tsc`) | npm |
| Tailwind CSS | 4.3.3 | npm |
| shadcn CLI | 4.21.0 | npm |
| TanStack Query / Table | 5.102.8 / **9.2.4** | npm |
| Zod | 4.5.4 | npm |
| Recharts | 3.10.1 | npm |
| openapi-typescript / openapi-fetch | 7.13.0 / 0.17.0 | npm |
| pnpm | 10.20.0 installed, **11.25.0** current | `pnpm --version`, npm |
| Go | 1.27.0 darwin/arm64 | `go version` |
| oapi-codegen | **v2.8.0** (OpenAPI 3.1 + strict server) | `~/go/bin/oapi-codegen --version` |
| sqlc / goose | v1.31.1 / v3.27.3 | `~/go/bin/...` |
| pgx | v5.10.0 | Go module proxy |
| chi | v5.3.2 | Go module proxy |
| go-redis | v9.22.0 | Go module proxy |
| pquerna/otp | v1.5.0 | Go module proxy |
| alexedwards/argon2id | v1.0.0 | Go module proxy |
| go-webauthn/webauthn | v0.18.0 (2026-08-27) | Go module proxy |
| Redis (local) | 8.6.2 (stopped) | `redis-server --version` |
| Docker / colima | 29.2.1 / **stopped** | `docker --version`, `colima status` |

Two Next.js 16 facts that change the design and are easy to get wrong:
1. **`middleware.ts` is now `proxy.ts`.** The exported function is `proxy`, the runtime is `nodejs` and is not configurable, and **a leftover `middleware.ts` is silently ignored at build time** — protected routes become publicly reachable with no error. ([Next.js 16](https://nextjs.org/blog/next-16), [upgrade guide](https://nextjs.org/docs/app/guides/upgrading/version-16))
2. **TypeScript 7.0 shipped without the programmatic JS API** (it lands in 7.1), so Next.js had to invoke `tsc` directly. That is behind `experimental.useTypeScriptCli` in Next 16.3. ([InfoQ](https://www.infoq.com/news/2026/08/typescript-7-released/), [vercel/next.js#95633](https://github.com/vercel/next.js/discussions/95633)) → **Pin TypeScript to the 6.x line for the panel** and treat TS 7 as an opt-in speed experiment later. Do not start a security-critical project on an experimental compiler path.

---

## 1. The central architecture decision: API-only, zero DB credentials in the web tier

### The choice
The panel talks **exclusively to the Go `/admin` API**. The Next.js container has **no `DATABASE_URL`, no Drizzle, no Prisma, no `pg`**. Not for writes, not for reads, not for the dashboard.

### Why (the arguments that actually decide it)

**1. The audit log must be in the same transaction as the mutation.** The brief demands "a complete audit log of every admin action with before/after values." If Next.js writes gold with Drizzle and then POSTs an audit row, a crash between the two produces an unlogged currency grant — exactly the event the audit log exists to catch. Only the process that owns the transaction can guarantee the pair. That process is Go.

**2. Invariants are not expressible in a table write.** "Grant 5000 gold" is not `UPDATE player SET gold = gold + 5000`. It is: append a `econ.gold_ledger` row with the correct `reason` and `balance_after`, stamp the active `balance_version`, bust the player's cached state, and possibly trip an economy alarm. "Ban a player" is: set the flag, revoke live sessions in Redis, cancel their outgoing shield, and remove them from the attack matchmaking pool. A second writer that knows only the schema will corrupt these invariants within weeks.

**3. Two ORMs over one schema guarantees drift.** Go uses sqlc + goose. A Drizzle schema is a hand-maintained copy that will silently diverge on the first migration someone forgets to mirror. sqlc already fails the Go build on schema drift; Drizzle would not.

**4. Security: this is the single largest blast-radius reduction available.** A `DATABASE_URL` in the web tier means one RCE in a Next.js dependency (the panel will carry ~600 transitive packages) equals total game-database compromise — read every account, mint unlimited gold, delete the audit log. Without it, the same RCE gets an attacker exactly the permissions of whichever admin session it can steal, and **every action it takes is written to a hash-chained audit log it cannot reach**. That is the difference between an incident and a company-ending event.

**5. Neon connection budget.** Neon runs PgBouncer in transaction mode with `max_client_conn = 10000`, but the pool to Postgres is 90% of `max_connections`, which scales with compute size ([Neon docs](https://neon.com/docs/connect/connection-pooling)). Adding a second independent pool from the web tier for no functional gain is pure waste on a metered compute.

### The honest cost, and how it is paid
The real argument *for* direct DB access is ad-hoc analytics: "gold per hour by level bucket for players who joined last Tuesday" is painful as REST. Three mechanisms pay that cost:

- **`POST /admin/analytics/query`** — a small set of *server-defined, named* aggregate queries with typed parameters (`{ metric, from, to, group_by, filters }`). Go owns the SQL; the panel owns only the parameters. Covers ~95% of dashboard needs.
- **Daily rollup tables** (`analytics.daily_kpi`, `analytics.player_day`) computed by a Go cron. The dashboard reads pre-aggregated rows, so it is fast and cheap regardless of player count.
- **An owner-only SQL console** (`/tools/sql`) that POSTs raw SQL to Go, which executes it **on a Neon read replica** as a distinct read-only Postgres role with `default_transaction_read_only = on`, `statement_timeout = 10s`, `SET ROLE emperors_analyst`, no `SELECT` grant on `admin.*` or `billing.receipt_raw`, a 10k-row cap, and a full audit entry containing the query text. The escape hatch exists — and it is still owned, constrained, and logged by Go.

Neon read replicas are the right home for this: they are independent read-only computes over the same storage, explicitly recommended for "offloading resource-intensive analytics and reporting workloads," same-region only, eventually consistent, max 3 on the free plan ([Neon read replicas](https://neon.com/docs/introduction/read-replicas)).

**Rejected:** Drizzle for reads + API for writes ("read-only creds are safe"). It is not safe — a read-only credential still exposes every player's email, every receipt, and the entire `admin.audit_log`, and it re-introduces schema drift for zero latency benefit once rollup tables exist.

---

## 2. Hosting and network topology

### Recommendation: co-locate on the VPS, expose via Cloudflare Tunnel + Cloudflare Access. Do not host on Vercel.

```
                    ┌─────────────────────────────────────────┐
   players ────────▶│ Caddy :443  emperors-api.example.com    │
   (iOS Godot)      │   └─▶ api:8080   (game API, /v1/*)      │
                    │                                          │
   owner/mods ─┐    │ cloudflared (outbound only, no ingress) │
               │    │   └─▶ admin-web:3000                     │
               │    │                                          │
               │    │ admin-api:8081  ← NO ports: mapping      │
               │    │ redis:6379      ← NO ports: mapping      │
               │    └─────────────────────────────────────────┘
               │                        │
               │                        ▼
               │              Neon eu-west-2 (primary + read replica)
               │
     Cloudflare Access (identity gate)
     admin.emperors.example
```

**Key structural decision: two listeners from one Go binary.**
- `:8080` — the public game API, `/v1/*`, published by Caddy.
- `:8081` — the admin API, `/admin/*`, with **no `ports:` entry in compose**. It is reachable only from `admin-web` on the Docker bridge network. The admin API does not listen on a public interface at all. No amount of misconfigured routing can expose it, because there is no route.

Two separate `http.Server` instances, two separate chi routers, two separate OpenAPI specs. This also means the game-client TypeScript/GDScript codegen physically cannot see admin endpoints.

**Cloudflare Tunnel means zero inbound firewall rules for the panel.** `cloudflared` dials out to Cloudflare; the VPS firewall allows only 443 (game API) and SSH-on-key. Cloudflare Tunnel is free with no usage limits; **Cloudflare Zero Trust Access is free up to 50 users** with full ZTNA (24h log retention on free) ([Cloudflare pricing 2026](https://costbench.com/software/business-vpn/cloudflare-zero-trust/)).

Cloudflare Access injects a signed JWT in the **`Cf-Access-Jwt-Assertion`** header on every request ([Cloudflare One docs](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/linked-app-token/)). The Go admin API **verifies this JWT against Cloudflare's JWKS and rejects any request without it** in production. That is a hard network-layer gate that is completely independent of application auth.

### Why not Vercel
Hosting on Vercel forces the Go admin API to be publicly reachable so Vercel's servers can call it. That converts the single strongest control in this design (an admin API with no public interface) into a hostname on the internet defended by a bearer token. You would then need Access service tokens or mTLS to re-create what the Docker network gave you for free. Vercel also adds egress from us-east to a London Neon and a London VPS for every dashboard query. **Vercel is the right host for a marketing site or the game's landing page. It is the wrong host for a console that mints currency.**

Trade-off accepted: no preview deployments, no zero-config CI. Mitigated by a two-line GitHub Action (§13). This is a 1–5 person console; preview deploys are not worth a public admin API.

### Where the VPS should be
Neon is in **eu-west-2 (London)**. Every request in this game hits Postgres several times. **DigitalOcean LON1** puts the VPS within a few ms of Neon; Hetzner has no London region, so Falkenstein/Helsinki adds ~15–25ms *per query*. For dashboard aggregates that run 10–30 queries, that is 0.3–0.75s of pure latency per page load. **Recommend DigitalOcean LON1** unless cost strictly dominates. (Flagged as an owner question.)

---

## 3. Admin authentication — owned by Go, not by Next.js

### Decision: Go owns identity, sessions, 2FA, RBAC. Next.js holds only a cookie.

This follows inevitably from §1. If Go must write the audit row inside the mutation's transaction, Go must know **who** the actor is. Any design where Next.js authenticates and then *asserts* an identity to Go creates a second trust boundary and a token-minting service to secure. Go authenticating directly means there is exactly one place that decides "is this person allowed to do this," and it is the same place that performs the action.

**Rejected: Better Auth 1.7.** It is genuinely excellent — TOTP secrets encrypted with the auth secret, a proper partial-auth `better-auth.two_factor` cookie with a 10-minute window, an admin plugin with RBAC and impersonation, and `npx auth create-admin` ([Better Auth 1.7](https://better-auth.com/blog/1-7), [2FA docs](https://better-auth.com/docs/plugins/2fa)). If the whole stack were TypeScript I would use it without hesitation. Here it would put the identity tables in the game database managed by a *second* migration tool, and still leave Go needing to independently validate every session. The Go equivalent is ~500 lines using libraries that are already the ecosystem standard.

### Schema

```sql
create schema if not exists admin;

create table admin.admin_user (
  id                bigint primary key generated always as identity,
  public_id         uuid not null unique default uuidv7(),   -- PG18; used in URLs
  email             citext not null unique,
  display_name      text   not null,
  password_hash     text   not null,          -- argon2id, PHC string
  role              text   not null references admin.role(name),
  status            text   not null default 'active'
                      check (status in ('active','suspended','disabled')),
  totp_secret_enc   bytea,                    -- AES-256-GCM, key from env, never leaves Go
  totp_confirmed_at timestamptz,
  recovery_codes    text[] not null default '{}',  -- argon2id hashes, single-use
  failed_attempts   int    not null default 0,
  locked_until      timestamptz,
  password_changed_at timestamptz not null default now(),
  last_login_at     timestamptz,
  created_by        bigint references admin.admin_user(id),
  created_at        timestamptz not null default now()
);

create table admin.role (
  name        text primary key,               -- owner|game_designer|moderator|support|analyst|read_only
  description text not null,
  permissions text[] not null
);

create table admin.webauthn_credential (
  id             bigint primary key generated always as identity,
  admin_id       bigint not null references admin.admin_user(id) on delete cascade,
  credential_id  bytea not null unique,
  public_key     bytea not null,
  sign_count     bigint not null default 0,
  aaguid         uuid,
  transports     text[] not null default '{}',
  backup_eligible boolean not null default false,
  nickname       text not null default '',
  created_at     timestamptz not null default now(),
  last_used_at   timestamptz
);

create table admin.session (
  id              bigint primary key generated always as identity,
  token_hash      bytea not null unique,       -- sha256 of a 32-byte CSPRNG token
  admin_id        bigint not null references admin.admin_user(id) on delete cascade,
  ip              inet not null,
  user_agent      text not null,
  cf_access_sub   text,                        -- 'sub' from Cf-Access-Jwt-Assertion
  amr             text[] not null,             -- ['pwd','totp'] or ['pwd','webauthn']
  created_at      timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  absolute_expires_at timestamptz not null,    -- created_at + 8h
  step_up_until   timestamptz,                 -- re-auth window for destructive ops
  revoked_at      timestamptz,
  revoked_reason  text
);
create index on admin.session (admin_id) where revoked_at is null;

create table admin.ip_allowlist (
  id         bigint primary key generated always as identity,
  cidr       cidr not null,
  label      text not null,
  enabled    boolean not null default true,
  added_by   bigint not null references admin.admin_user(id),
  added_at   timestamptz not null default now()
);

create table admin.login_attempt (          -- brute-force forensics, retained 90d
  id bigint primary key generated always as identity,
  email citext, ip inet not null, ua text,
  outcome text not null check (outcome in
    ('ok','bad_password','bad_totp','locked','ip_blocked','no_cf_jwt','unknown_user')),
  at timestamptz not null default now()
);
create index on admin.login_attempt (ip, at desc);
```

### Password hashing
**argon2id** via `github.com/alexedwards/argon2id v1.0.0`. Parameters, tuned to ~250ms on the target VPS (measure with a benchmark, do not copy blindly):

```go
var adminHashParams = &argon2id.Params{
    Memory:      64 * 1024, // 64 MiB
    Iterations:  3,
    Parallelism: 2,
    SaltLength:  16,
    KeyLength:   32,
}
```
Store the full PHC string so parameters can be raised later and rehashed transparently on successful login. Minimum 16 characters, checked against a bundled top-100k breached-password list (offline; do not call HIBP from the server).

### Second factor — passkey preferred, TOTP as the floor
- **Primary: WebAuthn passkey** via `github.com/go-webauthn/webauthn v0.18.0` (the maintained successor to the archived `duo-labs/webauthn`, last released 2026-08-27; still v0.x so pin exactly). A hardware-backed passkey is phishing-resistant; TOTP is not. On a macOS/iPhone-owning solo owner, Touch ID/Face ID passkeys are also the *easier* UX.
- **Fallback: TOTP** via `github.com/pquerna/otp v1.5.0`, RFC 6238, SHA-1, 6 digits, 30s, ±1 step skew. Secret encrypted at rest with AES-256-GCM under `ADMIN_TOTP_KEY`. **Store `last_used_totp_step` per admin and reject replay of the same step** — a surprising number of implementations skip this.
- **10 single-use recovery codes**, argon2id-hashed, shown exactly once, invalidated in bulk on regeneration.
- **2FA is mandatory.** No role can skip it. An admin without a confirmed second factor can reach only `/settings/security` and nothing else.

### Session strategy
Opaque random tokens, **not JWTs**. A ban or a compromised laptop must be revocable *now*; a stateless JWT cannot be.

- 32 bytes from `crypto/rand`, base64url-encoded. **Only the SHA-256 hash is stored** — a database leak does not yield live sessions.
- Cookie: `__Host-emp_admin`, `HttpOnly`, `Secure`, `SameSite=Strict`, `Path=/`, no `Domain`. The `__Host-` prefix is enforced by the browser and prevents a subdomain from setting it.
- **8h absolute** expiry, **30m idle** expiry, token **rotated on every privilege change** and on 2FA completion.
- **Step-up re-auth**: destructive actions (grant/remove currency, ban, wipe, balance publish, refund, impersonate) require `step_up_until > now()`. The step-up is a fresh passkey assertion or TOTP code, valid for **5 minutes**. This is what makes a stolen session cookie insufficient for the actions that matter.
- **Soft binding**: session records IP and a UA hash. A change forces step-up re-auth rather than a hard kill (mobile networks rotate IPs; a hard kill trains users to hate the tool). Record `/24` (v4) or `/48` (v6) prefixes, not exact IPs.
- `/settings/sessions` lists live sessions with IP, UA, location, and a "revoke all others" button.

### IP allowlist
`admin.ip_allowlist` holds CIDRs, checked in Go using `netip.Prefix.Contains`. **Fail-closed with one deliberate escape hatch**: if the table is empty, the allowlist is disabled and a loud banner appears in the UI; if it is non-empty and the client IP does not match, reject with 403 before password verification (and log to `admin.login_attempt`). The client IP comes from Cloudflare's `CF-Connecting-IP`, trusted **only** when the request also carries a valid `Cf-Access-Jwt-Assertion` — otherwise use `RemoteAddr`. Never trust `X-Forwarded-For` blindly.

Honest caveat: with Cloudflare Access already in front, the IP allowlist is a third layer of marginal value and a real lockout risk when the owner travels. **Ship it, default it off, document the recovery path** (`emperors-admin unlock --email …` on the VPS over SSH).

### RBAC

Six roles. The brief named four; two more are justified below.

| Permission | owner | game_designer | moderator | support | analyst | read_only |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| `player.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `player.grant_currency` | ✓ | – | – | ✓ (capped) | – | – |
| `player.remove_currency` | ✓ | – | – | – | – | – |
| `player.force_level` | ✓ | ✓ (staging) | – | – | – | – |
| `player.reset_shield` | ✓ | – | ✓ | ✓ | – | – |
| `player.rename` | ✓ | – | ✓ | ✓ | – | – |
| `player.ban` / `mute` | ✓ | – | ✓ | – | – | – |
| `player.wipe` | ✓ | – | – | – | – | – |
| `player.impersonate_ro` | ✓ | ✓ | ✓ | ✓ | – | – |
| `player.impersonate_rw` | ✓ | – | – | – | – | – |
| `balance.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `balance.edit` | ✓ | ✓ | – | – | – | – |
| `balance.publish` | ✓ | ✓ | – | – | – | – |
| `balance.rollback` | ✓ | ✓ | – | – | – | – |
| `ops.publish` | ✓ | ✓ | – | – | – | – |
| `mod.action` | ✓ | – | ✓ | ✓ | – | – |
| `econ.read` | ✓ | ✓ | – | – | ✓ | ✓ |
| `billing.read` | ✓ | – | – | ✓ | ✓ | – |
| `billing.refund` | ✓ | – | – | – | – | – |
| `admin.manage` | ✓ | – | – | – | – | – |
| `audit.read` | ✓ | ✓(own) | ✓(own) | ✓(own) | ✓ | – |
| `sql.readonly` | ✓ | – | – | – | – | – |

**Why `game_designer` exists:** balance publishing is the single highest-blast-radius action in the game and has nothing to do with moderation or currency. Bundling it into `owner` means the owner has to do it personally forever; bundling it into `moderator` means anyone who handles a name report can rewrite the economy. It is its own axis.

**Why `support` exists:** the person who answers "I bought diamonds and didn't get them" needs `player.grant_currency` and nothing else — and needs it *capped*.

**Grant caps and the two-person rule.** `support` may grant ≤10,000 gold or ≤100 diamonds per action, ≤5 actions/hour, ≤50,000 gold/day. Anything larger creates a row in `admin.approval_request` that an `owner` must approve in `/settings/approvals`; the mutation is executed by Go only on approval, and the audit row names **both** admins. Caps live in `admin.role.permissions` as structured limits so they are editable without a deploy.

### Audit log — tamper-evident by construction

```sql
create table admin.audit_log (
  id            bigint primary key generated always as identity,
  actor_id      bigint not null references admin.admin_user(id),
  actor_email   text   not null,     -- denormalized: survives admin deletion
  actor_role    text   not null,     -- role AT THE TIME of the action
  actor_ip      inet   not null,
  actor_ua      text   not null,
  cf_access_sub text,
  session_id    bigint,
  action        text   not null,     -- 'player.grant_gold', 'balance.publish', ...
  target_type   text   not null,     -- 'player' | 'balance_version' | 'kingdom' | ...
  target_id     text   not null,
  reason        text   not null,     -- REQUIRED, min 10 chars, from the UI
  before        jsonb,
  after         jsonb,
  diff          jsonb,               -- normalized [{path,before,after}]
  approved_by   bigint references admin.admin_user(id),
  request_id    text   not null,
  status        text   not null check (status in ('ok','denied','error')),
  error         text,
  created_at    timestamptz not null default now(),
  prev_hash     bytea not null,
  entry_hash    bytea not null
) partition by range (created_at);

create index on admin.audit_log (created_at desc);
create index on admin.audit_log (actor_id, created_at desc);
create index on admin.audit_log (target_type, target_id, created_at desc);
create index on admin.audit_log (action, created_at desc);
create index on admin.audit_log using gin (diff jsonb_path_ops);

-- The application role may INSERT and SELECT. It may never rewrite history.
revoke update, delete, truncate on admin.audit_log from emperors_app;
```

`entry_hash = sha256(prev_hash || canonical_json(row minus hash columns))`. A nightly job verifies the chain end-to-end and exports the previous day to append-only object storage with the day's terminal hash. **Deleting or editing a row breaks the chain and is detected within 24 hours** — including by someone with full database access. Combined with the `revoke`, this is genuine non-repudiation, not decoration.

Retention: `ok` entries 3 years (partitioned monthly, older partitions detached to cold storage), `denied`/`error` 1 year.

**The Go helper that makes "always audited" the path of least resistance:**

```go
// internal/audit/audit.go
package audit

type Entry struct {
    Action, TargetType, TargetID, Reason string
    Before, After any
    ApprovedBy    *int64
}

// Do runs fn inside one transaction and appends exactly one audit row.
// The audit row commits atomically with the mutation: if the mutation rolls
// back the log rolls back with it, and if the log insert fails the mutation
// is rolled back. There is no code path that mutates without logging.
func Do(ctx context.Context, db *pgxpool.Pool, ac *Actor, e *Entry,
    fn func(ctx context.Context, tx pgx.Tx, e *Entry) error) error {

    tx, err := db.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
    if err != nil {
        return err
    }
    defer tx.Rollback(ctx) //nolint:errcheck // no-op after commit

    if err := fn(ctx, tx, e); err != nil {
        // Failed/denied attempts are still evidence. Written on a separate
        // connection so the rollback above cannot erase them.
        writeOutcome(context.WithoutCancel(ctx), db, ac, e, statusFor(err), err)
        return err
    }
    if err := insertTx(ctx, tx, ac, e, "ok", nil); err != nil {
        return fmt.Errorf("audit: %w", err) // aborts the mutation. Intentional.
    }
    return tx.Commit(ctx)
}
```

Usage — note **PostgreSQL 18's `OLD`/`NEW` in `RETURNING`**, which makes before/after capture a single round trip with no race ([PG18 release notes](https://www.postgresql.org/docs/current/release-18.html)):

```go
func (s *PlayerService) GrantGold(ctx context.Context, ac *audit.Actor,
    playerID int64, amount int64, reason string) error {

    if err := ac.RequireStepUp(); err != nil { return err }
    if err := ac.RequirePermission("player.grant_currency"); err != nil { return err }
    if err := s.caps.Check(ctx, ac, "gold", amount); err != nil { return err } // may raise approval

    e := &audit.Entry{
        Action: "player.grant_gold", TargetType: "player",
        TargetID: strconv.FormatInt(playerID, 10), Reason: reason,
    }
    return audit.Do(ctx, s.db, ac, e, func(ctx context.Context, tx pgx.Tx, e *audit.Entry) error {
        var before, after int64
        err := tx.QueryRow(ctx, `
            update game.player set gold = gold + $2, updated_at = now()
             where id = $1
            returning old.gold, new.gold`, playerID, amount).Scan(&before, &after)
        if errors.Is(err, pgx.ErrNoRows) { return ErrPlayerNotFound }
        if err != nil { return err }

        if _, err := tx.Exec(ctx, `
            insert into econ.gold_ledger
                (player_id, delta, balance_after, reason, ref_type, ref_id, balance_version)
            values ($1, $2, $3, 'admin_grant', 'admin', $4, $5)`,
            playerID, amount, after, ac.AdminID, s.balance.Current().Seq); err != nil {
            return err
        }
        e.Before = map[string]any{"gold": before}
        e.After  = map[string]any{"gold": after}
        return nil
    })
}
```

---

## 4. Project layout

```
/Users/yigitkarabulut/Developer/Emperors/
├─ api/                              # Go 1.27 module — game server + admin API
│  ├─ cmd/emperors/main.go
│  ├─ openapi/game.v1.yaml           # public spec  -> :8080
│  ├─ openapi/admin.v1.yaml          # admin spec   -> :8081  (never shipped to client)
│  ├─ openapi/admin.cfg.yaml         # oapi-codegen config
│  ├─ internal/adminapi/server.gen.go        (generated, checked in)
│  ├─ internal/adminapi/handlers_*.go
│  ├─ internal/admin/{auth,session,rbac,caps}.go
│  ├─ internal/audit/audit.go
│  ├─ internal/balance/{doc.go,store.go,validate.go,publish.go,diff.go,canonical.go}
│  ├─ internal/economy/economy.go    # the ONE implementation of every formula
│  ├─ internal/sim/sim.go            # simulator; imports economy, never re-implements it
│  ├─ internal/jobs/{rollup.go,alarms.go,namesweep.go,auditchain.go}
│  ├─ db/migrations/*.sql            # goose
│  └─ db/query/*.sql                 # sqlc
├─ admin/                            # Next.js 16 panel
│  ├─ proxy.ts
│  ├─ next.config.ts
│  ├─ components.json
│  └─ src/…                          (see §5)
├─ client/                           # Godot 4.7.2 GDScript
├─ ops/{compose.yml,compose.dev.yml,Caddyfile,cloudflared/config.yml}
└─ .github/workflows/{ci.yml,deploy.yml}
```

### Next.js setup

```bash
pnpm create next-app@16.3.4 admin \
  --ts --app --tailwind --eslint --src-dir --import-alias "@/*" --turbopack
cd admin && pnpm dlx shadcn@4 init
```

`admin/package.json` essentials:
```jsonc
{
  "packageManager": "pnpm@11.25.0",
  "dependencies": {
    "next": "16.3.4", "react": "19.2.8", "react-dom": "19.2.8",
    "@tanstack/react-query": "5.102.8", "@tanstack/react-table": "9.2.4",
    "openapi-fetch": "0.17.0", "zod": "4.5.4", "nuqs": "2.10.1",
    "recharts": "3.10.1", "lucide-react": "1.41.0",
    "date-fns": "*", "server-only": "*", "sonner": "*"
  },
  "devDependencies": {
    "typescript": "~6.9",                 // NOT 7.x — see §0
    "tailwindcss": "4.3.3", "openapi-typescript": "7.13.0", "shadcn": "4.21.0"
  }
}
```

`admin/pnpm-workspace.yaml`:
```yaml
minimumReleaseAge: 10080   # 7 days. pnpm 11 defaults to 1440; a currency-minting
                           # console should not install week-old-or-newer packages.
blockExoticSubdeps: true   # no git/tarball transitive deps
```
([pnpm supply-chain docs](https://pnpm.io/supply-chain-security))

**Styling: Tailwind 4 + shadcn/ui.** Not a debate worth having — shadcn gives copy-in-tree components (auditable, no black-box dependency, patchable), Radix primitives give real keyboard/ARIA behaviour for the dialogs that gate destructive actions, and the CLI now supports private GitHub registries so a shared component set is easy later. Dark theme by default: this tool is used at night, next to a game with a dark medieval palette.

**Charts: Recharts 3.10.1** wrapped in shadcn's `Chart` primitives. Enough for time series, stacked faucet/sink bars, and cohort heatmaps. If the retention heatmap gets awkward, hand-roll it as a CSS grid rather than adding a second charting library.

### Data fetching strategy — a rule, not a vibe

| Kind of data | Mechanism | Why |
|---|---|---|
| Page-level reads (player detail, balance version, kingdom) | **Server Component** → `openapi-fetch` with the forwarded cookie | No client bundle cost, no waterfall, secrets stay server-side |
| Tables with sort/filter/page | Server Component reading **`searchParams`**, URL synced by `nuqs` | Shareable/bookmarkable URLs — "look at this player list" is a real workflow |
| Anything that refreshes on a timer | **TanStack Query** in a Client Component, hydrated from the RSC render | `refetchInterval`, stale-while-revalidate, no flash |
| Every mutation | **Server Action** → `openapi-fetch` → Go | One authenticated path; Go re-checks authz |
| Alarms, other admins' actions | **One SSE stream** (§12) | Someone else's change must interrupt you |

**Cache Components (`use cache`) are OFF for this app.** In Next 16, `use cache` / `cacheLife` / `cacheTag` are stable and are the successors to `revalidate` and `unstable_cache` ([Next.js 16](https://nextjs.org/blog/next-16)). They are the wrong tool here: every page is per-admin, permission-filtered, and must be fresh — a cached player balance shown to a moderator deciding on a ban is a bug. The only exceptions are the two genuinely global, expensive, non-sensitive reads:

```ts
// src/lib/data/kpi.ts
import { cacheLife, cacheTag } from "next/cache";

export async function getDailyKpis(from: string, to: string) {
  "use cache";
  cacheLife({ revalidate: 300, expire: 900 }); // rollups update hourly at best
  cacheTag("kpi");
  return api.GET("/admin/analytics/daily-kpi", { params: { query: { from, to } } });
}
```

---

## 5. Routes and components

```
src/app/
├─ (auth)/login/page.tsx                    email + password
├─ (auth)/login/2fa/page.tsx                TOTP / recovery code
├─ (auth)/login/passkey/page.tsx            WebAuthn assertion
├─ (auth)/locked/page.tsx                   IP-blocked / no CF JWT explainer
├─ (app)/layout.tsx                         AppShell: sidebar, command palette, SSE, actor ctx
│  ├─ page.tsx                              Dashboard
│  ├─ players/page.tsx                      search
│  ├─ players/[publicId]/layout.tsx         PlayerHeader + tabs
│  │   ├─ page.tsx                          overview + actions
│  │   ├─ inventory/page.tsx
│  │   ├─ soldiers/page.tsx
│  │   ├─ battles/page.tsx
│  │   ├─ ledger/page.tsx
│  │   ├─ purchases/page.tsx
│  │   └─ audit/page.tsx                    everything admins did TO this player
│  ├─ balance/page.tsx                      version list + live badge
│  │   ├─ [versionId]/layout.tsx            editor shell (section tabs)
│  │   │   ├─ constants/ jobs/ items/ tiers/ shop/ soldiers/ upgrades/ kingdom/
│  │   │   ├─ diff/page.tsx                 ?against=<id>
│  │   │   └─ simulate/page.tsx
│  │   └─ history/page.tsx                  activation log + rollback
│  ├─ economy/page.tsx                      faucets vs sinks
│  │   ├─ holders/page.tsx   alarms/page.tsx   flags/page.tsx
│  ├─ battles/page.tsx  battles/[id]/page.tsx
│  ├─ kingdoms/page.tsx kingdoms/[id]/page.tsx
│  ├─ liveops/announcements/[…]  liveops/events/[…]
│  ├─ moderation/page.tsx  moderation/reports/[id]  moderation/names
│  ├─ billing/purchases  billing/refunds
│  ├─ audit/page.tsx
│  ├─ settings/{admins,roles,sessions,ip-allowlist,approvals,security}
│  └─ tools/sql/page.tsx                    owner only
└─ api/
   ├─ auth/[...path]/route.ts               proxy to Go (Set-Cookie passthrough)
   ├─ stream/route.ts                       SSE proxy
   └─ export/[report]/route.ts              streamed CSV passthrough
```

Key components:
```
components/
├─ data-table/{DataTable,DataTableToolbar,DataTablePagination,DataTableFacetedFilter}.tsx
├─ kpi/{KpiCard,KpiSparkline,KpiGrid,RetentionHeatmap}.tsx
├─ player/{PlayerHeader,StateSummary,GrantCurrencyDialog,BanDialog,
│           ForceLevelDialog,WipeDialog,ImpersonateDialog,LedgerTable}.tsx
├─ balance/{BalanceEditorShell,ConstantsForm,JobsTable,TierCurveEditor,
│            WeightsEditor,ItemDefsTable,UpgradeCurveEditor,CurvePreviewChart,
│            DiffViewer,RiskBadge,PublishDialog,SimulatorPanel,DraftStatusBar}.tsx
├─ economy/{FaucetSinkChart,FlowTable,AlarmList,TopHoldersTable,GiniGauge}.tsx
├─ battle/{BattleLogViewer,ReplayVerifyBanner,SnapshotPanel}.tsx
├─ liveops/{AnnouncementForm,EventForm,AudiencePicker,SchedulePreview}.tsx
├─ moderation/{ReportQueue,ReportDetail,NameRuleTable,NameTester}.tsx
├─ audit/{AuditFeed,AuditEntry,DiffChips}.tsx
└─ common/{DangerConfirm,StepUpDialog,ReasonField,PermissionGate,
            CopyableId,RelativeTime,CommandPalette}.tsx
```

Two of these carry disproportionate weight:

- **`DangerConfirm`** — used by every destructive action. Shows the target's identity re-fetched *at confirm time* (name, level, gold), the exact delta, requires typing the target's **name** (not "DELETE" — typing the name proves you looked at the right row), requires a reason ≥10 chars, and triggers `StepUpDialog`. This is the primary defence against the realistic failure mode: wiping the wrong account because two rows looked alike.
- **`PermissionGate`** — hides/disables UI by permission. Explicitly **cosmetic**; the comment in the file says so, and Go re-checks. It exists so moderators do not see buttons that will 403.

`lib/`:
```
lib/api/{client.ts, schema.gen.ts, errors.ts}
lib/auth/{session.ts, guard.ts, permissions.ts}
lib/balance/{schema.ts, diff.ts, risk.ts, paths.ts, format.ts}
lib/query/{provider.tsx, keys.ts}
lib/format/{numbers.ts, duration.ts, currency.ts}
```

### AppShell sketch

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ⚔ EMPERORS ADMIN   [⌘K search…]         ● 412 online   owner@… ▾  [◐]     │
├──────────────┬─────────────────────────────────────────────────────────────┤
│ ◆ Dashboard  │                                                             │
│ ◆ Players    │                                                             │
│ ◆ Balance ● 2│   ← ● = unpublished draft count                              │
│ ◆ Economy ⚠1 │   ← ⚠ = firing alarms                                        │
│ ◆ Battles    │                        (page content)                       │
│ ◆ Kingdoms   │                                                             │
│ ◆ Live Ops   │                                                             │
│ ◆ Moderation⁷│   ← open report count                                        │
│ ◆ Billing    │                                                             │
│ ◆ Audit      │                                                             │
│ ◆ Settings   │                                                             │
├──────────────┴─────────────────────────────────────────────────────────────┤
│ LIVE  17:42 gd@ published balance v42 · 17:39 mod@ banned "Xx_Slayer"       │  ← SSE
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Dashboard — every metric with its exact source

### Analytics schema

```sql
create schema if not exists analytics;

-- Written by Go on session close (or by a sweeper for abandoned sessions).
create table analytics.session_event (
  id bigint primary key generated always as identity,
  player_id bigint not null,
  started_at timestamptz not null,
  ended_at   timestamptz,
  duration_s int,
  platform   text not null,          -- 'ios' | 'android'
  app_version text not null,
  country    char(2)
) partition by range (started_at);
create index on analytics.session_event (started_at);
create index on analytics.session_event (player_id, started_at);

-- Rollup: one row per player per day. THIS is what the dashboard reads.
create table analytics.player_day (
  day date not null,
  player_id bigint not null,
  sessions int not null default 0,
  session_seconds int not null default 0,
  collects int not null default 0,
  attacks_made int not null default 0,
  attacks_received int not null default 0,
  gold_in bigint not null default 0,
  gold_out bigint not null default 0,
  diamonds_in bigint not null default 0,
  diamonds_out bigint not null default 0,
  revenue_usd_micros bigint not null default 0,
  max_level int not null default 0,
  primary key (day, player_id)
);
create index on analytics.player_day (player_id, day);

create table analytics.daily_kpi (
  day date primary key,
  dau int not null, new_players int not null, returning_players int not null,
  wau int not null, mau int not null,
  sessions int not null, avg_session_seconds numeric not null,
  median_session_seconds numeric not null,
  payers int not null, new_payers int not null,
  revenue_usd_micros bigint not null,
  gold_created bigint not null, gold_destroyed bigint not null,
  diamonds_created bigint not null, diamonds_destroyed bigint not null,
  total_gold_in_circulation bigint not null,
  -- PG18: VIRTUAL is the default for generated columns — computed on read,
  -- zero disk, and adding one is an instant metadata change.
  arpdau_usd numeric generated always as
    (revenue_usd_micros / 1e6 / nullif(dau, 0)) virtual,
  arppu_usd numeric generated always as
    (revenue_usd_micros / 1e6 / nullif(payers, 0)) virtual,
  computed_at timestamptz not null default now()
);

create table analytics.retention_cohort (
  cohort_day date not null,
  day_offset smallint not null check (day_offset in (1,3,7,14,30)),
  cohort_size int not null,
  retained int not null,
  rate numeric generated always as (retained::numeric / nullif(cohort_size,0)) virtual,
  primary key (cohort_day, day_offset)
);
```

### The queries behind each tile

**DAU** — `player_day` is already one row per player per day:
```sql
select count(*) from analytics.player_day where day = $1;
```

**WAU / MAU** — rolling, not calendar:
```sql
select count(distinct player_id) from analytics.player_day
 where day > $1::date - interval '7 day' and day <= $1;   -- 30 for MAU
```

**New players** (labelled *New accounts*, see caveat):
```sql
select count(*) from game.player
 where created_at >= $1::date and created_at < $1::date + 1;
```
> **Caveat to put in the UI tooltip:** this is *new accounts*, not *installs*. True install counts live in App Store Connect / Play Console. Phase 3 ingests ASC Sales & Trends reports into `analytics.store_daily` and shows install→account conversion. Do not label an account count "installs" — it will silently mislead every marketing decision.

**Retention D1 / D7 / D30** — computed nightly into `retention_cohort`:
```sql
insert into analytics.retention_cohort (cohort_day, day_offset, cohort_size, retained)
select c.day, $2::smallint, count(*) as cohort_size,
       count(*) filter (where r.player_id is not null) as retained
from (select id as player_id, created_at::date as day
        from game.player where created_at::date = $1::date) c
left join analytics.player_day r
       on r.player_id = c.player_id and r.day = c.day + $2::int
group by c.day
on conflict (cohort_day, day_offset) do update
   set cohort_size = excluded.cohort_size, retained = excluded.retained;
```
Displayed as a triangular cohort heatmap (rows = cohort day, columns = D1/D3/D7/D14/D30). **A single D1 number is nearly useless; the triangle is where you see that last Tuesday's update broke onboarding.**

**Revenue / ARPDAU / ARPPU**:
```sql
select coalesce(sum(price_usd_micros),0) as revenue_usd_micros,
       count(distinct player_id)          as payers
from billing.purchase
where status = 'verified'
  and created_at >= $1::date and created_at < $1::date + 1;
```
ARPDAU and ARPPU are the PG18 virtual generated columns above — the formula lives in the schema, so the dashboard, the CSV export, and any ad-hoc query cannot disagree about it.

**Session length**:
```sql
select avg(duration_s) as mean,
       percentile_cont(0.5) within group (order by duration_s) as median,
       percentile_cont(0.9) within group (order by duration_s) as p90
from analytics.session_event
where started_at >= $1::date and started_at < $1::date + 1 and duration_s is not null;
```
Show **median and p90, not mean.** Session length is heavily right-skewed; the mean is dominated by the person who left the app open on a train.

**Active players right now** — the one metric that is *not* SQL. Go maintains a Redis sorted set `emp:online` keyed by player id with score = last heartbeat unix. `GET /admin/metrics/live` returns:
```
ZCOUNT emp:online <now-120> +inf
```
One O(log n) call, polled every 10s. Putting this in Postgres would mean a write per heartbeat per player — the fastest way to melt a Neon compute.

**Rollup job** (`internal/jobs/rollup.go`): runs at `:05` every hour recomputing today (partial) and at 00:20 UTC recomputing yesterday and D+1/3/7/14/30 cohorts whose window just closed. All `insert … on conflict do update`, so it is idempotent and safe to re-run by hand from the panel (`/settings/jobs` has a "Recompute day" button, audited).

### Dashboard sketch

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Dashboard                                    [ 7d | 30d | 90d ]  [Export CSV]│
├────────────┬────────────┬────────────┬────────────┬────────────┬─────────────┤
│ DAU        │ WAU        │ MAU        │ New accts  │ Revenue    │ ARPDAU      │
│ 1,284      │ 4,902      │ 11,733     │ 212        │ $412.80    │ $0.321      │
│ ▲ 4.1% ╱╲_ │ ▲ 1.2% ╱╲_ │ ▬ 0.3% ╱╲_ │ ▼ 8.0% ╲╱_ │ ▲ 12% ╱╲╱  │ ▲ 7.6% ╱╲_  │
├────────────┴────────────┴────────────┼────────────┴────────────┴─────────────┤
│ Retention (cohort triangle)          │ Online now                            │
│        D1    D3    D7   D14   D30    │            ●  412                     │
│ 09-03  41%   28%    –     –     –    │      ╱╲    peak today 863 @ 20:10     │
│ 09-02  38%   26%    –     –     –    │  ╱╲╱   ╲╱╲  ← 24h, 1-min buckets      │
│ 08-28  40%   27%   19%    –     –    ├───────────────────────────────────────┤
│ 08-05  43%   30%   21%   16%   11%   │ Session length   med 6m14s  p90 22m   │
├──────────────────────────────────────┴───────────────────────────────────────┤
│ Gold: created vs destroyed (14d)                     net today  +18.4M  ⚠     │
│  ███▁ collect  ██▁ tax  █▁ attack   ▁███ shop  ▁██ recruit  ▁█ upgrades       │
├──────────────────────────────────────────────────────────────────────────────┤
│ ⚠ ALARMS (1)   gold_net_positive_3d — net gold +12% for 3 days   [Investigate]│
│ ◆ RECENT       17:42 gd@ published balance v42 “nerf grapes”     [Diff]       │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Player search and detail

### Search
`/players?q=&status=&level_min=&level_max=&kingdom=&sort=&page=` — all state in the URL via `nuqs`, so the page is a pure function of the URL and every view is shareable.

Search matches: display name (trigram, `pg_trgm` GIN index), `public_id` (uuidv7), numeric id, email, device id, and last-seen IP. Backed by:
```sql
create index player_name_trgm on game.player using gin (display_name gin_trgm_ops);
```

**URLs use `public_id` (uuidv7), never the bigint.** Rationale in §14 — it removes both enumeration and the far more likely off-by-one typo landing on a real neighbour account.

### Detail — overview tab

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ← Players    Ser_Bartholomew   #018f2a…c31 ⧉    lvl 34   ACTIVE   🛡 12m     │
│ Overview │ Inventory │ Soldiers │ Battles │ Ledger │ Purchases │ Admin log   │
├───────────────────────────────┬──────────────────────────────────────────────┤
│ CURRENCIES                    │ ACTIVITY                                     │
│  Gold      1,284,905  [Adjust]│  Created     2026-03-12 (176d)               │
│  Diamonds        340  [Adjust]│  Last seen   2026-09-04 17:31 (11m ago)      │
│  Energy      18 / 42  [Adjust]│  Sessions 7d 22    Playtime 7d  4h12m        │
│  XP     84,201 → lvl 35 (61%) │  Platform    ios 26.2   app 1.4.2            │
├───────────────────────────────┼──────────────────────────────────────────────┤
│ STATS (allocated 96 pts)      │ KINGDOM                                      │
│  Max Energy 22  Atk 41 Def 33 │  ⚜ House Aurelian  — Marshal — rep 12,405   │
│  Total power (incl. gear) 812 │  [Open kingdom]                              │
├───────────────────────────────┼──────────────────────────────────────────────┤
│ EQUIPPED                      │ FLAGS                                        │
│  ⚔ Ashwood Blade   epic  +38  │  ⚠ gold_rate_outlier  p99.97  2026-09-01     │
│  🛡 Chain Hauberk   rare  +21  │     [Review] [Dismiss]                       │
│  🐎 Destrier      legend  +14  │                                              │
├───────────────────────────────┴──────────────────────────────────────────────┤
│ SOLDIERS 4/6 slots  · next slot 34,200g                                      │
│  Gladiator mystic 214⚔  │ Mercenary rare 98⚔ │ Peasant common 31⚔ │ empty    │
├──────────────────────────────────────────────────────────────────────────────┤
│ ADMIN ACTIONS                                                                │
│ [Grant/Remove ▾] [Refill energy] [Reset shield] [Rename] [Force level]        │
│ [Mute ▾] [Ban ▾] [Inspect as player] [Wipe account]                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Action catalogue

| Action | Endpoint | Permission | Gate | Audit action |
|---|---|---|---|---|
| Grant/remove gold | `POST /admin/players/{id}/currency` | `grant_currency` / `remove_currency` | step-up + reason + cap | `player.grant_gold` |
| Grant/remove diamonds | same, `currency=diamonds` | same | step-up + reason + cap | `player.grant_diamonds` |
| Set/refill energy | `POST /admin/players/{id}/energy` | `grant_currency` | reason | `player.set_energy` |
| Force level | `POST /admin/players/{id}/level` | `force_level` | step-up + `DangerConfirm` | `player.force_level` |
| Reset/grant shield | `POST /admin/players/{id}/shield` | `reset_shield` | reason | `player.set_shield` |
| Rename | `POST /admin/players/{id}/name` | `rename` | reason; re-runs the name filter | `player.rename` |
| Mute | `POST /admin/players/{id}/mute` | `mod.action` | reason + duration | `player.mute` |
| Ban / unban | `POST /admin/players/{id}/ban` | `player.ban` | step-up + `DangerConfirm` + duration | `player.ban` |
| Wipe account | `DELETE /admin/players/{id}` | `player.wipe` | step-up + type-the-name + owner only | `player.wipe` |
| Inspect (read-only) | `POST /admin/players/{id}/inspect` | `impersonate_ro` | reason | `player.inspect` |
| Impersonate (write) | `POST /admin/players/{id}/impersonate` | `impersonate_rw` | step-up, 15 min max, owner only | `player.impersonate` |

**Force level is not a slider.** Changing level must recompute unspent stat points, energy cap, and job unlocks consistently. Go recalculates from the XP curve in the *active* balance doc and returns the derived state for confirmation *before* applying it. The dialog shows "level 34 → 40, +18 unspent stat points, max energy 42 → 48, unlocks: Saffron, Silk". Never let the panel compute this.

**Wipe is a soft delete.** `game.player.deleted_at` is set, the display name is released, PII is scrubbed, and gold is destroyed via a `gold_ledger` row with `reason='admin_wipe'` so the economy charts stay balanced. Hard deletion happens after 30 days via a job — long enough to undo a mistake, short enough for GDPR. **A wipe that skips the ledger row silently corrupts every economy chart afterwards**; make the ledger write part of the same transaction.

**Inspect vs impersonate.** `inspect` mints a read-only, 15-minute, distinctly-badged token that renders the player's exact client state in a nested viewer — it cannot spend, attack, or collect. That covers ~95% of support tickets. True write-impersonation is owner-only, shows a permanent in-game banner to the player, and every action it takes is double-logged (game ledger + audit log with `impersonated_by`).

**The ledger tab is the support tool that matters.** Every gold and diamond movement with reason, delta, running balance, ref, and the balance version active at the time. "Where did my gold go" is answered by filtering, not by guessing.

---

## 8. The balance editor — the centrepiece

### Model: one immutable, hash-sealed JSON document per version

Not a pile of `collect_jobs` / `item_defs` / `upgrade_costs` tables. **One `jsonb` document.** This choice makes five otherwise-hard things trivial:

1. **Publish is atomic.** One row insert. There is no window where jobs are v42 and shop weights are v41.
2. **Diff is a pure function** of two documents. No 12-table join.
3. **Rollback is an append**, not a reverse migration.
4. **The client cache key is one hash.** One ETag for the whole config.
5. **The simulator can evaluate any version** without touching live tables.

The cost — no referential integrity from the database — is paid by strict Go decoding plus a semantic validator (below), which catches strictly more than FK constraints would (FKs cannot express "unlock levels must be non-decreasing").

```sql
create schema if not exists cfg;

create sequence cfg.balance_seq;

create table cfg.balance_version (
  id             bigint primary key generated always as identity,
  seq            int  not null unique default nextval('cfg.balance_seq'),  -- "v42"
  is_draft       boolean not null default true,
  label          text not null default '',
  notes          text not null default '',
  schema_version int  not null,
  doc            jsonb not null,
  doc_hash       text  not null,          -- sha256 of canonical JSON, hex
  parent_id      bigint references cfg.balance_version(id),
  created_by     bigint not null references admin.admin_user(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  sealed_at      timestamptz              -- set on publish; doc immutable after
);
create index on cfg.balance_version (is_draft, updated_at desc);

-- Append-only. The newest row IS the live config. Rollback appends; it never rewrites.
create table cfg.balance_activation (
  id              bigint primary key generated always as identity,
  version_id      bigint not null references cfg.balance_version(id),
  prev_version_id bigint references cfg.balance_version(id),
  kind            text not null check (kind in ('publish','rollback')),
  reason          text not null,
  rollout         jsonb not null default '{"mode":"all"}',  -- phase 2: cohort rollout
  activated_by    bigint not null references admin.admin_user(id),
  activated_at    timestamptz not null default now()
);
create index on cfg.balance_activation (activated_at desc);
revoke update, delete on cfg.balance_activation from emperors_app;
```

Live version:
```sql
select v.* from cfg.balance_activation a
  join cfg.balance_version v on v.id = a.version_id
 order by a.id desc limit 1;
```

### Document shape (`schema_version: 1`)

```jsonc
{
  "schema_version": 1,
  "constants": {
    "energy": { "max_base": 20, "regen_seconds_per_point": 300,
                "offline_accrual_cap_seconds": 28800 },
    "xp":     { "base": 100, "exponent": 1.55, "stat_points_per_level": 3 },
    "tax":    { "base_per_second": 0.05, "offline_cap_seconds": 28800 },
    "attack": { "energy_cost": 5, "steal_pct": 0.03, "shield_seconds": 1800,
                "reputation_per_win": 10 },
    "shop":   { "refresh_seconds": 300, "slots": 6, "reroll_diamond_cost": 15 }
  },
  "tiers": {
    "common":    { "index": 0, "stat_mult": 1.00, "price_mult": 1.0,  "color": "#9CA3AF", "frame": "plain" },
    "uncommon":  { "index": 1, "stat_mult": 1.35, "price_mult": 2.2,  "color": "#22C55E", "frame": "plain" },
    "rare":      { "index": 2, "stat_mult": 1.85, "price_mult": 5.0,  "color": "#3B82F6", "frame": "plain" },
    "epic":      { "index": 3, "stat_mult": 2.60, "price_mult": 12.0, "color": "#A855F7", "frame": "plain" },
    "legendary": { "index": 4, "stat_mult": 3.80, "price_mult": 30.0, "color": "#EAB308", "frame": "glow" },
    "mystic":    { "index": 5, "stat_mult": 5.60, "price_mult": 80.0, "color": "#22D3EE", "frame": "shimmer" },
    "special":   { "index": 6, "stat_mult": 8.00, "price_mult": 200.0,"color": "#EF4444", "frame": "ornate" }
  },
  "collect_jobs": [
    { "id": "grapes", "name": "Grapes", "unlock_level": 1, "energy_cost": 1,
      "gold": 2, "xp": 1, "icon": "job_grapes",
      "milestones": [ {"count":25,"gold_pct":5}, {"count":50,"gold_pct":10},
                      {"count":100,"gold_pct":15} ] }
  ],
  "item_tier_curve": { "atk": { "a": 4.0, "b": 1.45 }, "def": { "a": 3.0, "b": 1.45 } },
  "item_defs": [
    { "id": "sword_ashwood", "type": "weapon", "art": "sword_ashwood",
      "atk_weight": 1.0, "def_weight": 0.0,
      "min_tier": "common", "max_tier": "special" }
  ],
  "shop_roll_weights": {
    "by_type": { "weapon": 40, "armor": 35, "horse": 25 },
    "by_tier": { "common": 50, "uncommon": 25, "rare": 14, "epic": 7,
                 "legendary": 3, "mystic": 0.9, "special": 0.1 }
  },
  "soldier_types": {
    "peasant":   { "gold_cost": 500,   "base_atk": 3,  "base_def": 3,
                   "tier_weights": { "common": 70, "uncommon": 22, "rare": 6, "epic": 1.6,
                                     "legendary": 0.35, "mystic": 0.05, "special": 0 } },
    "mercenary": { "gold_cost": 5000,  "base_atk": 9,  "base_def": 8,  "tier_weights": { … } },
    "gladiator": { "gold_cost": 60000, "base_atk": 22, "base_def": 19, "tier_weights": { … } }
  },
  "soldier_slot_cost": { "base": 1000, "growth": 1.9, "max_slots": 12 },
  "family_upgrades": [
    { "id": "granary", "name": "Granary", "max_level": 50,
      "cost":   { "base": 100, "growth": 1.14 },
      "effect": { "stat": "collect_gold_pct", "per_level": 2.0 } }
  ],
  "kingdom_upgrades": [ … ],
  "kingdom": { "found_cost": 250000, "max_members": 30 }
}
```

**Tier colours live in the document.** This is the resolution to the epic/mystic conflict (§16): it becomes an owner-editable field, changeable in ten seconds without a client build.

### Editor screen

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Balance / v43 (draft) “grape nerf + mystic buff”      base v42 ● LIVE         │
│ [Constants][Jobs][Items][Tiers][Shop][Soldiers][Upgrades][Kingdom]           │
│                          [Diff vs live] [Simulate] [Discard] [Publish →]     │
├──────────────────────────────────────────────────────────────────────────────┤
│ COLLECT JOBS                                            + Add job            │
│ ┌─id────────┬name───────┬lvl┬energy┬gold┬ xp ┬g/energy┬milestones──────────┐ │
│ │ grapes    │ Grapes    │  1│    1 │ [2]│  1 │ 2.00   │ 25/50/100 +5/10/15 │ │
│ │ strawberr…│ Strawberr…│  3│    2 │  4 │  2 │ 2.00 ⚠ │ 25/50/100 +5/10/15 │ │
│ │ wheat     │ Wheat     │  6│    4 │  9 │  5 │ 2.25   │ 25/50/100 +5/10/15 │ │
│ │ saffron   │ Saffron   │ 12│    8 │ 21 │ 13 │ 2.63   │ 25/50/100 +5/10/15 │ │
│ └───────────┴───────────┴───┴──────┴────┴────┴────────┴────────────────────┘ │
│ ⚠ gold-per-energy is flat from grapes→strawberries: higher jobs give players  │
│   no advantage at all. Consider a rising g/energy curve.        [Explain]     │
├──────────────────────────────────────────────────────────────────────────────┤
│ Gold/energy across the ladder                                                │
│ 3.0┤                                        ╭──                              │
│ 2.5┤                          ╭─────────────╯                                │
│ 2.0┤━━━━━━━━━━━━━━━╮──────────╯      ── draft   ┄┄ live v42                   │
│    └──────────────────────────────────────────────────                       │
├──────────────────────────────────────────────────────────────────────────────┤
│ Draft saved 4s ago · autosave on · hash a3f1…9c2 · editing: you              │
└──────────────────────────────────────────────────────────────────────────────┘
```

Notes on the editor UX that matter more than they look:
- **Derived columns are shown, not stored.** `g/energy` is computed live. A designer editing raw numbers without seeing the ratio is flying blind — the ratio *is* the balance.
- **Every numeric table shows a ghost line for the live version.** You are always editing against a baseline.
- **`WeightsEditor` shows normalized percentages next to raw weights.** Raw weights are unintuitive; "0.9" means nothing until you see "0.9%".
- **Autosave with optimistic concurrency**, debounced 2s. `PUT /admin/balance/{id}` with `If-Match: <hash>`; a 409 shows "someone else edited this draft" with a diff and a merge choice. Simpler and more atomic than per-field PATCH.

### Publish flow

```
 Draft ──edit──▶ Draft ──validate──▶ Diff+Risk ──simulate──▶ Publish dialog
                                                                   │
                                          step-up 2FA + reason + ack risks
                                                                   ▼
                                       seal (immutable) → activate → NOTIFY
                                                                   │
                                              ┌────────────────────┴───────┐
                                       Go instances reload        Godot clients
                                       (LISTEN + 60s poll)        (X-Config-Epoch)
```

Publish dialog:
```
┌─ Publish balance v43 ────────────────────────────────────────────────────────┐
│ v42 (live since 2026-08-29 14:02) → v43                                      │
│                                                                              │
│ 14 changes in 4 sections                                    [Show full diff] │
│  collect_jobs[grapes].gold                     2 → 1        −50.0%    ⛔ HIGH │
│  constants.attack.steal_pct                 0.03 → 0.05     +66.7%    ⛔ HIGH │
│  tiers[mystic].stat_mult                    5.60 → 6.20     +10.7%    ⚠ MED  │
│  shop_roll_weights.by_tier.mystic            0.9 → 1.4      +55.6%    ⛔ HIGH │
│  … 10 more                                                                   │
│                                                                              │
│ SIMULATION (vs live)                                                         │
│  archetype        gold/h        xp/h      h→gladiator   h→kingdom            │
│  new (lvl 5)      142 → 128     31 → 31      422 → 469     1758 → 1953       │
│                     −9.9%          ▬          +11.1%         +11.1%          │
│  mid (lvl 30)   2,940 → 2,510   410 → 410      20 → 24         88 → 103      │
│                    −14.6%          ▬          +20.0%         +17.0%          │
│  whale (lvl 60) 9,120 → 8,050   980 → 980       6 → 7          28 → 33       │
│                    −11.7%          ▬          +16.7%         +17.9%          │
│  ⚠ Time-to-gladiator rises >15% for mid players. Expect churn complaints.    │
│                                                                              │
│ ☑ I understand collect gold drops ~12% for all players                       │
│ ☑ I understand PvP steal rate rises from 3% to 5%                            │
│ ☑ I understand mystic drops become ~56% more common                          │
│                                                                              │
│ Reason (required, ≥10 chars)                                                 │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Nerf early grape farming, compensate with better mystic drops.           │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                       [Cancel] [🔒 Publish]  │
└──────────────────────────────────────────────────────────────────────────────┘
```

The checkboxes are not theatre. Each is a **risk code** returned by the server; the server refuses the publish if any high-severity risk code is missing from `ack_risks`. The list is computed server-side from the actual diff, so it cannot be bypassed by a crafted request.

### Go: the publish transaction

```go
// api/internal/balance/publish.go
package balance

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

var (
	ErrNotFound = errors.New("balance: version not found")
	ErrNotDraft = errors.New("balance: version is sealed and cannot be published again")
	ErrStale    = errors.New("balance: draft changed since you loaded it")
	ErrNoChange = errors.New("balance: draft is identical to the live version")
)

// Serializes all publishes/rollbacks across every server instance.
const lockKeyBalance int64 = 0x454d505f42414c00 // "EMP_BAL\0"

type PublishCmd struct {
	DraftID  int64
	BaseHash string   // hash of the doc the admin actually reviewed
	Reason   string
	AckRisks []string // risk codes explicitly acknowledged in the UI
	Rollout  Rollout
}

type PublishResult struct {
	VersionID, PrevVersionID int64
	Seq                      int32
	Hash                     string
	Diff                     []DiffOp
}

func (s *Service) Publish(ctx context.Context, ac *audit.Actor, cmd PublishCmd) (*PublishResult, error) {
	if err := ac.RequirePermission("balance.publish"); err != nil { return nil, err }
	if err := ac.RequireStepUp(); err != nil { return nil, err }
	if len(cmd.Reason) < 10 { return nil, ErrReasonTooShort }

	var out *PublishResult
	e := &audit.Entry{
		Action: "balance.publish", TargetType: "balance_version",
		TargetID: fmt.Sprint(cmd.DraftID), Reason: cmd.Reason,
	}

	err := audit.Do(ctx, s.db, ac, e, func(ctx context.Context, tx pgx.Tx, e *audit.Entry) error {
		// 1. Serialize. The advisory lock is transaction-scoped: it releases on
		//    commit or rollback, so a crashed publish cannot wedge the system.
		if _, err := tx.Exec(ctx, `select pg_advisory_xact_lock($1)`, lockKeyBalance); err != nil {
			return err
		}

		// 2. Load and lock the draft.
		var (
			rawDraft  []byte
			draftHash string
			isDraft   bool
			schemaVer int32
			seq       int32
		)
		err := tx.QueryRow(ctx, `
			select doc::text, doc_hash, is_draft, schema_version, seq
			  from cfg.balance_version where id = $1 for update`, cmd.DraftID).
			Scan(&rawDraft, &draftHash, &isDraft, &schemaVer, &seq)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			return ErrNotFound
		case err != nil:
			return err
		case !isDraft:
			return ErrNotDraft
		case draftHash != cmd.BaseHash:
			// Someone edited the draft between "review" and "publish".
			return ErrStale
		}

		// 3. Strict decode. DisallowUnknownFields is the mass-assignment defence:
		//    a client-invented key is a hard error, not a silently ignored field.
		var doc Doc
		dec := json.NewDecoder(bytes.NewReader(rawDraft))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&doc); err != nil {
			return fmt.Errorf("balance: draft does not match schema v%d: %w", CurrentSchemaVersion, err)
		}
		if doc.SchemaVersion != CurrentSchemaVersion {
			return fmt.Errorf("balance: draft is schema v%d, server expects v%d (migrate the draft first)",
				doc.SchemaVersion, CurrentSchemaVersion)
		}

		// 4. Semantic invariants. Errors block; warnings surface in the response.
		problems := Validate(&doc)
		if problems.HasErrors() { return &ValidationError{Problems: problems} }

		// 5. Diff against live and enforce risk acknowledgement.
		liveDoc, liveID, err := loadActiveTx(ctx, tx)
		if err != nil && !errors.Is(err, ErrNotFound) { return err }
		var diff []DiffOp
		if liveDoc != nil {
			diff = DiffJSON(liveDoc.Raw, rawDraft)
			if len(diff) == 0 { return ErrNoChange }
			if missing := UnacknowledgedHighRisks(diff, cmd.AckRisks); len(missing) > 0 {
				return &RiskNotAcknowledgedError{Codes: missing}
			}
		}

		// 6. Canonicalize and seal. After this the doc is immutable forever, so
		//    the hash in the audit log always identifies exactly these bytes.
		canon, err := CanonicalJSON(&doc)
		if err != nil { return err }
		sum := sha256.Sum256(canon)
		hash := hex.EncodeToString(sum[:])

		var versionID int64
		if err := tx.QueryRow(ctx, `
			update cfg.balance_version
			   set is_draft = false, sealed_at = now(), updated_at = now(),
			       doc = $2::jsonb, doc_hash = $3
			 where id = $1
			returning id`, cmd.DraftID, canon, hash).Scan(&versionID); err != nil {
			return err
		}

		// 7. Activate: an append, never an update. History is preserved exactly.
		var prevID *int64
		if liveID != 0 { prevID = &liveID }
		if _, err := tx.Exec(ctx, `
			insert into cfg.balance_activation
			    (version_id, prev_version_id, kind, reason, rollout, activated_by)
			values ($1, $2, 'publish', $3, $4, $5)`,
			versionID, prevID, cmd.Reason, cmd.Rollout, ac.AdminID); err != nil {
			return err
		}

		// 8. Fan out. pg_notify inside a transaction is itself transactional:
		//    listeners are woken only if this COMMIT succeeds. Never notify
		//    from application code after commit — that races with a rollback.
		payload, _ := json.Marshal(map[string]any{
			"kind": "balance", "version_id": versionID, "seq": seq, "hash": hash,
		})
		if _, err := tx.Exec(ctx, `select pg_notify('emperors_config', $1)`, string(payload)); err != nil {
			return err
		}

		// 9. Full before/after in the audit row. Publishes are rare (a few per
		//    week) and the whole document is exactly what a post-mortem needs.
		if liveDoc != nil { e.Before = json.RawMessage(liveDoc.Raw) }
		e.After = json.RawMessage(canon)
		e.Diff, _ = json.Marshal(diff)

		out = &PublishResult{
			VersionID: versionID, PrevVersionID: liveID,
			Seq: seq, Hash: hash, Diff: diff,
		}
		return nil
	})
	return out, err
}

// Rollback re-activates an already-sealed version. It never resurrects or
// mutates a document: it appends a new activation row pointing backwards.
func (s *Service) Rollback(ctx context.Context, ac *audit.Actor, toVersionID int64, reason string) error {
	if err := ac.RequirePermission("balance.rollback"); err != nil { return err }
	if err := ac.RequireStepUp(); err != nil { return err }

	e := &audit.Entry{
		Action: "balance.rollback", TargetType: "balance_version",
		TargetID: fmt.Sprint(toVersionID), Reason: reason,
	}
	return audit.Do(ctx, s.db, ac, e, func(ctx context.Context, tx pgx.Tx, e *audit.Entry) error {
		if _, err := tx.Exec(ctx, `select pg_advisory_xact_lock($1)`, lockKeyBalance); err != nil {
			return err
		}
		var sealed bool
		var hash string
		if err := tx.QueryRow(ctx,
			`select sealed_at is not null, doc_hash from cfg.balance_version where id = $1`,
			toVersionID).Scan(&sealed, &hash); err != nil {
			return err
		}
		if !sealed { return errors.New("balance: cannot roll back to a draft") }

		_, liveID, err := loadActiveTx(ctx, tx)
		if err != nil { return err }
		if liveID == toVersionID { return errors.New("balance: that version is already live") }

		if _, err := tx.Exec(ctx, `
			insert into cfg.balance_activation
			    (version_id, prev_version_id, kind, reason, activated_by)
			values ($1, $2, 'rollback', $3, $4)`,
			toVersionID, liveID, reason, ac.AdminID); err != nil {
			return err
		}
		payload := fmt.Sprintf(`{"kind":"balance","version_id":%d,"hash":%q}`, toVersionID, hash)
		_, err = tx.Exec(ctx, `select pg_notify('emperors_config', $1)`, payload)
		e.After = map[string]any{"version_id": toVersionID, "hash": hash}
		return err
	})
}
```

**Rollback is one row.** That is the entire payoff of the append-only activation design, and it is why the 3am "we just broke the economy" path takes six seconds instead of a deploy.

### Go: canonical JSON, validation, and the store

```go
// api/internal/balance/canonical.go
// Round-tripping through map[string]any makes encoding/json sort keys for us,
// which is what makes the hash stable across Go versions and struct reordering.
func CanonicalJSON(d *Doc) ([]byte, error) {
	raw, err := json.Marshal(d)
	if err != nil { return nil, err }
	var generic map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber() // never let float64 mangle an integer gold value
	if err := dec.Decode(&generic); err != nil { return nil, err }
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(generic); err != nil { return nil, err }
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}
```

```go
// api/internal/balance/validate.go
type Problem struct {
	Path, Code, Message string
	Severity            string // "error" | "warning"
}

func Validate(d *Doc) Problems {
	var p Problems

	// --- structural errors: block the publish -------------------------------
	seen := map[string]bool{}
	for i, j := range d.CollectJobs {
		path := fmt.Sprintf("collect_jobs[%s]", j.ID)
		if j.ID == "" { p.Err(fmt.Sprintf("collect_jobs[%d]", i), "empty_id", "job id is required") }
		if seen[j.ID] { p.Err(path, "duplicate_id", "duplicate job id") }
		seen[j.ID] = true
		if j.EnergyCost <= 0 { p.Err(path+".energy_cost", "non_positive", "energy cost must be > 0") }
		if j.Gold < 0       { p.Err(path+".gold", "negative", "gold must be >= 0") }
		if j.UnlockLevel < 1 { p.Err(path+".unlock_level", "below_min", "unlock level must be >= 1") }
		last := 0
		for k, m := range j.Milestones {
			if m.Count <= last {
				p.Err(fmt.Sprintf("%s.milestones[%d].count", path, k),
					"not_increasing", "milestone counts must strictly increase")
			}
			last = m.Count
		}
	}
	for _, name := range []string{"weapon", "armor", "horse"} {
		if d.ShopRollWeights.ByType[name] < 0 {
			p.Err("shop_roll_weights.by_type."+name, "negative", "weight cannot be negative")
		}
	}
	if sumWeights(d.ShopRollWeights.ByTier) <= 0 {
		p.Err("shop_roll_weights.by_tier", "zero_sum",
			"all tier weights are zero: the shop would be unable to roll anything")
	}
	for id, def := range d.ItemDefsByID() {
		if _, ok := d.Tiers[def.MinTier]; !ok {
			p.Err("item_defs["+id+"].min_tier", "unknown_tier", "unknown tier "+def.MinTier)
		}
	}
	for _, u := range d.FamilyUpgrades {
		if u.Cost.Growth <= 1.0 {
			p.Err("family_upgrades["+u.ID+"].cost.growth", "flat_cost",
				"growth <= 1.0 makes the upgrade infinitely cheap to max")
		}
	}
	if d.SoldierSlotCost.Growth <= 1.0 {
		p.Err("soldier_slot_cost.growth", "flat_cost", "slot cost must grow")
	}
	if d.Constants.Attack.StealPct <= 0 || d.Constants.Attack.StealPct > 0.5 {
		p.Err("constants.attack.steal_pct", "out_of_range", "steal_pct must be in (0, 0.5]")
	}

	// --- design warnings: surfaced, but do not block -------------------------
	jobs := d.JobsSortedByUnlock()
	for i := 1; i < len(jobs); i++ {
		if jobs[i].UnlockLevel < jobs[i-1].UnlockLevel {
			p.Warn("collect_jobs", "unlock_not_monotonic",
				"unlock levels are not ordered; the job list will look scrambled in-game")
			break
		}
		prev := float64(jobs[i-1].Gold) / float64(jobs[i-1].EnergyCost)
		cur  := float64(jobs[i].Gold)   / float64(jobs[i].EnergyCost)
		if cur <= prev {
			p.Warn(fmt.Sprintf("collect_jobs[%s].gold", jobs[i].ID), "flat_gold_per_energy",
				fmt.Sprintf("gold-per-energy does not improve over %s (%.2f -> %.2f): "+
					"unlocking this job gives the player no advantage", jobs[i-1].ID, prev, cur))
		}
	}
	return p
}
```

> The `flat_gold_per_energy` warning is not hypothetical. The ladder in the brief — grapes 1→2 gold, strawberries 2→4 gold — is **exactly 2.0 gold per energy at both steps**. With one energy pool and no other constraint, unlocking strawberries changes nothing: the player taps twice as rarely for twice as much. **The progression ladder as specified is a no-op.** The validator surfaces this on day one instead of six months later.

```go
// api/internal/balance/store.go
type Snapshot struct {
	Doc  *Doc
	Raw  []byte
	ID   int64
	Seq  int32
	Hash string
}

type Store struct {
	cur       atomic.Pointer[Snapshot]
	pool      *pgxpool.Pool
	directDSN string // MUST be the un-pooled Neon endpoint. See below.
}

func (s *Store) Current() *Snapshot { return s.cur.Load() }

func (s *Store) Run(ctx context.Context) {
	if err := s.reload(ctx); err != nil { log.Fatal("balance: initial load: ", err) }
	go s.listen(ctx)
	go s.poll(ctx) // belt and braces
}

// listen must NOT use the pooled Neon DSN. Neon fronts every database with
// PgBouncer in transaction pooling mode, and transaction pooling silently
// breaks LISTEN/NOTIFY — the LISTEN is registered on a connection that is
// handed to someone else on the next statement. Symptom: publishes appear to
// work, servers just never pick them up. Use the endpoint WITHOUT "-pooler".
func (s *Store) listen(ctx context.Context) {
	for ctx.Err() == nil {
		conn, err := pgx.Connect(ctx, s.directDSN)
		if err != nil { sleepBackoff(ctx); continue }
		if _, err := conn.Exec(ctx, "listen emperors_config"); err != nil {
			conn.Close(ctx); sleepBackoff(ctx); continue
		}
		for {
			if _, err := conn.WaitForNotification(ctx); err != nil { break }
			if err := s.reload(ctx); err != nil { log.Error("balance reload: ", err) }
		}
		conn.Close(ctx)
	}
}

// poll catches a missed NOTIFY (dropped connection, Neon scale-to-zero).
// Cheap: one indexed row, and it only reparses when the hash actually moved.
func (s *Store) poll(ctx context.Context) {
	t := time.NewTicker(60 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			var hash string
			if err := s.pool.QueryRow(ctx, `
				select v.doc_hash from cfg.balance_activation a
				  join cfg.balance_version v on v.id = a.version_id
				 order by a.id desc limit 1`).Scan(&hash); err != nil {
				continue
			}
			if cur := s.cur.Load(); cur == nil || cur.Hash != hash {
				_ = s.reload(ctx)
			}
		}
	}
}
```

**This LISTEN/pooler interaction is the single most likely thing to silently break this feature.** It is worth a comment in the code and a line in the runbook.

### TypeScript: diff and risk

```ts
// admin/src/lib/balance/diff.ts
export type Json = string | number | boolean | null | Json[] | { [k: string]: Json };

export type DiffOp = {
  path: string;
  kind: "added" | "removed" | "changed";
  before?: Json;
  after?: Json;
  pctChange?: number;
};

// Arrays whose elements have stable identity are keyed by that field, so a
// reorder is not a diff and an edit is attributed to the right row.
const KEYED_ARRAYS: Record<string, string> = {
  collect_jobs: "id",
  item_defs: "id",
  family_upgrades: "id",
  kingdom_upgrades: "id",
};

function flatten(node: Json, path: string, out: Map<string, Json>, arrayKey?: string): void {
  if (Array.isArray(node)) {
    node.forEach((el, i) => {
      const id =
        arrayKey && el !== null && typeof el === "object" && !Array.isArray(el)
          ? String((el as Record<string, Json>)[arrayKey])
          : String(i);
      flatten(el, `${path}[${id}]`, out);
    });
    return;
  }
  if (node !== null && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) {
      flatten(v, path ? `${path}.${k}` : k, out, KEYED_ARRAYS[k]);
    }
    return;
  }
  out.set(path, node);
}

export function diffDoc(before: Json, after: Json): DiffOp[] {
  const a = new Map<string, Json>();
  const b = new Map<string, Json>();
  flatten(before, "", a);
  flatten(after, "", b);

  const ops: DiffOp[] = [];
  for (const [p, av] of a) {
    if (!b.has(p)) {
      ops.push({ path: p, kind: "removed", before: av });
      continue;
    }
    const bv = b.get(p)!;
    if (Object.is(av, bv)) continue;
    const op: DiffOp = { path: p, kind: "changed", before: av, after: bv };
    if (typeof av === "number" && typeof bv === "number" && av !== 0) {
      op.pctChange = ((bv - av) / Math.abs(av)) * 100;
    }
    ops.push(op);
  }
  for (const [p, bv] of b) {
    if (!a.has(p)) ops.push({ path: p, kind: "added", after: bv });
  }
  return ops.sort((x, y) => x.path.localeCompare(y.path));
}
```

```ts
// admin/src/lib/balance/risk.ts
import type { DiffOp } from "./diff";

export type Risk = {
  code: string;                       // must be echoed back in ack_risks
  severity: "high" | "medium";
  path: string;
  message: string;
};

const BIG_MOVE_PCT = 25;

const HOT: { test: RegExp; label: string; alwaysHigh?: boolean }[] = [
  { test: /^collect_jobs\[[^\]]+\]\.(gold|energy_cost)$/, label: "collect yield" },
  { test: /^constants\.energy\./,                          label: "energy economy" },
  { test: /^constants\.tax\./,                             label: "passive tax income" },
  { test: /^constants\.attack\.steal_pct$/,                label: "PvP steal rate", alwaysHigh: true },
  { test: /^constants\.attack\.shield_seconds$/,           label: "PvP shield duration" },
  { test: /^constants\.xp\./,                              label: "XP curve" },
  { test: /^item_tier_curve\./,                            label: "item stat curve" },
  { test: /^shop_roll_weights\./,                          label: "shop roll weights" },
  { test: /^soldier_types\.[^.]+\.tier_weights\./,         label: "recruit tier weights" },
  { test: /^tiers\.[^.]+\.stat_mult$/,                     label: "tier stat multiplier" },
  { test: /^soldier_slot_cost\./,                          label: "soldier slot cost" },
  { test: /^kingdom\.found_cost$/,                         label: "kingdom founding cost" },
];

export function assessRisk(ops: DiffOp[]): Risk[] {
  const risks: Risk[] = [];

  for (const op of ops) {
    const hot = HOT.find((h) => h.test.test(op.path));
    if (!hot) continue;
    const pct = op.pctChange;
    const big = hot.alwaysHigh || pct === undefined || Math.abs(pct) >= BIG_MOVE_PCT;
    risks.push({
      code: `${op.kind}:${op.path}`,
      severity: big ? "high" : "medium",
      path: op.path,
      message:
        pct === undefined
          ? `${hot.label} changed structurally at ${op.path}`
          : `${hot.label} changes by ${pct.toFixed(1)}% at ${op.path}`,
    });
  }

  // Structural changes that are dangerous regardless of magnitude.
  for (const op of ops) {
    if (op.kind === "removed" && /^collect_jobs\[/.test(op.path)) {
      risks.push({
        code: `removed:${op.path}`, severity: "high", path: op.path,
        message: "A collect job was removed. Players lose its milestone progress permanently.",
      });
    }
    if (op.kind === "removed" && /^(family|kingdom)_upgrades\[/.test(op.path)) {
      risks.push({
        code: `removed:${op.path}`, severity: "high", path: op.path,
        message: "An upgrade was removed. Players who bought it lose the bonus with no refund.",
      });
    }
  }
  return dedupeByCode(risks);
}

export const highRiskCodes = (r: Risk[]) => r.filter((x) => x.severity === "high").map((x) => x.code);
```

`assessRisk` is duplicated in Go (`UnacknowledgedHighRisks`) — **deliberately**. The TS copy drives the UI; the Go copy enforces. A shared table of hot paths is generated into both from `openapi/balance-hotpaths.yaml` so they cannot drift. This is one of very few places where duplication is correct: the client copy is a convenience and the server copy is the control.

### The simulator — it runs the real game code

**Non-negotiable design rule: the simulator does not contain a single formula.** It constructs the same `economy.Economy` the request path uses, from an arbitrary `*balance.Doc`, and calls the same methods. A reimplementation in TypeScript would drift within one sprint and would then confidently lie to the designer — worse than no simulator.

```go
// api/internal/sim/sim.go
package sim

type Archetype struct {
	Key               string
	Level             int32
	StatPoints        map[string]int32   // max_energy / attack / defense
	CollectCounts     map[string]int32   // drives milestone bonuses
	SoldierCount      int
	SoldierTier       string
	FamilyUpgrades    map[string]int32
	KingdomUpgrades   map[string]int32
	PlayMinutesPerDay int
}

type Metric struct {
	Key, Label, Unit string
	Value            float64
	Higher           string // "better" | "worse" — drives the arrow colour in the UI
}

type Comparison struct {
	Archetype string
	Base      []Metric
	Draft     []Metric
	Delta     []Metric // absolute; pct computed in the UI
}

type Report struct {
	BaseSeq, DraftSeq int32
	Comparisons       []Comparison
	MonteCarlo        MCReport
	Warnings          []string
	ElapsedMS         int64
}

// Run evaluates both documents through the production economy implementation.
func Run(base, draft *balance.Doc, archs []Archetype, seed int64) *Report { … }

func metricsFor(d *balance.Doc, a Archetype) []Metric {
	e := economy.New(d) // the exact constructor the HTTP handlers use

	energyPerHour := 3600.0 / e.EnergyRegenSeconds(a.Level, a.StatPoints["max_energy"])

	// A rational player always taps the best gold-per-energy job available.
	bestGPE := 0.0
	for _, j := range e.UnlockedJobs(a.Level) {
		g := e.JobGold(j.ID, a.CollectCounts[j.ID], e.BonusesFor(a.FamilyUpgrades, a.KingdomUpgrades))
		if gpe := g / float64(j.EnergyCost); gpe > bestGPE { bestGPE = gpe }
	}
	collectGPH := energyPerHour * bestGPE
	taxGPH := e.TaxPerSecond(a.FamilyUpgrades, a.KingdomUpgrades) * 3600

	return []Metric{
		{Key: "gold_h_collect", Label: "Gold/h (collect)", Unit: "g/h", Value: collectGPH, Higher: "better"},
		{Key: "gold_h_tax",     Label: "Gold/h (tax)",     Unit: "g/h", Value: taxGPH,     Higher: "better"},
		{Key: "gold_h_total",   Label: "Gold/h (total)",   Unit: "g/h", Value: collectGPH + taxGPH, Higher: "better"},
		{Key: "xp_h",           Label: "XP/h",             Unit: "xp/h", Value: energyPerHour * bestXPPerEnergy(e, a), Higher: "better"},
		{Key: "h_next_level",   Label: "Hours to next level", Unit: "h",
			Value: float64(e.XPForLevel(a.Level+1)-e.XPForLevel(a.Level)) / max(1, energyPerHour*bestXPPerEnergy(e, a)), Higher: "worse"},
		{Key: "h_gladiator",    Label: "Hours to a Gladiator", Unit: "h",
			Value: float64(d.SoldierTypes["gladiator"].GoldCost) / max(1, collectGPH+taxGPH), Higher: "worse"},
		{Key: "h_next_slot",    Label: "Hours to next soldier slot", Unit: "h",
			Value: e.SlotCost(a.SoldierCount) / max(1, collectGPH+taxGPH), Higher: "worse"},
		{Key: "h_kingdom",      Label: "Hours to found a kingdom", Unit: "h",
			Value: float64(d.Kingdom.FoundCost) / max(1, collectGPH+taxGPH), Higher: "worse"},
		{Key: "attack_g_per_e", Label: "Gold per energy (attack)", Unit: "g/e",
			Value: e.ExpectedStealGold(a.Level) / float64(d.Constants.Attack.EnergyCost), Higher: "better"},
	}
}

// MonteCarlo covers the parts that are not closed-form: shop rolls and recruits.
// Deterministic given the seed, so the same draft always reports the same numbers.
func monteCarlo(d *balance.Doc, trials int, seed int64) MCReport {
	rng := rand.New(rand.NewPCG(uint64(seed), 0x5eed))
	e := economy.New(d)
	var tierHits [7]int
	var atkSum, priceSum float64
	for i := 0; i < trials; i++ {
		it := e.RollShopItem(rng)
		tierHits[d.Tiers[it.Tier].Index]++
		atkSum += float64(it.Attack)
		priceSum += float64(it.Price)
	}
	// … same for each soldier type's recruit table …
	return MCReport{Trials: trials, TierDistribution: tierHits,
		MeanShopAttack: atkSum / float64(trials), MeanShopPrice: priceSum / float64(trials)}
}
```

Default archetypes ship in the repo and are editable per-simulation in the UI: `new (lvl 5, no soldiers)`, `early (lvl 15, 1 soldier)`, `mid (lvl 30, 4 soldiers, kingdom)`, `late (lvl 60, 8 soldiers, maxed family)`, `f2p_grinder`, `whale (bought slots)`.

Budget: 10k Monte Carlo trials × 2 documents × 6 archetypes runs in well under a second in Go. **Keep the endpoint synchronous** with a 10s context deadline; if it ever exceeds that, switch to a job id, not before.

### Server Action for publish

```ts
// admin/src/app/(app)/balance/[versionId]/actions.ts
"use server";
import "server-only";                       // build-time guarantee this never ships to the client
import { z } from "zod";
import { revalidateTag } from "next/cache";
import { requirePermission } from "@/lib/auth/guard";
import { apiFromCookies } from "@/lib/api/client";

// .strict() rejects unknown keys. Server Actions are public HTTP endpoints:
// this schema is the only thing standing between an attacker's curl and Go.
const PublishInput = z
  .object({
    versionId: z.coerce.number().int().positive(),
    baseHash:  z.string().regex(/^[0-9a-f]{64}$/),
    reason:    z.string().trim().min(10).max(500),
    ackRisks:  z.array(z.string().max(300)).max(500),
    stepUpCode: z.string().regex(/^\d{6}$/).optional(),
  })
  .strict();

export async function publishBalance(raw: unknown) {
  const input = PublishInput.parse(raw);

  // UX-level check only. Go re-verifies permission, step-up, risk acks and the
  // base hash. Never treat this line as the authorization boundary.
  await requirePermission("balance.publish");

  const api = await apiFromCookies();
  const requestId = crypto.randomUUID();

  const { data, error, response } = await api.POST("/admin/balance/{versionId}/publish", {
    params: { path: { versionId: input.versionId } },
    body: { base_hash: input.baseHash, reason: input.reason, ack_risks: input.ackRisks },
    headers: { "X-Request-Id": requestId, "X-Step-Up-Code": input.stepUpCode ?? "" },
  });

  if (error) {
    // 409 = stale draft, 412 = unacknowledged risk, 422 = validation errors.
    return { ok: false as const, status: response.status, error, requestId };
  }
  revalidateTag("balance");
  return { ok: true as const, version: data, requestId };
}
```

### How the client picks it up

```
Godot ──GET /v1/bootstrap  If-None-Match: "a3f1…"──▶ Go
      ◀── 304, or 200 { balance:{seq,hash,doc}, announcements[], events[],
                        server_time } + ETag + Cache-Control: no-cache

every gameplay response also carries:  X-Config-Epoch: a3f1…9c2
```

```gdscript
# client/autoload/config_service.gd
extends Node

signal config_changed(epoch: String)

const POLL_SECONDS := 300.0

var epoch: String = ""
var balance: Dictionary = {}
var announcements: Array = []
var events: Array = []

@onready var _http: HTTPRequest = HTTPRequest.new()

func _ready() -> void:
    add_child(_http)                       # one HTTPRequest node per concurrent request
    _http.request_completed.connect(_on_done)
    var t := Timer.new()
    t.wait_time = POLL_SECONDS
    t.timeout.connect(refresh)
    add_child(t)
    t.start()
    refresh()

# Called by ApiClient for EVERY response: config changes are noticed within one
# player action, without any extra request on the happy path.
func note_response_epoch(server_epoch: String) -> void:
    if server_epoch != "" and server_epoch != epoch:
        refresh()

func refresh() -> void:
    var headers := PackedStringArray(["Accept: application/json"])
    if epoch != "":
        headers.append('If-None-Match: "%s"' % epoch)
    var err := _http.request(Api.BASE_URL + "/v1/bootstrap", headers)
    if err != OK:
        push_warning("config refresh could not be queued: %d" % err)

func _on_done(_r: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
    if code == 304:
        return
    if code != 200:
        push_warning("config refresh failed: HTTP %d" % code)
        return
    var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
    if typeof(parsed) != TYPE_DICTIONARY:
        return
    balance       = parsed.get("balance", {}).get("doc", {})
    announcements = parsed.get("announcements", [])
    events        = parsed.get("events", [])
    epoch         = parsed.get("balance", {}).get("hash", "")
    config_changed.emit(epoch)
```

**Rules the client must obey, and the server must assume it will not:**
- The doc is used **only** for display: labels, icons, tier colours, and the cost shown *before* the player commits.
- Every reward, cost, roll and multiplier is computed server-side. A live-ops "double XP" modifier is applied in Go; the client just shows a banner. If the client applied it, the first person with a proxy would have permanent double XP.
- The server stamps `balance_version` on every ledger row and battle, so a mid-session publish is *recorded*, not just tolerated.

**The one genuine mid-flight hazard: offline tax accrual.** If a player is offline across a publish, at what rate did they accrue? Options: (a) accrue at the rate current when they return — simple, slightly wrong, self-correcting; (b) segment the accrual window by activation timestamps — exact, and roughly 80 extra lines. **Ship (a), store `last_tax_at`, and put a note in the publish dialog** ("offline tax accrued since the last collection will use the new rate"). Revisit only if a rate is ever cut sharply. This is an owner-visible trade-off, not an implementation detail.

---

## 9. Economy monitoring

```sql
create schema if not exists econ;

-- A lookup table, not a Go enum, so the chart and the SQL can never disagree
-- about whether a reason creates, destroys, or merely moves gold.
create table econ.gold_reason (
  reason       text primary key,
  flow_class   text not null check (flow_class in ('faucet','sink','transfer')),
  display_name text not null,
  category     text not null
);

insert into econ.gold_reason values
  ('collect',          'faucet',   'Collect jobs',        'core'),
  ('tax',              'faucet',   'Passive tax',         'core'),
  ('quest',            'faucet',   'Quests',              'core'),
  ('kingdom_payout',   'faucet',   'Kingdom payout',      'social'),
  ('admin_grant',      'faucet',   'Admin grant',         'admin'),
  ('iap_bundle',       'faucet',   'IAP gold bundle',     'monetization'),
  ('attack_steal',     'transfer', 'PvP steal (gained)',  'pvp'),
  ('attack_stolen',    'transfer', 'PvP steal (lost)',    'pvp'),
  ('shop_purchase',    'sink',     'Shop purchases',      'core'),
  ('soldier_slot',     'sink',     'Soldier slots',       'core'),
  ('recruit',          'sink',     'Recruiting',          'core'),
  ('family_upgrade',   'sink',     'Family upgrades',     'core'),
  ('kingdom_upgrade',  'sink',     'Kingdom upgrades',    'social'),
  ('kingdom_found',    'sink',     'Kingdom founding',    'social'),
  ('admin_remove',     'sink',     'Admin removal',       'admin'),
  ('admin_wipe',       'sink',     'Account wipe',        'admin');

create table econ.gold_ledger (
  id              bigint generated always as identity,
  player_id       bigint not null,
  delta           bigint not null check (delta <> 0),
  balance_after   bigint not null check (balance_after >= 0),
  reason          text   not null references econ.gold_reason(reason),
  ref_type        text, ref_id bigint,
  balance_version int    not null,
  created_at      timestamptz not null default now(),
  primary key (id, created_at)
) partition by range (created_at);
create index on econ.gold_ledger (player_id, created_at desc);
create index on econ.gold_ledger (reason, created_at desc);
-- monthly partitions, created 3 months ahead by a Go job

-- Same shape for diamonds; separate table so the two economies never mix.
create table econ.diamond_ledger (…) partition by range (created_at);
```

**`transfer` is the class people forget.** PvP theft moves gold between players; counting `attack_steal` as a faucet and `attack_stolen` as a sink makes both charts wrong by the same large number, and they cancel only if nothing else is broken. Making `flow_class` a foreign-keyed column means adding a new reason without classifying it is a **write error**, not a quietly wrong chart three weeks later.

Faucet/sink query behind `/economy`:
```sql
select date_trunc('day', l.created_at)::date as day,
       r.flow_class, r.category, l.reason, r.display_name,
       coalesce(sum(l.delta) filter (where l.delta > 0), 0)  as created,
       coalesce(-sum(l.delta) filter (where l.delta < 0), 0) as destroyed,
       count(*) as txns,
       count(distinct l.player_id) as players
from econ.gold_ledger l
join econ.gold_reason  r using (reason)
where l.created_at >= $1 and l.created_at < $2
group by 1,2,3,4,5
order by 1, 2, 5;
```

Net creation and the health ratio:
```sql
select day,
       sum(created)   filter (where flow_class = 'faucet') as faucet,
       sum(destroyed) filter (where flow_class = 'sink')   as sink,
       sum(created)   filter (where flow_class = 'faucet')
     - sum(destroyed) filter (where flow_class = 'sink')   as net,
       round((sum(destroyed) filter (where flow_class = 'sink'))::numeric
           / nullif(sum(created) filter (where flow_class = 'faucet'), 0), 3) as sink_ratio
from (…above…) t group by day order by day;
```
`sink_ratio` is the number to watch. Sustained below ~0.85 means gold is accumulating faster than the game removes it, and every price in the game is quietly becoming irrelevant.

```sql
create table econ.alarm_rule (
  id bigint primary key generated always as identity,
  name text not null unique,
  metric text not null,            -- 'gold_net','sink_ratio','gold_per_player_p99','refund_rate'
  comparator text not null check (comparator in ('gt','lt')),
  threshold numeric not null,
  window_hours int not null default 24,
  consecutive_windows int not null default 1,
  enabled boolean not null default true,
  severity text not null default 'warning',
  updated_by bigint references admin.admin_user(id),
  updated_at timestamptz not null default now()
);

create table econ.alarm_event (
  id bigint primary key generated always as identity,
  rule_id bigint not null references econ.alarm_rule(id),
  fired_at timestamptz not null default now(),
  observed numeric not null, threshold numeric not null,
  status text not null default 'open' check (status in ('open','acknowledged','resolved')),
  acknowledged_by bigint references admin.admin_user(id),
  note text
);
```
Thresholds are rows, editable at `/economy/alarms` — you will retune them constantly in the first month, and a redeploy per tweak means you stop tuning them.

**Top-holder outliers** (`/economy/holders`): top 100 by gold and by diamonds, each with a 30-day sparkline of their balance and a one-click jump to their ledger. Plus a **Gini coefficient** trend — a single number for "is the economy concentrating?" that a per-player list cannot show.

**Suspicious-activity flags** — a nightly job writes into:
```sql
create table mod.flag (
  id bigint primary key generated always as identity,
  player_id bigint not null,
  kind text not null,              -- see below
  severity smallint not null check (severity between 1 and 5),
  evidence jsonb not null,
  status text not null default 'open' check (status in ('open','reviewing','confirmed','dismissed')),
  detected_at timestamptz not null default now(),
  reviewed_by bigint references admin.admin_user(id), reviewed_at timestamptz, note text
);
create unique index on mod.flag (player_id, kind) where status in ('open','reviewing');
```
Detectors, in the order they will actually catch someone:
- `gold_rate_outlier` — daily `gold_in` above the p99.9 for that level bucket.
- `impossible_collect_rate` — collects/minute above what energy regen physically permits. This should be impossible if the server is authoritative; if it ever fires, **the bug is in the server**, and that is exactly why it is worth detecting.
- `shared_device` — one `device_id` across ≥4 accounts. The classic alt-farm signature.
- `win_trading` — ≥20 attacks with ≥95% win rate against ≤3 distinct defenders. Feeding your own alts.
- `shield_evasion` — attacked immediately at every shield expiry by the same attacker.
- `refund_abuse` — ≥2 refunds, or refund value > 40% of lifetime spend.
- `name_rule_hit` — a name matching a `flag`-class rule (§12).

---

## 10. Battle log browser and replay

```sql
create schema if not exists battle;

create table battle.battle (
  id bigint generated always as identity,
  attacker_id bigint not null, defender_id bigint not null,
  attacker_won boolean not null,
  gold_stolen bigint not null default 0,
  reputation_earned int not null default 0,
  kingdom_id bigint,
  seed bigint not null,                       -- makes the fight reproducible
  balance_version int not null,
  attacker_snapshot jsonb not null,           -- stats + equipment + soldiers at fight time
  defender_snapshot jsonb not null,
  log jsonb not null,                         -- ordered rounds
  duration_ms int not null,
  created_at timestamptz not null default now(),
  primary key (id, created_at)
) partition by range (created_at);
create index on battle.battle (attacker_id, created_at desc);
create index on battle.battle (defender_id, created_at desc);
```

**The replay verifier is the feature worth building.** Combat is deterministic given `(seed, attacker_snapshot, defender_snapshot, balance_version)`. So `POST /admin/battles/{id}/replay` re-runs the fight in Go using the *sealed document from that battle's balance version* and diffs the recomputed log against the stored one.

- Match → green banner "verified deterministic".
- Mismatch → red banner. A mismatch means one of: the combat code changed without a version bump, the balance version was mis-stamped, or a result was tampered with. **All three are things you desperately want to know about and would otherwise never discover.**

```
┌─ Battle #4,812,003   2026-09-04 16:22:11   balance v42  ✅ replay verified ──┐
│ Ser_Bartholomew  lvl 34  812⚔ ─────── VS ─────── Grimwald_III  lvl 31  744⚔  │
│ WINNER: attacker    stolen 38,547g (3.0%)    +10 rep → House Aurelian        │
├────────────────────────────────┬─────────────────────────────────────────────┤
│ ATTACKER SNAPSHOT              │ DEFENDER SNAPSHOT                           │
│  atk 41 def 33 energy 18/42    │  atk 38 def 44                              │
│  ⚔ Ashwood Blade  epic  +38    │  ⚔ Iron Falchion  rare  +24                 │
│  🛡 Chain Hauberk  rare  +21    │  🛡 Plate Cuirass  epic  +41                │
│  🐎 Destrier   legendary +14    │  🐎 Rouncey     uncommon  +7                │
│  4 soldiers (mystic/rare/…)    │  3 soldiers (epic/rare/common)              │
├────────────────────────────────┴─────────────────────────────────────────────┤
│ ROUNDS                                    seed 8814423907712  [Copy] [Re-run]│
│  1  attacker  hits  62   defender 744→682                                    │
│  2  defender  hits  49   attacker 812→763                                    │
│  …                                                                           │
│ 11  attacker  hits  71   defender  38→0     ▸ DEFENDER DOWN                  │
└──────────────────────────────────────────────────────────────────────────────┘
```

Browser filters: attacker, defender, kingdom, won/lost, gold-stolen range, date, balance version, `replay_verified` status. Sorting by `gold_stolen desc` over 24h is the fastest way to find someone farming a whale.

---

## 11. Kingdom browser and moderation

`/kingdoms` lists: name, tag, leader, members, total reputation, total power, gold in members' hands, upgrade levels, created date, flags. `/kingdoms/[id]` shows the roster with per-member reputation contribution, the upgrade tree state, a reputation-over-time chart, and the member join/leave log.

Actions: **rename** (re-runs the name filter, audited), **disband** (owner/moderator, `DangerConfirm` with type-the-name; refunds are *not* automatic — the dialog shows exactly what members lose, and the "refund the founding cost pro-rata" checkbox is explicit and audited), **transfer leadership** (pick a member; used when a leader is banned or goes inactive — this is the most common real request), **kick member**, **freeze recruitment**.

`kingdom.membership_event` is append-only so "who kicked whom" survives a leadership change. Without it, every kingdom drama ticket is unanswerable.

---

## 12. Live ops

```sql
create schema if not exists ops;

create table ops.announcement (
  id bigint primary key generated always as identity,
  title text not null, body text not null, image_url text,
  cta_kind text, cta_target text,               -- 'tab:shop' | 'url:https://…'
  locale text not null default 'en',
  starts_at timestamptz not null, ends_at timestamptz not null,
  min_app_version text, platforms text[] not null default '{ios,android}',
  audience jsonb not null default '{}',         -- {min_level,max_level,kingdom_id,player_ids,is_payer}
  priority int not null default 0,
  status text not null check (status in ('draft','scheduled','live','ended','archived')),
  created_by bigint not null references admin.admin_user(id),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table ops.event (
  id bigint primary key generated always as identity,
  key text not null unique,                     -- 'double_xp_weekend'
  name text not null, description text not null, banner_url text,
  starts_at timestamptz not null, ends_at timestamptz not null,
  modifiers jsonb not null,                     -- {"xp_mult":2.0,"shop_refresh_seconds":150,
                                                --  "drop_rate_mult":1.5,"tier_weight_bias":{"mystic":2.0}}
  audience jsonb not null default '{}',
  status text not null check (status in ('draft','scheduled','live','ended','cancelled')),
  created_by bigint not null references admin.admin_user(id),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
-- No two events may modify the same key at the same time.
create index on ops.event (starts_at, ends_at) where status in ('scheduled','live');
```

**Event modifiers are a separate concept from balance versions, deliberately.** An event is a *temporary, scheduled, overlapping* multiplier; a balance version is a *permanent, atomic, replacing* definition. Modelling "double XP weekend" as a balance publish would mean publishing twice (on and off) and would pollute the version history with operational noise until nobody can find the real balance changes. Keep them separate.

Modifier composition, resolved in Go once per request:
```go
// Multiplicative across concurrently live events. Composition order must not
// matter, so only multiplicative and additive-percentage modifiers are allowed.
// A "set to X" modifier is rejected at validation time precisely because two
// overlapping events could then produce different results depending on order.
func (r *Resolver) Effective(ctx context.Context, p *Player) *EffectiveConfig {
	base := r.balance.Current()
	eff := base.Doc.Clone()
	for _, ev := range r.events.LiveFor(p, time.Now()) {
		eff.ApplyModifiers(ev.Modifiers)
	}
	return eff
}
```

**How the client picks it up:** identical to the balance path (§8). One `GET /v1/bootstrap` returns balance, announcements and events together with a single ETag; every gameplay response carries `X-Config-Epoch`. A newly-scheduled event flipping to `live` changes the epoch, so clients see it within one action or 5 minutes, whichever comes first — **no push infrastructure required**.

`SchedulePreview` renders a timeline of scheduled events and announcements with overlap warnings ("Double XP overlaps Boosted Drops — combined XP multiplier will be 3.0×"). Overlapping multipliers compounding is the classic live-ops accident; make it visible before it ships.

Announcement images should be generated with the Gemini asset pipeline (one 2K sheet → `grid_slice.py` → `rembg_matting.py`) and uploaded to our own storage. **`image_url` must not be an arbitrary URL fetched by our server** — see SSRF in §14.

---

## 13. Moderation queue and name filtering

```sql
create schema if not exists mod;

create table mod.report (
  id bigint primary key generated always as identity,
  reporter_id bigint, target_player_id bigint, target_kingdom_id bigint,
  category text not null check (category in ('name','kingdom_name','cheating','harassment','other')),
  body text not null default '', evidence jsonb not null default '{}',
  status text not null default 'open' check (status in ('open','reviewing','actioned','dismissed')),
  assigned_to bigint references admin.admin_user(id),
  resolution text, resolved_by bigint references admin.admin_user(id), resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index on mod.report (status, created_at);
-- One open report per (reporter, target, category): stops brigading from
-- burying the queue under 400 identical rows.
create unique index on mod.report (reporter_id, target_player_id, category) where status = 'open';

create table mod.name_rule (
  id bigint primary key generated always as identity,
  pattern text not null,
  is_regex boolean not null default false,
  match_mode text not null default 'substring' check (match_mode in ('substring','word','exact')),
  action text not null check (action in ('block','flag')),
  locale text not null default '*',
  note text not null default '',
  enabled boolean not null default true,
  updated_by bigint references admin.admin_user(id),
  updated_at timestamptz not null default now()
);
```

**Normalize before matching**, in Go, in one function used by both the rename path and the sweep:
```go
// Normalize collapses the evasion tricks people actually use.
func Normalize(s string) string {
	s = strings.ToLower(s)
	s = norm.NFKD.String(s)               // decompose accents
	s = stripCombining(s)                 // "ｎı̈ｇ" -> "nig"
	s = leetReplacer.Replace(s)           // 0->o 1->i 3->e 4->a 5->s 7->t @->a $->s !->i
	s = nonAlnum.ReplaceAllString(s, "")  // drop spaces, dots, underscores
	return s
}
```

**`match_mode` exists because of the Scunthorpe problem.** A plain substring blocklist banning `ass` blocks "Assassin", "Ambassador" and "Grassland" — and the resulting support tickets will make you turn the filter off entirely. Short words use `word` mode (regex word boundaries on the *pre-normalized* string); long unambiguous slurs use `substring`.

`/moderation/names` includes a **NameTester**: type a name, see every rule it hits, with the normalized form shown. This turns rule-writing from guesswork into a two-second check, and it is the difference between a filter that is maintained and one that rots.

When a rule changes, a background sweep re-evaluates all existing names and files `mod.report` rows with `category='name'` — a new rule catches history, not just the future.

Queue screen:
```
┌─ Moderation                            open 7 · reviewing 2 · today 14 ──────┐
│ [All][Names][Kingdom names][Cheating][Harassment]   assignee [me ▾]          │
├──┬──────────────┬─────────────┬──────┬────────────────────┬──────────────────┤
│  │ target       │ category    │ #rep │ opened             │                  │
│ ⛔│ Xx_Sl4y3r_xX │ name        │   4  │ 12m ago            │ [Review]         │
│ ⚠ │ House Bl00d  │ kingdom_nam │   2  │ 41m ago            │ [Review]         │
│ ⚠ │ Grimwald_III │ cheating    │   1  │ 2h ago  ⚑ gold_out │ [Review]         │
└──┴──────────────┴─────────────┴──────┴────────────────────┴──────────────────┘
```
Report detail shows the target's full state inline (no tab switch), all reports about them, all `mod.flag` rows, and one-click actions that **resolve the report and take the action in the same audited transaction** — because a moderation tool where "act" and "close ticket" are two steps accumulates a permanent backlog of already-handled tickets.

---

## 14. IAP and refunds

```sql
create schema if not exists billing;

create table billing.purchase (
  id bigint primary key generated always as identity,
  player_id bigint not null,
  platform text not null check (platform in ('ios','android')),
  product_id text not null,
  transaction_id text not null,
  original_transaction_id text,
  price_usd_micros bigint not null,
  currency char(3) not null, price_local numeric not null,
  status text not null check (status in ('pending','verified','failed','refunded','revoked')),
  receipt_ref text not null,           -- pointer to encrypted blob, NOT the raw receipt
  environment text not null check (environment in ('sandbox','production')),
  diamonds_granted bigint not null default 0,
  verified_at timestamptz, refunded_at timestamptz, refund_reason text,
  created_at timestamptz not null default now(),
  unique (platform, transaction_id)
);
create index on billing.purchase (player_id, created_at desc);
create index on billing.purchase (status, created_at desc);

-- Refunds can exceed a player's current diamonds. Debt beats a negative balance:
-- a negative currency breaks every UI and every comparison in the game.
create table billing.clawback_debt (
  player_id bigint primary key,
  diamonds_owed bigint not null default 0 check (diamonds_owed >= 0),
  updated_at timestamptz not null default now()
);
```

- `unique (platform, transaction_id)` is the replay defence: a replayed receipt is an insert conflict, not a second grant.
- **The raw receipt is never a column the panel can select.** It is encrypted in object storage; the panel shows parsed fields and a "re-verify with Apple" button. Raw receipts are re-playable credentials.
- **Sandbox purchases are flagged, never counted in revenue.** Forgetting this is how a dashboard shows $40k from a TestFlight build.
- **Refunds arrive by webhook**, not by polling: App Store Server Notifications V2 / Google RTDN → Go → mark `refunded` → claw back diamonds → clamp at zero and record the remainder as `clawback_debt`, paid off by future purchases.
- `/billing/refunds` is a queue with per-player refund rate and lifetime spend, plus an `refund_abuse` auto-flag rule. **Manual admin refunds are owner-only, require step-up, and are audited** — they move real money.

---

## 15. Realtime: polling, with exactly one stream

**Polling is correct for almost everything here.** The panel has 1–5 concurrent users; a WebSocket layer would be more code, more failure modes, and more attack surface than the problem justifies.

| Surface | Mechanism | Interval | Why |
|---|---|---|---|
| Dashboard KPIs | TanStack Query `refetchInterval` | 60s | rollups update hourly at best |
| Online-now gauge | poll `/admin/metrics/live` | 10s | one Redis `ZCOUNT` |
| Moderation badge | poll | 30s | a 30s-stale count is fine |
| Player detail | on focus + manual refresh | — | you are reading a snapshot to make a decision |
| Balance draft autosave | debounced `PUT` | 2s idle | |
| Simulation | request/response | — | sub-second in Go |
| Battle/audit/ledger tables | on navigation | — | historical data |
| **Alarms, other admins' actions, draft-stolen notice** | **SSE** | — | see below |

**The one stream: `GET /admin/stream` (`text/event-stream`).** It carries only events that must *interrupt* you because someone or something else acted:
- `alarm.fired` — an economy alarm tripped
- `audit.entry` — another admin did something destructive (feeds the footer ticker)
- `balance.published` — **critical**: if you are editing draft v43 and someone publishes v42-derived v44, your diff baseline just moved. The editor shows an inline warning instead of letting you publish against a stale baseline.
- `report.created` — a new high-severity report

Server: Go writes SSE frames with a 20s heartbeat comment to defeat idle proxy timeouts, fed by a Redis pub/sub channel so any instance can serve any admin. Next.js proxies it through `app/api/stream/route.ts` (Node runtime, `export const dynamic = "force-dynamic"`) so the browser talks same-origin and the cookie is forwarded.

Client: native `EventSource` with exponential-backoff reconnect, mounted once in `(app)/layout.tsx`. On `balance.published`, invalidate the `balance` query key and show a `sonner` toast.

**Rule to write down:** *stream only what another actor changed; poll everything you are merely watching.*

---

## 16. Contract-first workflow: one spec, two generators

```
                    api/openapi/admin.v1.yaml   (OpenAPI 3.1 — the ONLY source of truth)
                                │
              ┌─────────────────┴──────────────────┐
              ▼                                    ▼
      oapi-codegen v2.8.0                  openapi-typescript 7.13.0
      (strict-server + chi)                          │
              ▼                                      ▼
  api/internal/adminapi/server.gen.go   admin/src/lib/api/schema.gen.ts
              │                                      │
     implement StrictServerInterface          openapi-fetch 0.17.0
     → compile error on drift                 → type error on drift
```

`api/openapi/admin.cfg.yaml`:
```yaml
package: adminapi
output: internal/adminapi/server.gen.go
generate:
  strict-server: true      # handlers take (ctx, TypedRequest) and return TypedResponse.
  chi-server: true         # No manual json.Decode, no manual WriteHeader — which
  models: true             # removes the whole class of "returned 200 with an error body".
  embedded-spec: true      # /admin/openapi.json for the panel's dev tooling
output-options:
  nullable-type: true
  skip-prune: false
```

```go
//go:generate go tool oapi-codegen -config ../../openapi/admin.cfg.yaml ../../openapi/admin.v1.yaml
```

oapi-codegen v2.8.0 requires **Go 1.25+** (we have 1.27) and **`github.com/oapi-codegen/runtime` v1.6.0+** (v1.7.0 is current) for the new Duration type, escaped path-parameter handling and typed response headers ([v2.8.0 release notes](https://github.com/oapi-codegen/oapi-codegen/releases/tag/v2.8.0)).

TypeScript side:
```jsonc
// admin/package.json
"scripts": {
  "gen:api": "openapi-typescript ../api/openapi/admin.v1.yaml -o src/lib/api/schema.gen.ts",
  "gen:check": "pnpm gen:api && git diff --exit-code src/lib/api/schema.gen.ts"
}
```

```ts
// admin/src/lib/api/client.ts
import "server-only";
import createClient from "openapi-fetch";
import { cookies, headers } from "next/headers";
import type { paths } from "./schema.gen";

// http://admin-api:8081 on the Docker network. This host is not routable from
// the internet; there is deliberately no public hostname for it.
const BASE = process.env.API_INTERNAL_URL!;

export async function apiFromCookies() {
  const [c, h] = await Promise.all([cookies(), headers()]);
  const session = c.get("__Host-emp_admin")?.value;
  return createClient<paths>({
    baseUrl: BASE,
    headers: {
      ...(session ? { cookie: `__Host-emp_admin=${session}` } : {}),
      // Forwarded so Go can enforce the IP allowlist and pin the audit row to
      // the human's real address, not the container's.
      "X-Forwarded-For": h.get("cf-connecting-ip") ?? h.get("x-forwarded-for") ?? "",
      "X-Admin-UA": h.get("user-agent") ?? "",
      "Cf-Access-Jwt-Assertion": h.get("cf-access-jwt-assertion") ?? "",
    },
  });
}
```

**Why not tRPC or Server Actions as the contract?** The contract crosses a Go↔TypeScript boundary; tRPC cannot express that, and Server Actions have no schema a Go server can generate against. Server Actions are still used — but only as thin authenticated wrappers around the generated client, never as the contract.

**Why two specs?** `game.v1.yaml` and `admin.v1.yaml` are separate files feeding separate routers on separate ports. The game client's codegen physically cannot emit an admin type, so no admin surface can be leaked into a shipped app binary.

CI enforcement (`.github/workflows/ci.yml`):
```yaml
- name: Lint spec
  run: go tool vacuum lint -d api/openapi/admin.v1.yaml
- name: Breaking-change check vs main
  run: go tool oasdiff breaking origin/main:api/openapi/admin.v1.yaml api/openapi/admin.v1.yaml
- name: Go codegen drift
  run: cd api && go generate ./... && git diff --exit-code
- name: TS codegen drift
  run: cd admin && pnpm gen:check
- name: Typecheck
  run: cd admin && pnpm tsc --noEmit
```
A spec change with stale generated code fails the build. That is the whole mechanism, and it is enough.

---

## 17. Development and deployment

`ops/compose.yml`:
```yaml
services:
  api:                                    # public game API
    image: ghcr.io/${GH_OWNER}/emperors-api:${TAG}
    command: ["-mode=game", "-addr=:8080"]
    environment:
      DATABASE_URL:        ${DATABASE_URL}          # Neon pooled
      DATABASE_URL_DIRECT: ${DATABASE_URL_DIRECT}   # un-pooled: LISTEN/NOTIFY only
      REDIS_ADDR: redis:6379
    depends_on: [redis]
    networks: [edge, internal]
    restart: unless-stopped

  admin-api:                              # SAME image, admin router
    image: ghcr.io/${GH_OWNER}/emperors-api:${TAG}
    command: ["-mode=admin", "-addr=:8081"]
    environment:
      DATABASE_URL:          ${DATABASE_URL}
      DATABASE_URL_REPLICA:  ${DATABASE_URL_REPLICA}   # Neon read replica: analytics + SQL console
      DATABASE_URL_DIRECT:   ${DATABASE_URL_DIRECT}
      REDIS_ADDR: redis:6379
      ADMIN_TOTP_KEY:  ${ADMIN_TOTP_KEY}
      CF_ACCESS_TEAM:  ${CF_ACCESS_TEAM}
      CF_ACCESS_AUD:   ${CF_ACCESS_AUD}
      REQUIRE_CF_ACCESS: "true"
    # NO ports: — reachable only from admin-web on the internal network.
    networks: [internal]
    restart: unless-stopped

  admin-web:
    image: ghcr.io/${GH_OWNER}/emperors-admin:${TAG}
    environment:
      API_INTERNAL_URL: http://admin-api:8081
      NODE_ENV: production
    # NO ports: — reachable only from cloudflared.
    networks: [internal]
    restart: unless-stopped

  cloudflared:
    image: cloudflare/cloudflared:latest
    command: ["tunnel", "--no-autoupdate", "run", "--token", "${CF_TUNNEL_TOKEN}"]
    networks: [internal]
    restart: unless-stopped

  caddy:
    image: caddy:2-alpine
    ports: ["80:80", "443:443"]            # game API only
    volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro", "caddy_data:/data"]
    networks: [edge]
    restart: unless-stopped

  redis:
    image: redis:8-alpine
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD}"]
    volumes: ["redis_data:/data"]
    networks: [internal]
    restart: unless-stopped

networks:
  edge:
  internal:
    internal: true                          # no egress to the internet at all
volumes: { caddy_data: {}, redis_data: {} }
```

Two structural points:
- **`admin-web` has no `ports:` and no `DATABASE_URL`.** The two most valuable properties of this design are both visible right here in the compose file.
- **`internal: true`** blocks outbound internet from `admin-web`. A compromised npm package cannot exfiltrate to an attacker-controlled host. (Note: `cloudflared` and `api` need egress, so they also attach to `edge`; `admin-web` does not.)

`admin/Dockerfile`:
```dockerfile
# syntax=docker/dockerfile:1
FROM node:22-alpine AS deps
RUN corepack enable && corepack prepare pnpm@11.25.0 --activate
WORKDIR /app
COPY admin/package.json admin/pnpm-lock.yaml admin/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

FROM node:22-alpine AS build
RUN corepack enable && corepack prepare pnpm@11.25.0 --activate
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY admin/ ./
COPY api/openapi/admin.v1.yaml /openapi/admin.v1.yaml
RUN pnpm gen:api && pnpm build      # next.config.ts: output: "standalone"

FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0
RUN addgroup -g 1001 nodejs && adduser -S -u 1001 -G nodejs nextjs
COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=build --chown=nextjs:nodejs /app/public ./public
USER nextjs
EXPOSE 3000
CMD ["node", "server.js"]
```
`output: "standalone"` produces a self-contained tree with a single `server.js` and no `node_modules` in the final image — the standard, well-supported self-hosting path ([Next.js self-hosting](https://nextjs.org/docs/app/guides/self-hosting)).

`admin/proxy.ts`:
```ts
// Next 16: this file replaces middleware.ts. The exported symbol MUST be
// `proxy` and the file MUST be named proxy.ts — a leftover middleware.ts is
// silently ignored at build time with no error, which would leave every route
// unguarded. Runtime is nodejs and is not configurable.
import { NextResponse, type NextRequest } from "next/server";

export function proxy(req: NextRequest) {
  // UX ONLY. Authorization is enforced by the Go admin API on every single
  // request. CVE-2025-29927 (x-middleware-subrequest, CVSS 9.1) is exactly what
  // happens when a Next.js edge/proxy layer is treated as a security boundary.
  const authed = req.cookies.has("__Host-emp_admin");
  const onAuthPage = req.nextUrl.pathname.startsWith("/login");

  if (!authed && !onAuthPage) {
    const url = req.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("next", req.nextUrl.pathname + req.nextUrl.search);
    return NextResponse.redirect(url);
  }
  if (authed && onAuthPage) {
    return NextResponse.redirect(new URL("/", req.url));
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|api/auth).*)"],
};
```

**Local development**: `colima start` (it is currently stopped), then `docker compose -f ops/compose.dev.yml up` for Postgres-in-Docker + Redis, `air` for the Go server, `pnpm dev` for the panel on `:3000` with `API_INTERNAL_URL=http://localhost:8081`.

**Dev auth bypass — use a build tag, not an env var:**
```go
//go:build !prod
package admin
const devBypassCompiled = true
```
```go
//go:build prod
package admin
const devBypassCompiled = false
```
Production images build with `-tags prod`, so the bypass code **is not in the binary**. An env var can be set by an attacker who gets shell or by a mistyped compose file; a build tag cannot be turned on at runtime by anyone.

**Deploy** (`.github/workflows/deploy.yml`): build both images → push to GHCR → SSH to the VPS → `docker compose pull && docker compose up -d`. Migrations run as a one-shot `goose up` container **before** the app containers, with expand/contract migrations only (add column → deploy → backfill → deploy → drop column) so a rollback never requires a down migration. Neon branches make pre-flight migration testing free: branch the production database, run `goose up` on the branch, verify, discard.

---

## 18. Security review

| # | Threat | Vector | Mitigation |
|---|---|---|---|
| 1 | **Admin panel reachable from the internet** | Anyone finds `admin.…` | Cloudflare Tunnel (no inbound ports) + Cloudflare Access identity gate + Go verifies `Cf-Access-Jwt-Assertion` against Cloudflare JWKS + admin API has no public listener. Four independent layers. |
| 2 | **CSRF on mutations** | Attacker page triggers a Server Action | `SameSite=Strict` + `__Host-` cookie; Go rejects requests whose `Origin`/`Sec-Fetch-Site` is not same-origin; Next's built-in Server Action origin check with `serverActions.allowedOrigins` set explicitly for the tunnel hostname. |
| 3 | **Auth bypass via the proxy layer** | The CVE-2025-29927 class (`x-middleware-subrequest`) | `proxy.ts` is never an authz boundary — it only redirects. Every endpoint re-checks in Go. Documented in the file itself. |
| 4 | **Server Actions are public endpoints** | `curl` with a crafted payload | Every action: `zod.strict()` parse → `requirePermission` → generated client → **Go re-checks permission, step-up, and caps**. Skipping any layer still leaves Go enforcing. |
| 5 | **Mass assignment (balance editor)** | Extra JSON keys, or editing fields the UI does not show | Go `json.Decoder.DisallowUnknownFields`; `schema_version` must match exactly; server-owned fields (`id`,`seq`,`doc_hash`,`sealed_at`,`created_by`) never read from the request; sealed versions immutable; per-role edit permission. |
| 6 | **IDOR / wrong-target actions** | Typo'd or enumerated player id | Admins legitimately see all players, so the real risk is *wrong target*: `uuidv7` public ids in URLs (no neighbours to hit), `DangerConfirm` re-fetches and re-displays the target at confirm time, and destructive ops require typing the target's **name**. |
| 7 | **SSRF** | `announcement.image_url` fetched server-side | The server never fetches admin-supplied URLs. Images are uploaded to our own storage. If a fetch is ever needed: scheme+host allowlist, resolve DNS and reject private/loopback/link-local/169.254.169.254, no redirects, 2s timeout. |
| 8 | **SQL injection** | The owner SQL console | Everything else is sqlc/pgx parameterized. The console runs on a **Neon read replica** as `emperors_analyst`: `default_transaction_read_only=on`, `statement_timeout=10s`, no grants on `admin.*` or `billing`, 10k-row cap, query text audited, owner-only, step-up required. |
| 9 | **Stolen admin session** | XSS, laptop theft, cookie exfil | `HttpOnly`+`Secure`+`SameSite=Strict`+`__Host-`; 30m idle / 8h absolute; **step-up 2FA within 5 minutes for every destructive action** — a stolen cookie alone cannot grant currency or ban anyone. |
| 10 | **Credential stuffing / brute force** | Reused password | argon2id 64MiB/t=3; per-account lockout with exponential backoff; per-IP Redis rate limit; breached-password list; **mandatory 2FA**; every attempt in `admin.login_attempt`. |
| 11 | **Phishing an admin** | Fake login page harvesting TOTP | **WebAuthn passkeys as the primary factor** — origin-bound, non-phishable. Cloudflare Access as an independent identity gate. TOTP is the documented weaker fallback. |
| 12 | **Insider / rogue admin** | A legitimate admin acts maliciously | Hash-chained `admin.audit_log` with `UPDATE`/`DELETE` revoked; nightly chain verification + off-box export; grant caps; two-person approval above caps; daily digest email of destructive actions; `actor_role` recorded at action time. |
| 13 | **Unaudited mutation** | New endpoint forgets the log | `audit.Do` is the only sanctioned way to open a transaction in admin handlers; the audit insert is *in* the transaction so it cannot be skipped; a lint rule fails CI on `db.Begin` inside `internal/adminapi`. |
| 14 | **Admin API abuse / runaway script** | Compromised session automating grants | Redis token buckets per `(admin_id, action_class)`; destructive classes get tiny buckets; **global circuit breaker**: >N currency grants/hour auto-freezes grants and pages the owner. Rate-limit the admin API exactly like the public one. |
| 15 | **XSS** | Player-supplied names, report bodies, audit reasons | React escapes by default; **`dangerouslySetInnerHTML` banned by ESLint**; strict CSP with per-request nonce (`default-src 'self'; script-src 'self' 'nonce-…'; frame-ancestors 'none'; object-src 'none'; base-uri 'self'`). |
| 16 | **Supply-chain attack in npm deps** | Malicious version of a transitive dep | `minimumReleaseAge: 10080` (7 days), `blockExoticSubdeps: true`, `--frozen-lockfile`, Dependabot, **and the two structural controls: no `DATABASE_URL` in the container and `internal: true` blocking egress**. |
| 17 | **Secrets leakage** | Server code imported into a client bundle | `import "server-only"` at the top of every `lib/api/*` and `lib/auth/*` file — it is a *build* error, not a review checklist item. No `NEXT_PUBLIC_*` secret ever. |
| 18 | **Balance publish catastrophe** | A typo makes gold 100× | Strict decode + semantic validator; server-enforced risk acknowledgement; simulator diff shown before publish; **one-row rollback**; optional cohort rollout (phase 2); `pg_advisory_xact_lock` prevents concurrent publishes. |
| 19 | **Impersonation abuse** | Admin plays as a whale, takes actions | Read-only inspect is the default; write-impersonation is owner-only, 15 min max, shows an in-game banner to the player, and double-logs every action with `impersonated_by`. |
| 20 | **PII exposure** | Analyst dumps emails/receipts | Column-level grants: `emperors_analyst` has no `SELECT` on `player.email`, `billing.receipt_ref`, or `admin.*`; exports are audited and row-capped; raw receipts are encrypted outside Postgres. |
| 21 | **Log injection** | Newlines/ANSI in an audit `reason` | `reason` stored as a parameterized value and rendered as text; structured JSON logs (`slog`); no log line is ever built by concatenation. |
| 22 | **Neon credential compromise** | `DATABASE_URL` leaks | Only the Go containers hold it; rotate via Neon roles; Neon IP allowlist restricted to the VPS egress IP; separate least-privilege roles for app / analyst / migration. |

---

## 19. The epic/mystic colour conflict — resolution

The brief specifies **epic = purple** and **mystic = purple**. Two of seven tiers sharing a colour defeats the entire point of tier colours: at a glance in an inventory grid, a player cannot tell a mid-tier item from a near-top-tier one, and the item they are most excited about looks identical to one they will vendor.

**Proposal, in priority order:**

1. **Make it data, not code.** `tiers[*].color` and `tiers[*].frame` live in the balance document (§8). The owner changes a hex value in the admin panel and every client picks it up within 5 minutes — no rebuild, no App Store review. **This is the real fix**, because it converts a permanent argument into a five-second experiment.
2. **Recommended values:** epic stays `#A855F7` (purple); **mystic becomes cyan `#22D3EE`**. Cyan is maximally distant from gray/green/blue/purple/yellow/red in both hue and perceived lightness, it reads as "otherworldly" rather than "just better purple," and it survives the ~8% of male players with red-green colour vision deficiency — a group for whom green/yellow/red are already partly collapsed and who therefore rely heavily on the blue-cyan axis.
3. **If the owner insists both stay purple:** differentiate by *treatment*, not hue — epic gets a flat purple frame, mystic gets an animated shimmer/gradient frame plus a distinct corner glyph. The `frame` field in the tier document exists for exactly this. Colour alone should never be the only channel carrying tier information anyway.

Note the second-order benefit: with colours in the balance document, the admin panel's `TierCurveEditor` renders live swatches, so the owner sees the whole seven-tier ramp side by side while editing. That is when the conflict becomes obvious and gets settled.

---

## 20. Implementation phases

**Phase 0 — foundations (before any panel code).** Agree `openapi/admin.v1.yaml` skeleton; goose migrations for `admin.*`, `cfg.*`, `econ.*`; `audit.Do`; the two-listener Go binary; compose + Cloudflare Tunnel + Access. *Nothing in the panel works until Go can authenticate an admin and write an audit row.*

**Phase 1 — auth + shell.** Login → 2FA → session; `proxy.ts`; AppShell; `/settings/{admins,sessions,security}`; audit log viewer. Ship this alone and it is already useful — it proves the whole security model end to end.

**Phase 2 — players.** Search, detail tabs, the action catalogue, `DangerConfirm`, `StepUpDialog`, grant caps. This is what the owner uses on day one of soft launch.

**Phase 3 — balance editor.** Doc schema, validator, draft CRUD, diff, risk, publish/rollback, `Store` + LISTEN/NOTIFY, client `bootstrap` endpoint. **Then** the simulator. Ship publish before simulate — publish without simulate is usable; simulate without publish is a toy.

**Phase 4 — analytics.** Rollup jobs, `daily_kpi`, cohorts, dashboard, economy faucet/sink, alarms. Needs real traffic to be meaningful, so it can trail the launch.

**Phase 5 — moderation, battles, kingdoms, live ops.** Driven by actual soft-launch pain; build in the order the tickets arrive.

**Phase 6 — billing, SQL console, cohort rollout, ASC ingestion.**

---

## Critical Files for Implementation

- `/Users/yigitkarabulut/Developer/Emperors/api/internal/balance/publish.go` — the versioned publish/rollback transaction: advisory lock, optimistic concurrency on `base_hash`, strict decode, validation, server-enforced risk acknowledgement, seal-and-hash, append-only activation, transactional `pg_notify`, and the in-transaction audit row. Everything else in the balance feature is presentation around this file.
- `/Users/yigitkarabulut/Developer/Emperors/api/internal/audit/audit.go` — `audit.Do`, the single sanctioned way to open a transaction in an admin handler. Makes "every admin action is logged with before/after" a structural property rather than a code-review convention.
- `/Users/yigitkarabulut/Developer/Emperors/api/openapi/admin.v1.yaml` — the only source of truth for the Go↔TypeScript contract; feeds `oapi-codegen` (strict server) and `openapi-typescript`, with CI drift checks on both sides.
- `/Users/yigitkarabulut/Developer/Emperors/admin/src/lib/balance/diff.ts` — identity-keyed flatten + diff, the basis of the diff viewer, the risk assessment, and the publish confirmation.
- `/Users/yigitkarabulut/Developer/Emperors/api/internal/balance/store.go` — the hot-path config snapshot with `LISTEN/NOTIFY` on a **direct, un-pooled Neon connection** plus a 60s reconciliation poll. The pooler/LISTEN interaction is the single most likely silent failure in this design.
- `/Users/yigitkarabulut/Developer/Emperors/ops/compose.yml` — encodes the two decisions that carry the most security weight: `admin-api` and `admin-web` have no published ports, and `admin-web` has no database credentials and no internet egress.

**Sources:** [Next.js 16](https://nextjs.org/blog/next-16) · [Next.js 16 upgrade guide](https://nextjs.org/docs/app/guides/upgrading/version-16) · [Next.js self-hosting](https://nextjs.org/docs/app/guides/self-hosting) · [vercel/next.js#95633 (TypeScript 7)](https://github.com/vercel/next.js/discussions/95633) · [InfoQ: TypeScript 7.0 released](https://www.infoq.com/news/2026/08/typescript-7-released/) · [oapi-codegen v2.8.0 release](https://github.com/oapi-codegen/oapi-codegen/releases/tag/v2.8.0) · [PostgreSQL 18 release notes](https://www.postgresql.org/docs/current/release-18.html) · [PostgreSQL 18 virtual generated columns](https://hashrocket.com/blog/posts/postgresql-18-virtual-generated-columns) · [Neon connection pooling](https://neon.com/docs/connect/connection-pooling) · [Neon read replicas](https://neon.com/docs/introduction/read-replicas) · [Cloudflare Access linked app token / JWT](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/linked-app-token/) · [Cloudflare Zero Trust pricing 2026](https://costbench.com/software/business-vpn/cloudflare-zero-trust/) · [Better Auth 1.7](https://better-auth.com/blog/1-7) · [Better Auth 2FA](https://better-auth.com/docs/plugins/2fa) · [go-webauthn/webauthn](https://github.com/go-webauthn/webauthn) · [pnpm supply-chain security](https://pnpm.io/supply-chain-security) · [TanStack Table v9](https://tanstack.com/blog/announcing-tanstack-table-v9) · [Makerkit: Server Actions security](https://makerkit.dev/blog/tutorials/secure-nextjs-server-actions) · [shadcn/ui CLI](https://ui.shadcn.com/docs/cli)

---

## Key decisions

- **The admin panel talks exclusively to the Go /admin API and holds NO database credentials — no Drizzle, no Prisma, no pg, not even for read-only dashboard queries.**
  - Rejected: Connect Next.js directly to Neon with Drizzle (or the common compromise: Drizzle for reads, API for writes).
  - Why: Three decisive reasons. (1) The audit log must commit in the same transaction as the mutation; a second writer that logs afterwards produces unlogged currency grants on any crash. (2) Admin operations are not table writes — 'grant gold' means ledger row + balance_version stamp + cache bust + alarm check; 'ban' means flag + Redis session revoke + matchmaking removal. A schema-only writer corrupts these within weeks. (3) It is the single largest blast-radius reduction available: with ~600 transitive npm packages in the web tier, one dependency RCE would otherwise equal total game-DB compromise including the ability to erase the audit log. The read-only-creds compromise is rejected because a read-only credential still exposes every email, every receipt, and the entire audit log, and still causes schema drift, for zero latency benefit once rollup tables exist. The analytics cost is paid by server-defined named aggregate queries, daily rollup tables, and an owner-only SQL console that Go runs on a Neon read replica as a constrained read-only role.
- **Host the panel on the same VPS in the same Docker Compose network, exposed only through a Cloudflare Tunnel behind Cloudflare Access. The admin API listens on :8081 with no ports: mapping at all.**
  - Rejected: Deploy the panel to Vercel (the CLI is already installed and configured).
  - Why: Vercel forces the Go admin API onto a public hostname so Vercel's servers can reach it, converting the strongest control in the design — an admin API with no public interface — into a bearer token on the internet. You would then rebuild with Access service tokens or mTLS what the Docker bridge network gave for free. It also adds transatlantic egress to a London Neon and a London VPS on every dashboard query. Cloudflare Tunnel is free with no usage limits and needs zero inbound firewall rules; Zero Trust Access is free to 50 users and injects a verifiable JWT the Go API checks against Cloudflare's JWKS. Cost accepted: no preview deployments, replaced by a small GitHub Action.
- **Admin identity, password hashing, 2FA, sessions and RBAC are owned by Go, not by Next.js. The panel holds only an opaque session cookie.**
  - Rejected: Better Auth 1.7 in Next.js (admin plugin with RBAC + impersonation, TOTP encrypted with the auth secret, npx auth create-admin).
  - Why: Follows inevitably from the API-only decision: if Go must write the audit row inside the mutation's transaction, Go must know who the actor is. Any design where Next authenticates and then asserts an identity to Go creates a second trust boundary and a token-minting service to secure. Better Auth is genuinely excellent and would be the right call in an all-TypeScript stack, but here it puts identity tables in the game database under a second migration tool while Go still has to independently validate every session. The Go equivalent is ~500 lines over ecosystem-standard libraries (argon2id v1.0.0, pquerna/otp v1.5.0, go-webauthn v0.18.0).
- **Model balance as ONE immutable, hash-sealed JSON document per version, with an append-only activation log; the newest activation row IS the live config.**
  - Rejected: Normalized relational tables per concept (collect_jobs, item_defs, shop_weights, upgrade_costs) with a version column on each.
  - Why: Makes five otherwise-hard things trivial: publish is one atomic insert (no window where jobs are v42 and shop weights are v41); diff is a pure function of two documents rather than a 12-table join; rollback is a single appended row instead of a reverse migration; the client cache key is one ETag for the whole config; and the simulator can evaluate any version without touching live tables. The lost referential integrity is paid back by strict Go decoding plus a semantic validator that catches strictly more than FKs could — an FK cannot express 'unlock levels must be non-decreasing' or 'gold-per-energy must improve up the ladder'.
- **The balance simulator runs the production Go economy code (economy.New(*balance.Doc)) against an arbitrary document. It contains zero formulas of its own.**
  - Rejected: Reimplement the economy formulas in TypeScript so the simulator runs instantly in the browser.
  - Why: A TS reimplementation drifts within one sprint and then confidently lies to the designer about the consequences of a change — worse than having no simulator, because it is trusted. Running the real code means the simulator is correct by construction and updates automatically when the game does. 10k Monte Carlo trials x 2 documents x 6 archetypes runs in well under a second in Go, so the endpoint stays synchronous with a 10s deadline.
- **Publish enforces server-side risk acknowledgement: Go computes high-severity risk codes from the actual diff and refuses the publish if any is missing from ack_risks.**
  - Rejected: Client-side warning banners plus a single 'I understand' checkbox.
  - Why: A single checkbox is trained away in a week. Per-risk codes derived server-side from the real diff cannot be bypassed by a crafted request, and they force the designer to read what specifically changed ('collect gold drops ~12%', 'steal rate 3% to 5%') rather than acknowledging an abstraction. The client copy of the risk rules drives the UI only; both copies are generated from one shared hot-path table so they cannot drift.
- **Step-up 2FA re-authentication (5-minute window) is required for every destructive action, on top of the normal session.**
  - Rejected: A single login with 2FA that grants full privileges for the whole 8-hour session.
  - Why: It is what makes a stolen session cookie insufficient for the actions that actually matter — granting currency, banning, wiping, publishing balance, refunding. Combined with WebAuthn passkeys as the primary factor (origin-bound and non-phishable, unlike TOTP), it means an XSS or a stolen laptop yields read access rather than the ability to mint unlimited gold.
- **The audit log is a hash chain (entry_hash = sha256(prev_hash || canonical row)), with UPDATE/DELETE/TRUNCATE revoked from the application role and nightly chain verification plus off-box export.**
  - Rejected: A plain append-only audit table with application-level discipline.
  - Why: Without it, anyone who reaches the database — including a rogue admin or an attacker who escalated — can quietly erase their own trail, which defeats the log's entire purpose. The chain makes tampering detectable within 24 hours even by someone with full DB access, and the REVOKE means the application literally cannot rewrite history. This is genuine non-repudiation rather than decoration.
- **econ.gold_reason is a lookup table with a foreign-keyed flow_class of faucet | sink | TRANSFER, and gold_ledger.reason references it.**
  - Rejected: A Go enum of reasons with the faucet/sink classification hard-coded in the dashboard queries.
  - Why: PvP theft moves gold between players; counting attack_steal as a faucet and attack_stolen as a sink makes both charts wrong by the same large number and they cancel only while nothing else is broken. Making the classification a foreign-keyed column means adding a new reason without classifying it is a write error at insert time, not a quietly wrong inflation chart discovered three weeks later.
- **Polling everywhere, with exactly one SSE stream (/admin/stream) reserved for events another actor caused.**
  - Rejected: A WebSocket layer for live dashboard updates.
  - Why: With 1-5 concurrent users, WebSockets are more code, more failure modes and more attack surface than the problem justifies. The rule is: stream only what another actor changed, poll everything you are merely watching. SSE earns its place for one case in particular — if you are editing draft v43 and someone else publishes, your diff baseline has silently moved, and the editor must interrupt you rather than let you publish against a stale baseline.
- **Live-ops events (double XP, boosted drops) are a separate concept from balance versions, with multiplicative-only modifiers composed server-side.**
  - Rejected: Model a double-XP weekend as a balance publish, then publish again to turn it off.
  - Why: Two publishes per event would fill the version history with operational noise until real balance changes become unfindable. Events are temporary, scheduled and overlapping; balance versions are permanent, atomic and replacing. Restricting modifiers to multiplicative/additive-percentage (rejecting 'set to X' at validation) guarantees composition order cannot change the result when two events overlap.
- **Ship a battle replay verifier that re-runs each fight in Go from (seed, snapshots, sealed balance doc) and diffs against the stored log.**
  - Rejected: A read-only battle log browser.
  - Why: Combat is already deterministic given those inputs, so verification is nearly free. A mismatch means one of three things you would otherwise never discover: combat code changed without a version bump, the balance version was mis-stamped, or a result was tampered with. It doubles as the strongest anti-cheat signal available.
- **Pin TypeScript to the 6.x line rather than adopting TypeScript 7.0.2.**
  - Rejected: Use TypeScript 7 (the Go-native tsc, 8-12x faster) since it is what npm install would fetch today.
  - Why: Verified today: TS 7.0 shipped without the programmatic JS API (due in 7.1), which broke every framework integrating via that API. Next.js had to work around it by invoking tsc directly, available only behind experimental.useTypeScriptCli in 16.3. typescript-eslint also cannot use it yet. A console that mints currency and bans players should not start on an experimental compiler path for a build-speed win on a small codebase.
- **Resolve the epic/mystic purple conflict by moving tier colours into the balance document (recommending mystic = cyan #22D3EE), rather than picking a colour in code.**
  - Rejected: Hard-code the corrected palette in the Godot client.
  - Why: Two of seven tiers sharing a colour defeats the point of tier colours entirely — the item a player is most excited about looks identical to one they will vendor. Putting colour and frame in the document turns a permanent argument into a five-second experiment the owner runs himself, with no rebuild and no App Store review. Cyan is recommended because it is maximally distant from the rest of the ramp in both hue and lightness and survives red-green colour vision deficiency, which already partly collapses the green/yellow/red end of this ladder.

## Risks flagged

- The collect job ladder as specified in the brief is mathematically a no-op: grapes (1 energy to 2 gold) and strawberries (2 energy to 4 gold) are both exactly 2.0 gold per energy. With one shared energy pool, unlocking a higher job changes nothing — the player taps half as often for twice as much. Unless gold-per-energy rises up the ladder, the entire Collect tab has no progression. The balance validator ships a `flat_gold_per_energy` warning that surfaces this on day one, but the underlying design needs an owner decision.
- LISTEN/NOTIFY silently does not work through Neon's PgBouncer, which runs in transaction pooling mode. If the balance Store uses the pooled DATABASE_URL, publishes will appear to succeed in the admin panel and game servers will simply never pick them up — with no error anywhere. Mitigated by a mandatory separate DATABASE_URL_DIRECT (endpoint without `-pooler`) plus a 60s reconciliation poll, but this is the single most likely silent failure in the whole design and belongs in the runbook.
- A leftover `middleware.ts` in the Next.js 16 app is ignored at build time with no error or warning. If anyone migrates code from a Next 15 tutorial or an older project, route guarding silently stops running. The design deliberately makes `proxy.ts` non-load-bearing for security (Go enforces everything), so this degrades UX rather than opening a hole — but only because of that choice.
- Offline tax accrual across a balance publish is approximated: accrual uses the rate current when the player returns, not the rates that were actually live during the window. Recommended for simplicity, but if a tax rate is ever cut sharply, returning players will be credited at the new lower rate for time they earned under the old one, which generates support tickets that are individually unanswerable without segmenting the accrual by activation timestamps (~80 extra lines).
- The risk-assessment rules exist in two implementations — TypeScript for the UI and Go for enforcement. They are generated from one shared hot-path table to prevent drift, but if that generation step is ever bypassed the UI could show a designer fewer risks than the server will demand, producing confusing 412 responses at the worst possible moment.
- The audit log stores the complete before/after balance document on every publish (potentially ~100KB each). Correct for post-mortems and cheap at a few publishes per week, but if publish frequency ever rises sharply (a designer iterating live) the audit partition will grow quickly. Player-action audit rows store only touched fields, so this is contained to balance publishes.
- Cloudflare Access on the free tier retains logs for only 24 hours. If the identity-layer logs are ever needed for an incident older than a day, they are gone — the application-side `admin.login_attempt` and hash-chained `admin.audit_log` are the durable record, so Access logs must not be relied on for forensics.
- The IP allowlist is a genuine lockout risk when the owner travels, and with Cloudflare Access already in front its marginal security value is small. Shipped defaulted off with a documented SSH recovery path (`emperors-admin unlock --email …`), but turning it on without testing the recovery path first is a plausible way to lock yourself out of your own live-ops console.
- Neon read replicas are eventually consistent. Dashboard numbers and SQL-console results can lag the primary by seconds to minutes. Harmless for daily rollups, but confusing if someone grants gold and then immediately queries for it on the replica — the metrics UI needs a visible 'as of' timestamp so this does not read as a bug.
- `analytics.player_day` has one row per active player per day. At meaningful scale this is the largest table in the system and drives Neon compute cost for every dashboard query. It is unpartitioned in this design; if DAU grows past roughly six figures it will need monthly partitioning and a retention policy, which is easier to add before the table is large.
- Both the Go admin API and the Next panel are built from the same repo and deployed together, but the OpenAPI drift check only runs in CI. A hotfix deployed by SSHing to the VPS and running `docker compose up` with a hand-built image bypasses that check entirely and can ship a panel whose types no longer match the server.
- Colima (the Docker daemon) is currently stopped and no Android SDK/JDK is installed. Nothing in the admin panel depends on Android, but the local development loop for the whole stack is blocked until colima is started, and the Dockerfile/compose files here have therefore not been executed.

## Questions raised for the owner

- VPS region: Neon is in eu-west-2 (London), and every game request hits Postgres several times while dashboard aggregates run 10-30 queries. DigitalOcean LON1 sits within a few ms of Neon; Hetzner has no London region, so Falkenstein/Helsinki adds roughly 15-25ms per query (0.3-0.75s of pure latency on a dashboard page load). Is the Hetzner cost saving worth that, or should this be DigitalOcean LON1?
- The collect ladder in the brief is flat in gold-per-energy (grapes 1:2, strawberries 2:4 — both exactly 2.0), which makes unlocking higher jobs give the player literally no advantage. Should gold-per-energy rise up the ladder (e.g. 2.00, 2.25, 2.60, 3.00), or is the intended progression something else entirely — bigger single taps for players with more energy, per-job cooldowns, or job-specific item drops?
- Epic and mystic are both specified as purple. Recommendation is to keep epic purple (#A855F7) and move mystic to cyan (#22D3EE), with the colours stored in the balance document so you can change them yourself in seconds. Do you want cyan, a different hue, or would you rather keep both purple and distinguish mystic by an animated shimmer frame instead?
- Who besides you will ever have an admin account, and what should they be able to do? The design proposes six roles (owner / game_designer / moderator / support / analyst / read_only). If it is only ever you, several things simplify a lot — the two-person approval queue and grant caps could be deferred entirely. If you plan to hire a community moderator or a support person, they should be designed in from the start.
- Is 2FA acceptable as passkey-first (Touch ID / Face ID on your Mac and iPhone) with TOTP only as a fallback? Passkeys are meaningfully more secure because they cannot be phished, and on your hardware they are also less friction — but they need a working authenticator on every device you might need to log in from.
- How much gold should a support person be able to grant without your approval? The design proposes 10,000 gold or 100 diamonds per action, 5 actions per hour, 50,000 gold per day, with anything larger going to a two-person approval queue. These numbers need to relate to the real economy — what is a typical player's daily gold income going to be?
- When you publish a balance change while players are mid-session, should offline tax that accrued before the publish be credited at the old rate or the new one? The simple answer (new rate, self-correcting) is recommended, but if you ever plan to cut tax rates sharply the exact answer costs about 80 more lines and avoids a class of support ticket that is otherwise unanswerable.
- Do you want gradual balance rollouts — publish a change to 10% of players first, watch the economy for a day, then go to 100%? The schema supports it from day one but the implementation is deferred to phase 2. It makes each publish much safer and makes economy analysis somewhat harder, since two cohorts are running different rules.
- How long should a wiped account be recoverable? The design soft-deletes, scrubs PII, and hard-deletes after 30 days. Longer is safer against mistakes; shorter is cleaner for GDPR requests. Also: when you wipe an account, should its gold be destroyed via the ledger (keeping economy charts correct) or excluded from the economy entirely?
- Do you want real install and store-revenue numbers on the dashboard, or are new-account counts enough for now? The panel can only measure accounts; true install counts and store revenue require ingesting App Store Connect Sales & Trends reports, which is a phase 6 item. Without it the install-to-account conversion rate is invisible — which matters a lot the moment you spend money on user acquisition.
- Should announcements and events support languages other than English later? All in-game text is English today and the schema has a `locale` column ready, but if localisation is genuinely never happening, the announcement editor gets simpler and the client bootstrap payload gets smaller.
- For the initial soft launch, is it acceptable that the admin panel has no preview deployments and no public URL — meaning you can only reach it through Cloudflare Access on a device you have enrolled? That is the source of most of its security, but it does mean no quick check from a borrowed laptop.

---

# Adversarial review — verdict: needs-revision


## BLOCKER (5)

### ops/compose.yml: `admin-api` and `cloudflared` are attached ONLY to the `internal: true` network, which blocks all egress. `admin-api` cannot reach Neon; `cloudflared` cannot reach Cloudflare's edge.

**Breaks because:** Docker's `internal` flag installs netfilter rules that block masquerading/SNAT for the network — containers on it 'cannot reach the internet or any other host outside'. `admin-api` needs outbound TLS to `*.neon.tech:5432` for DATABASE_URL, DATABASE_URL_DIRECT and DATABASE_URL_REPLICA, and outbound HTTPS to `<team>.cloudflareaccess.com/cdn-cgi/access/certs` for the JWKS the design says it verifies on every request. `cloudflared` must dial out to `region1.v2.argotunnel.com:7844`. Neither can. The stack starts and the admin panel is 100% unreachable while admin-api crash-loops on connect. The document's own prose contradicts its YAML: '(Note: `cloudflared` and `api` need egress, so they also attach to `edge`; `admin-web` does not.)' — but the YAML lists `cloudflared: networks: [internal]`.

**Fix:** Use three networks. `edge:` (normal bridge, egress) — caddy, api, cloudflared, admin-api. `adminnet: {internal: true}` — admin-web, admin-api, cloudflared. `data:` (normal bridge, egress) — api, admin-api, redis. Concretely: `admin-api: networks: [adminnet, data]`, `cloudflared: networks: [adminnet, edge]`, `admin-web: networks: [adminnet]` only. A container on both an internal and a non-internal network takes its default route from the non-internal one, so admin-api reaches Neon while admin-web still has zero egress — which is the property the design actually wants. Add a compose smoke test to CI/runbook: `docker compose exec admin-api sh -c 'nc -z <neon-host> 5432'` and `docker compose exec admin-web sh -c '! nc -z -w2 1.1.1.1 443'`.

### The hash-seal is destroyed by the jsonb round-trip. Go computes `sha256(CanonicalJSON(doc))` and then stores those bytes in a `jsonb` column (`set doc = $2::jsonb`). jsonb is not a byte store.

**Breaks because:** PostgreSQL docs: 'jsonb does not preserve white space, does not preserve the order of object keys, and does not keep duplicate object keys' and 'shorter keys are stored before longer keys'. Go's `encoding/json` sorts map keys purely bytewise. So for `{"xp":…, "tax":…, "energy":…, "attack":…, "shop":…}` Go emits attack,energy,shop,tax,xp while jsonb stores xp,tax,shop,attack,energy (length-first). jsonb also strips E-notation (`1.230e-5` → `0.00001230`). Consequence: `sha256(canonical(read_back(doc))) != doc_hash`, always. The claim in publish.go step 6 — 'the hash in the audit log always identifies exactly these bytes' — is false, because the bytes are unrecoverable. Worse, the same defect kills the audit chain: `admin.audit_log.before/after/diff` are jsonb, `entry_hash` is computed in Go over the pre-insert values, and the nightly verifier recomputes from what Postgres returns. It will report tamper on 100% of rows containing a jsonb payload, on night one — permanently discrediting the one control the design calls 'genuine non-repudiation'.

**Fix:** Store the hashed bytes verbatim and derive the queryable form. In `cfg.balance_version`: `doc_canonical bytea not null`, `doc jsonb generated always as (convert_from(doc_canonical,'utf8')::jsonb) stored`. Hash and serve `doc_canonical`; use `doc` only for indexing/`jsonb_path_ops` queries. Identically in `admin.audit_log`: add `payload_canonical bytea not null` holding the exact canonicalized `{before,after,diff,…}` bytes that `entry_hash` covers, and keep `before/after/diff jsonb` as generated/derived columns for the GIN index. Additionally, replace the map-round-trip `CanonicalJSON` with RFC 8785 (JCS) — Go's map ordering is bytewise on UTF-8 but JCS specifies UTF-16 code-unit ordering, so the current function is not a named canonicalization anyone can re-implement or audit; use `github.com/gowebpki/jcs` or an explicit JCS implementation, and add a round-trip unit test asserting `hash(canon) == hash(canon(parse(canon)))` over the full default document.

### Two partitioned tables declare a primary key that omits the partition key: `admin.audit_log` (`id bigint primary key`, `partition by range (created_at)`) and `analytics.session_event` (`id bigint primary key`, `partition by range (started_at)`). Also, no partitions and no DEFAULT partition are ever created for `admin.audit_log`, `analytics.session_event`, or `battle.battle`.

**Breaks because:** PostgreSQL: 'the constraint's columns must include all of the partition key columns'. Both CREATE TABLE statements fail outright — `ERROR: unique constraint on partitioned table must include all partitioning columns`. The very first goose migration in Phase 0 does not apply. (The design gets this right for `econ.gold_ledger` and `battle.battle`, which use `primary key (id, created_at)` — so it is an inconsistency, not a knowledge gap.) Separately, 'Inserting data into the parent table that does not map to one of the existing partitions will cause an error' — so even after the DDL is fixed, the first admin login's `admin.login_attempt`/`admin.audit_log` insert fails with `no partition of relation "audit_log" found for row`.

**Fix:** Change both to `primary key (id, created_at)` / `primary key (id, started_at)`. Note this makes `id` non-unique globally, so `admin.audit_log.session_id`-style FKs and any `references admin.audit_log(id)` must be dropped or re-pointed. Then, in the same migration that creates each partitioned table, create a `DEFAULT` partition (`create table admin.audit_log_default partition of admin.audit_log default;`) plus the current and next two months, and have `internal/jobs/` create partitions 3 months ahead for all four partitioned tables, not just `gold_ledger`. Add a startup assertion that a partition exists covering `now() + 24h` for every partitioned table, and fail fast if not.

### `admin/package.json` pins `"typescript": "~6.9"`. TypeScript 6.x never reached 6.9.

**Breaks because:** Verified against npm on this machine: the entire published 6.x line is `6.0.2` and `6.0.3` (dist-tags: `beta: 6.0.0-beta`, `rc: 7.0.1-rc`, `latest: 7.0.2`, `next: 7.1.0-dev`). `~6.9` matches nothing, so `pnpm install --frozen-lockfile` in the `deps` Docker stage and the first local `pnpm install` both fail with `No matching version found for typescript@~6.9`. The reasoning for avoiding TS 7 is correct; the pin is not.

**Fix:** Pin `"typescript": "6.0.3"` exactly (the 6.x line is effectively frozen, so a caret/tilde range buys nothing). Next.js 16 requires TypeScript >= 5.1, so 6.0.3 is supported. Add a note that TS 7.1 — which restores the programmatic JS API — is the upgrade target once `experimental.useTypeScriptCli` is no longer needed.

### `publishBalance` calls `revalidateTag("balance")` with one argument, and `getDailyKpis` uses `"use cache"` while §4 states 'Cache Components (`use cache`) are OFF for this app.'

**Breaks because:** Two independent failures. (1) Next.js 16 upgrade guide: '`revalidateTag` now requires a second argument specifying a `cacheLife` profile. The single-argument form is deprecated and **will produce a TypeScript error**.' CI runs `pnpm tsc --noEmit`, so the build fails. It is also the wrong API — in a Server Action you want `updateTag` for read-your-writes — and it is a no-op regardless because nothing anywhere calls `cacheTag("balance")`. (2) The `use cache` reference states plainly: '`use cache` is a Cache Components feature. To enable it, add the `cacheComponents` option.' With `cacheComponents: false` the directive is a build error; with it `true`, enabling it 'can surface build errors for uncached data outside of `<Suspense>` and requires adopting the Cache Components model' — an unbudgeted refactor of every page in a panel where literally every read goes through `apiFromCookies()`. And if `getDailyKpis` calls `apiFromCookies()` (which calls `cookies()`/`headers()`), it throws `next-request-in-use-cache`; the docs warn 'on a dynamically rendered route this surfaces when the route runs, so it can pass `next build` and fail under `next start`' — i.e. it ships green and 500s in production.

**Fix:** Delete the `use cache` block entirely and keep `cacheComponents` off, which is what §4's own rule already argues for. Replace `getDailyKpis` with a TanStack Query client-side fetch on a 60s `refetchInterval` (the design's own rule for 'anything that refreshes on a timer'), or with a plain uncached RSC read — the rollups are already pre-aggregated, so the query is one indexed row-range scan and caching buys nothing. In `publishBalance`, drop `revalidateTag` and call `updateTag('balance')` only if you later introduce a matching `cacheTag`; for now use `refresh()` from `next/cache` to refresh the client router after publish.


## MAJOR (17)

### The Next.js 16 `middleware.ts` claim is factually wrong, and one of the document's stated risks is built on it.

**Breaks because:** §0 asserts: '**a leftover `middleware.ts` is silently ignored at build time** — protected routes become publicly reachable with no error', and the risk list repeats it. The Next.js 16 upgrade guide says the opposite: 'The `middleware` filename is **deprecated**, and has been renamed to `proxy`… The `edge` runtime is NOT supported in `proxy`. The `proxy` runtime is `nodejs`, and it cannot be configured. **If you want to continue using the `edge` runtime, keep using `middleware`.**' `middleware.ts` still runs. This is presented as one of exactly two 'facts that change the design' and as a headline risk, so it corrodes trust in the rest of the verification. (The `nodejs`-and-not-configurable half of the claim is correct.)

**Fix:** Correct §0 fact 1 to: '`middleware.ts` is deprecated in favour of `proxy.ts`; both run, but only `middleware` supports the edge runtime, and `proxy` is Node-only and not configurable. Use `proxy.ts`; run `npx @next/codemod@canary upgrade latest` to migrate the filename, the exported symbol, and the renamed config flags (`skipMiddlewareUrlNormalize` → `skipProxyUrlNormalize`).' Delete the corresponding risk-list entry. Keep the (correct and load-bearing) design conclusion that `proxy.ts` must never be an authz boundary.

### The audit hash chain has no serialization, so concurrent writers fork it — and `audit.Do` guarantees concurrency by design.

**Breaks because:** `entry_hash = sha256(prev_hash || …)` requires a single total order. Under `pgx.ReadCommitted`, two admin actions in flight both read the current chain head, both see row N-1 (neither sees the other's uncommitted row), both write `prev_hash = hash(N-1)`, both commit. The chain now has two rows claiming the same predecessor and the nightly verifier reports tampering. This is not a rare race: `audit.Do`'s failure path explicitly calls `writeOutcome(...)` on a *separate pool connection* while the mutation transaction is still open, so a denied action and a successful one are structurally guaranteed to interleave. Separately, `id bigint generated always as identity` is not a commit-order sequence — identity values are handed out at INSERT time, so `order by id` can invert commit order even with one writer, and the verifier's notion of 'the previous row' is wrong.

**Fix:** Add an explicit chain position and serialize on it. Take `pg_advisory_xact_lock(AUDIT_CHAIN_KEY)` as the FIRST statement inside `audit.Do`'s transaction (before `fn`), then `select chain_seq, entry_hash from admin.audit_log order by chain_seq desc limit 1` and insert with `chain_seq = prev+1`. Verify by `chain_seq`, never by `id`. For `writeOutcome` on the separate connection, wrap it in its own short transaction that takes the same advisory lock — and note that it must be issued *after* `tx.Rollback` completes, not before, or it will block on the lock the outer transaction still holds; restructure `Do` to capture the error, rollback explicitly, then write the outcome. Add a concurrency test that fires 50 parallel audited mutations and asserts `chain_seq` is gapless and every `prev_hash` matches.

### `revoke update, delete, truncate on admin.audit_log from emperors_app` does not protect the partitions, and is a no-op if `emperors_app` owns the table.

**Breaks because:** Two holes in the control the design calls 'genuine non-repudiation, not decoration'. (1) Partitions do not inherit the parent's ACL, and PostgreSQL checks privileges on the relation actually named in the statement. `DELETE FROM admin.audit_log WHERE …` is denied; `DELETE FROM admin.audit_log_2026_09 WHERE …` is checked against that partition's own ACL — and the partition was created by the design's own Go partition-maintenance job running as `emperors_app`, which therefore owns it. An attacker with an admin session that reaches any SQL path, or the rogue insider this control exists for, deletes their trail by naming the child. (2) goose runs the migrations; if it connects as `emperors_app` then `emperors_app` owns `admin.audit_log` and can simply `GRANT DELETE ON admin.audit_log TO emperors_app` before deleting. §18 row 22 mentions 'separate least-privilege roles for app / analyst / migration' but no DDL establishes this and no migration sets ownership.

**Fix:** Create three Neon roles up front in the first migration, run by the Neon owner role: `emperors_migrate` (owns all schemas and tables), `emperors_app` (DML only), `emperors_analyst` (SELECT on a whitelist). Run goose as `emperors_migrate`. After each `create table … partition of`, the partition job must `alter table <partition> owner to emperors_migrate` and re-issue `revoke update, delete, truncate on <partition> from emperors_app` — or, better, move partition creation out of the app entirely into a goose migration / a separate cron container running as `emperors_migrate`. Add a nightly assertion query over `pg_class`/`information_schema.table_privileges` that no relation in schema `admin` is owned by or grants UPDATE/DELETE to `emperors_app`, and fire an alarm if it is.

### The economy inverts the brief: passive tax income is ~5.7x larger than active collect income at the document's own constants.

**Breaks because:** From §8's `constants`: `energy.regen_seconds_per_point: 300` → 12 energy/hour. Best gold-per-energy on the ladder shown in the editor mock is saffron at 21g/8e = 2.63 g/e. Active collect income = 12 × 2.63 = **31.6 gold/hour**. `tax.base_per_second: 0.05` = **180 gold/hour**. Even with the `granary` family upgrade fully maxed (50 × 2% = +100% collect gold) active play yields 63 g/h against 180 g/h of doing nothing. The 8h offline cap pays 1,440 gold for being away versus ~253 gold for playing the same 8 hours. The brief is explicit and non-negotiable: 'active "collect" actions are the PRIMARY gold source; in addition the player's household/kingdom produces a **small** passive "tax" income'. This is exactly backwards, and it is the kind of thing a soft launch discovers as 'nobody opens the Collect tab'.

**Fix:** Peg tax to simulated collect income rather than setting it as a free-floating absolute. Set `constants.tax.base_per_second: 0.0013` (≈4.7 g/h ≈ 15% of level-30 collect income) as the immediate correction. Better structurally: add `constants.tax.target_pct_of_collect_gph: 0.15` to the document and derive `base_per_second` in `economy.New()` from the archetype ladder, so it cannot drift when the collect ladder is retuned. Add a hard validator ERROR (not warning) `tax_exceeds_collect` that runs the simulator over every default archetype and blocks the publish when `gold_h_tax > 0.35 * gold_h_collect` — the simulator already computes both metrics (`gold_h_collect`, `gold_h_tax`), so this is ~10 lines and it makes the brief's requirement mechanically enforced instead of aspirational.

### PvP steal is ~2,900x more gold-per-energy than the best collect job, and both draw on the same energy pool, so the entire Collect tab is dead content.

**Breaks because:** Using the design's own two mocks, which are consistent with each other: the player detail shows 1,284,905 gold and the battle log shows 38,547 gold stolen at `steal_pct: 0.03`. At `attack.energy_cost: 5` that is 7,709 gold per energy, against 2.63 gold per energy for saffron. At 12 energy/hour a player earns ~92,500 g/h attacking versus ~32 g/h collecting. No rational player ever taps a collect job once they can find one rich target, which deletes one of the six bottom tabs, the entire per-job milestone system, and the point of the collect ladder the document spends a page fixing. Second-order: `econ.gold_reason` correctly classifies `attack_steal`/`attack_stolen` as `transfer`, so the `/economy` faucet-sink chart and the `sink_ratio` alarm show a perfectly healthy economy while ~99.9% of all gold movement is invisible PvP churn — and the `/economy` page has no transfer-volume panel at all. Third-order: shield is 30 min and only fires on a loss, so a rich weak defender can be hit 48x/day at 3% each and retains 0.97^48 = 23% of their gold per day.

**Fix:** Cap the steal relative to what the attacker's energy is otherwise worth, and bracket matchmaking. Add to the document: `constants.attack.steal_cap_vs_collect_multiple: 20` and compute `stolen = min(steal_pct * defender_gold, multiple * attack_energy_cost * attacker_best_gold_per_energy)` — with the numbers above that is 20 × 5 × 2.63 = 263 gold, making PvP a strong 20x energy multiplier instead of a 2,900x one, and bounding whale drain to a survivable rate. Add `constants.attack.matchmaking: {level_band: 5, gold_band_pct: 0.5}` — the design references an 'attack matchmaking pool' exactly once (in the ban invariants) and never specifies it anywhere. Add a validator ERROR `pvp_dominates_collect` when simulated `attack_g_per_e > 25 * best_collect_gpe` for any archetype; the simulator already emits both metrics side by side. Add a `Transfers` panel and a `pvp_drain_ratio` alarm rule (gold stolen per day / gold held by the top decile) to `/economy`, because `flow_class='transfer'` deliberately hides this from every existing chart.

### The XP curve `base: 100, exponent: 1.55` makes levelling get *faster* as you level, so there is no late game.

**Breaks because:** Taking the document's own `XPForLevel(L) = 100 * L^1.55` (as used in `metricsFor`: `XPForLevel(L+1) - XPForLevel(L)`) against its own simulator xp/h figures (new lvl5 = 31, mid lvl30 = 410, whale lvl60 = 980): marginal XP for L5→6 is 395 → 12.7 hours; L30→31 is 1,010 → 2.5 hours; L60→61 is 1,480 → 1.5 hours. Marginal cost grows 3.7x across the whole game while income grows 31x, so hours-per-level falls monotonically. Total XP to level 60 is 100 × 60^1.55 ≈ 57,000, i.e. ~139 hours of play to reach the design's own 'late' archetype. For an idle/RPG built around months of retention and a level-gated collect ladder, the grind is front-loaded onto the new player (12.7h for level 6) and evaporates exactly where retention needs a wall.

**Fix:** A pure power law with exponent < ~2.5 cannot outrun compounding income. Switch to a hybrid: `xp: {base: 60, poly_exponent: 2.0, growth: 1.055}` with `xp_to_next(L) = base * L^2.0 * growth^L`, which gives ~1.5h at L5, ~6h at L30 and ~40h at L60 against the same income curve — front-light, back-heavy. Then stop eyeballing it: the simulator already computes `h_next_level` per archetype, so add a validator ERROR `level_pace_inverted` that runs the archetype ladder and blocks the publish if `h_next_level` is not non-decreasing from `new` → `early` → `mid` → `late`. Also add an explicit `targets` block to the balance document (`hours_to_first_soldier_slot`, `hours_to_first_gladiator_f2p`, `days_to_found_kingdom`, `hours_to_level_60`) and have the simulator report measured-vs-target, because right now not a single constant in the document was derived from a time-to-milestone goal.

### The publish-dialog simulation numbers are internally inconsistent with the `constants` block in the same document, by 10–100x.

**Breaks because:** The dialog shows new (lvl 5) at 142 gold/h. At grapes (2.0 g/e), 142 g/h requires 71 energy/hour, i.e. ~50 seconds per energy point — but `constants.energy.regen_seconds_per_point` is 300 (12/hour, → 24 g/h). It also cannot include the 180 g/h passive tax, since 142 < 180. Mid at 2,940 g/h is ~93x the 31.6 g/h the constants actually produce. The derived columns are self-consistent with the fabricated income (60,000/142 = 422h to gladiator ✓, 250,000/142 = 1,760h to kingdom ✓), which makes them look authoritative. This matters more than a typo: the single strongest argument in §8 is that the simulator runs the real `economy.Economy` so its numbers cannot lie to the designer — and the exemplar output shown to the owner as 'what this tool will print' is off by two orders of magnitude. The owner will calibrate expectations on numbers the system will never produce.

**Fix:** Regenerate the §8 publish-dialog mock from the actual constants once §-fixes above land, or mark it explicitly as illustrative-only with placeholder digits. Then make drift impossible: add a golden-file test (`api/internal/sim/testdata/default_archetypes.golden`) that runs `sim.Run` over the checked-in default balance document and asserts the metrics, so any change to constants or formulas that moves the archetype numbers must update the golden file in the same commit. Wire the same fixture into the docs so the mock is generated, not hand-written.

### The owner SQL console's isolation controls do not work on a Neon pooled connection, and `SET ROLE` is reversible by the submitted SQL.

**Breaks because:** Neon's connection-pooling docs list, under 'Not supported with pooled connections': `SET` / `RESET` (session variables), LISTEN/NOTIFY, session-level advisory locks. The console's entire containment story is `SET ROLE emperors_analyst`, `default_transaction_read_only = on`, `statement_timeout = 10s` — all `SET`. `DATABASE_URL_REPLICA` in compose is the replica endpoint, and Neon hands you the pooled `-pooler` host by default, so every one of those guards silently does nothing. Separately, even on a direct connection, `SET ROLE` is not a boundary: if Go prepends it to admin-supplied SQL sent over the simple query protocol, the admin submits `RESET ROLE; SELECT email, receipt_ref FROM …` and regains the `emperors_app` grants on `admin.*` and `billing.*` that §18 row 20 says are denied. (The design does get LISTEN/NOTIFY and `pg_advisory_xact_lock` right — transaction-scoped advisory locks are fine through the pooler; only session-level ones are not.)

**Fix:** Do not use `SET` at all. Create `emperors_analyst` as a real login role with its limits baked in: `alter role emperors_analyst set default_transaction_read_only = on; alter role emperors_analyst set statement_timeout = '10s'; alter role emperors_analyst set idle_in_transaction_session_timeout = '30s';` then `revoke all on schema admin, billing from emperors_analyst` and grant column-level SELECT only on the analytics whitelist. Give the console its own `DATABASE_URL_ANALYST` pointing at the **direct (non-`-pooler`) read-replica endpoint** with `user=emperors_analyst`. Reject multi-statement submissions by sending the query through pgx's extended protocol (`QueryExecModeExec`/`Query` with args), which cannot execute multiple statements, and pre-parse with `pg_query_go` to assert exactly one top-level `SelectStmt`. Add `DATABASE_URL_ANALYST` to the compose env for `admin-api` — it is currently missing entirely.

### `SameSite=Strict` on `__Host-emp_admin` breaks the Cloudflare Access re-authentication flow.

**Breaks because:** Cloudflare Access sessions expire (24h by default on the free tier). On expiry the browser is redirected to `<team>.cloudflareaccess.com`, authenticates, and is redirected back to `admin.emperors.example`. That return is a top-level cross-site navigation, and `SameSite=Strict` cookies are not sent on cross-site navigations. The admin lands on the app with no session cookie, `proxy.ts` bounces them to `/login`, and they re-enter password + TOTP/passkey every single Access session renewal — for a tool whose whole design premise is that the owner reaches for it at 3am during an economy incident. The same problem hits any bookmark or link followed from email/Slack.

**Fix:** Use `SameSite=Lax`. `Lax` still blocks the attack this is guarding: cross-site POSTs carry no cookie, and every mutation in this design is a Server Action POST. The design already layers three independent CSRF controls on top (`__Host-` prefix, Go rejecting non-same-origin `Origin`/`Sec-Fetch-Site`, and Next's `serverActions.allowedOrigins`), so Strict adds nothing against POST and costs a real workflow. If you insist on Strict, add a same-site bounce: a `GET /auth/resume` route with a `SameSite=Lax` companion cookie that immediately 302s to the target, which re-issues the Strict cookie on a now-same-site navigation.

### The client-IP / IP-allowlist policy is unimplementable as specified, and `lib/api/client.ts` contradicts it.

**Breaks because:** §3 states the client IP comes from `CF-Connecting-IP`, trusted only when a valid `Cf-Access-Jwt-Assertion` is present, 'otherwise use `RemoteAddr`', and 'never trust `X-Forwarded-For` blindly'. But admin-api only ever receives connections from the `admin-web` container, so `RemoteAddr` is always a `172.x.x.x` bridge address. The fallback branch therefore either denies every request (if the allowlist is on) or writes a meaningless container IP into every `admin.audit_log.actor_ip` and `admin.login_attempt.ip` row — destroying the brute-force forensics those tables exist for. Meanwhile the shipped client does exactly what §3 forbids: `"X-Forwarded-For": h.get("cf-connecting-ip") ?? h.get("x-forwarded-for") ?? ""` — it falls back to a browser-controllable header and relabels it as XFF, so anything that can reach admin-web forges its source IP past the allowlist.

**Fix:** Make the CF Access JWT the sole source of truth and delete the fallback. In `apiFromCookies`, forward only `cf-connecting-ip` under its own header name (`X-Real-Client-IP`) and never `x-forwarded-for`. In Go: (a) with `REQUIRE_CF_ACCESS=true`, verify the JWT against the JWKS at `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` and check `aud == CF_ACCESS_AUD` and `iss`; reject with 403 if absent or invalid — which makes the 'otherwise' branch dead code by construction. (b) Only after that verification, parse `X-Real-Client-IP` with `netip.ParseAddr` and use it for the allowlist and audit rows. (c) Assert `RemoteAddr` is inside the configured `adminnet` subnet and reject otherwise, so a sibling container cannot impersonate admin-web. Cache the JWKS with a 10-minute TTL and a stale-on-error fallback, or the JWKS fetch becomes a hard dependency on every request.

### The Go/TypeScript risk-code duplication will drift, because only the hot-path table is shared — not the diff algorithm that produces the paths the table matches against.

**Breaks because:** `assessRisk` matches regexes like `/^collect_jobs\[[^\]]+\]\.(gold|energy_cost)$/` against paths produced by `diff.ts`'s identity-keyed `flatten`. The Go side calls a separately-implemented `DiffJSON(liveDoc.Raw, rawDraft)` and `UnacknowledgedHighRisks`. Sharing `openapi/balance-hotpaths.yaml` synchronises the *regexes*, not the *path strings* — the keyed-array bracket syntax, empty-object handling, `pctChange` when `av === 0`, and array-reorder attribution all have to match byte-for-byte in two languages, and nothing tests that they do. Worse, the two sides diff different inputs: Go diffs raw bytes out of a `jsonb` column (key order and number formatting normalised by Postgres, per the finding above) while TS diffs JSON parsed from the API. Numeric formatting alone (`2.60` vs `2.6`) will produce a change on one side and not the other. The failure is exactly the one the document lists as a risk — the UI shows fewer risks than the server demands, producing a 412 on the publish click — but the mitigation it claims does not address the cause.

**Fix:** Delete `admin/src/lib/balance/diff.ts` and `admin/src/lib/balance/risk.ts`. Add `POST /admin/balance/{id}/preview` returning `{diff: DiffOp[], risks: Risk[], validation: Problem[], simulation: Report}` computed entirely in Go from the same bytes `Publish` will read. The editor renders exactly what the server returned and echoes `risks[].code` verbatim into `ack_risks`. This removes ~200 lines of TypeScript, removes a stated risk, removes one of the design's five 'critical files', and makes the diff shown and the diff enforced the same object by construction. Cost: one round trip on the diff tab, which is already a server call for the simulation.

### The revenue query omits `environment = 'production'`, the exact mistake the surrounding prose warns about.

**Breaks because:** §14 says 'Sandbox purchases are flagged, never counted in revenue. Forgetting this is how a dashboard shows $40k from a TestFlight build.' The §6 query is `where status = 'verified' and created_at >= …` with no environment predicate, and it is the query feeding `daily_kpi.revenue_usd_micros`, which feeds the `arpdau_usd`/`arppu_usd` generated columns and every revenue tile. During TestFlight and sandbox QA — i.e. the entire pre-launch period when the owner is learning to read this dashboard — revenue will be pure fiction. Separately, because `status` flips to `'refunded'` on a chargeback but the rollup job only recomputes yesterday, a refund on day D+10 silently desynchronises the stored `daily_kpi` row for day D from what the live query returns.

**Fix:** Add `and environment = 'production'` to the revenue query and to every `billing.purchase` aggregate. Add a partial index `create index on billing.purchase (created_at) where status = 'verified' and environment = 'production'`. Extend the nightly rollup to recompute a trailing 35-day window rather than only yesterday, so late refunds and late store reconciliation land in the stored rows; the job is already `insert … on conflict do update`, so this is a loop bound change. Add an explicit `Sandbox` badge on `/billing/purchases` rows so QA purchases are visible rather than merely excluded.

### The 'sealed = immutable forever' guarantee on `cfg.balance_version` is enforced only by application discipline — there is no trigger and no REVOKE.

**Breaks because:** `revoke update, delete on cfg.balance_activation from emperors_app` protects the activation log, but `cfg.balance_version` has no protection at all, and `Publish` itself does `update cfg.balance_version set … doc = $2::jsonb, doc_hash = $3`. So the same role, via the same code path, can rewrite the document of an already-sealed version. Every downstream guarantee depends on this not happening: the audit row's `after` hash 'always identifies exactly these bytes', the battle replay verifier re-runs fights 'using the sealed document from that battle's balance version', and rollback re-activates a version assuming its bytes are unchanged. A single mis-scoped `WHERE` in a future handler silently rewrites history and makes every historical replay verification fail with no indication why.

**Fix:** Add a trigger: `create function cfg.deny_sealed_update() returns trigger as $$ begin if old.sealed_at is not null and (new.doc is distinct from old.doc or new.doc_hash is distinct from old.doc_hash or new.seq is distinct from old.seq or new.sealed_at is distinct from old.sealed_at) then raise exception 'balance version % is sealed and immutable', old.id using errcode='23514'; end if; return new; end $$ language plpgsql;` with `create trigger trg_balance_sealed before update on cfg.balance_version for each row execute function cfg.deny_sealed_update();` (label/notes stay editable). Also add a nightly job that recomputes `sha256(doc_canonical)` for every sealed version and alarms on mismatch — this is nearly free once `doc_canonical` exists per the hash finding, and it turns the immutability claim into something verified rather than asserted.

### The `admin/Dockerfile` build stage cannot find the OpenAPI spec, so `pnpm gen:api` fails.

**Breaks because:** The Dockerfile does `COPY api/openapi/admin.v1.yaml /openapi/admin.v1.yaml`, but `gen:api` is `openapi-typescript ../api/openapi/admin.v1.yaml -o src/lib/api/schema.gen.ts` and `WORKDIR` is `/app`, so it resolves `../api/openapi/admin.v1.yaml` = `/api/openapi/admin.v1.yaml` — which does not exist. `RUN pnpm gen:api && pnpm build` exits non-zero and the image never builds, blocking the deploy workflow in §17. (The build context also has to be the repo root for `COPY admin/…` and `COPY api/…` to resolve, which is never stated in the compose/deploy sections.)

**Fix:** Change the COPY to `COPY api/openapi/admin.v1.yaml ../api/openapi/admin.v1.yaml` — which Docker rejects — so instead do `COPY api/openapi/admin.v1.yaml /api/openapi/admin.v1.yaml` (matching the `..` resolution from `/app`), or better, make the script path configurable: `"gen:api": "openapi-typescript ${ADMIN_SPEC:-../api/openapi/admin.v1.yaml} -o src/lib/api/schema.gen.ts"` and set `ENV ADMIN_SPEC=/openapi/admin.v1.yaml` in the build stage. Document `docker build -f admin/Dockerfile .` (context = repo root) in `deploy.yml`. Best of all: check `schema.gen.ts` into the repo like `server.gen.go` already is, let CI's `gen:check` enforce freshness, and drop the codegen step from the image build entirely — one less thing that can fail at 3am.

### Phase ordering makes the game client unbootable: the balance Store and `/v1/bootstrap` are in Phase 3, behind the admin panel's login shell and player screens.

**Breaks because:** The Godot client cannot render a single screen without the balance document — `config_service.gd` fetches `/v1/bootstrap` in `_ready()` and every job label, tier colour, price and icon comes from it. Putting 'Doc schema, validator, draft CRUD, diff, risk, publish/rollback, Store + LISTEN/NOTIFY, client bootstrap endpoint' in Phase 3 means the game itself is blocked behind an admin panel's auth shell and player search. Similarly, Phase 4 defers analytics — but `econ.gold_ledger`, `analytics.session_event` and `battle.battle` writes must exist from the first player action or there is no history to roll up when the dashboards are built, and backfilling them is impossible.

**Fix:** Split by write-path vs read-path rather than by feature. Phase 0 becomes: `game.*` + `cfg.*` + `econ.*` schema, `balance.Doc` + `Validate` + `Store` + `/v1/bootstrap`, a seeded initial sealed version (published by a goose migration, not by the UI), `audit.Do`, and instrumentation writes for `gold_ledger`/`session_event`/`battle`. Phase 1 stays auth + shell. Phase 3 then contains only the *editor UI and publish endpoint* — the runtime half already shipped. Phase 4 contains only the rollup jobs and dashboards, reading data that has been accumulating since Phase 0.

### The `game.*` schema — the core of the product — is never defined, and several referenced objects have no DDL.

**Breaks because:** Eight queries reference `game.player` columns (`gold`, `created_at`, `display_name`, `deleted_at`, `email`, `device_id`, `id`) and the plan's Phase 0 is 'goose migrations for `admin.*`, `cfg.*`, `econ.*`' — `game.*` is not in any phase. `admin.approval_request` is central to the two-person rule and `/settings/approvals` but has no DDL. `econ.diamond_ledger` is `(…)` and there is no `econ.diamond_reason` lookup table, so the design's own strongest schema argument — that a foreign-keyed `flow_class` makes an unclassified reason a write error — does not apply to the hard currency, which is the one tied to real money and refunds.

**Fix:** Add `game.player`, `game.item`, `game.soldier`, `game.soldier_slot`, `game.kingdom`, `game.kingdom_member`, `game.shop_offer` to Phase 0 with the columns the existing queries already assume, including `public_id uuid default uuidv7()`, `deleted_at`, `device_id`, and the `pg_trgm` GIN index on `display_name` that §7 specifies. Add `admin.approval_request (id, requested_by, action, target_type, target_id, payload jsonb, reason, status check in ('pending','approved','denied','expired'), decided_by, decided_at, expires_at default now()+interval '24 hours')`. Mirror `econ.gold_reason` as `econ.diamond_reason` with its own `flow_class` and FK from `econ.diamond_ledger.reason`.

### No formula is specified anywhere, yet four subsystems are declared to depend on `internal/economy/economy.go` as 'the ONE implementation of every formula'.

**Breaks because:** §8 specifies the balance document's *data* in fine detail but never states a single equation. `item_tier_curve: {atk: {a: 4.0, b: 1.45}}` and `tiers[*].stat_mult` both exist and the relationship between them is undefined — is item attack `a * b^tier_index`, or `a * atk_weight * stat_mult`, or all three multiplied (which would double-count tier)? Neither reading reproduces the mock's 'Ashwood Blade epic +38'. Likewise undefined: how milestone bonuses stack with family/kingdom percentage bonuses (additively or multiplicatively — a 10x difference at max upgrades), how soldier base stats combine with equipment, how combat resolves, and how tax scales with upgrades. The simulator, the `flat_gold_per_energy` validator, the replay verifier and the entire risk model all sit on top of this, and `economy.go` does not appear in the plan's critical-files list.

**Fix:** Write `api/internal/economy/FORMULAS.md` (or a doc comment block in `economy.go`) before any of §8 is implemented, specifying each of: `XPForLevel`, `EnergyRegenSeconds`, `JobGold` (base × milestone × family × kingdom × event, with stacking rule stated), `ItemStat` (pick one: `round(a * b^tier_index * weight)` and DELETE `tiers[*].stat_mult` from the item path, keeping `stat_mult` for soldiers only — two tier multipliers on one value is a balancing trap), `SoldierStat`, `TaxPerSecond`, `SlotCost`, `ExpectedStealGold`, and combat round resolution. Promote `economy.go` to the critical-files list — it is the file every other file in the plan is defined in terms of.


## MINOR (6)

### `cfg.balance_seq` assigns the human-facing version number at draft creation, not at publish.

**Breaks because:** `seq int not null unique default nextval('cfg.balance_seq')` fires on INSERT of the draft row. A designer who opens three drafts and publishes the third ships 'v45' while v43 and v44 never existed in production, and discarded drafts leave permanent gaps. The publish dialog's 'v42 (live since …) → v43' framing and the version list's implied ordering both assume sequential activation. `PublishResult.Seq` is also read from the draft row before sealing, so the number in the audit log and the `pg_notify` payload is a draft ID masquerading as a release number.

**Fix:** Drop the `default nextval(...)`, make `seq` nullable, and assign it inside the publish transaction: `update cfg.balance_version set is_draft=false, sealed_at=now(), seq=nextval('cfg.balance_seq'), doc_canonical=$2, doc_hash=$3 where id=$1 returning id, seq`. Read `seq` from the RETURNING clause into `PublishResult`. Identify drafts in the UI by `label` and short `id` (`draft #17 "grape nerf"`), and reserve `vN` for things that actually shipped.

### `DangerConfirm` requires typing the target's display name, which is unusable for exactly the names it is meant to protect.

**Breaks because:** The names a moderator bans are, by selection, the adversarial ones: leetspeak, homoglyphs, zero-width joiners, RTL overrides, emoji, combining diacritics — the design's own `Normalize()` function exists precisely because players use all of these. Asking a moderator to retype `Xx_Sl4y3r_xX` with a zero-width space in it either fails silently forever (they cannot produce the exact bytes) or trains them to copy-paste, which defeats the 'typing the name proves you looked at the right row' rationale entirely.

**Fix:** Compare on the normalized form using the same `Normalize()` the name filter uses, and display the normalized string as the thing to type (`Type: xxsl4y3rxx`). For names that normalize to something short or ambiguous, fall back to requiring the first 8 characters of `public_id`, which is already shown in the header (`#018f2a…c31`) and is copy-resistant in the useful sense — it is unique to the row and meaningless to memorise.

### The step-up TOTP code is sent as an HTTP header (`X-Step-Up-Code`).

**Breaks because:** `headers: { "X-Step-Up-Code": input.stepUpCode ?? "" }` puts a live second-factor credential into request headers, which are the thing most commonly captured by access logs, APM traces, proxy debug logging and Cloudflare's request inspection. It is a 30-second-window secret, but it is captured on the highest-value actions in the system (currency grants, bans, wipes, balance publishes, refunds) and the design's whole step-up premise is that this value is what a stolen session cannot supply.

**Fix:** Move it into the JSON request body (`body: { base_hash, reason, ack_risks, step_up_code }`) where the design's existing 'no log line is ever built by concatenation' and structured-`slog` rules keep it out of logs, and add the field to the OpenAPI schema marked `format: password` / `x-sensitive: true` so redaction middleware can find it. Also add an explicit slog `ReplaceAttr` denylist for `step_up_code`, `password`, `totp_secret`, `recovery_code` and `Cf-Access-Jwt-Assertion`.

### The read-replica decision contradicts the document's own argument against a second connection pool.

**Breaks because:** §1 argument 5 rejects a Next.js connection pool because 'adding a second independent pool from the web tier for no functional gain is pure waste on a metered compute' — then §1 and §17 provision a **Neon read replica**, which is an entire second compute (independent CPU/RAM, its own compute-hour meter, its own scale-to-zero cold starts), for an admin panel with 1–5 users querying pre-aggregated rollup tables. A pooled connection consumes one slot from `0.9 × max_connections` on an existing compute; a replica bills separately. The stated ordering of costs is backwards, and the replica adds eventual-consistency confusion the risk list itself flags.

**Fix:** Keep the read replica in the plan but move it to Phase 6 alongside the SQL console, gated on an actual measured problem (dashboard queries contending with gameplay traffic). Until then, point `DATABASE_URL_REPLICA` at the primary and let the rollup tables do their job — they are the real fix and they work regardless. Drop argument 5 from §1; arguments 1–4 (transactional audit, invariants, ORM drift, blast radius) carry the decision on their own and are correct.

### Scope for a solo owner: Phase 0 + Phase 1 require the full security apparatus before a single player row is visible.

**Breaks because:** The panel is explicitly for '1–5 people' and realistically one. Before `/players` exists, the plan requires: two-listener Go binary, `admin.*` schema, argon2id tuning, TOTP with replay prevention, WebAuthn ceremony state (a v0.x library, exactly-pinned), 10 recovery codes, opaque sessions with rotation, step-up windows, soft IP/UA binding, 6-role RBAC with structured caps, a two-person approval workflow, hash-chained audit with nightly verification and off-box export, an IP allowlist with an SSH recovery CLI, Cloudflare Tunnel, Cloudflare Access, JWKS verification, and OpenAPI codegen for two languages. Several are structurally meaningless with one admin: the two-person approval rule cannot be satisfied (nobody to approve), `support`/`analyst`/`moderator`/`game_designer` roles have no occupants, and the design itself concedes the IP allowlist is 'a third layer of marginal value and a real lockout risk' — then ships it anyway.

**Fix:** Cut Phase 0/1 to: Cloudflare Tunnel + Access (which already provides the identity gate and is free), Go session cookies + argon2id + TOTP with replay prevention, two roles (`owner`, `read_only`), `audit.Do` with the hash chain, and the OpenAPI pipeline. Defer to a 'second human joins' milestone: WebAuthn, the other four roles, grant caps, `admin.approval_request`, and the IP allowlist (delete it — Access with a hardware-key IdP policy strictly dominates it and cannot lock you out of your own console while travelling). This removes roughly a third of Phase 0/1 and none of the actual protection, since every one of those actions still goes through `audit.Do` and step-up.

### `mod.report`'s anti-brigading index does not cover kingdom reports, and the retention cohort query is non-sargable and timezone-dependent.

**Breaks because:** `create unique index on mod.report (reporter_id, target_player_id, category) where status = 'open'` — for a `kingdom_name` report `target_player_id` is NULL, NULLs are distinct in unique indexes by default, and `target_kingdom_id` is not in the index at all. So one reporter can file unlimited open reports against the same kingdom, which is exactly the brigading case the queue mock shows (`House Bl00d`). Separately, the cohort insert uses `where created_at::date = $1::date`, which cannot use an index on `created_at` (the design uses the sargable half-open form everywhere else) and depends on the session `TimeZone` for the day boundary, so cohort membership shifts if the connection's TZ ever differs between the app and a manual re-run.

**Fix:** Add `create unique index on mod.report (reporter_id, target_kingdom_id, category) where status = 'open' and target_kingdom_id is not null;` and add a `check (num_nonnulls(target_player_id, target_kingdom_id) = 1)` so a report always has exactly one target. Rewrite the cohort predicate as `where created_at >= $1::date and created_at < $1::date + 1` and set `TimeZone = 'UTC'` via `ALTER ROLE emperors_app SET TimeZone = 'UTC'` so every date bucket in the system agrees.


## Missing coverage

- Shop offers are never persisted. There is no `game.shop_offer` table and no record of what the 5-minute refresh actually rolled for a player, so `/economy`'s `shop_purchase` sink cannot be attributed to an item and the ticket 'the shop showed me a mystic sword and charged me for a common one' is structurally unanswerable. The design's own §14 argument for the ledger tab ('Where did my gold go' is answered by filtering, not by guessing') applies identically here and is not honoured. Add `game.shop_offer (player_id, slot, rolled_at, expires_at, item_def_id, tier, price, balance_version, purchased_at)` written on every refresh, plus a Shop tab on the player detail.
- No item administration exists. The brief makes Inventory one of six tabs with seven rarity tiers and three slots per soldier, and `players/[publicId]/inventory` is listed as a route, but the §7 action catalogue has no grant/remove/modify-item action at all. 'I lost my legendary sword in the update' is the second most common support ticket in this genre after currency, and it is the one that cannot be resolved with the currency tools that are specified.
- No soldier administration. `players/[publicId]/soldiers` is a route with no actions behind it — no grant slot, no set soldier tier, no re-roll, no unequip. Given soldier slots cost gold on a 1.9x growth curve and recruits roll a random tier, a botched recruit or a slot purchase that failed mid-transaction has no remediation path.
- No stat-point respec. Levels grant 3 points into Max Energy / Attack / Defense and the player detail shows 'STATS (allocated 96 pts)', but `player.force_level` only *grants* points. A player who dumped 96 points into Defense and now cannot progress has no fix, and a force-level that changes the point budget has no way to reconcile an existing allocation.
- PvP matchmaking is entirely unspecified. 'the attack matchmaking pool' appears exactly once, in the list of things a ban must touch. There is no table, no endpoint, no balance-document knobs (level band, gold band, power band, shield-aware exclusion, kingdom-mate exclusion), and no admin surface to inspect or force an opponent set. Given the brief requires that kingdom members cannot attack each other and that PvP is one of six tabs, this is a missing subsystem, not a missing screen.
- Diamond economy is a placeholder. `econ.diamond_ledger (…)` is elided and there is no `econ.diamond_reason` lookup table, so the faucet/sink/transfer classification argument — the design's strongest schema argument — is not applied to the currency that maps to real money, drives refunds, and feeds `clawback_debt`.
- `game.*` schema is absent from every phase and every DDL block, despite eight queries depending on its columns.
- No formula specification for `internal/economy/economy.go`, which the simulator, validator, replay verifier and risk model are all defined in terms of. The relationship between `item_tier_curve` and `tiers[*].stat_mult` in particular is ambiguous in a way that changes item power by ~3x.
- No `targets` block and no time-to-milestone goals anywhere in the balance document, so no constant in the design was derived from a play-experience target and the simulator has nothing to assert against.
- `admin.approval_request` has no DDL despite being the mechanism behind grant caps, the two-person rule, and `/settings/approvals`.
- No transfer-volume view on `/economy`. `flow_class='transfer'` deliberately excludes PvP theft from the faucet/sink chart and the `sink_ratio` alarm, which is correct — but nothing replaces it, so the largest single flow of gold in the game (see the PvP finding) is invisible on every economy screen.
- No backup/restore or disaster-recovery story. Neon branches are mentioned once for testing migrations, but there is no stated PITR retention, no restore runbook, and no procedure for the case the audit-chain verifier is designed to detect — 'the chain is broken, what now?' has no answer.
- Godot client integration is thin: `config_service.gd` is specified, but there is no plan for what the client does when `/v1/bootstrap` fails on a cold start (no cached document, no bundled fallback document, no offline behaviour), which is a launch-blocking crash path on a flaky mobile network.
- No load or cost model for Neon. The design argues from connection budgets and metered compute but never estimates queries-per-player-action, the write rate into `econ.gold_ledger` (one row per collect, at 12+ collects/hour/player), or what DAU the free/entry compute tier survives.

## Corrected recommendations

## Verdict in one line

The **architecture is right and the numbers are wrong.** Six of the fourteen key decisions are ones I would defend unchanged. But there are seven day-1 blockers (the stack does not start, the schema does not migrate, the panel does not install or build), and the game economy — the thing the balance editor exists to manage — is internally inconsistent by two orders of magnitude and inverts an explicit requirement of the brief.

## What is genuinely sound — keep these, do not relitigate

Verified correct against primary sources today:

- **API-only web tier with no `DATABASE_URL`.** Arguments 1–4 (transactional audit, non-table-write invariants, ORM drift, blast radius) are individually sufficient. Only argument 5 (connection budget) is weak, and it is contradicted by the read-replica decision.
- **Go owns identity.** Follows necessarily from the in-transaction audit row. The Better Auth rejection reaches the right conclusion.
- **One immutable JSON document + append-only activation log.** All five claimed benefits are real. Rollback-as-one-row is worth the schema.
- **The simulator runs production `economy` code.** Correct and non-negotiable — and the reason the flat-gold-per-energy and PvP-dominance findings below are *findable* rather than hypothetical.
- **Server-enforced risk acknowledgement from the real diff.** Right; only the client-side duplicate needs deleting.
- **`econ.gold_reason` with a FK'd `faucet | sink | transfer`.** The `transfer` class is a genuinely good catch that most designs miss. It just needs a UI that shows transfers.
- **LISTEN/NOTIFY on the un-pooled Neon endpoint.** Confirmed: Neon's pooling docs list `LISTEN`/`NOTIFY` as unsupported. The design flags this as its top silent-failure risk and it is right to. It is also right that `pg_advisory_xact_lock` (transaction-scoped) *is* safe through the pooler — only session-level advisory locks are not.
- **PG18 `RETURNING old.gold, new.gold`.** Confirmed valid syntax.
- **pnpm supply-chain settings.** `minimumReleaseAge`, `blockExoticSubdeps`, and `pnpm-workspace.yaml` as the location are all exactly right, and pnpm 11's default really is `1440`.
- **oapi-codegen v2.8.0 for OpenAPI 3.1.** Confirmed — v2.8.0's release is titled "OpenAPI 3.1, fewer assumptions, and a giant bug hunt" and it moved to a kin-openapi that parses 3.1.
- **Tier colours as document data + cyan for mystic.** The right resolution to the epic/mystic conflict. One refinement below.

Every npm/Go version in the table checks out exactly, except `typescript@~6.9`.

## Fix order

**Week 1 — unblock (nothing else can be tested until these land):**
1. Compose networks (admin-api and cloudflared need egress).
2. Partitioned-table PKs + create DEFAULT partitions.
3. `typescript` → `6.0.3`.
4. Delete `use cache` / fix `revalidateTag`.
5. Dockerfile spec path.
6. `doc_canonical bytea` + JCS, for both `cfg.balance_version` and `admin.audit_log`.
7. Audit-chain advisory lock + `chain_seq`.

**Week 2 — before the first real admin session:**
8. Role separation (`emperors_migrate` / `emperors_app` / `emperors_analyst`) + partition ownership, which is what makes the REVOKE mean anything.
9. `SameSite=Lax` + CF Access JWT as the sole client-IP source; delete the `RemoteAddr` fallback and the `x-forwarded-for` fallback.
10. Sealed-version immutability trigger.
11. `environment = 'production'` on revenue.

**Before any player sees the game — the economy pass:**

This is the part I would push back on hardest. The balance editor is beautifully engineered around numbers that do not work. Concretely, from the document's own `constants` block:

| Quantity | Document's value | Implied by `constants` | Ratio |
|---|---|---|---|
| Collect income (best job) | — | 12 e/h × 2.63 g/e = **31.6 g/h** | — |
| Passive tax | `0.05/s` | **180 g/h** | tax is **5.7×** collect |
| PvP steal (mock's own figures) | 38,547g / 5 energy | **7,709 g/energy** | **2,931×** collect |
| Hours per level | `100·L^1.55` | L5 → 12.7h, L30 → 2.5h, L60 → 1.5h | **decreasing** |
| Publish-dialog sim, mid | 2,940 g/h | 31.6 g/h | **93×** off |

Three of these are independently game-breaking; the fourth means the tool built to catch them would have printed fiction. The fixes are specified per-finding above, but the structural change that matters is: **add a `targets` block to the balance document and turn the simulator's existing metrics into blocking validator errors.** The design already computes `gold_h_collect`, `gold_h_tax`, `attack_g_per_e` and `h_next_level` per archetype and displays them side by side — it just never asserts anything about their relationships. Four new checks (`tax_exceeds_collect`, `pvp_dominates_collect`, `level_pace_inverted`, `only_one_viable_job`) are perhaps 80 lines and convert the simulator from a report into a guardrail. That is the highest-leverage change in this entire review.

Add the fourth check because the design's own `flat_gold_per_energy` warning *creates* a new problem it does not mention: once gold-per-energy rises monotonically up the ladder and a rational player always taps the best available job (as `metricsFor` explicitly assumes), every lower job is dead and the per-job 25/50/100 milestone system can never be completed on anything but the newest unlock. Either add per-job daily caps or cooldowns so players ladder downward, or make milestones global — but decide, because the current design silently picks "the Collect tab is one button."

## Simplifications that buy back the schedule

- **Delete `admin/src/lib/balance/diff.ts` and `risk.ts`** (~200 lines) in favour of `POST /admin/balance/{id}/preview`. Removes a stated risk, removes a whole class of Go↔TS drift, and removes one of the plan's five "critical files."
- **Delete the IP allowlist.** The document argues against it, then ships it. Cloudflare Access with a hardware-key policy strictly dominates it and cannot strand a travelling solo owner.
- **Defer WebAuthn, four of six roles, grant caps, and `admin.approval_request`** to "a second human joins." The two-person rule is unsatisfiable with one admin.
- **Defer the read replica and SQL console to Phase 6.** Rollup tables are the actual fix and they work on the primary.
- **Check `schema.gen.ts` into the repo** like `server.gen.go` already is, and drop codegen from the Docker build.

Net: roughly a third out of Phase 0/1 with no loss of protection, because every action still routes through `audit.Do` + step-up.

## Two smaller corrections

**Tier palette.** Cyan for mystic is the right call — it is the largest gap in the ramp and it survives red-green CVD, which the yellow/red end already collapses. But `#22D3EE` (mystic, tier 5) sits next to `#3B82F6` (rare, tier 2) in hue, so the ramp is non-monotonic in "hotness" and two cool blues bracket the ladder. Shift rare to indigo `#4F46E5` to open the gap, and lean on `frame: shimmer` as the primary channel — colour alone should never be the only carrier of tier, which the design already argues.

**Re-derive the §8 publish-dialog mock from a golden file** (`api/internal/sim/testdata/default_archetypes.golden`) rather than hand-writing it, so the illustrative numbers and the real ones cannot diverge again.