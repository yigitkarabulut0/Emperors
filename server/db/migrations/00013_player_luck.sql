-- +goose Up
-- +goose StatementBegin

-- Per-player luck: a bonus, in basis points, on the LEVEL COEFFICIENT of the
-- tier ladder. 0 is neutral, which is what every other basis-point field on a
-- player means, so a config-granted luck node and an admin override add rather
-- than fighting over a 10000 baseline.
--
-- Luck is deliberately NOT a seed input. A shop shelf is a pure function of
-- (secret, player, window, reroll, slot) and is recomputed a second time inside
-- the Buy transaction; a seed that moved when luck moved would let GetShop and
-- Buy disagree about what the player tapped. Luck enters the WEIGHTS instead.
--
-- The ceiling is duplicated here on purpose. Go clamps in one place
-- (items.ClampLuckBP), and the database refuses to store a value that clamp
-- would otherwise have to silently correct.
ALTER TABLE app.players
    ADD COLUMN luck_bp         integer NOT NULL DEFAULT 0
                               CHECK (luck_bp BETWEEN -10000 AND 10000),
    -- NULL means permanent. A luck override moves no counter anyone watches and
    -- writes no ledger row, so time-boxing it by default is what stops a
    -- forgotten one compounding quietly for a year.
    ADD COLUMN luck_expires_at timestamptz;

-- Who currently has an override, without scanning the whole table.
CREATE INDEX players_luck_idx ON app.players (luck_expires_at)
    WHERE luck_bp <> 0;

-- The luck the current shop window was rolled with.
--
-- Offers are recomputed on every GetShop and once more inside Buy, and they have
-- to be identical across all of those calls. Reading luck live would mean an
-- override applied mid-window changes which ITEM is on the shelf -- not merely
-- its price, the way a shop discount does -- and the player is charged for
-- something they never saw.
ALTER TABLE app.shop_state
    ADD COLUMN luck_bp integer NOT NULL DEFAULT 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP INDEX IF EXISTS app.players_luck_idx;
ALTER TABLE app.players
    DROP COLUMN IF EXISTS luck_bp,
    DROP COLUMN IF EXISTS luck_expires_at;
ALTER TABLE app.shop_state DROP COLUMN IF EXISTS luck_bp;
-- +goose StatementEnd
