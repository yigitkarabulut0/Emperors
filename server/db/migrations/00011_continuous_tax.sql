-- +goose Up
-- +goose StatementBegin

-- Estate income arrives continuously instead of waiting behind a button.
--
-- The hourly rate is cached on the player row so that crediting the accrual is a
-- single UPDATE with no reads. The rate depends on holdings, upgrades, kingdom
-- nodes and level; recomputing all of that on every request in order to credit a
-- few gold would cost far more than the income is worth. It is rewritten
-- whenever anything feeding it changes, and crediting at the cached rate is
-- always correct because the rate is settled BEFORE it is allowed to change.
ALTER TABLE app.players
    ADD COLUMN tax_milli_per_hour bigint NOT NULL DEFAULT 0;

-- Everyone's clock restarts at the migration rather than being paid for all the
-- time that passed before continuous income existed.
UPDATE app.players SET tax_updated_at = now(), tax_milli_accrued = 0;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE app.players
    DROP COLUMN IF EXISTS tax_milli_per_hour;
-- +goose StatementEnd
