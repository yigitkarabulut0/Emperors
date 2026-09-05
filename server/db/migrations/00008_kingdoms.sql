-- +goose Up
-- +goose StatementBegin

CREATE TABLE app.kingdoms (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text        NOT NULL,
    tag         text        NOT NULL,
    leader_id   uuid        REFERENCES app.players(id) ON DELETE SET NULL,

    level       integer     NOT NULL DEFAULT 1 CHECK (level >= 1),
    xp          bigint      NOT NULL DEFAULT 0 CHECK (xp >= 0),
    treasury    bigint      NOT NULL DEFAULT 0 CHECK (treasury >= 0),
    -- Reputation is stored scaled by 100 so the 2%/day decay does not round a
    -- small kingdom's score to nothing on the first night.
    reputation  bigint      NOT NULL DEFAULT 0 CHECK (reputation >= 0),

    created_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT kingdoms_name_len CHECK (char_length(name) BETWEEN 3 AND 24),
    CONSTRAINT kingdoms_tag_len  CHECK (char_length(tag) BETWEEN 2 AND 4)
);
CREATE UNIQUE INDEX kingdoms_name_lower_key ON app.kingdoms (lower(name));
CREATE UNIQUE INDEX kingdoms_tag_lower_key  ON app.kingdoms (lower(tag));
CREATE INDEX kingdoms_reputation_idx ON app.kingdoms (reputation DESC);

-- Membership lives on the player row rather than in a join table: the hottest
-- question in the game is "do these two share a kingdom?", asked on every raid,
-- and it should not need a join.
ALTER TABLE app.players
    ADD COLUMN kingdom_id            uuid REFERENCES app.kingdoms(id) ON DELETE SET NULL,
    ADD COLUMN kingdom_role          text NOT NULL DEFAULT 'none'
                                     CHECK (kingdom_role IN ('none','member','marshal','king')),
    ADD COLUMN kingdom_joined_at     timestamptz,
    ADD COLUMN kingdom_donated_total bigint NOT NULL DEFAULT 0 CHECK (kingdom_donated_total >= 0),
    ADD COLUMN kingdom_favour        bigint NOT NULL DEFAULT 0 CHECK (kingdom_favour >= 0),
    ADD COLUMN kingdom_rep_today     integer NOT NULL DEFAULT 0 CHECK (kingdom_rep_today >= 0),
    ADD COLUMN kingdom_donated_today bigint NOT NULL DEFAULT 0 CHECK (kingdom_donated_today >= 0),
    ADD COLUMN kingdom_day           date;

CREATE INDEX players_kingdom_idx ON app.players (kingdom_id) WHERE kingdom_id IS NOT NULL;

-- A member with no kingdom must have no role, and a member of one must have a
-- real role. Making it a constraint means no code path can produce a ghost.
ALTER TABLE app.players
    ADD CONSTRAINT players_kingdom_role_consistent
    CHECK ((kingdom_id IS NULL AND kingdom_role = 'none')
        OR (kingdom_id IS NOT NULL AND kingdom_role <> 'none'));

CREATE TABLE app.kingdom_upgrades (
    kingdom_id uuid    NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    upgrade_id text    NOT NULL,
    level      integer NOT NULL DEFAULT 0 CHECK (level >= 0),
    PRIMARY KEY (kingdom_id, upgrade_id)
);

CREATE TABLE app.kingdom_invites (
    kingdom_id uuid        NOT NULL REFERENCES app.kingdoms(id) ON DELETE CASCADE,
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    invited_by uuid        REFERENCES app.players(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (kingdom_id, player_id)
);
CREATE INDEX kingdom_invites_player_idx ON app.kingdom_invites (player_id);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.kingdom_invites;
DROP TABLE IF EXISTS app.kingdom_upgrades;
ALTER TABLE app.players
    DROP CONSTRAINT IF EXISTS players_kingdom_role_consistent,
    DROP COLUMN IF EXISTS kingdom_id,
    DROP COLUMN IF EXISTS kingdom_role,
    DROP COLUMN IF EXISTS kingdom_joined_at,
    DROP COLUMN IF EXISTS kingdom_donated_total,
    DROP COLUMN IF EXISTS kingdom_favour,
    DROP COLUMN IF EXISTS kingdom_rep_today,
    DROP COLUMN IF EXISTS kingdom_donated_today,
    DROP COLUMN IF EXISTS kingdom_day;
DROP TABLE IF EXISTS app.kingdoms;
