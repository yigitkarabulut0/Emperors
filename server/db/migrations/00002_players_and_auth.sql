-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- Players
-- ============================================================================
-- Money is bigint in whole units; every multiplier elsewhere is integer basis
-- points (10000 = 1.0x) and rounding is always floor. No floating point ever
-- touches the economy, so the server, the admin simulator and the client's
-- optimistic display agree bit for bit and the ledger reconciles exactly.
--
-- Energy is NOT stored as a current value. It is (energy_milli, updated_at) and
-- materialised on read, so there is no cron sweeping every player every minute.
-- Milli-energy exists so a regen rate that does not divide evenly into a second
-- does not silently round away.
CREATE TABLE app.players (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    username             text        NOT NULL,
    display_name         text        NOT NULL,

    level                integer     NOT NULL DEFAULT 1  CHECK (level >= 1),
    xp                   bigint      NOT NULL DEFAULT 0  CHECK (xp >= 0),

    gold                 bigint      NOT NULL DEFAULT 0  CHECK (gold >= 0),
    treasury_gold        bigint      NOT NULL DEFAULT 0  CHECK (treasury_gold >= 0),
    diamonds             bigint      NOT NULL DEFAULT 0  CHECK (diamonds >= 0),

    energy_milli         bigint      NOT NULL DEFAULT 60000 CHECK (energy_milli >= 0),
    energy_updated_at    timestamptz NOT NULL DEFAULT now(),

    -- Allocated level-up points. Max energy, attack and defense are DERIVED from
    -- these plus the active balance config; they are never stored, so a rebalance
    -- applies without a migration.
    stat_energy          integer     NOT NULL DEFAULT 0 CHECK (stat_energy  >= 0),
    stat_attack          integer     NOT NULL DEFAULT 0 CHECK (stat_attack  >= 0),
    stat_defense         integer     NOT NULL DEFAULT 0 CHECK (stat_defense >= 0),
    stat_points_unspent  integer     NOT NULL DEFAULT 0 CHECK (stat_points_unspent >= 0),

    shield_until         timestamptz,

    -- Monotonic per-player counter. The client sends the sequence number it
    -- expects; a retry on a flaky mobile network replays the same number and is
    -- recognised as a duplicate rather than spending twice.
    action_seq           bigint      NOT NULL DEFAULT 0 CHECK (action_seq >= 0),

    state                text        NOT NULL DEFAULT 'active'
                                     CHECK (state IN ('active','banned','deleted')),
    -- Seeded from the device timezone at signup; daily resets happen at the
    -- player's local midnight, not at a single UTC hour that is 3am for half the world.
    reset_offset_minutes integer     NOT NULL DEFAULT 0
                                     CHECK (reset_offset_minutes BETWEEN -840 AND 840),

    created_at           timestamptz NOT NULL DEFAULT now(),
    last_seen_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT players_username_len CHECK (char_length(username) BETWEEN 3 AND 16)
)
-- Every gameplay action updates this row. Leaving free space per page lets those
-- be HOT updates that do not have to touch every index.
WITH (fillfactor = 80);

-- Case-insensitive uniqueness without depending on the citext extension.
CREATE UNIQUE INDEX players_username_lower_key ON app.players (lower(username));

-- Deliberately NOT indexed: gold, xp, energy_milli, action_seq. They are the
-- hottest columns in the database and indexing them would cost every write to
-- serve queries that are better answered from the leaderboard snapshot.

-- ============================================================================
-- Identities — one row per way of proving you are this player
-- ============================================================================
-- Credential-typed from day one. v1 ships 'password' only, but adding email,
-- Apple or Google later is then an INSERT, not a rewrite of the auth model.
CREATE TABLE app.identities (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    kind        text        NOT NULL CHECK (kind IN ('password','email','apple','google')),
    -- The stable external key: the lowercased username, the email, or the
    -- provider's subject claim.
    subject     text        NOT NULL,
    -- Argon2id encoded hash for 'password'. NULL for OAuth kinds, where the
    -- provider is the proof.
    secret_hash text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,

    CONSTRAINT identities_password_needs_hash
        CHECK (kind <> 'password' OR secret_hash IS NOT NULL)
);
CREATE UNIQUE INDEX identities_kind_subject_key ON app.identities (kind, subject);
CREATE INDEX identities_player_idx ON app.identities (player_id);

-- ============================================================================
-- Sessions — opaque rotating refresh tokens
-- ============================================================================
-- Access tokens are short-lived JWTs and are not stored. Refresh tokens are
-- opaque, stored only as a hash, and rotate on every use. `family_id` groups a
-- rotation chain: if a already-rotated token is presented again, the token was
-- stolen, and the whole family is revoked.
CREATE TABLE app.sessions (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id        uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    family_id        uuid        NOT NULL,
    token_hash       bytea       NOT NULL,
    issued_at        timestamptz NOT NULL DEFAULT now(),
    expires_at       timestamptz NOT NULL,
    used_at          timestamptz,
    revoked_at       timestamptz,
    revoked_reason   text,
    user_agent       text,
    CONSTRAINT sessions_expiry_after_issue CHECK (expires_at > issued_at)
);
CREATE UNIQUE INDEX sessions_token_hash_key ON app.sessions (token_hash);
CREATE INDEX sessions_player_idx ON app.sessions (player_id) WHERE revoked_at IS NULL;
CREATE INDEX sessions_family_idx ON app.sessions (family_id);
CREATE INDEX sessions_expiry_idx ON app.sessions (expires_at) WHERE revoked_at IS NULL;

-- ============================================================================
-- Collect progress
-- ============================================================================
-- One row per (player, job). `collects` drives the 25/50/100/250/500/1000
-- mastery milestones, whose bonuses REPLACE rather than stack (max +30%).
CREATE TABLE app.player_job_progress (
    player_id  uuid   NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    job_id     text   NOT NULL,
    collects   bigint NOT NULL DEFAULT 0 CHECK (collects >= 0),
    PRIMARY KEY (player_id, job_id)
) WITH (fillfactor = 85);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.player_job_progress;
DROP TABLE IF EXISTS app.sessions;
DROP TABLE IF EXISTS app.identities;
DROP TABLE IF EXISTS app.players;
