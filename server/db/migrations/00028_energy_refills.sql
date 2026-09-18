-- +goose Up
-- +goose StatementBegin

-- How many full refills a player has bought today, and which day "today" is.
--
-- Refills were unlimited at a flat price, which is unlimited gold and XP for
-- money the moment diamonds can be bought. They are now a short daily ladder
-- (store.energy_refill_prices). The day is the player's LOCAL day, the same one
-- the daily calendar turns over on, so the count resets at their midnight rather
-- than at a UTC hour that is mid-afternoon for a third of the world.
--
-- A count on the player row rather than a table: it is read on every store view
-- and written only on a refill, and a stale day simply reads as zero used -- no
-- sweeper resets anything.
ALTER TABLE app.players
    ADD COLUMN refills_day  date,
    ADD COLUMN refills_used smallint NOT NULL DEFAULT 0 CHECK (refills_used >= 0);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.players DROP COLUMN IF EXISTS refills_used;
ALTER TABLE app.players DROP COLUMN IF EXISTS refills_day;
-- +goose StatementEnd
