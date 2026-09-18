-- +goose Up
-- +goose StatementBegin

-- One row per UTC day: the figures the panel charts, rolled up once so that
-- they outlive app.player_days (kept 400 days) and cost one read to show. The
-- kpi_rollup job writes yesterday and the two days before it every morning, so
-- a refund or a delivery that lands a day late is counted on its own day.
-- Revenue is Production only, in US cents, as the billing desk counts it.
CREATE TABLE app.daily_kpi (
    day             date        PRIMARY KEY,
    -- Lords who played that day, and lords who joined it (deleted ones too).
    dau             integer     NOT NULL,
    new_lords       integer     NOT NULL,
    -- Lords who bought that day, what they paid, and what Apple gave back on it.
    payers          integer     NOT NULL,
    purchases       integer     NOT NULL,
    gross_cents     bigint      NOT NULL,
    refund_cents    bigint      NOT NULL,
    -- Diamonds that day: what play gave, what money bought, what was spent.
    diamonds_earned bigint      NOT NULL,
    diamonds_bought bigint      NOT NULL,
    diamonds_spent  bigint      NOT NULL,
    computed_at     timestamptz NOT NULL DEFAULT now()
);

-- The rollup sums a day of the ledger by class; without this it reads it all.
CREATE INDEX diamond_ledger_created_idx ON app.diamond_ledger (created_at);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP INDEX IF EXISTS app.diamond_ledger_created_idx;
DROP TABLE IF EXISTS app.daily_kpi;
-- +goose StatementEnd
