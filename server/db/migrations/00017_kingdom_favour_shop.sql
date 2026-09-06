-- +goose Up
-- +goose StatementBegin

-- A timed experience boost the player buys for themselves.
--
-- Shaped exactly like the luck override two migrations ago (00013), and for the
-- same reasons: an expiry in the past is simply not applied, so there is no
-- sweeper, no scheduled job, and no window in which a lapsed boost is still
-- live because nothing ran. loadEffects reads it, adds it to the SAME xp bucket
-- everything else feeds, and the bucket's cap is still the cap.
--
-- This is what Kingdom Favour is for. Favour has been granted on every donation
-- since kingdoms shipped, displayed on the Realm card, and never spendable --
-- so donating cost the donor gold and gave them nothing personally, which is
-- precisely the thing the design said would stop anyone donating.
ALTER TABLE app.players
    ADD COLUMN xp_boost_bp         integer NOT NULL DEFAULT 0
                                   CHECK (xp_boost_bp BETWEEN 0 AND 10000),
    ADD COLUMN xp_boost_expires_at timestamptz;

-- Partial: only the handful of players holding a live boost are ever scanned.
CREATE INDEX players_xp_boost_idx ON app.players (xp_boost_expires_at)
    WHERE xp_boost_bp <> 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP INDEX IF EXISTS app.players_xp_boost_idx;
ALTER TABLE app.players
    DROP COLUMN IF EXISTS xp_boost_bp,
    DROP COLUMN IF EXISTS xp_boost_expires_at;
-- +goose StatementEnd
