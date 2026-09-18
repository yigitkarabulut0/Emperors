-- +goose Up
-- +goose StatementBegin

-- The Royal Store's daily deals, one row per lord: the day's four, picked at
-- the day's first look and fixed until the lord's next midnight, so a balance
-- published at noon never reshuffles what someone is looking at. slots holds
-- what each slot was given and its price that day; claimed is a bit per slot.
-- A new day replaces the row.
CREATE TABLE app.player_deals (
    player_id uuid    PRIMARY KEY REFERENCES app.players(id) ON DELETE CASCADE,
    day       date    NOT NULL,
    slots     jsonb   NOT NULL,
    claimed   integer NOT NULL DEFAULT 0 CHECK (claimed >= 0)
);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS app.player_deals;
-- +goose StatementEnd
