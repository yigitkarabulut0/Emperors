-- +goose Up
-- +goose StatementBegin

-- ============================================================================
-- What a reward can hold, beyond the columns the player row already has
-- ============================================================================
-- Every system that pays a player -- a letter, a login square, a chest, a
-- purchase, a season track -- pays through one function (service.grantBundle).
-- Most of what it pays already has a home (gold, diamonds, XP, favour, items).
-- These three do not.

-- Tokens: consumables held in a count. An energy potion is one: it refills the
-- pool like the store's refill and counts as one of the day's refills. Keyed by
-- the token's id from the balance document, so a new token is data, not a
-- migration.
CREATE TABLE app.player_tokens (
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    token      text        NOT NULL,
    qty        bigint      NOT NULL CHECK (qty >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, token)
);

-- Timed bonuses owned by ONE player (a reward, not a server event). Always the
-- timed lane of a bucket (economy.AddTemp), with its own ceiling, and never
-- energy regeneration. The player row carries the latest expiry so the hot path
-- only reads this table while one is live.
CREATE TABLE app.player_boosts (
    id         bigserial   PRIMARY KEY,
    player_id  uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    bucket     text        NOT NULL CHECK (bucket IN ('collect_income_bp', 'xp_bp')),
    amount_bp  integer     NOT NULL CHECK (amount_bp BETWEEN 1 AND 20000),
    starts_at  timestamptz NOT NULL,
    expires_at timestamptz NOT NULL CHECK (expires_at > starts_at),
    source     text        NOT NULL,
    source_ref text
);
CREATE INDEX player_boosts_live_idx ON app.player_boosts (player_id, expires_at);
ALTER TABLE app.players ADD COLUMN boost_until timestamptz;

-- Cosmetics a player owns: portrait frames, titles, name colours, crests. They
-- change how a lord looks to everyone else and nothing about how they fight.
-- expires_at is for the ones held for a season or a reign; NULL is forever.
CREATE TABLE app.player_cosmetics (
    player_id   uuid        NOT NULL REFERENCES app.players(id) ON DELETE CASCADE,
    cosmetic_id text        NOT NULL,
    source      text        NOT NULL,
    source_ref  text,
    acquired_at timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz,
    PRIMARY KEY (player_id, cosmetic_id)
);
-- What the player wears, one per kind. Ids from the balance catalogue; an id the
-- player no longer owns simply resolves to nothing when read.
ALTER TABLE app.players
    ADD COLUMN cos_frame text,
    ADD COLUMN cos_title text,
    ADD COLUMN cos_color text,
    ADD COLUMN cos_crest text;

-- ============================================================================
-- Where an item came from
-- ============================================================================
-- Only 'shop' has ever been written. Rewards grant items too now, and so will
-- the systems after them; the list is widened ONCE here so no later migration
-- has to fight over the same constraint.
ALTER TABLE app.player_items DROP CONSTRAINT IF EXISTS player_items_acquired_from_check;
ALTER TABLE app.player_items ADD CONSTRAINT player_items_acquired_from_check
    CHECK (acquired_from IN (
        'shop', 'milestone', 'loot', 'recruit', 'admin',
        'mail', 'reward', 'promo', 'event', 'season', 'chest',
        'forge', 'expedition', 'campaign', 'boss', 'war', 'tutorial'
    ));

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.player_items DROP CONSTRAINT IF EXISTS player_items_acquired_from_check;
ALTER TABLE app.player_items ADD CONSTRAINT player_items_acquired_from_check
    CHECK (acquired_from IN ('shop','milestone','loot','recruit','admin'));
ALTER TABLE app.players
    DROP COLUMN IF EXISTS cos_crest,
    DROP COLUMN IF EXISTS cos_color,
    DROP COLUMN IF EXISTS cos_title,
    DROP COLUMN IF EXISTS cos_frame,
    DROP COLUMN IF EXISTS boost_until;
DROP TABLE IF EXISTS app.player_cosmetics;
DROP TABLE IF EXISTS app.player_boosts;
DROP TABLE IF EXISTS app.player_tokens;
-- +goose StatementEnd
