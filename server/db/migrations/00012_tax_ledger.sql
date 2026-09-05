-- +goose Up
-- +goose StatementBegin

-- Estate income has to appear in the gold ledger, or the economy dashboard is
-- measuring a fraction of the economy.
--
-- It cannot be one ledger row per credit: income is settled on every
-- authenticated request, which would write thousands of rows a day per player
-- for a few gold each. So the credited amount accumulates here and is flushed as
-- a single row once it is worth recording. The player's gold is unaffected --
-- this column only tracks what has not yet been written to the ledger.
ALTER TABLE app.players
    ADD COLUMN tax_unlogged bigint NOT NULL DEFAULT 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.players
    DROP COLUMN IF EXISTS tax_unlogged;
-- +goose StatementEnd
