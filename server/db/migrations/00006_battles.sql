-- +goose Up
-- +goose StatementBegin

-- Bots fill the Attack tab at launch. Without them the core PvP loop is empty
-- on day one — exactly when retention matters most — and the first player to
-- install has nobody to fight.
ALTER TABLE app.players
    ADD COLUMN is_bot boolean NOT NULL DEFAULT false;

CREATE INDEX players_targets_idx ON app.players (level)
    WHERE state = 'active';

-- ============================================================================
-- Battles
-- ============================================================================
-- Only INPUTS are stored, plus the event log the client animates. The armies are
-- frozen into the record because a replay must stay valid after the player sells
-- the sword they won with.
CREATE TABLE app.battles (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    attacker_id    uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    defender_id    uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,

    seed           bigint      NOT NULL,
    config_version integer     NOT NULL,
    attacker_won   boolean     NOT NULL,
    rounds         integer     NOT NULL,

    attacker_might bigint      NOT NULL,
    defender_might bigint      NOT NULL,

    gold_stolen    bigint      NOT NULL DEFAULT 0,
    ransom_paid    bigint      NOT NULL DEFAULT 0,
    xp_awarded     bigint      NOT NULL DEFAULT 0,
    energy_spent   bigint      NOT NULL DEFAULT 0,

    -- The full replay. Kept as jsonb so the admin panel can inspect a fight
    -- without a bespoke decoder.
    replay         jsonb       NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX battles_attacker_idx ON app.battles (attacker_id, created_at DESC);
CREATE INDEX battles_defender_idx ON app.battles (defender_id, created_at DESC);

-- Per-pair cooldown. Without it a strong player farms one weak target the
-- instant each shield lapses, which is the single fastest way to lose a new
-- player.
CREATE TABLE app.attack_cooldowns (
    attacker_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    defender_id uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    last_at     timestamptz NOT NULL DEFAULT now(),
    count_24h   integer     NOT NULL DEFAULT 1,
    PRIMARY KEY (attacker_id, defender_id)
);

-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS app.attack_cooldowns;
DROP TABLE IF EXISTS app.battles;
DROP INDEX IF EXISTS app.players_targets_idx;
ALTER TABLE app.players DROP COLUMN IF EXISTS is_bot;
