-- +goose Up
-- +goose StatementBegin

-- Server-wide, time-boxed modifiers: a weekend of double experience, an hour of
-- better luck after an outage, a boosted collect rate for a launch event.
--
-- They feed the SAME buckets as family upgrades, kingdom nodes and job mastery,
-- which is the whole reason they are safe. Every percentage bonus in this game
-- belongs to exactly one bucket, and each bucket has a cap; a boost that shared
-- a bucket's cap can lift a player toward it but can never take the game
-- somewhere its own upgrades could not already reach.
--
-- Append-only in spirit: a boost is REVOKED, never deleted, so "why was everyone
-- earning double on the 14th" is still answerable in March.
CREATE TABLE admin.server_boosts (
    id         bigserial   PRIMARY KEY,
    bucket     text        NOT NULL,
    amount_bp  bigint      NOT NULL,
    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz NOT NULL,
    note       text        NOT NULL DEFAULT '',
    created_by text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    revoked_by text,

    -- A window that ends before it starts is a boost nobody would ever see, and
    -- is far more likely to be a typo than an intention.
    CONSTRAINT server_boosts_window CHECK (ends_at > starts_at)
);

-- The read that runs on the refresh poll: everything live right now.
CREATE INDEX server_boosts_live_idx ON admin.server_boosts (starts_at, ends_at)
    WHERE revoked_at IS NULL;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS admin.server_boosts;
-- +goose StatementEnd
